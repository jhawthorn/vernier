# frozen_string_literal: true

module Vernier
  module Hooks
    class Bundler
      def initialize(collector)
        @collector = collector
        @times = {}
        @tp = nil
      end

      def enable
        @tp = TracePoint.new(:call) do |x|
          event, spec = x.binding.eval("[event, args.first]")
          case event
          when "before-install"
            @times[spec.name] = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
          when "after-install"
            @collector.add_marker(name: spec.name,
              start: @times[spec.name],
              finish: Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond),
              data: { :type => 'UserTiming', :entryType => 'measure', :name => spec.name }
            )
            @collector.add_marker(name: spec.name,
              start: @times[spec.name],
              finish: Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond),
              thread: Thread.main.object_id,
              data: { :type => 'UserTiming', :entryType => 'measure', :name => spec.name }
            )
          end
        end
        require "bundler/errors"
        require "bundler/plugin"
        @tp.enable(target: ::Bundler::Plugin.method(:hook))
      end

      def disable
        @tp.disable
      end
    end
  end
end
