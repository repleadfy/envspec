require_relative "command"

class EnvPact
  class CLI
    class Check < Command
      command_name "check"
      summary "Check .env files (or process ENV) against the contract (envpact.yml)"
      banner "Usage: envpact check --env=NAME [options]"
      description <<~DESC
        Validates values against the contract (envpact.yml) for one env. By default reads the
        dotenv files for that env from the current directory
        (.env, .env.<env>, .env.local, .env.<env>.local; .env.local is skipped
        for test). Secret values are never printed unless --show-values.
      DESC

      def default_opts
        { strict: false, show_values: false, from_env: false }
      end

      def configure(o, opts)
        o.on("--env=NAME", "Env to check (required)")                 { |v| opts[:env] = v }
        spec_option(o, opts)
        o.on("--from-env", "Check the current process ENV, not files") { opts[:from_env] = true }
        o.on("--strict", "Treat unknown env vars as errors")           { opts[:strict] = true }
        o.on("--show-values", "Show secret values in problem messages") { opts[:show_values] = true }
        o.on("--source", "Also read the env's secrets from OpenBao (in memory, nothing is written)") { opts[:source] = true }
      end

      def call(_rest, opts)
        env = opts[:env] or raise UsageError, "--env=NAME is required"
        raise UsageError, "--show-values cannot be combined with --source" if opts[:source] && opts[:show_values]
        spec = load_spec(opts)

        if opts[:from_env]
          values = ENV.to_h
        else
          loaded = Dotenv.load(Dir.pwd, env: env)
          values = loaded[:values]
          puts "Read: #{loaded[:files].empty? ? '(no .env files found)' : loaded[:files].join(', ')}"
        end

        source_warnings = []
        values = values.merge(fetch_source(spec, env, warnings: source_warnings)) if opts[:source]

        result = spec.check(values, env: env, strict: opts[:strict], extras: !opts[:from_env])
        source_warnings.each { |p| warn "  ! #{p.message}" }
        report(spec, result, opts, reveal: opts[:show_values] ? values : nil)
      end
    end
  end
end
