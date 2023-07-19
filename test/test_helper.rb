# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "vernier"

ENV["MT_CPU"] = "0"
require "minitest/autorun"

class Minitest::Test
  def assert_valid_result(result)
    assert_equal result.samples.length, result.weights.length

    stack_table_size = result.stack_table[:parent].length
    assert_equal stack_table_size, result.stack_table[:frame].length
    result.samples.each do |stack_idx|
      assert stack_idx < stack_table_size
    end

    frame_table_size = result.frame_table[:func].length
    assert_equal frame_table_size, result.frame_table[:line].length
    result.stack_table[:frame].each do |frame_idx|
      assert frame_idx < frame_table_size, "frame index (#{frame_idx}) out of range #{frame_table_size}"
    end

    func_table_size = result.func_table[:name].length
    assert_equal func_table_size, result.func_table[:first_line].length
    assert_equal func_table_size, result.func_table[:filename].length
    result.frame_table[:func].each do |func_idx|
      assert func_idx < func_table_size
    end

    result.func_table[:name].each do |name|
    end
  end
end
