# frozen_string_literal: true

require_relative "filename_filter"
require_relative "../output_helpers"
require "cgi/escape"

module Vernier
  module Output
    class FileListing
      include OutputHelpers

      class SamplesByLocation
        attr_accessor :self, :total
        def initialize
          @self = @total = 0
        end
      end

      def initialize(profile)
        @profile = profile
      end

      def samples_by_file
        return @samples_by_file if defined?(@samples_by_file)

        thread = @profile.main_thread
        if Hash === thread
          # live profile
          stack_table = @profile._stack_table
          filename_filter = FilenameFilter.new
        else
          stack_table = thread.stack_table
          filename_filter = ->(x) { x }
        end

        weights = thread[:weights]
        samples = thread[:samples]

        stack_weights = collapse_stack_weights(samples, weights)

        self_by_frame, total_by_frame = frame_weights(stack_table, stack_weights)

        samples_by_file = Hash.new do |h, k|
          h[k] = Hash.new do |h2, k2|
            h2[k2] = SamplesByLocation.new
          end
        end

        self_by_frame.each_with_index do |self_weight, frame|
          total_weight = total_by_frame[frame]
          next if self_weight == 0 && total_weight == 0

          line = stack_table.frame_line_no(frame)
          func_index = stack_table.frame_func_idx(frame)
          filename = stack_table.func_filename(func_index)

          location = samples_by_file[filename][line]
          location.self += self_weight
          location.total += total_weight
        end

        @samples_by_file = samples_by_file.transform_keys! do |filename|
          filename_filter.call(filename)
        end
      end

      # Returns [self_weight, total_weight] arrays indexed by frame, from a
      # hash of per-stack weights.
      #
      # The stack table is a prefix tree whose parent is always interned
      # before its children (parent idx < child idx), so total weights are
      # accumulated bottom-up in a single reverse pass.
      private def frame_weights(stack_table, stack_weights)
        # Scatter the sparse weights into an array indexed by stack.
        stack_totals = Array.new(stack_table.stack_count, 0)
        stack_weights.each do |stack_idx, weight|
          stack_totals[stack_idx] = weight
        end

        # Accumulate each stack's total into its parent, children first,
        # so a single descending pass completes every subtree's total.
        (stack_totals.length - 1).downto(0) do |stack_idx|
          parent_idx = stack_table.stack_parent_idx(stack_idx)
          next unless parent_idx

          if parent_idx >= stack_idx
            raise "Invalid profile: stack table is not parent-before-child ordered"
          end

          stack_totals[parent_idx] += stack_totals[stack_idx]
        end

        self_by_frame = Array.new(stack_table.frame_count, 0)
        total_by_frame = Array.new(stack_table.frame_count, 0)
        stack_weights.each do |stack_idx, weight|
          self_by_frame[stack_table.stack_frame_idx(stack_idx)] += weight
        end
        stack_totals.each_with_index do |total, stack_idx|
          next if total == 0

          total_by_frame[stack_table.stack_frame_idx(stack_idx)] += total
        end

        [self_by_frame, total_by_frame]
      end

      def output(template: nil)
        output = +""

        relevant_files = samples_by_file.select do |k, v|
          next if k.start_with?("gem:")
          next if k.start_with?("rubylib:")
          next if k.start_with?("<")
          v.values.map(&:total).sum > total * 0.01
        end

        if template == "html"
          html_output(output, relevant_files)
        else
          relevant_files.keys.sort.each do |filename|
            output << "="*80 << "\n"
            output << filename << "\n"
            output << "-"*80 << "\n"
            format_file(output, filename, samples_by_file, total: total)
          end
          output << "="*80 << "\n"
        end
      end

      def total
        @total ||= @profile.main_thread[:weights].sum
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

      def html_output(output, relevant_files)
        output << "<pre>"
        output << "  SELF     FILE\n"
        relevant_files.sort_by {|k, v| -v.values.map(&:self).sum }.each do |filename, file_contents|
          tmpl = "<details style=\"display:inline-block;vertical-align:top;\"><summary>%s</summary>"
          output << sprintf("% 5.1f%%   #{tmpl}\n", file_contents.values.map(&:self).sum * 100 / total.to_f, filename)
          format_file_html(output, filename, relevant_files)
          output << "</details>\n"
        end
        output << "</pre>"
      end

      def format_file_html(output, filename, relevant_files)
        samples = relevant_files[filename]

        # file_name, lines, file_wall, file_cpu, file_idle, file_sort
        output << sprintf(" TOTAL |  SELF  | LINE SOURCE\n")
        File.readlines(filename).each_with_index do |line, i|
          lineno = i + 1
          calls = samples[lineno]

          if calls && calls.total > 0
            output << sprintf("%5.1f%% | %5.1f%% | % 4i  %s", 100 * calls.total / total.to_f, 100 * calls.self / total.to_f, lineno, CGI::escapeHTML(line))
          else
            output << sprintf("       |        | % 4i  %s", lineno, CGI::escapeHTML(line))
          end
        end
      end
    end
  end
end
