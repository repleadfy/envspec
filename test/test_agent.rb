require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "json"
require "socket"

class TestAgent < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("epa")
    @saved = ENV.to_h.select { |k, _| %w[ENVPACT_AGENT_SOCK XDG_RUNTIME_DIR].include?(k) }
    ENV["ENVPACT_AGENT_SOCK"] = File.join(@dir, "a.sock")
    ENV.delete("XDG_RUNTIME_DIR")
  end

  def teardown
    begin
      EnvPact::Agent.request("lock")
    rescue EnvPact::Error
      nil
    end
    sleep 0.1
    %w[ENVPACT_AGENT_SOCK XDG_RUNTIME_DIR].each { |k| ENV.delete(k) }
    @saved.each { |k, v| ENV[k] = v }
    FileUtils.remove_entry(@dir)
  end

  def start(token: "tok", addr: "http://bao.test", secs: 30)
    EnvPact::Agent.start(token: token, addr: addr, until_time: Time.now + secs)
  end

  def test_agent_serves_token_then_expires
    start(secs: 1)
    r = EnvPact::Agent.request("token")
    assert_equal "tok", r["token"]
    assert_equal "http://bao.test", r["addr"]
    assert r["until"]
    sleep 1.7
    assert_nil EnvPact::Agent.request("token")
    refute File.exist?(ENV["ENVPACT_AGENT_SOCK"])
  end

  def test_lock_stops_agent
    pid = start
    assert_equal({ "ok" => true }, EnvPact::Agent.request("lock"))
    sleep 0.3
    assert_nil EnvPact::Agent.request("token")
    refute File.exist?(ENV["ENVPACT_AGENT_SOCK"])
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end

  def test_stale_socket_replaced
    UNIXServer.new(ENV["ENVPACT_AGENT_SOCK"]).close
    assert File.socket?(ENV["ENVPACT_AGENT_SOCK"])
    assert_nil EnvPact::Agent.request("token")
    start
    assert_equal "tok", EnvPact::Agent.request("token")["token"]
  end

  def test_non_socket_at_path_is_refused_and_kept
    File.write(ENV["ENVPACT_AGENT_SOCK"], "precious")
    assert_raises(EnvPact::Error) { start }
    assert_equal "precious", File.read(ENV["ENVPACT_AGENT_SOCK"])
  end

  def test_live_agent_is_replaced
    start(token: "one")
    start(token: "two")
    assert_equal "two", EnvPact::Agent.request("token")["token"]
  end

  def test_socket_mode_0600_dir_0700
    ENV.delete("ENVPACT_AGENT_SOCK")
    ENV["XDG_RUNTIME_DIR"] = @dir
    start
    sock = File.join(@dir, "envpact-#{Process.uid}", "agent.sock")
    assert_equal sock, EnvPact::Agent.socket_path
    assert_equal 0o600, File.stat(sock).mode & 0o777
    assert_equal 0o700, File.stat(File.dirname(sock)).mode & 0o777
  end

  def test_socket_mode_0600_under_loose_umask
    old = File.umask(0o000)
    begin
      start
    ensure
      File.umask(old)
    end
    assert_equal 0o600, File.stat(ENV["ENVPACT_AGENT_SOCK"]).mode & 0o777
  end

  def test_dir_with_wrong_mode_is_error
    ENV.delete("ENVPACT_AGENT_SOCK")
    ENV["XDG_RUNTIME_DIR"] = @dir
    d = File.join(@dir, "envpact-#{Process.uid}")
    Dir.mkdir(d, 0o755)
    File.chmod(0o755, d)
    err = assert_raises(EnvPact::Error) { EnvPact::Agent.socket_path }
    assert_includes err.message, d
  end

  def test_dir_that_is_a_symlink_is_error
    ENV.delete("ENVPACT_AGENT_SOCK")
    ENV["XDG_RUNTIME_DIR"] = @dir
    elsewhere = File.join(@dir, "elsewhere")
    Dir.mkdir(elsewhere, 0o700)
    File.symlink(elsewhere, File.join(@dir, "envpact-#{Process.uid}"))
    assert_raises(EnvPact::Error) { EnvPact::Agent.socket_path }
  end

  def test_status_has_no_token
    start(token: "s3cr3t-tok")
    r = EnvPact::Agent.request("status")
    assert_equal "http://bao.test", r["addr"]
    assert r["until"]
    refute_includes JSON.generate(r), "s3cr3t-tok"
    refute r.key?("token")
  end

  def test_unknown_op_and_garbage_do_not_kill_agent
    start
    assert EnvPact::Agent.request("nope")["error"]
    s = UNIXSocket.new(ENV["ENVPACT_AGENT_SOCK"])
    s.write("this is not json\n")
    s.close
    assert_equal "tok", EnvPact::Agent.request("token")["token"]
  end

  def test_request_without_agent_is_nil
    assert_nil EnvPact::Agent.request("token")
  end

  def test_max_lifetime_is_capped_at_8h
    assert_in_delta Time.now.to_f + 8 * 3600, EnvPact::Agent.cap_until(Time.now + 30 * 3600).to_f, 2
    t = Time.now + 60
    assert_equal t, EnvPact::Agent.cap_until(t)
  end

  def test_peer_uid_of_same_user_is_allowed
    a, b = UNIXSocket.pair
    assert EnvPact::Agent.peer_allowed?(a)
    assert EnvPact::Agent.peer_allowed?(b)
  ensure
    a.close if a
    b.close if b
  end

  def test_other_uid_is_refused
    refute EnvPact::Agent.uid_allowed?(Process.uid + 1)
    assert EnvPact::Agent.uid_allowed?(Process.uid)
  end

  def test_token_not_in_process_argv_or_environ
    skip "needs /proc" unless File.directory?("/proc/self")
    pid = start(token: "s3cr3t-agent-token")
    # The child renames itself a moment after the fork.
    40.times do
      break if File.binread("/proc/#{pid}/cmdline").include?("envpact-agent")
      sleep 0.05
    end
    cmdline = File.binread("/proc/#{pid}/cmdline")
    environ  = File.binread("/proc/#{pid}/environ")
    assert_includes cmdline, "envpact-agent"
    refute_includes cmdline, "s3cr3t-agent-token"
    refute_includes environ, "s3cr3t-agent-token"
  end

  # The agent is a fork of the test process; if it left through a normal exit
  # it would run minitest's at_exit and re-run the suite.
  def test_agent_child_does_not_run_parent_at_exit_hooks
    marker = File.join(@dir, "marker")
    parent = Process.pid
    at_exit { File.write(marker, "ran") if Process.pid != parent }
    start(secs: 1)
    EnvPact::Agent.request("lock")
    sleep 0.5
    refute File.exist?(marker), "forked agent ran an at_exit hook"
  end
end
