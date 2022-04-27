# frozen_string_literal: true

require "test_helper"

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

    lines = result.lines.map(&:chomp)

    assert lines.size < 200
    assert lines.size > 100

    lines_matching_retained = lines.select do |line|
      line.include?("#{__FILE__}:#{start_line+5}")
    end

    # WHY 101 and not 100 ????
    assert lines_matching_retained.size == 101

    #lines.uniq.each do |line|
    #  puts "="*80
    #  puts line.split(";")
    #end
  end
end
