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

    markers = result.main_thread[:markers].select{|x| x[1] == "foo.bar" }
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

    markers = result.main_thread[:markers].select{|x| x[1] == "foo.bar" }
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

    markers = result.main_thread[:markers].select{|x| x[1] == "foo.bar" }
    assert_equal 0, markers.size
  end

  def test_firefox_marker_schema
    schema = Vernier::Hooks::ActiveSupport::FIREFOX_MARKER_SCHEMA

    names = schema.map { _1[:name] }
    assert_equal names.uniq, names

    schema.each do |marker|
      keys = marker[:fields].map { _1[:key] }
      refute_includes keys, "type", "#{marker[:name]} would overwrite the marker type"

      marker.values_at(:tooltipLabel, :chartLabel, :tableLabel).compact.each do |label|
        label.scan(/\{marker\.data\.(\w+)\}/).flatten.each do |key|
          assert_includes keys, key, "#{marker[:name]} label references #{key}"
        end
      end
    end
  end

  def test_firefox_marker_schema_marks_sensitive_fields
    schema = Vernier::Hooks::ActiveSupport::FIREFOX_MARKER_SCHEMA

    sensitive = schema.flat_map do |marker|
      marker[:fields].select { _1[:format] == "sanitized-string" }.map { [marker[:name], _1[:key]] }
    end

    assert_includes sensitive, ["sql.active_record", "sql"]
    assert_includes sensitive, ["sql.active_record", "type_casted_binds"]
    assert_includes sensitive, ["cache_read.active_support", "key"]
    assert_includes sensitive, ["cache_write.active_support", "key"]
    assert_includes sensitive, ["read_fragment.action_controller", "key"]
  end
end
