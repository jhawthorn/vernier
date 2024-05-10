# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "vernier"

ENV["MT_CPU"] = "0"
require "minitest/autorun"

class Minitest::Test
  make_my_diffs_pretty!

  def assert_valid_result(result)
    assert_equal result.samples.length, result.weights.length

    stack_table_size = result._stack_table.stack_count

    result.samples.each do |stack_idx|
      assert_kind_of Integer, stack_idx
      assert stack_idx < stack_table_size
    end
  end
end
