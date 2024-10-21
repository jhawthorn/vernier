# frozen_string_literal: true

require "json"
require "rbconfig"

module Vernier
  module Output
    # https://profiler.firefox.com/
    # https://github.com/firefox-devtools/profiler/blob/main/src/types/profile.js
    class Firefox
      class Categorizer
        attr_reader :categories
        def initialize
          @categories = []
          @categories_by_name = {}

          add_category(name: "Ruby", color: "grey") do |c|
            rails_components = %w[ activesupport activemodel activerecord
              actionview actionpack activejob actionmailer actioncable
              activestorage actionmailbox actiontext railties ]
            c.add_subcategory(
              name: "Rails",
              matcher: gem_path(*rails_components)
            )
            c.add_subcategory(
              name: "gem",
              matcher: starts_with(*Gem.path)
            )
            c.add_subcategory(
              name: "stdlib",
              matcher: starts_with(RbConfig::CONFIG["rubylibdir"])
            )
          end
          add_category(name: "Idle", color: "transparent")
          add_category(name: "Stalled", color: "transparent")

          add_category(name: "GC", color: "orange")
          add_category(name: "cfunc", color: "yellow", matcher: "<cfunc>")

          add_category(name: "Thread", color: "grey")
        end

        def add_category(name:, **kw)
          category = Category.new(@categories.length, name: name, **kw)
          @categories << category
          @categories_by_name[name] = category
          category.add_subcategory(name: "Other")
          yield category if block_given?
          category
        end

        def get_category(name)
          @categories_by_name[name]
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
          attr_reader :idx, :name, :color, :matcher, :subcategories
          def initialize(idx, name:, color:, matcher: nil)
            @idx = idx
            @name = name
            @color = color
            @matcher = matcher
            @subcategories = []
          end

          def add_subcategory(**args)
            @subcategories << Category.new(@subcategories.size, color: nil, **args)
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

      def output(gzip: false)
        result = ::JSON.fast_generate(data)
        if gzip
          require "zlib"
          result = Zlib.gzip(result)
        end
        result
      end

      private

      attr_reader :profile

      def data
        markers_by_thread = profile.markers.group_by { |marker| marker[0] }

        threads = profile.threads.map do |ruby_thread_id, thread_info|
          markers = markers_by_thread[ruby_thread_id] || []
          Thread.new(
            ruby_thread_id,
            profile,
            @categorizer,
            markers: markers,
            **thread_info,
          )
        end

        {
          meta: {
            interval: 1, # FIXME: memory vs wall
            startTime: profile.started_at / 1_000_000.0,
            #endTime: (profile.timestamps&.max || 0) / 1_000_000.0,
            processType: 0,
            product: "Ruby/Vernier",
            stackwalk: 1,
            version: 28,
            preprocessedProfileVersion: 47,
            symbolicated: true,
            markerSchema: marker_schema,
            sampleUnits: {
              time: "ms",
              eventDelay: "ms",
              threadCPUDelta: "µs"
            }, # FIXME: memory vs wall
            categories: @categorizer.categories.map do |category|
              {
                name: category.name,
                color: category.color,
                subcategories: category.subcategories.map(&:name)
              }
            end,
            sourceCodeIsNotOnSearchfox: true,
            initialVisibleThreads: threads.each_index.to_a,
            initialSelectedThreads: Array(threads.find_index(&:is_start))
          },
          libs: [],
          threads: threads.map(&:data)
        }
      end

      def marker_schema
        hook_additions = profile.hooks.flat_map do |hook|
          if hook.respond_to?(:firefox_marker_schema)
            hook.firefox_marker_schema
          end
        end.compact

        [
          {
            name: "THREAD_RUNNING",
            display: [ "marker-chart" ],
            data: [
              {
                label: "Description",
                value: "The thread has acquired the GVL and is executing"
              }
            ]
          },
          {
            name: "THREAD_STALLED",
            display: [ "marker-chart" ],
            data: [
              {
                label: "Description",
                value: "The thread is ready, but stalled waiting for the GVL to be available"
              }
            ]
          },
          {
            name: "THREAD_SUSPENDED",
            display: [ "marker-chart" ],
            data: [
              {
                label: "Description",
                value: "The thread has voluntarily released the GVL (ex. to sleep, for I/O, waiting on a lock)"
              }
            ]
          },
          {
            name: "GC_PAUSE",
            display: [ "marker-chart", "marker-table", "timeline-overview" ],
            tooltipLabel: "{marker.name} - {marker.data.state}",
            data: [
              {
                label: "Description",
                value: "All threads are paused as GC is performed"
              },
              { key: "state", format: "string" },
              { key: "gc_by", format: "string" },
            ]
          },
          *hook_additions
        ]
      end

      class Thread
        attr_reader :profile, :is_start

        def initialize(ruby_thread_id, profile, categorizer, name:, tid:, samples:, weights:, timestamps: nil, sample_categories: nil, markers:, started_at:, stopped_at: nil, allocations: nil, is_main: nil, is_start: nil)
          @ruby_thread_id = ruby_thread_id
          @profile = profile
          @categorizer = categorizer
          @tid = tid
          @name = name
          @is_main = is_main
          if is_main.nil?
            @is_main = @ruby_thread_id == ::Thread.main.object_id
          end
          @is_main = true if profile.threads.size == 1
          @is_start = is_start.nil? ? @is_main : is_start

          @stack_table = Vernier::StackTable.new
          samples = samples.map { |sample| @stack_table.convert(profile._stack_table, sample) }

          @samples = samples

          if allocations
            allocation_samples = allocations[:samples].dup
            allocation_samples.map! do |sample|
              @stack_table.convert(profile._stack_table, sample)
            end
            allocations = allocations.merge(samples: allocation_samples)
          end
          @allocations = allocations

          timestamps ||= [0] * samples.size
          @weights, @timestamps = weights, timestamps
          @sample_categories = sample_categories || ([0] * samples.size)
          @markers = markers.map do |marker|
            if stack_idx = marker[5]&.dig(:cause, :stack)
              marker = marker.dup
              new_idx = @stack_table.convert(profile._stack_table, stack_idx)
              marker[5] = marker[5].merge({ cause: { stack: new_idx }})
            end
            marker
          end

          @started_at, @stopped_at = started_at, stopped_at

          @stack_table_hash = @stack_table.to_h
          names = @stack_table_hash[:func_table].fetch(:name)
          filenames = @stack_table_hash[:func_table].fetch(:filename)

          stacks_size = @stack_table.stack_count
          @categorized_stacks = Hash.new do |h, k|
            h[k] = h.size + stacks_size
          end

          @strings = Hash.new { |h, k| h[k] = h.size }
          @func_names = names.map do |name|
            @strings[name]
          end

          @filenames = filter_filenames(filenames).map do |filename|
            @strings[filename]
          end

          func_implementations = filenames.map do |filename|
            # Must match strings in `src/profile-logic/profile-data.js`
            # inside the firefox profiler. See `getFriendlyStackTypeName`
            if filename == "<cfunc>"
              @strings["native"]
            else
              # nil means interpreter
              nil
            end
          end
          @frame_implementations = @stack_table_hash[:frame_table].fetch(:func).map do |func_idx|
            func_implementations[func_idx]
          end

          cfunc_category = @categorizer.get_category("cfunc")
          ruby_category = @categorizer.get_category("Ruby")
          func_categories, func_subcategories = [], []
          filenames.each do |filename|
            if filename == "<cfunc>"
              func_categories << cfunc_category
              func_subcategories << 0
            else
              func_categories << ruby_category
              subcategory = ruby_category.subcategories.detect {|c| c.matches?(filename) }&.idx || 0
              func_subcategories << subcategory
            end
          end
          @frame_categories = @stack_table_hash[:frame_table].fetch(:func).map do |func_idx|
            func_categories[func_idx]
          end
          @frame_subcategories = @stack_table_hash[:frame_table].fetch(:func).map do |func_idx|
            func_subcategories[func_idx]
          end
        end

        def filter_filenames(filenames)
          pwd = "#{Dir.pwd}/"
          gem_regex = %r{\A#{Regexp.union(Gem.path)}/gems/}
          gem_match_regex = %r{\A#{Regexp.union(Gem.path)}/gems/([a-zA-Z](?:[a-zA-Z0-9\.\_]|-[a-zA-Z])*)-([0-9][0-9A-Za-z\-_\.]*)/(.*)\z}
          rubylibdir = "#{RbConfig::CONFIG["rubylibdir"]}/"

          filenames.map do |filename|
            if filename.match?(gem_regex)
              gem_match_regex =~ filename
              "gem:#$1-#$2:#$3"
            elsif filename.start_with?(pwd)
              filename.delete_prefix(pwd)
            elsif filename.start_with?(rubylibdir)
              path = filename.delete_prefix(rubylibdir)
              "rubylib:#{RUBY_VERSION}:#{path}"
            else
              filename
            end
          end
        end

        def data
          started_at = (@started_at - 0) / 1_000_000.0
          stopped_at = (@stopped_at - 0) / 1_000_000.0 if @stopped_at

          {
            name: @name,
            isMainThread: @is_main,
            processStartupTime: started_at,
            processShutdownTime: stopped_at,
            registerTime: started_at,
            unregisterTime: stopped_at,
            pausedRanges: [],
            pid: profile.pid || Process.pid,
            tid: @tid,
            frameTable: frame_table,
            funcTable: func_table,
            nativeSymbols: {},
            samples: samples_table,
            jsAllocations: allocations_table,
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
          }.compact
        end

        def markers_table
          string_indexes = []
          start_times = []
          end_times = []
          phases = []
          categories = []
          data = []

          @markers.each_with_index do |(_, name, start, finish, phase, datum), i|
            string_indexes << @strings[name]
            start_times << (start / 1_000_000.0)

            # Please don't hate me. Divide by 1,000,000 only if finish is not nil
            end_times << (finish&./(1_000_000.0))
            phases << phase

            category =
              if name.start_with?("GC")
                gc_category.idx
              elsif name.start_with?("Thread")
                thread_category.idx
              else
                0
              end

            categories << category
            data << datum
          end

          {
            data: data,
            name: string_indexes,
            startTime: start_times,
            endTime: end_times,
            phase: phases,
            category: categories,
            length: start_times.size
          }
        end

        def allocations_table
          return nil if !@allocations
          samples, weights, timestamps = @allocations.values_at(:samples, :weights, :timestamps)
          return nil if samples.size == 0
          size = samples.size
          timestamps = timestamps.map { _1 / 1_000_000.0 }
          ret = {
            "time": timestamps,
            "className": ["Object"]*size,
            "typeName": ["JSObject"]*size,
            "coarseType": ["Object"]*size,
            "weight": weights,
            "inNursery": [false] * size,
            "stack": samples,
            "length": size
          }
          ret
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
            weightType: profile.meta[:mode] == :retained ? "bytes" : "samples",
            length: samples.length
          }
        end

        def stack_table
          frames =   @stack_table_hash[:stack_table].fetch(:frame).dup
          prefixes = @stack_table_hash[:stack_table].fetch(:parent).dup
          categories  = frames.map{|idx| @frame_categories[idx].idx }
          subcategories  = frames.map{|idx| @frame_subcategories[idx] }

          @categorized_stacks.each_key do |(stack, category)|
            frames << frames[stack]
            prefixes << prefixes[stack]
            categories << category
            subcategories << 0
          end

          size = frames.length
          raise unless frames.size == size
          raise unless prefixes.size == size
          {
            frame: frames,
            category: categories,
            subcategory: subcategories,
            prefix: prefixes,
            length: prefixes.length
          }
        end

        def frame_table
          funcs = @stack_table_hash[:frame_table].fetch(:func)
          lines = @stack_table_hash[:frame_table].fetch(:line)
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
            implementation: @frame_implementations,
            line: lines,
            column: none,
            length: size
          }
        end

        def func_table
          size = @func_names.size

          cfunc_idx = @strings["<cfunc>"]
          is_js = @filenames.map { |fn| fn != cfunc_idx }
          line_numbers = @stack_table_hash[:func_table].fetch(:first_line).map.with_index do |line, i|
            if is_js[i] || line != 0
              line
            else
              nil
            end
          end
          {
            name: @func_names,
            isJS: is_js,
            relevantForJS: is_js,
            resource: [-1] * size, # set to unidentified for now
            fileName: @filenames,
            lineNumber: line_numbers,
            columnNumber: [nil] * size,
            #columnNumber: functions.map { _1.column },
            length: size
          }
        end

        def string_table
          @strings.keys
        end

        private

        def gc_category
          @categorizer.get_category("GC")
        end

        def thread_category
          @categorizer.get_category("Thread")
        end
      end
    end
  end
end
