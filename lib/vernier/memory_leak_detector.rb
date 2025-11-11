# frozen_string_literal: true

module Vernier
  class MemoryLeakDetector
    def self.start_thread(...)
      detector = new(...)
      detector.start_thread
      detector
    end

    def initialize(collect_time:, drain_time:, **collector_options)
      @collect_time = collect_time
      @drain_time = drain_time
      @collector_options = collector_options
      @thread = nil
    end

    def start_thread
      @thread = Thread.new do
        collector = Collector.new(:retained, @collector_options)
        collector.start

        sleep @collect_time

        collector.drain

        sleep @drain_time

        collector.stop
      end
    end

    def result
      @thread&.value
    end
  end
end
