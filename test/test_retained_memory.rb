# frozen_string_literal: true

require "test_helper"

class ReportReader
  attr_reader :result
  def initialize(result)
    @result = result
  end

  def profile_hash
    @profile_hash ||= @data["profiles"][0]
  end

  def frames_array
    @frames_array ||= @data["shared"]["frames"]
  end

  def weights
    result.weights
  end

  def total_bytes
    weights.sum
  end
end

class TestRetainedMemory < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Vernier::VERSION
  end

  def test_tracing_retained_objects
    retained = []

    result = Vernier.trace_retained do
      100.times {
        Object.new

        retained << Object.new
      }
    end

    #reader = ReportReader.new(result)

    assert_operator result.total_bytes, :>, 40 * 100
    assert_operator result.total_bytes, :<, 40 * 200

    top_stack_tally = result.samples.tally.max_by(&:last)
    top_stack = result.stack(top_stack_tally.first)

    assert_equal "Class#new", top_stack.frames[0].label
    assert_equal "#{self.class}##{__method__}", top_stack.frames[1].label
  end

  def test_empty_block
    result = Vernier.trace_retained do
    end

    result = ReportReader.new(result)
    assert result.total_bytes < 40 * 8
  end

  def test_nested_collections
    result1 = result2 = nil
    result1 = Vernier.trace_retained do
      result2 = Vernier.trace_retained do
        Object.new
      end
    end

    assert_operator result2.samples.size, :>, 0
    assert_operator result1.samples.size, :>, result2.samples.size
  end

  def test_thread_allocation
    result = Vernier.trace_retained do
      Thread.new { }.join
    end
    assert_valid_result result
  end

  def test_nothing_retained
    result = Vernier.trace_retained do
      100.times {
        Object.new
      }
    end

    result = ReportReader.new(result)
    assert_operator result.total_bytes, :<, 40 * 8
  end

  def test_nothing_retained_in_eval
    result = Vernier.trace_retained do
      100.times {
        eval "Object.new"
      }
    end

    result = ReportReader.new(result)
    assert_operator result.total_bytes, :<, 40 * 8
  end

  def test_alloc_order
    result = Vernier.trace_retained do
      alloc_a
      alloc_b
      alloc_c
    end

    frames = result.each_sample.map {|stack, _| stack.frames[0] }
    labels = frames.map(&:label)
    inspects = frames.map(&:to_s)

    expected_labels = %W[
      #{self.class.name}#alloc_a
      #{self.class.name}#alloc_b
      #{self.class.name}#alloc_c
    ]
    assert_equal expected_labels, labels.grep(/#alloc_[abc]\z/)

    expected_inspects = [
      "#{self.class.name}#alloc_a at #{method(:alloc_a).source_location.join(":")}",
      "#{self.class.name}#alloc_b at #{method(:alloc_b).source_location.join(":")}",
      "#{self.class.name}#alloc_c at #{method(:alloc_c).source_location.join(":")}"
    ]
    assert_equal expected_inspects, inspects.grep(/#alloc_[abc]/)
  end

  def test_nothing_retained_in_module_eval
    skip("WIP")

    # Warm
    build_large_module

    result = Vernier.trace_retained do
      # Allocate a large module
      build_large_module
      build_large_module
      build_large_module

      # Do some other object allocations
      10_000.times { Object.new }
    end

    result = ReportReader.new(result)

    # Ideally this would be lower around 320, but in many cases it does seem to
    # use more memory
    assert_operator result.total_bytes, :<, 2500
  end

  def test_includes_options_in_result_meta
    output_file = File.join(__dir__, "../tmp/exception_output.json")
    result = Vernier.trace_retained(out: output_file) { }

    assert_equal :retained, result.meta[:mode]
    assert_equal output_file, result.meta[:out]
    assert_nil result.meta[:interval]
    assert_nil result.meta[:allocation_sample_rate]
    assert_equal true, result.meta[:gc]
  end

  private

  def build_large_module
    eval <<~'RUBY'
    mod = Module.new
    1.times do |i|
      mod.module_eval "define_singleton_method(:test#{i}) { Object.new }; test#{i}"
    end
    RUBY
    nil
  end

  def alloc_a = Object.new

  def alloc_b = Object.new

  def alloc_c = Object.new
end
