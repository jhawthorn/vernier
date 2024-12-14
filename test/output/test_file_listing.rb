# frozen_string_literal: true

require "test_helper"

class TestOutputFileListing < Minitest::Test
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

    output = Vernier::Output::FileListing.new(result).output
    assert_match(/\d+\.\d% \| *\d\.\d% \| *\d+ +sleep 0\.01/, output)
    assert_match(/\d+\.\d% \| *\d\.\d% \| *\d+ +GVLTest\.sleep_without_gvl/, output)
    assert_match(/\d+\.\d% \| *\d\.\d% \| *\d+ +GVLTest\.sleep_holding_gvl/, output)
    assert_match(/\d+\.\d% \| *\d\.\d% \| *\d+ +while Process\.clock_gettime/, output)
  end

  def test_parsed_profile
    profile = Vernier::ParsedProfile.read_file(fixture_path("gvl_sleep.vernier.json"))
    output = Vernier::Output::FileListing.new(profile).output
    assert_includes output, <<TEXT
 24.8% |   0.0% |   44  run(:cfunc_sleep_gvl)
 24.7% |   0.0% |   45  run(:cfunc_sleep_idle)
 24.6% |   0.0% |   46  run(:ruby_sleep_gvl)
 24.7% |   0.0% |   47  run(:sleep_idle)
TEXT
  end
end
