# frozen_string_literal: true

require_relative "vernier/version"
require_relative "vernier/collector"
require_relative "vernier/stack_table"
require_relative "vernier/result"
require_relative "vernier/hooks"
require_relative "vernier/vernier"
require_relative "vernier/output/firefox"
require_relative "vernier/output/top"

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

      raise "Profile already started, stopping..."
    end

    @collector = Vernier::Collector.new(mode, collector_options)
    @collector.start
  end

  def self.stop_profile
    raise "No profile started" unless @collector

    result = @collector.stop
    @collector = nil

    result
  end

  def self.trace_retained(**profile_options, &block)
    profile(**profile_options.merge(mode: :retained), &block)
  end

  class Collector
    def self.new(mode, options = {})
      _new(mode, options)
    end
  end
end
