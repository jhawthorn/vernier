# frozen_string_literal: true

module FirefoxTestHelpers
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
end
