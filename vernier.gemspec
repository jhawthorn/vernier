# frozen_string_literal: true

require_relative "lib/vernier/version"

Gem::Specification.new do |spec|
  spec.name = "vernier"
  spec.version = Vernier::VERSION
  spec.authors = ["John Hawthorn"]
  spec.email = ["john@hawthorn.email"]

  spec.summary = "An experimental profiler"
  spec.description = spec.summary
  spec.homepage = "https://github.com/jhawthorn/vernier"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.6.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = spec.homepage

  spec.post_install_message = <<~WARNING
    #{'!'*80}
    WARNING! You've installed a very old version of Vernier, likely due to Ruby >= 3.2 version requirement.
    Please use gem "vernier", "~> 1.0" in your gemspec to install a modern version.
    #{'!'*80}
  WARNING

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
end
