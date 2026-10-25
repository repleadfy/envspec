class EnvPact
  # One thing wrong with a set of values checked against a spec.
  #
  # kind is :missing, :invalid or :extra. value is the offending value for
  # configmap keys only -- it is always nil for secrets and extras, so a
  # Problem can be printed or logged without leaking a secret.
  Problem = Struct.new(:kind, :key, :secret, :line, :value, :type, :enum_values, keyword_init: true) do
    def message
      Message.format(self)
    end
  end

  # Builds problem text. Pass value: explicitly to reveal a secret value
  # (the CLI does this for --show-values); by default the problem's own,
  # already-masked value is used.
  module Message
    BOOL_HINT = "(expected true/false/1/0/yes/no)".freeze

    def self.format(problem, value: problem.value)
      key = problem.key
      case problem.kind
      when :missing
        "missing required env var '#{key}' (declared at line #{problem.line})"
      when :extra
        "unknown env var '#{key}' (not declared in spec)"
      when :invalid
        subject = value.nil? ? "env var '#{key}' (secret)" : "env var '#{key}' = #{value.inspect}"
        "#{subject} #{invalid_reason(problem.type, problem.enum_values)}"
      end
    end

    def self.invalid_reason(type, enum_values)
      case type
      when :bool then "is not a valid bool #{BOOL_HINT}"
      when :enum then "is not in enum(#{enum_values.join(', ')})"
      else "is not a valid #{type}"
      end
    end
  end
end
