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

      def initialize(prompt: nil)
        @opts = default_opts
        @help_requested = false
        @prompt = prompt || EnvPact::Prompt.new
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

      # Prints the result and returns the exit code. reveal: is the values
      # hash when the user asked for --show-values; extras never show values.
      # An OpenBao client for reading env's secrets, with the read token from
      # the agent or ~/.ob_read. The token is only ever sent to the address it
      # was issued for: a spec (or $BAO_ADDR) naming another address is
      # refused rather than followed.
      def read_client(ref)
        cred = Credentials.new(prompt: @prompt).read_token
        wanted = ref.addr || (ENV["BAO_ADDR"] unless ENV["BAO_ADDR"].to_s.empty?)
        if wanted && cred[:addr] && wanted.sub(%r{/+\z}, "") != cred[:addr].sub(%r{/+\z}, "")
          raise EnvPact::Error, "refusing to send the OpenBao token to a different address than the one it was " \
                                "issued for (#{cred[:addr]} vs #{wanted}); run envpact login --read --addr=#{wanted}"
        end
        OpenBao::Client.new(addr: cred[:addr] || wanted, token: cred[:token], role: :read)
      end

      # The env's secrets from OpenBao (see EnvPact::Source.fetch). Extras
      # found in the source go to warnings.
      def fetch_source(spec, env, warnings: nil)
        ref = spec.source_for(env)
        raise EnvPact::Error, "no [source] for env '#{env}' in env.spec" if ref.nil?
        client = read_client(ref)
        values = Source.fetch(spec, env: env, client: client, warnings: warnings)
        begin
          client.renew_self # keeps the monthly login monthly
        rescue OpenBao::Error
          nil
        end
        values
      end

      def report(spec, result, opts, reveal: nil)
        name  = File.basename(spec_path(opts))
        scope = "(#{scope_label(spec, result)})"
        if result.ok?
          puts "✓ #{name} satisfied #{scope}"
        else
          warn "✗ #{name} not satisfied #{scope}"
          result.errors.each { |p| warn "  - #{problem_text(p, reveal)}" }
        end
        result.warnings.each { |p| warn "  ! #{problem_text(p, reveal)}" }
        result.ok? ? 0 : 1
      end

      def scope_label(spec, result)
        env = result.env
        return "env: #{env} — shared + [env: #{env}]" if result.applied_sections.include?(env)
        others = spec.envs
        others.empty? ? "env: #{env} — shared only" : "env: #{env} — shared only; sections in spec: #{others.join(', ')}"
      end

      def problem_text(problem, reveal)
        return problem.message if reveal.nil? || problem.kind == :extra
        Message.format(problem, value: reveal[problem.key])
      end
    end
  end
end
