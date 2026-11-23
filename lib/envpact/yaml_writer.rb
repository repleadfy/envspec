require "json"

# Writes the model back as envpact.yml (used by `envpact convert`). Keys keep
# their order of declaration; keys declared once for several envs
# ([env: a, b]) stay grouped under "a, b". Comments are not carried over.
class EnvPact
  def to_yaml_contract
    out = ["version: 1"]
    shared_source = @sources.find { |s| s.envs.nil? }
    out << "" << "source:" << yaml_source_lines(shared_source, "  ") if shared_source
    shared_vars = yaml_group(@configmap)[SHARED]
    shared_secrets = yaml_group(@secrets)[SHARED]
    out << "" << "vars:" << yaml_key_lines(shared_vars, "  ") if shared_vars
    out << "" << "secrets:" << yaml_key_lines(shared_secrets, "  ") if shared_secrets

    groups = yaml_env_groups
    unless groups.empty?
      out << "" << "envs:"
      groups.each do |label, parts|
        out << "  #{JSON.generate(label)}:"
        out << "    source:" << yaml_source_lines(parts[:source], "      ") if parts[:source]
        out << "    vars:" << yaml_key_lines(parts[:vars], "      ") if parts[:vars]
        out << "    secrets:" << yaml_key_lines(parts[:secrets], "      ") if parts[:secrets]
      end
    end
    out.flatten.join("\n") + "\n"
  end

  private

  # { "*" or "a, b" => [[name, entry], ...] }, regrouping env-scoped keys that
  # came from one declaration (same line) under one label.
  def yaml_group(bucket)
    by_decl = {}
    bucket.each do |env, keys|
      keys.each do |name, entry|
        (by_decl[[name, entry.line]] ||= { entry: entry, envs: [] })[:envs] << env
      end
    end
    groups = {}
    by_decl.sort_by { |(_, line), _| line }.each do |(name, _), d|
      label = d[:envs].include?(SHARED) ? SHARED : d[:envs].join(", ")
      (groups[label] ||= []) << [name, d[:entry]]
    end
    groups
  end

  def yaml_env_groups
    groups = {}
    @sources.reject { |s| s.envs.nil? }.each { |s| (groups[s.envs.join(", ")] ||= {})[:source] = s }
    yaml_group(@configmap).each { |label, keys| (groups[label] ||= {})[:vars] = keys unless label == SHARED }
    yaml_group(@secrets).each { |label, keys| (groups[label] ||= {})[:secrets] = keys unless label == SHARED }
    groups
  end

  def yaml_source_lines(s, indent)
    lines = ["#{indent}openbao:", "#{indent}  path: #{JSON.generate(s.path)}"]
    lines << "#{indent}  mount: #{JSON.generate(s.mount)}" unless s.mount == "secret"
    lines << "#{indent}  addr: #{JSON.generate(s.addr)}" if s.addr
    lines
  end

  def yaml_key_lines(pairs, indent)
    pairs.map do |name, e|
      type = yaml_type_text(e)
      if !e.optional && e.default.nil? && e.description.nil?
        type == "str" ? "#{indent}#{name}:" : "#{indent}#{name}: #{type}"
      else
        fields = []
        fields << "type: #{type.include?('(') ? JSON.generate(type) : type}" unless type == "str"
        fields << "default: #{JSON.generate(e.default)}" unless e.default.nil?
        fields << "optional: true" if e.optional
        fields << "description: #{JSON.generate(e.description)}" if e.description
        "#{indent}#{name}: {#{fields.join(', ')}}"
      end
    end
  end

  def yaml_type_text(e)
    return e.type.to_s unless e.enum_values

    "#{e.type}(#{e.enum_values.join(', ')})"
  end
end
