require_relative "test_helper"
require "pty"
require "timeout"

class TestPrompt < Minitest::Test
  # Runs the block with a Prompt wired to a fresh pty; feeds `answers` one by
  # one, each right after the prompt label shows up (so echo is already off).
  def with_pty(answers)
    master, slave = PTY.open
    seen = +""
    feeder = Thread.new do
      answers.each do |ans|
        Timeout.timeout(5) { seen << master.readpartial(1024) while seen.empty? || !seen.end_with?(": ", "] ") }
        master.write(ans + "\n")
        seen.clear
        sleep 0.05
      end
    end
    yield EnvPact::Prompt.new(slave.path)
  ensure
    feeder.join(5) if feeder
    master.close if master && !master.closed?
    slave.close if slave && !slave.closed?
  end

  def test_secret_returns_typed_text
    with_pty(["hunter2"]) { |p| assert_equal "hunter2", p.secret("Pass: ") }
  end

  def test_secret_does_not_echo
    master, slave = PTY.open
    out = +""
    reader = Thread.new { loop { out << master.readpartial(1024) } rescue nil }
    t = Thread.new { sleep 0.3; master.write("hunter2\n") }
    EnvPact::Prompt.new(slave.path).secret("Pass: ")
    t.join
    sleep 0.2
    reader.kill
    assert_includes out, "Pass: "
    refute_includes out, "hunter2"
  ensure
    master.close if master
    slave.close if slave
  end

  def test_confirm_accepts_y_and_yes
    with_pty(["y", "YES"]) do |p|
      assert p.confirm("OK? [y/N] ")
      assert p.confirm("OK? [y/N] ")
    end
  end

  def test_confirm_declines_everything_else
    with_pty(["", "n", "yep"]) do |p|
      refute p.confirm("OK? [y/N] ")
      refute p.confirm("OK? [y/N] ")
      refute p.confirm("OK? [y/N] ")
    end
  end

  def test_available_with_tty
    master, slave = PTY.open
    assert EnvPact::Prompt.new(slave.path).available?
  ensure
    master.close if master
    slave.close if slave
  end

  def test_unavailable_without_tty
    p = EnvPact::Prompt.new("/nonexistent/tty")
    refute p.available?
    err = assert_raises(EnvPact::Error) { p.secret("x: ") }
    assert_equal "needs a terminal to confirm writes", err.message
    err = assert_raises(EnvPact::Error) { p.confirm("x? ") }
    assert_equal "needs a terminal to confirm writes", err.message
  end
end
