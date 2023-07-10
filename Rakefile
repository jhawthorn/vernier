# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
end

task :console => :compile do
  sh "irb -r vernier"
end

require "rake/extensiontask"

task build: :compile

Rake::ExtensionTask.new("vernier") do |ext|
  ext.lib_dir = "lib/vernier"
end

task default: %i[clobber compile test]
