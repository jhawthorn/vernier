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
    stack1 = allocations.stack(obj1)
    stack2 = allocations.stack(obj2)

    assert_equal "Class#new at <cfunc>", stack1[0].to_s

    assert_equal File.expand_path(__FILE__), stack1[1].filename
    assert_equal lines[0], stack1[1].lineno
    assert_equal File.expand_path(__FILE__), stack2[1].filename
    assert_equal lines[1], stack2[1].lineno
  end

  def test_compaction
    retained = []

    expected_line = __LINE__ + 4
    allocations = Vernier::AllocationTracer.trace do
      100.times {
        Object.new
        retained << Object.new
      }
    end

    GC.verify_compaction_references(toward: :empty, expand_heap: true)

    result = retained.map do |obj|
      allocations.stack(obj)[1].to_s
    end.tally
    assert_equal 1, result.size
    expected_file = File.expand_path(__FILE__)
    expected_source = "TestAllocationTracer#test_compaction at #{expected_file}:#{expected_line}"
    assert_equal expected_source, result.keys[0]
  end
end
