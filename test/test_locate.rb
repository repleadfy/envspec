require_relative "test_helper"
require "tmpdir"

class TestLocate < Minitest::Test
  def in_dir(files)
    Dir.mktmpdir do |d|
      files.each { |n| File.write(File.join(d, n), "version: 1\n") }
      yield d
    end
  end

  def test_prefers_envpact_yml
    in_dir(%w[envpact.yml]) do |d|
      assert_equal [File.join(d, "envpact.yml"), false], EnvPact.locate(d)
    end
  end

  def test_falls_back_to_legacy_env_spec
    in_dir(%w[env.spec]) do |d|
      assert_equal [File.join(d, "env.spec"), true], EnvPact.locate(d)
    end
  end

  def test_both_files_is_an_error
    in_dir(%w[envpact.yml env.spec]) do |d|
      err = assert_raises(EnvPact::Error) { EnvPact.locate(d) }
      assert_match(/both envpact.yml and env.spec/, err.message)
    end
  end

  def test_neither_returns_the_yaml_path_not_legacy
    in_dir([]) do |d|
      assert_equal [File.join(d, "envpact.yml"), false], EnvPact.locate(d)
    end
  end

  def test_parse_file_picks_the_format_by_extension
    Dir.mktmpdir do |d|
      y = File.join(d, "envpact.yml")
      File.write(y, "version: 1\nsecrets:\n  DB_PASS:\n")
      s = File.join(d, "env.spec")
      File.write(s, "[secrets]\nDB_PASS\n")
      assert_equal ["DB_PASS"], EnvPact.parse_file(y).secrets_for("x").keys
      assert_equal ["DB_PASS"], EnvPact.parse_file(s).secrets_for("x").keys
    end
  end
end
