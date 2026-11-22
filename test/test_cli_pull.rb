require_relative "test_helper"
require_relative "support/fake_bao"
require_relative "support/tmp_home"
require "tmpdir"
require "fileutils"
require "open3"

class TestCliPull < Minitest::Test
  include TmpHome

  SPEC = <<~SPEC.freeze
    PORT: int = 3000
    [source]
    openbao path=team/app/{env}
    [secrets]
    DB_PASS
  SPEC
  VALUE = "s3cr3t-v4lue".freeze

  def setup
    super
    @bao = FakeBao.new
    @bao.on("GET", "/v1/secret/data/team/app/development", body: { "data" => { "data" => { "DB_PASS" => VALUE } } })
    @bao.on("POST", "/v1/auth/token/renew-self", body: { "auth" => {} })
    @work = Dir.mktmpdir("epw")
    @sockdir = Dir.mktmpdir("eps")
    @saved = { "ENVPACT_AGENT_SOCK" => ENV["ENVPACT_AGENT_SOCK"], "BAO_ADDR" => ENV["BAO_ADDR"], "ENVPACT_SPEC" => ENV["ENVPACT_SPEC"] }
    ENV["ENVPACT_AGENT_SOCK"] = File.join(@sockdir, "a.sock")
    ENV["BAO_ADDR"] = nil
    ENV["ENVPACT_SPEC"] = nil
    EnvPact::Agent.start(token: "t0k", addr: @bao.addr, until_time: Time.now + 60)
    File.write(File.join(@work, "env.spec"), SPEC)
  end

  def teardown
    EnvPact::Agent.request("lock")
    sleep 0.1
    @saved.each { |k, v| ENV[k] = v }
    @bao.stop
    FileUtils.remove_entry(@work)
    FileUtils.remove_entry(@sockdir)
    super
  end

  def run_cli(*argv)
    code = nil
    out = err = nil
    Dir.chdir(@work) { out, err = capture_io { code = EnvPact::CLI.run(argv) } }
    [code, out, err]
  end

  def target(name = ".env.development.local")
    File.join(@work, name)
  end

  def test_pull_writes_0600_and_no_value_on_stdout
    code, out, err = run_cli("pull", "--env=development")
    assert_equal 0, code, err
    assert_equal 0o600, File.stat(target).mode & 0o777
    assert_equal({ "DB_PASS" => VALUE }, EnvPact::Dotenv.parse(File.read(target)))
    assert_match(/\A# written by envpact pull from openbao:secret\/team\/app\/development at \d{4}-\d\d-\d\dT[\d:]+Z?.*; do not edit\n/, File.read(target))
    refute_includes out, VALUE
    refute_includes err, VALUE
    assert_includes out, "✓ pulled 1 secrets → .env.development.local (0600)"
    assert_equal "t0k", @bao.requests_for("GET", "/v1/secret/data/team/app/development").first.headers["x-vault-token"]
  end

  def test_pull_custom_out
    code, = run_cli("pull", "--env=development", "--out=my.env")
    assert_equal 0, code
    assert File.exist?(target("my.env"))
    refute File.exist?(target)
  end

  def test_pull_renews_the_token
    run_cli("pull", "--env=development")
    assert_equal 1, @bao.requests_for("POST", "/v1/auth/token/renew-self").size
  end

  def test_pull_refuses_when_check_fails
    @bao.on("GET", "/v1/secret/data/team/app/development", body: { "data" => { "data" => {} } })
    code, _, err = run_cli("pull", "--env=development")
    assert_equal 1, code
    assert_includes err, "missing required env var 'DB_PASS'"
    refute File.exist?(target)
  end

  def test_pull_failed_check_keeps_existing_file
    File.write(target, "DB_PASS=\"old\"\n")
    @bao.on("GET", "/v1/secret/data/team/app/development", body: { "data" => { "data" => {} } })
    code, = run_cli("pull", "--env=development")
    assert_equal 1, code
    assert_equal "DB_PASS=\"old\"\n", File.read(target)
  end

  def test_pull_ignores_its_own_target_when_merging
    File.write(target, "DB_PASS=\"stale\"\n")
    @bao.on("GET", "/v1/secret/data/team/app/development", body: { "data" => { "data" => {} } })
    code, = run_cli("pull", "--env=development")
    assert_equal 1, code
  end

  def test_pull_overwrites_stale_target_with_fresh_values
    File.write(target, "DB_PASS=\"stale\"\nOLD=\"x\"\n")
    code, = run_cli("pull", "--env=development")
    assert_equal 0, code
    assert_equal({ "DB_PASS" => VALUE }, EnvPact::Dotenv.parse(File.read(target)))
  end

  def test_pull_checks_other_dotenv_files_for_configmap_keys
    File.write(File.join(@work, "env.spec"), "NEEDED\n" + SPEC)
    code, _, err = run_cli("pull", "--env=development")
    assert_equal 1, code
    assert_includes err, "missing required env var 'NEEDED'"
    File.write(File.join(@work, ".env"), "NEEDED=1\n")
    code, = run_cli("pull", "--env=development")
    assert_equal 0, code
  end

  def test_pull_warns_about_extra_source_keys_without_values
    @bao.on("GET", "/v1/secret/data/team/app/development", body: { "data" => { "data" => { "DB_PASS" => VALUE, "JUNK" => "j-v4l" } } })
    code, out, err = run_cli("pull", "--env=development")
    assert_equal 0, code
    assert_includes err, "JUNK"
    refute_includes out + err, "j-v4l"
    refute_includes File.read(target), "JUNK"
  end

  def test_pull_warns_not_gitignored
    skip "git not available" unless system("git", "--version", out: File::NULL, err: File::NULL)
    system("git", "init", "-q", @work, out: File::NULL, err: File::NULL)
    code, _, err = run_cli("pull", "--env=development")
    assert_equal 0, code
    assert_includes err, "! .env.development.local is not git-ignored"

    File.write(File.join(@work, ".gitignore"), ".env*.local\n")
    _, _, err = run_cli("pull", "--env=development")
    refute_includes err, "not git-ignored"
  end

  def test_pull_no_warning_outside_git
    skip "inside a git repo" if system("git", "-C", @work, "rev-parse", out: File::NULL, err: File::NULL)
    _, _, err = run_cli("pull", "--env=development")
    refute_includes err, "git-ignored"
  end

  def test_pull_refuses_symlink_target
    File.write(target("real"), "keep")
    File.symlink(target("real"), target)
    code, _, err = run_cli("pull", "--env=development")
    assert_equal 1, code
    assert_includes err, "refusing to write through symlink"
    assert_equal "keep", File.read(target("real"))
  end

  def test_pull_without_source_for_env
    File.write(File.join(@work, "env.spec"), "[secrets]\nDB_PASS\n")
    code, _, err = run_cli("pull", "--env=development")
    assert_equal 1, code
    assert_includes err, "no [source] for env 'development' in env.spec"
  end

  def test_pull_requires_env
    code, = run_cli("pull")
    assert_equal 2, code
  end

  def test_pull_refuses_token_for_another_address
    EnvPact::Agent.request("lock")
    sleep 0.2
    EnvPact::Agent.start(token: "t0k", addr: "http://somewhere-else.test:8200", until_time: Time.now + 60)
    ENV["BAO_ADDR"] = @bao.addr
    code, _, err = run_cli("pull", "--env=development")
    assert_equal 1, code
    assert_includes err, "different address"
    assert_empty @bao.requests_for("GET")
    refute_includes err, "t0k"
  end

  def test_pull_source_addr_overrides_nothing_when_equal
    File.write(File.join(@work, "env.spec"), "[source]\nopenbao path=team/app/{env} addr=#{@bao.addr}/\n[secrets]\nDB_PASS\n")
    code, = run_cli("pull", "--env=development")
    assert_equal 0, code
  end

  def test_pull_denied_token_message
    @bao.on("GET", "/v1/secret/data/team/app/development", status: 403, body: { "errors" => ["permission denied"] })
    code, _, err = run_cli("pull", "--env=development")
    assert_equal 1, code
    assert_includes err, "token rejected for secret/team/app/development (expired, revoked or not allowed); run envpact login --read"
    refute_includes err, "t0k"
  end

  def test_check_source_overlays_values
    File.write(File.join(@work, ".env"), "PORT=1\n")
    code, out, err = run_cli("check", "--env=development", "--source")
    assert_equal 0, code, err
    refute_includes out + err, VALUE
    refute File.exist?(target)
  end

  def test_check_source_reports_missing_secret
    @bao.on("GET", "/v1/secret/data/team/app/development", body: { "data" => { "data" => {} } })
    code, _, err = run_cli("check", "--env=development", "--source")
    assert_equal 1, code
    assert_includes err, "missing required env var 'DB_PASS'"
  end

  def test_check_source_rejects_show_values
    code, _, err = run_cli("check", "--env=development", "--source", "--show-values")
    assert_equal 2, code
    assert_includes err, "--show-values"
    assert_empty @bao.requests
  end

  def test_check_source_with_from_env
    code, = run_cli("check", "--env=development", "--source", "--from-env")
    assert_equal 0, code
  end

  def test_check_source_never_prints_secret_value_even_when_invalid
    File.write(File.join(@work, "env.spec"), "[source]\nopenbao path=team/app/{env}\n[secrets]\nDB_PASS: int\n")
    code, out, err = run_cli("check", "--env=development", "--source")
    assert_equal 1, code
    refute_includes out + err, VALUE
  end
end
