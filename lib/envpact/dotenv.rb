class EnvPact
  # Minimal stdlib reader for .env files. Supports KEY=value, an optional
  # `export ` prefix, comments, and single/double quoted values. No variable
  # interpolation and no multiline values.
  module Dotenv
    LINE_RE = /\A\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)\z/.freeze
    DOUBLE_QUOTE_ESCAPES = { "n" => "\n", '"' => '"', "\\" => "\\" }.freeze

    # Files read for an env, in order; later files override earlier ones.
    # .env.local is skipped for test so test runs don't depend on a
    # developer's personal overrides (dotenv convention).
    def self.files_for(env)
      files = [".env", ".env.#{env}"]
      files << ".env.local" unless env == "test"
      files << ".env.#{env}.local"
      files
    end

    # skip: absolute paths to leave out (the pull target is never an input).
    def self.load(dir, env:, skip: [])
      files  = []
      values = {}
      skipped = skip.map { |f| File.expand_path(f) }
      files_for(env).each do |name|
        path = File.join(dir, name)
        next if skipped.include?(File.expand_path(path))
        next unless File.file?(path)
        files << name
        values.merge!(parse(EnvPact.read_text(path)))
      end
      { files: files, values: values }
    end

    def self.parse(text)
      EnvPact.utf8(text).sub(/\A﻿/, "").each_line.each_with_object({}) do |raw, out|
        m = LINE_RE.match(raw.chomp.chomp("\r"))
        next unless m
        out[m[1]] = parse_value(m[2].strip)
      end
    end

    def self.parse_value(raw)
      return "" if raw.start_with?("#") # `KEY= # comment` is an empty value
      if raw.start_with?("'") && (close = raw.index("'", 1))
        raw[1...close]
      elsif raw.start_with?('"') && (m = raw.match(/\A"((?:[^"\\]|\\.)*)"/))
        m[1].gsub(/\\(.)/) { DOUBLE_QUOTE_ESCAPES.fetch(Regexp.last_match(1), Regexp.last_match(0)) }
      else
        raw.sub(/\s+#.*\z/, "")
      end
    end
  end
end
