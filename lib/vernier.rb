# frozen_string_literal: true

require_relative "vernier/version"
require_relative "vernier/collector"
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
