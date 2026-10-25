# frozen_string_literal: true

module FirefoxTestHelpers
  FRAME_FLAG_HAS_CATEGORY = Vernier::Output::Firefox::FRAME_FLAG_HAS_CATEGORY
  FRAME_FLAG_HAS_LINE = Vernier::Output::Firefox::FRAME_FLAG_HAS_LINE
  FUNC_FLAG_IS_JS = Vernier::Output::Firefox::FUNC_FLAG_IS_JS
  FUNC_FLAG_HAS_SOURCE = Vernier::Output::Firefox::FUNC_FLAG_HAS_SOURCE
  FUNC_FLAG_HAS_LINE = Vernier::Output::Firefox::FUNC_FLAG_HAS_LINE

  def assert_valid_firefox_profile(profile)
    data = JSON.parse(profile)

    meta = data["meta"]
    assert meta
    assert_equal 28, meta["version"]
    assert_equal Vernier::Output::Firefox::PROCESSED_PROFILE_VERSION, meta["preprocessedProfileVersion"]
    assert_equal 1, meta["stackwalk"]
    assert meta["interval"]
    assert meta["startTime"]

    meta["markerSchema"].each do |schema|
      assert schema["name"]
      assert_kind_of Array, schema["display"]
      assert_kind_of Array, schema["fields"], "#{schema["name"]} must list its fields"
      refute schema.key?("data"), "#{schema["name"]} uses the pre-55 marker schema format"
      schema["fields"].each do |field|
        assert field["key"], "#{schema["name"]} fields must have a key"
        assert field["format"], "#{schema["name"]} fields must have a format"
      end
    end

    (data["counters"] || []).each do |counter|
      assert counter["name"]
      assert_equal counter["samples"]["length"], counter["samples"]["time"].size
      assert_equal counter["samples"]["length"], counter["samples"]["count"].size
      display = counter["display"]
      assert display, "counter #{counter["name"]} needs a display config"
      %w[graphType unit color sortWeight label tooltipRows].each do |key|
        assert display.key?(key), "counter #{counter["name"]} display is missing #{key}"
      end
    end

    categories = meta["categories"]

    shared = data["shared"]
    assert shared
    assert_valid_shared_tables(shared, categories)

    stack_length = shared["stackTable"]["length"]
    string_array = shared["stringArray"]

    threads = data["threads"]
    assert_equal 1, threads.count { _1["isMainThread"] }
    assert_operator threads.size, :>=, 1
    assert_equal threads.size, meta["initialVisibleThreads"].size
    assert_equal 1, meta["initialSelectedThreads"].size

    data["counters"].each do |counter|
      assert_kind_of String, counter["pid"]
      assert_kind_of Integer, counter["mainThreadIndex"]
      assert_operator counter["mainThreadIndex"], :<, threads.size
    end
    threads.each do |thread|
      assert thread["name"]
      assert_kind_of String, thread["pid"]
      assert thread["tid"]
      assert thread["registerTime"]
      assert_equal "default", thread["processType"]

      # These are shared across threads
      %w[frameTable funcTable stackTable stringArray resourceTable nativeSymbols].each do |key|
        refute thread.key?(key), "#{key} belongs in shared, not on the thread"
      end

      assert thread["markers"]

      markers = thread["markers"]
      assert markers["data"]
      marker_keys = ["data", "name", "startTime", "endTime", "phase", "category", "length"]
      assert_equal marker_keys.sort, markers.keys.sort

      assert_operator markers["length"], :>=, 0

      markers["length"].times do |i|
        name_idx = markers["name"][i]
        assert_kind_of Integer, name_idx
        assert_operator name_idx, :<, string_array.size

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
          assert_operator stack_idx, :<, stack_length
        end
      end

      samples = thread["samples"]
      assert thread["samples"]
      assert_equal samples["length"], samples["stack"].size
      assert_equal samples["length"], samples["weight"].size
      assert_equal samples["length"], samples["time"].size

      assert_operator samples["stack"].max || -1, :<, stack_length

      if allocations = thread["jsAllocations"]
        assert_equal allocations["length"], allocations["stack"].size
        assert_equal allocations["length"], allocations["weight"].size
        assert_equal allocations["length"], allocations["time"].size
        assert_equal allocations["length"], allocations["className"].size
        assert_equal allocations["length"], allocations["typeName"].size
        assert_equal allocations["length"], allocations["coarseType"].size
        assert_equal allocations["length"], allocations["inNursery"].size

        assert_operator allocations["stack"].max || -1, :<, stack_length
      end
    end
  end

  def assert_valid_shared_tables(shared, categories)
    string_array = shared["stringArray"]
    assert_kind_of Array, string_array

    stack_table = shared["stackTable"]
    frame_table = shared["frameTable"]
    func_table = shared["funcTable"]
    sources = shared["sources"]

    stack_length = stack_table["length"]
    frame_length = frame_table["length"]
    func_length = func_table["length"]
    source_length = sources["length"]

    # Check stack table
    assert_equal %w[frame prefixOffset length].sort, stack_table.keys.sort
    assert_equal stack_length, stack_table["frame"].length
    assert_equal stack_length, stack_table["prefixOffset"].length

    stack_table["prefixOffset"].each_with_index do |offset, idx|
      assert_kind_of Integer, offset
      # 0 means root, otherwise the parent is at idx - offset
      assert_operator offset, :>=, 0
      assert_operator offset, :<=, idx
    end

    stack_table["frame"].each do |idx|
      assert_operator idx, :<, frame_length
    end

    # Check frame table
    frame_columns = %w[flags address lib category subcategory func nativeSymbol innerWindowID line column originalLocation]
    assert_equal (frame_columns + ["length"]).sort, frame_table.keys.sort
    frame_columns.each do |column|
      assert_equal frame_length, frame_table[column].length, "frameTable.#{column}"
      frame_table[column].each { |value| assert_kind_of Integer, value, "frameTable.#{column} must not contain nulls" }
    end

    frame_length.times do |idx|
      flags = frame_table["flags"][idx]
      assert_equal FRAME_FLAG_HAS_CATEGORY, flags & FRAME_FLAG_HAS_CATEGORY, "every frame has a category"

      category_idx = frame_table["category"][idx]
      subcategory_idx = frame_table["subcategory"][idx]
      assert_operator category_idx, :<, categories.length
      assert_operator subcategory_idx, :<, categories[category_idx]["subcategories"].length

      assert_operator frame_table["func"][idx], :<, func_length

      if flags & FRAME_FLAG_HAS_LINE != 0
        assert_operator frame_table["line"][idx], :>, 0
      end
    end

    # Check func table
    func_columns = %w[flags name resource source lineNumber columnNumber originalLocation]
    assert_equal (func_columns + ["length"]).sort, func_table.keys.sort
    func_columns.each do |column|
      assert_equal func_length, func_table[column].length, "funcTable.#{column}"
      func_table[column].each { |value| assert_kind_of Integer, value, "funcTable.#{column} must not contain nulls" }
    end

    func_length.times do |idx|
      flags = func_table["flags"][idx]
      assert_operator func_table["name"][idx], :<, string_array.size
      if flags & FUNC_FLAG_HAS_SOURCE != 0
        assert_operator func_table["source"][idx], :<, source_length
      end
    end

    # Check sources
    source_columns = %w[id filename startLine startColumn sourceMapURL content]
    assert_equal (source_columns + ["length"]).sort, sources.keys.sort
    source_columns.each do |column|
      assert_equal source_length, sources[column].length, "sources.#{column}"
    end
    sources["filename"].each do |idx|
      assert_kind_of Integer, idx
      assert_operator idx, :<, string_array.size
    end
    sources["content"].each do |content|
      assert_kind_of String, content unless content.nil?
    end

    assert_equal 0, shared["resourceTable"]["length"]
    assert_equal 0, shared["nativeSymbols"]["length"]
    assert_equal 0, shared["sourceLocationTable"]["length"]
  end
end
