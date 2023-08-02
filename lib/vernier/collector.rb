# frozen_string_literal: true

require_relative "marker"

module Vernier
  class Collector
    def initialize(mode)
      @mode = mode
      @marker_strings = Marker.name_table
    end

    def stop
      result = finish

      if @mode == :wall
        result.instance_variable_set(:@marker_timestamps, marker_timestamps)
        result.instance_variable_set(:@marker_threads, marker_threads)
        result.instance_variable_set(:@marker_strings, @marker_strings)
        result.instance_variable_set(:@marker_ids, marker_ids)
      end

      result
    end
  end
end
