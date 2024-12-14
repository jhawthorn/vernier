# frozen_string_literal: true

require_relative "filename_filter"

module Vernier
  module Output
    class FileListing
      class SamplesByLocation
        attr_accessor :self, :total
        def initialize
          @self = @total = 0
        end

        def +(other)
          ret = SamplesByLocation.new
          ret.self = @self + other.self
          ret.total = @total + other.total
          ret
        end
      end

      def initialize(profile)
        @profile = profile
      end

      def output
        output = +""

        thread = @profile.main_thread
        if Hash === thread
          # live profile
          stack_table = @profile._stack_table
          weights = thread[:weights]
          samples = thread[:samples]
          filename_filter = FilenameFilter.new
        else
          stack_table = thread.stack_table
          weights = thread.weights
          samples = thread.samples
          filename_filter = ->(x) { x }
        end

        self_samples_by_frame = Hash.new do |h, k|
          h[k] = SamplesByLocation.new
        end

        total = weights.sum

        samples.zip(weights).each do |stack_idx, weight|
          # self time
          top_frame_index = stack_table.stack_frame_idx(stack_idx)
          self_samples_by_frame[top_frame_index].self += weight

          # total time
          while stack_idx
            frame_idx = stack_table.stack_frame_idx(stack_idx)
            self_samples_by_frame[frame_idx].total += weight
            stack_idx = stack_table.stack_parent_idx(stack_idx)
          end
        end

        samples_by_file = Hash.new do |h, k|
          h[k] = Hash.new do |h2, k2|
            h2[k2] = SamplesByLocation.new
          end
        end

        self_samples_by_frame.each do |frame, samples|
          line = stack_table.frame_line_no(frame)
          func_index = stack_table.frame_func_idx(frame)
          filename = stack_table.func_filename(func_index)

          samples_by_file[filename][line] += samples
        end

        samples_by_file.transform_keys! do |filename|
          filename_filter.call(filename)
        end

        relevant_files = samples_by_file.select do |k, v|
          next if k.start_with?("gem:")
          next if k.start_with?("rubylib:")
          next if k.start_with?("<")
          v.values.map(&:total).sum > total * 0.01
        end
        relevant_files.keys.sort.each do |filename|
          output << "="*80 << "\n"
          output << filename << "\n"
          output << "-"*80 << "\n"
          format_file(output, filename, samples_by_file, total: total)
        end
        output << "="*80 << "\n"
      end

      def format_file(output, filename, all_samples, total:)
        samples = all_samples[filename]

        # file_name, lines, file_wall, file_cpu, file_idle, file_sort
        output << sprintf(" TOTAL |  SELF  | LINE SOURCE\n")
        File.readlines(filename).each_with_index do |line, i|
          lineno = i + 1
          calls = samples[lineno]

          if calls && calls.total > 0
            output << sprintf("%5.1f%% | %5.1f%% | % 4i  %s", 100 * calls.total / total.to_f, 100 * calls.self / total.to_f, lineno, line)
          else
            output << sprintf("       |        | % 4i  %s", lineno, line)
          end
        end
      end
    end
  end
end
