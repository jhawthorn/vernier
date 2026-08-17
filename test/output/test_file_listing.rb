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

  describe "aggregation" do
    def test_handcomputed_duplicate_stacks
      profile = build_parsed_profile(
        funcs: [["a", "x.rb"], ["b", "x.rb"], ["c", "y.rb"]],
        frames: [[0, 10], [1, 20], [2, 30]],
        stacks: [[nil, 0], [0, 1], [1, 2], [0, 2]],
        samples: [2, 2, 3, 1, 0, 2],
        weights: [1, 2, 4, 8, 16, 32],
      )

      listing = Vernier::Output::FileListing.new(profile)
      assert_equal 63, listing.total

      expected = {
        "x.rb" => { 10 => [16, 63], 20 => [8, 43] },
        "y.rb" => { 30 => [39, 39] },
      }
      assert_equal expected, normalize_samples_by_file(listing.samples_by_file)
    end

    def test_unsampled_interior_stacks
      # Stacks 0 and 1 are never sampled directly, but their frames must
      # still carry the total weight propagated from stack 2.

      profile = build_parsed_profile(
        funcs: [["a", "x.rb"], ["b", "x.rb"], ["c", "y.rb"]],
        frames: [[0, 10], [1, 20], [2, 30]],
        stacks: [[nil, 0], [0, 1], [1, 2]],
        samples: [2, 2],
        weights: [10, 20],
      )

      expected = {
        "x.rb" => { 10 => [0, 30], 20 => [0, 30] },
        "y.rb" => { 30 => [30, 30] },
      }
      assert_equal expected, normalize_samples_by_file(
        Vernier::Output::FileListing.new(profile).samples_by_file
      )
    end

    def test_random_deep_tree_matches_reference
      rng = Random.new(1234)
      func_count = 100
      stack_count = 500

      funcs = Array.new(func_count) { |i| ["func_#{i}", "file_#{i % 3}.rb"] }
      frames = Array.new(func_count) do |i|
        [i, rng.rand < 0.1 ? nil : rng.rand(1..100)]
      end
      stacks = Array.new(stack_count) do |i|
        [i == 0 ? nil : rng.rand(i), rng.rand(func_count)]
      end
      # Fewer samples than stacks: many stacks stay unsampled, so the
      # sparse-to-dense scatter is exercised (5000 samples would leave
      # ~zero stacks unsampled and never test it).
      samples = Array.new(200) { rng.rand(stack_count) }
      weights = Array.new(200) { rng.rand(1..500) }

      profile = build_parsed_profile(
        funcs: funcs, frames: frames, stacks: stacks,
        samples: samples, weights: weights,
      )

      actual = normalize_samples_by_file(
        Vernier::Output::FileListing.new(profile).samples_by_file
      )
      assert_equal reference_samples_by_file(profile), actual
    end

    def test_serialized_fixture_is_parent_before_child_ordered
      profile = Vernier::ParsedProfile.read_file(fixture_path("gvl_sleep.vernier.json"))
      stack_table = profile.main_thread.stack_table

      stack_table.stack_count.times do |idx|
        parent = stack_table.stack_parent_idx(idx)
        assert_operator parent, :<, idx if parent
      end
    end

    def test_out_of_order_stack_table_raises
      profile = build_parsed_profile(
        funcs: [["a", "x.rb"], ["b", "x.rb"]],
        frames: [[0, 10], [1, 20]],
        stacks: [[1, 0], [nil, 1]], # invalid: stack 0's parent is stack 1
        samples: [0, 1],
        weights: [1, 1],
      )

      error = assert_raises(RuntimeError) do
        Vernier::Output::FileListing.new(profile).samples_by_file
      end
      assert_match(/parent-before-child/, error.message)
    end

    def test_live_retained_profile_matches_reference
      retained = []
      result = Vernier.trace_retained do
        10.times { retained << Object.new }
      end

      actual = normalize_samples_by_file(
        Vernier::Output::FileListing.new(result).samples_by_file
      )
      refute_empty actual

      expected = reference_samples_by_file(
        result, filename_filter: Vernier::Output::FilenameFilter.new
      )
      assert_equal expected, actual
    end
  end
end
