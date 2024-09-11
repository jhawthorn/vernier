# frozen_string_literal: true

require "test_helper"

class IntegrationTest < Minitest::Test
  include FirefoxTestHelpers

  LIB_DIR = File.expand_path("../lib", __dir__)

  def test_allocations
    result = run_vernier({allocation_sample_rate: 1}, "-e", "")
    assert_valid_firefox_profile(result)
  end

  def run_vernier(options, *argv)
    result_json = nil
    Tempfile.open('vernier') do |tempfile|
      options = {
        quiet: true,
        output: tempfile.path,
      }.merge(options)
      env = options.map do |k, v|
        ["VERNIER_#{k.to_s.upcase}", v.to_s]
      end.to_h
      result = system(env, RbConfig.ruby, "-I", LIB_DIR, "-r", "vernier/autorun", *argv, exception: true)
      tempfile.rewind
      result_json = tempfile.read
    end
    result = JSON.parse(result_json)
    result
  end
end
