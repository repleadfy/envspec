require_relative "test_helper"

class TestYamlParser < Minitest::Test
  def parse(text)
    EnvPact.parse_yaml(text)
  end

  def assert_raises_parse(msg_pattern, &block)
    err = assert_raises(EnvPact::ParseError, &block)
    assert_match msg_pattern, err.message
    err
  end

  # The model without line numbers, to compare both formats.
  def model(spec)
    strip = lambda do |bucket|
      bucket.transform_values do |keys|
        keys.transform_values { |e| [e.type, e.optional, e.default, e.enum_values] }
      end
    end
    {
      configmap: strip.call(spec.configmap),
      secrets: strip.call(spec.secrets),
      sources: spec.sources.map { |s| [s.backend, s.mount, s.path, s.addr, s.envs] }
    }
  end

  # ── basics ───────────────────────────────────────────────────────

  def test_empty_document_is_an_empty_contract
    spec = parse("version: 1\n")
    assert_empty spec.configmap
    assert_empty spec.secrets
    assert_empty spec.sources
  end

  def test_version_is_required_and_must_be_1
    assert_raises_parse(/version/) { parse("vars:\n  A:\n") }
    assert_raises_parse(/version.*1/) { parse("version: 2\n") }
  end

  def test_top_level_must_be_a_mapping
    assert_raises_parse(/mapping/) { parse("- a\n- b\n") }
  end

  def test_empty_value_is_required_str
    e = parse("version: 1\nvars:\n  APP_NAME:\n").configmap["*"]["APP_NAME"]
    assert_equal :str, e.type
    refute e.optional
    assert_nil e.default
  end

  def test_shorthand_types
    spec = parse(<<~YAML)
      version: 1
      vars:
        A: int
        B: bool
        C: url
        D: url(https, http)
        E: enum(debug, info)
        F: str
    YAML
    cm = spec.configmap["*"]
    assert_equal :int, cm["A"].type
    assert_equal :bool, cm["B"].type
    assert_equal [:url, nil], [cm["C"].type, cm["C"].enum_values]
    assert_equal [:url, %w[https http]], [cm["D"].type, cm["D"].enum_values]
    assert_equal [:enum, %w[debug info]], [cm["E"].type, cm["E"].enum_values]
    assert_equal :str, cm["F"].type
  end

  def test_long_form
    e = parse(<<~YAML).configmap["*"]["PORT"]
      version: 1
      vars:
        PORT: {type: int, default: "3000", optional: true, description: "http port"}
    YAML
    assert_equal :int, e.type
    assert e.optional
    assert_equal "3000", e.default
    assert_equal "http port", e.description
  end

  def test_line_numbers_point_at_the_key
    spec = parse("version: 1\nvars:\n  A:\n  B: int\nsecrets:\n  S:\n")
    assert_equal 3, spec.configmap["*"]["A"].line
    assert_equal 4, spec.configmap["*"]["B"].line
    assert_equal 6, spec.secrets["*"]["S"].line
  end

  # ── YAML traps: scalars are raw text ─────────────────────────────

  def test_scalars_are_raw_text_not_yaml_coerced
    cm = parse(<<~YAML).configmap["*"]
      version: 1
      vars:
        TAG: {default: 0.30}
        FLAG: {type: bool, default: no}
        ON_OFF: {type: "enum(on, off)", default: on}
        PORT: {type: int, default: 0800}
    YAML
    assert_equal "0.30", cm["TAG"].default
    assert_equal "no", cm["FLAG"].default
    assert_equal "on", cm["ON_OFF"].default
    assert_equal "0800", cm["PORT"].default
  end

  def test_optional_accepts_only_true_or_false
    assert parse("version: 1\nvars:\n  A: {optional: true}\n").configmap["*"]["A"].optional
    refute parse("version: 1\nvars:\n  A: {optional: false}\n").configmap["*"]["A"].optional
    assert_raises_parse(/optional.*true or false/) { parse("version: 1\nvars:\n  A: {optional: yes}\n") }
  end

  def test_quoted_default_keeps_hash_and_spaces
    e = parse(%(version: 1\nvars:\n  G: {default: "hi # there "}\n)).configmap["*"]["G"]
    assert_equal "hi # there ", e.default
  end

  def test_explicit_null_is_empty_value
    assert_equal :str, parse("version: 1\nvars:\n  A: ~\n  B: null\n").configmap["*"]["B"].type
  end

  # ── errors ───────────────────────────────────────────────────────

  def test_invalid_key_name
    assert_raises_parse(/line 3.*invalid key name 'lower'/) { parse("version: 1\nvars:\n  lower:\n") }
  end

  def test_unknown_top_level_key
    assert_raises_parse(/line 2.*unknown key 'varz'/) { parse("version: 1\nvarz:\n  A:\n") }
  end

  def test_unknown_field_in_long_form
    assert_raises_parse(/line 3.*unknown field 'requird'/) { parse("version: 1\nvars:\n  A: {requird: true}\n") }
  end

  def test_comma_inside_flow_mapping_gets_a_hint
    assert_raises_parse(/quote the type/) { parse("version: 1\nvars:\n  L: {type: enum(a, b)}\n") }
  end

  def test_unknown_type
    assert_raises_parse(/line 3.*unknown type 'float'/) { parse("version: 1\nvars:\n  A: float\n") }
  end

  def test_secret_cannot_have_default_and_value_is_not_echoed
    err = assert_raises_parse(/line 3.*secret 'TOKEN' cannot have a default/) do
      parse("version: 1\nsecrets:\n  TOKEN: {default: sk-live-abc123}\n")
    end
    refute_includes err.message, "sk-live-abc123"
  end

  def test_bad_default_type
    assert_raises_parse(/line 3.*default "abc" for 'PORT'/) { parse("version: 1\nvars:\n  PORT: {type: int, default: abc}\n") }
  end

  def test_duplicate_key_in_same_mapping
    assert_raises_parse(/line 4.*duplicate key 'A'/) { parse("version: 1\nvars:\n  A:\n  A: int\n") }
  end

  def test_key_in_vars_and_secrets
    assert_raises_parse(/'A' declared as both configmap/) { parse("version: 1\nvars:\n  A:\nsecrets:\n  A:\n") }
  end

  def test_alias_anchor_and_tags_are_refused
    assert_raises_parse(/anchors and aliases/) { parse("version: 1\nvars: &v\n  A:\nsecrets: *v\n") }
    assert_raises_parse(/tags/) { parse("version: 1\nvars:\n  A: !!str int\n") }
  end

  def test_yaml_syntax_error_reports_line_without_content
    err = assert_raises_parse(/YAML syntax error at line \d+/) { parse("version: 1\nvars:\n  A: [unclosed sk-live-xyz\n") }
    refute_includes err.message, "sk-live-xyz"
  end

  # ── source and envs ──────────────────────────────────────────────

  def test_shared_source
    spec = parse(<<~YAML)
      version: 1
      source:
        openbao:
          path: team/app/{env}
          addr: https://bao.example.com
    YAML
    ref = spec.source_for("staging")
    assert_equal ["openbao", "secret", "team/app/staging", "https://bao.example.com"], [ref.backend, ref.mount, ref.path, ref.addr]
  end

  def test_env_source_overrides_shared
    spec = parse(<<~YAML)
      version: 1
      source: {openbao: {path: "team/app/{env}"}}
      envs:
        production:
          source: {openbao: {path: cluster/selly/app, mount: kv}}
    YAML
    assert_equal ["kv", "cluster/selly/app"], [spec.source_for("production").mount, spec.source_for("production").path]
    assert_equal "team/app/dev", spec.source_for("dev").path
  end

  def test_source_errors
    assert_raises_parse(/line 3.*unknown backend 'vault'/) { parse("version: 1\nsource:\n  vault: {path: a}\n") }
    assert_raises_parse(/needs path/) { parse("version: 1\nsource:\n  openbao: {addr: https://x.y}\n") }
    assert_raises_parse(/invalid path/) { parse("version: 1\nsource:\n  openbao: {path: ../x}\n") }
    assert_raises_parse(/unknown option 'pth'/) { parse("version: 1\nsource:\n  openbao: {path: a, pth: b}\n") }
  end

  def test_envs_scope_and_multi_env_key
    spec = parse(<<~YAML)
      version: 1
      vars:
        APP:
      envs:
        production:
          vars: {SENTRY_DSN: url}
          secrets: {STRIPE: }
        "staging, production":
          vars: {CDN_HOST: }
    YAML
    assert_equal %w[production staging], spec.envs
    assert_equal %w[APP CDN_HOST SENTRY_DSN], spec.configmap_for("production").keys.sort
    assert_equal %w[APP CDN_HOST], spec.configmap_for("staging").keys.sort
    assert_equal %w[STRIPE], spec.secrets_for("production").keys
  end

  def test_env_key_overlapping_shared_is_refused
    assert_raises_parse(/overlapping scopes/) do
      parse("version: 1\nvars:\n  A:\nenvs:\n  production:\n    vars: {A: int}\n")
    end
  end

  def test_invalid_env_name
    assert_raises_parse(/invalid env name 'prod uction'/) { parse("version: 1\nenvs:\n  prod uction:\n    vars: {A: }\n") }
  end

  # ── parity with env.spec ─────────────────────────────────────────

  def test_same_contract_same_model_as_env_spec
    spec_text = <<~SPEC
      APP_NAME
      LOG_LEVEL: enum(debug, info) = info
      DEBUG?: bool
      PORT: int = 3000
      PUBLIC_URL: url(https)

      [source]
      openbao path=team/myapp/{env}
      openbao path=cluster/selly/myapp-web env=production addr=https://bao.example.com

      [secrets]
      DB_PASS

      [env: production]
      SENTRY_DSN: url
      [secrets]
      STRIPE_LIVE_KEY

      [env: production, staging]
      CDN_HOST
    SPEC
    yaml_text = <<~YAML
      version: 1
      source:
        openbao: {path: "team/myapp/{env}"}
      vars:
        APP_NAME:
        LOG_LEVEL: {type: "enum(debug, info)", default: info}
        DEBUG: {type: bool, optional: true}
        PORT: {type: int, default: "3000"}
        PUBLIC_URL: url(https)
      secrets:
        DB_PASS:
      envs:
        production:
          source: {openbao: {path: cluster/selly/myapp-web, addr: "https://bao.example.com"}}
          vars: {SENTRY_DSN: url}
          secrets: {STRIPE_LIVE_KEY: }
        production, staging:
          vars: {CDN_HOST: }
    YAML
    assert_equal model(EnvPact.parse(spec_text)), model(parse(yaml_text))
  end
end
