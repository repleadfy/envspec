require_relative "test_helper"
require "tmpdir"

class TestCLI < Minitest::Test
  def run_cli(*argv)
    code = nil
    out, err = capture_io { code = EnvPact::CLI.run(argv) }
    [code, out, err]
  end

  def with_env(vars)
    saved = vars.keys.map { |k| [k, ENV[k]] }.to_h
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  def in_tmpdir(files = {})
    Dir.mktmpdir do |d|
      files.each { |name, content| File.write(File.join(d, name), content) }
      Dir.chdir(d) { yield d }
    end
  end

  # ── framework ─────────────────────────────────────────────────────

  def test_command_class_name_untouched
    assert_equal "EnvPact::CLI::Lint", EnvPact::CLI::Lint.name
  end

  def test_help_flag_returns_0
    code, out, = run_cli("lint", "-h")
    assert_equal 0, code
    assert_match(/Usage: envpact lint/, out)
  end

  def test_unknown_option_exits_2
    assert_equal 2, run_cli("lint", "--nope").first
  end

  def test_unknown_command_exits_2
    assert_equal 2, run_cli("nope").first
  end

  # ── lint ──────────────────────────────────────────────────────────

  def test_lint_ok_with_spec_flag
    in_tmpdir("my.spec" => "A\n") do |d|
      code, out, = run_cli("lint", "--spec=#{File.join(d, 'my.spec')}")
      assert_equal 0, code
      assert_match(/valid/, out)
    end
  end

  def test_lint_defaults_to_env_spec_in_cwd
    in_tmpdir("env.spec" => "A\n") do
      assert_equal 0, run_cli("lint").first
    end
  end

  def test_lint_uses_envpact_spec_env_var
    in_tmpdir("other.spec" => "A\n") do |d|
      with_env("ENVPACT_SPEC" => File.join(d, "other.spec")) do
        assert_equal 0, run_cli("lint").first
      end
    end
  end

  def test_lint_parse_error_exits_1
    in_tmpdir("env.spec" => "x\n") do
      code, _, err = run_cli("lint")
      assert_equal 1, code
      assert_match(/line 1: invalid key line/, err)
    end
  end

  def test_missing_spec_exits_1_without_backtrace
    code, _, err = run_cli("lint", "--spec=/nonexistent/env.spec")
    assert_equal 1, code
    assert_equal "envpact: spec not found: /nonexistent/env.spec\n", err
  end
end
