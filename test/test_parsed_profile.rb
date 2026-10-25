# frozen_string_literal: true

require "test_helper"
require "vernier/parsed_profile"

class TestParsedProfile < Minitest::Test
  def test_gvl_sleep
    path = File.expand_path("../fixtures/gvl_sleep.vernier.json", __FILE__)
    parsed_profile = Vernier::ParsedProfile.read_file(path)
    main_thread = parsed_profile.main_thread

    stack_table = main_thread.stack_table
    assert_equal "#<Vernier::ParsedProfile::StackTable 742 stacks, 385 frames, 252 funcs>", stack_table.inspect
  end

  def test_current_format_round_trip
    result = Vernier.trace do
      target = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.02
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < target
      end
    end

    data = JSON.parse(result.to_firefox)
    parsed_profile = Vernier::ParsedProfile.new(data)

    stack_table = parsed_profile.main_thread.stack_table
    assert_same stack_table, parsed_profile.stack_table
    assert_equal data["shared"]["stackTable"]["length"], stack_table.stack_count
    assert_equal data["shared"]["frameTable"]["length"], stack_table.frame_count
    assert_equal data["shared"]["funcTable"]["length"], stack_table.func_count

    assert_equal Vernier::Output::Top.new(result, 20).output,
                 Vernier::Output::Top.new(parsed_profile, 20).output

    # Backtraces of every sample resolve through the shared tables
    parsed_profile.main_thread.samples.uniq.each do |stack_idx|
      backtrace = stack_table.backtrace(stack_idx)
      refute_empty backtrace
      assert(backtrace.any? { |line| line.include?("Process.clock_gettime") || line.include?("test_current_format_round_trip") })
    end
  end
end
