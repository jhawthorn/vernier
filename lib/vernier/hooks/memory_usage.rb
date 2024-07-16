# frozen_string_literal: true

module Vernier
  module Hooks
    class MemoryUsage
      def initialize(collector)
        @collector = collector
        @tracker = Vernier::MemoryTracker.new
      end

      def enable
        @tracker.start
      end

      def disable
        @tracker.stop
      end

      def firefox_counters
        timestamps, memory = @tracker.results
        memory = ([0] + memory).each_cons(2).map { _2 - _1 }
        {
          name: "memory",
          category: "Memory",
          description: "Memory usage in bytes",
          pid: Process.pid,
          mainThreadIndex: 0,
          samples: {
            time: timestamps.map { _1 / 1_000_000.0 },
            count: memory,
            length: timestamps.length
          }
        }
      end
    end
  end
end
