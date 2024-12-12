# frozen_string_literal: true

module Vernier
  if ::Process.respond_to?(:_fork)
    module ForkHooks
      def _fork
        pid = super
        if pid == 0 # We're in the child
          ObjectSpace.each_object(Vernier::Collector) do |collector|
             Vernier.cancel_profile
          end
        end
        pid
      end
    end

    ::Process.singleton_class.prepend(ForkHooks)
  end
end
