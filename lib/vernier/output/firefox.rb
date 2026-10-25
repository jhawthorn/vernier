# frozen_string_literal: true

require "json"
require "rbconfig"

require_relative "filename_filter"
require_relative "../output_helpers"

module Vernier
  module Output
    # https://profiler.firefox.com/
    # https://github.com/firefox-devtools/profiler/blob/main/src/types/profile.ts
    class Firefox
      class Categorizer
        RAILS_COMPONENTS = %w[ activesupport activemodel activerecord actionview
                               actionpack activejob actionmailer actioncable
                               activestorage actionmailbox actiontext railties ]

        AVAILABLE_COLORS = %w[ transparent purple green orange yellow lightblue
                               blue brown magenta red lightred darkgrey grey ]

        ORDERED_CATEGORIES = %w[ Kernel Rails gem Ruby ] # This is in the order of preference

        attr_reader :categories

        def initialize
          @categories = []
          @categories_by_name = {}

          add_category(name: "Kernel", color: "magenta") do |c|
            c.add_subcategory(
              name: "Kernel",
              matcher: starts_with("<internal")
            )
          end

          add_category(name: "gem", color: "lightblue") do |c|
            c.add_subcategory(
              name: "gem",
              matcher: starts_with(*Gem.path)
            )
          end

          add_category(name: "Rails", color: "red") do |c|
            RAILS_COMPONENTS.each do |subcategory|
              c.add_subcategory(
                name: subcategory,
                matcher: gem_path(subcategory)
              )
            end
          end

          add_category(name: "Ruby", color: "purple") do |c|
            c.add_subcategory(
              name: "stdlib",
              matcher: starts_with(RbConfig::CONFIG["rubylibdir"])
            )
          end

          add_category(name: "Idle", color: "transparent")
          add_category(name: "Stalled", color: "transparent")

          add_category(name: "GC", color: "red")

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
            raise ArgumentError, "invalid color: #{color}" if color && AVAILABLE_COLORS.none?(color)

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

      # The processed profile format version this output targets. See
      # docs-developer/CHANGELOG-formats.md in the firefox profiler repository
      # for the list of changes between versions.
      PROCESSED_PROFILE_VERSION = 76

      # Bits of the frameTable "flags" column (FrameFlag in profile.ts)
      FRAME_FLAG_HAS_CATEGORY = 1 << 2
      FRAME_FLAG_HAS_LINE = 1 << 4

      # Bits of the funcTable "flags" column (FuncFlag in profile.ts)
      FUNC_FLAG_IS_JS = 1 << 0
      FUNC_FLAG_RELEVANT_FOR_JS = 1 << 1
      FUNC_FLAG_HAS_SOURCE = 1 << 3
      FUNC_FLAG_HAS_LINE = 1 << 4

      def initialize(profile)
        @profile = profile
        @categorizer = Categorizer.new
      end

      def output(gzip: false)
        result = ::JSON.generate(data(profile.meta[:hide_anonymous_threads]))
        if gzip
          require "zlib"
          result = Zlib.gzip(result)
        end
        result
      end

      private

      attr_reader :profile

      def data(hide_anonymous_threads)
        shared = Shared.new(profile, @categorizer)

        threads = profile.threads.map do |ruby_thread_id, thread_info|
          Thread.new(
            ruby_thread_id,
            profile,
            shared,
            **thread_info,
          )
        end

        # Every thread has now copied the stacks it references into the shared
        # stack table. Its size must be fixed before any thread data is built,
        # because the extra stacks for Idle/Stalled samples are appended after
        # it. The shared tables themselves are built last, since building the
        # thread data allocates those extra stacks and interns marker strings.
        shared.finalize
        thread_data = threads.map(&:data)
        shared_data = shared.data

        initially_visible_threads = if hide_anonymous_threads
          threads.each_index.reject { |i| threads[i].anonymous? && !threads[i].is_main && !threads[i].is_start }.to_a
        else
          threads.each_index.to_a
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
            preprocessedProfileVersion: PROCESSED_PROFILE_VERSION,
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
            initialVisibleThreads: initially_visible_threads,
            initialSelectedThreads: Array(threads.find_index(&:is_start)),
            vernierUserMetadata: profile.meta[:user_metadata],
            extra: [
              label: "User-Supplied Metadata",
              entries: profile.meta[:user_metadata].map do |k, v|
                {
                  label: k,
                  format: "string",
                  value: v
                }
              end
            ]
          },
          counters: counter_data,
          libs: [],
          shared: shared_data,
          threads: thread_data
        }
      end

      def counter_data
        profile.hooks.flat_map do |hook|
          if hook.respond_to?(:firefox_counters)
            hook.firefox_counters
          end
        end.compact
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
            description: "The thread has acquired the GVL and is executing",
            fields: []
          },
          {
            name: "THREAD_STALLED",
            display: [ "marker-chart" ],
            description: "The thread is ready, but stalled waiting for the GVL to be available",
            fields: []
          },
          {
            name: "THREAD_SUSPENDED",
            display: [ "marker-chart" ],
            description: "The thread has voluntarily released the GVL (ex. to sleep, for I/O, waiting on a lock)",
            fields: []
          },
          {
            name: "GC_PAUSE",
            display: [ "marker-chart", "marker-table", "timeline-overview" ],
            tooltipLabel: "{marker.name} - {marker.data.state}",
            description: "All threads are paused as GC is performed",
            fields: [
              { key: "state", format: "string" },
              { key: "gc_by", format: "string" },
            ]
          },
          {
            name: "FIBER_SWITCH",
            display: [ "marker-chart", "marker-table", "timeline-overview" ],
            tooltipLabel: "{marker.name} - {marker.data.fiber_id}",
            description: "Switch running Fiber",
            fields: [
              { key: "fiber_id", format: "integer" },
            ]
          },
          *hook_additions
        ]
      end

      # Tables shared by all threads of the profile: the stack, frame and func
      # tables, the string table and the source table.
      class Shared
        include OutputHelpers

        SAMPLE_CATEGORY_NAMES = {
          1 => "Idle",
          2 => "Stalled"
        }.freeze

        attr_reader :categorizer

        def initialize(profile, categorizer)
          @profile = profile
          @categorizer = categorizer

          @stack_table = Vernier::StackTable.new
          @strings = Hash.new { |h, k| h[k] = h.size }
          @finalized = false
          @categorized_stacks = nil

          @sample_category_idx = SAMPLE_CATEGORY_NAMES.transform_values do |name|
            @categorizer.get_category(name).idx
          end
        end

        def intern(string)
          @strings[string]
        end

        # Copies a stack from the profile's stack table into the shared table,
        # which only contains stacks that are actually referenced.
        def convert_stack(stack_idx)
          raise "stack table already finalized" if @finalized

          @stack_table.convert(@profile._stack_table, stack_idx)
        end

        def finalize
          @finalized = true
          base_stack_count = @stack_table.stack_count
          @categorized_stacks = Hash.new do |h, k|
            h[k] = base_stack_count + h.size
          end
        end

        # Samples recorded while a thread was idle or stalled on the GVL get a
        # copy of their stack whose leaf frame carries that category, so the
        # time shows up as such in the profiler.
        def categorized_stack(stack_idx, raw_category)
          raise "stack table not yet finalized" unless @finalized

          @categorized_stacks[[stack_idx, raw_category]]
        end

        def data
          raise "stack table not yet finalized" unless @finalized

          tables = @stack_table.to_h
          func_names = tables[:func_table].fetch(:name)
          filenames = tables[:func_table].fetch(:filename)
          first_lines = tables[:func_table].fetch(:first_line)
          frame_funcs = tables[:frame_table].fetch(:func).dup
          frame_lines = tables[:frame_table].fetch(:line).dup
          stack_frames = tables[:stack_table].fetch(:frame).dup
          stack_parents = tables[:stack_table].fetch(:parent).dup

          sources, func_sources = build_sources(filenames)

          func_categories = filenames.map { |filename| categorize_filename(filename) }
          frame_categories = frame_funcs.map { |func_idx| func_categories[func_idx][0].idx }
          frame_subcategories = frame_funcs.map { |func_idx| func_categories[func_idx][1] }

          # Keys were inserted in index order, see finalize.
          extra_frames = {}
          @categorized_stacks.each_key do |(stack_idx, raw_category)|
            original_frame_idx = stack_frames[stack_idx]
            category_idx = @sample_category_idx.fetch(raw_category)

            frame_idx = extra_frames[[original_frame_idx, category_idx]] ||= begin
              frame_funcs << frame_funcs[original_frame_idx]
              frame_lines << frame_lines[original_frame_idx]
              frame_categories << category_idx
              frame_subcategories << 0
              frame_funcs.size - 1
            end

            stack_frames << frame_idx
            stack_parents << stack_parents[stack_idx]
          end

          stack_table = stack_table_data(stack_frames, stack_parents)
          frame_table = frame_table_data(frame_funcs, frame_lines, frame_categories, frame_subcategories)
          func_table = func_table_data(func_names, filenames, first_lines, func_sources)

          # The string table must come last: building the other tables interns strings.
          {
            stackTable: stack_table,
            frameTable: frame_table,
            funcTable: func_table,
            resourceTable: {
              length: 0,
              name: [],
              host: [],
              type: []
            },
            nativeSymbols: {
              length: 0,
              libIndex: [],
              address: [],
              name: [],
              functionSize: []
            },
            sources: sources,
            sourceLocationTable: {
              length: 0,
              source: [],
              line: [],
              column: []
            },
            stringArray: string_table
          }
        end

        private

        def stack_table_data(frames, parents)
          prefix_offsets = parents.each_with_index.map do |parent, idx|
            if parent.nil?
              0
            else
              raise "stack table is not ordered parent-first" unless parent < idx
              idx - parent
            end
          end

          {
            frame: frames,
            prefixOffset: prefix_offsets,
            length: frames.size
          }
        end

        def frame_table_data(funcs, lines, categories, subcategories)
          size = funcs.size
          raise unless lines.size == size && categories.size == size && subcategories.size == size

          flags = lines.map do |line|
            if line == 0
              FRAME_FLAG_HAS_CATEGORY
            else
              FRAME_FLAG_HAS_CATEGORY | FRAME_FLAG_HAS_LINE
            end
          end
          zeros = [0] * size

          {
            flags: flags,
            address: zeros,
            lib: zeros,
            category: categories,
            subcategory: subcategories,
            func: funcs,
            nativeSymbol: zeros,
            innerWindowID: zeros,
            line: lines,
            column: zeros,
            originalLocation: zeros,
            length: size
          }
        end

        def func_table_data(names, filenames, first_lines, sources)
          size = names.size
          zeros = [0] * size

          flags = filenames.each_with_index.map do |filename, i|
            flags = FUNC_FLAG_HAS_SOURCE
            unless filename == "<cfunc>"
              flags |= FUNC_FLAG_IS_JS | FUNC_FLAG_RELEVANT_FOR_JS
              flags |= FUNC_FLAG_HAS_LINE
            end
            flags |= FUNC_FLAG_HAS_LINE if first_lines[i] != 0
            flags
          end

          {
            flags: flags,
            name: names.map { |name| intern(name) },
            resource: zeros,
            source: sources,
            lineNumber: first_lines,
            columnNumber: zeros,
            originalLocation: zeros,
            length: size
          }
        end

        # One source per distinct file. Returns the table and the source index
        # of each func.
        def build_sources(filenames)
          filter = FilenameFilter.new
          table = {
            length: 0,
            id: [],
            filename: [],
            startLine: [],
            startColumn: [],
            sourceMapURL: [],
            content: []
          }
          index_by_filename = {}

          func_sources = filenames.map do |filename|
            index_by_filename[filename] ||= begin
              table[:id] << nil
              table[:filename] << intern(filter.call(filename))
              table[:startLine] << 1
              table[:startColumn] << 1
              table[:sourceMapURL] << nil
              table[:content] << nil
              table[:length] += 1
              table[:length] - 1
            end
          end

          [table, func_sources]
        end

        def string_table
          @strings.keys.map do |string|
            sanitize_string(string)
          end
        end

        def categorize_filename(filename)
          return cfunc_category_and_subcategory if filename == "<cfunc>"

          category, subcategory = find_category_and_subcategory(filename, Categorizer::ORDERED_CATEGORIES)
          return category, subcategory if subcategory

          ruby_category_and_subcategory
        end

        def cfunc_category_and_subcategory
          [@categorizer.get_category("cfunc"), 0]
        end

        def ruby_category_and_subcategory
          [@categorizer.get_category("Ruby"), 0]
        end

        def find_category_and_subcategory(filename, categories)
          categories.each do |category_name|
            category = @categorizer.get_category(category_name)
            subcategory = category.subcategories.detect { |c| c.matches?(filename) }&.idx
            return category, subcategory if subcategory
          end
          [nil, nil]
        end
      end

      class Thread
        attr_reader :profile, :is_start, :anonymous, :is_main
        alias :anonymous? :anonymous

        def initialize(ruby_thread_id, profile, shared, name:, tid:, samples:, weights:, timestamps: nil, sample_categories: nil, markers:, started_at:, anonymous:, stopped_at: nil, allocations: nil, is_main: nil, is_start: nil)
          @ruby_thread_id = ruby_thread_id
          @profile = profile
          @shared = shared
          @tid = tid
          @name = name
          @is_main = is_main
          @anonymous = anonymous
          if is_main.nil?
            @is_main = @ruby_thread_id == ::Thread.main.object_id
          end
          @is_main = true if profile.threads.size == 1
          @is_start = is_start.nil? ? @is_main : is_start

          @samples = samples.map { |sample| shared.convert_stack(sample) }

          if allocations
            allocation_samples = allocations[:samples].map do |sample|
              shared.convert_stack(sample)
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
              new_idx = shared.convert_stack(stack_idx)
              marker[5] = marker[5].merge({ cause: { stack: new_idx }})
            end
            marker
          end

          @started_at, @stopped_at = started_at, stopped_at
        end

        def data
          started_at = (@started_at - 0) / 1_000_000.0
          stopped_at = (@stopped_at - 0) / 1_000_000.0 if @stopped_at

          {
            processType: "default",
            name: @name,
            isMainThread: @is_main,
            processStartupTime: started_at,
            processShutdownTime: stopped_at,
            registerTime: started_at,
            unregisterTime: stopped_at,
            pausedRanges: [],
            pid: (profile.pid || Process.pid).to_s,
            tid: @tid,
            samples: samples_table,
            markers: markers_table
          }.tap do |thread|
            # processShutdownTime and unregisterTime must be present (as null)
            # for threads that haven't ended, so only drop the optional table
            allocations = allocations_table
            thread[:jsAllocations] = allocations if allocations
          end
        end

        def markers_table
          string_indexes = []
          start_times = []
          end_times = []
          phases = []
          categories = []
          data = []

          @markers.each do |(_, name, start, finish, phase, datum)|
            string_indexes << @shared.intern(name)
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
          return nil unless @allocations

          samples, weights, timestamps = @allocations.values_at(:samples, :weights, :timestamps)
          return nil if samples.empty?

          size = samples.size
          timestamps = timestamps.map { _1 / 1_000_000.0 }
          {
            "time": timestamps,
            "className": ["Object"]*size,
            "typeName": ["JSObject"]*size,
            "coarseType": ["Object"]*size,
            "weight": weights,
            "inNursery": [false] * size,
            "stack": samples,
            "length": size
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

          raise unless weights.size == size
          raise unless times.size == size

          samples = samples.zip(categories).map do |sample, category|
            if category == 0
              sample
            else
              @shared.categorized_stack(sample, category)
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

        private

        def gc_category
          @shared.categorizer.get_category("GC")
        end

        def thread_category
          @shared.categorizer.get_category("Thread")
        end
      end
    end
  end
end
