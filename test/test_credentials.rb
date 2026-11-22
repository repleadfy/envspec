require_relative "test_helper"
require_relative "support/tmp_home"
require_relative "support/fake_prompt"
require "fileutils"

class TestCredentials < Minitest::Test
  include TmpHome

  PASS = "correct horse battery".freeze

  def setup
    super
    @sockdir = Dir.mktmpdir("epc")
    @old_sock = ENV["ENVPACT_AGENT_SOCK"]
    ENV["ENVPACT_AGENT_SOCK"] = File.join(@sockdir, "a.sock")
  end

  def teardown
    EnvPact::Agent.request("lock")
    sleep 0.1
    ENV["ENVPACT_AGENT_SOCK"] = @old_sock
    FileUtils.remove_entry(@sockdir)
    super
  end

  def keyfile(kind, token)
    EnvPact::Keyfile.write(kind, token: token, addr: "http://file.test", role: "r", expire_time: nil,
                                 passphrase: PASS, iterations: 1_000)
  end

  def creds(prompt)
    EnvPact::Credentials.new(prompt: prompt)
  end

  def test_credentials_prefers_agent
    EnvPact::Agent.start(token: "agent-tok", addr: "http://agent.test", until_time: Time.now + 30)
    prompt = FakePrompt.new
    assert_equal({ token: "agent-tok", addr: "http://agent.test" }, creds(prompt).read_token)
    assert_empty prompt.labels
  end

  def test_read_token_falls_back_to_keyfile_with_passphrase
    keyfile(:read, "file-tok")
    prompt = FakePrompt.new(secrets: [PASS])
    assert_equal({ token: "file-tok", addr: "http://file.test" }, creds(prompt).read_token)
    assert_equal 1, prompt.labels.size
    assert_includes prompt.labels.first, "~/.ob_read"
  end

  def test_read_token_without_keyfile_does_not_prompt
    prompt = FakePrompt.new
    err = assert_raises(EnvPact::Error) { creds(prompt).read_token }
    assert_equal "no ~/.ob_read; run envpact login --read", err.message
    assert_empty prompt.labels
  end

  def test_read_token_wrong_passphrase
    keyfile(:read, "file-tok")
    assert_raises(EnvPact::Error) { creds(FakePrompt.new(secrets: ["wrong wrong wrong"])).read_token }
  end

  def test_write_token_ignores_agent
    EnvPact::Agent.start(token: "agent-tok", addr: "http://agent.test", until_time: Time.now + 30)
    keyfile(:write, "write-tok")
    prompt = FakePrompt.new(secrets: [PASS])
    assert_equal({ token: "write-tok", addr: "http://file.test" }, creds(prompt).write_token)
    assert_equal 1, prompt.labels.size
    assert_includes prompt.labels.first, "~/.ob_write"
  end
end
