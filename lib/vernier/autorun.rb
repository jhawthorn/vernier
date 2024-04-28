require "tempfile"
require "vernier"

module Vernier
  module Autorun
    class << self
      attr_accessor :collector
      attr_reader :options
    end
    @collector = nil

    @options = ENV.to_h.select { |k,v| k.start_with?("VERNIER_") }
    @options.transform_keys! do |key|
      key.sub(/\AVERNIER_/, "").downcase.to_sym
    end
    @options.freeze

    def self.start
      interval = options.fetch(:interval, 500).to_i
      allocation_sample_rate = options.fetch(:allocation_sample_rate, 0).to_i
      hooks = options.fetch(:hooks, "").split(",")

      STDERR.puts("starting profiler with interval #{interval}")

      @collector = Vernier::Collector.new(:wall, interval:, allocation_sample_rate:, hooks:)
      @collector.start
    end

    def self.stop
      result = @collector.stop
      @collector = nil
      output_path = options[:output]
      output_path ||= Tempfile.create(["profile", ".vernier.json.gz"]).path
      result.write(out: output_path)

      STDERR.puts(result.inspect)
      STDERR.puts("written to #{output_path}")
    end

    def self.running?
      !!@collector
    end

    def self.at_exit
      stop if running?
    end

    def self.toggle
      running? ? stop : start
    end
  end
end

unless Vernier::Autorun.options[:start_paused]
  Vernier::Autorun.start
end

if signal = Vernier::Autorun.options[:signal]
  STDERR.puts "to toggle profiler: kill -#{signal} #{Process.pid}"
  trap(signal) do
    Thread.new { Vernier::Autorun.toggle }
  end
end

at_exit do
  Vernier::Autorun.at_exit
end
