class EnvPact
  # Shared by `exec` and `run`: the last steps before handing the process to
  # the app.
  module Boot
    # Fills defaults for absent or empty keys of env into the process ENV.
    def self.fill_defaults(spec, env)
      spec.configmap_for(env).each do |key, entry|
        next if entry.default.nil?
        ENV[key] = entry.default if ENV[key].nil? || ENV[key].empty?
      end
    end

    # Replaces this process with argv. Only returns on failure, with the
    # exit code (127 not found, 126 not executable) after printing why.
    def self.exec_command(argv)
      Kernel.exec(*argv)
    rescue Errno::ENOENT
      warn "envpact: command not found: #{argv.first}"
      127
    rescue Errno::EACCES, Errno::ENOEXEC => e
      warn "envpact: cannot execute: #{argv.first} (#{e.message})"
      126
    end
  end
end
