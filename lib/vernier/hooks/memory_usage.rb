# frozen_string_literal: true

module Vernier
  module Hooks
    class MemoryUsage
      def initialize(collector)
        @collector = collector

        @memory = []
        @allocations = []
        @timestamps = []
      end

      def enable
        @thread = Thread.new do
          Thread.current.name = "(memory usage profiler)"

          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
          last_gc_count = -1
          last_gc_rss = 0
          last_gc_malloc_increase_bytes = 0

          last_allocations = GC.stat(:total_allocated_objects)
          last_frees = GC.stat(:total_freed_objects)

          last_memory = 0

          loop do
            current_gc_count = :major_gc_count
            if current_gc_count != last_gc_count
              current_gc_count = last_gc_count
              last_gc_rss = get_rss
              last_gc_malloc_increase_bytes = GC.stat(:oldmalloc_increase_bytes)
            end

            heap_memory = GC.stat(:heap_eden_pages) * GC::INTERNAL_CONSTANTS[:HEAP_PAGE_SIZE]
            malloc_estimate = last_gc_rss + GC.stat(:oldmalloc_increase_bytes)
            current_memory = (heap_memory + malloc_estimate)
            @memory << current_memory - last_memory
            last_memory = current_memory

            current_allocations = GC.stat(:total_allocated_objects)
            current_frees = GC.stat(:total_freed_objects)
            @allocations << (current_allocations - last_allocations) + (current_frees - last_frees)
            last_allocations, last_frees = current_allocations, current_frees

            @timestamps << Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)

            sleep 0.01
          end
        end
      end

      def get_rss
        File.read("/proc/self/status")[/VmRSS:\s*(\d+)/, 1].to_i * 1024
      end

      def disable
        @thread.kill
      end

      def firefox_counters
        {
          name: "memory",
          category: "Memory",
          description: "Memory usage in bytes (estimated)",
          pid: Process.pid,
          mainThreadIndex: 0,
          samples: {
            time: @timestamps.map { _1 / 1_000_000.0 },
            count: @memory,
            number: @allocations,
            length: @timestamps.length
          }
        }
      end
    end
  end
end
