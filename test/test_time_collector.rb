# frozen_string_literal: true

require "test_helper"

class TestTimeCollector < Minitest::Test
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
    assert_similar 200, result.weights.sum

    samples_by_stack = result.samples.zip(result.weights).group_by(&:first).transform_values do |samples|
      samples.map(&:last).sum
    end
    significant_stacks = samples_by_stack.select { |k,v| v > 10 }
    assert_equal 2, significant_stacks.size
    assert_similar 200, significant_stacks.sum(&:last)
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

    assert_similar 200, tally[Thread.current.object_id]
    assert_similar 200, tally[th1id]
    assert_similar 200, tally[th2id]

    assert_valid_result result
    # TODO: some assertions on behaviour
  end

  def test_existing_thread
    mutex = Mutex.new
    mutex.lock
    th = Thread.new do
      Thread.current.name = "measure me"
      mutex.lock
    end
    Thread.pass

    collector = Vernier::Collector.new(:wall, interval: SAMPLE_SCALE_INTERVAL)
    collector.start
    sleep 0.01
    result = collector.stop

    mutex.unlock
    th.join

    assert_equal 2, result.threads.count
    assert_includes result.threads.values.map{ _1[:name] }, "measure me"
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

  def test_many_empty_threads
    50.times do
      collector = Vernier::Collector.new(:wall)
      collector.start
      50.times.map do
        Thread.new { }
      end.map(&:join)
      result = collector.stop
      assert_valid_result result
    end
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

  def test_killed_threads
    collector = Vernier::Collector.new(:wall)
    collector.start
    threads = 10.times.map do
      Thread.new { sleep 100 }
    end
    threads.shuffle!
    Thread.new do
      until threads.empty?
        sleep 0.01
        threads.shift.kill
      end
    end.join
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

    assert_similar 100, inner_result.weights.sum
    assert_similar 200, outer_result.weights.sum
  end

  ExpectedError = Class.new(StandardError)
  def test_raised_exceptions_will_output
    output_file = File.join(__dir__, "../tmp/exception_output.json")

    assert_raises(ExpectedError) do
      Vernier.trace(out: output_file) do
        raise ExpectedError
      end
    end

    assert File.exist?(output_file)
  end

  def test_gzip_output
    output_file = File.join(__dir__, "../tmp/gzip_output.json.gz")

    Vernier.trace(out: output_file) do
      sleep 0.01
    end

    assert File.exist?(output_file)
    data = File.binread(output_file)
    assert_equal "\x1f\x8b".b, data.byteslice(0, 2)
  end

  class ThreadWithInspect < ::Thread
    def inspect
      raise "boom!"
    end
  end

  def test_thread_with_inspect
    result = Vernier.trace do
      th1 = ThreadWithInspect.new { sleep 0.01 }
      th1.join
    end

    assert_valid_result result
  end

  def test_collected_thread_names
    thread_obj_ids = []
    result = Vernier.trace do
      5.times do |i|
        th = Thread.new {
          Thread.current.name = "named thread #{i}"
        }.join
        thread_obj_ids << th.object_id
      end
      GC.start
    end

    assert_valid_result result

    thread_names = thread_obj_ids.map { result.threads[_1][:name] }

    expected = 5.times.map { "named thread #{_1}" }
    assert_equal expected, thread_names
  end

  def test_start_stop
    Vernier.start_profile(interval: SAMPLE_SCALE_INTERVAL)
    two_slow_methods
    result = Vernier.stop_profile
    assert_valid_result result
    assert_similar 200, result.weights.sum
  end

  def test_multiple_starts
    error = assert_raises(RuntimeError) do
      Vernier.start_profile(interval: SAMPLE_SCALE_INTERVAL)
      Vernier.start_profile(interval: SAMPLE_SCALE_INTERVAL)
    end
    assert_equal "Profile already started, stopping...", error.message
  end

  def test_stop_without_start
    error = assert_raises("No trace started") do
      Vernier.stop_profile
    end
    assert_equal "No profile started", error.message
  end

  def test_includes_options_in_result_meta
    output_file = File.join(__dir__, "../tmp/exception_output.json")
    result = Vernier.profile(
      out: output_file,
      interval: SAMPLE_SCALE_INTERVAL,
      allocation_sample_rate: SAMPLE_SCALE_ALLOCATIONS
    ) { }

    assert_equal :wall, result.meta[:mode]
    assert_equal output_file, result.meta[:out]
    assert_equal SAMPLE_SCALE_INTERVAL, result.meta[:interval]
    assert_equal SAMPLE_SCALE_ALLOCATIONS, result.meta[:allocation_sample_rate]
    assert_equal false, result.meta[:gc]
  end

  private

  SLOW_RUNNER = ENV["GITHUB_ACTIONS"] && ENV["RUNNER_OS"] == "macOS"
  DEFAULT_SLEEP_SCALE =
      if SLOW_RUNNER
        1
      else
        0.1
      end
  SLEEP_SCALE = ENV.fetch("TEST_SLEEP_SCALE", DEFAULT_SLEEP_SCALE).to_f # seconds/100ms
  SAMPLE_SCALE_INTERVAL = 10_000 * SLEEP_SCALE # Microseconds
  SAMPLE_SCALE_ALLOCATIONS = 100
  private_constant :SLOW_RUNNER, :DEFAULT_SLEEP_SCALE, :SLEEP_SCALE, :SAMPLE_SCALE_INTERVAL, :SAMPLE_SCALE_ALLOCATIONS

  def slow_method
    sleep SLEEP_SCALE
  end

  def two_slow_methods
    slow_method
    1.times do
      slow_method
    end
  end

  def assert_similar expected, actual
    delta_ratio =
      if SLOW_RUNNER
        0.25
      else
        0.1
      end
    delta = expected * delta_ratio
    assert_in_delta expected, actual, delta
  end
end
