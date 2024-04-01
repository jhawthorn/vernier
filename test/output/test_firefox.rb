# frozen_string_literal: true

require "test_helper"
require "firefox_test_helpers"

class TestOutputFirefox < Minitest::Test
  include FirefoxTestHelpers

  def test_gc_events_have_duration
    result = Vernier.trace do
      GC.start
      GC.start
    end
    output = Vernier::Output::Firefox.new(result).output
    assert_valid_firefox_profile(output)

    data = JSON.parse output
    thread = data["threads"].first
    markers = thread["markers"]
    intervals = markers["length"].times.map { |i|
      ["name", "startTime", "endTime", "phase"].map { |key|
        markers[key][i]
      }
    }.select { |record| record.last == Vernier::Marker::Phase::INTERVAL }

    # we should have _some_ intervals from GC
    assert_operator intervals.length, :>, 0
    names = intervals.map { |record| thread["stringArray"][record.first] }.uniq

    # We should have a GC pause in there
    assert_includes names, "GC pause"
  end

  def test_retained_firefox_output
    retained = []

    result = Vernier.trace_retained do
      100.times {
        retained << Object.new
      }
    end

    output = Vernier::Output::Firefox.new(result).output

    assert_valid_firefox_profile(output)

    data = JSON.parse(output)
    assert_equal 1, data["threads"].size
    assert_equal "retained memory", data["threads"][0]["name"]
  end

  def test_empty_block
    result = Vernier.trace do
    end
    output = Vernier::Output::Firefox.new(result).output
    assert_valid_firefox_profile(output)
  end

  def test_timed_firefox_output
    result = Vernier.trace do
      i = 0
      while i < 1_000_000
        i += 1
      end
    end

    output = Vernier::Output::Firefox.new(result).output

    assert_valid_firefox_profile(output)
  end

  def test_threaded_timed_firefox_output
    result = Vernier.trace do
      th1 = Thread.new { sleep 0.01 }
      th2 = Thread.new { sleep 0.02 }
      th1.join
      th2.join
    end

    output = Vernier::Output::Firefox.new(result).output

    assert_valid_firefox_profile(output)
  end

  def test_custom_intervals
    result = Vernier.trace do |collector|
      collector.record_interval("custom") do
        sleep 0.01
      end
    end

    output = Vernier::Output::Firefox.new(result).output

    assert_valid_firefox_profile(output)

    markers = JSON.parse(output)["threads"].flat_map { _1["markers"]["data"] }
    assert_includes markers, {"type"=>"UserTiming", "entryType"=>"measure", "name"=>"custom"}
  end


  def test_thread_names
    orig_name = Thread.current.name
    th1_loc, th2_loc = nil

    # Case with just the named, main thread and no location
    result = Vernier.trace do
      Thread.current.name="main"
    end

    output = Vernier::Output::Firefox.new(result).output
    assert_valid_firefox_profile(output)

    data = JSON.parse(output)
    threads = data["threads"]
    assert_equal 1, threads.size
    assert_equal("main", threads.first["name"])

    # Case with unnamed thread and location
    result = Vernier.trace do
      th1 = Thread.new { th1_loc = file_lineno; sleep 0.01 }
      th1.join
    end

    output = Vernier::Output::Firefox.new(result).output
    assert_valid_firefox_profile(output)

    data = JSON.parse(output)
    threads = data["threads"]
    assert_equal 2, threads.size

    threads.each do |tr|
      next if tr["isMainThread"]
      assert_match(/^#{th1_loc} \(\d+\)$/, tr["name"])
    end

    # Case with named thread and location
    result = Vernier.trace do
      th2 = Thread.new { th2_loc = file_lineno; sleep 0.01 }
      th2.name = "named thread"
      th2.join
    end

    output = Vernier::Output::Firefox.new(result).output
    assert_valid_firefox_profile(output)

    data = JSON.parse(output)
    threads = data["threads"]
    assert_equal 2, threads.size

    threads.each do |tr|
      next if tr["isMainThread"]
      assert_equal "named thread", tr["name"]
    end

  ensure
    Thread.current.name = orig_name
  end

  private

  def file_lineno
    caller_locations(1, 1).first.yield_self{|loc| "#{loc.path}:#{loc.lineno}"}
  end
end
