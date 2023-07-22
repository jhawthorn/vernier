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

      samples = thread["samples"]
      assert thread["samples"]
      assert_equal samples["length"], samples["stack"].size
      assert_equal samples["length"], samples["weight"].size
      assert_equal samples["length"], samples["time"].size

      assert_operator samples["stack"].max || -1, :<, thread["stackTable"]["length"]
    end
  end

  def test_retained_firefox_output
    skip "retained is broken"
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
end
