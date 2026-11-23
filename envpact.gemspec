lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "envpact/version"

Gem::Specification.new do |spec|
  spec.name          = "envpact"
  spec.version       = EnvPact::VERSION
  spec.authors       = ["Leadfy"]
  spec.email         = ["dev@leadfy.com"]
  spec.summary       = "Env var contract for apps: one file, checked locally, before deploy and at boot"
  spec.description   = "Parses envpact.yml (and legacy env.spec) files: a declarative contract describing which env vars an app expects, their types, optionality, and ConfigMap-vs-Secret classification, and syncs secrets with OpenBao. Pure stdlib, zero runtime dependencies."
  spec.homepage      = "https://github.com/repleadfy/envpact"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 2.5.0"

  spec.files         = Dir["lib/**/*", "exe/*", "LICENSE.txt", "README.md", "CHANGELOG.md"]
  spec.bindir        = "exe"
  spec.executables   = ["envpact"]
  spec.require_paths = ["lib"]

  # Zero runtime dependencies -- stdlib only
  spec.add_development_dependency "bundler", ">= 2.0", "< 5"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
