require "time"
require_relative "command"

class EnvPact
  class CLI
    class Pull < Command
      command_name "pull"
      summary "Download the env's secrets from OpenBao into a 0600 dotenv file"
      banner "Usage: envpact pull --env=NAME [--out=PATH] [--spec=PATH]"
      description <<~DESC
        Reads the secrets of one env from the source in envpact.yml, checks the
        result against the contract (together with the .env* files, except the
        target itself) and, only if it is satisfied, writes the secrets to
        .env.<env>.local (or --out), mode 0600. The values are never printed.
        The read token comes from the agent (envpact unlock) or ~/.ob_read.
      DESC

      def configure(o, opts)
        o.on("--env=NAME", "Env to pull (required)") { |v| opts[:env] = v }
        o.on("--out=PATH", "Target file (default: .env.<env>.local)") { |v| opts[:out] = v }
        spec_option(o, opts)
      end

      def call(_rest, opts)
        env = opts[:env] or raise UsageError, "--env=NAME is required"
        spec = load_spec(opts)
        out  = opts[:out] || ".env.#{env}.local"
        ref  = spec.source_for(env)
        raise EnvPact::Error, "no source for env '#{env}' in the contract" if ref.nil?

        # The target is the last file check reads, so stale values in it must
        # not satisfy the contract: leave it out of the merge.
        loaded  = Dotenv.load(Dir.pwd, env: env, skip: [File.expand_path(out)])
        warnings = []
        fetched = fetch_source(spec, env, warnings: warnings)
        values  = loaded[:values].merge(fetched)

        result = spec.check(values, env: env, strict: false)
        warnings.each { |p| warn "  ! #{p.message}" }
        code = report(spec, result, opts)
        return code unless result.ok?

        header = "# written by envpact pull from openbao:#{ref.mount}/#{ref.path} at " \
                 "#{Time.now.utc.iso8601}; do not edit\n"
        AtomicFile.write(out, header + Dotenv.dump(fetched))
        puts "✓ pulled #{fetched.size} secrets → #{out} (0600)"
        warn "! #{out} is not git-ignored" if not_ignored?(out)
        0
      end

      private

      # git check-ignore -q: 0 ignored, 1 not ignored, 128 not a repo. Without
      # git, or outside a repo, stay quiet.
      def not_ignored?(path)
        system("git", "check-ignore", "-q", path, out: File::NULL, err: File::NULL)
        $?.exitstatus == 1
      rescue SystemCallError
        false
      end
    end
  end
end
