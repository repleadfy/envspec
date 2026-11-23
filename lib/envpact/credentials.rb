class EnvPact
  # Resolves tokens for the commands.
  #   read:  the agent when unlocked, otherwise ~/.ob_read + passphrase
  #   write: always ~/.ob_write + passphrase; the agent is never consulted
  class Credentials
    def initialize(prompt: Prompt.new)
      @prompt = prompt
    end

    # -> { token:, addr: }
    def read_token
      reply = Agent.request("token")
      if reply && reply["token"].is_a?(String) && !reply["token"].empty?
        return { token: reply["token"], addr: reply["addr"] }
      end
      from_keyfile(:read)
    end

    def write_token
      from_keyfile(:write)
    end

    # A ready OpenBao client for the read or write token. addr_hint is the
    # address the spec asked for (or nil); with none, $BAO_ADDR, then the
    # address the token was issued for. A token is only ever sent to the
    # address it was issued for: any other address is refused rather than
    # followed (a spec could otherwise point envpact at a server of its own).
    def read_client(addr_hint = nil)
      build_client(:read, read_token, addr_hint)
    end

    def write_client(addr_hint = nil)
      build_client(:write, write_token, addr_hint)
    end

    # Raises, without asking for anything, when ~/.ob_<kind> does not exist.
    def self.require_keyfile!(kind)
      return if File.exist?(Keyfile.path(kind))
      raise Error, "no ~/#{File.basename(Keyfile.path(kind))}; run envpact login --#{kind}"
    end

    private

    def build_client(kind, cred, addr_hint)
      wanted = addr_hint || (ENV["BAO_ADDR"] unless ENV["BAO_ADDR"].to_s.empty?)
      if wanted && cred[:addr] && wanted.sub(%r{/+\z}, "") != cred[:addr].sub(%r{/+\z}, "")
        raise Error, "refusing to send the OpenBao token to a different address than the one it was " \
                     "issued for (#{cred[:addr]} vs #{wanted}); run envpact login --#{kind} --addr=#{wanted}"
      end
      OpenBao::Client.new(addr: cred[:addr] || wanted, token: cred[:token], role: kind)
    end

    def from_keyfile(kind)
      # Fail before asking for a passphrase that cannot help.
      self.class.require_keyfile!(kind)
      name = "~/#{File.basename(Keyfile.path(kind))}"
      got = Keyfile.read(kind, passphrase: @prompt.secret("Passphrase for #{name}: "))
      { token: got[:token], addr: got[:addr] }
    end
  end
end
