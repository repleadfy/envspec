require_relative "command"

class EnvPact
  class CLI
    class Set < Command
      command_name "set"
      summary "Write one secret to OpenBao (merge), after confirmation"
      banner "Usage: envpact set --env=NAME KEY [--spec=PATH]"
      description <<~DESC
        Sets one secret declared in the contract for the env. The value is read
        from one line of stdin when stdin is not a terminal, otherwise prompted
        for without echo. Never taken from argv or ENV. Asks for confirmation
        and the ~/.ob_write passphrase on the terminal; with no terminal it
        refuses before any network call.
      DESC

      def configure(o, opts)
        o.on("--env=NAME", "Env to write (required)") { |v| opts[:env] = v }
        spec_option(o, opts)
      end

      def call(rest, opts)
        env = opts[:env] or raise UsageError, "--env=NAME is required"
        raise UsageError, "give exactly one KEY: envpact set --env=NAME KEY" unless rest.size == 1
        key = rest.first
        spec = load_spec(opts)

        unless spec.secrets_for(env).key?(key)
          return die("'#{key}' is not a declared secret for env '#{env}' in the contract")
        end
        unless @prompt.available?
          return die(Prompt::NO_TTY)
        end

        value = read_value(key)
        WriteFlow.new(spec: spec, env: env, prompt: @prompt).call(key => value)
      end

      private

      def read_value(key)
        if $stdin.tty?
          @prompt.secret("Value for #{key}: ")
        else
          line = $stdin.gets
          raise EnvPact::Error, "no value on stdin for #{key}" if line.nil?
          line.chomp.chomp("\r")
        end
      end
    end
  end
end
