# frozen_string_literal: true

require "test_helper"

class TestOutputTop < Minitest::Test
  include FirefoxTestHelpers

  def test_complex_profile
    result = Vernier.trace do
      # Proper Ruby sleep
      sleep 0.01

      # Sleep inside rb_thread_call_without_gvl
      GVLTest.sleep_without_gvl(0.01)

      # Sleep with GVL held
      GVLTest.sleep_holding_gvl(0.01)

      # Ruby busy sleep
      target = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.01
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < target
      end
    end

    output = Vernier::Output::Top.new(result).output
    assert_match(/^\d+\tGVLTest\.sleep_without_gvl$/, output)
    assert_match(/^\d+\tGVLTest\.sleep_holding_gvl$/, output)
    assert_match(/^\d+\tKernel#sleep$/, output)
    assert_match(/^\d+\tProcess.clock_gettime$/, output)
  end
end
