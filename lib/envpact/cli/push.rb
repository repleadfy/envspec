require_relative "command"

class EnvPact
  class CLI
    class Push < Command
      command_name "push"
      summary "Write secrets from a dotenv file to OpenBao (merge), after confirmation"
      banner "Usage: envpact push --env=NAME --from=PATH|- [--spec=PATH]"
      description <<~DESC
        Reads KEY=value lines from a dotenv file (or stdin with --from=-), keeps
        the keys the contract declares as secrets for the env, validates them and
        merges them into the env's [source] path. Existing keys in OpenBao are
        never deleted. Asks for confirmation and the ~/.ob_write passphrase on
        the terminal; with no terminal it refuses before any network call.
      DESC

      def configure(o, opts)
        o.on("--env=NAME", "Env to write (required)") { |v| opts[:env] = v }
        o.on("--from=PATH", "Dotenv file to read, or - for stdin (required)") { |v| opts[:from] = v }
        spec_option(o, opts)
      end

      def call(_rest, opts)
        env  = opts[:env]  or raise UsageError, "--env=NAME is required"
        from = opts[:from] or raise UsageError, "--from=PATH (or -) is required"
        spec = load_spec(opts)

        text = from == "-" ? $stdin.read : EnvPact.read_text(from)
        input = Dotenv.parse(text.to_s)

        secrets   = spec.secrets_for(env)
        configmap = spec.configmap_for(env)
        values = {}
        input.each do |key, value|
          if configmap.key?(key)
            warn "! #{key} ignored (configmap)"
          elsif value.empty?
            warn "! #{key} is empty (skipped)"
          else
            values[key] = value
          end
        end
        secrets.each do |key, entry|
          next if entry.optional || values.key?(key) || !entry.default.nil?
          warn "! #{key} not in input (kept as is in OpenBao)"
        end

        WriteFlow.new(spec: spec, env: env, prompt: @prompt).call(values)
      end
    end
  end
end
