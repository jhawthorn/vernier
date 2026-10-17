# frozen_string_literal: true

module Vernier
  module Hooks
    autoload :ActiveSupport, "vernier/hooks/active_support"
    autoload :MemoryUsage, "vernier/hooks/memory_usage"
    autoload :Bundler, "vernier/hooks/bundler"
  end
end
