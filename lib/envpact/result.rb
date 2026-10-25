class EnvPact
  # Outcome of EnvPact#check. ok? ignores warnings.
  class Result
    attr_reader :env, :errors, :warnings, :applied_sections

    def initialize(env:, errors:, warnings:, applied_sections:)
      @env = env
      @errors = errors
      @warnings = warnings
      @applied_sections = applied_sections
    end

    def ok?
      @errors.empty?
    end
  end
end
