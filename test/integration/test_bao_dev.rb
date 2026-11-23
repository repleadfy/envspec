require_relative "../test_helper"
require_relative "../support/tmp_home"
require_relative "../support/pty_run"
require "open3"
require "json"
require "socket"
require "net/http"
require "tmpdir"
require "fileutils"

# Runs the real CLI against a real `bao server -dev`. Skipped unless
# ENVPACT_BAO_BIN points at an OpenBao binary (CI pins 2.7.3).
#
#   ENVPACT_BAO_BIN=/path/to/bao rake test:integration
class TestBaoDev < Minitest::Test
  include TmpHome

  ROOT = File.expand_path("../..", __dir__)
  BAO  = ENV["ENVPACT_BAO_BIN"]
  ROOT_TOKEN = "root".freeze # dev-mode token of a throwaway in-memory server
  PASS = "correct horse battery".freeze
  VALUE = %(p@ss "quoted" \\ back # hash ünï\n second line ).freeze

  READ_POLICY  = %(path "secret/data/app/*" { capabilities = ["read"] }\n).freeze
  WRITE_POLICY = %(path "secret/data/app/*" { capabilities = ["create", "update", "patch"] }\n).freeze

  def setup
    skip "set ENVPACT_BAO_BIN to an OpenBao binary to run the integration test" unless BAO && File.executable?(BAO)
    super
    @work = Dir.mktmpdir("epi")
    @sockdir = Dir.mktmpdir("epj")
    @port = free_port
    @addr = "http://127.0.0.1:#{@port}"
    @pid = Process.spawn({ "HOME" => @home }, BAO, "server", "-dev", "-dev-root-token-id=#{ROOT_TOKEN}",
                         "-dev-listen-address=127.0.0.1:#{@port}",
                         out: File.join(@work, "bao.log"), err: [:child, :out])
    wait_ready
    @read_token  = create_token("ro", READ_POLICY)
    @write_token = create_token("rw", WRITE_POLICY)
    File.write(File.join(@work, "env.spec"), <<~SPEC)
      [source]
      openbao path=app/{env} addr=#{@addr}
      [secrets]
      DB_PASS
      OTHER?
    SPEC
  end

  def teardown
    if @pid
      Process.kill("TERM", @pid) rescue nil
      Process.wait(@pid) rescue nil
    end
    envpact("lock") if @sockdir
    FileUtils.remove_entry(@work) if @work
    FileUtils.remove_entry(@sockdir) if @sockdir
    super
  end

  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    s.addr[1]
  ensure
    s.close if s
  end

  def wait_ready
    80.times do
      begin
        res = Net::HTTP.get_response(URI("#{@addr}/v1/sys/health"))
        return if res.code.to_i == 200
      rescue SystemCallError, EOFError
        nil
      end
      sleep 0.25
    end
    flunk "bao server -dev did not come up; log: #{File.read(File.join(@work, 'bao.log'))[-500..-1]}"
  end

  def bao(*args, stdin: nil)
    env = { "HOME" => @home, "BAO_ADDR" => @addr, "BAO_TOKEN" => ROOT_TOKEN }
    out, err, st = Open3.capture3(env, BAO, *args, stdin_data: stdin.to_s)
    flunk "bao #{args.first(2).join(' ')} failed: #{err}" unless st.success?
    out
  end

  def create_token(name, policy)
    bao("policy", "write", name, "-", stdin: policy)
    JSON.parse(bao("token", "create", "-policy=#{name}", "-format=json"))["auth"]["client_token"]
  end

  def envpact(args, stdin: nil, answers: [])
    base = "exec ruby -I#{ROOT}/lib #{ROOT}/exe/envpact #{args}"
    script = stdin ? "printf '%s\\n' #{stdin} | #{base}" : base
    PtyRun.run(["sh", "-c", script], answers: answers, timeout: 90,
               env: { "HOME" => @home, "ENVPACT_AGENT_SOCK" => File.join(@sockdir, "a.sock"), "BAO_ADDR" => nil,
                      "BAO_TOKEN" => nil, "ENVPACT_SPEC" => nil })
  end

  def login(kind, token)
    out, code = envpact("login --#{kind} --addr=#{@addr} --token-stdin", stdin: token,
                        answers: [[/passphrase.*: \z/i, PASS], [/repeat/i, PASS]])
    assert_equal 0, code, out
  end

  PASSPHRASE = [/Passphrase for ~\/\.ob_(read|write): \z/, PASS].freeze

  def test_push_pull_run_and_denied_write
    login(:read, @read_token)
    login(:write, @write_token)

    # push (confirmation + write passphrase)
    input = File.join(@work, "in.env")
    File.write(input, EnvPact::Dotenv.dump("DB_PASS" => VALUE))
    out, code = envpact("push --env=dev --from=#{input} --spec=#{@work}/env.spec",
                        answers: [[/Write 1 key\? \[y\/N\] \z/, "y"], PASSPHRASE])
    assert_equal 0, code, out
    assert_includes out, "✓ wrote 1 key"

    # pull (read passphrase) gives the same value back, in a 0600 file
    out, code = envpact("pull --env=dev --spec=#{@work}/env.spec --out=#{@work}/.env.dev.local", answers: [PASSPHRASE])
    assert_equal 0, code, out
    target = File.join(@work, ".env.dev.local")
    assert_equal 0o600, File.stat(target).mode & 0o777
    assert_equal({ "DB_PASS" => VALUE }, EnvPact::Dotenv.parse(File.read(target)))
    refute_includes out, "p@ss"

    # unlock, then run needs no passphrase
    out, code = envpact("unlock --for=1h", answers: [PASSPHRASE])
    assert_equal 0, code, out
    out, code = envpact("run --env=dev --spec=#{@work}/env.spec -- ruby -e 'print ENV[%(DB_PASS)].bytesize'")
    assert_equal 0, code, out
    assert_includes out, VALUE.bytesize.to_s
    envpact("lock")

    # a second push merges: the first key survives
    File.write(input, EnvPact::Dotenv.dump("OTHER" => "o"))
    out, code = envpact("push --env=dev --from=#{input} --spec=#{@work}/env.spec",
                        answers: [[/Write 1 key\? \[y\/N\] \z/, "y"], PASSPHRASE])
    assert_equal 0, code, out
    out, code = envpact("pull --env=dev --spec=#{@work}/env.spec --out=#{@work}/.env.dev.local", answers: [PASSPHRASE])
    assert_equal 0, code, out
    assert_equal({ "DB_PASS" => VALUE, "OTHER" => "o" }, EnvPact::Dotenv.parse(File.read(target)))

    # the read-only token, stored as the write token, is denied by the server
    login(:write, @read_token)
    out, code = envpact("set --env=dev DB_PASS --spec=#{@work}/env.spec", stdin: "new",
                        answers: [[/Write 1 key\? \[y\/N\] \z/, "y"], PASSPHRASE])
    assert_equal 1, code, out
    assert_includes out, "token rejected for secret/app/dev (expired, revoked or not allowed); run envpact login --write"
    refute_includes out, @read_token
  end

  def test_pull_with_write_only_token_is_denied
    login(:read, @write_token)
    out, code = envpact("pull --env=dev --spec=#{@work}/env.spec", answers: [PASSPHRASE])
    assert_equal 1, code, out
    assert_includes out, "run envpact login --read"
    refute_includes out, @write_token
  end
end
