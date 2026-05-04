require "optparse"

class EnvSpec
  class CLI
    SUBCOMMANDS = %w[lint check init help version].freeze

    def self.run(argv)
      new.run(argv)
    end

    def run(argv)
      argv = argv.dup
      cmd = argv.shift

      case cmd
      when nil, "help", "-h", "--help"
        print_help(argv.first)
        0
      when "version", "-v", "--version"
        puts EnvSpec::VERSION
        0
      when "lint"
        cmd_lint(argv)
      when "check"
        cmd_check(argv)
      when "init"
        cmd_init(argv)
      else
        warn "envspec: unknown command '#{cmd}'"
        warn ""
        print_help
        2
      end
    rescue OptionParser::ParseError => e
      warn "envspec: #{e.message}"
      2
    rescue EnvSpec::ParseError, EnvSpec::ValidationError => e
      warn "envspec: #{e.message}"
      1
    end

    private

    # ── help ──────────────────────────────────────────────────────────

    def print_help(topic = nil)
      case topic
      when "lint"  then puts lint_parser.help
      when "check" then puts check_parser({}).help
      when "init"  then puts init_parser({}).help
      else              puts global_help
      end
    end

    def global_help
      <<~HELP
        Usage: envspec <command> [options]

        Commands:
          lint <file>            Parse and validate syntax of an env.spec file
          check <file>           Check current ENV against the spec
          init                   Scan repo for env vars and generate env.spec
          help [command]         Show help for a command
          version                Show version

        Run `envspec help <command>` for command-specific options.
        Docs: https://github.com/repleadfy/envspec
      HELP
    end

    # ── lint ──────────────────────────────────────────────────────────

    def lint_parser
      OptionParser.new do |o|
        o.banner = "Usage: envspec lint <file>"
        o.separator ""
        o.separator "Parses an env.spec file and reports any syntax errors."
        o.separator ""
        o.separator "Options:"
        o.on("-h", "--help") { puts o; exit 0 }
      end
    end

    def cmd_lint(argv)
      rest = lint_parser.parse(argv)
      file = rest.shift or (warn lint_parser.help; return 2)
      die_unless_file(file)

      EnvSpec.parse_file(file)
      puts "✓ #{file} is valid"
      0
    end

    # ── check ─────────────────────────────────────────────────────────

    def check_parser(opts)
      OptionParser.new do |o|
        o.banner = "Usage: envspec check <file> [options]"
        o.separator ""
        o.separator "Validates the current process ENV against an env.spec file."
        o.separator "Checks presence of required keys and that values match declared types."
        o.separator ""
        o.separator "Options:"
        o.on("--env=NAME", "Env scope to validate against (default: shared/*)") do |v|
          opts[:env] = v
        end
        o.on("--strict", "Treat unknown env vars as problems") do
          opts[:strict] = true
        end
        o.on("-h", "--help") { puts o; exit 0 }
      end
    end

    def cmd_check(argv)
      opts = { env: "*", strict: false }
      rest = check_parser(opts).parse(argv)
      file = rest.shift or (warn check_parser(opts).help; return 2)
      die_unless_file(file)

      spec = EnvSpec.parse_file(file)
      spec.validate!(ENV.to_h, env: opts[:env], strict: opts[:strict])

      label = opts[:env] == "*" ? "shared" : opts[:env]
      puts "✓ ENV satisfies #{file} (env: #{label})"
      0
    end

    # ── init ──────────────────────────────────────────────────────────

    def init_parser(opts)
      OptionParser.new do |o|
        o.banner = "Usage: envspec init [options]"
        o.separator ""
        o.separator "Scans the current directory tree for env var usages across"
        o.separator "Ruby/Python/JS/Go/Shell sources and writes a starter env.spec."
        o.separator ""
        o.separator "Options:"
        o.on("--force", "Overwrite an existing env.spec") { opts[:force] = true }
        o.on("--output=PATH", "Output file (default: env.spec)") { |v| opts[:output] = v }
        o.on("--root=PATH",   "Directory to scan (default: cwd)") { |v| opts[:root] = v }
        o.on("-h", "--help") { puts o; exit 0 }
      end
    end

    def cmd_init(argv)
      opts = { force: false, output: "env.spec", root: Dir.pwd }
      init_parser(opts).parse(argv)

      result = EnvSpec::Init.run(root: opts[:root], force: opts[:force], output: opts[:output])

      unless result[:ok]
        if result[:reason] == :exists
          warn "envspec: #{opts[:output]} already exists (use --force to overwrite)"
          return 1
        end
        warn "envspec: init failed: #{result[:reason]}"
        return 1
      end

      puts "✓ Scanned in #{format('%.2fs', result[:elapsed])}"
      puts "✓ Found #{result[:keys]} env vars across #{result[:files]} files"
      puts "✓ Wrote #{result[:path]}"
      puts ""
      puts "Next steps:"
      puts "  1. Edit #{opts[:output]} — review heuristic suggestions, classify secrets"
      puts "  2. Run `envspec lint #{opts[:output]}` to validate"
      puts "  3. Run `envspec check #{opts[:output]}` to test against your current ENV"
      0
    end

    # ── helpers ───────────────────────────────────────────────────────

    def die_unless_file(file)
      return if File.exist?(file)
      warn "envspec: file not found: #{file}"
      exit 1
    end
  end
end
