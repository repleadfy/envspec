require_relative "test_helper"
require "tmpdir"

class TestAtomicFile < Minitest::Test
  def with_dir
    Dir.mktmpdir("envpact-af") { |d| yield d }
  end

  def test_writes_content_0600_even_with_loose_umask
    with_dir do |d|
      old = File.umask(0o022)
      begin
        path = File.join(d, "out")
        EnvPact::AtomicFile.write(path, "hello")
        assert_equal "hello", File.read(path)
        assert_equal 0o600, File.stat(path).mode & 0o777
      ensure
        File.umask(old)
      end
    end
  end

  def test_overwrite_replaces_and_keeps_0600
    with_dir do |d|
      path = File.join(d, "out")
      File.write(path, "old")
      File.chmod(0o644, path)
      EnvPact::AtomicFile.write(path, "new")
      assert_equal "new", File.read(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  def test_atomic_refuses_symlink
    with_dir do |d|
      target = File.join(d, "target")
      File.write(target, "keep")
      link = File.join(d, "link")
      File.symlink(target, link)
      err = assert_raises(EnvPact::Error) { EnvPact::AtomicFile.write(link, "x") }
      assert_equal "refusing to write through symlink #{link}", err.message
      assert_equal "keep", File.read(target)
    end
  end

  def test_atomic_leaves_no_tmp_on_success
    with_dir do |d|
      EnvPact::AtomicFile.write(File.join(d, "out"), "x")
      assert_equal ["out"], Dir.children(d)
    end
  end

  def test_atomic_leaves_no_tmp_on_failure
    with_dir do |d|
      # A directory at the target makes rename fail after the temp was written.
      path = File.join(d, "out")
      Dir.mkdir(path)
      assert_raises(SystemCallError) { EnvPact::AtomicFile.write(path, "x") }
      assert_equal ["out"], Dir.children(d)
    end
  end

  def test_missing_directory_is_an_error
    assert_raises(SystemCallError) { EnvPact::AtomicFile.write("/nonexistent-envpact-dir/x", "x") }
  end
end
