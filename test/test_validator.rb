require_relative "test_helper"

class TestValidator < Minitest::Test
  def spec(text)
    EnvSpec.parse(text)
  end

  # ── presence ──────────────────────────────────────────────────────

  def test_passes_when_all_required_present
    s = spec("APP_NAME\nPORT: int")
    assert s.validate!({ "APP_NAME" => "leadfy", "PORT" => "3000" })
  end

  def test_missing_required_fails
    s = spec("APP_NAME")
    err = assert_raises(EnvSpec::ValidationError) { s.validate!({}) }
    assert_match(/missing required env var 'APP_NAME'/, err.message)
  end

  def test_missing_optional_ok
    s = spec("DEBUG?: bool")
    assert s.validate!({})
  end

  def test_missing_with_default_ok
    s = spec("LOG_LEVEL: str = info")
    assert s.validate!({})
  end

  def test_empty_string_treated_as_missing
    s = spec("APP_NAME")
    assert_raises(EnvSpec::ValidationError) { s.validate!({ "APP_NAME" => "" }) }
  end

  # ── type checks ───────────────────────────────────────────────────

  def test_int_parses
    s = spec("PORT: int")
    assert s.validate!({ "PORT" => "3000" })
    err = assert_raises(EnvSpec::ValidationError) { s.validate!({ "PORT" => "abc" }) }
    assert_match(/not a valid int/, err.message)
  end

  def test_bool_accepts_common_values
    s = spec("DEBUG: bool")
    %w[true false 1 0 yes no TRUE False].each do |v|
      assert s.validate!({ "DEBUG" => v }), "expected #{v.inspect} to be valid bool"
    end
    assert_raises(EnvSpec::ValidationError) { s.validate!({ "DEBUG" => "nope" }) }
  end

  def test_enum_validates_membership
    s = spec("TIER: enum(free, pro, enterprise)")
    assert s.validate!({ "TIER" => "pro" })
    err = assert_raises(EnvSpec::ValidationError) { s.validate!({ "TIER" => "team" }) }
    assert_match(/not in enum/, err.message)
  end

  def test_dsn_treated_as_string
    s = spec("[secrets]\nDATABASE_URL: dsn")
    assert s.validate!({ "DATABASE_URL" => "postgres://user:pass@host/db" })
  end

  # ── env scoping ───────────────────────────────────────────────────

  def test_env_specific_key_only_required_in_that_env
    s = spec(<<~SPEC)
      APP_NAME

      [env: production]
      DB_HOST
    SPEC

    assert s.validate!({ "APP_NAME" => "x" }, env: "staging")
    assert s.validate!({ "APP_NAME" => "x", "DB_HOST" => "db.local" }, env: "production")
    err = assert_raises(EnvSpec::ValidationError) do
      s.validate!({ "APP_NAME" => "x" }, env: "production")
    end
    assert_match(/DB_HOST/, err.message)
  end

  def test_secret_required_too
    s = spec("[secrets]\nDB_PASS")
    assert_raises(EnvSpec::ValidationError) { s.validate!({}) }
    assert s.validate!({ "DB_PASS" => "hunter2" })
  end

  # ── strict mode ───────────────────────────────────────────────────

  def test_strict_flags_extras
    s = spec("APP_NAME")
    err = assert_raises(EnvSpec::ValidationError) do
      s.validate!({ "APP_NAME" => "x", "EXTRA_VAR" => "y" }, strict: true)
    end
    assert_match(/unknown env var 'EXTRA_VAR'/, err.message)
  end

  def test_non_strict_ignores_extras
    s = spec("APP_NAME")
    assert s.validate!({ "APP_NAME" => "x", "PATH" => "/usr/bin", "HOME" => "/root" })
  end

  # ── multiple problems aggregated ──────────────────────────────────

  def test_aggregates_all_problems
    s = spec("APP_NAME\nPORT: int\n[secrets]\nDB_PASS")
    err = assert_raises(EnvSpec::ValidationError) { s.validate!({ "PORT" => "abc" }) }
    assert_equal 3, err.problems.size
  end
end
