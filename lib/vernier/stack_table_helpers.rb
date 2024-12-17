module Vernier
  module StackTableHelpers
    def inspect
      "#<#{self.class.name} #{stack_count} stacks, #{frame_count} frames, #{func_count} funcs>"
    end

    def to_h
      {
        stack_table: {
          parent: stack_count.times.map { stack_parent_idx(_1) },
          frame:  stack_count.times.map { stack_frame_idx(_1) }
        },
        frame_table: {
          func: frame_count.times.map { frame_func_idx(_1) },
          line:  frame_count.times.map { frame_line_no(_1) }
        },
        func_table: {
          name: func_count.times.map { func_name(_1) },
          filename: func_count.times.map { func_filename(_1) },
          first_line: func_count.times.map { func_first_lineno(_1) }
        }
      }
    end

    def backtrace(stack_idx)
      full_stack(stack_idx).map do |stack_idx|
        frame_idx = stack_frame_idx(stack_idx)
        func_idx = frame_func_idx(frame_idx)
        line = frame_line_no(frame_idx)
        name = func_name(func_idx);
        filename = func_filename(func_idx);

        "#{filename}:#{line}:in '#{name}'"
      end
    end

    def full_stack(stack_idx)
      full_stack = []
      while stack_idx
        full_stack << stack_idx
        stack_idx = stack_parent_idx(stack_idx)
      end
      full_stack
    end

    class BaseType
      attr_reader :stack_table, :idx
      def initialize(stack_table, idx)
        @stack_table = stack_table
        @idx = idx
      end

      def inspect
        "#<#{self.class}\n#{to_s}>"
      end
    end

    class Func < BaseType
      def label
        stack_table.func_name(idx)
      end
      alias name label

      def filename
        stack_table.func_filename(idx)
      end

      def to_s
        "#{name} at #{filename}"
      end
    end

    class Frame < BaseType
      def label; func.label; end
      def filename; func.filename; end
      alias name label

      def func
        func_idx = stack_table.frame_func_idx(idx)
        Func.new(stack_table, func_idx)
      end

      def line
        stack_table.frame_line_no(idx)
      end

      def to_s
        "#{func}:#{line}"
      end
    end

    class Stack < BaseType
      def each_frame
        return enum_for(__method__) unless block_given?

        stack_idx = idx
        while stack_idx
          frame_idx = stack_table.stack_frame_idx(stack_idx)
          yield Frame.new(stack_table, frame_idx)
          stack_idx = stack_table.stack_parent_idx(stack_idx)
        end
      end

      def leaf_frame_idx
        stack_table.stack_frame_idx(idx)
      end

      def leaf_frame
        Frame.new(stack_table, leaf_frame_idx)
      end

      def frames
        each_frame.to_a
      end

      def to_s
        arr = []
        each_frame do |frame|
          arr << frame.to_s
        end
        arr.join("\n")
      end
    end

    def stack(idx)
      Stack.new(self, idx)
    end
  end
end
