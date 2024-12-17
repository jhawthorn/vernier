module Vernier
  class Result
    attr_accessor :stack_table
    alias _stack_table stack_table

    attr_reader :gc_markers

    attr_accessor :hooks

    attr_accessor :pid, :end_time
    attr_accessor :threads
    attr_accessor :meta
    attr_accessor :mode

    def main_thread
      threads.values.detect {|x| x[:is_main] }
    end

    # TODO: remove these
    def weights; threads.values.flat_map { _1[:weights] }; end
    def samples; threads.values.flat_map { _1[:samples] }; end
    def sample_categories; threads.values.flat_map { _1[:sample_categories] }; end

    # Realtime in nanoseconds since the unix epoch
    def started_at
      started_at_mono_ns = meta[:started_at]
      current_time_mono_ns = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      current_time_real_ns = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
      (current_time_real_ns - current_time_mono_ns + started_at_mono_ns)
    end

    def to_gecko(gzip: false)
      Output::Firefox.new(self).output(gzip:)
    end

    def write(out:)
      gzip = out.end_with?(".gz")
      File.binwrite(out, to_gecko(gzip:))
    end

    def elapsed_seconds
      (end_time - started_at) / 1_000_000_000.0
    end

    def inspect
      "#<#{self.class} #{elapsed_seconds} seconds, #{threads.count} threads, #{samples.count} samples, #{samples.uniq.size} unique>"
    end

    def each_sample
      return enum_for(__method__) unless block_given?
      samples.size.times do |sample_idx|
        weight = weights[sample_idx]
        stack_idx = samples[sample_idx]
        yield stack(stack_idx), weight
      end
    end

    class BaseType
      attr_reader :stack_table, :idx
      def initialize(stack_table, idx)
        @stack_table = stack_table
        @idx = idx
      end

      def to_s
        idx.to_s
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
      Stack.new(_stack_table, idx)
    end

    def total_bytes
      weights.sum
    end
  end
end
