# frozen_string_literal: true

require "test_helper"

class TestOutputFirefox < Minitest::Test
  def assert_valid_firefox_profile(profile)
    data = JSON.parse(profile)

    meta = data["meta"]
    assert meta
    assert_equal 28, meta["version"]
    assert_equal 1, meta["stackwalk"]
    assert meta["interval"]
    assert meta["startTime"]

    threads = data["threads"]
    assert_equal 1, threads.count { _1["isMainThread"] }
    assert_operator threads.size, :>=, 1
    threads.each do |thread|
      assert thread["name"]
      assert thread["pid"]
      assert thread["tid"]
      assert thread["registerTime"]

      assert thread["frameTable"]
      assert thread["funcTable"]
      assert thread["stackTable"]
      assert thread["stringArray"]

      assert thread["markers"]

      markers = thread["markers"]
      assert markers["data"]
      assert markers["data"]
      marker_keys = ["data", "name", "startTime", "endTime", "phase", "category", "length"]
      assert_equal marker_keys.sort, markers.keys.sort

      assert_operator markers["length"], :>=, 0

      markers["length"].times do |i|
        start_time = markers["startTime"][i]
        assert start_time, "start time is required"

        end_time = markers["endTime"][i]

        phase = markers["phase"][i]
        assert_operator phase, :>=, 0
        case phase
        when Vernier::Marker::Phase::INSTANT
          assert_nil end_time
        when Vernier::Marker::Phase::INTERVAL
          assert end_time, "intervals must have an end time"
          assert_operator start_time, :<=, end_time
        else
        end
      end

      samples = thread["samples"]
      assert thread["samples"]
      assert_equal samples["length"], samples["stack"].size
      assert_equal samples["length"], samples["weight"].size
      assert_equal samples["length"], samples["time"].size

      assert_operator samples["stack"].max || -1, :<, thread["stackTable"]["length"]
    end
  end

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
