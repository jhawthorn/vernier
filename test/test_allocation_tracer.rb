# frozen_string_literal: true

require "test_helper"

class TestAllocationTracer < Minitest::Test
  def test_trace_allocations
    obj1 = obj2 = nil
    lines = []
    allocations = Vernier::AllocationTracer.trace do
      obj1 = Object.new; lines << __LINE__
      obj2 = Object.new; lines << __LINE__
    end
    stack = allocations.stack(obj1)
    pp stack
    binding.irb
    p stack[1]
    #file = allocations.sourcefile(obj1)
    #line = allocations.sourceline(obj2)
  end
end
