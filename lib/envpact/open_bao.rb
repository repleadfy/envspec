require "net/http"
require "openssl"
require "json"
require "uri"

class EnvPact
  # The only piece of envpact that speaks HTTP: a KV v2 client for OpenBao.
  # Error messages carry the address, mount/path and HTTP status, never a
  # token, a request or response body, or a header.
  module OpenBao
    class Error < EnvPact::Error; end
    class NotFound < Error; end
    class Denied < Error; end

    class Client
      SAFE_PATH_RE = %r{\A[A-Za-z0-9_./-]+\z}.freeze
      TOKEN_RE     = /\A[!-~]+\z/.freeze
      DEFAULT_TIMEOUT = 10

      # role (:read or :write) only picks the hint in the Denied message.
      def initialize(addr:, token: nil, role: :read, timeout: DEFAULT_TIMEOUT)
        if addr.nil? || addr.to_s.strip.empty?
          raise Error, "no OpenBao address: set addr= in [source] or $BAO_ADDR"
        end
        @addr = addr.to_s.strip.sub(%r{/+\z}, "")
        @uri  = parse_addr(@addr)
        if token && !TOKEN_RE.match?(token)
          raise Error, "invalid token format"
        end
        @token   = token
        @role    = role
        @timeout = timeout
      end

      def inspect
        "#<#{self.class} addr=#{addr} token=[redacted]>"
      end
      alias to_s inspect

      attr_reader :addr

      # -> Hash{String=>String} or nil when the path does not exist.
      def read(mount, path)
        label = location(mount, path)
        code, body = request("GET", "/v1/#{label_to_data(mount, path)}", label: label, ok: [404])
        return nil if code == 404
        data = body.is_a?(Hash) && body["data"].is_a?(Hash) ? body["data"]["data"] : nil
        return {} unless data.is_a?(Hash)
        data.each do |key, value|
          raise Error, "non-string value for key '#{key}' at #{label}" unless value.is_a?(String)
        end
        data
      end

      # Merge-patch; on first write (404) creates the secret.
      def write(mount, path, data)
        label = location(mount, path)
        url   = "/v1/#{label_to_data(mount, path)}"
        payload = JSON.generate("data" => data)
        code, = request("PATCH", url, payload, label: label, ok: [404],
                                              content_type: "application/merge-patch+json")
        request("POST", url, payload, label: label) if code == 404
        nil
      end

      def lookup_self
        _, body = request("GET", "/v1/auth/token/lookup-self", label: "auth/token/lookup-self")
        d = (body.is_a?(Hash) && body["data"]) || {}
        {
          "ttl"          => d["ttl"].to_i,
          "expire_time"  => d["expire_time"],
          "display_name" => d["display_name"].to_s,
          "policies"     => Array(d["policies"]),
          # The auth role the token came from (OIDC/JWT put it in meta.role).
          "role"         => (d["meta"]["role"] if d["meta"].is_a?(Hash))
        }
      end

      # A token that cannot be renewed (400) is not an error.
      def renew_self
        code, body = request("POST", "/v1/auth/token/renew-self", "{}", label: "auth/token/renew-self", ok: [400])
        code == 400 ? nil : body
      end

      def post_unauthenticated(path, body)
        _, parsed = request("POST", "/v1/#{safe(path)}", JSON.generate(body), label: path, auth: false)
        parsed
      end

      def get_unauthenticated(path, query)
        qs = URI.encode_www_form(query)
        _, parsed = request("GET", "/v1/#{safe(path)}?#{qs}", label: path, auth: false)
        parsed
      end

      private

      def parse_addr(addr)
        uri = URI.parse(addr)
        unless %w[http https].include?(uri.scheme.to_s.downcase) && !uri.host.to_s.empty?
          raise Error, "invalid OpenBao address (expected http(s)://host[:port])"
        end
        uri
      rescue URI::InvalidURIError
        raise Error, "invalid OpenBao address (expected http(s)://host[:port])"
      end

      def safe(path)
        ok = SAFE_PATH_RE.match?(path) && !path.start_with?("/") && !path.split("/").include?("..")
        raise Error, "unsafe OpenBao path '#{path}'" unless ok
        path
      end

      def location(mount, path)
        "#{safe(mount)}/#{safe(path)}"
      end

      def label_to_data(mount, path)
        "#{mount}/data/#{path}"
      end

      # Returns [code, parsed_body]. Codes in ok: are returned instead of
      # raised. 2xx always returns.
      def request(method, url, body = nil, label:, ok: [], content_type: "application/json", auth: true)
        http = Net::HTTP.new(@uri.host, @uri.port, nil) # nil: never an env proxy
        http.use_ssl = @uri.scheme.casecmp("https").zero?
        http.open_timeout = @timeout
        http.read_timeout = @timeout

        req = Net::HTTPGenericRequest.new(method, !body.nil?, true, url)
        req["Accept"] = "application/json"
        req["X-Vault-Token"] = @token if auth && @token
        if body
          req["Content-Type"] = content_type
          req.body = body
        end

        res = http.start { |h| h.request(req) }
        code = res.code.to_i
        parsed = parse_body(res.body)
        return [code, parsed] if code.between?(200, 299) || ok.include?(code)

        if code == 403
          raise Denied, "token rejected for #{label} (expired, revoked or not allowed); " \
                        "run envpact login --#{@role}"
        end
        raise NotFound, "#{label} not found at #{addr}" if code == 404
        raise Error, "OpenBao at #{addr} answered HTTP #{code} for #{label}"
      rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
        raise Error, "OpenBao at #{addr} timed out"
      rescue SocketError, SystemCallError, EOFError, IOError, OpenSSL::SSL::SSLError => e
        raise Error, "cannot reach OpenBao at #{addr} (#{e.class})"
      end

      def parse_body(text)
        return {} if text.nil? || text.empty?
        JSON.parse(text)
      rescue JSON::ParserError
        {}
      end
    end
  end
end
