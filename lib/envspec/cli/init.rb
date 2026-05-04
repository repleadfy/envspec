require_relative "command"

class EnvSpec
  class CLI
    class Init < Command
      name "init"
      summary "Scan repo for env vars and generate env.spec"
      banner "Usage: envspec init [options]"
      description <<~DESC
        Scans the current directory tree for env var usages across
        Ruby/Python/JS/Go/Shell sources and writes a starter env.spec.
      DESC

      def default_opts
        { force: false, output: "env.spec", root: Dir.pwd }
      end

      def configure(o, opts)
        o.on("--force",       "Overwrite an existing env.spec")    { opts[:force] = true }
        o.on("--output=PATH", "Output file (default: env.spec)")   { |v| opts[:output] = v }
        o.on("--root=PATH",   "Directory to scan (default: cwd)")  { |v| opts[:root] = v }
      end

      def call(_rest, opts)
        result = EnvSpec::Init.run(root: opts[:root], force: opts[:force], output: opts[:output])

        unless result[:ok]
          if result[:reason] == :exists
            return die("#{opts[:output]} already exists (use --force to overwrite)", 1)
          end
          return die("init failed: #{result[:reason]}", 1)
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
    end
  end
end
