require_relative "command"

class EnvPact
  class CLI
    class Lint < Command
      command_name "lint"
      summary "Parse and validate syntax of the contract (envpact.yml, or the legacy env.spec)"
      banner "Usage: envpact lint [--spec=PATH]"
      description "Parses the contract (envpact.yml, or the legacy env.spec) and reports any syntax errors."

      def configure(o, opts)
        spec_option(o, opts)
      end

      def call(_rest, opts)
        load_spec(opts)
        puts "✓ #{spec_path(opts)} is valid"
        0
      end
    end
  end
end
