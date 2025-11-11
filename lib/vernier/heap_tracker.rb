# frozen_string_literal: true

module Vernier
  # Plan: The heap tracker can be in a few states:
  #  * Idle
  #  * Collecting
  #    * Watching for new objects
  #    * Watching for freed objects
  #  * Draining
  #    * Ignoring new objects
  #    * Watching for freed objects
  #  * Locked
  #    * Ignoring new objects
  #    * Ignoring freed objects
  #    * Marking all existing objects (not yet implemented)
  #    * N.B. This prevents any objects which the tracker has seen from being GC'd
  class HeapTracker
    attr_reader :stack_table

    def self.new(stack_table = StackTable.new)
      _new(stack_table)
    end

    def inspect
      "#<#{self.class} allocated_objects=#{allocated_objects} freed_objects=#{freed_objects} stack_table=#{stack_table.inspect}>"
    end

    def self.track(&block)
      tracker = new
      tracker.track(&block)
      tracker
    end

    def track
      collect
      yield self
    ensure
      lock
    end

    def stack(obj)
      idx = stack_idx(obj)
      return nil unless idx
      stack_table.stack(idx)
    end
  end
end
