lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "envspec/version"

Gem::Specification.new do |spec|
  spec.name          = "envspec"
  spec.version       = EnvSpec::VERSION
  spec.authors       = ["Leadfy"]
  spec.email         = ["dev@leadfy.com"]
  spec.summary       = "Declarative env var contract for apps (parser + validator + scaffolder)"
  spec.description   = "Parses env.spec files: a declarative contract describing which env vars an app expects, their types, optionality, and ConfigMap-vs-Secret classification. Pure stdlib, zero runtime dependencies."
  spec.homepage      = "https://github.com/repleadfy/envspec"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 2.5.0"

  spec.files         = Dir["lib/**/*", "exe/*", "LICENSE.txt", "README.md", "CHANGELOG.md"]
  spec.bindir        = "exe"
  spec.executables   = ["envspec"]
  spec.require_paths = ["lib"]

  # Zero runtime dependencies -- stdlib only
  spec.add_development_dependency "bundler"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
