# frozen_string_literal: true

module Vernier
  module Output
    class Top
      def initialize(profile)
        @profile = profile
      end

      def output
        stack_weights = Hash.new(0)
        @profile.samples.zip(@profile.weights) do |stack_idx, weight|
          stack_weights[stack_idx] += weight
        end

        top_by_self = Hash.new(0)
        stack_weights.each do |stack_idx, weight|
          stack = @profile.stack(stack_idx)
          top_by_self[stack.leaf_frame.name] += weight
        end

        s = +""
        top_by_self.sort_by(&:last).reverse.each do |frame, samples|
          s << "#{samples}\t#{frame}\n"
        end
        s
      end
    end
  end
end
