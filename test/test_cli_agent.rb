require_relative "test_helper"
require_relative "support/fake_bao"
require_relative "support/tmp_home"
require_relative "support/pty_run"
require "tmpdir"
require "fileutils"

class TestCliAgent < Minitest::Test
  include TmpHome

  ROOT = File.expand_path("..", __dir__)
  PASS = "correct horse battery".freeze
  TOKEN = "t0k-agent-cli".freeze

  def setup
    super
    @bao = FakeBao.new
    @bao.on("POST", "/v1/auth/token/renew-self", body: { "auth" => {} })
    @expire = (Time.now.utc + 3 * 3600).strftime("%Y-%m-%dT%H:%M:%SZ")
    @bao.on("GET", "/v1/auth/token/lookup-self", body: { "data" => {
      "ttl" => 10_800, "expire_time" => @expire, "display_name" => "x", "policies" => ["default"]
    } })
    @sockdir = Dir.mktmpdir("epcli")
    @sock = File.join(@sockdir, "a.sock")
    @old_sock = ENV["ENVPACT_AGENT_SOCK"]
    ENV["ENVPACT_AGENT_SOCK"] = @sock
    EnvPact::Keyfile.write(:read, token: TOKEN, addr: @bao.addr, role: "leitura",
                                  expire_time: @expire, passphrase: PASS, iterations: 1_000)
  end

  def teardown
    EnvPact::Agent.request("lock")
    sleep 0.1
    ENV["ENVPACT_AGENT_SOCK"] = @old_sock
    @bao.stop
    FileUtils.remove_entry(@sockdir)
    super
  end

  def envpact(args, answers: [])
    PtyRun.run(["sh", "-c", "exec ruby -I#{ROOT}/lib #{ROOT}/exe/envpact #{args}"],
               env: { "HOME" => @home, "ENVPACT_AGENT_SOCK" => @sock, "BAO_ADDR" => nil }, answers: answers)
  end

  def test_unlock_status_lock_cycle
    out, code = envpact("unlock --for=2h", answers: [[/passphrase.*: \z/i, PASS]])
    assert_equal 0, code, out
    assert_match(/unlocked until/, out)
    refute_includes out, TOKEN
    assert_equal TOKEN, EnvPact::Agent.request("token")["token"]
    assert_equal 1, @bao.requests_for("POST", "/v1/auth/token/renew-self").size

    out, code = envpact("status")
    assert_equal 0, code, out
    assert_match(/agent: unlocked until/, out)
    assert_match(/\.ob_read: role leitura/, out)
    assert_match(/\.ob_write: not logged in/, out)
    refute_includes out, TOKEN
    refute_includes out, PASS

    out, code = envpact("lock")
    assert_equal 0, code, out
    sleep 0.3
    assert_nil EnvPact::Agent.request("token")
    out, = envpact("status")
    assert_match(/agent: locked/, out)
  end

  def test_unlock_por_alias
    out, code = envpact("unlock --por=1h", answers: [[/passphrase.*: \z/i, PASS]])
    assert_equal 0, code, out
    assert_equal TOKEN, EnvPact::Agent.request("token")["token"]
  end

  def test_unlock_is_capped_by_token_expiry
    out, code = envpact("unlock --for=8h", answers: [[/passphrase.*: \z/i, PASS]])
    assert_equal 0, code, out
    untill = Time.iso8601(EnvPact::Agent.request("status")["until"])
    assert_operator untill, :<=, Time.iso8601(@expire) + 1
  end

  def test_unlock_rejects_bad_duration
    ["2d", "abc", "0s", "-1h", "2"].each do |bad|
      out, code = envpact("unlock --for=#{bad}")
      assert_equal 2, code, "#{bad}: #{out}"
    end
    assert_nil EnvPact::Agent.request("token")
  end

  def test_unlock_wrong_passphrase_starts_no_agent
    out, code = envpact("unlock", answers: [[/passphrase.*: \z/i, "wrong wrong wrong"]])
    assert_equal 1, code, out
    assert_match(/wrong passphrase/, out)
    assert_nil EnvPact::Agent.request("token")
  end

  def test_unlock_rejected_token_starts_no_agent
    @bao.on("POST", "/v1/auth/token/renew-self", status: 403)
    out, code = envpact("unlock", answers: [[/passphrase.*: \z/i, PASS]])
    assert_equal 1, code, out
    assert_match(/envpact login --read/, out)
    assert_nil EnvPact::Agent.request("token")
  end

  def test_lock_without_agent_is_ok
    out, code = envpact("lock")
    assert_equal 0, code, out
  end

  def test_unlock_without_keyfile
    FileUtils.rm_f(File.join(@home, ".ob_read"))
    out, code = envpact("unlock")
    assert_equal 1, code, out
    assert_match(/no ~\/\.ob_read/, out)
  end
end
