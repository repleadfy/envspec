class EnvPact
  # Instructions for an AI agent to build or update a repo's env.spec. The
  # template and the syntax reference ship with the gem, so the prompt always
  # matches the parser it was released with.
  module ScanPrompt
    DIR = __dir__

    def self.render
      template = File.read(File.join(DIR, "scan_prompt.md"))
      template.sub("{{SYNTAX}}") { syntax.chomp }
    end

    def self.syntax
      File.read(File.join(DIR, "syntax.md"))
    end
  end
end
