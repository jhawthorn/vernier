# frozen_string_literal: true

require "test_helper"

class TestOutputFirefox < Minitest::Test
  def assert_valid_firefox_profile(profile)
    data = JSON.parse(profile)
  end

  def test_retained_firefox_output
    retained = []

    result = Vernier.trace_retained do
      100.times {
        retained << Object.new
      }
    end

    output = Vernier::Output::Firefox.new(result).output

    assert_valid_firefox_profile(output)
  end

  def test_timed_firefox_output
    retained = []

    result = Vernier.trace do
      i = 0
      while i < 1_000_000
        i += 1
      end
    end

    output = Vernier::Output::Firefox.new(result).output

    assert_valid_firefox_profile(output)
  end
end
