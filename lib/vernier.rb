# frozen_string_literal: true

require_relative "vernier/version"
require_relative "vernier/collector"
require_relative "vernier/result"
require_relative "vernier/vernier"
require_relative "vernier/output/firefox"
require_relative "vernier/output/top"

module Vernier
  class Error < StandardError; end

  def self.trace(mode: :wall, out: nil, interval: nil)
    collector = Vernier::Collector.new(mode, { interval: })
    collector.start

    result = nil
    begin
      yield collector
    ensure
      result = collector.stop
    end

    if out
      File.write(out, Output::Firefox.new(result).output)
    end
    result
  end

  def self.trace_retained(out: nil, gc: true)
    3.times { GC.start } if gc

    start_time = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)

    collector = Vernier::Collector.new(:retained)
    collector.start

    result = nil
    begin
      yield collector
    ensure
      result = collector.stop
      end_time = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
      result.pid = Process.pid
      result.start_time = start_time
      result.end_time = end_time
    end

    if out
      result.write(out:)
    end
    result
  end

  class Collector
    def self.new(mode, options = {})
      _new(mode, options)
    end
  end
end
