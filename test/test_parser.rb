require_relative "test_helper"

class TestParser < Minitest::Test
  def parse(text)
    EnvPact.parse(text)
  end

  def assert_raises_parse(msg_pattern, &block)
    err = assert_raises(EnvPact::ParseError, &block)
    assert_match msg_pattern, err.message
  end

  # ── basic parsing ────────────────────────────────────────────────

  def test_empty_input
    spec = parse("")
    assert_empty spec.configmap
    assert_empty spec.secrets
  end

  def test_only_comments_and_blank_lines
    spec = parse(<<~SPEC)
      # this is a comment

         # indented comment
    SPEC
    assert_empty spec.configmap
    assert_empty spec.secrets
  end

  def test_single_shared_key_default_type_str
    spec = parse("APP_NAME")
    entry = spec.configmap["*"]["APP_NAME"]
    assert_equal :str, entry.type
    refute entry.optional
    assert_nil entry.default
  end

  def test_optional_marker
    spec = parse("DEBUG?")
    assert spec.configmap["*"]["DEBUG"].optional
  end

  def test_explicit_type_int
    spec = parse("PORT: int")
    assert_equal :int, spec.configmap["*"]["PORT"].type
  end

  def test_default_value
    spec = parse("LOG_LEVEL: str = info")
    e = spec.configmap["*"]["LOG_LEVEL"]
    assert_equal :str, e.type
    assert_equal "info", e.default
  end

  def test_enum_type
    spec = parse("TIER: enum(free, pro, enterprise)")
    e = spec.configmap["*"]["TIER"]
    assert_equal :enum, e.type
    assert_equal %w[free pro enterprise], e.enum_values
  end

  def test_invalid_type_raises
    assert_raises_parse(/unknown type/) { parse("FOO: float") }
  end

  def test_inline_comment_stripped
    spec = parse("APP_NAME  # the app name")
    assert spec.configmap["*"]["APP_NAME"]
  end

  # ── [secrets] modifier ───────────────────────────────────────────

  def test_secrets_modifier_flips_type
    spec = parse(<<~SPEC)
      APP_NAME

      [secrets]
      DB_PASS
      API_KEY
    SPEC

    assert spec.configmap["*"]["APP_NAME"]
    assert_nil spec.configmap["*"]["DB_PASS"]
    assert spec.secrets["*"]["DB_PASS"]
    assert spec.secrets["*"]["API_KEY"]
  end

  def test_secret_with_default_is_error
    assert_raises_parse(/cannot have a default/) do
      parse(<<~SPEC)
        [secrets]
        DB_PASS = hunter2
      SPEC
    end
  end

  # ── [env: ...] selector ──────────────────────────────────────────

  def test_env_selector_resets_to_configmap
    spec = parse(<<~SPEC)
      [secrets]
      SHARED_SECRET

      [env: production]
      PROD_VAR
    SPEC

    assert spec.secrets["*"]["SHARED_SECRET"]
    assert spec.configmap["production"]["PROD_VAR"]
    assert_nil spec.secrets["production"]
  end

  def test_env_selector_multi_env
    spec = parse(<<~SPEC)
      [env: production, staging]
      SHARED_VAR
    SPEC

    assert spec.configmap["production"]["SHARED_VAR"]
    assert spec.configmap["staging"]["SHARED_VAR"]
    assert_nil spec.configmap["*"]
  end

  def test_secret_within_env_scope
    spec = parse(<<~SPEC)
      [env: production]
      [secrets]
      PROD_SECRET
    SPEC

    assert spec.secrets["production"]["PROD_SECRET"]
    refute spec.configmap.key?("production")
  end

  def test_empty_env_selector_is_error
    assert_raises_parse(/empty \[env:/) { parse("[env:]\nFOO\n") }
  end

  def test_unknown_header_is_error
    assert_raises_parse(/unknown header/) { parse("[infisical]\nFOO\n") }
  end

  def test_invalid_env_name_is_error
    # space-separated (not comma) — would silently become one env named "production development"
    assert_raises_parse(/invalid env name/) { parse("[env: production development]\nFOO\n") }
  end

  def test_env_name_with_special_char_is_error
    assert_raises_parse(/invalid env name/) { parse("[env: prod@1]\nFOO\n") }
  end

  def test_env_name_with_underscore_and_dash_ok
    spec = parse(<<~SPEC)
      [env: prod-eu, qa_1]
      FOO
    SPEC
    assert spec.configmap["prod-eu"]["FOO"]
    assert spec.configmap["qa_1"]["FOO"]
  end

  # ── conflict detection ───────────────────────────────────────────

  def test_shared_and_env_overlap_is_error
    assert_raises_parse(/overlapping scopes/) do
      parse(<<~SPEC)
        FOO

        [env: production]
        FOO
      SPEC
    end
  end

  def test_redeclare_in_same_scope_is_error
    assert_raises_parse(/overlapping scopes/) do
      parse(<<~SPEC)
        FOO
        FOO
      SPEC
    end
  end

  def test_cross_env_type_mismatch_is_error
    assert_raises_parse(/different types across envs/) do
      parse(<<~SPEC)
        [env: production]
        PORT: int

        [env: staging]
        PORT: str
      SPEC
    end
  end

  def test_disjoint_envs_with_same_key_and_same_type_ok
    spec = parse(<<~SPEC)
      [env: production]
      DB_HOST

      [env: staging]
      DB_HOST
    SPEC

    assert_equal :str, spec.configmap["production"]["DB_HOST"].type
    assert_equal :str, spec.configmap["staging"]["DB_HOST"].type
  end

  # ── realistic example ───────────────────────────────────────────

  def test_realistic_spec
    spec = parse(<<~SPEC)
      # shared configmap
      APP_NAME
      LOG_LEVEL: enum(debug, info, warn, error) = info
      DEBUG?: bool

      [secrets]
      # shared secrets
      DB_PASS
      OPENAI_API_KEY

      [env: production]
      DB_HOST
      [secrets]
      STRIPE_LIVE_KEY

      [env: staging]
      DB_HOST
      [secrets]
      STRIPE_TEST_KEY
    SPEC

    assert_equal :enum, spec.configmap["*"]["LOG_LEVEL"].type
    assert_equal "info", spec.configmap["*"]["LOG_LEVEL"].default
    assert spec.secrets["*"]["DB_PASS"]
    assert spec.configmap["production"]["DB_HOST"]
    assert spec.secrets["production"]["STRIPE_LIVE_KEY"]
    assert spec.configmap["staging"]["DB_HOST"]
    assert spec.secrets["staging"]["STRIPE_TEST_KEY"]
  end
end
