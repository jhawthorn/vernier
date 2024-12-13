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
    assert_match(/^\d+\tProcess\.clock_gettime$/, output)
  end

  def test_parsed_profile
    profile = Vernier::ParsedProfile.read_file(fixture_path("gvl_sleep.vernier.json"))
    output = Vernier::Output::Top.new(profile).output
    assert_match(/^2010\tGVLTest\.sleep_without_gvl$/, output)
    assert_match(/^2013\tGVLTest\.sleep_holding_gvl$/, output)
    assert_match(/^2010\tKernel#sleep$/, output)
    assert_match(/^1989\tObject#ruby_sleep_gvl$/, output)
    assert_match(/^10\tProcess\.clock_gettime$/, output)
  end
end
