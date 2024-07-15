# frozen_string_literal: true

require "test_helper"

class TestMemoryTracker < Minitest::Test
  def test_explicit_record
    memory_tracker = Vernier::MemoryTracker.new
    memory_tracker.record
    memory_tracker.record
    memory_tracker.record

    timestamps, memory = memory_tracker.results
    assert_equal 3, timestamps.size
    assert_equal timestamps.size, memory.size
  end

  def test_start_and_stop
    memory_tracker = Vernier::MemoryTracker.new
    memory_tracker.start
    sleep 0.2
    timestamps, memory = memory_tracker.results
    assert_includes (18..22), timestamps.size
    assert_equal timestamps.size, memory.size
  end
end
