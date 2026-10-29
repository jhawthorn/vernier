# frozen_string_literal: true

require "test_helper"
require "tempfile"

class TestOutputFirefox < Minitest::Test
  include FirefoxTestHelpers

  def test_complex_profile
    result = Vernier.trace do
      # Proper Ruby sleep
      sleep 0.01

      # Sleep inside rb_thread_call_without_gvl
      GVLTest.sleep_without_gvl(0.01)

      # Sleep with GVL held
      GVLTest.sleep_holding_gvl(0.01)

      # Ruby busy sleep
      target = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.01
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < target
      end

      # Short sleeps (likely) create markers without matching sampling stacks
      1.times { sleep 0.00001 }
      1.times { sleep 0.00001 }
      1.times { sleep 0.00001 }

      # Some GC time
      GC.start
    end

    output = Vernier::Output::Firefox.new(result).output
    assert_valid_firefox_profile(output)
  end

  def test_unfinished_threads_have_null_shutdown_times
    result = Vernier.trace { 1000.times { Object.new } }

    profile = JSON.parse(Vernier::Output::Firefox.new(result).output)
    profile["threads"].each do |thread|
      next if thread["unregisterTime"]
      assert thread.key?("unregisterTime")
      assert thread.key?("processShutdownTime")
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
    names = intervals.map { |record| data["shared"]["stringArray"][record.first] }.uniq

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
    th1_loc = nil

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
      th2 = Thread.new { sleep 0.01 }
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

  def test_selected_thread_with_main_thread_start
    result = Vernier.trace do
      Thread.new do
        sleep 0.01
      end.join
    end

    output = Vernier::Output::Firefox.new(result).output
    assert_valid_firefox_profile(output)

    data = JSON.parse(output)
    threads = data["threads"]
    assert_equal 2, threads.size

    meta = data["meta"]
    main_thread_index = threads.find_index { |tr| tr["isMainThread"] }
    assert_equal [main_thread_index], meta["initialSelectedThreads"]
  end

  def test_selected_thread_with_spawned_thread_start
    result = nil
    Thread.new do
      result = Vernier.trace do
        sleep 0.01
      end
    end.join

    output = Vernier::Output::Firefox.new(result).output
    assert_valid_firefox_profile(output)

    data = JSON.parse(output)
    threads = data["threads"]
    assert_equal 2, threads.size

    meta = data["meta"]
    spawned_thread_index = threads.find_index { |tr| !tr["isMainThread"] }
    assert_equal [spawned_thread_index], meta["initialSelectedThreads"]
  end

  def test_sources_not_embedded_by_default
    result = Vernier.trace do
      sleep 0.01
    end

    output = Vernier::Output::Firefox.new(result).output
    assert_valid_firefox_profile(output)

    sources = firefox_profile_sources(JSON.parse(output))
    assert_includes sources.keys, this_file_source_name
    assert sources.values.all?(&:nil?), "no source content should be embedded"
  end

  def test_embed_sources
    result = Vernier.trace(embed_sources: true) do
      sleep 0.01
    end

    output = Vernier::Output::Firefox.new(result).output
    assert_valid_firefox_profile(output)

    sources = firefox_profile_sources(JSON.parse(output))
    assert_equal File.read(__FILE__), sources.fetch(this_file_source_name)
    assert_nil sources.fetch("<cfunc>")
  end

  def test_embed_sources_at_output_time
    result = Vernier.trace do
      sleep 0.01
    end

    output = result.to_firefox(embed_sources: true)
    assert_valid_firefox_profile(output)
    sources = firefox_profile_sources(JSON.parse(output))
    assert_equal File.read(__FILE__), sources.fetch(this_file_source_name)

    output = Vernier::Output::Firefox.new(result, embed_sources: false).output
    sources = firefox_profile_sources(JSON.parse(output))
    assert_nil sources.fetch(this_file_source_name)
  end

  def test_embed_sources_with_missing_file
    # Code loaded from a file which no longer exists when the profile is written
    path = nil
    Tempfile.create(["vernier_missing", ".rb"], File.realpath(Dir.tmpdir)) do |file|
      file.write("def vernier_test_method_from_deleted_file\n  sleep 0.01\nend\n")
      file.flush
      path = file.path
      load path
    end
    refute File.exist?(path)

    result = Vernier.trace(embed_sources: true) do
      vernier_test_method_from_deleted_file
    end

    output = Vernier::Output::Firefox.new(result).output
    assert_valid_firefox_profile(output)

    sources = firefox_profile_sources(JSON.parse(output))
    assert_nil sources.fetch(path)
    assert_equal File.read(__FILE__), sources.fetch(this_file_source_name)
  end

  def test_shared_stack_table_only_contains_sampled_stacks
    result = Vernier.trace do
      th = Thread.new { sleep 0.01 }
      th.join
    end

    data = JSON.parse(Vernier::Output::Firefox.new(result).output)
    stack_length = data["shared"]["stackTable"]["length"]
    assert_operator stack_length, :>, 0

    referenced = data["threads"].flat_map do |thread|
      thread["samples"]["stack"] + thread["markers"]["data"].filter_map { |d| d&.dig("cause", "stack") }
    end
    assert_operator referenced.uniq.size, :<=, stack_length
    assert_operator referenced.max, :<, stack_length
  end

  def test_idle_samples_get_idle_category
    result = Vernier.trace do
      sleep 0.01
    end

    data = JSON.parse(Vernier::Output::Firefox.new(result).output)
    categories = data["meta"]["categories"].map { _1["name"] }
    idle_category = categories.index("Idle")

    shared = data["shared"]
    thread = data["threads"].first
    sample_categories = thread["samples"]["stack"].map do |stack_idx|
      frame_idx = shared["stackTable"]["frame"][stack_idx]
      shared["frameTable"]["category"][frame_idx]
    end
    assert_includes sample_categories, idle_category
  end

  def test_hide_anonymous_threads
    result = Vernier.trace(hide_anonymous_threads: true) do
      th1 = Thread.new { Thread.current.name = "not anonymous"; sleep 0.01 }
      th2 = Thread.new { sleep 0.02 }
      th1.join
      th2.join
    end

    data = JSON.parse(Vernier::Output::Firefox.new(result).output)
    threads = data["threads"]

    meta = data["meta"]
    main_thread_index = threads.find_index { |tr| tr["isMainThread"] }
    named_thread_index = threads.find_index { |tr| tr["name"] == "not anonymous" }
    assert_equal [main_thread_index, named_thread_index].sort, meta["initialVisibleThreads"]
  end

  def test_hide_anonymous_threads_with_spawned_thread_start
    result = nil
    Thread.new do
      result = Vernier.trace(hide_anonymous_threads: true) do
        sleep 0.01
      end
    end.join

    data = JSON.parse(Vernier::Output::Firefox.new(result).output)
    threads = data["threads"]

    meta = data["meta"]
    spawned_thread_index = threads.find_index { |tr| !tr["isMainThread"] }
    assert_includes meta["initialVisibleThreads"], spawned_thread_index
  end

  def test_allocation_samples
    result = Vernier.trace(allocation_interval: 1) do
      JSON.parse(%{{ "foo": { "bar": ["baz", 123] } }})
    end

    output = Vernier::Output::Firefox.new(result).output
    assert_valid_firefox_profile(output)
  end

  def test_profile_with_various_encodings
    result = Vernier.trace(mode: :custom) do |profiler|
      sample = -> { profiler.sample }

      encoded_method("ASCII", name: "ascii").call(&sample)
      encoded_method("UTF-8").call(&sample)
      encoded_method("BINARY").call(&sample)

      # This doesn't quite work how I'd like, as we just interpret bytes as
      # UTF-8, but what's most important is that we don't crash
      encoded_method("Shift_JIS").call(&sample)
    end

    output = Vernier::Output::Firefox.new(result).output
    assert_valid_firefox_profile(output)
  end

  private

  def file_lineno
    caller_locations(1, 1).first.yield_self{|loc| "#{loc.path}:#{loc.lineno}"}
  end

  private

  # The name under which this test file appears in the profile's sources
  def this_file_source_name
    Vernier::Output::FilenameFilter.new.call(File.expand_path(__FILE__))
  end
end
