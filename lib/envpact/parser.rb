# Parses env.spec files -- declarative contract for ConfigMap and Secret keys
# an app expects.
#
# Syntax (v5):
#   KEY                       # str, required, configmap, shared (all envs)
#   KEY?                      # optional
#   KEY: int                  # typed (str|int|bool|url|enum(a,b))
#   KEY: str = default        # with default (configmap only)
#
#   [secrets]                 # MODIFIER: type flips to secret (scope unchanged)
#   [env: production]         # SELECTOR: scope -> production, type RESETS to configmap
#   [env: production, staging]# multi-env scope
#   [shared]                  # SELECTOR: scope -> back to shared, type RESETS to configmap
#
# Output:
#   configmap = { "*" => { "KEY" => Entry }, "production" => {...} }
#   secrets   = { "*" => { "DB_PASS" => Entry }, "production" => {...} }
class EnvPact
  SHARED = "*".freeze
  VALID_TYPES = %i[str int bool url enum].freeze
  ENV_NAME_RE = /\A[A-Za-z0-9_-]+\z/.freeze

  attr_reader :configmap, :secrets

  def self.parse(text)
    new.tap { |spec| spec.send(:_parse, text) }
  end

  def self.parse_file(path)
    parse(File.read(path))
  end

  def initialize
    @configmap = {}
    @secrets   = {}
  end

  # Returns array of env names declared in the spec (excluding "*").
  def envs
    (@configmap.keys + @secrets.keys).uniq.reject { |e| e == SHARED }.sort
  end

  # Returns merged keys (shared + given env) for configmap.
  def configmap_for(env)
    merge_scope(@configmap, env)
  end

  def secrets_for(env)
    merge_scope(@secrets, env)
  end

  private

  def merge_scope(bucket, env)
    out = {}
    out.merge!(bucket[SHARED]) if bucket[SHARED]
    out.merge!(bucket[env])    if bucket[env]
    out
  end

  def _parse(text)
    scope = [SHARED]
    type  = :configmap

    text = text.sub(/\A\uFEFF/, "")
    text.each_line.with_index(1) do |raw, line_no|
      line = strip_comment(raw.chomp).strip
      next if line.empty?

      if line.start_with?("[") && line.end_with?("]")
        inner = line[1..-2].strip
        if inner == "secrets"
          type = :secret
        elsif inner == "shared"
          scope = [SHARED]
          type  = :configmap
        elsif inner.start_with?("env:")
          envs = inner.sub(/\Aenv:/, "").split(",").map(&:strip).reject(&:empty?)
          raise ParseError.new("empty [env: ...] selector", line_no) if envs.empty?
          envs.each do |e|
            unless ENV_NAME_RE.match?(e)
              raise ParseError.new(
                "invalid env name '#{e}' in [env: ...] (must match #{ENV_NAME_RE.source}; use commas to separate envs)",
                line_no
              )
            end
          end
          scope = envs
          type  = :configmap
        else
          raise ParseError.new("unknown header [#{inner}] (only [secrets], [shared] and [env: ...] allowed)", line_no)
        end
        next
      end

      entry = parse_key_line(line, line_no)
      if type == :secret && !entry[:default].nil?
        raise ParseError.new("secret '#{entry[:name]}' cannot have a default value", line_no)
      end

      store_entry(type, scope, entry, line_no)
    end
  end

  def parse_key_line(line, line_no)
    m = line.match(/\A([A-Z][A-Z0-9_]*)(\?)?(?:\s*:\s*([a-z]+(?:\([^)]*\))?))?(?:\s*=\s*(.+))?\z/)
    raise ParseError.new("invalid key line: #{line.inspect}", line_no) unless m

    name      = m[1]
    optional  = !m[2].nil?
    type_str  = m[3] || "str"
    default   = m[4] && parse_default(m[4].strip, line_no)

    type, enum_values = parse_type(type_str, line_no)
    { name: name, type: type, optional: optional, default: default, enum_values: enum_values }
  end

  # A "#" starts a comment at line start or after whitespace, never inside a
  # double-quoted default.
  def strip_comment(line)
    in_quotes = false
    escaped   = false
    line.each_char.with_index do |ch, i|
      if escaped
        escaped = false
      elsif ch == "\\" && in_quotes
        escaped = true
      elsif ch == "\""
        in_quotes = !in_quotes
      elsif ch == "#" && !in_quotes && (i.zero? || line[i - 1] =~ /\s/)
        return line[0...i]
      end
    end
    line
  end

  def parse_default(raw, line_no)
    return raw unless raw.start_with?("\"")
    m = raw.match(/\A"((?:[^"\\]|\\.)*)"\z/)
    raise ParseError.new("unterminated quoted default: #{raw}", line_no) unless m
    m[1].gsub(/\\(.)/) { Regexp.last_match(1) }
  end

  def parse_type(type_str, line_no)
    if type_str.start_with?("enum(")
      unless (em = type_str.match(/\Aenum\((.+)\)\z/))
        raise ParseError.new("malformed enum type: #{type_str}", line_no)
      end
      values = em[1].split(",").map(&:strip).reject(&:empty?)
      raise ParseError.new("enum requires at least one value", line_no) if values.empty?
      [:enum, values]
    else
      sym = type_str.to_sym
      unless VALID_TYPES.include?(sym)
        raise ParseError.new("unknown type '#{type_str}' (valid: #{VALID_TYPES.join(', ')})", line_no)
      end
      [sym, nil]
    end
  end

  def store_entry(type, scope, e, line_no)
    bucket = (type == :secret ? @secrets : @configmap)
    other  = (type == :secret ? @configmap : @secrets)

    scope.each do |env|
      bucket[env] ||= {}

      if (clash = find_overlapping(other, env, e[:name]))
        cm_line, secret_line = type == :secret ? [clash[:entry].line, line_no] : [line_no, clash[:entry].line]
        raise ParseError.new(
          "key '#{e[:name]}' declared as both configmap (line #{cm_line}) and secret (line #{secret_line})",
          line_no
        )
      end

      if (existing = find_overlapping(bucket, env, e[:name]))
        raise ParseError.new(
          "key '#{e[:name]}' defined in overlapping scopes ('#{existing[:env]}' line #{existing[:entry].line} and '#{env}' here)",
          line_no
        )
      end

      bucket[env][e[:name]] = Entry.new(
        type: e[:type],
        optional: e[:optional],
        default: e[:default],
        enum_values: e[:enum_values],
        line: line_no
      )
    end

    check_cross_env_type_consistency(bucket, e[:name], e[:type], e[:enum_values], line_no)
  end

  def find_overlapping(bucket, env, key)
    bucket.each do |existing_env, keys|
      next unless keys.key?(key)
      next if existing_env == env
      if existing_env == SHARED || env == SHARED
        return { env: existing_env, entry: keys[key] }
      end
    end
    if bucket[env] && bucket[env].key?(key)
      return { env: env, entry: bucket[env][key] }
    end
    nil
  end

  def check_cross_env_type_consistency(bucket, key, type, enum_values, line_no)
    seen = nil
    bucket.each do |env, keys|
      next unless keys.key?(key)
      e = keys[key]
      if seen.nil?
        seen = [env, e.type, e.enum_values]
      else
        if seen[1] != e.type || seen[2] != e.enum_values
          raise ParseError.new(
            "key '#{key}' has different types across envs ('#{seen[0]}' is #{seen[1]}, '#{env}' is #{e.type})",
            line_no
          )
        end
      end
    end
  end
end
