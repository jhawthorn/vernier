# frozen_string_literal: true

require_relative "marker"

module Vernier
  class Collector
    def initialize(mode)
      @mode = mode
    end

    def stop
      result = finish

      markers = []
      marker_list = self.markers
      size = marker_list.size
      marker_strings = Marker.name_table

      marker_list.each_with_index do |(tid, id, ts), i|
        name = marker_strings[id]
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

          markers << [tid, name, ts, finish, phase]
        end
      end

      result.instance_variable_set(:@markers, markers)

      result
    end
  end
end
