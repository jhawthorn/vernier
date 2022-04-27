# frozen_string_literal: true

require "test_helper"

class TestVernier < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Vernier::VERSION
  end

  def test_tracing_retained_objects
    retained = []

    result = Vernier.trace_retained do
      100.times {
        Object.new

        retained << Object.new
      }
    end

    p result
  end
end
