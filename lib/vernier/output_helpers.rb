# frozen_string_literal: true

module Vernier
  module OutputHelpers
    # Returns a string safe to embed in JSON output: valid UTF-8 with any
    # invalid bytes replaced. Method names and paths can carry arbitrary
    # encodings (e.g. BINARY or Shift_JIS source), which would otherwise
    # raise JSON::GeneratorError.
    def sanitize_string(string)
      if string.ascii_only?
        string
      elsif string.encoding == Encoding::UTF_8
        string.valid_encoding? ? string : string.scrub
      else
        # We don't know the real encoding; interpret the bytes as UTF-8
        # and replace anything invalid.
        string.dup.force_encoding(Encoding::UTF_8).scrub
      end
    end
  end
end
