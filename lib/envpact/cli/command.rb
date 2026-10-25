require "optparse"

class EnvPact
  class CLI
    # Raised for bad invocations; the dispatcher maps it to exit code 2.
    class UsageError < EnvPact::Error; end

    # Base class for a single CLI subcommand.
    #
    # Subclasses declare:
    #   - command_name (string, e.g. "lint")
    #   - summary      (one-line description for global help)
    #   - configure(parser, opts) — define options on the OptionParser
    #   - call(argv, opts) — execute; return exit code
    class Command
      DEFAULT_SPEC = "env.spec".freeze

      class << self
        def command_name(value = nil)
          @command_name = value if value
          @command_name
        end

        def summary(value = nil)
          @summary = value if value
          @summary
        end

        def banner(value = nil)
          @banner = value if value
          @banner
        end

        def description(value = nil)
          @description = value if value
          @description
        end
      end

      def initialize
        @opts = default_opts
        @help_requested = false
      end

      def default_opts
        {}
      end

      def parser
        @parser ||= build_parser
      end

      def build_parser
        OptionParser.new do |o|
          o.banner = self.class.banner || "Usage: envpact #{self.class.command_name}"
          if self.class.description
            o.separator ""
            self.class.description.each_line { |ln| o.separator ln.chomp }
          end
          o.separator ""
          o.separator "Options:"
          configure(o, @opts)
          o.on("-h", "--help", "Show help for this command") { @help_requested = true }
        end
      end

      def configure(_parser, _opts)
        # subclass override
      end

      def help
        parser.help
      end

      # Subclasses override `call(argv, opts)`. The dispatcher invokes `run(argv)`.
      def run(argv)
        rest = parser.parse(argv)
        if @help_requested
          puts parser.help
          return 0
        end
        call(rest, @opts)
      end

      def call(_rest, _opts)
        raise NotImplementedError
      end

      protected

      def die(msg, code = 1)
        warn "envpact: #{msg}"
        code
      end

      def spec_option(o, opts)
        o.on("--spec=PATH", "Contract file (default: $ENVPACT_SPEC or ./#{DEFAULT_SPEC})") { |v| opts[:spec] = v }
      end

      def spec_path(opts)
        opts[:spec] || ENV["ENVPACT_SPEC"] || DEFAULT_SPEC
      end

      def load_spec(opts)
        path = spec_path(opts)
        raise EnvPact::Error, "spec not found: #{path}" unless File.file?(path)
        EnvPact.parse_file(path)
      end
    end
  end
end
