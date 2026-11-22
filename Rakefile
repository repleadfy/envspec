require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
  # Force UTF-8 in the test process whatever the locale. Not RUBYOPT: that
  # would leak into the subprocesses the tests spawn.
  t.ruby_opts << "-EUTF-8"
end

task :default => :test
