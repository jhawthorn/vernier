# frozen_string_literal: true

require_relative "marker"
require_relative "thread_names"

module Vernier
  class Collector
    class CustomCollector < Collector
      def initialize(mode, options)
        @stack_table = StackTable.new

        @samples = []
        @timestamps = []

        @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        super
      end

      def sample
        @samples << @stack_table.current_stack
        @timestamps << Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      end

      def start
      end

      def finish
        result = Result.new
        result.instance_variable_set(:@threads, {
          0 => {
            tid: 0,
            name: "custom",
            started_at: @started_at,
            samples: @samples,
            weights: [1] * @samples.size,
            timestamps: @timestamps,
            sample_categories: [0] * @samples.size,
          }
        })
        result.instance_variable_set(:@meta, {
          started_at: @started_at
        })
        result
      end
    end

    class RetainedCollector < Collector
      def initialize(mode, options)
        @stack_table = StackTable.new
        @allocation_tracer = AllocationTracer.new(@stack_table)

        @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        super
      end

      def start
        @allocation_tracer.start
      end

      def finish
        @allocation_tracer.pause

        GC.start

        stack_table.finalize

        GC.start

        tracer_data = @allocation_tracer.data
        @allocation_tracer.stop

        samples = tracer_data.fetch(:samples)
        weights = tracer_data.fetch(:weights)

        result = Result.new
        result.instance_variable_set(:@threads, {
          0 => {
            tid: 0,
            name: "retained memory",
            started_at: @started_at,
            samples: samples,
            weights: weights,
            sample_categories: [0] * samples.size,
          }
        })
        result.instance_variable_set(:@meta, {
          started_at: @started_at
        })
        result
      end
    end

    def self.new(mode, options = {})
      return super unless Collector.equal?(self)

      case mode
      when :wall
        TimeCollector.new(mode, options)
      when :custom
        CustomCollector.new(mode, options)
      when :retained
        RetainedCollector.new(mode, options)
      else
        raise ArgumentError, "invalid mode: #{mode.inspect}"
      end
    end

    def initialize(mode, options = {})
      @gc = options.fetch(:gc, true) && (mode == :retained)
      GC.start if @gc

      @mode = mode
      @out = options[:out]

      @markers = []
      @hooks = []

      @thread_names = ThreadNames.new

      if options[:hooks]
        Array(options[:hooks]).each do |hook|
          add_hook(hook)
        end
      end
      @hooks.each do |hook|
        hook.enable
      end
    end

    attr_reader :stack_table

    private def add_hook(hook)
      case hook.to_sym
      when :rails, :activesupport
        @hooks << Vernier::Hooks::ActiveSupport.new(self)
      when :memory_usage
        @hooks << Vernier::Hooks::MemoryUsage.new(self)
      else
        warn "unknown hook: #{hook.inspect}"
      end
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

    def add_marker(name:, start:, finish:, thread: Thread.current.object_id, phase: Marker::Phase::INTERVAL, data: nil)
      @markers << [thread,
                   name,
                   start,
                   finish,
                   phase,
                   data]
    end

    ##
    # Record an interval with a category and name.  Yields to a block and
    # records the amount of time spent in the block as an interval marker.
    def record_interval(category, name = category)
      start = current_time
      yield
      add_marker(
        name: category,
        start:,
        finish: current_time,
        phase: Marker::Phase::INTERVAL,
        thread: Thread.current.object_id,
        data: { :type => 'UserTiming', :entryType => 'measure', :name => name }
      )
    end

    def stop
      result = finish

      result.meta[:mode] = @mode
      result.meta[:out] = @out
      result.meta[:gc] = @gc

      result.stack_table = stack_table
      @thread_names.finish

      @hooks.each do |hook|
        hook.disable
      end

      result.threads.each do |obj_id, thread|
        thread[:name] ||= @thread_names[obj_id]
      end

      result.hooks = @hooks

      end_time = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
      result.pid = Process.pid
      result.end_time = end_time

      marker_strings = Marker.name_table

      markers_by_thread_id = (@markers || []).group_by(&:first)

      result.threads.each do |tid, thread|
        last_fiber = nil
        markers = []

        markers.concat markers_by_thread_id.fetch(tid, [])

        original_markers = thread[:markers] || []
        original_markers += result.gc_markers || []
        original_markers.each do |data|
          type, phase, ts, te, stack, extra_info = data
          if type == Marker::Type::FIBER_SWITCH
            if last_fiber
              start_event = markers[last_fiber]
              markers << [nil, "Fiber Running", start_event[2], ts, Marker::Phase::INTERVAL, start_event[5].merge(type: "Fiber Running", cause: nil)]
            end
            last_fiber = markers.size
          end
          name = marker_strings[type]
          sym = Marker::MARKER_SYMBOLS[type]
          data = { type: sym }
          data[:cause] = { stack: stack } if stack
          data.merge!(extra_info) if extra_info
          markers << [tid, name, ts, te, phase, data]
        end
        if last_fiber
          end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
          start_event = markers[last_fiber]
          markers << [nil, "Fiber Running", start_event[2], end_time, Marker::Phase::INTERVAL, start_event[5].merge(type: "Fiber Running", cause: nil)]
        end

        thread[:markers] = markers
      end

      #markers.concat @markers

      #result.instance_variable_set(:@markers, markers)

      if @out
        result.write(out: @out)
      end

      result
    end
  end
end
