class EnvPact
  # Reads the secrets of one env from where the spec's [source] says they
  # live. This is the API the deploy tooling uses.
  module Source
    # -> Hash{String=>String}: only the keys declared as secrets for env. Keys
    # in the source that are not declared secrets are dropped; when warnings
    # (an Array) is given, a Problem(kind: :extra, type: :source) without any
    # value is appended for each. A path that does not exist yields {}.
    def self.fetch(spec, env:, client:, warnings: nil)
      ref = spec.source_for(env)
      raise Error, "no [source] for env '#{env}' in env.spec" if ref.nil?

      data   = client.read(ref.mount, ref.path) || {}
      wanted = spec.secrets_for(env)
      data.each_key do |key|
        next if wanted.key?(key)
        warnings << Problem.new(kind: :extra, key: key, secret: false, type: :source) if warnings
      end
      data.select { |key, _| wanted.key?(key) }
    end
  end
end
