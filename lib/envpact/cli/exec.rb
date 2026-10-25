require_relative "command"

class EnvPact
  class CLI
    class Exec < Command
      command_name "exec"
      summary "Check process ENV, then replace this process with CMD"
      banner "Usage: envpact exec [--env=NAME] [--spec=PATH] -- CMD [ARGS...]"
      description <<~DESC
        Boot check for containers and local runs. Validates the current process
        ENV against the spec; on success fills in defaults for absent or empty
        keys and execs CMD (envpact disappears from the process tree). On
        failure prints the problems and exits 1 without starting CMD.
        The env name comes from --env or $ENVPACT_ENV.
      DESC

      def configure(o, opts)
        o.on("--env=NAME", "Env to check (default: $ENVPACT_ENV)") { |v| opts[:env] = v }
        spec_option(o, opts)
      end

      # Everything after the first "--" is the command, untouched by
      # OptionParser.
      def run(argv)
        sep = argv.index("--")
        own, @command = sep ? [argv[0...sep], argv[(sep + 1)..-1]] : [argv, []]
        super(own)
      end

      def call(_rest, opts)
        env = opts[:env] || ENV["ENVPACT_ENV"]
        raise UsageError, "--env=NAME (or $ENVPACT_ENV) is required" if env.nil? || env.empty?
        raise UsageError, "missing command: envpact exec [options] -- CMD [ARGS...]" if @command.empty?

        spec   = load_spec(opts)
        result = spec.check(ENV.to_h, env: env, extras: false)
        return report(spec, result, opts) unless result.ok?

        # stderr, so the app's stdout stays its own; shows which sections
        # applied, which is how an ENVPACT_ENV typo becomes visible at boot.
        warn "✓ #{File.basename(spec_path(opts))} satisfied (#{scope_label(spec, result)})"
        fill_defaults(spec, env)
        Kernel.exec(*@command)
      rescue Errno::ENOENT
        die("command not found: #{@command.first}", 127)
      rescue Errno::EACCES, Errno::ENOEXEC => e
        die("cannot execute: #{@command.first} (#{e.message})", 126)
      end

      private

      def fill_defaults(spec, env)
        spec.configmap_for(env).each do |key, entry|
          next if entry.default.nil?
          ENV[key] = entry.default if ENV[key].nil? || ENV[key].empty?
        end
      end
    end
  end
end
