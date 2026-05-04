class EnvSpec
  Entry = Struct.new(:type, :optional, :default, :enum_values, :line, keyword_init: true)
end
