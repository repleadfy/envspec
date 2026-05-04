class EnvSpec
  class Error < StandardError; end

  class ParseError < Error
    attr_reader :line_no
    def initialize(msg, line_no = nil)
      super(line_no ? "line #{line_no}: #{msg}" : msg)
      @line_no = line_no
    end
  end

  class ValidationError < Error
    attr_reader :problems
    def initialize(problems)
      @problems = Array(problems)
      lines = ["env validation failed:"] + @problems.map { |p| "  - #{p}" }
      super(lines.join("\n"))
    end
  end
end
