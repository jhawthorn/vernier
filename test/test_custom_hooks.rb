# frozen_string_literal: true

require "test_helper"

class TestCustomHooks < Minitest::Test
  include FirefoxTestHelpers

  class SimpleHook
    def initialize(collector)
      @collector = collector
    end

    def enable
      @start_time = @collector.current_time
    end

    def disable
      @collector.add_marker(
        name: "Simple Hook",
        start: @start_time,
        finish: @collector.current_time,
        data: { type: "simple_hook" }
      )
    end
  end

  class HookWithSchema
    def initialize(collector)
      @collector = collector
    end

    def enable
      @collector.add_marker(
        name: "custom_event",
        start: @collector.current_time,
        finish: @collector.current_time + 1000,
        data: { type: "custom_event", event_name: "test" }
      )
    end

    def disable
    end

    def firefox_marker_schema
      [{
        name: "custom_event",
        display: ["marker-chart", "marker-table"],
        data: [{ key: "event_name", format: "string" }]
      }]
    end
  end

  class HookWithCounters
    def initialize(collector)
      @collector = collector
    end

    def enable
    end

    def disable
    end

    def firefox_counters
      {
        name: "test_counter",
        category: "Test",
        description: "Test counter",
        samples: {
          time: [0, 1000],
          count: [10, 20],
          length: 2
        }
      }
    end
  end

  def test_custom_hook_class
    result = Vernier.profile(hooks: [SimpleHook]) do
      sleep 0.01
    end

    output = Vernier::Output::Firefox.new(result).output
    assert_valid_firefox_profile(output)
  end

  def test_custom_hook_with_schema
    result = Vernier.profile(hooks: [HookWithSchema]) do
      sleep 0.01
    end

    output = Vernier::Output::Firefox.new(result).output
    assert_valid_firefox_profile(output)

    data = JSON.parse(output)
    schemas = data.dig("meta", "markerSchema") || []
    assert schemas.any? { |s| s["name"] == "custom_event" }
  end

  def test_mixed_hooks
    result = Vernier.profile(hooks: [:memory_usage, SimpleHook]) do
      sleep 0.01
    end

    output = Vernier::Output::Firefox.new(result).output
    assert_valid_firefox_profile(output)
    assert_equal 2, result.hooks.size
  end

  def test_custom_hook_with_counters
    result = Vernier.profile(hooks: [HookWithCounters]) do
      sleep 0.01
    end

    output = Vernier::Output::Firefox.new(result).output
    assert_valid_firefox_profile(output)

    data = JSON.parse(output)
    counters = data["counters"]
    assert counters.any? { |c| c["name"] == "test_counter" }
  end
end
