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

  # ── check ─────────────────────────────────────────────────────────

  def test_check_requires_env
    in_tmpdir("env.spec" => "A\n") do
      assert_equal 2, run_cli("check").first
    end
  end

  def test_check_reads_dotenv_files_for_env
    in_tmpdir("env.spec" => "A\nB\n", ".env" => "A=1\n", ".env.test" => "B=2\n") do
      code, out, = run_cli("check", "--env=test")
      assert_equal 0, code
      assert_match(/^Read: \.env, \.env\.test$/, out)
      assert_includes out, "✓ env.spec satisfied (env: test — shared only)"
    end
  end

  def test_check_reports_no_files_found
    in_tmpdir("env.spec" => "A?\n") do
      _, out, = run_cli("check", "--env=dev")
      assert_includes out, "Read: (no .env files found)"
    end
  end

  def test_check_reports_applied_section
    in_tmpdir("env.spec" => "A\n[env: production]\nB\n", ".env" => "A=1\nB=2\n") do
      _, out, = run_cli("check", "--env=production")
      assert_includes out, "✓ env.spec satisfied (env: production — shared + [env: production])"
    end
  end

  def test_check_lists_sections_when_env_has_none
    in_tmpdir("env.spec" => "A\n[env: production]\nB\n[env: staging]\nC\n", ".env" => "A=1\n") do
      _, out, = run_cli("check", "--env=prod")
      assert_includes out, "✓ env.spec satisfied (env: prod — shared only; sections in spec: production, staging)"
    end
  end

  def test_check_failure_lists_problems
    in_tmpdir("env.spec" => "A\nB\n", ".env" => "A=1\n") do
      code, _, err = run_cli("check", "--env=dev")
      assert_equal 1, code
      assert_includes err, "✗ env.spec not satisfied (env: dev — shared only)"
      assert_includes err, "  - missing required env var 'B' (declared at line 2)"
    end
  end

  def test_check_masks_secrets_unless_show_values
    in_tmpdir("env.spec" => "[secrets]\nP: int\n", ".env" => "P=hunter2\n") do
      _, _, err = run_cli("check", "--env=dev")
      refute_match(/hunter2/, err)
      _, _, err = run_cli("check", "--env=dev", "--show-values")
      assert_match(/hunter2/, err)
    end
  end

  def test_check_extras_warn_and_strict_fails
    in_tmpdir("env.spec" => "A\n", ".env" => "A=1\nZ=secretish\n") do
      code, _, err = run_cli("check", "--env=dev")
      assert_equal 0, code
      assert_includes err, "  ! unknown env var 'Z' (not declared in spec)"
      _, _, err = run_cli("check", "--env=dev", "--show-values")
      refute_match(/secretish/, err)
      assert_equal 1, run_cli("check", "--env=dev", "--strict").first
    end
  end

  def test_check_from_env_ignores_extras
    in_tmpdir("env.spec" => "ENVPACT_T_A\n") do
      with_env("ENVPACT_T_A" => "1") do
        code, _, err = run_cli("check", "--env=x", "--from-env", "--strict")
        assert_equal 0, code
        refute_match(/unknown env var/, err)
      end
    end
  end

  def test_check_missing_spec_exits_1
    in_tmpdir do
      code, _, err = run_cli("check", "--env=x")
      assert_equal 1, code
      assert_equal "envpact: spec not found: envpact.yml\n", err
    end
  end

  def test_unreadable_spec_exits_1_without_backtrace
    skip "root can read anything" if Process.uid.zero?
    in_tmpdir("env.spec" => "A\n") do
      File.chmod(0o000, "env.spec")
      code, _, err = run_cli("lint")
      assert_equal 1, code
      assert_match(/^envpact: Permission denied/, err)
    end
  end

  def test_missing_spec_exits_1_without_backtrace
    code, _, err = run_cli("lint", "--spec=/nonexistent/env.spec")
    assert_equal 1, code
    assert_equal "envpact: spec not found: /nonexistent/env.spec\n", err
  end

  # ── envpact.yml and the legacy env.spec ──────────────────────────

  def test_lint_defaults_to_envpact_yml
    in_tmpdir("envpact.yml" => "version: 1\nvars:\n  A:\n") do
      code, out, err = run_cli("lint")
      assert_equal 0, code
      assert_includes out, "envpact.yml is valid"
      assert_equal "", err
    end
  end

  def test_legacy_env_spec_works_with_a_warning
    in_tmpdir("env.spec" => "A\n") do
      code, out, err = run_cli("lint")
      assert_equal 0, code
      assert_includes out, "env.spec is valid"
      assert_includes err, "env.spec is deprecated: run `envpact convert`"
    end
  end

  def test_both_contracts_is_an_error
    in_tmpdir("env.spec" => "A\n", "envpact.yml" => "version: 1\n") do
      code, _, err = run_cli("lint")
      assert_equal 1, code
      assert_includes err, "both envpact.yml and env.spec"
    end
  end

  def test_check_with_envpact_yml
    in_tmpdir("envpact.yml" => "version: 1\nvars:\n  A: int\n", ".env" => "A=12\n") do
      code, out, _ = run_cli("check", "--env=dev")
      assert_equal 0, code
      assert_includes out, "✓ envpact.yml satisfied"
    end
  end
end
