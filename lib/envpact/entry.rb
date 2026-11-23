class EnvPact
  Entry = Struct.new(:type, :optional, :default, :enum_values, :line, :description, keyword_init: true)
end
