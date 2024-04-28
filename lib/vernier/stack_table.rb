module Vernier
  class StackTable
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
  end
end
