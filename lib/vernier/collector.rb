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
        markers = self.markers.map do |tid, id, ts|
          [tid, @marker_strings[id], ts]
        end

        result.instance_variable_set(:@markers, markers)
      end

      result
    end
  end
end
