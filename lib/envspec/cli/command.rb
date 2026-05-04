require "optparse"

class EnvSpec
  class CLI
    # Base class for a single CLI subcommand.
    #
    # Subclasses declare:
    #   - name     (string, e.g. "lint")
    #   - summary  (one-line description for global help)
    #   - configure(parser, opts) — define options on the OptionParser
    #   - call(argv, opts) — execute; return exit code
    class Command
      class << self
        def name(value = nil)
          @name = value if value
          @name
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
      end

      def default_opts
        {}
      end

      def parser
        @parser ||= build_parser
      end

      def build_parser
        OptionParser.new do |o|
          o.banner = self.class.banner || "Usage: envspec #{self.class.name}"
          if self.class.description
            o.separator ""
            self.class.description.each_line { |ln| o.separator ln.chomp }
          end
          o.separator ""
          o.separator "Options:"
          configure(o, @opts)
          o.on("-h", "--help", "Show help for this command") { puts o; exit 0 }
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
        call(rest, @opts)
      end

      def call(_rest, _opts)
        raise NotImplementedError
      end

      protected

      def die(msg, code = 1)
        warn "envspec: #{msg}"
        code
      end

      def require_file(file)
        return file if file && File.exist?(file)
        if file.nil?
          warn parser.help
          exit 2
        end
        warn "envspec: file not found: #{file}"
        exit 1
      end
    end
  end
end
