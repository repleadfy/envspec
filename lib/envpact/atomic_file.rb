class EnvPact
  # Writes a file that is 0600 from its first byte, via a temp file in the
  # same directory and a rename, so readers never see a partial file.
  module AtomicFile
    def self.write(path, content)
      raise Error, "refusing to write through symlink #{path}" if File.symlink?(path)

      dir = File.dirname(path)
      tmp = File.join(dir, ".#{File.basename(path)}.#{Process.pid}.tmp")
      done = false
      begin
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
          f.chmod(0o600) # the umask can only remove bits, but be explicit
          f.binmode
          f.write(content)
          f.flush
          f.fsync
        end
        File.rename(tmp, path)
        done = true
      ensure
        File.unlink(tmp) if !done && (File.exist?(tmp) || File.symlink?(tmp))
      end
      nil
    end
  end
end
