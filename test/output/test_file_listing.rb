# frozen_string_literal: true

require "test_helper"

class TestOutputFileListing < Minitest::Test
  describe "with a live profile" do
    before do
      @result = Vernier.trace do
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
    end

    def test_complex_profile
      output = Vernier::Output::FileListing.new(@result).output
      assert_match(/\d+\.\d% \| *\d+\.\d% \| *\d+ +sleep 0\.01/, output)
      assert_match(/\d+\.\d% \| *\d+\.\d% \| *\d+ +GVLTest\.sleep_without_gvl/, output)
      assert_match(/\d+\.\d% \| *\d+\.\d% \| *\d+ +GVLTest\.sleep_holding_gvl/, output)
      assert_match(/\d+\.\d% \| *\d+\.\d% \| *\d+ +while Process\.clock_gettime/, output)
    end

    def test_html_output
      output = Vernier::Output::FileListing.new(@result).output(template: "html")
      assert_match(/<details style=\"display:inline-block;vertical-align:top;\"><summary>.+#{Regexp.escape(File.basename(__FILE__))}<\/summary>/, output)
    end
  end

  describe "with a parsed profile" do
    before do
      @profile = Vernier::ParsedProfile.read_file(fixture_path("gvl_sleep.vernier.json"))
    end
    
    def test_parsed_profile
      output = Vernier::Output::FileListing.new(@profile).output
      assert_includes output, <<TEXT
 24.8% |   0.0% |   44  run(:cfunc_sleep_gvl)
 24.7% |   0.0% |   45  run(:cfunc_sleep_idle)
 24.6% |   0.0% |   46  run(:ruby_sleep_gvl)
 24.7% |   0.0% |   47  run(:sleep_idle)
TEXT
    end

    def test_html_output
      output = Vernier::Output::FileListing.new(@profile).output(template: "html")
      assert_includes output,
        " 24.5%   <details style=\"display:inline-block;vertical-align:top;\"><summary>examples/gvl_sleep.rb</summary>\n"
    end
  end
end
