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
end
