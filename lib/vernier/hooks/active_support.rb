# frozen_string_literal: true

module Vernier
  module Hooks
    class ActiveSupport
      FIREFOX_MARKER_SCHEMA = Ractor.make_shareable([
        {
          name: "sql.active_record",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: "{marker.data.name}",
          chartLabel: "{marker.data.name}",
          tableLabel: "{marker.data.sql}",
          data: [
            { key: "sql", format: "string", searchable: true },
            { key: "name", format: "string", searchable: true },
            { key: "type_casted_binds", label: "binds", format: "string"
            }
          ]
        },
        {
          name: "instantiation.active_record",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: "{marker.data.record_count} × {marker.data.class_name}",
          chartLabel: "{marker.data.record_count} × {marker.data.class_name}",
          tableLabel: "Instantiate {marker.data.record_count} × {marker.data.class_name}",
          data: [
            { key: "record_count", format: "integer" },
            { key: "class_name", format: "string" }
          ]
        },
        {
          name: "start_processing.action_controller",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.method} {marker.data.controller}#{marker.data.action}',
          chartLabel:   '{marker.data.method} {marker.data.controller}#{marker.data.action}',
          tableLabel:   '{marker.data.method} {marker.data.controller}#{marker.data.action}',
          data: [
            { key: "controller", format: "string" },
            { key: "action", format: "string" },
            { key: "status", format: "integer" },
            { key: "path", format: "string" },
            { key: "method", format: "string" },
            { key: "format", format: "string" }
          ]
        },
        {
          name: "process_action.action_controller",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.method} {marker.data.controller}#{marker.data.action}',
          chartLabel:   '{marker.data.method} {marker.data.controller}#{marker.data.action}',
          tableLabel:   '{marker.data.method} {marker.data.controller}#{marker.data.action}',
          data: [
            { key: "controller", format: "string" },
            { key: "action", format: "string" },
            { key: "status", format: "integer" },
            { key: "path", format: "string" },
            { key: "method", format: "string" },
            { key: "format", format: "string" }
          ]
        },
        {
          name: "cache_read.active_support",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.super_operation} {marker.data.key}',
          chartLabel:   '{marker.data.super_operation} {marker.data.key}',
          tableLabel:   '{marker.data.super_operation} {marker.data.key}',
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
          tooltipLabel: 'HIT {marker.data.key}',
          chartLabel:   'HIT {marker.data.key}',
          tableLabel:   'HIT {marker.data.key}',
          display: [ "marker-chart", "marker-table" ],
          data: [
            { key: "key", format: "string" },
            { key: "store", format: "string" }
          ]
        },
        {
          name: "render_template.action_view",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.identifier}',
          chartLabel:   '{marker.data.identifier}',
          tableLabel:   '{marker.data.identifier}',
          data: [
            { key: "identifier", format: "string" }
          ]
        },
        {
          name: "render_layout.action_view",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.identifier}',
          chartLabel:   '{marker.data.identifier}',
          tableLabel:   '{marker.data.identifier}',
          data: [
            { key: "identifier", format: "string" }
          ]
        },
        {
          name: "render_partial.action_view",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.identifier}',
          chartLabel:   '{marker.data.identifier}',
          tableLabel:   '{marker.data.identifier}',
          data: [
            { key: "identifier", format: "string" }
          ]
        },
        {
          name: "render_collection.action_view",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.identifier}',
          chartLabel:   '{marker.data.identifier}',
          tableLabel:   '{marker.data.identifier}',
          data: [
            { key: "identifier", format: "string" },
            { key: "count", format: "integer" }
          ]
        },
        {
          name: "load_config_initializer.railties",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.initializer}',
          chartLabel:   '{marker.data.initializer}',
          tableLabel:   '{marker.data.initializer}',
          data: [
            { key: "initializer", format: "string" }
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
