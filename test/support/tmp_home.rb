require "tmpdir"
require "fileutils"

# Points $HOME at a fresh tmpdir for the duration of a test.
module TmpHome
  def setup
    super
    @old_home = ENV["HOME"]
    @home = Dir.mktmpdir("envpact-home")
    ENV["HOME"] = @home
  end

  def teardown
    ENV["HOME"] = @old_home
    FileUtils.remove_entry(@home) if @home && File.exist?(@home)
    super
  end
end
