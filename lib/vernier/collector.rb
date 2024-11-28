# frozen_string_literal: true

require_relative "marker"
require_relative "thread_names"

module Vernier
  class Collector
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
