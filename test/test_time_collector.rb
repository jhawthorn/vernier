# frozen_string_literal: true

require "test_helper"

class TestTimeCollector < Minitest::Test
  SLEEP_SCALE = ENV.fetch("TEST_SLEEP_SCALE", 0.1).to_f # seconds/100ms
  SAMPLE_SCALE_INTERVAL = 10_000 * SLEEP_SCALE # Microseconds

  def slow_method
    sleep SLEEP_SCALE
  end

  def two_slow_methods
    slow_method
    1.times do
      slow_method
    end
  end

  def test_receives_gc_events
    collector = Vernier::Collector.new(:wall)
    collector.start
    GC.start
    GC.start
    result = collector.stop

    assert_valid_result result
    # make sure we got all GC events (since we did GC.start twice)
    assert_equal ["GC end marking", "GC end sweeping", "GC pause", "GC start"].sort,
      result.markers.map { |x| x[1] }.grep(/^GC/).uniq.sort
  end

  def test_time_collector
    collector = Vernier::Collector.new(:wall, interval: SAMPLE_SCALE_INTERVAL)
    collector.start
    two_slow_methods
    result = collector.stop

    assert_valid_result result
    assert_in_epsilon 200, result.weights.sum, generous_epsilon

    samples_by_stack = result.samples.zip(result.weights).group_by(&:first).transform_values do |samples|
      samples.map(&:last).sum
    end
    significant_stacks = samples_by_stack.select { |k,v| v > 10 }
    assert_equal 2, significant_stacks.size
    assert_in_epsilon 200, significant_stacks.sum(&:last), generous_epsilon
  end

  def test_sleeping_threads
    collector = Vernier::Collector.new(:wall, interval: SAMPLE_SCALE_INTERVAL)
    th1 = Thread.new { two_slow_methods; Thread.current.object_id }
    th2 = Thread.new { two_slow_methods; Thread.current.object_id }
    collector.start
    th1id = th1.value
    th2id = th2.value
    result = collector.stop

    tally = result.threads.transform_values do |thread|
      # Number of samples
      thread[:weights].sum
    end.to_h

    assert_in_epsilon 200, tally[Thread.current.object_id], generous_epsilon
    assert_in_epsilon 200, tally[th1id], generous_epsilon
    assert_in_epsilon 200, tally[th2id], generous_epsilon

    assert_valid_result result
    # TODO: some assertions on behaviour
  end

  def count_up_to(n)
    i = 0
    while i < n
      i += 1
    end
  end

  def test_two_busy_threads
    collector = Vernier::Collector.new(:wall)
    th1 = Thread.new { count_up_to(10_000_000) }
    th2 = Thread.new { count_up_to(10_000_000) }
    collector.start
    th1.join
    th2.join
    result = collector.stop

    assert_valid_result result
    # TODO: some assertions on behaviour
  end

  def test_many_threads
    50.times do
      collector = Vernier::Collector.new(:wall)
      collector.start
      50.times.map do
        Thread.new { count_up_to(2_000) }
      end.map(&:join)
      result = collector.stop
      assert_valid_result result
    end

    # TODO: some assertions on behaviour
  end

  def test_sequential_threads
    collector = Vernier::Collector.new(:wall)
    collector.start
    10.times do
      10.times.map do
        Thread.new { sleep 0.1 }
      end.map(&:join)
    end
    result = collector.stop
    assert_valid_result result
  end

  def test_nested_collections
    outer_result = inner_result = nil
    outer_result = Vernier.trace(interval: SAMPLE_SCALE_INTERVAL) do
      inner_result = Vernier.trace(interval: SAMPLE_SCALE_INTERVAL) do
        slow_method
      end
      slow_method
    end

    assert_in_epsilon 100, inner_result.weights.sum, generous_epsilon
    assert_in_epsilon 200, outer_result.weights.sum, generous_epsilon
  end

  ExpectedError = Class.new(StandardError)
  def test_raised_exceptions_will_output
    output_file = File.join(__dir__, "../tmp/exception_output.json")

    result = nil
    assert_raises(ExpectedError) do
      Vernier.trace(out: output_file) do
        raise ExpectedError
      end
    end

    assert File.exist?(output_file)
  end

  def generous_epsilon
    0.75 # Everyone gets generous epsilons
  end
end
