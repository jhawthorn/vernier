# frozen_string_literal: true

module Vernier
  module Output
    class Top
      def initialize(profile)
        @profile = profile
      end

      class Table
        def initialize(header)
          @header = header
          @rows = []
          yield self
        end

        def <<(row)
          @rows << row
        end

        def to_s
          (
            [
              row_separator,
              format_row(@header),
              row_separator
            ] + @rows.map do |row|
              format_row(row)
            end + [row_separator]
          ).join("\n")
        end

        def widths
          @widths ||=
            (@rows + [@header]).transpose.map do |col|
              col.map(&:size).max
            end
        end

        def row_separator
          @row_separator = "+" + widths.map { |i| "-" * (i + 2) }.join("+") + "+"
        end

        def format_row(row)
          "|" + row.map.with_index { |str, i| " " + str.ljust(widths[i] + 1) }.join("|") + "|"
        end
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

        total = stack_weights.values.sum

        top_by_self = Hash.new(0)
        stack_weights.each do |stack_idx, weight|
          frame_idx = stack_table.stack_frame_idx(stack_idx)
          func_idx = stack_table.frame_func_idx(frame_idx)
          name = stack_table.func_name(func_idx)
          top_by_self[name] += weight
        end

        Table.new %w[Samples % name] do |t|
          top_by_self.sort_by(&:last).reverse.each do |frame, samples|
            pct = 100.0 * samples / total
            t << [samples.to_s, pct.round(1).to_s, frame]
          end
        end.to_s
      end
    end
  end
end
