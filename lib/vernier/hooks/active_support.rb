# frozen_string_literal: true

module Vernier
  module Hooks
    class ActiveSupport
      FIREFOX_MARKER_SCHEMA = Ractor.make_shareable([
        {
          name: "sql.active_record",
          display: [ "marker-chart", "marker-table" ],
          data: [
            { key: "sql", format: "string" },
            { key: "name", format: "string" },
            { key: "type_casted_binds", label: "binds", format: "string"
            }
          ]
        },
        {
          name: "instantiation.active_record",
          display: [ "marker-chart", "marker-table" ],
          data: [
            { key: "record_count", format: "integer" },
            { key: "class_name", format: "string" }
          ]
        },
        {
          name: "process_action.action_controller",
          display: [ "marker-chart", "marker-table" ],
          data: [
            { key: "controller", format: "string" },
            { key: "action", format: "string" },
            { key: "status", format: "integer" },
            { key: "path", format: "string" },
            { key: "method", format: "string" }
          ]
        },
        {
          name: "cache_read.active_support",
          display: [ "marker-chart", "marker-table" ],
          data: [
            { key: "key", format: "string" },
            { key: "store", format: "string" },
            { key: "hit", format: "string" },
            { key: "super_operation", format: "string" }
          ]
        },
        {
          name: "cache_read_multi.active_support",
          display: [ "marker-chart", "marker-table" ],
          data: [
            { key: "key", format: "string" },
            { key: "store", format: "string" },
            { key: "hit", format: "string" },
            { key: "super_operation", format: "string" }
          ]
        },
        {
          name: "cache_fetch_hit.active_support",
          display: [ "marker-chart", "marker-table" ],
          data: [
            { key: "key", format: "string" },
            { key: "store", format: "string" }
          ]
        }
      ])

      SERIALIZED_KEYS = FIREFOX_MARKER_SCHEMA.map do |format|
        [
          format[:name],
          format[:data].map { _1[:key].to_sym }.freeze
        ]
      end.to_h.freeze

      def initialize(collector)
        @collector = collector
      end

      def enable
        require "active_support"
        @subscription = ::ActiveSupport::Notifications.monotonic_subscribe(/\A[^!]/) do |name, start, finish, id, payload|
          # Notifications.publish API may reach here without proper timing information included
          unless Float === start && Float === finish
            next
          end

          data = { type: name }
          if keys = SERIALIZED_KEYS[name]
            keys.each do |key|
              data[key] = payload[key]
            end
          end
          @collector.add_marker(
            name: name,
            start: (start * 1_000_000_000.0).to_i,
            finish: (finish * 1_000_000_000.0).to_i,
            data: data
          )
        end
      end

      def disable
        ::ActiveSupport::Notifications.unsubscribe(@subscription)
        @subscription = nil
      end

      def firefox_marker_schema
        FIREFOX_MARKER_SCHEMA
      end
    end
  end
end
