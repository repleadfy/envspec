require_relative "test_helper"
require_relative "support/fake_bao"
require_relative "support/tmp_home"
require_relative "support/pty_run"
require "open3"
require "tmpdir"
require "fileutils"
require "json"

class TestCliWrite < Minitest::Test
  include TmpHome

  ROOT = File.expand_path("..", __dir__)
  PASS = "correct horse battery".freeze
  WRITE_TOKEN = "w-t0k-secret".freeze
  VALUE = "s3cr3t-pushed".freeze
  PATH = "/v1/secret/data/team/app/production".freeze
  SPEC = <<~SPEC.freeze
    PORT: int = 3000
    [source]
    openbao path=team/app/{env}
    [secrets]
    DB_PASS
    OTHER
    DB_PORT?: int
  SPEC

  def setup
    super
    @bao = FakeBao.new
    @bao.on("PATCH", PATH, body: { "data" => {} })
    @work = Dir.mktmpdir("epx")
    @sockdir = Dir.mktmpdir("epy")
    @sock = File.join(@sockdir, "a.sock")
    @old_sock = ENV["ENVPACT_AGENT_SOCK"]
    ENV["ENVPACT_AGENT_SOCK"] = @sock
    File.write(File.join(@work, "env.spec"), SPEC)
    write_keyfile
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

  def write_keyfile(token: WRITE_TOKEN)
    EnvPact::Keyfile.write(:write, token: token, addr: @bao.addr, role: "escrita", expire_time: nil,
                                   passphrase: PASS, iterations: 1_000)
  end

  def base_env
    { "HOME" => @home, "ENVPACT_AGENT_SOCK" => @sock, "BAO_ADDR" => nil, "BAO_TOKEN" => nil, "ENVPACT_SPEC" => nil }
  end

  def cli(args)
    "ruby -I#{ROOT}/lib #{ROOT}/exe/envpact #{args} --spec=#{@work}/env.spec"
  end

  # Runs under a pty (so /dev/tty exists). stdin: is piped into the command.
  def envpact(args, stdin: nil, answers: [])
    cmd = stdin ? "printf '%s\\n' #{stdin} | exec #{cli(args)}" : "exec #{cli(args)}"
    PtyRun.run(["sh", "-c", cmd], env: base_env, answers: answers)
  end

  CONFIRM_1 = [/Write 1 key\? \[y\/N\] \z/, "y"].freeze
  PASSPHRASE = [/Passphrase for ~\/\.ob_write: \z/, PASS].freeze

  def patches
    @bao.requests_for("PATCH")
  end

  def all_writes
    @bao.requests.select { |r| %w[PATCH POST PUT DELETE].include?(r.method) }
  end

  # --- push ------------------------------------------------------------

  def test_push_writes_after_confirm_and_passphrase
    out, code = envpact("push --env=production --from=-", stdin: "DB_PASS=#{VALUE}", answers: [CONFIRM_1, PASSPHRASE])
    assert_equal 0, code, out
    assert_equal 1, patches.size
    assert_equal({ "data" => { "DB_PASS" => VALUE } }, JSON.parse(patches.first.body))
    assert_equal WRITE_TOKEN, patches.first.headers["x-vault-token"]
    assert_equal "application/merge-patch+json", patches.first.headers["content-type"]
    refute_includes out, VALUE
    refute_includes out, WRITE_TOKEN
    refute_includes out, PASS
    assert_includes out, "openbao:secret/team/app/production (env: production) ← DB_PASS (merge; existing keys kept)"
    assert_includes out, "✓ wrote 1 key"
  end

  def test_push_from_file
    path = File.join(@work, "in.env")
    File.write(path, "DB_PASS=\"#{VALUE}\"\nOTHER=o\n")
    out, code = envpact("push --env=production --from=#{path}",
                        answers: [[/Write 2 keys\? \[y\/N\] \z/, "y"], PASSPHRASE])
    assert_equal 0, code, out
    assert_equal({ "DB_PASS" => VALUE, "OTHER" => "o" }, JSON.parse(patches.first.body)["data"])
  end

  def test_push_first_write_creates_with_post
    @bao.on("PATCH", PATH, status: 404, body: { "errors" => [] })
    @bao.on("POST", PATH, body: { "data" => {} })
    out, code = envpact("push --env=production --from=-", stdin: "DB_PASS=#{VALUE}", answers: [CONFIRM_1, PASSPHRASE])
    assert_equal 0, code, out
    assert_equal 1, @bao.requests_for("POST", PATH).size
  end

  def test_push_no_tty_makes_no_request
    # setsid: a session without a controlling terminal, so /dev/tty cannot be
    # opened, whatever the test runner has.
    cmd = ["ruby", "-e", "Process.setsid; exec(*ARGV)", "ruby", "-I#{ROOT}/lib", "#{ROOT}/exe/envpact",
           "push", "--env=production", "--from=-", "--spec=#{@work}/env.spec"]
    out, err, status = Open3.capture3(base_env, *cmd, stdin_data: "DB_PASS=#{VALUE}\n")
    assert_equal 1, status.exitstatus
    assert_includes err, "needs a terminal to confirm writes"
    refute_includes out + err, VALUE
    assert_empty @bao.requests
  end

  def test_push_declined_makes_no_request
    out, code = envpact("push --env=production --from=-", stdin: "DB_PASS=#{VALUE}", answers: [[CONFIRM_1[0], "n"]])
    assert_equal 1, code, out
    assert_empty @bao.requests
    refute_includes out, "Passphrase"
  end

  def test_push_wrong_passphrase_makes_no_request
    out, code = envpact("push --env=production --from=-", stdin: "DB_PASS=#{VALUE}",
                        answers: [CONFIRM_1, [PASSPHRASE[0], "wrong wrong wrong"]])
    assert_equal 1, code, out
    assert_match(/wrong passphrase/, out)
    assert_empty @bao.requests
  end

  def test_push_without_write_keyfile_asks_nothing
    FileUtils.rm_f(File.join(@home, ".ob_write"))
    out, code = envpact("push --env=production --from=-", stdin: "DB_PASS=#{VALUE}")
    assert_equal 1, code, out
    assert_includes out, "no ~/.ob_write; run envpact login --write"
    refute_includes out, "Write 1 key"
    assert_empty @bao.requests
  end

  def test_push_rejects_unknown_key
    out, code = envpact("push --env=production --from=-", stdin: "NOPE=#{VALUE}")
    assert_equal 1, code, out
    assert_includes out, "NOPE"
    assert_includes out, "not declared"
    refute_includes out, VALUE
    assert_empty @bao.requests
  end

  def test_push_invalid_type_no_value_in_message
    out, code = envpact("push --env=production --from=-", stdin: "DB_PORT=abc")
    assert_equal 1, code, out
    assert_includes out, "DB_PORT"
    refute_includes out, "abc"
    assert_empty @bao.requests
  end

  def test_push_ignores_configmap_and_warns_about_missing
    out, code = envpact("push --env=production --from=-", stdin: "'DB_PASS=#{VALUE}\nPORT=1'",
                        answers: [CONFIRM_1, PASSPHRASE])
    assert_equal 0, code, out
    assert_includes out, "! PORT ignored (configmap)"
    assert_includes out, "! OTHER not in input (kept as is in OpenBao)"
    refute_includes out, "DB_PORT not in input" # optional keys are not warned about
    assert_equal({ "data" => { "DB_PASS" => VALUE } }, JSON.parse(patches.first.body))
  end

  def test_push_nothing_to_write
    out, code = envpact("push --env=production --from=-", stdin: "PORT=1")
    assert_equal 1, code, out
    assert_includes out, "nothing to write"
    assert_empty @bao.requests
  end

  def test_push_denied_shows_login_hint
    @bao.on("PATCH", PATH, status: 403, body: { "errors" => ["permission denied"] })
    out, code = envpact("push --env=production --from=-", stdin: "DB_PASS=#{VALUE}", answers: [CONFIRM_1, PASSPHRASE])
    assert_equal 1, code, out
    assert_includes out, "run envpact login --write"
    refute_includes out, WRITE_TOKEN
    refute_includes out, VALUE
  end

  def test_push_without_source_fails_before_asking
    File.write(File.join(@work, "env.spec"), "[secrets]\nDB_PASS\n")
    out, code = envpact("push --env=production --from=-", stdin: "DB_PASS=#{VALUE}")
    assert_equal 1, code, out
    assert_includes out, "no [source] for env 'production'"
    assert_empty @bao.requests
  end

  def test_push_requires_from
    _, code = envpact("push --env=production")
    assert_equal 2, code
  end

  # --- set -------------------------------------------------------------

  def test_set_reads_value_from_stdin_pipe
    out, code = envpact("set --env=production DB_PASS", stdin: VALUE, answers: [CONFIRM_1, PASSPHRASE])
    assert_equal 0, code, out
    assert_equal({ "data" => { "DB_PASS" => VALUE } }, JSON.parse(patches.first.body))
    refute_includes out, VALUE
  end

  def test_set_keeps_spaces_in_value
    out, code = envpact("set --env=production DB_PASS", stdin: "'  a b  '", answers: [CONFIRM_1, PASSPHRASE])
    assert_equal 0, code, out
    assert_equal "  a b  ", JSON.parse(patches.first.body)["data"]["DB_PASS"]
  end

  def test_set_key_not_secret_in_env
    out, code = envpact("set --env=production PORT", stdin: "1")
    assert_equal 1, code, out
    assert_includes out, "PORT"
    assert_empty @bao.requests
  end

  def test_set_invalid_value_no_value_in_message
    out, code = envpact("set --env=production DB_PORT", stdin: "abc")
    assert_equal 1, code, out
    refute_includes out, "abc"
    assert_empty @bao.requests
  end

  def test_set_needs_exactly_one_key
    _, code = envpact("set --env=production")
    assert_equal 2, code
    _, code = envpact("set --env=production A B")
    assert_equal 2, code
  end

  def test_set_empty_stdin_is_an_error
    out, code = envpact("set --env=production DB_PASS", stdin: "''")
    assert_equal 1, code, out
    assert_empty @bao.requests
  end

  # --- agent ------------------------------------------------------------

  def test_write_ignores_agent
    EnvPact::Agent.start(token: "agent-read-tok", addr: @bao.addr, until_time: Time.now + 60)
    out, code = envpact("push --env=production --from=-", stdin: "DB_PASS=#{VALUE}", answers: [CONFIRM_1, PASSPHRASE])
    assert_equal 0, code, out
    assert_match(/Passphrase for ~\/\.ob_write/, out)
    assert_equal WRITE_TOKEN, patches.first.headers["x-vault-token"]
  end
end
