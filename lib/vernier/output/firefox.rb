# frozen_string_literal: true

require "json"

module Vernier
  module Output
    # https://profiler.firefox.com/
    # https://github.com/firefox-devtools/profiler/blob/main/src/types/profile.js
    class Firefox
      def initialize(profile)
        @profile = profile

        names = profile.func_table.fetch(:name)
        filenames = profile.func_table.fetch(:filename)

        @strings = Hash.new { |h, k| h[k] = h.size }
        @func_names = names.map do |name|
          @strings[name]
        end
        @filenames = filenames.map do |filename|
          @strings[filename]
        end
      end

      def output
        ::JSON.generate(data)
      end

      private

      attr_reader :profile

      def data
        {
          meta: {
            interval: 1, # FIXME: memory vs wall
            startTime: 0,
            endTime: profile.total_bytes, # FIXME
            processType: 0,
            product: "Ruby/Vernier",
            stackwalk: 1,
            version: 28,
            preprocessedProfileVersion: 47,
            symbolicated: true,
            markerSchema: [],
            sampleUnits: {
              time: "ms",
              eventDelay: "ms",
              threadCPUDelta: "µs"
            } # FIXME: memory vs wall
          },
          libs: [],
          threads: [
            {
              name: "Main",
              isMainThread: true,
              processStartupTime: 0, # FIXME
              processShutdownTime: nil, # FIXME
              registerTime: 0,
              unregisterTime: nil,
              pausedRanges: [],
              pid: 123,
              tid: 456,
              frameTable: frame_table,
              funcTable: func_table,
              nativeSymbols: {},
              stackTable: stack_table,
              samples: samples_table,
              resourceTable: {
                length: 0,
                lib: [],
                name: [],
                host: [],
                type: []
              },
              markers: {
                data: [],
                name: [],
                startTime: [],
                endTime: [],
                phase: [],
                category: [],
                length: 0
              },
              stringArray: string_table
            }
          ]
        }
      end

      def samples_table
        samples = profile.samples
        weights = profile.weights
        size = samples.size

        times = []
        t = 0
        weights.each do |w|
          times << t
          t += w
        end

        raise unless samples.size == size
        raise unless weights.size == size
        raise unless times.size == size

        {
          stack: samples,
          time: times,
          weight: weights,
          #weightType: "samples",
          weightType: "bytes",
          length: samples.length
        }
      end

      def stack_table
        frames = profile.stack_table.fetch(:frame)
        prefixes = profile.stack_table.fetch(:parent)
        size = frames.length
        raise unless frames.size == size
        raise unless prefixes.size == size
        {
          frame: frames,
          category: [1] * size,
          subcategory: [0] * size,
          prefix: prefixes,
          length: prefixes.length
        }
      end

      def frame_table
        funcs = profile.frame_table.fetch(:func)
        lines = profile.frame_table.fetch(:line)
        size = funcs.length
        none = [nil] * size

        raise unless lines.size == funcs.size

        {
          address: [-1] * size,
          inlineDepth: [0] * size,
          category: nil,
          subcategory: nil,
          func: funcs,
          nativeSymbol: none,
          innerWindowID: none,
          implementation: none,
          line: lines,
          column: none,
          length: size
        }
      end

      def func_table
        size = @func_names.size
        {
          name: @func_names,
          isJS: [false] * size,
          relevantForJS: [false] * size,
          resource: [-1] * size, # set to unidentified for now
          fileName: @filenames,
          lineNumber: [0] * size,
          columnNumber: [0] * size,
          #lineNumber: functions.map { _1.line },
          #columnNumber: functions.map { _1.column },
          length: size
        }
      end

      def string_table
        @strings.keys
      end
    end
  end
end
