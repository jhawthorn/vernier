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
    assert_match(/^| \d+ *| \d+\.\d *| GVLTest\.sleep_without_gvl *|$/, output)
    assert_match(/^| \d+ *| \d+\.\d *| GVLTest\.sleep_holding_gvl *|$/, output)
    assert_match(/^| \d+ *| \d+\.\d *| Kernel#sleep *|$/, output)
    assert_match(/^| \d+ *| \d+\.\d *| Process\.clock_gettime *|$/, output)
  end

  def test_parsed_profile
    profile = Vernier::ParsedProfile.read_file(fixture_path("gvl_sleep.vernier.json"))
    output = Vernier::Output::Top.new(profile).output
    assert_includes output, "| 2013    | 24.8 | GVLTest.sleep_holding_gvl"
    assert_includes output, "| 2010    | 24.7 | Kernel#sleep"
    assert_includes output, "| 2010    | 24.7 | GVLTest.sleep_without_gvl"
    assert_includes output, "| 1989    | 24.5 | Object#ruby_sleep_gvl"
    assert_includes output, "| 10      | 0.1  | Process.clock_gettime"
  end
end
