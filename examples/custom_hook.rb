#!/usr/bin/env ruby

require "vernier"

class CustomHook
  def initialize(collector)
    @collector = collector
    @events = []
  end

  def enable
    # Simulate subscribing to application events
    @thread = Thread.new do
      3.times do |i|
        sleep 0.03
        start_time = @collector.current_time
        sleep 0.01 # Simulate work
        @collector.add_marker(
          name: "custom_event",
          start: start_time,
          finish: @collector.current_time,
          data: { type: "custom_event", event_id: i + 1 }
        )
      end
    end
  end

  def disable
    @thread&.join
  end
end

result = Vernier.profile(hooks: [CustomHook]) do
  sleep 0.15
end

puts "Profile complete with custom events"
