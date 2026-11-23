require_relative "test_helper"
require "tmpdir"

class TestConvert < Minitest::Test
  RICH = <<~SPEC.freeze
    # comment that does not survive
    APP_NAME
    LOG_LEVEL: enum(debug, info) = info
    DEBUG?: bool
    PORT: int = 3000
    GREETING = "hi # there "
    PUBLIC_URL: url(https, http)

    [source]
    openbao path=team/myapp/{env}
    openbao path=cluster/selly/myapp-web env=production addr=https://bao.example.com
    openbao path=cluster/x/y mount=kv env=staging,qa

    [secrets]
    DB_PASS
    DB_PORT: int

    [env: production]
    SENTRY_DSN: url
    [secrets]
    STRIPE_LIVE_KEY

    [env: production, staging]
    CDN_HOST
  SPEC

  def model(spec)
    strip = lambda do |bucket|
      bucket.transform_values { |keys| keys.transform_values { |e| [e.type, e.optional, e.default, e.enum_values] } }
    end
    { configmap: strip.call(spec.configmap), secrets: strip.call(spec.secrets),
      sources: spec.sources.map { |s| [s.backend, s.mount, s.path, s.addr, s.envs] }.sort_by(&:to_s) }
  end

  def test_round_trip_keeps_the_model
    spec = EnvPact.parse(RICH)
    yaml = spec.to_yaml_contract
    assert_equal model(spec), model(EnvPact.parse_yaml(yaml))
  end

  def test_output_is_grouped_and_readable
    yaml = EnvPact.parse(RICH).to_yaml_contract
    assert yaml.start_with?("version: 1\n")
    assert_includes yaml, "  \"production, staging\":\n"
    assert_includes yaml, "  DB_PASS:\n"
    assert_includes yaml, "  PUBLIC_URL: url(https, http)\n"
    assert_includes yaml, %(  LOG_LEVEL: {type: "enum(debug, info)", default: "info"}\n)
    refute_includes yaml, "comment that does not survive"
  end

  def test_promptune_like_contract
    spec = EnvPact.parse("DASH_URL: url(https)\n\n[source]\nopenbao path=cluster/selly/promptune-web addr=https://bao.leadfy.xyz\n\n[secrets]\nA\nDB_PORT: int\n")
    assert_equal <<~YAML, spec.to_yaml_contract
      version: 1

      source:
        openbao:
          path: "cluster/selly/promptune-web"
          addr: "https://bao.leadfy.xyz"

      vars:
        DASH_URL: url(https)

      secrets:
        A:
        DB_PORT: int
    YAML
  end

  def run_cli(*argv)
    code = nil
    out, err = capture_io { code = EnvPact::CLI.run(argv) }
    [code, out, err]
  end

  def test_cli_convert_writes_next_to_the_spec_and_refuses_to_overwrite
    Dir.mktmpdir do |d|
      File.write(File.join(d, "env.spec"), "A\n[secrets]\nB\n")
      Dir.chdir(d) do
        code, out, err = run_cli("convert")
        assert_equal 0, code, err
        assert_includes out, "wrote envpact.yml"
        assert_includes out, "delete env.spec"
        assert_equal %w[A], EnvPact.parse_file("envpact.yml").configmap_for("x").keys
        code, _, err = run_cli("convert", "--spec=env.spec")
        assert_equal 1, code
        assert_includes err, "envpact.yml already exists"
      end
    end
  end

  def test_cli_convert_refuses_a_yaml_input
    Dir.mktmpdir do |d|
      File.write(File.join(d, "envpact.yml"), "version: 1\n")
      Dir.chdir(d) do
        code, _, err = run_cli("convert")
        assert_equal 1, code
        assert_includes err, "convert reads an env.spec"
      end
    end
  end
end
