# frozen_string_literal: true

require_relative "vernier/version"
require_relative "vernier/vernier"
require_relative "vernier/output/firefox"

module Vernier
  class Error < StandardError; end

  class Result
    attr_reader :weights, :samples, :stack_table, :frame_table, :func_table

    attr_reader :pid, :start_time, :end_time

    def initialize(result)
      @samples = result.fetch(:samples)
      @weights = result.fetch(:weights)
      @stack_table = result.fetch(:stack_table)
      @frame_table = result.fetch(:frame_table)
      @func_table = result.fetch(:func_table)

      @pid = result.fetch(:pid)
      @start_time = result.fetch(:start_time)
      @end_time = result.fetch(:end_time)
    end

    def each_sample
      @samples.size.times do |sample_idx|
        weight = @weights[sample_idx]
        stack_idx = @samples[sample_idx]
      end
    end

    class Func < Struct.new(:result, :idx)
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

    class Frame < Struct.new(:result, :idx)
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

    class Stack < Struct.new(:result, :idx)
      def each_frame
        return enum_for(__method__) unless block_given?

        stack_idx = idx
        while stack_idx
          frame_idx = result.stack_table[:frame][stack_idx]
          yield Frame.new(result, frame_idx)
          stack_idx = result.stack_table[:parent][stack_idx]
        end
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

      def inspect
        "#<#{self.class}\n#{self}>"
      end
    end

    def stack(idx)
      Stack.new(self, idx)
    end
  end

  class RetainedResult < Result
    def total_bytes
      @weights.sum
    end
  end

  def self.trace_retained(out: nil, gc: true)
    3.times { GC.start } if gc

    start_time = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)

    Vernier.trace_retained_start

    result = nil
    begin
      yield
    ensure
      data = trace_retained_stop
      end_time = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
      data.update(
        pid: Process.pid,
        start_time: start_time,
        end_time: end_time,
      )
      result = RetainedResult.new(data)
    end

    if out
      File.write(out, Output::Firefox.new(result).output)
    end
    result
  end
end
