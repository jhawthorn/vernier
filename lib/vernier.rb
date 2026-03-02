# frozen_string_literal: true

require "vernier/version"
require "vernier/collector"
require "vernier/stack_table"
require "vernier/heap_tracker"
require "vernier/memory_leak_detector"
require "vernier/parsed_profile"
require "vernier/result"
require "vernier/hooks"
require "vernier/output/firefox"
require "vernier/output/cpuprofile"
require "vernier/output/top"
require "vernier/output/file_listing"
require "vernier/output/filename_filter"
require "vernier/output/markdown"
require "vernier/vernier"

module Vernier
  class Error < StandardError; end

  autoload :Middleware, "vernier/middleware"

  def self.profile(mode: :wall, **collector_options)
    collector = Vernier::Collector.new(mode, collector_options)
    collector.start

    result = nil
    begin
      yield collector
    ensure
      result = collector.stop
    end

    result
  end

  class << self
    alias_method :trace, :profile
    alias_method :run, :profile
  end

  @collector = nil

  def self.start_profile(mode: :wall, **collector_options)
    if @collector
      @collector.stop
      @collector = nil

      raise "profile already started, stopping..."
    end

    @collector = Vernier::Collector.new(mode, collector_options)
    @collector.start
  end

  def self.stop_profile
    raise "profile not started" unless @collector

    result = @collector.stop
    @collector = nil

    result
  end

  def self.trace_retained(**profile_options, &block)
    profile(**profile_options.merge(mode: :retained), &block)
  end
end
