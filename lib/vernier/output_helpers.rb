# frozen_string_literal: true

module Vernier
  module OutputHelpers
    # Collapses parallel samples/weights arrays into a hash of total weight
    # per stack index. Retained-mode profiles have one sample per object and
    # many samples share the same stack, so collapsing first keeps later
    # aggregation proportional to the number of unique stacks.
    def collapse_stack_weights(samples, weights)
      stack_weights = Hash.new(0)
      samples.each_with_index do |stack_idx, idx|
        stack_weights[stack_idx] += weights[idx]
      end
      stack_weights
    end

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
