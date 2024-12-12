# frozen_string_literal: true

require "test_helper"
require "vernier/parsed_profile"

class TestParsedProfile < Minitest::Test
  def test_gvl_sleep
    path = File.expand_path("../fixtures/gvl_sleep.vernier.json", __FILE__)
    parsed_profile = Vernier::ParsedProfile.read_file(path)
    main_thread = parsed_profile.main_thread
  end
end
