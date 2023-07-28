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
    assert_equal ["GC end marking", "GC end sweeping", "GC enter", "GC exit", "GC start"],
      result.marker_names.uniq.sort
  end

  def test_time_collector
    collector = Vernier::Collector.new(:wall)
    collector.start
    foo
    result = collector.stop

    assert_valid_result result
    assert_includes (380..420), result.samples.size

    significant_stacks = result.samples.tally.select { |k,v| v > 10 }
    assert_equal 2, significant_stacks.size
    assert significant_stacks.sum(&:last) > 350
  end

  def test_sleeping_threads
    collector = Vernier::Collector.new(:wall)
    th1 = Thread.new { foo; Thread.current.native_thread_id }
    th2 = Thread.new { foo; Thread.current.native_thread_id }
    collector.start
    th1id = th1.value
    th2id = th2.value
    result = collector.stop

    tally = result.sample_threads.tally
    pp tally
    assert_includes (380..430), tally[Thread.current.native_thread_id]
    assert_includes (380..430), tally[th1id]
    assert_includes (380..430), tally[th2id]

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
end
