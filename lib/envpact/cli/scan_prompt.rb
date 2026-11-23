require_relative "command"

class EnvPact
  class CLI
    class ScanPromptCommand < Command
      command_name "scan-prompt"
      summary "Print instructions for an AI agent to write envpact.yml"
      banner "Usage: envpact scan-prompt"
      description <<~DESC
        Prints a self-contained prompt that tells an agent (e.g. Claude) how to
        find every env var in this repo and write or update envpact.yml.
        Typical use: envpact scan-prompt | claude
      DESC

      def call(_rest, _opts)
        print EnvPact::ScanPrompt.render
        0
      end
    end
  end
end
