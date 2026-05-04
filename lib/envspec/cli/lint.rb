require_relative "command"

class EnvSpec
  class CLI
    class Lint < Command
      name "lint"
      summary "Parse and validate syntax of an env.spec file"
      banner "Usage: envspec lint <file>"
      description "Parses an env.spec file and reports any syntax errors."

      def call(rest, _opts)
        file = require_file(rest.shift)
        EnvSpec.parse_file(file)
        puts "✓ #{file} is valid"
        0
      end
    end
  end
end
