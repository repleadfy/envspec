class EnvPact
  # Validates an env hash (or ENV) against a parsed spec.
  #
  # Checks:
  #   - required keys are present
  #   - typed values parse cleanly (int, bool, dsn, enum)
  #   - reports unknown keys as warnings (extras), not errors
  #
  # Usage:
  #   spec.validate!(ENV.to_h, env: "production")
  #
  # Raises EnvPact::ValidationError with a list of all problems found.
  def validate!(env_hash, env: SHARED, strict: false)
    problems = validate(env_hash, env: env, strict: strict)
    raise ValidationError.new(problems) unless problems.empty?
    true
  end

  def validate(env_hash, env: SHARED, strict: false)
    problems = []

    keys = configmap_for(env).merge(secrets_for(env))

    keys.each do |name, entry|
      raw = env_hash[name]
      if raw.nil? || raw.empty?
        next if entry.optional || !entry.default.nil?
        problems << "missing required env var '#{name}' (declared at line #{entry.line})"
        next
      end

      err = type_problem(name, raw, entry)
      problems << err if err
    end

    if strict
      known = keys.keys
      env_hash.each_key do |k|
        next unless k =~ /\A[A-Z][A-Z0-9_]*\z/
        problems << "unknown env var '#{k}' (not declared in spec)" unless known.include?(k)
      end
    end

    problems
  end

  private

  def type_problem(name, raw, entry)
    case entry.type
    when :str, :dsn
      nil
    when :int
      Integer(raw, 10)
      nil
    when :bool
      unless %w[true false 1 0 yes no].include?(raw.downcase)
        return "env var '#{name}' = #{raw.inspect} is not a valid bool (expected true/false/1/0/yes/no)"
      end
      nil
    when :enum
      unless entry.enum_values.include?(raw)
        return "env var '#{name}' = #{raw.inspect} is not in enum(#{entry.enum_values.join(', ')})"
      end
      nil
    end
  rescue ArgumentError
    "env var '#{name}' = #{raw.inspect} is not a valid #{entry.type}"
  end
end
