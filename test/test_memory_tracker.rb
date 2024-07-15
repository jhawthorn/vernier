# frozen_string_literal: true

require "test_helper"

class TestMemoryTracker < Minitest::Test
  def test_memory_rss
    memory_tracker = Vernier::MemoryTracker.new
    memory_tracker.record
    memory_tracker.record
    memory_tracker.record

    results = memory_tracker.results
    assert_equal 3, results.size
  end
end
