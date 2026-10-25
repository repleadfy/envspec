require_relative "test_helper"
require "open3"
require "tmpdir"

# exec replaces the process, so these run envpact in a subprocess.
class TestExec < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PRINT_A    = ["ruby", "-e", 'print ENV["A"]'].freeze
  PRINT_PORT = ["ruby", "-e", 'print ENV["PORT"]'].freeze

  def envpact(spec_text, env, *args)
    Dir.mktmpdir do |d|
      spec = File.join(d, "env.spec")
      File.write(spec, spec_text)
      cmd = ["ruby", "-I#{ROOT}/lib", "#{ROOT}/exe/envpact", "exec", "--spec=#{spec}", *args]
      # Clear vars a test might inherit from the runner's own ENV.
      clean = { "A" => nil, "B" => nil, "P" => nil, "PORT" => nil, "ENVPACT_ENV" => nil, "ENVPACT_SPEC" => nil }
      out, err, status = Open3.capture3(clean.merge(env), *cmd)
      [status.exitstatus, out, err]
    end
  end

  def test_exec_runs_command_when_satisfied
    code, out, = envpact("A\n", { "A" => "1" }, "--env=x", "--", *PRINT_A)
    assert_equal 0, code
    assert_equal "1", out
  end

  def test_exec_fills_defaults_for_absent_and_empty
    assert_equal "3000", envpact("PORT: int = 3000\n", { "PORT" => "" }, "--env=x", "--", *PRINT_PORT)[1]
    assert_equal "3000", envpact("PORT: int = 3000\n", {}, "--env=x", "--", *PRINT_PORT)[1]
  end

  def test_exec_keeps_present_values_over_defaults
    assert_equal "8080", envpact("PORT: int = 3000\n", { "PORT" => "8080" }, "--env=x", "--", *PRINT_PORT)[1]
  end

  def test_exec_refuses_to_start_on_failure
    code, out, err = envpact("A\n", {}, "--env=x", "--", *PRINT_A)
    assert_equal 1, code
    assert_equal "", out
    assert_includes err, "missing required env var 'A'"
  end

  def test_exec_never_prints_secret_values
    code, _, err = envpact("[secrets]\nP: int\n", { "P" => "hunter2" }, "--env=x", "--", "true")
    assert_equal 1, code
    refute_match(/hunter2/, err)
  end

  def test_exec_env_from_envpact_env
    code, _, err = envpact("A\n[env: production]\nB\n", { "ENVPACT_ENV" => "production", "A" => "1" }, "--", "true")
    assert_equal 1, code
    assert_includes err, "missing required env var 'B'"
  end

  def test_exec_command_not_found
    code, _, err = envpact("A\n", { "A" => "1" }, "--env=x", "--", "definitely-not-a-command-xyz")
    assert_equal 127, code
    assert_equal "envpact: command not found: definitely-not-a-command-xyz\n", err.lines.last
    refute_match(/\.rb:\d+:in/, err)
  end

  def test_exec_command_not_executable
    Dir.mktmpdir do |d|
      script = File.join(d, "noexec.sh")
      File.write(script, "#!/bin/sh\necho hi\n")
      File.chmod(0o644, script)
      code, _, err = envpact("A\n", { "A" => "1" }, "--env=x", "--", script)
      assert_equal 126, code
      assert_match(/\Aenvpact: cannot execute: #{Regexp.escape(script)} \(/, err.lines.last)
      refute_match(/\.rb:\d+:in/, err)
    end
  end

  def test_exec_reports_applied_sections_on_success
    _, _, err = envpact("A\n[env: production]\nB?\n", { "A" => "1" }, "--env=prod", "--", "true")
    assert_includes err, "✓ env.spec satisfied (env: prod — shared only; sections in spec: production)"
  end

  def test_exec_missing_spec_exits_1
    Dir.mktmpdir do |d|
      cmd = ["ruby", "-I#{ROOT}/lib", "#{ROOT}/exe/envpact", "exec", "--spec=#{d}/nope.spec", "--env=x", "--", "true"]
      _, err, status = Open3.capture3({ "ENVPACT_SPEC" => nil }, *cmd)
      assert_equal 1, status.exitstatus
      assert_equal "envpact: spec not found: #{d}/nope.spec\n", err
    end
  end

  def test_exec_without_command_is_usage_error
    assert_equal 2, envpact("A\n", { "A" => "1" }, "--env=x").first
  end

  def test_exec_without_env_is_usage_error
    assert_equal 2, envpact("A\n", { "A" => "1" }, "--", "true").first
  end

  def test_exec_passes_command_flags_through
    _, out, = envpact("A\n", { "A" => "1" }, "--env=x", "--", "ruby", "-e", "print ARGV.join(',')", "--", "--env=y")
    assert_equal "--env=y", out
  end
end
