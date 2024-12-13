# frozen_string_literal: true

module Vernier
  module Output
    class Top
      def initialize(profile)
        @profile = profile
      end

      def output
        thread = @profile.main_thread
        stack_table =
          if thread.respond_to?(:stack_table)
            thread.stack_table
          else
            @profile._stack_table
          end

        stack_weights = Hash.new(0)
        thread[:samples].zip(thread[:weights]) do |stack_idx, weight|
          stack_weights[stack_idx] += weight
        end

        top_by_self = Hash.new(0)
        stack_weights.each do |stack_idx, weight|
          frame_idx = stack_table.stack_frame_idx(stack_idx)
          func_idx = stack_table.frame_func_idx(frame_idx)
          name = stack_table.func_name(func_idx)
          top_by_self[name] += weight
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
