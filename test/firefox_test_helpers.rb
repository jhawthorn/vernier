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

    categories = data["meta"]["categories"]
    threads = data["threads"]
    assert_equal 1, threads.count { _1["isMainThread"] }
    assert_operator threads.size, :>=, 1
    assert_equal threads.size, meta["initialVisibleThreads"].size
    assert_equal 1, meta["initialSelectedThreads"].size
    threads.each do |thread|
      assert thread["name"]
      assert thread["pid"]
      assert thread["tid"]
      assert thread["registerTime"]

      assert thread["frameTable"]
      assert thread["funcTable"]
      assert thread["stackTable"]
      assert thread["stringArray"]

      stack_length = thread["stackTable"]["length"]
      frame_length = thread["frameTable"]["length"]

      string_array = thread["stringArray"]

      # Check stack table
      assert_equal stack_length, thread["stackTable"]["frame"].length
      assert_equal stack_length, thread["stackTable"]["category"].length
      assert_equal stack_length, thread["stackTable"]["subcategory"].length
      assert_equal stack_length, thread["stackTable"]["prefix"].length

      thread["stackTable"]["prefix"].each do |prefix|
        next if prefix.nil?
        assert_operator prefix, :<, stack_length
      end

      thread["stackTable"]["frame"].each do |idx|
        assert_operator idx, :<, frame_length
      end

      stack_length.times do |idx|
        category_idx = thread["stackTable"]["category"][idx]
        subcategory_idx = thread["stackTable"]["subcategory"][idx]
        assert category_idx < categories.length
        assert subcategory_idx < categories[category_idx]["subcategories"].length
      end

      # Check frame table
      assert_equal frame_length, thread["frameTable"]["column"].length
      assert_equal frame_length, thread["frameTable"]["line"].length
      assert_equal frame_length, thread["frameTable"]["implementation"].length
      assert_equal frame_length, thread["frameTable"]["innerWindowID"].length
      assert_equal frame_length, thread["frameTable"]["func"].length
      assert_equal frame_length, thread["frameTable"]["category"].length
      assert_equal frame_length, thread["frameTable"]["inlineDepth"].length
      assert_equal frame_length, thread["frameTable"]["address"].length

      thread["frameTable"]["implementation"].each do |idx|
        next if idx.nil?
        assert_kind_of Integer, idx
        assert idx < string_array.size
      end

      frame_length.times do |idx|
        category_idx = thread["frameTable"]["category"][idx]
        #subcategory_idx = thread["frameTable"]["subcategory"][idx]
        assert category_idx < categories.length
        #assert subcategory_idx < categories[category_idx]["subcategories"].length
      end

      thread["funcTable"]["name"].each do |idx|
        assert_kind_of Integer, idx
        assert idx < string_array.size
      end
      thread["funcTable"]["fileName"].each do |idx|
        assert_kind_of Integer, idx
        assert idx < string_array.size
      end

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

        data = markers["data"][i]

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

        if stack_idx = data.dig("cause", "stack")
          assert_operator stack_idx, :<=, stack_length
        end
      end

      samples = thread["samples"]
      assert thread["samples"]
      assert_equal samples["length"], samples["stack"].size
      assert_equal samples["length"], samples["weight"].size
      assert_equal samples["length"], samples["time"].size

      assert_operator samples["stack"].max || -1, :<, thread["stackTable"]["length"]

      if allocations = thread["jsAllocations"]
        assert_equal allocations["length"], allocations["stack"].size
        assert_equal allocations["length"], allocations["weight"].size
        assert_equal allocations["length"], allocations["time"].size
        assert_equal allocations["length"], allocations["className"].size
        assert_equal allocations["length"], allocations["typeName"].size
        assert_equal allocations["length"], allocations["coarseType"].size
        assert_equal allocations["length"], allocations["inNursery"].size

        assert_operator allocations["stack"].max || -1, :<, thread["stackTable"]["length"]
      end
    end
  end
end
