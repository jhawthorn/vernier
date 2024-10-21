# frozen_string_literal: true

require "test_helper"

class TestAllocations < Minitest::Test
  def test_plain_objects
    result = Vernier.trace(allocation_interval: 1) do
      100.times do
        Object.new
      end
    end

    allocations = result.main_thread.fetch(:allocations)
    stacks = allocations.fetch(:samples)

    assert_includes 100..102, stacks.tally.values.max
  end

  def test_interval
    result = Vernier.trace(allocation_interval: 10) do
      1000.times do
        Object.new
      end
    end

    assert_valid_result result

    allocations = result.main_thread.fetch(:allocations)
    stacks = allocations.fetch(:samples)

    assert_includes 100..102, stacks.tally.values.max
  end

  def test_sample_rate
    result = Vernier.trace(allocation_sample_rate: 10) do
      1000.times do
        Object.new
      end
    end

    assert_valid_result result

    allocations = result.main_thread.fetch(:allocations)
    stacks = allocations.fetch(:samples)

    assert_includes 100..102, stacks.tally.values.max
  end

  def test_thread_allocation
    result = Vernier.trace(allocation_interval: 1) do
      Thread.new do
        100.times do
          Object.new
        end
      end.join
    end

    assert_valid_result result

    assert_equal 2, result.threads.count
    other_thread = result.threads.values.detect { !_1[:is_main] }

    allocation_samples = other_thread.dig(:allocations, :samples)

    assert_includes 100..130, allocation_samples.count
  end
end
