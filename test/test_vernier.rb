# frozen_string_literal: true

require "test_helper"
require "json"

class ReportReader
  def initialize(json)
    @data = JSON.parse(json)
  end

  def profile_hash
    @profile_hash ||= @data["profiles"][0]
  end

  def frames_array
    @frames_array ||= @data["shared"]["frames"]
  end

  def weights
    profile_hash["weights"]
  end

  def total_bytes
    weights.sum
  end
end

class TestVernier < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Vernier::VERSION
  end

  def test_tracing_retained_objects
    retained = []

    start_line = __LINE__
    result = Vernier.trace_retained do
      100.times {
        Object.new

        retained << Object.new
      }
    end

    result = ReportReader.new(result)

    assert result.total_bytes > 40 * 100
    assert result.total_bytes < 40 * 200

    #lines_matching_retained = lines.select do |line|
    #  line.include?("#{__FILE__}:#{start_line+5}")
    #end

    ## WHY 101 and not 100 ????
    #assert lines_matching_retained.size == 101

    #lines.uniq.each do |line|
    #  puts "="*80
    #  puts line.split(";")
    #end
  end

  def test_empty_block
    result = Vernier.trace_retained do
    end

    result = ReportReader.new(result)
    assert result.total_bytes < 40 * 8
  end

  def test_nothing_retained
    result = Vernier.trace_retained do
      100.times {
        Object.new
      }
    end

    result = ReportReader.new(result)
    assert result.total_bytes < 40 * 8
  end

  def test_nothing_retained_in_eval
    result = Vernier.trace_retained do
      100.times {
        eval "Object.new"
      }
    end

    result = ReportReader.new(result)
    assert result.total_bytes < 40 * 8
  end

  def build_large_module
    eval <<~'RUBY'
    mod = Module.new
    1.times do |i|
      mod.module_eval "define_singleton_method(:test#{i}) { Object.new }; test#{i}"
    end
    RUBY
    nil
  end

  def test_nothing_retained_in_module_eval
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
end
