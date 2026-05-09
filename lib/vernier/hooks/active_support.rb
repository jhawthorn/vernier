# frozen_string_literal: true

module Vernier
  module Hooks
    class ActiveSupport
      FIREFOX_MARKER_SCHEMA = Ractor.make_shareable([
        # ActiveRecord

        {
          name: "sql.active_record",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.name}',
          chartLabel:   '{marker.data.name}',
          tableLabel:   '{marker.data.sql}',
          data: [
            { key: "sql", format: "string", searchable: true },
            { key: "name", format: "string", searchable: true },
            { key: "type_casted_binds", label: "binds", format: "string" },
            { key: "connection", format: "string", searchable: true },
            { key: "async", format: "string", searchable: true }
          ]
        },
        {
          name: "instantiation.active_record",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.record_count} × {marker.data.class_name}',
          chartLabel:   '{marker.data.record_count} × {marker.data.class_name}',
          tableLabel:   'Instantiate {marker.data.record_count} × {marker.data.class_name}',
          data: [
            { key: "record_count", format: "integer" },
            { key: "class_name", format: "string", searchable: true }
          ]
        },
        {
          name: "start_transaction.active_record",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: 'Start transaction',
          chartLabel:   'Start transaction',
          tableLabel:   'Start transaction {marker.data.transaction}',
          data: [
            { key: "transaction", format: "string", searchable: true },
            { key: "connection", format: "string", searchable: true }
          ]
        },
        {
          name: "transaction.active_record",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: 'Finish transaction ({marker.data.outcome})',
          chartLabel:   'Finish transaction ({marker.data.outcome})',
          tableLabel:   'Finish transaction ({marker.data.outcome}) {marker.data.transaction}',
          data: [
            { key: "outcome", format: "string" },
            { key: "transaction", format: "string", searchable: true },
            { key: "connection", format: "string", searchable: true }
          ]
        },

        # ActionController

        {
          name: "start_processing.action_controller",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.method}',
          chartLabel:   '{marker.data.method}',
          tableLabel:   '{marker.data.method} {marker.data.controller}#{marker.data.action}',
          data: [
            { key: "controller", format: "string", searchable: true },
            { key: "action", format: "string", searchable: true },
            { key: "path", format: "string", searchable: true },
            { key: "method", format: "string", searchable: true },
            { key: "format", format: "string" }
          ]
        },
        {
          name: "process_action.action_controller",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.method}',
          chartLabel:   '{marker.data.method}',
          tableLabel:   '{marker.data.method} {marker.data.controller}#{marker.data.action}',
          data: [
            { key: "controller", format: "string", searchable: true },
            { key: "action", format: "string", searchable: true },
            { key: "path", format: "string", searchable: true },
            { key: "method", format: "string", searchable: true },
            { key: "status", format: "integer" },
            { key: "format", format: "string" },
            { key: "view_runtime", format: "milliseconds" },
            { key: "db_runtime", format: "milliseconds" }
          ]
        },
        {
          name: "send_data.action_controller",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: 'Send data',
          chartLabel:   'Send data',
          tableLabel:   'Send data {marker.data.location}',
          data: [
            { key: "status", format: "integer" },
            { key: "location", format: "string", searchable: true }
          ]
        },
        {
          name: "send_stream.action_controller",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: 'Send stream ({marker.data.disposition})',
          chartLabel:   'Send stream ({marker.data.disposition})',
          tableLabel:   'Send stream ({marker.data.disposition}) {marker.data.filename}',
          data: [
            { key: "filename", format: "string", searchable: true },
            { key: "type", format: "string" },
            { key: "disposition", format: "string", searchable: true }
          ]
        },
        {
          name: "send_file.action_controller",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: 'Send file',
          chartLabel:   'Send file',
          tableLabel:   'Send file {marker.data.path}',
          data: [
            { key: "path", format: "string", searchable: true }
          ]
        },
        {
          name: "read_fragment.action_controller",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Read fragment {marker.data.key}',
          data: [
            { key: "key", format: "string", searchable: true }
          ]
        },
        {
          name: "write_fragment.action_controller",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Write fragment {marker.data.key}',
          data: [
            { key: "key", format: "string", searchable: true }
          ]
        },
        {
          name: "exist_fragment?.action_controller",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Exist fragment {marker.data.key}',
          data: [
            { key: "key", format: "string", searchable: true }
          ]
        },
        {
          name: "expire_fragment.action_controller",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Expire fragment {marker.data.key}',
          data: [
            { key: "key", format: "string", searchable: true }
          ]
        },

        # ActionDispatch

        {
          name: "process_middleware.action_dispatch",
        },
        {
          name: "request.action_dispatch",
        },

        # ActiveSupport

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
          name: "cache_write.active_support",
        },
        {
          name: "cache_write_multi.active_support",
        },
        {
          name: "cache_increment.active_support",
        },
        {
          name: "cache_decrement.active_support",
        },
        {
          name: "cache_exist?.active_support",
        },
        {
          name: "cache_generate.active_support",
        },
        {
          name: "cache_delete.active_support",
        },
        {
          name: "cache_delete_multi.active_support",
        },
        {
          name: "cache_delete_matched.active_support",
        },
        {
          name: "cache_delete_matched.active_support",
        },
        {
          name: "cache_cleanup.active_support",
        },
        {
          name: "cache_prune.active_support",
        },

        # ActionView

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

        # ActionCable

        {
          name: "perform_action.action_cable",
        },
        {
          name: "transmit.action_cable",
        },
        {
          name: "transmit_subscription_confirmation.action_cable",
        },
        {
          name: "transmit_subscription_rejection.action_cable",
        },
        {
          name: "broadcast.action_cable",
        },

        # ActionMailer

        {
          name: "process.action_mailer",
        },
        {
          name: "deliver.action_mailer",
        },
        {
          name: "read_fragment.action_mailer",
        },
        {
          name: "write_fragment.action_mailer",
        },
        {
          name: "exist_fragment?.action_mailer",
        },
        {
          name: "expire_fragment.action_mailer",
        },

        # ActionMailbox

        {
          name: "process.action_mailbox",
        },

        # ActiveJob

        {
          name: "enqueue.active_job",
        },
        {
          name: "enqueue_at.active_job",
        },
        {
          name: "enqueue_all.active_job",
        },
        {
          name: "perform.active_job",
        },
        {
          name: "perform_start.active_job",
        },
        {
          name: "enqueue_retry.active_job",
        },
        {
          name: "retry_stopped.active_job",
        },
        {
          name: "discard.active_job",
        },

        # ActiveStorage

        {
          name: "analyze.active_storage",
        },
        {
          name: "preview.active_storage",
        },
        {
          name: "mirror.active_storage",
        },
        {
          name: "transform.active_storage",
        },
        {
          name: "service_url.active_storage",
        },
        {
          name: "service_upload.active_storage",
        },
        {
          name: "service_download.active_storage",
        },
        {
          name: "service_download_chunk.active_storage",
        },
        {
          name: "service_streaming_download.active_storage",
        },
        {
          name: "service_update_metadata.active_storage",
        },
        {
          name: "service_delete.active_storage",
        },
        {
          name: "service_delete_prefixed.active_storage",
        },
        {
          name: "service_exist.active_storage",
        },

        # Railties

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
