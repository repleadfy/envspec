require_relative "test_helper"
require_relative "support/fake_bao"

class TestOpenBao < Minitest::Test
  TOKEN = "t0k".freeze

  def setup
    @bao = FakeBao.new
  end

  def teardown
    @bao.stop
  end

  def client(**opts)
    EnvPact::OpenBao::Client.new(addr: @bao.addr, token: TOKEN, **opts)
  end

  def kv(data)
    { "data" => { "data" => data, "metadata" => { "version" => 1 } } }
  end

  def test_read_returns_data
    @bao.on("GET", "/v1/secret/data/team/app", body: kv("A" => "1"))
    assert_equal({ "A" => "1" }, client.read("secret", "team/app"))
    assert_equal TOKEN, @bao.requests.last.headers["x-vault-token"]
  end

  def test_read_404_is_nil
    assert_nil client.read("secret", "nope/x")
  end

  def test_write_patches_then_creates_on_404
    @bao.on("PATCH", "/v1/secret/data/team/app", status: 404, body: { "errors" => [] })
    @bao.on("POST", "/v1/secret/data/team/app", body: kv({}))
    client.write("secret", "team/app", "A" => "1")
    patch = @bao.requests_for("PATCH").first
    post  = @bao.requests_for("POST").first
    assert_equal "application/merge-patch+json", patch.headers["content-type"]
    assert_equal({ "data" => { "A" => "1" } }, JSON.parse(patch.body))
    assert_equal patch.body, post.body
  end

  def test_write_patch_ok_makes_no_post
    @bao.on("PATCH", "/v1/secret/data/team/app", body: kv({}))
    client.write("secret", "team/app", "A" => "1")
    assert_empty @bao.requests_for("POST")
  end

  def test_denied_message_has_no_token_or_body
    @bao.on("GET", "/v1/secret/data/team/app", status: 403, body: { "errors" => ["permission denied"] })
    err = assert_raises(EnvPact::OpenBao::Denied) { client.read("secret", "team/app") }
    assert_equal "token rejected for secret/team/app (expired, revoked or not allowed); run envpact login --read", err.message
    refute_includes err.message, TOKEN
    refute_includes err.message, "permission denied"
  end

  def test_denied_message_names_write_role
    @bao.on("PATCH", "/v1/secret/data/a", status: 403)
    err = assert_raises(EnvPact::OpenBao::Denied) { client(role: :write).write("secret", "a", "A" => "1") }
    assert_match(/run envpact login --write\z/, err.message)
  end

  def test_denied_is_an_error
    assert EnvPact::OpenBao::Denied < EnvPact::OpenBao::Error
    assert EnvPact::OpenBao::Error < EnvPact::Error
  end

  def test_inspect_redacts_token
    c = client
    assert_equal "#<EnvPact::OpenBao::Client addr=#{@bao.addr} token=[redacted]>", c.inspect
    refute_includes c.inspect, TOKEN
  end

  def test_non_string_value_errors_without_value
    @bao.on("GET", "/v1/secret/data/a", body: kv("A" => 12_345))
    err = assert_raises(EnvPact::OpenBao::Error) { client.read("secret", "a") }
    assert_includes err.message, "non-string value for key 'A' at secret/a"
    refute_includes err.message, "12345"
  end

  def test_timeout_is_error
    @bao.on("GET", "/v1/secret/data/a", hang: true)
    err = assert_raises(EnvPact::OpenBao::Error) { client(timeout: 0.2).read("secret", "a") }
    assert_includes err.message, @bao.addr
    refute_includes err.message, TOKEN
  end

  def test_connection_refused_is_error
    port = @bao.port
    @bao.stop
    err = assert_raises(EnvPact::OpenBao::Error) do
      EnvPact::OpenBao::Client.new(addr: "http://127.0.0.1:#{port}", token: TOKEN, timeout: 1).read("secret", "a")
    end
    assert_includes err.message, "127.0.0.1:#{port}"
  end

  def test_server_error_has_status_but_no_body
    @bao.on("GET", "/v1/secret/data/a", status: 503, body: { "errors" => ["sealed s3cr3t"] })
    err = assert_raises(EnvPact::OpenBao::Error) { client.read("secret", "a") }
    assert_includes err.message, "503"
    refute_includes err.message, "s3cr3t"
  end

  def test_no_addr_is_error
    err = assert_raises(EnvPact::OpenBao::Error) { EnvPact::OpenBao::Client.new(addr: nil, token: TOKEN) }
    assert_equal "no OpenBao address: set addr= in [source] or $BAO_ADDR", err.message
    assert_raises(EnvPact::OpenBao::Error) { EnvPact::OpenBao::Client.new(addr: "", token: TOKEN) }
  end

  def test_token_with_newline_is_refused_without_echo
    err = assert_raises(EnvPact::OpenBao::Error) { EnvPact::OpenBao::Client.new(addr: @bao.addr, token: "a\nb") }
    refute_includes err.message, "a\nb"
  end

  def test_unsafe_path_is_refused
    assert_raises(EnvPact::OpenBao::Error) { client.read("secret", "../sys/x") }
    assert_empty @bao.requests
  end

  def test_lookup_self
    @bao.on("GET", "/v1/auth/token/lookup-self", body: { "data" => {
      "ttl" => 100, "expire_time" => "2026-11-23T03:00:00Z", "display_name" => "oidc-tom", "policies" => %w[default x], "id" => TOKEN
    } })
    info = client.lookup_self
    assert_equal({ "ttl" => 100, "expire_time" => "2026-11-23T03:00:00Z", "display_name" => "oidc-tom", "policies" => %w[default x] }, info)
  end

  def test_renew_self_posts
    @bao.on("POST", "/v1/auth/token/renew-self", body: { "auth" => {} })
    client.renew_self
    assert_equal 1, @bao.requests_for("POST", "/v1/auth/token/renew-self").size
  end

  def test_renew_self_swallows_non_renewable
    @bao.on("POST", "/v1/auth/token/renew-self", status: 400, body: { "errors" => ["lease is not renewable"] })
    assert_nil client.renew_self
  end

  def test_renew_self_403_is_denied
    @bao.on("POST", "/v1/auth/token/renew-self", status: 403)
    assert_raises(EnvPact::OpenBao::Denied) { client.renew_self }
  end

  def test_post_unauthenticated_sends_no_token
    @bao.on("POST", "/v1/auth/oidc/oidc/auth_url", body: { "data" => { "auth_url" => "http://idp.test/" } })
    out = EnvPact::OpenBao::Client.new(addr: @bao.addr).post_unauthenticated("auth/oidc/oidc/auth_url", "role" => "r")
    assert_equal "http://idp.test/", out["data"]["auth_url"]
    req = @bao.requests.last
    assert_nil req.headers["x-vault-token"]
    assert_equal({ "role" => "r" }, JSON.parse(req.body))
  end

  def test_get_unauthenticated_sends_query
    @bao.on("GET", "/v1/auth/oidc/oidc/callback", body: { "auth" => { "client_token" => "x" } })
    out = EnvPact::OpenBao::Client.new(addr: @bao.addr).get_unauthenticated("auth/oidc/oidc/callback", "state" => "s 1", "code" => "c")
    assert_equal "x", out["auth"]["client_token"]
    assert_equal({ "state" => "s 1", "code" => "c" }, URI.decode_www_form(@bao.requests.last.query).to_h)
    assert_nil @bao.requests.last.headers["x-vault-token"]
  end
end
