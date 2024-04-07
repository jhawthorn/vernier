# frozen_string_literal: true

require "test_helper"

class TestStackTable < Minitest::Test
  def test_new
    Vernier::StackTable.new
  end

  def test_empty_to_h
    stack_table = Vernier::StackTable.new
    hash = stack_table.to_h
    assert_empty hash[:stack_table][:parent]
    assert_empty hash[:stack_table][:frame]
    assert_empty hash[:frame_table][:func]
    assert_empty hash[:frame_table][:line]
    assert_empty hash[:func_table][:name]
    assert_empty hash[:func_table][:filename]
    assert_empty hash[:func_table][:first_line]
  end

  def test_current_sample
    stack_table = Vernier::StackTable.new
    stack1 = stack_table.current_stack; stack2 = stack_table.current_stack
    stack3 = stack_table.current_stack

    assert_equal stack1, stack2
    refute_equal stack1, stack3

    hash = stack_table.to_h

    # We must have recorded at least one stack for each level of depth of our
    # current stack
    assert_operator hash[:stack_table][:parent].size, :>, caller_locations.size+1

    frame1 = hash[:stack_table][:frame][stack1]
    frame3 = hash[:stack_table][:frame][stack3]

    func1 = hash[:frame_table][:func][frame1]
    func3 = hash[:frame_table][:func][frame1]

    name1 = hash[:func_table][:name][func1]
    name3 = hash[:func_table][:name][func3]
    assert_equal "#{self.class}##{__method__}", name1
    assert_equal "#{self.class}##{__method__}", name3

    filename1 = hash[:func_table][:filename][func1]
    filename3 = hash[:func_table][:filename][func3]
    assert_equal File.absolute_path(__FILE__), File.expand_path(filename1)
    assert_equal File.absolute_path(__FILE__), File.expand_path(filename3)

    # Frames should not be the same, different lines
    refute_equal frame1, frame3

    #assert_equal func1, func3
  end

  def test_calling_to_h_multiple_times
    return skip("TODO")
    stack_table = Vernier::StackTable.new
    stack_table.current_stack

    first = stack_table.to_h
    second = stack_table.to_h
    assert_equal first, second
  end

  def test_current_sample_with_offset
    stack_table = Vernier::StackTable.new

    # No offset specified
    stack1 = stack_table.current_stack
    stack2 = stack_table.current_stack
    refute_equal stack1, stack2

    # Offset 0 - this method, different lines
    stack1 = stack_table.current_stack(0)
    stack2 = stack_table.current_stack(0)
    refute_equal stack1, stack2

    # Offset 1 - parent method
    stack1 = stack_table.current_stack(1)
    stack2 = stack_table.current_stack(1)
    assert_equal stack1, stack2

    # Too many arguments
    assert_raises ArgumentError do
      stack_table.current_stack(1, 2)
    end
  end

  def test_does_not_allocate
    stack_table = Vernier::StackTable.new

    before = GC.stat(:total_allocated_objects)
    10000.times do
      stack_table.current_stack
    end
    after = GC.stat(:total_allocated_objects)

    assert after < before + 10
  end

  def test_collector_stack_table
    collector = Vernier::Collector.new(:custom)
    collector.start
    collector.sample
    collector.stop

    assert_kind_of Vernier::StackTable, collector.stack_table

    assert_operator collector.stack_table.to_h[:stack_table][:parent].size, :>, caller_locations.size+1
  end

  def test_timer_and_manual_samples
    collector = Vernier::Collector.new(:wall, sample_rate: 10)
    collector.start

    stack_table = collector.stack_table
    100_000.times do |i|
      eval("stack_table.current_stack", binding, "(eval)", i)
    end

    collector.stop
  end
end
