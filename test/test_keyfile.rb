require_relative "test_helper"
require_relative "support/tmp_home"
require "json"

class TestKeyfile < Minitest::Test
  include TmpHome

  TOKEN = "s.t0k-abcdef".freeze
  PASS  = "correct horse battery".freeze

  def write(kind = :read, **over)
    EnvPact::Keyfile.write(kind, **{ token: TOKEN, addr: "http://bao.test:8200", role: "leitura",
                                     expire_time: "2026-11-23T03:00:00Z", passphrase: PASS,
                                     iterations: 1_000 }.merge(over))
  end

  def path(kind = :read)
    EnvPact::Keyfile.path(kind)
  end

  def test_paths
    assert_equal File.join(@home, ".ob_read"), path(:read)
    assert_equal File.join(@home, ".ob_write"), path(:write)
  end

  def test_roundtrip
    write
    got = EnvPact::Keyfile.read(:read, passphrase: PASS)
    assert_equal({ token: TOKEN, addr: "http://bao.test:8200", role: "leitura", expire_time: "2026-11-23T03:00:00Z" }, got)
    refute_includes File.read(path), TOKEN
  end

  def test_file_format
    write
    j = JSON.parse(File.read(path))
    assert_equal 1, j["v"]
    assert_equal "pbkdf2-sha256", j["kdf"]
    assert_equal 1_000, j["iter"]
    %w[salt iv tag ct addr role expire_time created_at].each { |k| assert j.key?(k), k }
    assert_equal "http://bao.test:8200", j["addr"]
  end

  def test_default_iterations_is_600k
    EnvPact::Keyfile.write(:read, token: TOKEN, addr: "http://a", role: nil, expire_time: nil, passphrase: PASS)
    assert_equal 600_000, JSON.parse(File.read(path))["iter"]
  end

  def test_wrong_passphrase
    write
    err = assert_raises(EnvPact::Error) { EnvPact::Keyfile.read(:read, passphrase: "nope nope nope") }
    assert_equal "wrong passphrase or corrupted ~/.ob_read", err.message
    refute_includes err.message, TOKEN
  end

  def test_tampered_meta_fails
    write
    j = JSON.parse(File.read(path))
    j["addr"] = "http://evil.test"
    File.write(path, JSON.generate(j))
    File.chmod(0o600, path)
    assert_raises(EnvPact::Error) { EnvPact::Keyfile.read(:read, passphrase: PASS) }
  end

  def test_garbage_file_is_corrupted
    File.write(path, "not json")
    File.chmod(0o600, path)
    err = assert_raises(EnvPact::Error) { EnvPact::Keyfile.read(:read, passphrase: PASS) }
    assert_equal "wrong passphrase or corrupted ~/.ob_read", err.message
  end

  def test_absurd_iteration_count_refused
    write
    j = JSON.parse(File.read(path))
    j["iter"] = 2_000_000_000
    File.write(path, JSON.generate(j))
    File.chmod(0o600, path)
    assert_raises(EnvPact::Error) { EnvPact::Keyfile.read(:read, passphrase: PASS) }
  end

  def test_read_file_is_not_a_write_file
    write(:read)
    FileUtils.cp(path(:read), path(:write))
    File.chmod(0o600, path(:write))
    err = assert_raises(EnvPact::Error) { EnvPact::Keyfile.read(:write, passphrase: PASS) }
    assert_equal "wrong passphrase or corrupted ~/.ob_write", err.message
  end

  def test_loose_mode_refused
    write
    File.chmod(0o644, path)
    err = assert_raises(EnvPact::Error) { EnvPact::Keyfile.read(:read, passphrase: PASS) }
    assert_equal "~/.ob_read is readable by others; chmod 600 ~/.ob_read", err.message
  end

  def test_group_readable_refused
    write
    File.chmod(0o640, path)
    assert_raises(EnvPact::Error) { EnvPact::Keyfile.read(:read, passphrase: PASS) }
  end

  def test_missing_file
    err = assert_raises(EnvPact::Error) { EnvPact::Keyfile.read(:read, passphrase: PASS) }
    assert_equal "no ~/.ob_read; run envpact login --read", err.message
    err = assert_raises(EnvPact::Error) { EnvPact::Keyfile.read(:write, passphrase: PASS) }
    assert_equal "no ~/.ob_write; run envpact login --write", err.message
  end

  def test_file_created_0600
    old = File.umask(0o022)
    begin
      write
    ensure
      File.umask(old)
    end
    assert_equal 0o600, File.stat(path).mode & 0o777
  end

  def test_meta_reads_without_passphrase
    write
    assert_equal({ addr: "http://bao.test:8200", role: "leitura", expire_time: "2026-11-23T03:00:00Z" },
                 EnvPact::Keyfile.meta(:read))
  end

  def test_meta_nil_when_absent_or_garbage
    assert_nil EnvPact::Keyfile.meta(:read)
    File.write(path, "junk")
    assert_nil EnvPact::Keyfile.meta(:read)
  end

  def test_empty_passphrase_refused
    assert_raises(EnvPact::Error) { write(passphrase: "") }
    refute File.exist?(path)
  end

  def test_non_ascii_passphrase_and_token
    write(token: "tök€n", passphrase: "pässwörd-ünï-12")
    assert_equal "tök€n", EnvPact::Keyfile.read(:read, passphrase: "pässwörd-ünï-12")[:token]
  end

  def test_write_replaces_previous_file
    write(token: "first")
    write(token: "second")
    assert_equal "second", EnvPact::Keyfile.read(:read, passphrase: PASS)[:token]
  end
end
