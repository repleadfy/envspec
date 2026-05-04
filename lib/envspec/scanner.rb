require "find"
require "set"

class EnvSpec
  # Scans a directory tree for env var usages across multiple languages.
  # Pure regex (no AST parser) to keep zero-deps requirement.
  #
  # Returns:
  #   { "OPENAI_API_KEY" => [{ file: "...", line: 9, default: nil, optional: true }, ...] }
  module Scanner
    SKIP_DIRS = %w[
      .git node_modules vendor tmp log logs coverage
      .bundle .yarn .pnpm-store dist build target
      __pycache__ .venv venv .pytest_cache .next .nuxt .turbo
    ].to_set.freeze

    SKIP_FILE_RE = /
      \.lock\z |
      \.min\.(js|css)\z |
      \.svg\z |
      \.png\z | \.jpg\z | \.jpeg\z | \.gif\z | \.ico\z | \.webp\z |
      \.pdf\z | \.zip\z | \.tar\z | \.gz\z |
      \.woff2?\z | \.ttf\z | \.eot\z |
      \.map\z
    /x.freeze

    MAX_FILE_BYTES = 1_048_576  # 1 MB

    EXT_LANG = {
      ".rb"     => :ruby,
      ".rake"   => :ruby,
      ".gemspec"=> :ruby,
      ".py"     => :python,
      ".js"     => :js,
      ".jsx"    => :js,
      ".ts"     => :js,
      ".tsx"    => :js,
      ".mjs"    => :js,
      ".cjs"    => :js,
      ".go"     => :go,
      ".sh"     => :shell,
      ".bash"   => :shell,
    }.freeze

    SPECIAL_FILES = {
      "Dockerfile"   => :shell,
      "Rakefile"     => :ruby,
      "Gemfile"      => :ruby,
      "config.ru"    => :ruby,
    }.freeze

    PATTERNS = {
      ruby: [
        /ENV\s*\[\s*["']([A-Z][A-Z0-9_]*)["']\s*\]/,
        /ENV\.fetch\s*\(\s*["']([A-Z][A-Z0-9_]*)["'](?:\s*,\s*([^)]+))?\s*\)/,
      ],
      python: [
        /os\.environ\s*\[\s*["']([A-Z][A-Z0-9_]*)["']\s*\]/,
        /os\.environ\.get\s*\(\s*["']([A-Z][A-Z0-9_]*)["'](?:\s*,\s*([^)]+))?\s*\)/,
        /os\.getenv\s*\(\s*["']([A-Z][A-Z0-9_]*)["'](?:\s*,\s*([^)]+))?\s*\)/,
      ],
      js: [
        /process\.env\.([A-Z][A-Z0-9_]*)/,
        /process\.env\s*\[\s*["']([A-Z][A-Z0-9_]*)["']\s*\]/,
        /import\.meta\.env\.([A-Z][A-Z0-9_]*)/,
      ],
      go: [
        /os\.Getenv\s*\(\s*["']([A-Z][A-Z0-9_]*)["']\s*\)/,
        /os\.LookupEnv\s*\(\s*["']([A-Z][A-Z0-9_]*)["']\s*\)/,
      ],
      shell: [
        /\$\{([A-Z][A-Z0-9_]*)(?::[-=?+][^}]*)?\}/,
        /\$([A-Z][A-Z0-9_]{2,})\b/,  # require ≥ 3 chars to dodge $PATH-style false positives... actually $PATH is fine, but cuts $A
      ],
    }.freeze

    def self.scan(root, ignore_globs: [])
      results = Hash.new { |h, k| h[k] = [] }
      gitignore_globs = parse_gitignore(File.join(root, ".gitignore"))
      all_globs = (ignore_globs + gitignore_globs).uniq

      Find.find(root) do |path|
        rel = path.sub(/\A#{Regexp.escape(root)}\/?/, "")

        if File.directory?(path)
          base = File.basename(path)
          if SKIP_DIRS.include?(base) || ignored?(rel, all_globs, dir: true)
            Find.prune
          end
          next
        end

        next if File.basename(path).start_with?(".") && File.basename(path) != ".envrc"
        next if path =~ SKIP_FILE_RE
        next if File.size(path) > MAX_FILE_BYTES rescue next
        next if ignored?(rel, all_globs, dir: false)

        lang = lang_for(path)
        next unless lang

        scan_file(path, lang, results)
      end

      results
    end

    def self.lang_for(path)
      base = File.basename(path)
      return SPECIAL_FILES[base] if SPECIAL_FILES.key?(base)
      EXT_LANG[File.extname(path)]
    end

    def self.scan_file(path, lang, results)
      content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
      patterns = PATTERNS[lang] || []

      content.each_line.with_index(1) do |line, line_no|
        patterns.each do |re|
          line.scan(re) do |captures|
            name    = captures[0]
            default = captures[1] && captures[1].strip
            results[name] << {
              file: path,
              line: line_no,
              default: extract_default(default),
              optional: !default.nil?,
            }
          end
        end
      end
    rescue ArgumentError, Errno::ENOENT
      # Skip unreadable / binary files
    end

    def self.extract_default(raw)
      return nil if raw.nil? || raw.empty?
      # strip surrounding quotes if literal string
      m = raw.match(/\A["']([^"']*)["']\z/)
      m ? m[1] : nil
    end

    # Minimal .gitignore parser — supports literal patterns and globs (no
    # full git semantics, just common cases).
    def self.parse_gitignore(path)
      return [] unless File.exist?(path)
      File.readlines(path).map(&:strip).reject { |l| l.empty? || l.start_with?("#") }
    rescue
      []
    end

    def self.ignored?(rel, globs, dir:)
      globs.any? do |pat|
        clean = pat.sub(/\A\//, "").sub(/\/\z/, "")
        next false if clean.empty?
        File.fnmatch?(clean, rel, File::FNM_PATHNAME) ||
          File.fnmatch?(clean, File.basename(rel)) ||
          rel.start_with?("#{clean}/")
      end
    end
  end
end
