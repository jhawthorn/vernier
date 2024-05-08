module Vernier
  class Result
    def stack_table
      @stack_table[:stack_table]
    end

    def frame_table
      @stack_table[:frame_table]
    end

    def func_table
      @stack_table[:func_table]
    end

    attr_reader :markers

    attr_accessor :hooks

    attr_accessor :pid, :end_time
    attr_accessor :threads
    attr_accessor :meta

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
      attr_reader :result, :idx
      def initialize(result, idx)
        @result = result
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
        result.func_table[:name][idx]
      end
      alias name label

      def filename
        result.func_table[:filename][idx]
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
        func_idx = result.frame_table[:func][idx]
        Func.new(result, func_idx)
      end

      def line
        result.frame_table[:line][idx]
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
          frame_idx = result.stack_table[:frame][stack_idx]
          yield Frame.new(result, frame_idx)
          stack_idx = result.stack_table[:parent][stack_idx]
        end
      end

      def leaf_frame_idx
        result.stack_table[:frame][idx]
      end

      def leaf_frame
        Frame.new(result, leaf_frame_idx)
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

    def total_bytes
      weights.sum
    end
  end
end
