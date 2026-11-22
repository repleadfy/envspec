require "uri"

class EnvPact
  # Where the secrets of one env live: a resolved `[source]` line.
  SourceRef = Struct.new(:backend, :mount, :path, :addr, :line, keyword_init: true)

  # One raw `[source]` line, before {env} is resolved. envs is nil for the
  # fallback line.
  SourceLine = Struct.new(:backend, :mount, :path, :addr, :envs, :line, keyword_init: true)

  # Parsing of `openbao k=v ...` lines. The parser only dispatches here.
  module SourceParser
    BACKENDS = %w[openbao].freeze
    OPTIONS  = %w[path mount addr env].freeze
    PATH_RE  = %r{\A[A-Za-z0-9_./{}-]+\z}.freeze
    MOUNT_RE = /\A[A-Za-z0-9_-]+\z/.freeze
    EXPECTED = "expected 'openbao path=...' in [source]".freeze

    # Returns a SourceLine. Messages never echo the line, only option names
    # and the offending path/env names.
    def self.parse_line(line, line_no)
      tokens  = line.split(/\s+/)
      backend = tokens.shift
      raise ParseError.new(EXPECTED, line_no) unless BACKENDS.include?(backend)

      opts = {}
      tokens.each do |tok|
        k, v = tok.split("=", 2)
        raise ParseError.new(EXPECTED, line_no) if v.nil? || v.empty?
        raise ParseError.new("unknown option '#{k}' in [source] (valid: #{OPTIONS.join(', ')})", line_no) unless OPTIONS.include?(k)
        raise ParseError.new("duplicate option '#{k}' in [source]", line_no) if opts.key?(k)
        opts[k] = v
      end

      raise ParseError.new("[source] line needs path=...", line_no) unless opts.key?("path")
      validate_path(opts["path"], line_no)
      mount = opts.fetch("mount", "secret")
      raise ParseError.new("invalid mount '#{mount}' in [source]", line_no) unless MOUNT_RE.match?(mount)
      validate_addr(opts["addr"], line_no) if opts["addr"]

      envs = opts["env"] && opts["env"].split(",").map(&:strip).reject(&:empty?)
      if envs
        raise ParseError.new("empty env= in [source]", line_no) if envs.empty?
        envs.each do |e|
          raise ParseError.new("invalid env name '#{e}' in [source] env=", line_no) unless EnvPact::ENV_NAME_RE.match?(e)
        end
      end

      SourceLine.new(backend: backend, mount: mount, path: opts["path"], addr: opts["addr"], envs: envs, line: line_no)
    end

    def self.validate_path(path, line_no)
      ok = PATH_RE.match?(path) && !path.start_with?("/") && !path.end_with?("/") &&
           path.split("/", -1).none? { |seg| seg.empty? || seg == ".." || seg == "." } &&
           path.gsub("{env}", "").count("{}").zero?
      raise ParseError.new("invalid path '#{path}' in [source] (allowed: letters, digits, _ . / -, and {env}; " \
                           "no '..', no leading or trailing '/')", line_no) unless ok
    end

    def self.validate_addr(addr, line_no)
      uri = URI.parse(addr)
      ok = %w[http https].include?(uri.scheme.to_s.downcase) && !uri.host.to_s.empty?
      raise ParseError.new("addr must be http(s)://host[:port] in [source]", line_no) unless ok
    rescue URI::InvalidURIError
      raise ParseError.new("addr must be http(s)://host[:port] in [source]", line_no)
    end

    # Registers a line into the list, rejecting overlaps.
    def self.add(lines, sl)
      if sl.envs.nil?
        if (prev = lines.find { |l| l.envs.nil? })
          raise ParseError.new("second fallback [source] line (the first is at line #{prev.line}); use env=... to scope it", sl.line)
        end
      else
        sl.envs.each do |e|
          if (prev = lines.find { |l| l.envs && l.envs.include?(e) })
            raise ParseError.new("env '#{e}' is in two [source] lines (the first is at line #{prev.line})", sl.line)
          end
        end
      end
      lines << sl
    end

    def self.resolve(lines, env)
      unless EnvPact::ENV_NAME_RE.match?(env.to_s)
        raise EnvPact::Error, "invalid env name '#{env}' (must match #{EnvPact::ENV_NAME_RE.source})"
      end
      sl = lines.find { |l| l.envs && l.envs.include?(env) } || lines.find { |l| l.envs.nil? }
      return nil unless sl
      SourceRef.new(backend: sl.backend, mount: sl.mount, path: sl.path.gsub("{env}", env),
                    addr: sl.addr, line: sl.line)
    end
  end
end
