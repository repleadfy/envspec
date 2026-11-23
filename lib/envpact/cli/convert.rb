require_relative "command"

class EnvPact
  class CLI
    class Convert < Command
      command_name "convert"
      summary "Write envpact.yml from a legacy env.spec"
      banner "Usage: envpact convert [--spec=PATH] [--out=PATH]"
      description <<~TXT
        Reads an env.spec (default ./env.spec) and writes the same contract as
        envpact.yml next to it. Never overwrites; comments are not carried over.
        Review the result, then delete the env.spec: with both files present
        every command refuses to run.
      TXT

      def configure(o, opts)
        o.on("--spec=PATH", "The env.spec to read (default: ./#{EnvPact::LEGACY_FILE})") { |v| opts[:spec] = v }
        o.on("--out=PATH", "Where to write (default: #{EnvPact::YAML_FILE} next to the spec)") { |v| opts[:out] = v }
      end

      def call(_rest, opts)
        src = opts[:spec] || (File.file?(EnvPact::LEGACY_FILE) ? EnvPact::LEGACY_FILE : EnvPact.locate(".").first)
        return die("convert reads an env.spec; #{src} is already YAML") if File.extname(src).match?(/\A\.ya?ml\z/i)
        return die("spec not found: #{src}") unless File.file?(src)

        out = opts[:out] || File.join(File.dirname(src), EnvPact::YAML_FILE)
        out = EnvPact::YAML_FILE if out == "./#{EnvPact::YAML_FILE}"
        return die("#{out} already exists; not overwriting") if File.exist?(out)

        yaml = EnvPact.parse_file(src).to_yaml_contract
        EnvPact.parse_yaml(yaml) # never write something we cannot read back
        File.write(out, yaml)
        puts "✓ wrote #{out} (comments in #{File.basename(src)} are not carried over)"
        puts "  review it, then delete #{src} (git rm #{src}): with both files every command refuses to run"
        0
      end
    end
  end
end
