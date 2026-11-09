# frozen_string_literal: true

require "test_helper"
require "stringio"

class TestOutputPprof < Minitest::Test
  include PprofTestHelpers

  Protobuf = Vernier::Output::Pprof::Protobuf

  # Encoding examples from https://protobuf.dev/programming-guides/encoding/
  def test_protobuf_varint
    assert_equal "\x00".b, varint(0)
    assert_equal "\x01".b, varint(1)
    assert_equal "\x7f".b, varint(127)
    assert_equal "\x80\x01".b, varint(128)
    assert_equal "\x96\x01".b, varint(150)
    assert_equal "\xac\x02".b, varint(300)
    assert_equal "\x80\x80\x80\x80\x10".b, varint(1 << 32)
    assert_equal "\xff\xff\xff\xff\xff\xff\xff\xff\x7f".b, varint((1 << 63) - 1)
    assert_equal "\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01".b, varint((1 << 64) - 1)
  end

  def test_protobuf_int_fields
    buf = Protobuf.new_buffer
    Protobuf.write_int(buf, 1, 150)
    assert_equal "\x08\x96\x01".b, buf

    # Default values are omitted
    buf = Protobuf.new_buffer
    Protobuf.write_int(buf, 1, 0)
    assert_equal "".b, buf

    # Negative int64 is the 10 byte two's complement
    buf = Protobuf.new_buffer
    Protobuf.write_int(buf, 1, -1)
    assert_equal "\x08\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01".b, buf

    buf = Protobuf.new_buffer
    Protobuf.write_int(buf, 1, -(1 << 63))
    assert_equal "\x08\x80\x80\x80\x80\x80\x80\x80\x80\x80\x01".b, buf

    # Field numbers above 15 take a two byte tag
    buf = Protobuf.new_buffer
    Protobuf.write_int(buf, 16, 1)
    assert_equal "\x80\x01\x01".b, buf

    assert_raises(ArgumentError) { Protobuf.write_int(Protobuf.new_buffer, 1, 1 << 64) }
    assert_raises(ArgumentError) { Protobuf.write_int(Protobuf.new_buffer, 1, -(1 << 63) - 1) }
  end

  def test_protobuf_bool_field
    buf = Protobuf.new_buffer
    Protobuf.write_bool(buf, 7, true)
    Protobuf.write_bool(buf, 8, false)
    assert_equal "\x38\x01".b, buf
  end

  def test_protobuf_string_field
    buf = Protobuf.new_buffer
    Protobuf.write_string(buf, 2, "testing")
    assert_equal "\x12\x07testing".b, buf

    buf = Protobuf.new_buffer
    Protobuf.write_string(buf, 6, "")
    assert_equal "\x32\x00".b, buf

    buf = Protobuf.new_buffer
    Protobuf.write_string(buf, 1, "文字")
    assert_equal "\x0a\x06\xe6\x96\x87\xe5\xad\x97".b, buf

    assert_raises(ArgumentError) { Protobuf.write_string(Protobuf.new_buffer, 1, "\xff".b) }
  end

  def test_protobuf_packed_ints
    buf = Protobuf.new_buffer
    Protobuf.write_packed_ints(buf, 6, [3, 270, 86942])
    assert_equal "\x32\x06\x03\x8e\x02\x9e\xa7\x05".b, buf

    buf = Protobuf.new_buffer
    Protobuf.write_packed_ints(buf, 6, [])
    assert_equal "".b, buf
  end

  def test_protobuf_embedded_message
    inner = Protobuf.new_buffer
    Protobuf.write_int(inner, 1, 150)
    buf = Protobuf.new_buffer
    Protobuf.write_bytes(buf, 3, inner)
    assert_equal "\x1a\x03\x08\x96\x01".b, buf
  end

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

    output = result.to_pprof
    profile = assert_valid_pprof(output)

    assert_equal [["samples", "count"], ["wall", "nanoseconds"]], pprof_sample_types(profile)
    assert_equal "wall", pprof_string(profile, profile[:default_sample_type])
    assert_equal ["wall", "nanoseconds"], [pprof_string(profile, profile[:period_type][:type]), pprof_string(profile, profile[:period_type][:unit])]
    assert_equal result.meta[:interval] * 1000, profile[:period]

    assert_in_delta result.started_at, profile[:time_nanos], 1_000_000
    assert_in_delta result.end_time - result.started_at, profile[:duration_nanos], 1_000_000

    totals = pprof_totals(profile)
    assert_equal result.total_weights, totals["samples"]
    assert_equal result.total_weights * profile[:period], totals["wall"]

    names = profile[:sample].flat_map { |sample| pprof_sample_stack(profile, sample).map(&:first) }.uniq
    assert_includes names, "Kernel#sleep"
    assert_includes names, "GVLTest.sleep_without_gvl"
    assert_includes names, "GVLTest.sleep_holding_gvl"
    assert_includes names, "Process.clock_gettime"

    states = profile[:sample].map { |sample| pprof_labels(profile, sample)["state"] }.uniq
    assert_includes states, "running"
    assert_includes states, "idle"
    assert_empty states - %w[running idle stalled]

    main_thread = result.main_thread
    profile[:sample].each do |sample|
      labels = pprof_labels(profile, sample)
      assert_equal main_thread[:name], labels["thread"]
      assert_equal main_thread[:tid], labels["tid"]
    end
  end

  def test_empty_block
    result = Vernier.trace do
    end
    profile = assert_valid_pprof(result.to_pprof)
    assert_equal [["samples", "count"], ["wall", "nanoseconds"]], pprof_sample_types(profile)
  end

  def test_threads
    result = Vernier.trace do
      th1 = Thread.new { Thread.current.name = "pprof thread one"; sleep 0.02 }
      th2 = Thread.new { Thread.current.name = "pprof thread two"; sleep 0.02 }
      th1.join
      th2.join
    end

    profile = assert_valid_pprof(result.to_pprof)

    thread_names = profile[:sample].map { |sample| pprof_labels(profile, sample)["thread"] }.uniq
    assert_includes thread_names, "pprof thread one"
    assert_includes thread_names, "pprof thread two"

    # Samples are included from all threads
    totals = pprof_totals(profile)
    assert_equal result.total_weights, totals["samples"]

    result.threads.each_value do |thread|
      next if thread[:samples].empty?

      thread_samples = profile[:sample].select { |sample| pprof_labels(profile, sample)["thread"] == thread[:name] }
      assert_equal thread[:weights].sum, thread_samples.sum { |sample| sample[:value][0] }
      thread_samples.each do |sample|
        labels = pprof_labels(profile, sample)
        if thread[:tid] == 0
          refute labels.key?("tid"), "unknown native thread ids are omitted"
        else
          assert_equal thread[:tid], labels["tid"]
        end
      end
    end
  end

  def pprof_test_outer(profiler)
    pprof_test_inner(profiler)
  end

  def pprof_test_inner(profiler)
    profiler.sample
  end

  def test_stacks_match_result
    result = Vernier.trace(mode: :custom) do |profiler|
      3.times { pprof_test_outer(profiler) }
      pprof_test_inner(profiler)
    end

    profile = assert_valid_pprof(result.to_pprof)

    assert_equal [["samples", "count"]], pprof_sample_types(profile)
    assert_equal 0, profile[:period]
    assert_nil profile[:period_type]

    # Identical stacks are collapsed into one sample
    assert_equal 2, profile[:sample].size
    assert_equal 4, pprof_totals(profile)["samples"]

    outer_sample = profile[:sample].find { |sample| sample[:value] == [3] }
    inner_sample = profile[:sample].find { |sample| sample[:value] == [1] }
    refute_nil outer_sample
    refute_nil inner_sample

    outer_stack = pprof_sample_stack(profile, outer_sample)
    inner_stack = pprof_sample_stack(profile, inner_sample)

    # Leaf first, matching the order of the stack table
    outer_names = outer_stack.map(&:first)
    inner_names = inner_stack.map(&:first)
    assert_operator outer_names.index("TestOutputPprof#pprof_test_inner"), :<, outer_names.index("TestOutputPprof#pprof_test_outer")
    assert_includes inner_names, "TestOutputPprof#pprof_test_inner"
    refute_includes inner_names, "TestOutputPprof#pprof_test_outer"

    inner_frame = outer_stack.find { |name, _| name == "TestOutputPprof#pprof_test_inner" }
    outer_frame = outer_stack.find { |name, _| name == "TestOutputPprof#pprof_test_outer" }
    assert_equal File.expand_path(__FILE__), inner_frame[1]
    assert_equal method(:pprof_test_inner).source_location[1] + 1, inner_frame[2]
    assert_equal method(:pprof_test_outer).source_location[1] + 1, outer_frame[2]

    # Every sample's stack matches the stack table's view of it
    expected_stacks = result.threads.values.flat_map do |thread|
      thread[:samples].map do |stack_idx|
        result.stack_table.stack(stack_idx).frames.map { |frame| [frame.name, frame.filename, frame.line] }
      end
    end.uniq
    actual_stacks = profile[:sample].map { |sample| pprof_sample_stack(profile, sample) }
    assert_equal expected_stacks.sort, actual_stacks.sort

    # Function start lines
    functions = profile[:function].to_h { |f| [pprof_string(profile, f[:name]), f] }
    assert_equal method(:pprof_test_inner).source_location[1], functions.fetch("TestOutputPprof#pprof_test_inner")[:start_line]
  end

  def test_only_referenced_locations_and_functions_are_written
    result = Vernier.trace(mode: :custom) do |profiler|
      pprof_test_outer(profiler)
    end

    profile = assert_valid_pprof(result.to_pprof)
    referenced = profile[:sample].flat_map { |sample| sample[:location_id] }.uniq.sort
    assert_equal referenced, profile[:location].map { |l| l[:id] }.sort

    referenced_functions = profile[:location].flat_map { |l| l[:line].map { |line| line[:function_id] } }.uniq.sort
    assert_equal referenced_functions, profile[:function].map { |f| f[:id] }.sort
  end

  def test_allocation_samples
    result = Vernier.trace(allocation_interval: 1) do
      JSON.parse(%{{ "foo": { "bar": ["baz", 123] } }})
    end

    profile = assert_valid_pprof(result.to_pprof)

    assert_equal [["samples", "count"], ["wall", "nanoseconds"], ["allocations", "count"]], pprof_sample_types(profile)
    assert_equal "wall", pprof_string(profile, profile[:default_sample_type])

    totals = pprof_totals(profile)
    assert_equal result.total_weights, totals["samples"]
    expected_allocations = result.threads.values.sum { |thread| thread[:allocations][:weights].sum }
    assert_operator expected_allocations, :>, 0
    assert_equal expected_allocations, totals["allocations"]

    allocation_samples = profile[:sample].select { |sample| sample[:value][2] > 0 }
    allocation_samples.each do |sample|
      assert_equal [0, 0], sample[:value][0, 2], "allocation samples carry no time"
      refute pprof_labels(profile, sample).key?("state")
    end
    time_samples = profile[:sample] - allocation_samples
    time_samples.each do |sample|
      assert_equal 0, sample[:value][2]
    end

    names = allocation_samples.flat_map { |sample| pprof_sample_stack(profile, sample).map(&:first) }
    assert_includes names, "JSON::Ext::Parser.parse"
  end

  def test_allocation_samples_are_scaled_by_interval
    result = Vernier.trace(allocation_interval: 10) do
      Array.new(10_000) { Object.new }
    end
    skip "no allocation samples recorded" if result.threads.values.sum { |t| t[:allocations][:samples].size } == 0

    profile = assert_valid_pprof(result.to_pprof)
    sampled = result.threads.values.sum { |thread| thread[:allocations][:weights].sum }
    assert_equal sampled * 10, pprof_totals(profile)["allocations"]
  end

  def test_retained
    retained = []
    result = Vernier.trace_retained do
      100.times { retained << Object.new }
      retained << "x" * 10_000
    end

    profile = assert_valid_pprof(result.to_pprof)

    assert_equal [["objects", "count"], ["retained", "bytes"]], pprof_sample_types(profile)
    assert_equal "retained", pprof_string(profile, profile[:default_sample_type])
    assert_nil profile[:period_type]
    assert_equal 0, profile[:period]

    totals = pprof_totals(profile)
    assert_equal result.total_samples, totals["objects"]
    assert_equal result.total_bytes, totals["retained"]
    assert_operator totals["retained"], :>=, 10_000

    profile[:sample].each do |sample|
      refute pprof_labels(profile, sample).key?("state")
    end
  ensure
    retained.clear
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

    profile = assert_valid_pprof(result.to_pprof)
    names = profile[:function].map { |f| pprof_string(profile, f[:name]) }
    assert names.any? { |name| name.end_with?(".ascii") }, names.inspect
    assert names.any? { |name| name.end_with?(".文字化け") }, names.inspect
  end

  def test_metadata_comments
    result = Vernier.trace(metadata: { "key1" => "val1", key2: "val2" }) { sleep 0.001 }

    profile = assert_valid_pprof(result.to_pprof)
    comments = profile[:comment].map { |idx| pprof_string(profile, idx) }
    assert_equal ["key1: val1", "key2: val2"], comments
  end

  def test_gzip
    result = Vernier.trace { sleep 0.001 }

    raw = result.to_pprof
    gzipped = result.to_pprof(gzip: true)

    assert gzipped.start_with?("\x1F\x8B".b)
    assert_equal pprof_without_times(decode_pprof(raw)), pprof_without_times(decode_pprof(Zlib.gunzip(gzipped)))
    assert_valid_pprof(gzipped)
  end

  def test_write
    result = Vernier.trace { sleep 0.001 }

    Dir.mktmpdir do |dir|
      path = File.join(dir, "profile.vernier.pb.gz")
      result.write(out: path, format: "pprof")
      content = File.binread(path)
      assert content.start_with?("\x1F\x8B".b), "expected a gzipped file"
      assert_equal pprof_without_times(decode_pprof(result.to_pprof)), pprof_without_times(decode_pprof(content))

      path = File.join(dir, "profile.pprof")
      result.write(out: path, format: "pprof")
      content = File.binread(path)
      refute content.start_with?("\x1F\x8B".b), "expected an uncompressed file"
      assert_valid_pprof(content)
    end

    io = StringIO.new
    result.write(out: io, format: "pprof")
    assert_valid_pprof(io.string)
  end

  def test_output_is_binary_and_deterministic
    result = Vernier.trace { sleep 0.001 }
    first = result.to_pprof
    second = result.to_pprof
    assert_equal Encoding::BINARY, first.encoding
    # Result#started_at is derived from the current clocks, so only the
    # time fields may differ between two outputs of the same result.
    assert_equal pprof_without_times(decode_pprof(first)), pprof_without_times(decode_pprof(second))
  end

  # The remaining tests run the real pprof tool when one is available
  # (`pprof` or `go` in PATH, or VERNIER_PPROF="...").

  def test_pprof_tool_wall
    skip "pprof tool not available" unless pprof_command

    result = Vernier.trace do
      sleep 0.01
      GVLTest.sleep_holding_gvl(0.01)
      target = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.01
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < target
      end
    end
    output = result.to_pprof(gzip: true)

    raw = run_pprof(output, "-raw")
    assert_includes raw, "Kernel#sleep"
    assert_includes raw, "GVLTest.sleep_holding_gvl"
    assert_includes raw, "Process.clock_gettime"

    top = run_pprof(output, "-top", "-nodecount=1000")
    assert_includes top, "Type: wall"
    assert_includes top, "Kernel#sleep"
    assert_includes top, "GVLTest.sleep_holding_gvl"
    assert_match(/Duration: .*Total samples = /, top)

    top_samples = run_pprof(output, "-top", "-sample_index=samples")
    assert_includes top_samples, "Type: samples"
    assert_match(/#{result.total_weights} total$/, top_samples.lines.grep(/Showing nodes/).first.to_s.strip)

    tags = run_pprof(output, "-tags")
    assert_includes tags, "state:"
    assert_includes tags, "thread:"
    assert_includes tags, "idle"
    assert_includes tags, "running"

    # Idle samples (Kernel#sleep) can be filtered out via the state label
    running_only = run_pprof(output, "-top", "-nodecount=1000", "-tagfocus=state=running")
    refute_match(/^.*Kernel#sleep$/, running_only)
    assert_includes running_only, "GVLTest.sleep_holding_gvl"

    traces = run_pprof(output, "-traces")
    assert_includes traces, "TestOutputPprof#test_pprof_tool_wall"
  end

  class Comparison
    def initialize(profiler)
      @profiler = profiler
    end

    def <=>(other)
      @profiler.sample
      0
    end
  end

  # pprof applies C++ demangling heuristics to names that look mangled, which
  # would turn "Comparison#<=>" into "Comparison#". Ruby names must survive.
  def test_pprof_tool_keeps_operator_method_names
    skip "pprof tool not available" unless pprof_command

    result = Vernier.trace(mode: :custom) do |profiler|
      Comparison.new(profiler) <=> nil
    end
    output = result.to_pprof(gzip: true)

    names = result.stack_table.func_count.times.map { |i| result.stack_table.func_name(i) }
    assert_includes names, "TestOutputPprof::Comparison#<=>"

    top = run_pprof(output, "-top", "-nodecount=1000")
    assert_match(/ TestOutputPprof::Comparison#<=>$/, top)

    traces = run_pprof(output, "-traces")
    assert_match(/ TestOutputPprof::Comparison#<=>$/, traces)
  end

  def test_pprof_tool_allocations
    skip "pprof tool not available" unless pprof_command

    result = Vernier.trace(allocation_interval: 1) do
      JSON.parse(%{{ "foo": { "bar": ["baz", 123] } }})
    end
    output = result.to_pprof(gzip: true)

    top = run_pprof(output, "-top")
    assert_includes top, "Type: wall"

    top = run_pprof(output, "-top", "-sample_index=allocations", "-nodecount=1000")
    assert_includes top, "Type: allocations"
    assert_includes top, "JSON::Ext::Parser.parse"
  end

  def test_pprof_tool_retained
    skip "pprof tool not available" unless pprof_command

    retained = []
    result = Vernier.trace_retained do
      retained << "x" * 10_000
    end
    output = result.to_pprof(gzip: true)

    top = run_pprof(output, "-top", "-unit=B", "-nodecount=1000")
    assert_includes top, "Type: retained"
    assert_includes top, "String#*"
    assert_match(/#{result.total_bytes}B total/, top)
  ensure
    retained&.clear
  end

  private

  def varint(value)
    buf = Protobuf.new_buffer
    Protobuf.varint(buf, value)
    buf
  end
end
