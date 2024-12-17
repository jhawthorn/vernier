# frozen_string_literal: true

module Vernier
  class AllocationTracer
    attr_reader :stack_table

    def self.new
      _new(StackTable.new)
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
      stack_table.stack(idx)
    end
  end
end
