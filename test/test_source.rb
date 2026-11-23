require_relative "test_helper"
require_relative "support/fake_bao"

class TestSource < Minitest::Test
  SPEC = <<~SPEC.freeze
    PORT: int = 3000
    [source]
    openbao path=team/app/{env}
    [secrets]
    DB_PASS
    OPT?
  SPEC

  def setup
    @bao = FakeBao.new
    @client = EnvPact::OpenBao::Client.new(addr: @bao.addr, token: "t0k")
  end

  def teardown
    @bao.stop
  end

  def kv(data)
    { "data" => { "data" => data } }
  end

  def test_fetch_filters_to_secrets_of_env
    @bao.on("GET", "/v1/secret/data/team/app/dev", body: kv("DB_PASS" => "s3cr3t", "PORT" => "9", "JUNK" => "j"))
    warnings = []
    got = EnvPact::Source.fetch(EnvPact.parse(SPEC), env: "dev", client: @client, warnings: warnings)
    assert_equal({ "DB_PASS" => "s3cr3t" }, got)
    assert_equal %w[JUNK PORT], warnings.map(&:key).sort
    assert(warnings.all? { |w| w.kind == :extra && w.value.nil? })
    text = warnings.map(&:message).join("\n")
    assert_includes text, "PORT"
    assert_includes text, "JUNK"
    refute_includes text, "s3cr3t"
  end

  def test_fetch_without_warnings_array
    @bao.on("GET", "/v1/secret/data/team/app/dev", body: kv("DB_PASS" => "x", "JUNK" => "j"))
    assert_equal({ "DB_PASS" => "x" }, EnvPact::Source.fetch(EnvPact.parse(SPEC), env: "dev", client: @client))
  end

  def test_missing_path_is_empty
    assert_equal({}, EnvPact::Source.fetch(EnvPact.parse(SPEC), env: "dev", client: @client))
  end

  def test_no_source_is_error
    err = assert_raises(EnvPact::Error) { EnvPact::Source.fetch(EnvPact.parse("[secrets]\nA\n"), env: "dev", client: @client) }
    assert_equal "no source for env 'dev' in the contract", err.message
  end

  def test_uses_mount_and_env_specific_path
    spec = EnvPact.parse("[source]\nopenbao path=a/{env}\nopenbao path=c/web mount=kv env=production\n[secrets]\nK\n")
    @bao.on("GET", "/v1/kv/data/c/web", body: kv("K" => "v"))
    assert_equal({ "K" => "v" }, EnvPact::Source.fetch(spec, env: "production", client: @client))
  end

  def test_only_reads_the_declared_env_secrets
    spec = EnvPact.parse("[source]\nopenbao path=a/{env}\n[secrets]\nA\n[env: production]\n[secrets]\nB\n")
    @bao.on("GET", "/v1/secret/data/a/dev", body: kv("A" => "1", "B" => "2"))
    assert_equal({ "A" => "1" }, EnvPact::Source.fetch(spec, env: "dev", client: @client))
  end
end
