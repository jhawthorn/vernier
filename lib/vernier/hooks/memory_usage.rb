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
          pid: Process.pid.to_s,
          mainThreadIndex: 0,
          samples: {
            time: timestamps.map { _1 / 1_000_000.0 },
            count: memory,
            length: timestamps.length
          },
          display: {
            graphType: "line-accumulated",
            unit: "bytes",
            color: "orange",
            markerSchemaLocation: "timeline-memory",
            sortWeight: 20,
            label: "Memory",
            tooltipRows: [
              {
                type: "value",
                source: "accumulated",
                format: { unit: "bytes" },
                label: "relative memory at this time"
              },
              {
                type: "value",
                source: "count-range",
                format: { unit: "bytes" },
                label: "memory range in graph"
              },
              {
                type: "value",
                source: "sample-number",
                format: { unit: "number" },
                label: "allocations and deallocations since the previous sample"
              }
            ]
          }
        }
      end
    end
  end
end
