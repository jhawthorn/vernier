# frozen_string_literal: true

require "test_helper"

class TestCustomSampler < Minitest::Test
  def test_custom_sampler
    collector = Vernier::Collector.new(:custom)
    collector.start
    10.times do
      collector.sample
    end
    result = collector.stop

    assert_valid_result result
    assert_equal 10, result.weights.sum
  end
end
