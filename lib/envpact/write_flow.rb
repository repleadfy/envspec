class EnvPact
  # The one path every write to OpenBao goes through: validate, show what
  # will happen, get a human yes on the terminal, then the passphrase of the
  # write token, then the write. Nothing reaches the network before the yes.
  class WriteFlow
    def initialize(spec:, env:, prompt:, out: $stdout, err: $stderr)
      @spec   = spec
      @env    = env
      @prompt = prompt
      @out    = out
      @err    = err
    end

    # values: Hash{String=>String}. Returns the exit code (0 or 1).
    def call(values)
      unless @prompt.available?
        @err.puts "envpact: #{Prompt::NO_TTY}"
        return 1
      end

      ref = @spec.source_for(@env)
      raise Error, "no [source] for env '#{@env}' in env.spec" if ref.nil?

      problems = validate(values)
      unless problems.empty?
        @err.puts "envpact: nothing written; #{problems.size} problem(s):"
        problems.each { |text| @err.puts "  - #{text}" }
        return 1
      end
      if values.empty?
        @err.puts "envpact: nothing to write"
        return 1
      end

      Credentials.require_keyfile!(:write)
      keys = values.keys.sort
      @out.puts "openbao:#{ref.mount}/#{ref.path} (env: #{@env}) ← #{keys.join(', ')} (merge; existing keys kept)"
      unless @prompt.confirm("Write #{keys.size} #{keys.size == 1 ? 'key' : 'keys'}? [y/N] ")
        @err.puts "envpact: aborted, nothing written"
        return 1
      end

      client = Credentials.new(prompt: @prompt).write_client(ref.addr)
      client.write(ref.mount, ref.path, values)
      @out.puts "✓ wrote #{keys.size} #{keys.size == 1 ? 'key' : 'keys'}"
      0
    end

    private

    # Texts name keys and types only, never values.
    def validate(values)
      secrets   = @spec.secrets_for(@env)
      configmap = @spec.configmap_for(@env)
      values.keys.sort.each_with_object([]) do |key, problems|
        entry = secrets[key]
        if entry.nil?
          problems << (configmap.key?(key) ? "'#{key}' is a ConfigMap key in env '#{@env}', not a secret" :
                                             "'#{key}' is not declared in env.spec for env '#{@env}'")
        elsif values[key].nil? || values[key].empty?
          problems << "'#{key}' has an empty value"
        elsif values[key].include?("\0")
          problems << "'#{key}' contains a NUL byte"
        elsif !Types.valid?(values[key], entry.type, entry.enum_values)
          problems << "env var '#{key}' (secret) #{Message.invalid_reason(entry.type, entry.enum_values)}"
        end
      end
    end
  end
end
