# frozen_string_literal: true

require_relative "vernier/version"
require_relative "vernier/vernier"

module Vernier
  class Error < StandardError; end

  def self.trace_retained(out: nil, gc: true)
    3.times { GC.start } if gc
    Vernier.trace_retained_start

    result = nil
    begin
      yield
    ensure
      result = Vernier.trace_retained_stop
    end

    File.write(out, result) if out
    result
  end
end
