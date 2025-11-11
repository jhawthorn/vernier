# frozen_string_literal: true

require "test_helper"

class TestHeapTracker < Minitest::Test
  def test_trace_allocations
    obj1 = obj2 = nil
    lines = []
    allocations = Vernier::HeapTracker.trace do
      obj1 = Object.new; lines << __LINE__
      obj2 = Object.new; lines << __LINE__
    end
    stack1 = allocations.stack(obj1)
    stack2 = allocations.stack(obj2)

    frame1 = first_relevant_frame(stack1)
    frame2 = first_relevant_frame(stack2)

    assert_equal File.expand_path(__FILE__), frame1.filename
    assert_equal lines[0], frame1.lineno
    assert_equal File.expand_path(__FILE__), frame2.filename
    assert_equal lines[1], frame2.lineno
  end

  def test_untraced_object_while_running
    allocated_before = Object.new
    Vernier::HeapTracker.trace do |trace|
      1000.times { Object.new }
      assert_nil trace.stack_idx(allocated_before)
    end
  end

  def test_untraced_object_after_running
    allocated_before = Object.new
    allocations = Vernier::HeapTracker.trace do
      1000.times { Object.new }
    end
    allocated_after = Object.new
    assert_nil allocations.stack_idx(allocated_before)
    assert_nil allocations.stack_idx(allocated_after)
  end

  def test_gc
    retained = []
    allocations = Vernier::HeapTracker.trace do
      1000.times {
        Object.new
        retained << Object.new
      }
      GC.start
    end

    assert_in_delta 2000, allocations.allocated_objects, 50
    assert_in_delta 1000, allocations.freed_objects, 50
  end

  def test_compaction
    retained = []

    expected_line = __LINE__ + 4
    allocations = Vernier::HeapTracker.trace do
      100.times {
        Object.new
        retained << Object.new
      }
    end

    GC.verify_compaction_references(toward: :empty, expand_heap: true)

    result = retained.map do |obj|
      first_relevant_frame(allocations.stack(obj)).to_s
    end.tally
    assert_equal 1, result.size
    expected_file = File.expand_path(__FILE__)
    expected_source = "TestHeapTracker#test_compaction at #{expected_file}:#{expected_line}"
    assert_equal expected_source, result.keys[0]
  end

  private
  def first_relevant_frame(stack)
    if stack[0].to_s.include?("Class#new")
      stack[1]
    else
      stack[0]
    end
  end
end
