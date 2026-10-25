require "uri"

class EnvPact
  KEY_RE = /\A[A-Z][A-Z0-9_]*\z/.freeze
  BOOL_VALUES = %w[true false 1 0 yes no].freeze

  # Checks a values hash against the spec for one env.
  #
  #   - required keys must be present and non-empty (empty counts as absent)
  #   - present values must parse as their declared type
  #   - keys not in the spec are warnings, or errors with strict: true;
  #     extras: false skips them entirely (process ENV is full of PATH etc.)
  def check(values, env:, strict: false, extras: true)
    configmap = configmap_for(env)
    secrets   = secrets_for(env)
    errors    = []
    warnings  = []

    { false => configmap, true => secrets }.each do |secret, entries|
      entries.each do |key, entry|
        raw = values[key]
        if raw.nil? || raw.empty?
          next if entry.optional || !entry.default.nil?
          errors << Problem.new(kind: :missing, key: key, secret: secret, line: entry.line)
        elsif !valid_value?(raw, entry)
          errors << Problem.new(kind: :invalid, key: key, secret: secret, line: entry.line,
                                value: (secret ? nil : raw), type: entry.type, enum_values: entry.enum_values)
        end
      end
    end

    if extras
      known = configmap.merge(secrets)
      values.each_key do |key|
        next unless KEY_RE.match?(key) && !known.key?(key)
        (strict ? errors : warnings) << Problem.new(kind: :extra, key: key, secret: false)
      end
    end

    Result.new(env: env, errors: errors, warnings: warnings, applied_sections: applied_sections(env))
  end

  def check!(values, env:, strict: false, extras: true)
    result = check(values, env: env, strict: strict, extras: extras)
    raise ValidationError.new(result) unless result.ok?
    result
  end

  private

  def applied_sections(env)
    sections = ["shared"]
    sections << env if @configmap.key?(env) || @secrets.key?(env)
    sections
  end

  def valid_value?(raw, entry)
    case entry.type
    when :str  then true
    when :int  then !Integer(raw, 10).nil?
    when :bool then BOOL_VALUES.include?(raw.downcase)
    when :enum then entry.enum_values.include?(raw)
    when :url  then valid_url?(raw)
    end
  rescue ArgumentError
    false
  end

  def valid_url?(raw)
    uri = URI.parse(raw)
    !uri.scheme.nil? && !uri.host.nil? && !uri.host.empty?
  rescue URI::InvalidURIError
    false
  end
end
