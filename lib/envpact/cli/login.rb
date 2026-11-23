require "time"
require_relative "command"

class EnvPact
  class CLI
    class Login < Command
      command_name "login"
      summary "Log in to OpenBao and store the token, encrypted, in ~/.ob_read or ~/.ob_write"
      banner "Usage: envpact login --read|--write [options]"
      description <<~DESC
        Logs in with OIDC (opens a browser, waits on 127.0.0.1) or takes a token
        from stdin (--token-stdin), then asks for a passphrase on the terminal
        and stores the token encrypted: ~/.ob_read (--read) or ~/.ob_write
        (--write). Without --role, --read uses the server's default role;
        --write needs --role (e.g. --role=escrita).
        The address comes from --addr, $BAO_ADDR or addr= in the env.spec [source].
      DESC

      MIN_PASSPHRASE = 12

      def default_opts
        { oidc_mount: "oidc", port: 8250, token_stdin: false }
      end

      def configure(o, opts)
        o.on("--read", "Store the read token (~/.ob_read)")   { opts[:kind] = [*opts[:kind], :read] }
        o.on("--write", "Store the write token (~/.ob_write)") { opts[:kind] = [*opts[:kind], :write] }
        o.on("--addr=URL", "OpenBao address (default: $BAO_ADDR or [source] addr=)") { |v| opts[:addr] = v }
        o.on("--role=NAME", "OIDC role")                       { |v| opts[:role] = v }
        o.on("--oidc-mount=NAME", "OIDC auth mount (default: oidc)") { |v| opts[:oidc_mount] = v }
        o.on("--port=N", Integer, "Loopback port for the OIDC redirect (default: 8250)") { |v| opts[:port] = v }
        o.on("--token-stdin", "Read the token from one line of stdin instead of OIDC") { opts[:token_stdin] = true }
        spec_option(o, opts)
      end

      def call(_rest, opts)
        kinds = opts[:kind].to_a
        raise UsageError, "give --read or --write" if kinds.empty?
        raise UsageError, "--read and --write are exclusive" if kinds.uniq.size > 1
        kind = kinds.first
        raise UsageError, "--write needs --role=NAME" if kind == :write && opts[:role].nil? && !opts[:token_stdin]
        raise UsageError, "--port must be 0..65535" unless (0..65_535).cover?(opts[:port])

        addr = resolve_addr(opts)
        unless @prompt.available?
          raise EnvPact::Error, "login needs a terminal to ask for the passphrase"
        end

        client = OpenBao::Client.new(addr: addr)
        token = opts[:token_stdin] ? read_token_stdin : oidc_token(client, opts)
        authed = OpenBao::Client.new(addr: addr, token: token, role: kind)
        info = authed.lookup_self

        passphrase = ask_new_passphrase
        role = opts[:role] || info["role"] || "default"
        Keyfile.write(kind, token: token, addr: addr, role: role, expire_time: info["expire_time"], passphrase: passphrase)
        puts "✓ logged in (#{kind}, role #{role}, #{expiry_text(info['expire_time'])}) → ~/#{File.basename(Keyfile.path(kind))}"
        0
      end

      private

      def resolve_addr(opts)
        return opts[:addr] if opts[:addr]
        return ENV["BAO_ADDR"] if ENV["BAO_ADDR"] && !ENV["BAO_ADDR"].empty?
        path = spec_path(opts)
        File.file?(path) ? EnvPact.parse_file(path).sources.map(&:addr).compact.first : nil
      end

      def read_token_stdin
        line = $stdin.gets
        token = line.to_s.strip
        raise EnvPact::Error, "no token on stdin" if token.empty?
        token
      end

      def oidc_token(client, opts)
        OIDCLogin.new(client: client, mount: opts[:oidc_mount], role: opts[:role], port: opts[:port]).token
      end

      def ask_new_passphrase
        first = @prompt.secret("New passphrase for the token file (min #{MIN_PASSPHRASE} chars): ")
        raise EnvPact::Error, "passphrase must have at least #{MIN_PASSPHRASE} characters" if first.length < MIN_PASSPHRASE
        again = @prompt.secret("Repeat passphrase: ")
        raise EnvPact::Error, "passphrases do not match" unless first == again
        first
      end

      def expiry_text(expire_time)
        return "no expiry" if expire_time.nil? || expire_time.to_s.empty?
        "expires #{Time.iso8601(expire_time).localtime.strftime('%Y-%m-%d %H:%M')}"
      rescue ArgumentError
        "expires #{expire_time}"
      end
    end
  end
end
