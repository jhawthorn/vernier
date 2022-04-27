# frozen_string_literal: true

require "test_helper"

class TestVernier < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Vernier::VERSION
  end

  def test_tracing_retained_objects
    Vernier.trace_retained_start

    100.times { Object.new }

    result = Vernier.trace_retained_stop
    p result
  end
end
