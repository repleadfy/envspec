require_relative "test_helper"

class TestChecker < Minitest::Test
  def spec(text)
    EnvPact.parse(text)
  end

  def check(text, values, env: "x", **opts)
    spec(text).check(values, env: env, **opts)
  end

  # ── presence ──────────────────────────────────────────────────────

  def test_passes_when_all_required_present
    assert check("APP_NAME\nPORT: int", { "APP_NAME" => "leadfy", "PORT" => "3000" }).ok?
  end

  def test_missing_required_fails
    r = check("APP_NAME", {})
    assert_equal ["missing required env var 'APP_NAME' (declared at line 1)"], r.errors.map(&:message)
  end

  def test_missing_optional_ok
    assert check("DEBUG?: bool", {}).ok?
  end

  def test_missing_with_default_ok
    assert check("LOG_LEVEL: str = info", {}).ok?
  end

  def test_env_is_required_keyword
    assert_raises(ArgumentError) { spec("A").check({}) }
  end

  def test_empty_counts_as_missing
    assert_equal [:missing], check("A", { "A" => "" }).errors.map(&:kind)
  end

  def test_empty_with_default_is_ok_and_not_type_checked
    assert check("PORT: int = 3000", { "PORT" => "" }).ok?
  end

  def test_empty_optional_not_type_checked
    assert check("PORT?: int", { "PORT" => "" }).ok?
  end

  # ── type checks ───────────────────────────────────────────────────

  def test_int
    assert check("PORT: int", { "PORT" => "3000" }).ok?
    r = check("PORT: int", { "PORT" => "abc" })
    assert_equal [%(env var 'PORT' = "abc" is not a valid int)], r.errors.map(&:message)
  end

  def test_bool_accepts_common_values
    %w[true false 1 0 yes no TRUE False].each do |v|
      assert check("DEBUG: bool", { "DEBUG" => v }).ok?, "expected #{v.inspect} to be valid bool"
    end
    r = check("DEBUG: bool", { "DEBUG" => "nope" })
    assert_equal [%(env var 'DEBUG' = "nope" is not a valid bool (expected true/false/1/0/yes/no))], r.errors.map(&:message)
  end

  def test_enum_validates_membership
    assert check("TIER: enum(free, pro)", { "TIER" => "pro" }).ok?
    r = check("TIER: enum(free, pro)", { "TIER" => "team" })
    assert_equal [%(env var 'TIER' = "team" is not in enum(free, pro))], r.errors.map(&:message)
  end

  def test_url_validation
    %w[postgres://u:p@h:5432/db redis://h:6379/0 https://x.y].each do |v|
      assert check("U: url", { "U" => v }).ok?, v
    end
    ["localhost:3000", "not a url"].each do |v|
      refute check("U: url", { "U" => v }).ok?, v
    end
    assert_equal [%(env var 'U' = "x" is not a valid url)], check("U: url", { "U" => "x" }).errors.map(&:message)
  end

  # ── secret masking ────────────────────────────────────────────────

  def test_secret_value_never_in_message
    r = check("[secrets]\nDB_PORT: int", { "DB_PORT" => "hunter2" })
    assert_equal "env var 'DB_PORT' (secret) is not a valid int", r.errors.first.message
    assert_nil r.errors.first.value
    assert r.errors.first.secret
  end

  def test_secret_enum_masked
    r = check("[secrets]\nT: enum(a, b)", { "T" => "hunter2" })
    assert_equal "env var 'T' (secret) is not in enum(a, b)", r.errors.first.message
  end

  def test_configmap_value_kept_on_problem
    assert_equal "abc", check("PORT: int", { "PORT" => "abc" }).errors.first.value
  end

  def test_message_format_can_reveal
    r = check("[secrets]\nDB_PORT: int", { "DB_PORT" => "hunter2" })
    assert_equal %(env var 'DB_PORT' = "hunter2" is not a valid int),
                 EnvPact::Message.format(r.errors.first, value: "hunter2")
  end

  def test_check_bang_message_masks_secrets
    err = assert_raises(EnvPact::ValidationError) do
      spec("[secrets]\nP: int").check!({ "P" => "hunter2" }, env: "x")
    end
    refute_match(/hunter2/, err.message)
  end

  # ── env scoping ───────────────────────────────────────────────────

  def test_env_specific_key_only_required_in_that_env
    text = "APP_NAME\n[env: production]\nDB_HOST"
    assert check(text, { "APP_NAME" => "x" }, env: "staging").ok?
    assert check(text, { "APP_NAME" => "x", "DB_HOST" => "db" }, env: "production").ok?
    assert_equal ["DB_HOST"], check(text, { "APP_NAME" => "x" }, env: "production").errors.map(&:key)
  end

  def test_secret_required_too
    refute check("[secrets]\nDB_PASS", {}).ok?
    assert check("[secrets]\nDB_PASS", { "DB_PASS" => "hunter2" }).ok?
  end

  def test_applied_sections
    text = "A\n[env: production]\nB"
    assert_equal %w[shared production], check(text, { "A" => "1", "B" => "1" }, env: "production").applied_sections
    assert_equal %w[shared], check(text, { "A" => "1" }, env: "prod").applied_sections
  end

  def test_applied_sections_counts_secret_only_sections
    assert_equal %w[shared staging], check("[env: staging]\n[secrets]\nS", { "S" => "1" }, env: "staging").applied_sections
  end

  def test_result_env
    assert_equal "prod", check("A", { "A" => "1" }, env: "prod").env
  end

  # ── extras ────────────────────────────────────────────────────────

  def test_extras_are_warnings_by_default
    r = check("A", { "A" => "1", "B" => "2" })
    assert r.ok?
    assert_equal ["unknown env var 'B' (not declared in spec)"], r.warnings.map(&:message)
    assert_nil r.warnings.first.value
  end

  def test_extras_are_errors_when_strict
    r = check("A", { "A" => "1", "B" => "2" }, strict: true)
    refute r.ok?
    assert_equal [:extra], r.errors.map(&:kind)
  end

  def test_extras_false_ignores_unknown_keys
    r = check("A", { "A" => "1", "PATH" => "/bin" }, extras: false, strict: true)
    assert r.ok?
    assert_empty r.warnings
  end

  def test_lowercase_extras_ignored
    assert_empty check("A", { "A" => "1", "lower" => "x" }).warnings
  end

  # ── aggregation / bang ───────────────────────────────────────────

  def test_aggregates_all_problems
    r = check("APP_NAME\nPORT: int\n[secrets]\nDB_PASS", { "PORT" => "abc" })
    assert_equal 3, r.errors.size
  end

  def test_check_bang_raises_with_result
    err = assert_raises(EnvPact::ValidationError) { spec("A").check!({}, env: "x") }
    assert_equal [:missing], err.result.errors.map(&:kind)
    assert_match(/missing required env var 'A'/, err.message)
  end

  def test_check_bang_returns_result_when_ok
    assert spec("A").check!({ "A" => "1" }, env: "x").ok?
  end
end
