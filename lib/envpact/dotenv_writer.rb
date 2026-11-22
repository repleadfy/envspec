class EnvPact
  module Dotenv
    DUMP_KEY_RE = /\A[A-Za-z_][A-Za-z0-9_]*\z/.freeze

    # One KEY="value" line per key, sorted. Escapes \ " and newline, the
    # inverse of parse_value, so Dotenv.parse(dump(h)) == h. A value with a
    # carriage return cannot round-trip (parse strips it) and is refused;
    # errors name the key, never the value.
    def self.dump(hash)
      hash.keys.sort.map do |key|
        raise Error, "cannot write key '#{key}' to a dotenv file (invalid name)" unless DUMP_KEY_RE.match?(key)
        value = hash[key].to_s
        raise Error, "value of '#{key}' contains a carriage return; it cannot be written to a dotenv file" if value.include?("\r")
        escaped = value.gsub(/[\\"\n]/) { |c| c == "\n" ? "\\n" : "\\#{c}" }
        %(#{key}="#{escaped}"\n)
      end.join
    end
  end
end
