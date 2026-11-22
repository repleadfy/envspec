require "time"
require_relative "command"

class EnvPact
  class CLI
    class Unlock < Command
      command_name "unlock"
      summary "Keep the read token in a local agent for a while (no passphrase for pull/run)"
      banner "Usage: envpact unlock [--for=2h]"
      description <<~DESC
        Decrypts ~/.ob_read (passphrase on the terminal) and hands the token to a
        local agent that serves only this user, for --for (default 2h; units s, m,
        h; at most 8h and never past the token's own expiry). Writes (push/set)
        never use the agent.
      DESC

      DURATION_RE = /\A(\d+)([smh])\z/.freeze
      UNIT = { "s" => 1, "m" => 60, "h" => 3600 }.freeze

      def initialize(prompt: EnvPact::Prompt.new)
        super()
        @prompt = prompt
      end

      def default_opts
        { for: "2h" }
      end

      def configure(o, opts)
        o.on("--for=DURATION", "--por=DURATION", "How long to stay unlocked (default 2h)") { |v| opts[:for] = v }
      end

      def self.parse_duration(text)
        m = DURATION_RE.match(text.to_s)
        return nil unless m
        secs = m[1].to_i * UNIT.fetch(m[2])
        secs.positive? ? secs : nil
      end

      def call(_rest, opts)
        secs = self.class.parse_duration(opts[:for])
        raise UsageError, "--for must look like 30m, 2h or 90s (got '#{opts[:for]}')" unless secs

        raise EnvPact::Error, "unlock needs a terminal to ask for the passphrase" unless @prompt.available?
        unless File.exist?(Keyfile.path(:read))
          raise EnvPact::Error, "no ~/.ob_read; run envpact login --read"
        end
        got = Keyfile.read(:read, passphrase: @prompt.secret("Passphrase for ~/.ob_read: "))

        client = OpenBao::Client.new(addr: got[:addr], token: got[:token], role: :read)
        client.renew_self
        expire = fresh_expiry(client, got[:expire_time])

        until_time = Time.now + secs
        until_time = [until_time, expire].min if expire
        raise EnvPact::Error, "the read token has already expired; run envpact login --read" if until_time <= Time.now

        pid = Agent.start(token: got[:token], addr: got[:addr], until_time: until_time)
        puts "✓ unlocked until #{Agent.cap_until(until_time).localtime.strftime('%Y-%m-%d %H:%M')} (agent pid #{pid})"
        0
      end

      private

      def fresh_expiry(client, stale)
        text = client.lookup_self["expire_time"] || stale
        text.nil? || text.to_s.empty? ? nil : Time.iso8601(text)
      rescue OpenBao::Error, ArgumentError
        stale && (Time.iso8601(stale) rescue nil)
      end
    end
  end
end
