# frozen_string_literal: true

require_relative "filename_filter"

module Vernier
  module Output
    class Markdown
      DEFAULT_TOP_N = 20
      DEFAULT_LINES_PER_FILE = 5

      def initialize(profile, top_n: DEFAULT_TOP_N, lines_per_file: DEFAULT_LINES_PER_FILE)
        @profile = profile
        @top_n = top_n
        @lines_per_file = lines_per_file
      end

      def output
        out = +""
        out << build_title
        out << build_summary
        out << build_hotspots
        out << build_threads
        out << build_files
        out
      end

      private

      def build_title
        "# Vernier Profile\n\n"
      end

      def build_summary
        out = +"## Summary\n\n"

        mode = @profile.meta[:mode] rescue nil
        weight_unit = mode == :retained ? "bytes" : "samples"

        out << "| Metric | Value |\n"
        out << "|--------|-------|\n"
        out << "| Mode | #{mode || 'unknown'} |\n"

        if @profile.respond_to?(:elapsed_seconds)
          begin
            out << "| Duration | #{format("%.2f", @profile.elapsed_seconds)} seconds |\n"
          rescue
            # elapsed_seconds may fail if end_time not set
          end
        end

        out << "| Total Samples | #{total_samples} |\n"
        out << "| Total Unique Samples | #{@profile.total_unique_samples rescue 'N/A'} |\n"
        out << "| Threads | #{thread_count} |\n"
        out << "| Weight Unit | #{weight_unit} |\n"

        if @profile.respond_to?(:pid) && @profile.pid
          out << "| PID | #{@profile.pid} |\n"
        end

        out << "\n"

        # User metadata if available
        if @profile.respond_to?(:meta) && @profile.meta[:user_metadata]
          metadata = @profile.meta[:user_metadata]
          unless metadata.empty?
            out << "### User Metadata\n\n"
            out << "| Key | Value |\n"
            out << "|-----|-------|\n"
            metadata.each do |k, v|
              out << "| #{escape_markdown(k.to_s)} | #{escape_markdown(v.to_s)} |\n"
            end
            out << "\n"
          end
        end

        out
      end

      def build_hotspots
        out = +"## Top Hotspots\n\n"

        thread = main_thread
        return out << "_No samples collected._\n\n" unless thread

        stack_table = get_stack_table(thread)
        samples = thread[:samples] || []
        weights = thread[:weights] || []

        return out << "_No samples collected._\n\n" if samples.empty?

        # Compute self weights per function
        total = weights.sum
        return out << "_No samples collected._\n\n" if total == 0

        top_by_func = Hash.new { |h, k| h[k] = { self: 0, total: 0, file: nil, line: nil } }

        samples.zip(weights).each do |stack_idx, weight|
          # Self time: top frame only
          frame_idx = stack_table.stack_frame_idx(stack_idx)
          func_idx = stack_table.frame_func_idx(frame_idx)
          name = stack_table.func_name(func_idx)
          filename = stack_table.func_filename(func_idx)
          first_lineno = stack_table.func_first_lineno(func_idx)

          top_by_func[name][:self] += weight
          top_by_func[name][:file] ||= filename
          top_by_func[name][:line] ||= first_lineno

          # Total time: walk up the stack
          seen = {}
          current_stack_idx = stack_idx
          while current_stack_idx
            frame_idx = stack_table.stack_frame_idx(current_stack_idx)
            func_idx = stack_table.frame_func_idx(frame_idx)
            func_name = stack_table.func_name(func_idx)

            unless seen[func_name]
              seen[func_name] = true
              top_by_func[func_name][:total] += weight
              top_by_func[func_name][:file] ||= stack_table.func_filename(func_idx)
              top_by_func[func_name][:line] ||= stack_table.func_first_lineno(func_idx)
            end

            current_stack_idx = stack_table.stack_parent_idx(current_stack_idx)
          end
        end

        out << top_functions_table("By Self Time", top_by_func, total, :self)
        out << top_functions_table("By Total Time", top_by_func, total, :total)

        out
      end

      def top_functions_table(title, funcs, total, sort_key)
        out = +"### #{title}\n\n"
        sorted = funcs.sort_by { |_, v| -v[sort_key] }.first(@top_n)

        primary = sort_key == :self ? "Self" : "Total"
        secondary = sort_key == :self ? "Total" : "Self"
        out << "| Rank | #{primary} % | #{secondary} % | Function | Location |\n"
        out << "|------|--------|---------|----------|----------|\n"

        sorted.each_with_index do |(name, data), idx|
          self_pct = 100.0 * data[:self] / total
          total_pct = 100.0 * data[:total] / total
          primary_pct = sort_key == :self ? self_pct : total_pct
          secondary_pct = sort_key == :self ? total_pct : self_pct
          location = format_location(data[:file], data[:line])
          out << "| #{idx + 1} | #{format("%.1f", primary_pct)}% | #{format("%.1f", secondary_pct)}% | #{format_code_span(name)} | #{escape_markdown(location)} |\n"
        end

        out << "\n"
        out
      end

      def build_threads
        out = +"## Threads\n\n"

        threads_data = get_threads
        return out << "_No thread information available._\n\n" if threads_data.empty?

        threads_data.each do |thread_id, thread|
          name = get_thread_name(thread) || "Thread #{thread_id}"
          is_main = get_thread_main(thread) ? "yes" : "no"
          tid = get_thread_tid(thread) || thread_id

          samples = thread[:samples] || []
          weights = thread[:weights] || []
          sample_count = samples.size
          weight_sum = weights.sum

          out << "### #{escape_markdown(name)}\n\n"
          out << "| Property | Value |\n"
          out << "|----------|-------|\n"
          out << "| TID | #{tid} |\n"
          out << "| Main Thread | #{is_main} |\n"
          out << "| Samples | #{sample_count} |\n"
          out << "| Total Weight | #{weight_sum} |\n"
          out << "\n"
        end

        out
      end

      def build_files
        out = +"## Hot Files\n\n"

        thread = main_thread
        return out << "_No file information available._\n\n" unless thread

        stack_table = get_stack_table(thread)
        samples = thread[:samples] || []
        weights = thread[:weights] || []

        return out << "_No samples collected._\n\n" if samples.empty?

        total = weights.sum
        return out << "_No samples collected._\n\n" if total == 0

        # Build samples by file and line (similar to FileListing)
        samples_by_frame = Hash.new { |h, k| h[k] = { self: 0, total: 0 } }

        samples.zip(weights).each do |stack_idx, weight|
          # Self time: top frame only
          top_frame_idx = stack_table.stack_frame_idx(stack_idx)
          samples_by_frame[top_frame_idx][:self] += weight

          # Total time: walk up the stack
          current_stack_idx = stack_idx
          while current_stack_idx
            frame_idx = stack_table.stack_frame_idx(current_stack_idx)
            samples_by_frame[frame_idx][:total] += weight
            current_stack_idx = stack_table.stack_parent_idx(current_stack_idx)
          end
        end

        # Group by file
        samples_by_file = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = { self: 0, total: 0 } } }

        samples_by_frame.each do |frame_idx, data|
          func_idx = stack_table.frame_func_idx(frame_idx)
          filename = stack_table.func_filename(func_idx)
          line = stack_table.frame_line_no(frame_idx)

          filename = filter_filename(filename)
          samples_by_file[filename][line][:self] += data[:self]
          samples_by_file[filename][line][:total] += data[:total]
        end

        # Filter to relevant files (>1% self time, exclude gem/rubylib/<)
        relevant_files = samples_by_file.select do |filename, lines|
          next false if filename.start_with?("gem:")
          next false if filename.start_with?("rubylib:")
          next false if filename.start_with?("<")

          lines.values.map { |d| d[:self] }.max > total * 0.01
        end

        if relevant_files.empty?
          return out << "_No significant file hotspots found._\n\n"
        end

        # Sort files by total weight
        sorted_files = relevant_files.sort_by { |_, lines| -lines.values.map { |d| d[:self] }.sum }

        sorted_files.each do |filename, lines|
          out << "### #{escape_markdown(filename)}\n\n"

          # Get top lines by self weight
          sorted_lines = lines.sort_by { |_, d| -d[:self] }.first(@lines_per_file)

          out << "| Line | Self % | Total % | Code |\n"
          out << "|------|--------|---------|------|\n"

          sorted_lines.each do |line_no, data|
            self_pct = 100.0 * data[:self] / total
            total_pct = 100.0 * data[:total] / total

            source_line = read_source_line(filename, line_no)
            code = source_line ? truncate_code(source_line) : "_source unavailable_"

            out << "| #{line_no} | #{format("%.1f", self_pct)}% | #{format("%.1f", total_pct)}% | #{format_code_span(code)} |\n"
          end

          out << "\n"
        end

        out
      end

      # Helper methods

      def main_thread
        @profile.main_thread
      end

      def get_threads
        if @profile.respond_to?(:threads)
          threads = @profile.threads
          if threads.is_a?(Hash)
            threads
          elsif threads.is_a?(Array)
            # ParsedProfile returns array
            threads.each_with_index.to_h { |t, i| [i, t] }
          else
            {}
          end
        else
          {}
        end
      end

      def get_stack_table(thread)
        if thread.respond_to?(:stack_table)
          thread.stack_table
        else
          @profile._stack_table
        end
      end

      def get_thread_name(thread)
        if thread.is_a?(Hash)
          thread[:name]
        elsif thread.respond_to?(:data)
          thread.data["name"]
        end
      end

      def get_thread_main(thread)
        if thread.is_a?(Hash)
          thread[:is_main]
        elsif thread.respond_to?(:main_thread?)
          thread.main_thread?
        end
      end

      def get_thread_tid(thread)
        if thread.is_a?(Hash)
          thread[:tid]
        elsif thread.respond_to?(:data)
          thread.data["tid"]
        end
      end

      def total_samples
        if @profile.respond_to?(:total_samples)
          @profile.total_samples
        else
          main = main_thread
          main ? (main[:samples]&.size || 0) : 0
        end
      end

      def thread_count
        threads = get_threads
        threads.is_a?(Hash) ? threads.size : threads.length
      end

      def filter_filename(filename)
        @filename_filter ||= if live_profile?
          FilenameFilter.new
        else
          ->(x) { x }
        end
        @filename_filter.call(filename)
      end

      def live_profile?
        thread = main_thread
        thread.is_a?(Hash)
      end

      def format_location(file, line)
        return "unknown" unless file
        filtered = filter_filename(file)
        line ? "#{filtered}:#{line}" : filtered
      end

      def read_source_line(filename, line_no)
        return nil unless line_no && line_no > 0

        # For filtered filenames, try to resolve back to real path
        real_path = resolve_filename(filename)
        return nil unless real_path && File.exist?(real_path)

        lines = File.readlines(real_path)
        lines[line_no - 1]&.chomp
      rescue
        nil
      end

      def resolve_filename(filename)
        return nil if filename.start_with?("gem:", "rubylib:", "<")
        return filename if File.exist?(filename)

        # Try expanding relative to cwd
        expanded = File.expand_path(filename)
        return expanded if File.exist?(expanded)

        nil
      end

      def truncate_code(code, max_length: 60)
        code = code.strip
        if code.length > max_length
          code[0, max_length - 3] + "..."
        else
          code
        end
      end

      def format_code_span(text)
        content = text.to_s.gsub("|", "\\|")

        # Find longest run of consecutive backticks in content
        max_run = content.scan(/`+/).map(&:length).max || 0
        delimiter = "`" * (max_run + 1)

        if delimiter.length > 1
          "#{delimiter} #{content} #{delimiter}"
        else
          "#{delimiter}#{content}#{delimiter}"
        end
      end

      def escape_markdown(text)
        return "" unless text
        text.to_s
          .gsub("&", "&amp;")
          .gsub("<", "&lt;")
          .gsub(">", "&gt;")
          .gsub(/([|`*_\[\]])/, '\\\\\1')
      end
    end
  end
end
