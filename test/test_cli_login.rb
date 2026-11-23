require_relative "test_helper"
require_relative "support/fake_bao"
require_relative "support/tmp_home"
require_relative "support/pty_run"

class TestCliLogin < Minitest::Test
  include TmpHome

  ROOT = File.expand_path("..", __dir__)
  PASS = "twelve chars ok".freeze

  def setup
    super
    @bao = FakeBao.new
    @bao.on("GET", "/v1/auth/token/lookup-self", body: { "data" => {
      "ttl" => 3600, "expire_time" => "2026-11-23T03:00:00Z", "display_name" => "x", "policies" => ["default"]
    } })
  end

  def teardown
    @bao.stop
    super
  end

  def envpact(args, stdin: nil, answers: [], env: {})
    base = "exec ruby -I#{ROOT}/lib #{ROOT}/exe/envpact #{args}"
    script = stdin ? "printf '%s\\n' #{stdin} | #{base}" : base
    PtyRun.run(["sh", "-c", script],
               env: { "HOME" => @home, "BAO_ADDR" => @bao.addr, "BAO_TOKEN" => nil, "ENVPACT_SPEC" => nil }.merge(env),
               answers: answers)
  end

  def test_cli_login_token_stdin_writes_keyfile
    out, code = envpact("login --read --token-stdin", stdin: "t0k-secret-value",
                        answers: [[/passphrase.*: \z/i, PASS], [/again|repeat|confirm/i, PASS]])
    assert_equal 0, code, out
    path = File.join(@home, ".ob_read")
    assert File.exist?(path)
    assert_equal 0o600, File.stat(path).mode & 0o777
    refute_includes out, "t0k-secret-value"
    refute_includes out, PASS
    assert_match(/logged in \(read, role default, expires 2026-11-23 \d\d:\d\d\) → ~\/\.ob_read/, out)
    assert_equal "t0k-secret-value", EnvPact::Keyfile.read(:read, passphrase: PASS)[:token]
    assert_equal "t0k-secret-value", @bao.requests_for("GET", "/v1/auth/token/lookup-self").first.headers["x-vault-token"]
  end

  def test_cli_login_records_server_role_when_no_role_given
    @bao.on("GET", "/v1/auth/token/lookup-self", body: { "data" => {
      "ttl" => 3600, "expire_time" => "2026-11-23T03:00:00Z", "display_name" => "oidc-tom", "policies" => ["default"],
      "meta" => { "role" => "leitura" }
    } })
    out, code = envpact("login --read --token-stdin", stdin: "t0k-secret-value",
                        answers: [[/passphrase.*: \z/i, PASS], [/again|repeat|confirm/i, PASS]])
    assert_equal 0, code, out
    assert_match(/logged in \(read, role leitura,/, out)
    assert_equal "leitura", EnvPact::Keyfile.meta(:read)[:role]
  end

  def test_cli_login_write_with_role_and_token_stdin
    out, code = envpact("login --write --role=escrita --token-stdin", stdin: "w-tok",
                        answers: [[/passphrase.*: \z/i, PASS], [/again|repeat|confirm/i, PASS]])
    assert_equal 0, code, out
    assert_equal "escrita", EnvPact::Keyfile.meta(:write)[:role]
    assert_equal @bao.addr, EnvPact::Keyfile.meta(:write)[:addr]
  end

  def test_cli_login_passphrase_mismatch
    out, code = envpact("login --read --token-stdin", stdin: "t0k-secret-value",
                        answers: [[/passphrase.*: \z/i, PASS], [/again|repeat|confirm/i, PASS + "x"]])
    assert_equal 1, code, out
    assert_match(/do not match/, out)
    refute File.exist?(File.join(@home, ".ob_read"))
  end

  def test_cli_login_short_passphrase
    out, code = envpact("login --read --token-stdin", stdin: "t0k-secret-value",
                        answers: [[/passphrase.*: \z/i, "short"], [/again|repeat|confirm/i, "short"]])
    assert_equal 1, code, out
    assert_match(/at least 12/, out)
    refute File.exist?(File.join(@home, ".ob_read"))
  end

  def test_cli_login_rejected_token_writes_nothing
    @bao.on("GET", "/v1/auth/token/lookup-self", status: 403)
    out, code = envpact("login --read --token-stdin", stdin: "t0k-secret-value")
    assert_equal 1, code, out
    refute_includes out, "t0k-secret-value"
    refute File.exist?(File.join(@home, ".ob_read"))
  end

  def test_cli_login_write_needs_role
    out, code = envpact("login --write")
    assert_equal 2, code, out
    assert_includes out, "--write needs --role=NAME"
  end

  def test_cli_login_needs_read_or_write
    _, code = envpact("login")
    assert_equal 2, code
  end

  def test_cli_login_read_and_write_are_exclusive
    _, code = envpact("login --read --write --role=x")
    assert_equal 2, code
  end

  def test_cli_login_without_address_is_error
    out, code = envpact("login --read --token-stdin", stdin: "t0k", env: { "BAO_ADDR" => nil })
    assert_equal 1, code, out
    assert_includes out, "no OpenBao address"
  end

  def test_cli_login_addr_from_spec_source
    Dir.mktmpdir do |d|
      File.write(File.join(d, "env.spec"), "[source]\nopenbao path=team/x/{env} addr=#{@bao.addr}\n")
      out, code = envpact("login --read --token-stdin --spec=#{d}/env.spec", stdin: "t0k-secret-value", env: { "BAO_ADDR" => nil },
                          answers: [[/passphrase.*: \z/i, PASS], [/again|repeat|confirm/i, PASS]])
      assert_equal 0, code, out
    end
  end

  def test_cli_login_bad_port_is_usage_error
    _, code = envpact("login --read --port=99999")
    assert_equal 2, code
  end
end
