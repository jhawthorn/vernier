# frozen_string_literal: true

require "test_helper"

class TestTimeCollector < Minitest::Test
  def bar
    sleep 0.1
  end

  def foo
    bar
    1.times do
      bar
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
      result.markers.map { |x| x[1] }.uniq.sort
  end

  def test_time_collector
    collector = Vernier::Collector.new(:wall, interval: 1000)
    collector.start
    foo
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
    collector = Vernier::Collector.new(:wall, interval: 1000)
    th1 = Thread.new { foo; Thread.current.native_thread_id }
    th2 = Thread.new { foo; Thread.current.native_thread_id }
    collector.start
    th1id = th1.value
    th2id = th2.value
    result = collector.stop

    tally = result.threads.transform_values do |thread|
      thread[:weights].sum
    end.to_h
    assert_in_epsilon 200, tally[Thread.current.native_thread_id], generous_epsilon
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

  def generous_epsilon
    if ENV["GITHUB_ACTIONS"] && ENV["RUNNER_OS"] == "macOS"
      # Timing on macOS Actions runners seem extremely unpredictable
      0.75
    else
      0.1
    end
  end
end
