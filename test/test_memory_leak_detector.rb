# frozen_string_literal: true

require "test_helper"

class TestMemoryLeakDetector < Minitest::Test
  def test_start_thread
    detector = Vernier::MemoryLeakDetector.start_thread(
      collect_time: 0.01,
      drain_time: 0.01
    )

    result = detector.result

    assert_instance_of Vernier::Result, result
  end
end
