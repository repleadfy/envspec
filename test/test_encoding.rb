require_relative "test_helper"
require "open3"
require "tmpdir"

# Images that install Ruby from a distro package often run with no locale, so
# Ruby's default external encoding is US-ASCII. Files must still parse.
class TestEncoding < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BOM  = "\xEF\xBB\xBF".b

  def run_c_locale(dir, *args)
    env = { "LANG" => "C", "LC_ALL" => "C", "RUBYOPT" => nil }
    cmd = ["ruby", "-I#{ROOT}/lib", "#{ROOT}/exe/envpact", *args]
    out, err, status = Open3.capture3(env, *cmd, chdir: dir)
    [status.exitstatus, out, err]
  end

  def test_lint_spec_with_bom_and_non_ascii_comment_under_c_locale
    Dir.mktmpdir do |d|
      File.binwrite(File.join(d, "env.spec"), BOM + "# usuário do banco\nDB_USER\n".b)
      code, out, err = run_c_locale(d, "lint")
      assert_equal 0, code, err
      assert_match(/valid/, out)
    end
  end

  def test_check_dotenv_with_bom_under_c_locale
    Dir.mktmpdir do |d|
      File.binwrite(File.join(d, "env.spec"), "A\nB\n")
      File.binwrite(File.join(d, ".env"), BOM + "A=olá\nB=2\n".b)
      code, _, err = run_c_locale(d, "check", "--env=dev")
      assert_equal 0, code, err
    end
  end

  def test_dotenv_parse_strips_bom
    assert_equal({ "A" => "1", "B" => "2" }, EnvPact::Dotenv.parse("﻿A=1\nB=2\n"))
  end
end
