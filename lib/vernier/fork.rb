# frozen_string_literal: true

module Vernier
  if ::Process.respond_to?(:_fork)
    module ForkHooks
      def _fork
        running_collectors = ObjectSpace.each_object(Vernier::Collector).select(&:running?)
        running_collectors.each(&:pause)
        pid = super
        if pid == 0
          # We're in the child
        else
          # We're in the parent
          running_collectors.each do |collector|
            collector.resume
          end
        end
        pid
      end
    end

    ::Process.singleton_class.prepend(ForkHooks)
  end
end
