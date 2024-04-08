module Vernier
  class StackTable
    def backtrace(stack_idx)
      hash = to_h

      full_stack = []
      cur_stack_idx = stack_idx
      while cur_stack_idx
        full_stack << cur_stack_idx
        cur_stack_idx = hash[:stack_table][:parent][cur_stack_idx]
      end

      full_stack.map do |stack_idx|
        frame_idx = hash[:stack_table][:frame][stack_idx]
        func_idx = hash[:frame_table][:func][frame_idx]
        line = hash[:frame_table][:line][frame_idx]
        name = hash[:func_table][:name][func_idx]
        filename = hash[:func_table][:filename][func_idx]

        "#{filename}:#{line}:in '#{name}'"
      end
    end
  end
end
