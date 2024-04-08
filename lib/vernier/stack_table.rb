module Vernier
  class StackTable
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
