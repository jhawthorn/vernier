# frozen_string_literal: true

require "test_helper"

class TestOutputFirefox < Minitest::Test
  def test_firefox_output
    retained = []

    result = Vernier.trace_retained do
      100.times {
        retained << Object.new
      }
    end

    output = Vernier::Output::Firefox.new(result).output

    JSON.parse(output)
  end
end
