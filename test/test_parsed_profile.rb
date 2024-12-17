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
end
