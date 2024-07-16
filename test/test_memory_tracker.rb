# frozen_string_literal: true

require "test_helper"

class TestMemoryTracker < Minitest::Test
  # 10MB to 200MB
  REASONABLE_RANGE = (10_000_000)..(200_000_000)

  def test_memory_rss
    return skip("https://bugs.ruby-lang.org/issues/20638") if ENV["RUBY_MN_THREADS"]
    assert_includes REASONABLE_RANGE, Vernier.memory_rss
  end

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
    assert_operator timestamps.size, :>, 18
    assert_equal timestamps.size, memory.size
  end
end
