require "uri"

class EnvPact
  BOOL_VALUES = %w[true false 1 0 yes no].freeze

  # Value validation shared by the checker (values) and the parser (defaults).
  module Types
    def self.valid?(raw, type, enum_values = nil)
      case type
      when :str  then true
      when :int  then !Integer(raw, 10).nil?
      when :bool then BOOL_VALUES.include?(raw.downcase)
      when :enum then enum_values.include?(raw)
      when :url  then valid_url?(raw, enum_values)
      end
    rescue ArgumentError
      false
    end

    # schemes (optional) restricts the scheme, compared case-insensitively.
    def self.valid_url?(raw, schemes = nil)
      uri = URI.parse(raw)
      return false if uri.scheme.nil? || uri.host.nil? || uri.host.empty?
      schemes.nil? || schemes.include?(uri.scheme.downcase)
    rescue URI::InvalidURIError
      false
    end
  end

  # Reads a text file as UTF-8 whatever the process locale, dropping a BOM.
  def self.read_text(path)
    File.read(path, mode: "r:BOM|UTF-8")
  end

  # Text handed to the parsers may come tagged US-ASCII or binary (e.g. under
  # LANG=C); treat it as UTF-8 so non-ASCII comments don't crash matching.
  def self.utf8(text)
    text.encoding == Encoding::UTF_8 ? text : text.dup.force_encoding(Encoding::UTF_8)
  end
end
