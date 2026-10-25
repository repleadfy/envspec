require_relative "command"

class EnvPact
  class CLI
    class Check < Command
      name "check"
      summary "Check current ENV against an env.spec"
      banner "Usage: envpact check <file> [options]"
      description <<~DESC
        Validates the current process ENV against an env.spec file.
        Checks presence of required keys and that values match declared types.
      DESC

      def default_opts
        { env: "*", strict: false }
      end

      def configure(o, opts)
        o.on("--env=NAME", "Env scope to validate against (default: shared/*)") { |v| opts[:env] = v }
        o.on("--strict", "Treat unknown env vars as problems")                  { opts[:strict] = true }
      end

      def call(rest, opts)
        file = require_file(rest.shift)
        spec = EnvPact.parse_file(file)
        spec.validate!(ENV.to_h, env: opts[:env], strict: opts[:strict])
        label = opts[:env] == "*" ? "shared" : opts[:env]
        puts "✓ ENV satisfies #{file} (env: #{label})"
        0
      end
    end
  end
end
