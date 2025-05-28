module Vernier
  module Output
    class OutputPathBuilder
      def initialize(formatter:)
        @formatter = formatter
      end

      def build(output_dir: nil)
        unless output_dir
          if File.writable?(".")
            output_dir = "."
          else
            output_dir = Dir.tmpdir
          end
        end
        timestamp = Time.now.strftime("%Y%m%d-%H%M%S")

        File.expand_path("#{output_dir}/profile-#{timestamp}-#{$$}vernier.#{formatter.suffix}")
      end

      private

      attr_reader :formatter
    end
  end
end