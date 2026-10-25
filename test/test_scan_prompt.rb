require_relative "test_helper"

class TestScanPrompt < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def syntax
    File.read(File.join(ROOT, "lib/envpact/syntax.md"))
  end

  def test_render_embeds_syntax_and_has_no_placeholder
    out = EnvPact::ScanPrompt.render
    assert_includes out, syntax
    refute_includes out, "{{SYNTAX}}"
  end

  def test_syntax_example_is_a_valid_spec
    example = syntax[/```\n(.*?)```/m, 1]
    spec = EnvPact.parse(example)
    assert spec.configmap["*"].key?("FEATURE_FLAGS")
    assert spec.secrets["production"].key?("STRIPE_LIVE_KEY")
  end

  def test_prompt_forbids_copying_values
    assert_includes EnvPact::ScanPrompt.render, "never copy values into the contract or the transcript"
  end

  def test_prompt_mentions_todo_convention_and_lint
    out = EnvPact::ScanPrompt.render
    assert_includes out, "# TODO(envpact):"
    assert_includes out, "envpact lint"
  end

  def test_readme_syntax_matches_gem_reference
    readme = File.read(File.join(ROOT, "README.md"))
    assert_includes readme, syntax, "README syntax section drifted from lib/envpact/syntax.md"
  end

  def test_cli_scan_prompt
    code = nil
    out, = capture_io { code = EnvPact::CLI.run(["scan-prompt"]) }
    assert_equal 0, code
    assert_equal EnvPact::ScanPrompt.render, out
  end
end
