# frozen_string_literal: true

module Vernier
  class Result
    attr_accessor :stack_table
    alias _stack_table stack_table

    attr_accessor :hooks, :pid, :end_time

    attr_reader :meta, :threads, :gc_markers

    def main_thread
      threads.values.detect {|x| x[:is_main] }
    end

    # Realtime in nanoseconds since the unix epoch
    def started_at
      started_at_mono_ns = meta[:started_at]
      current_time_mono_ns = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      current_time_real_ns = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
      (current_time_real_ns - current_time_mono_ns + started_at_mono_ns)
    end

    def to_firefox(gzip: false)
      Output::Firefox.new(self).output(gzip:)
    end
    alias_method :to_gecko, :to_firefox

    def to_cpuprofile
      Output::Cpuprofile.new(self).output
    end

    def write(out:, format: "firefox")
      case format
      when "cpuprofile"
        if out.respond_to?(:write)
          out.write(to_cpuprofile)
        else
          File.binwrite(out, to_cpuprofile)
        end
      when "firefox", nil
        if out.respond_to?(:write)
          out.write(to_firefox)
        else
          File.binwrite(out, to_firefox(gzip: out.end_with?(".gz")))
        end
      else
        raise ArgumentError, "unknown format: #{format}"
      end
    end

    def elapsed_seconds
      (end_time - started_at) / 1_000_000_000.0
    end

    def inspect
      "#<#{self.class} #{elapsed_seconds rescue "?"} seconds, #{threads.count} threads, #{total_samples} samples, #{total_unique_samples} unique>"
    end

    def each_sample
      return enum_for(__method__) unless block_given?
      threads.values.each do |thread|
        thread[:samples].zip(thread[:weights]) do |stack_idx, weight|
          yield stack(stack_idx), weight
        end
      end
    end

    def stack(idx)
      stack_table.stack(idx)
    end

    def total_weights
      threads.values.sum { _1[:weights].sum }
    end

    def total_bytes
      unless meta[:mode] == :retained
        raise NotImplementedError, "total_bytes is only implemented for retained mode"
      end

      total_weights
    end

    def total_samples
      threads.values.sum { _1[:samples].count }
    end

    def total_unique_samples
      threads.values.flat_map { _1[:samples] }.uniq.count
    end
  end
end
