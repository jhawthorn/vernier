# frozen_string_literal: true

module Vernier
  module Hooks
    class ActiveSupport
      def initialize(collector)
        @collector = collector
      end

      def enable
        require "active_support"
        @subscription = ::ActiveSupport::Notifications.monotonic_subscribe do |name, start, finish, id, payload|
          data = { type: name }
          data.update(payload)
          @collector.add_marker(
            name: name,
            start: (start * 1_000_000_000.0).to_i,
            finish: (finish * 1_000_000_000.0).to_i,
            data: data
          )
        end
      end

      def disable
        ActiveSupport::Notifications.unsubscribe(@subscription)
        @subscription = nil
      end

      FIREFOX_MARKER_SCHEMA = Ractor.make_shareable([
        {
          name: "sql.active_record",
          display: [ "marker-chart", "marker-table" ],
          data: [
            {
              key: "sql",
              format: "string"
            },
            {
              key: "name",
              format: "string"
            },
            {
              key: "type_casted_binds",
              label: "binds",
              format: "string"
            }
          ]
        },
        {
          name: "instantiation.active_record",
          display: [ "marker-chart", "marker-table" ],
          data: [
            {
              key: "record_count",
              format: "integer"
            },
            {
              key: "class_name",
              format: "string"
            }
          ]
        },
        {
          name: "process_action.action_controller",
          display: [ "marker-chart", "marker-table" ],
          data: [
            {
              key: "controller",
              format: "string"
            },
            {
              key: "action",
              format: "string"
            },
            {
              key: "status",
              format: "integer"
            },
            {
              key: "path",
              format: "string"
            },
            {
              key: "method",
              format: "string"
            }
          ]
        }
      ])

      def firefox_marker_schema
        FIREFOX_MARKER_SCHEMA
      end
    end
  end
end
