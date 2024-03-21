# frozen_string_literal: true

require "test_helper"
require "active_support"

class TestActiveSupport < Minitest::Test
  def test_subscribers_removed
    refute ActiveSupport::Notifications.notifier.listening?("sql.active_record")

    Vernier.trace(hooks: [:activesupport]) do
      assert ActiveSupport::Notifications.notifier.listening?("sql.active_record")
    end

    refute ActiveSupport::Notifications.notifier.listening?("sql.active_record")
  end

  def test_instrument
    result = Vernier.trace(hooks: [:activesupport]) do
      ActiveSupport::Notifications.instrument("foo.bar") {}
    end

    markers = result.markers.select{|x| x[1] == "foo.bar" }
    assert_equal 1, markers.size

    marker = markers[0]
    assert_equal Thread.current.object_id, marker[0]
    assert_equal Vernier::Marker::Phase::INTERVAL, marker[4]
    assert_equal({ type: "foo.bar" }, marker[5])
  end

  def test_instrument_without_block
    result = Vernier.trace(hooks: [:activesupport]) do
      ActiveSupport::Notifications.instrument("foo.bar")
    end

    markers = result.markers.select{|x| x[1] == "foo.bar" }
    assert_equal 1, markers.size

    marker = markers[0]
    assert_equal Thread.current.object_id, marker[0]
    assert_equal Vernier::Marker::Phase::INTERVAL, marker[4]
    assert_equal({ type: "foo.bar" }, marker[5])
  end

  def test_instrument_publish
    result = Vernier.trace(hooks: [:activesupport]) do
      ActiveSupport::Notifications.publish("foo.bar")
    end

    markers = result.markers.select{|x| x[1] == "foo.bar" }
    assert_equal 0, markers.size
  end

end
