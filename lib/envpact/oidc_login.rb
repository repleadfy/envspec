require "socket"
require "securerandom"
require "uri"

class EnvPact
  # OIDC login through a loopback listener, like `bao login -method=oidc`:
  # asks the server for the IdP URL, hands it to a browser, waits for the
  # redirect back to 127.0.0.1, and trades code+state for a client token.
  class OIDCLogin
    CALLBACK_PATH = "/oidc/callback".freeze
    PAGE = "envpact: login ok, you can close this tab\n".freeze

    # opener is called with the IdP URL; the URL is always printed on stderr
    # too, so a missing browser is not fatal. wait: is the time (seconds) to
    # wait for the redirect.
    def initialize(client:, mount:, role:, port:, opener: self.class.default_opener, wait: 120)
      @client = client
      @mount  = mount
      @role   = role
      @port   = port
      @opener = opener
      @wait   = wait
    end

    def self.default_opener
      lambda do |url|
        %w[open xdg-open wslview].each do |bin|
          next unless on_path?(bin)
          system(bin, url, out: File::NULL, err: File::NULL)
          return
        end
      end
    end

    def self.on_path?(bin)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, bin)) }
    end

    def token
      server = listen
      begin
        port  = server.addr[1]
        nonce = SecureRandom.hex(16)
        redirect_uri = "http://localhost:#{port}#{CALLBACK_PATH}"

        params = { "redirect_uri" => redirect_uri, "client_nonce" => nonce }
        params["role"] = @role if @role
        resp = @client.post_unauthenticated("auth/#{@mount}/oidc/auth_url", params)
        auth_url = resp.is_a?(Hash) && resp["data"].is_a?(Hash) ? resp["data"]["auth_url"] : nil
        raise Error, "OpenBao returned no auth_url (is the OIDC role configured?)" if auth_url.to_s.empty?
        expected_state = state_of(auth_url)

        warn "Open this URL to log in (waiting for the browser):\n  #{auth_url}"
        opener = @opener
        Thread.new { begin; opener.call(auth_url); rescue StandardError; nil; end }

        code, state = wait_for_callback(server, expected_state)

        out = @client.get_unauthenticated("auth/#{@mount}/oidc/callback",
                                          "state" => state, "code" => code, "client_nonce" => nonce)
        tok = out.is_a?(Hash) && out["auth"].is_a?(Hash) ? out["auth"]["client_token"] : nil
        raise Error, "OpenBao returned no token for this login" if tok.to_s.empty?
        tok
      ensure
        server.close unless server.closed?
      end
    end

    private

    def listen
      TCPServer.new("127.0.0.1", @port)
    rescue SystemCallError => e
      raise Error, "cannot listen on 127.0.0.1:#{@port} (#{e.class.name.split('::').last}); " \
                   "pick another with --port"
    end

    def state_of(url)
      q = URI.parse(url).query
      q && URI.decode_www_form(q).to_h["state"]
    rescue URI::InvalidURIError, ArgumentError
      nil
    end

    # Serves requests until one is the callback; returns [code, state]. Other
    # paths get a 404 and are ignored; a callback with the wrong state aborts.
    def wait_for_callback(server, expected_state)
      deadline = Time.now + @wait
      loop do
        left = deadline - Time.now
        raise Error, "login timed out" if left <= 0
        next unless IO.select([server], nil, nil, left)
        sock = server.accept
        begin
          path, query = read_request(sock, deadline)
          if path != CALLBACK_PATH
            respond(sock, 404, "not found\n")
            next
          end
          q = query ? URI.decode_www_form(query).to_h : {}
          if q["code"].to_s.empty? || q["state"].to_s.empty?
            respond(sock, 400, "envpact: missing code or state\n")
            next
          end
          if expected_state.nil? || q["state"] != expected_state
            respond(sock, 400, "envpact: login failed (state mismatch)\n")
            raise Error, "login state mismatch"
          end
          respond(sock, 200, PAGE)
          return [q["code"], q["state"]]
        ensure
          sock.close unless sock.closed?
        end
      end
    end

    def read_request(sock, deadline)
      line = timed_gets(sock, deadline)
      return [nil, nil] unless line
      64.times do
        l = timed_gets(sock, deadline)
        break if l.nil? || l == "\r\n" || l == "\n"
      end
      target = line.split(" ")[1].to_s
      uri = URI.parse(target)
      [uri.path, uri.query]
    rescue URI::InvalidURIError
      [nil, nil]
    end

    def timed_gets(sock, deadline)
      left = [deadline - Time.now, 5].min
      return nil if left <= 0 || !IO.select([sock], nil, nil, left)
      sock.gets
    end

    def respond(sock, status, text)
      sock.write("HTTP/1.1 #{status} X\r\nContent-Type: text/plain; charset=utf-8\r\n" \
                 "Content-Length: #{text.bytesize}\r\nConnection: close\r\n\r\n#{text}")
    rescue SystemCallError, IOError
      nil
    end
  end
end
