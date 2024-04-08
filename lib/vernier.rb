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

  def self.profile(mode: :wall, out: nil, gc: true, **collector_options)
    gc &&= (mode == :retained)
    3.times { GC.start } if gc

    collector = Vernier::Collector.new(mode, collector_options)
    collector.start

    result = nil
    begin
      yield collector
    ensure
      result = collector.stop
      if out
        result.write(out:)
      end
    end

    result
  end

  @collector = nil
  @collector_out = nil

  def self.start_profile(mode: :wall, out: nil, gc: true, **collector_options)
    if @collector
      @collector.stop
      @collector = @collector_out = nil

      raise "Profile already started, stopping..."
    end

    gc &&= (mode == :retained)
    3.times { GC.start } if gc

    @collector_out = out
    @collector = Vernier::Collector.new(mode, collector_options)
    @collector.start
  end

  def self.stop_profile
    raise "No profile started" unless @collector

    result = @collector.stop
    if @collector_out
      result.write(out: @collector_out)
    end
    @collector = @collector_out = nil

    result
  end

  class << self
    alias_method :trace, :profile
    alias_method :run, :profile
  end

  def self.trace_retained(out: nil, gc: true, &block)
    profile(mode: :retained, out:, gc:, &block)
  end

  class Collector
    def self.new(mode, options = {})
      _new(mode, options)
    end
  end
end
