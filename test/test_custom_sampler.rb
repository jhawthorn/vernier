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
    assert_equal 10, result.total_weights
  end

  def test_custom_result_has_main_thread
    collector = Vernier::Collector.new(:custom)
    collector.start
    collector.sample
    result = collector.stop

    assert_equal result.threads[0], result.main_thread
    assert Vernier::Output::Top.new(result, 20).output
    assert Vernier::Output::FileListing.new(result).output
  end
end
