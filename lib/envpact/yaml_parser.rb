require "psych"

# Parses envpact.yml -- the YAML form of the contract. Builds the same model as
# the env.spec parser (configmap, secrets, sources), so everything downstream is
# format-agnostic.
#
#   version: 1
#   source: {openbao: {path: team/app/{env}, addr: https://bao.example.com}}
#   vars:    {APP_NAME: , PORT: {type: int, default: "3000"}}
#   secrets: {DB_PASS: }
#   envs:
#     production: {source: {...}, vars: {...}, secrets: {...}}
#     "staging, production": {vars: {...}}
#
# Scalars are read as the raw text of the YAML node, never coerced: `no`,
# `on`, `0.30` and `0800` stay strings. Anchors, aliases and tags are refused.
# Messages give the line and never echo a value.
class EnvPact
  YAML_FILE   = "envpact.yml".freeze
  LEGACY_FILE = "env.spec".freeze

  TOP_KEYS     = %w[version source vars secrets envs].freeze
  ENV_KEYS     = %w[source vars secrets].freeze
  ENTRY_FIELDS = %w[type default optional description].freeze
  KEY_NAME_RE  = /\A[A-Z][A-Z0-9_]*\z/.freeze
  NULLS        = ["", "~", "null", "Null", "NULL"].freeze

  def self.parse_yaml(text)
    new.tap { |spec| spec.send(:_parse_yaml, text) }
  end

  private

  def _parse_yaml(text)
    text = EnvPact.utf8(text).sub(/\A﻿/, "")
    root = yaml_root(text)
    return if root.nil?

    top = yaml_mapping(root, "the top level")
    pairs = yaml_pairs(top)
    pairs.each { |k, _v| raise ParseError.new("unknown key '#{k.value}' (valid: #{TOP_KEYS.join(', ')})", line_of(k)) unless TOP_KEYS.include?(k.value) }
    by_key = pairs.map { |k, v| [k.value, [k, v]] }.to_h

    version = by_key["version"]
    raise ParseError.new("missing 'version: 1'", 1) unless version
    unless yaml_scalar_text(version[1], "version") == "1"
      raise ParseError.new("version must be 1", line_of(version[1]))
    end

    yaml_source(by_key["source"][1], nil) if by_key["source"]
    yaml_keys(by_key["vars"][1], :configmap, [SHARED], "vars") if by_key["vars"]
    yaml_keys(by_key["secrets"][1], :secret, [SHARED], "secrets") if by_key["secrets"]
    yaml_envs(by_key["envs"][1]) if by_key["envs"]
  end

  def yaml_root(text)
    doc = Psych.parse(text)
    doc && doc.root
  rescue Psych::SyntaxError => e
    # The problem text names a token class, not the content of the line.
    raise ParseError.new("YAML syntax error at line #{e.line} column #{e.column} (#{e.problem})", e.line)
  end

  def line_of(node)
    node.start_line + 1
  end

  def yaml_check_plain(node)
    if node.is_a?(Psych::Nodes::Alias) || (node.respond_to?(:anchor) && node.anchor)
      raise ParseError.new("anchors and aliases are not allowed", line_of(node))
    end
    return unless node.respond_to?(:tag) && node.tag

    raise ParseError.new("tags are not allowed", line_of(node))
  end

  def yaml_mapping(node, where)
    yaml_check_plain(node)
    return node if node.is_a?(Psych::Nodes::Mapping)

    raise ParseError.new("#{where} must be a mapping", line_of(node))
  end

  # [[key_node, value_node], ...], refusing non-scalar and duplicate keys.
  def yaml_pairs(mapping)
    seen = {}
    mapping.children.each_slice(2).map do |k, v|
      yaml_check_plain(k)
      raise ParseError.new("keys must be plain names", line_of(k)) unless k.is_a?(Psych::Nodes::Scalar)
      raise ParseError.new("duplicate key '#{k.value}'", line_of(k)) if seen[k.value]

      seen[k.value] = true
      yaml_check_plain(v)
      [k, v]
    end
  end

  # nil for an empty value (KEY:, KEY: ~, KEY: null); the raw text otherwise.
  def yaml_scalar_text(node, what)
    yaml_check_plain(node)
    raise ParseError.new("#{what} must be a single value", line_of(node)) unless node.is_a?(Psych::Nodes::Scalar)
    return nil if node.plain && NULLS.include?(node.value)

    node.value
  end

  def yaml_empty?(node)
    node.is_a?(Psych::Nodes::Scalar) && node.plain && NULLS.include?(node.value)
  end

  def yaml_keys(node, type, scope, section)
    return if yaml_empty?(node)

    yaml_pairs(yaml_mapping(node, "'#{section}'")).each do |k, v|
      name = k.value
      line = line_of(k)
      raise ParseError.new("invalid key name '#{name}' (expected A-Z, 0-9 and _, starting with a letter)", line) unless KEY_NAME_RE.match?(name)

      entry = yaml_entry(name, v, line)
      raise ParseError.new("secret '#{name}' cannot have a default value", line) if type == :secret && !entry[:default].nil?

      check_default_type(entry, line)
      store_entry(type, scope, entry, line)
    end
  end

  def yaml_entry(name, node, line)
    type_str = "str"
    optional = false
    default = nil
    description = nil

    if node.is_a?(Psych::Nodes::Mapping)
      yaml_pairs(node).each do |k, v|
        field = k.value
        unless ENTRY_FIELDS.include?(field)
          hint = field.include?(")") ? "; inside {...} a comma splits enum(...)/url(...): quote the type, e.g. type: \"enum(a, b)\"" : ""
          raise ParseError.new("unknown field '#{field}' for '#{name}' (valid: #{ENTRY_FIELDS.join(', ')})#{hint}", line_of(k))
        end

        case field
        when "type" then type_str = yaml_scalar_text(v, "type") || "str"
        when "default" then default = yaml_scalar_text(v, "default")
        when "description" then description = yaml_scalar_text(v, "description")
        when "optional"
          raw = yaml_scalar_text(v, "optional")
          raise ParseError.new("optional for '#{name}' must be true or false", line_of(v)) unless %w[true false].include?(raw)

          optional = raw == "true"
        end
      end
    else
      type_str = yaml_scalar_text(node, "the value of '#{name}'") || "str"
    end

    type, enum_values = parse_type(type_str.strip, line)
    { name: name, type: type, optional: optional, default: default, enum_values: enum_values, description: description }
  end

  def yaml_envs(node)
    return if yaml_empty?(node)

    yaml_pairs(yaml_mapping(node, "'envs'")).each do |k, v|
      line = line_of(k)
      envs = k.value.split(",").map(&:strip).reject(&:empty?)
      raise ParseError.new("empty env name in 'envs'", line) if envs.empty?

      envs.each do |e|
        raise ParseError.new("invalid env name '#{e}' (must match #{ENV_NAME_RE.source}; use commas to separate envs)", line) unless ENV_NAME_RE.match?(e)
      end
      next if yaml_empty?(v)

      body = yaml_pairs(yaml_mapping(v, "env '#{k.value}'"))
      body.each { |bk, _| raise ParseError.new("unknown key '#{bk.value}' in env '#{k.value}' (valid: #{ENV_KEYS.join(', ')})", line_of(bk)) unless ENV_KEYS.include?(bk.value) }
      parts = body.map { |bk, bv| [bk.value, bv] }.to_h
      yaml_source(parts["source"], envs) if parts["source"]
      yaml_keys(parts["vars"], :configmap, envs, "vars") if parts["vars"]
      yaml_keys(parts["secrets"], :secret, envs, "secrets") if parts["secrets"]
    end
  end

  def yaml_source(node, envs)
    pairs = yaml_pairs(yaml_mapping(node, "'source'"))
    raise ParseError.new("'source' needs one backend (openbao)", line_of(node)) unless pairs.size == 1

    bk, bv = pairs.first
    line = line_of(bk)
    raise ParseError.new("unknown backend '#{bk.value}' in source (valid: #{SourceParser::BACKENDS.join(', ')})", line) unless SourceParser::BACKENDS.include?(bk.value)

    opts = {}
    yaml_pairs(yaml_mapping(bv, "source '#{bk.value}'")).each do |k, v|
      opt = k.value
      raise ParseError.new("unknown option '#{opt}' in source (valid: path, mount, addr)", line_of(k)) unless %w[path mount addr].include?(opt)

      opts[opt] = yaml_scalar_text(v, opt)
    end
    raise ParseError.new("source needs path", line) if opts["path"].nil?

    begin
      SourceParser.validate_path(opts["path"], line)
      SourceParser.validate_addr(opts["addr"], line) if opts["addr"]
    rescue ParseError => e
      raise ParseError.new(e.message.sub(/\Aline \d+: /, "").sub(" in [source]", " in source"), line)
    end
    mount = opts["mount"] || "secret"
    raise ParseError.new("invalid mount '#{mount}' in source", line) unless SourceParser::MOUNT_RE.match?(mount)

    sl = SourceLine.new(backend: bk.value, mount: mount, path: opts["path"], addr: opts["addr"], envs: envs, line: line)
    SourceParser.add(@sources, sl)
  end
end

class EnvPact
  # Where the contract of a repo is: [path, legacy?]. envpact.yml wins; env.spec
  # is the legacy fallback; both at once is an error (they would drift). With
  # neither, the envpact.yml path is returned so "not found" names it.
  def self.locate(dir = ".")
    yml = dir == "." ? YAML_FILE : File.join(dir, YAML_FILE)
    legacy = dir == "." ? LEGACY_FILE : File.join(dir, LEGACY_FILE)
    has_yml = File.file?(yml)
    has_legacy = File.file?(legacy)
    if has_yml && has_legacy
      raise Error, "both #{YAML_FILE} and #{LEGACY_FILE} in #{File.expand_path(dir)}: keep only #{YAML_FILE} (envpact convert writes it from #{LEGACY_FILE})"
    end
    return [legacy, true] if has_legacy

    [yml, false]
  end

  LEGACY_WARNING = "#{LEGACY_FILE} is deprecated: run `envpact convert` to write #{YAML_FILE}".freeze
end
