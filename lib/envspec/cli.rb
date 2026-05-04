require_relative "cli/command"
require_relative "cli/lint"
require_relative "cli/check"
require_relative "cli/init"

class EnvSpec
  # Dispatcher for `envspec` subcommands.
  #
  # Each subcommand is a class under EnvSpec::CLI inheriting from
  # EnvSpec::CLI::Command. Register new commands by adding them to COMMANDS
  # below and creating a file under lib/envspec/cli/.
  class CLI
    COMMANDS = {
      "lint"  => Lint,
      "check" => Check,
      "init"  => Init,
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
        puts EnvSpec::VERSION
        return 0
      end

      klass = COMMANDS[cmd]
      unless klass
        warn "envspec: unknown command '#{cmd}'"
        warn ""
        print_help
        return 2
      end

      klass.new.run(argv)
    rescue OptionParser::ParseError => e
      warn "envspec: #{e.message}"
      2
    rescue EnvSpec::ParseError, EnvSpec::ValidationError => e
      warn "envspec: #{e.message}"
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
      lines << "Usage: envspec <command> [options]"
      lines << ""
      lines << "Commands:"
      rows.each { |name, summary| lines << format("  %-#{width}s   %s", name, summary) }
      lines << ""
      lines << "Run `envspec help <command>` (or `envspec <command> -h`) for command-specific options."
      lines << "Docs: https://github.com/repleadfy/envspec"
      lines.join("\n")
    end
  end
end
