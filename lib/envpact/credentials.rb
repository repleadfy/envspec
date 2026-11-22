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

    private

    def from_keyfile(kind)
      # Fail before asking for a passphrase that cannot help.
      unless File.exist?(Keyfile.path(kind))
        raise Error, "no ~/#{File.basename(Keyfile.path(kind))}; run envpact login --#{kind}"
      end
      name = "~/#{File.basename(Keyfile.path(kind))}"
      got = Keyfile.read(kind, passphrase: @prompt.secret("Passphrase for #{name}: "))
      { token: got[:token], addr: got[:addr] }
    end
  end
end
