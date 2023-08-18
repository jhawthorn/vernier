# frozen_string_literal: true

require_relative "marker"

module Vernier
  class Collector
    def initialize(mode)
      @mode = mode
      @markers = []
    end

    ##
    # Get the current time.
    #
    # This method returns the current time from Process.clock_gettime in
    # integer nanoseconds.  It's the same time used by Vernier internals and
    # can be used to generate timestamps for custom markers.
    def current_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end

    def add_marker(name:, type: name.to_sym, start:, finish:, thread: Thread.current.native_thread_id, phase: Marker::Phase::INTERVAL, data: nil)
      @markers << [thread,
                   name,
                   type,
                   start,
                   finish,
                   phase,
                   data]
    end

    ##
    # Record an interval with a name.  Yields to a block and records the amount
    # of time spent in the block as an interval marker.
    def record_interval name
      start = current_time
      yield
      add_marker(
        name:,
        start:,
        finish: current_time,
        phase: Marker::Phase::INTERVAL,
        thread: Thread.current.native_thread_id
      )
    end

    def stop
      result = finish

      markers = []
      marker_list = self.markers
      size = marker_list.size
      marker_strings = Marker.name_table

      marker_list.each_with_index do |(tid, id, ts), i|
        name = marker_strings[id]
        sym = Marker::MARKER_SYMBOLS[id]
        finish = nil
        phase = Marker::Phase::INSTANT

        if id == Marker::Type::GC_EXIT
          # skip because these are incorporated in "GC enter"
        else
          if id == Marker::Type::GC_ENTER
            j = i + 1

            name = "GC pause"
            phase = Marker::Phase::INTERVAL

            while j < size
              if marker_list[j][1] == Marker::Type::GC_EXIT
                finish = marker_list[j][2]
                break
              end

              j += 1
            end
          end

          markers << [tid, name, sym, ts, finish, phase]
        end
      end

      markers.concat @markers

      result.instance_variable_set(:@markers, markers)

      result
    end
  end
end
