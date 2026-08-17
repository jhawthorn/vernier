# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "vernier"
require "gvltest"
require "firefox_test_helpers"
require "cpuprofile_test_helpers"

ENV["MT_CPU"] = "0"
require "minitest/autorun"

class Minitest::Test
  make_my_diffs_pretty!

  def fixture_path(filename)
    File.expand_path("fixtures/#{filename}", __dir__)
  end

  def assert_valid_result(result)
    stack_table_size = result._stack_table.stack_count

    assert_kind_of Integer, result.pid
    assert_kind_of Integer, result.end_time
    assert_kind_of Integer, result.started_at

    assert_in_delta Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond), result.started_at, 300 * 1_000_000_000
    assert_in_delta Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond), result.end_time, 300 * 1_000_000_000

    meta = result.meta
    assert_kind_of Hash, meta
    mode = meta[:mode]
    assert_kind_of Symbol, mode

    threads = result.threads
    assert_kind_of Hash, threads
    refute_empty threads

    threads.each do |tid, thread|
      assert_kind_of Integer, thread[:tid]
      assert_kind_of String, thread[:name]
      assert_kind_of Integer, thread[:started_at]

      assert_kind_of Array, thread[:samples]
      assert_kind_of Array, thread[:weights]
      assert_equal thread[:samples].length, thread[:weights].length

      unless mode == :retained
        assert_kind_of Array, thread[:timestamps]
        assert_kind_of Array, thread[:sample_categories]
      end

      thread[:samples].each do |stack_idx|
        assert_kind_of Integer, stack_idx
        assert_operator stack_idx, :<, stack_table_size
        assert_operator stack_idx, :>=, 0
      end
    end
  end

  # Reference implementations of the original (pre-optimization) O(samples ×
  # stack depth) aggregation algorithms, used as oracles to prove the
  # optimized Output::FileListing and Output::Top produce identical results.

  def reference_samples_by_file(profile, filename_filter: nil)
    thread = profile.main_thread
    stack_table =
      if Hash === thread
        profile._stack_table
      else
        thread.stack_table
      end

    self_samples_by_frame = Hash.new { |h, k| h[k] = [0, 0] } # frame => [self, total]
    thread[:samples].zip(thread[:weights]).each do |stack_idx, weight|
      top_frame_index = stack_table.stack_frame_idx(stack_idx)
      self_samples_by_frame[top_frame_index][0] += weight

      while stack_idx
        frame_idx = stack_table.stack_frame_idx(stack_idx)
        self_samples_by_frame[frame_idx][1] += weight
        stack_idx = stack_table.stack_parent_idx(stack_idx)
      end
    end

    result = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = [0, 0] } }
    self_samples_by_frame.each do |frame, (self_weight, total_weight)|
      line = stack_table.frame_line_no(frame)
      func_index = stack_table.frame_func_idx(frame)
      filename = stack_table.func_filename(func_index)
      filename = filename_filter.call(filename) if filename_filter

      result[filename][line][0] += self_weight
      result[filename][line][1] += total_weight
    end
    result
  end

  def reference_top_by_self(profile)
    thread = profile.main_thread
    stack_table =
      if Hash === thread
        profile._stack_table
      else
        thread.stack_table
      end

    result = Hash.new(0)
    thread[:samples].zip(thread[:weights]).each do |stack_idx, weight|
      frame_idx = stack_table.stack_frame_idx(stack_idx)
      func_idx = stack_table.frame_func_idx(frame_idx)
      result[stack_table.func_name(func_idx)] += weight
    end
    result
  end

  def normalize_samples_by_file(samples_by_file)
    samples_by_file.transform_values do |lines|
      lines.transform_values { |location| [location.self, location.total] }
    end
  end

  # Builds a minimal gecko-format profile hash suitable for
  # Vernier::ParsedProfile. +stacks+ is a list of [prefix, frame_idx] pairs
  # where prefix must always be less than the stack's own index.
  def build_parsed_profile(funcs:, frames:, stacks:, samples:, weights:)
    strings = []
    string_idx = {}
    intern = ->(str) { string_idx[str] ||= (strings << str; strings.length - 1) }

    Vernier::ParsedProfile.new(
      "threads" => [{
        "isMainThread" => true,
        "name" => "main",
        "stackTable" => {
          "prefix" => stacks.map { |prefix, _| prefix },
          "frame" => stacks.map { |_, frame| frame },
        },
        "frameTable" => {
          "func" => frames.map { |func, _| func },
          "line" => frames.map { |_, line| line },
        },
        "funcTable" => {
          "name" => funcs.map { |name, _| intern.(name) },
          "fileName" => funcs.map { |_, file| intern.(file) },
          "lineNumber" => funcs.map { 1 },
        },
        "stringArray" => strings,
        "samples" => { "stack" => samples, "weight" => weights },
      }]
    )
  end

  def encoded_method(encoding, name: "文字化け")
    obj = Object.new
    code = <<~RUBY
      def #{name}
        yield
      end
    RUBY
    if encoding == "BINARY"
      code = code.b
      name = name.b
    else
      code = code.encode(encoding)
      name = name.encode(encoding)
    end
    obj.instance_eval(code)
    obj.method(name)
  end
end

GC.auto_compact = true
