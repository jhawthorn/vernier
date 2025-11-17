# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
  t.deps << :install
end

task :console => :compile do
  sh "irb -r vernier"
end

require "rake/extensiontask"

task build: :compile
task install: :compile

Rake::ExtensionTask.new("vernier") do |ext|
  ext.lib_dir = "lib/vernier"
end

task default: %i[clobber compile install test]
