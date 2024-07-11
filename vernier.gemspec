# frozen_string_literal: true

require_relative "lib/vernier/version"

Gem::Specification.new do |spec|
  spec.name = "vernier"
  spec.version = Vernier::VERSION
  spec.authors = ["John Hawthorn"]
  spec.email = ["john@hawthorn.email"]

  spec.summary = "A next generation CRuby profiler"
  spec.description = "Next-generation Ruby 3.2.1+ sampling profiler. Tracks multiple threads, GVL activity, GC pauses, idle time, and more."
  spec.homepage = "https://github.com/jhawthorn/vernier"
  spec.license = "MIT"

  unless ENV["IGNORE_REQUIRED_RUBY_VERSION"]
    spec.required_ruby_version = ">= 3.2.1"
  end

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = spec.homepage

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) || f.match(%r{\A(?:(?:test|spec|features)/|\.(?:git|travis|circleci)|appveyor)})
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/vernier/extconf.rb"]

  spec.add_development_dependency "activesupport"
  spec.add_development_dependency "gvltest"
  spec.add_development_dependency "rack"
end
