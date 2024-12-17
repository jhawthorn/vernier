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

    def stack(idx)
      stack_table.stack(idx)
    end

    def total_bytes
      weights.sum
    end
  end
end
