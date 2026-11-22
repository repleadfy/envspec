require_relative "test_helper"
require_relative "support/fake_bao"
require_relative "support/tmp_home"
require "open3"
require "tmpdir"
require "fileutils"

# run replaces the process, so these run envpact in a subprocess.
class TestRun < Minitest::Test
  include TmpHome

  ROOT = File.expand_path("..", __dir__)
  SPEC = <<~SPEC.freeze
    PORT: int = 3000
    [source]
    openbao path=team/app/{env}
    [secrets]
    DB_PASS
  SPEC
  PRINT = ->(code) { ["ruby", "-e", code] }

  def setup
    super
    @bao = FakeBao.new
    @bao.on("GET", "/v1/secret/data/team/app/dev", body: { "data" => { "data" => { "DB_PASS" => "s3cr3t" } } })
    @bao.on("POST", "/v1/auth/token/renew-self", body: { "auth" => {} })
    @work = Dir.mktmpdir("epr")
    @sockdir = Dir.mktmpdir("epq")
    @sock = File.join(@sockdir, "a.sock")
    @old_sock = ENV["ENVPACT_AGENT_SOCK"]
    ENV["ENVPACT_AGENT_SOCK"] = @sock
    EnvPact::Agent.start(token: "t0k-run", addr: @bao.addr, until_time: Time.now + 60)
    File.write(File.join(@work, "env.spec"), SPEC)
  end

  def teardown
    EnvPact::Agent.request("lock")
    sleep 0.1
    ENV["ENVPACT_AGENT_SOCK"] = @old_sock
    @bao.stop
    FileUtils.remove_entry(@work)
    FileUtils.remove_entry(@sockdir)
    super
  end

  def envpact(env, *args)
    cmd = ["ruby", "-I#{ROOT}/lib", "#{ROOT}/exe/envpact", "run", "--spec=#{@work}/env.spec", *args]
    clean = { "DB_PASS" => nil, "PORT" => nil, "ENVPACT_ENV" => nil, "ENVPACT_SPEC" => nil, "BAO_TOKEN" => nil,
              "VAULT_TOKEN" => nil, "BAO_ADDR" => nil, "HOME" => @home, "ENVPACT_AGENT_SOCK" => @sock }
    out, err, status = Open3.capture3(clean.merge(env), *cmd)
    [status.exitstatus, out, err]
  end

  def test_run_injects_secrets
    code, out, err = envpact({}, "--env=dev", "--", *PRINT.call('print ENV["DB_PASS"]'))
    assert_equal 0, code, err
    assert_equal "s3cr3t", out
  end

  def test_run_fills_defaults
    code, out, = envpact({}, "--env=dev", "--", *PRINT.call('print ENV["PORT"]'))
    assert_equal 0, code
    assert_equal "3000", out
  end

  def test_run_source_overrides_env
    code, out, = envpact({ "DB_PASS" => "from-env" }, "--env=dev", "--", *PRINT.call('print ENV["DB_PASS"]'))
    assert_equal 0, code
    assert_equal "s3cr3t", out
  end

  def test_run_child_env_has_no_token
    code, out, err = envpact({ "BAO_TOKEN" => "inherited-bao", "VAULT_TOKEN" => "inherited-vault" }, "--env=dev", "--",
                             *PRINT.call('print ENV.keys.grep(/\A(BAO|VAULT)_TOKEN\z/).inspect, "|", ENV.values.grep(/t0k-run|inherited/).inspect'))
    assert_equal 0, code, err
    assert_equal "[]|[]", out
  end

  def test_run_env_from_envpact_env
    code, out, = envpact({ "ENVPACT_ENV" => "dev" }, "--", *PRINT.call('print ENV["DB_PASS"]'))
    assert_equal 0, code
    assert_equal "s3cr3t", out
  end

  def test_run_refuses_on_missing_secret
    @bao.on("GET", "/v1/secret/data/team/app/dev", body: { "data" => { "data" => {} } })
    code, out, err = envpact({}, "--env=dev", "--", *PRINT.call('print "RAN"'))
    assert_equal 1, code
    assert_equal "", out
    assert_includes err, "missing required env var 'DB_PASS'"
  end

  def test_run_keeps_process_env_for_keys_absent_from_source
    # The source overrides the env where it has a key; elsewhere the env stands.
    @bao.on("GET", "/v1/secret/data/team/app/dev", body: { "data" => { "data" => {} } })
    code, = envpact({ "DB_PASS" => "from-env" }, "--env=dev", "--", *PRINT.call('print "RAN"'))
    assert_equal 0, code
  end

  def test_run_invalid_secret_never_printed
    File.write(File.join(@work, "env.spec"), "[source]\nopenbao path=team/app/{env}\n[secrets]\nDB_PASS: int\n")
    code, out, err = envpact({}, "--env=dev", "--", *PRINT.call('print "RAN"'))
    assert_equal 1, code
    assert_equal "", out
    refute_includes err, "s3cr3t"
  end

  def test_run_without_source_fails
    File.write(File.join(@work, "env.spec"), "[secrets]\nDB_PASS\n")
    code, out, err = envpact({}, "--env=dev", "--", *PRINT.call('print "RAN"'))
    assert_equal 1, code
    assert_equal "", out
    assert_includes err, "no [source] for env 'dev' in env.spec"
  end

  def test_run_command_not_found
    code, _, err = envpact({}, "--env=dev", "--", "definitely-not-a-command-xyz")
    assert_equal 127, code
    assert_includes err, "command not found: definitely-not-a-command-xyz"
  end

  def test_run_value_with_nul_byte_is_a_clean_error
    @bao.on("GET", "/v1/secret/data/team/app/dev", body: { "data" => { "data" => { "DB_PASS" => "a\u0000b" } } })
    code, out, err = envpact({}, "--env=dev", "--", *PRINT.call('print "RAN"'))
    assert_equal 1, code
    assert_equal "", out
    assert_includes err, "DB_PASS"
    refute_match(/\.rb:\d+/, err)
  end

  def test_run_requires_env_and_command
    code, = envpact({}, "--", "true")
    assert_equal 2, code
    code, = envpact({}, "--env=dev")
    assert_equal 2, code
  end

  def test_run_exit_status_is_the_commands
    code, = envpact({}, "--env=dev", "--", *PRINT.call("exit 7"))
    assert_equal 7, code
  end

  def test_run_never_writes_files
    envpact({}, "--env=dev", "--", "true")
    assert_equal ["env.spec"], Dir.children(@work)
  end
end
