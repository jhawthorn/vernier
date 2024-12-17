# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "vernier"
require "gvltest"
require "firefox_test_helpers"

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
end

GC.auto_compact = true
