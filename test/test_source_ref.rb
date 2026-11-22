require_relative "test_helper"
require "tmpdir"

class TestSourceRef < Minitest::Test
  SPEC = <<~SPEC.freeze
    [source]
    openbao path=team/promptune/{env}
    openbao path=cluster/selly/promptune-web env=production
  SPEC

  def parse(text)
    EnvPact.parse(text)
  end

  def assert_raises_parse(msg_pattern, &block)
    err = assert_raises(EnvPact::ParseError, &block)
    assert_match msg_pattern, err.message
    err
  end

  def test_fallback_source_resolves_env
    ref = parse(SPEC).source_for("development")
    assert_equal "team/promptune/development", ref.path
    assert_equal "secret", ref.mount
    assert_equal "openbao", ref.backend
    assert_nil ref.addr
    assert_equal 2, ref.line
  end

  def test_env_specific_source_wins
    assert_equal "cluster/selly/promptune-web", parse(SPEC).source_for("production").path
  end

  def test_mount_and_addr_options
    ref = parse("[source]\nopenbao path=a/b mount=kv addr=http://bao.test:8200\n").source_for("x")
    assert_equal "kv", ref.mount
    assert_equal "http://bao.test:8200", ref.addr
  end

  def test_env_list_option
    spec = parse("[source]\nopenbao path=a/{env}\nopenbao path=b env=staging,production\n")
    assert_equal "b", spec.source_for("staging").path
    assert_equal "b", spec.source_for("production").path
    assert_equal "a/dev", spec.source_for("dev").path
  end

  def test_no_source_section_returns_nil
    spec = parse("A\n")
    assert_nil spec.source_for("x")
    assert_empty spec.sources
  end

  def test_no_fallback_and_unlisted_env_returns_nil
    assert_nil parse("[source]\nopenbao path=a env=production\n").source_for("dev")
  end

  def test_source_for_rejects_unsafe_env_name
    spec = parse(SPEC)
    assert_raises(EnvPact::Error) { spec.source_for("../x") }
  end

  def test_sources_lists_raw_lines
    assert_equal 2, parse(SPEC).sources.size
  end

  def test_two_fallbacks_error
    assert_raises_parse(/line 3: .*fallback/) { parse("[source]\nopenbao path=a\nopenbao path=b\n") }
  end

  def test_env_in_two_sources_error
    assert_raises_parse(/line 3: .*'production'/) do
      parse("[source]\nopenbao path=a env=production\nopenbao path=b env=staging,production\n")
    end
  end

  def test_unknown_backend_error
    assert_raises_parse(/line 2: .*expected 'openbao path=\.\.\.' in \[source\]/) { parse("[source]\nvault path=x\n") }
  end

  def test_unknown_option_error
    assert_raises_parse(/unknown option 'tls'/) { parse("[source]\nopenbao path=x tls=no\n") }
  end

  def test_duplicate_option_error
    assert_raises_parse(/duplicate option 'path'/) { parse("[source]\nopenbao path=x path=y\n") }
  end

  def test_missing_path_error
    assert_raises_parse(/needs path=/) { parse("[source]\nopenbao mount=kv\n") }
  end

  def test_bad_path_error
    ["../x", "/x", "a b", "{project}", "a/../b", "a//b", "a/"].each do |bad|
      assert_raises(EnvPact::ParseError, bad) { parse("[source]\nopenbao path=#{bad}\n") }
    end
  end

  def test_bad_env_name_in_source_error
    assert_raises_parse(/invalid env name/) { parse("[source]\nopenbao path=a env=a/b\n") }
  end

  def test_bad_addr_error
    assert_raises_parse(/addr must be http/) { parse("[source]\nopenbao path=a addr=ftp://x\n") }
  end

  def test_key_line_inside_source_error
    err = assert_raises_parse(/expected 'openbao path=\.\.\.' in \[source\]/) { parse("[source]\nDB_PASS\n") }
    refute_includes err.message, "DB_PASS"
  end

  def test_header_after_source_resumes_keys
    spec = parse("[source]\nopenbao path=a\n[secrets]\nDB_PASS\n")
    assert spec.secrets_for("x").key?("DB_PASS")
  end

  def test_source_resets_scope_to_shared
    spec = parse("[env: production]\nA\n[source]\nopenbao path=a\n[secrets]\nB\n")
    assert spec.secrets_for("dev").key?("B")
    assert spec.configmap_for("production").key?("A")
  end

  def test_env_header_after_source
    spec = parse("[source]\nopenbao path=a\n[env: production]\nA\n")
    assert spec.configmap_for("production").key?("A")
    refute spec.configmap_for("dev").key?("A")
  end

  def test_comments_and_blank_lines_in_source
    spec = parse("[source]\n# where\n\nopenbao path=a # trailing\n")
    assert_equal "a", spec.source_for("x").path
  end

  def test_lint_accepts_source
    Dir.mktmpdir do |d|
      path = File.join(d, "env.spec")
      File.write(path, SPEC + "[secrets]\nDB_PASS\n")
      code = nil
      capture_io { code = EnvPact::CLI.run(["lint", "--spec=#{path}"]) }
      assert_equal 0, code
    end
  end
end
