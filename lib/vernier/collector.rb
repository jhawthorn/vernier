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
        marker_names = []
        marker_timestamps = []
        marker_threads = []

        markers.each do |tid, id, ts|
          marker_names << @marker_strings[id]
          marker_timestamps << ts
          marker_threads << tid
        end

        result.instance_variable_set(:@marker_timestamps, marker_timestamps)
        result.instance_variable_set(:@marker_threads, marker_threads)
        result.instance_variable_set(:@marker_names, marker_names)
      end

      result
    end
  end
end
