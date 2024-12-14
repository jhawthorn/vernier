# frozen_string_literal: true

module Vernier
  module Output
    class FilenameFilter
      def initialize
        @pwd = "#{Dir.pwd}/"
        @gem_regex = %r{\A#{Regexp.union(Gem.path)}/gems/}
        @gem_match_regex = %r{\A#{Regexp.union(Gem.path)}/gems/([a-zA-Z](?:[a-zA-Z0-9\.\_]|-[a-zA-Z])*)-([0-9][0-9A-Za-z\-_\.]*)/(.*)\z}
        @rubylibdir = "#{RbConfig::CONFIG["rubylibdir"]}/"
      end

      attr_reader :pwd, :gem_regex, :gem_match_regex, :rubylibdir

      def call(filename)
        if filename.match?(gem_regex)
          gem_match_regex =~ filename
          "gem:#$1-#$2:#$3"
        elsif filename.start_with?(pwd)
          filename.delete_prefix(pwd)
        elsif filename.start_with?(rubylibdir)
          path = filename.delete_prefix(rubylibdir)
          "rubylib:#{RUBY_VERSION}:#{path}"
        else
          filename
        end
      end
    end
  end
end
