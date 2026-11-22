require "time"
require_relative "command"

class EnvPact
  class CLI
    class Status < Command
      command_name "status"
      summary "Show the agent and the stored tokens (never the tokens)"
      banner "Usage: envpact status"

      def call(_rest, _opts)
        agent = Agent.request("status")
        if agent && agent["until"]
          puts "agent: unlocked until #{local(agent['until'])} (#{agent['addr']})"
        else
          puts "agent: locked"
        end
        %i[read write].each do |kind|
          name = "~/#{File.basename(Keyfile.path(kind))}"
          meta = Keyfile.meta(kind)
          if meta.nil?
            puts "#{name}: not logged in"
          else
            exp = meta[:expire_time] ? "expires #{local(meta[:expire_time])}" : "no expiry"
            puts "#{name}: role #{meta[:role]}, #{exp} (#{meta[:addr]})"
          end
        end
        0
      end

      private

      def local(iso)
        Time.iso8601(iso).localtime.strftime("%Y-%m-%d %H:%M")
      rescue ArgumentError
        iso.to_s
      end
    end
  end
end
