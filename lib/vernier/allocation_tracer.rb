# frozen_string_literal: true

module Vernier
  # Plan: The allocation tracer can be in a few states:
  #  * Idle
  #  * Started
  #    * Watching for new objects
  #    * Watching for freed objects
  #  * Paused
  #    * Ignoring new objects
  #    * Watching for freed objects
  #  * Stopped
  #    * Ignoring new objects
  #    * Ignoring for freed objects
  #    * Marking all existing objects (not yet implemented)
  #    * N.B. This prevents any objects which the tracer has seen from being GC'd
  class AllocationTracer
    attr_reader :stack_table

    def self.new(stack_table = StackTable.new)
      _new(stack_table)
    end

    def inspect
      "#<#{self.class} allocated_objects=#{allocated_objects} freed_objects=#{freed_objects} stack_table=#{stack_table.inspect}>"
    end

    def self.trace(&block)
      tracer = new
      tracer.trace(&block)
      tracer
    end

    def trace
      start
      yield self
    ensure
      stop
    end

    def stack(obj)
      idx = stack_idx(obj)
      return nil unless idx
      stack_table.stack(idx)
    end
  end
end
