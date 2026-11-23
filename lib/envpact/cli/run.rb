require_relative "exec"

class EnvPact
  class CLI
    # `exec` plus the secrets from OpenBao, held only in this process's ENV.
    class Run < Exec
      command_name "run"
      summary "Fetch the env's secrets from OpenBao, check, then exec CMD with them"
      banner "Usage: envpact run [--env=NAME] [--spec=PATH] -- CMD [ARGS...]"
      description <<~DESC
        Reads the secrets of the env from the source in envpact.yml and puts them
        in the environment of CMD only: nothing is written to disk, and the
        OpenBao token never reaches CMD. Values from the source override the
        current ENV. The result is checked against the contract (unknown ENV
        keys are ignored), defaults are filled in, and CMD replaces this
        process. On failure prints the problems and exits 1 without starting
        CMD. The env name comes from --env or $ENVPACT_ENV.
      DESC

      def call(_rest, opts)
        env = opts[:env] || ENV["ENVPACT_ENV"]
        raise UsageError, "--env=NAME (or $ENVPACT_ENV) is required" if env.nil? || env.empty?
        raise UsageError, "missing command: envpact run [options] -- CMD [ARGS...]" if @command.empty?

        spec = load_spec(opts)
        # An inherited token must not reach the app, whatever happens next.
        %w[BAO_TOKEN VAULT_TOKEN].each { |k| ENV.delete(k) }

        warnings = []
        fetched = fetch_source(spec, env, warnings: warnings)
        fetched.each do |key, value|
          raise EnvPact::Error, "value of '#{key}' contains a NUL byte; it cannot be put in the environment" if value.include?("\0")
        end
        ENV.update(fetched)
        warnings.each { |p| warn "  ! #{p.message}" }

        result = spec.check(ENV.to_h, env: env, extras: false)
        return report(spec, result, opts) unless result.ok?

        warn "✓ #{File.basename(spec_path(opts))} satisfied (#{scope_label(spec, result)})"
        Boot.fill_defaults(spec, env)
        Boot.exec_command(@command)
      end
    end
  end
end
