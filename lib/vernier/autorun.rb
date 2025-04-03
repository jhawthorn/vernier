require "tempfile"
require "vernier"
require "base64"
require "json"

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
      allocation_interval = options.fetch(:allocation_interval, 0).to_i
      hooks = options.fetch(:hooks, "").split(",")
      metadata = if options[:metadata]
        JSON.parse(Base64.decode64(@options[:metadata])).to_h { |k, v| [k.to_sym, v] }
      else
        {}
      end

      STDERR.puts("starting profiler with interval #{interval} and allocation interval #{allocation_interval}")

      @collector = Vernier::Collector.new(:wall, interval:, allocation_interval:, hooks:, metadata:)
      @collector.start
    end

    def self.stop
      result = @collector.stop
      @collector = nil

      output_path = options[:output]
      unless output_path
        output_dir = options[:output_dir]
        unless output_dir
          if File.writable?(".")
            output_dir = "."
          else
            output_dir = Dir.tmpdir
          end
        end
        prefix = "profile-"
        timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
        suffix = ".vernier.json.gz"

        output_path = File.expand_path("#{output_dir}/#{prefix}#{timestamp}-#{$$}#{suffix}")
      end

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
