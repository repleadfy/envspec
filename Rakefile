require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
  # Force UTF-8 in the test process whatever the locale. Not RUBYOPT: that
  # would leak into the subprocesses the tests spawn.
  t.ruby_opts << "-EUTF-8"
end

namespace :test do
  # Needs ENVPACT_BAO_BIN=/path/to/bao (OpenBao 2.7.3); skips without it.
  Rake::TestTask.new(:integration) do |t|
    t.libs << "test"
    t.libs << "lib"
    t.test_files = FileList["test/integration/test_*.rb"]
    t.ruby_opts << "-EUTF-8"
  end
end

task :default => :test
