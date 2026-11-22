require_relative "test_helper"
require "tmpdir"

class TestDotenv < Minitest::Test
  def parse(text)
    EnvPact::Dotenv.parse(text)
  end

  def test_parse_basic
    text = <<~'ENV'
      A=1
      export B="two words"
      C='lit $X'
      # comment

      D=x # tail
    ENV
    assert_equal({ "A" => "1", "B" => "two words", "C" => "lit $X", "D" => "x" }, parse(text))
  end

  def test_parse_keeps_equals_in_value
    assert_equal "abc==", parse("TOKEN=abc==")["TOKEN"]
  end

  def test_parse_crlf
    assert_equal({ "A" => "1", "B" => "2" }, parse("A=1\r\nB=2\r\n"))
  end

  def test_parse_double_quote_escapes
    # .env text: A="a\nb\"c"  →  value: a<newline>b"c
    assert_equal "a\nb\"c", parse('A="a\\nb\\"c"')["A"]
  end

  def test_parse_hash_inside_unquoted_value_kept
    assert_equal "http://x/a#frag", parse("URL=http://x/a#frag")["URL"]
  end

  def test_parse_empty_value
    assert_equal({ "A" => "" }, parse("A=\n"))
  end

  def test_parse_empty_value_with_comment
    assert_equal({ "SENTRY_DSN" => "" }, parse("SENTRY_DSN= # optional in dev\n"))
  end

  def test_lines_without_equals_ignored
    assert_equal({}, parse("garbage\n"))
  end

  def test_files_for
    assert_equal %w[.env .env.development .env.local .env.development.local],
                 EnvPact::Dotenv.files_for("development")
    assert_equal %w[.env .env.test .env.test.local], EnvPact::Dotenv.files_for("test")
  end

  def test_load_overrides_in_order_and_skips_missing
    Dir.mktmpdir do |d|
      File.write(File.join(d, ".env"), "A=1\nB=1\n")
      File.write(File.join(d, ".env.local"), "B=2\n")
      r = EnvPact::Dotenv.load(d, env: "development")
      assert_equal %w[.env .env.local], r[:files]
      assert_equal({ "A" => "1", "B" => "2" }, r[:values])
    end
  end

  def test_load_test_env_skips_dot_env_local
    Dir.mktmpdir do |d|
      File.write(File.join(d, ".env.local"), "B=2\n")
      File.write(File.join(d, ".env.test"), "A=1\n")
      r = EnvPact::Dotenv.load(d, env: "test")
      assert_equal %w[.env.test], r[:files]
      assert_equal({ "A" => "1" }, r[:values])
    end
  end

  def test_dump_roundtrip
    h = {
      "A" => "a\nb", "B" => 'q"q', "C" => 'back\\slash', "D" => "x # y", "E" => "trail ",
      "F" => "", "G" => "ünï", "H" => "lit\\nnewline", "I" => "'single'", "J" => "  lead",
      "K" => "tab\tbed", "L" => "a\\", "M" => "\\\\n", "N" => "#start", "O" => "=eq=", "P" => "$HOME ${X}"
    }
    assert_equal h, EnvPact::Dotenv.parse(EnvPact::Dotenv.dump(h))
  end

  def test_dump_is_sorted_and_quoted
    assert_equal %(A="1"\nB="2"\n), EnvPact::Dotenv.dump("B" => "2", "A" => "1")
  end

  def test_dump_escapes
    assert_equal %(A="a\\nb\\"c\\\\d"\n), EnvPact::Dotenv.dump("A" => "a\nb\"c\\d")
  end

  def test_dump_empty_hash
    assert_equal "", EnvPact::Dotenv.dump({})
  end

  def test_dump_rejects_cr
    err = assert_raises(EnvPact::Error) { EnvPact::Dotenv.dump("TOKEN" => "a\rb") }
    assert_includes err.message, "TOKEN"
    refute_includes err.message, "a\rb"
  end

  def test_dump_rejects_bad_key
    err = assert_raises(EnvPact::Error) { EnvPact::Dotenv.dump("A B" => "x") }
    assert_includes err.message, "A B"
  end

  def test_load_skips_given_file
    Dir.mktmpdir do |d|
      File.write(File.join(d, ".env"), "A=1\n")
      File.write(File.join(d, ".env.development.local"), "A=old\nB=old\n")
      r = EnvPact::Dotenv.load(d, env: "development", skip: [File.join(d, ".env.development.local")])
      assert_equal %w[.env], r[:files]
      assert_equal({ "A" => "1" }, r[:values])
    end
  end
end
