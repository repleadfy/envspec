require_relative "command"

class EnvPact
  class CLI
    class Lock < Command
      command_name "lock"
      summary "Stop the local agent and forget the read token"
      banner "Usage: envpact lock"

      def call(_rest, _opts)
        if Agent.request("lock")
          puts "✓ agent locked"
        else
          puts "no agent running"
        end
        0
      end
    end
  end
end
