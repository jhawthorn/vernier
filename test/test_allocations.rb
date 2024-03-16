# frozen_string_literal: true

require "test_helper"

class TestAllocations < Minitest::Test
  def test_plain_objects
    result = Vernier.trace(allocation_sample_rate: 1) do
      100.times do
        Object.new
      end
    end

    allocations = result.main_thread.fetch(:allocations)
    stacks = allocations.fetch(:samples)

    assert_equal 100, stacks.tally.values.max
  end

  def test_sample_rate
    result = Vernier.trace(allocation_sample_rate: 10) do
      1000.times do
        Object.new
      end
    end

    allocations = result.main_thread.fetch(:allocations)
    stacks = allocations.fetch(:samples)

    assert_equal 100, stacks.tally.values.max
  end
end
