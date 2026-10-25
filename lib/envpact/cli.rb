require_relative "cli/command"
require_relative "cli/lint"
require_relative "cli/check"
require_relative "cli/exec"
require_relative "cli/scan_prompt"

class EnvPact
  # Dispatcher for `envpact` subcommands.
  #
  # Each subcommand is a class under EnvPact::CLI inheriting from
  # EnvPact::CLI::Command. Register new commands by adding them to COMMANDS
  # below and creating a file under lib/envpact/cli/.
  class CLI
    COMMANDS = {
      "lint"  => Lint,
      "check" => Check,
      "exec"  => Exec,
      "scan-prompt" => ScanPromptCommand,
    }.freeze

    def self.run(argv)
      new.run(argv)
    end

    def run(argv)
      argv = argv.dup
      cmd = argv.shift

      case cmd
      when nil, "help", "-h", "--help"
        print_help(argv.first)
        return 0
      when "version", "-v", "--version"
        puts EnvPact::VERSION
        return 0
      end

      klass = COMMANDS[cmd]
      unless klass
        warn "envpact: unknown command '#{cmd}'"
        warn ""
        print_help
        return 2
      end

      klass.new.run(argv)
    rescue OptionParser::ParseError, UsageError => e
      warn "envpact: #{e.message}"
      2
    rescue EnvPact::Error, SystemCallError => e
      warn "envpact: #{e.message}"
      1
    end

    private

    def print_help(topic = nil)
      if topic && (klass = COMMANDS[topic])
        puts klass.new.help
        return
      end
      puts global_help
    end

    def global_help
      rows = COMMANDS.map { |n, k| [n, k.summary] }
      rows << ["help",    "Show help for a command"]
      rows << ["version", "Show version"]
      width = rows.map { |r| r[0].length }.max

      lines = []
      lines << "Usage: envpact <command> [options]"
      lines << ""
      lines << "Commands:"
      rows.each { |name, summary| lines << format("  %-#{width}s   %s", name, summary) }
      lines << ""
      lines << "Run `envpact help <command>` (or `envpact <command> -h`) for command-specific options."
      lines << "Docs: https://github.com/repleadfy/envpact"
      lines.join("\n")
    end
  end
end
