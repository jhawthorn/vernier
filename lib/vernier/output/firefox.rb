# frozen_string_literal: true

require "json"

module Vernier
  module Output
    # https://profiler.firefox.com/
    # https://github.com/firefox-devtools/profiler/blob/main/src/types/profile.js
    class Firefox
      class Categorizer
        attr_reader :categories, :gc_category, :jit_category
        def initialize
          @categories = []

          add_category(name: "Default", color: "grey")
          add_category(name: "Idle", color: "transparent")
          @gc_category = add_category(name: "GC", color: "red")
          add_category(
            name: "stdlib",
            color: "red",
            matcher: starts_with(RbConfig::CONFIG["rubylibdir"])
          )
          add_category(name: "cfunc", color: "yellow", matcher: "<cfunc>")

          rails_components = %w[ activesupport activemodel activerecord
          actionview actionpack activejob actionmailer actioncable
          activestorage actionmailbox actiontext railties ]
          add_category(
            name: "Rails",
            color: "green",
            matcher: gem_path(*rails_components)
          )
          add_category(
            name: "gem",
            color: "red",
            matcher: starts_with(*Gem.path)
          )
          add_category(
            name: "Application",
            color: "purple"
          )
          @jit_category = add_category(
            name: "JIT",
            color: "blue"
          )
        end

        def add_category(**kw)
          category = Category.new(@categories.length, **kw)
          @categories << category
          category
        end

        def starts_with(*paths)
          %r{\A#{Regexp.union(paths)}}
        end

        def gem_path(*names)
          %r{\A#{Regexp.union(Gem.path)}/gems/#{Regexp.union(names)}}
        end

        def categorize(path)
          @categories.detect { |category| category.matches?(path) } || @categories.first
        end

        class Category
          attr_reader :idx, :name, :color, :matcher
          def initialize(idx, name:, color:, matcher: nil)
            @idx = idx
            @name = name
            @color = color
            @matcher = matcher
          end

          def matches?(path)
            @matcher && @matcher === path
          end
        end
      end

      def initialize(profile)
        @profile = profile
        @categorizer = Categorizer.new
      end

      def output
        ::JSON.generate(data)
      end

      private

      attr_reader :profile

      def data
        threads = Hash.new {|h,k| h[k] = {
          timestamps: [],
          weights: [],
          samples: [],
          categories: [],
          markers: [],
        }}

        profile.samples.size.times do |i|
          tid = profile.sample_threads[i]
          thread = threads[tid]

          thread[:timestamps] << profile.timestamps[i]
          thread[:weights] << profile.weights[i]
          thread[:samples] << profile.samples[i]
          thread[:categories] << profile.sample_categories[i]
        end

        profile.markers.each do |marker|
          threads[marker[0]][:markers] << marker
        end

        thread_data = profile.threads.map do |tid, thread_info|
          data = threads[tid]
          Thread.new(
            profile,
            @categorizer,
            **thread_info,
            **data
          ).data
        end

        {
          meta: {
            interval: 1, # FIXME: memory vs wall
            startTime: profile.meta[:started_at] / 1_000_000.0,
            endTime: (profile.timestamps&.max || 0) / 1_000_000.0,
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
            }, # FIXME: memory vs wall
            categories: @categorizer.categories.map do |category|
              {
                name: category.name,
                color: category.color,
                subcategories: []
              }
            end
          },
          libs: [],
          threads: thread_data
        }
      end

      class Thread
        attr_reader :profile

        def initialize(profile, categorizer, name:, tid:, samples:, weights:, timestamps:, categories:, markers:, started_at:, stopped_at: nil)
          @profile = profile
          @categorizer = categorizer
          @tid = tid
          @name = name

          @samples, @weights, @timestamps = samples, weights, timestamps
          @sample_categories = categories
          @markers = markers

          @started_at, @stopped_at = started_at, stopped_at

          names = profile.func_table.fetch(:name)
          filenames = profile.func_table.fetch(:filename)

          stacks_size = profile.stack_table.fetch(:frame).size
          @categorized_stacks = Hash.new do |h, k|
            h[k] = h.size + stacks_size
          end

          @strings = Hash.new { |h, k| h[k] = h.size }
          @func_names = names.map do |name|
            @strings[name]
          end
          @filenames = filenames.map do |filename|
            @strings[filename]
          end
          @frame_categories = filenames.map do |filename|
            @categorizer.categorize(filename)
          end
        end

        def data
          {
            name: @name,
            isMainThread: @tid == ::Thread.main.native_thread_id,
            processStartupTime: 0, # FIXME
            processShutdownTime: nil, # FIXME
            registerTime: (@started_at - 0) / 1_000_000.0,
            unregisterTime: ((@stopped_at - 0) / 1_000_000.0 if @stopped_at),
            pausedRanges: [],
            pid: profile.pid || Process.pid,
            tid: @tid,
            frameTable: frame_table,
            funcTable: func_table,
            nativeSymbols: {},
            samples: samples_table,
            stackTable: stack_table,
            resourceTable: {
              length: 0,
              lib: [],
              name: [],
              host: [],
              type: []
            },
            markers: markers_table,
            stringArray: string_table
          }
        end

        def markers_table
          size = @markers.size

          string_indexes = []
          start_times = []
          end_times = []
          phases = []
          categories = []

          @markers.each_with_index do |(_, name, start, finish, phase), i|
            string_indexes << @strings[name]
            start_times << (start / 1_000_000.0)

            # Please don't hate me. Divide by 1,000,000 only if finish is not nil
            end_times << (finish&./(1_000_000.0))
            phases << phase
            categories << (name =~ /GC/ ? gc_category.idx : 0)
          end

          {
            data: [nil] * start_times.size,
            name: string_indexes,
            startTime: start_times,
            endTime: end_times,
            phase: phases,
            category: categories,
            length: start_times.size
          }
        end

        def samples_table
          samples = @samples
          weights = @weights
          categories = @sample_categories
          size = samples.size
          if categories.empty?
            categories = [0] * size
          end

          if @timestamps
            times = @timestamps.map { _1 / 1_000_000.0 }
          else
            # FIXME: record timestamps for memory samples
            times = (0...size).to_a
          end

          raise unless samples.size == size
          raise unless weights.size == size
          raise unless times.size == size

          samples = samples.zip(categories).map do |sample, category|
            if category == 0
              sample
            else
              @categorized_stacks[[sample, category]]
            end
          end

          {
            stack: samples,
            time: times,
            weight: weights,
            weightType: "samples",
            #weightType: "bytes",
            length: samples.length
          }
        end

        def stack_table
          frames = profile.stack_table.fetch(:frame).dup
          prefixes = profile.stack_table.fetch(:parent).dup
          categories  = frames.map{|idx| @frame_categories[idx].idx }

          @categorized_stacks.keys.each do |(stack, category)|
            frames << frames[stack]
            prefixes << prefixes[stack]
            categories << category
          end

          size = frames.length
          raise unless frames.size == size
          raise unless prefixes.size == size
          {
            frame: frames,
            category: categories,
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
          categories = @frame_categories.map(&:idx)

          raise unless lines.size == funcs.size

          {
            address: [-1] * size,
            inlineDepth: [0] * size,
            category: categories,
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

          cfunc_idx = @strings["<cfunc>"]
          is_js = @filenames.map { |fn| fn != cfunc_idx }
          {
            name: @func_names,
            isJS: is_js,
            relevantForJS: is_js,
            resource: [-1] * size, # set to unidentified for now
            fileName: @filenames,
            lineNumber: profile.func_table.fetch(:first_line),
            columnNumber: [0] * size,
            #columnNumber: functions.map { _1.column },
            length: size
          }
        end

        def string_table
          @strings.keys
        end

        private

        def gc_category
          @categorizer.gc_category
        end
      end
    end
  end
end
