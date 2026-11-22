require_relative "test_helper"
require_relative "support/fake_bao"
require "net/http"

class TestOIDCLogin < Minitest::Test
  AUTH_URL_PATH = "/v1/auth/oidc/oidc/auth_url".freeze
  CALLBACK_PATH = "/v1/auth/oidc/oidc/callback".freeze

  def setup
    @bao = FakeBao.new
    @bao.on("POST", AUTH_URL_PATH, body: { "data" => { "auth_url" => "http://idp.test/?state=s1&x=y" } })
    @bao.on("GET", CALLBACK_PATH, body: { "auth" => { "client_token" => "tok" } })
  end

  def teardown
    @bao.stop
  end

  def login(opener, **opts)
    client = EnvPact::OpenBao::Client.new(addr: @bao.addr)
    EnvPact::OIDCLogin.new(client: client, mount: "oidc", role: "leitura", port: 0, opener: opener, **opts)
  end

  def redirect_port
    JSON.parse(@bao.requests_for("POST", AUTH_URL_PATH).first.body)["redirect_uri"][%r{localhost:(\d+)/oidc/callback\z}, 1]
  end

  # Browser stand-in: hits the loopback URL from a thread.
  def browser(path_and_query)
    lambda do |_url|
      Thread.new do
        sleep 0.05
        Net::HTTP.get_response(URI("http://localhost:#{redirect_port}#{path_and_query}"))
      end
    end
  end

  def test_oidc_flow_returns_token
    assert_equal "tok", login(browser("/oidc/callback?code=c1&state=s1")).token

    body = JSON.parse(@bao.requests_for("POST", AUTH_URL_PATH).first.body)
    assert_equal "leitura", body["role"]
    assert_match(%r{\Ahttp://localhost:\d+/oidc/callback\z}, body["redirect_uri"])
    nonce = body["client_nonce"]
    assert_operator nonce.length, :>=, 16

    cb = @bao.requests_for("GET", CALLBACK_PATH)
    assert_equal 1, cb.size
    q = URI.decode_www_form(cb.first.query).to_h
    assert_equal({ "code" => "c1", "state" => "s1", "client_nonce" => nonce }, q)
    assert_nil cb.first.headers["x-vault-token"]
  end

  def test_opener_receives_auth_url
    seen = nil
    opener = lambda do |url|
      seen = url
      browser("/oidc/callback?code=c1&state=s1").call(url)
    end
    login(opener).token
    assert_equal "http://idp.test/?state=s1&x=y", seen
  end

  def test_browser_gets_plain_text_page
    resp = nil
    opener = lambda do |_url|
      Thread.new { sleep 0.05; resp = Net::HTTP.get_response(URI("http://localhost:#{redirect_port}/oidc/callback?code=c1&state=s1")) }
    end
    login(opener).token
    sleep 0.2
    assert_equal "envpact: login ok, you can close this tab", resp.body.strip
  end

  def test_oidc_state_mismatch_errors
    err = assert_raises(EnvPact::Error) { login(browser("/oidc/callback?code=c1&state=zzz")).token }
    assert_match(/state/, err.message)
    assert_empty @bao.requests_for("GET", CALLBACK_PATH)
  end

  def test_unrelated_request_is_ignored
    opener = lambda do |_url|
      Thread.new do
        sleep 0.05
        Net::HTTP.get_response(URI("http://localhost:#{redirect_port}/favicon.ico"))
        Net::HTTP.get_response(URI("http://localhost:#{redirect_port}/oidc/callback?code=c1&state=s1"))
      end
    end
    assert_equal "tok", login(opener).token
  end

  def test_oidc_timeout
    err = assert_raises(EnvPact::Error) { login(->(_url) {}, wait: 0.3).token }
    assert_equal "login timed out", err.message
  end

  def test_missing_auth_url_is_error
    @bao.on("POST", AUTH_URL_PATH, body: { "data" => {} })
    assert_raises(EnvPact::Error) { login(->(_url) {}, wait: 0.3).token }
  end

  def test_missing_client_token_is_error
    @bao.on("GET", CALLBACK_PATH, body: { "auth" => nil })
    err = assert_raises(EnvPact::Error) { login(browser("/oidc/callback?code=c1&state=s1")).token }
    refute_match(/\btok\b/, err.message)
  end

  def test_opener_failure_does_not_abort
    opener = lambda do |_url|
      browser("/oidc/callback?code=c1&state=s1").call(nil)
      raise "no browser here"
    end
    assert_equal "tok", login(opener).token
  end

  def test_port_in_use_is_error
    srv = TCPServer.new("127.0.0.1", 0)
    port = srv.addr[1]
    client = EnvPact::OpenBao::Client.new(addr: @bao.addr)
    err = assert_raises(EnvPact::Error) do
      EnvPact::OIDCLogin.new(client: client, mount: "oidc", role: nil, port: port, opener: ->(_u) {}).token
    end
    assert_includes err.message, port.to_s
  ensure
    srv.close if srv
  end
end
