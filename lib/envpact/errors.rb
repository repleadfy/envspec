class EnvPact
  class Error < StandardError; end

  class ParseError < Error
    attr_reader :line_no
    def initialize(msg, line_no = nil)
      super(line_no ? "line #{line_no}: #{msg}" : msg)
      @line_no = line_no
    end
  end

  class ValidationError < Error
    attr_reader :result
    def initialize(result)
      @result = result
      lines = ["env validation failed (env: #{result.env}):"] + result.errors.map { |p| "  - #{p.message}" }
      super(lines.join("\n"))
    end
  end
end
