# frozen_string_literal: true

module Vernier
  module Hooks
    class ActiveSupport
      FIREFOX_MARKER_SCHEMA = Ractor.make_shareable([
        # Active Record

        {
          name: "sql.active_record",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.name}',
          chartLabel:   '{marker.data.name}',
          tableLabel:   '{marker.data.sql}',
          data: [
            { key: "sql", format: "sanitized-string" },
            { key: "name", format: "string" },
            { key: "type_casted_binds", label: "binds", format: "sanitized-string" },
            { key: "connection", format: "string" },
            { key: "async", format: "string" }
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
            { key: "class_name", format: "string" }
          ]
        },
        {
          name: "start_transaction.active_record",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: 'Start transaction',
          chartLabel:   'Start transaction',
          tableLabel:   'Start transaction {marker.data.transaction}',
          data: [
            { key: "transaction", format: "string" },
            { key: "connection", format: "string" }
          ]
        },
        {
          name: "transaction.active_record",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.outcome}',
          chartLabel:   '{marker.data.outcome}',
          tableLabel:   'Transaction {marker.data.outcome} {marker.data.transaction}',
          data: [
            { key: "outcome", format: "string" },
            { key: "transaction", format: "string" },
            { key: "connection", format: "string" }
          ]
        },

        # Action Controller

        {
          name: "start_processing.action_controller",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.method} {marker.data.controller}#{marker.data.action}',
          chartLabel:   '{marker.data.method} {marker.data.controller}#{marker.data.action}',
          tableLabel:   'Start processing {marker.data.method} {marker.data.controller}#{marker.data.action}',
          data: [
            { key: "controller", format: "string" },
            { key: "action", format: "string" },
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
          tableLabel:   'Process action {marker.data.method} {marker.data.controller}#{marker.data.action}',
          data: [
            { key: "controller", format: "string" },
            { key: "action", format: "string" },
            { key: "path", format: "string" },
            { key: "method", format: "string" },
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
          tableLabel:   'Send data {marker.data.filename}',
          data: [
            { key: "filename", format: "string" },
            { key: "disposition", format: "string" },
            { key: "status", format: "integer" }
          ]
        },
        {
          name: "send_stream.action_controller",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.filename}',
          chartLabel:   '{marker.data.filename}',
          tableLabel:   'Send stream {marker.data.filename}',
          data: [
            { key: "filename", format: "string" },
            { key: "disposition", format: "string" }
          ]
        },
        {
          name: "send_file.action_controller",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.path}',
          chartLabel:   '{marker.data.path}',
          tableLabel:   'Send file {marker.data.path}',
          data: [
            { key: "path", format: "string" }
          ]
        },
        {
          name: "read_fragment.action_controller",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Read fragment {marker.data.key}',
          data: [
            { key: "key", format: "sanitized-string" }
          ]
        },
        {
          name: "write_fragment.action_controller",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Write fragment {marker.data.key}',
          data: [
            { key: "key", format: "sanitized-string" }
          ]
        },
        {
          name: "exist_fragment?.action_controller",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Exist fragment {marker.data.key}',
          data: [
            { key: "key", format: "sanitized-string" }
          ]
        },
        {
          name: "expire_fragment.action_controller",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Expire fragment {marker.data.key}',
          data: [
            { key: "key", format: "sanitized-string" }
          ]
        },

        # Action Dispatch

        {
          name: "process_middleware.action_dispatch",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.middleware}',
          chartLabel:   '{marker.data.middleware}',
          tableLabel:   'Process middleware {marker.data.middleware}',
          data: [
            { key: "middleware", format: "string" }
          ]
        },
        {
          name: "request.action_dispatch",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: 'Request',
          chartLabel:   'Request',
          tableLabel:   'Request',
          data: []
        },

        # Active Support

        {
          name: "cache_read.active_support",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Cache read {marker.data.key}',
          data: [
            { key: "key", format: "sanitized-string" },
            { key: "store", format: "string" },
            { key: "hit", format: "string" },
            { key: "super_operation", format: "string" }
          ]
        },
        {
          name: "cache_read_multi.active_support",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Cache read multi {marker.data.key}',
          data: [
            { key: "key", format: "sanitized-string" },
            { key: "store", format: "string" },
            { key: "hits", format: "string" },
            { key: "super_operation", format: "string" }
          ]
        },
        {
          name: "cache_fetch_hit.active_support",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Cache fetch hit {marker.data.key}',
          data: [
            { key: "key", format: "sanitized-string" },
            { key: "store", format: "string" }
          ]
        },
        {
          name: "cache_write.active_support",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Cache write {marker.data.key}',
          data: [
            { key: "key", format: "sanitized-string" },
            { key: "store", format: "string" }
          ]
        },
        {
          name: "cache_write_multi.active_support",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.store}',
          chartLabel:   '{marker.data.store}',
          tableLabel:   'Cache write multi {marker.data.store}',
          # The payload's key also holds the written values, so it isn't recorded
          data: [
            { key: "store", format: "string" }
          ]
        },
        {
          name: "cache_increment.active_support",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Cache increment {marker.data.key}',
          data: [
            { key: "key", format: "sanitized-string" },
            { key: "store", format: "string" },
            { key: "amount", format: "integer" }
          ]
        },
        {
          name: "cache_decrement.active_support",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Cache decrement {marker.data.key}',
          data: [
            { key: "key", format: "sanitized-string" },
            { key: "store", format: "string" },
            { key: "amount", format: "integer" }
          ]
        },
        {
          name: "cache_delete.active_support",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Cache delete {marker.data.key}',
          data: [
            { key: "key", format: "sanitized-string" },
            { key: "store", format: "string" }
          ]
        },
        {
          name: "cache_delete_multi.active_support",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Cache delete multi {marker.data.key}',
          data: [
            { key: "key", format: "sanitized-string" },
            { key: "store", format: "string" }
          ]
        },
        {
          name: "cache_delete_matched.active_support",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Cache delete matched {marker.data.key}',
          data: [
            { key: "key", label: "pattern", format: "sanitized-string" },
            { key: "store", format: "string" }
          ]
        },
        {
          name: "cache_exist?.active_support",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Cache exist {marker.data.key}',
          data: [
            { key: "key", format: "sanitized-string" },
            { key: "store", format: "string" }
          ]
        },
        {
          name: "cache_generate.active_support",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Cache generate {marker.data.key}',
          data: [
            { key: "key", format: "sanitized-string" },
            { key: "store", format: "string" }
          ]
        },
        {
          name: "cache_cleanup.active_support",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.store}',
          chartLabel:   '{marker.data.store}',
          tableLabel:   'Cache cleanup {marker.data.store}',
          data: [
            { key: "store", format: "string" },
            { key: "size", format: "integer" }
          ]
        },
        {
          name: "cache_prune.active_support",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.store}',
          chartLabel:   '{marker.data.store}',
          tableLabel:   'Cache prune {marker.data.store}',
          data: [
            { key: "store", format: "string" },
            { key: "key", label: "target size", format: "bytes" },
            { key: "from", format: "bytes" }
          ]
        },

        # Action View

        {
          name: "render_template.action_view",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.identifier}',
          chartLabel:   '{marker.data.identifier}',
          tableLabel:   'Render template {marker.data.identifier}',
          data: [
            { key: "identifier", format: "string" },
            { key: "layout", format: "string" }
          ]
        },
        {
          name: "render_layout.action_view",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.identifier}',
          chartLabel:   '{marker.data.identifier}',
          tableLabel:   'Render layout {marker.data.identifier}',
          data: [
            { key: "identifier", format: "string" }
          ]
        },
        {
          name: "render_partial.action_view",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.identifier}',
          chartLabel:   '{marker.data.identifier}',
          tableLabel:   'Render partial {marker.data.identifier}',
          data: [
            { key: "identifier", format: "string" }
          ]
        },
        {
          name: "render_collection.action_view",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.identifier}',
          chartLabel:   '{marker.data.identifier}',
          tableLabel:   'Render collection {marker.data.identifier}',
          data: [
            { key: "identifier", format: "string" },
            { key: "count", format: "integer" },
            { key: "cache_hits", format: "integer" }
          ]
        },

        # Action Cable

        {
          name: "perform_action.action_cable",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.channel_class}#{marker.data.action}',
          chartLabel:   '{marker.data.channel_class}#{marker.data.action}',
          tableLabel:   'Perform action {marker.data.channel_class}#{marker.data.action}',
          data: [
            { key: "channel_class", format: "string" },
            { key: "action", format: "string" }
          ]
        },
        {
          name: "transmit.action_cable",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.channel_class}',
          chartLabel:   '{marker.data.channel_class}',
          tableLabel:   'Transmit {marker.data.channel_class} {marker.data.via}',
          data: [
            { key: "channel_class", format: "string" },
            { key: "via", format: "string" }
          ]
        },
        {
          name: "transmit_subscription_confirmation.action_cable",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.channel_class}',
          chartLabel:   '{marker.data.channel_class}',
          tableLabel:   'Transmit subscription confirmation {marker.data.channel_class}',
          data: [
            { key: "channel_class", format: "string" }
          ]
        },
        {
          name: "transmit_subscription_rejection.action_cable",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.channel_class}',
          chartLabel:   '{marker.data.channel_class}',
          tableLabel:   'Transmit subscription rejection {marker.data.channel_class}',
          data: [
            { key: "channel_class", format: "string" }
          ]
        },
        {
          name: "broadcast.action_cable",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.broadcasting}',
          chartLabel:   '{marker.data.broadcasting}',
          tableLabel:   'Broadcast {marker.data.broadcasting}',
          data: [
            { key: "broadcasting", format: "string" }
          ]
        },

        # Action Mailer

        {
          name: "process.action_mailer",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.mailer}#{marker.data.action}',
          chartLabel:   '{marker.data.mailer}#{marker.data.action}',
          tableLabel:   'Process {marker.data.mailer}#{marker.data.action}',
          data: [
            { key: "mailer", format: "string" },
            { key: "action", format: "string" }
          ]
        },
        {
          name: "deliver.action_mailer",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.mailer}',
          chartLabel:   '{marker.data.mailer}',
          tableLabel:   'Deliver {marker.data.mailer} {marker.data.message_id}',
          data: [
            { key: "mailer", format: "string" },
            { key: "message_id", format: "string" },
            { key: "perform_deliveries", format: "string" }
          ]
        },
        {
          name: "read_fragment.action_mailer",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Read fragment {marker.data.key}',
          data: [
            { key: "key", format: "sanitized-string" }
          ]
        },
        {
          name: "write_fragment.action_mailer",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Write fragment {marker.data.key}',
          data: [
            { key: "key", format: "sanitized-string" }
          ]
        },
        {
          name: "exist_fragment?.action_mailer",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Exist fragment {marker.data.key}',
          data: [
            { key: "key", format: "sanitized-string" }
          ]
        },
        {
          name: "expire_fragment.action_mailer",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Expire fragment {marker.data.key}',
          data: [
            { key: "key", format: "sanitized-string" }
          ]
        },

        # Action Mailbox

        {
          name: "process.action_mailbox",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.mailbox}',
          chartLabel:   '{marker.data.mailbox}',
          tableLabel:   'Process {marker.data.mailbox}',
          data: [
            { key: "mailbox", format: "string" }
          ]
        },

        # Active Job

        {
          name: "enqueue.active_job",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.job}',
          chartLabel:   '{marker.data.job}',
          tableLabel:   'Enqueue {marker.data.job}',
          data: [
            { key: "job", format: "string" }
          ]
        },
        {
          name: "enqueue_at.active_job",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.job}',
          chartLabel:   '{marker.data.job}',
          tableLabel:   'Enqueue at {marker.data.job}',
          data: [
            { key: "job", format: "string" }
          ]
        },
        {
          name: "enqueue_all.active_job",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: 'Enqueue all',
          chartLabel:   'Enqueue all',
          tableLabel:   'Enqueue all',
          data: []
        },
        {
          name: "perform.active_job",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.job}',
          chartLabel:   '{marker.data.job}',
          tableLabel:   'Perform {marker.data.job}',
          data: [
            { key: "job", format: "string" },
            { key: "db_runtime", format: "milliseconds" }
          ]
        },
        {
          name: "perform_start.active_job",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.job}',
          chartLabel:   '{marker.data.job}',
          tableLabel:   'Perform start {marker.data.job}',
          data: [
            { key: "job", format: "string" }
          ]
        },
        {
          name: "enqueue_retry.active_job",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.job}',
          chartLabel:   '{marker.data.job}',
          tableLabel:   'Enqueue retry {marker.data.job}',
          data: [
            { key: "job", format: "string" },
            { key: "error", format: "string" },
            { key: "wait", format: "string" }
          ]
        },
        {
          name: "retry_stopped.active_job",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.job}',
          chartLabel:   '{marker.data.job}',
          tableLabel:   'Retry stopped {marker.data.job}',
          data: [
            { key: "job", format: "string" },
            { key: "error", format: "string" }
          ]
        },
        {
          name: "discard.active_job",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.job}',
          chartLabel:   '{marker.data.job}',
          tableLabel:   'Discard {marker.data.job}',
          data: [
            { key: "job", format: "string" },
            { key: "error", format: "string" }
          ]
        },
        {
          name: "interrupt.active_job",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.job}',
          chartLabel:   '{marker.data.job}',
          tableLabel:   'Interrupt {marker.data.job}',
          data: [
            { key: "job", format: "string" },
            { key: "reason", format: "string" },
            { key: "description", format: "string" }
          ]
        },
        {
          name: "resume.active_job",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.job}',
          chartLabel:   '{marker.data.job}',
          tableLabel:   'Resume {marker.data.job}',
          data: [
            { key: "job", format: "string" },
            { key: "description", format: "string" }
          ]
        },
        {
          name: "step.active_job",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.job}',
          chartLabel:   '{marker.data.job}',
          tableLabel:   'Step {marker.data.job}',
          data: [
            { key: "job", format: "string" },
            { key: "interrupted", format: "string" }
          ]
        },
        {
          name: "step_started.active_job",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.job}',
          chartLabel:   '{marker.data.job}',
          tableLabel:   'Step started {marker.data.job}',
          data: [
            { key: "job", format: "string" }
          ]
        },
        {
          name: "step_skipped.active_job",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.step}',
          chartLabel:   '{marker.data.step}',
          tableLabel:   'Step skipped {marker.data.step}',
          data: [
            { key: "step", format: "string" },
            { key: "job", format: "string" }
          ]
        },

        # Active Storage

        {
          name: "analyze.active_storage",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.analyzer}',
          chartLabel:   '{marker.data.analyzer}',
          tableLabel:   'Analyze {marker.data.analyzer}',
          data: [
            { key: "analyzer", format: "string" }
          ]
        },
        {
          name: "preview.active_storage",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Preview {marker.data.key}',
          data: [
            { key: "key", format: "string" },
            { key: "service", format: "string" }
          ]
        },
        {
          name: "transform.active_storage",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: 'Transform',
          chartLabel:   'Transform',
          tableLabel:   'Transform',
          data: []
        },
        {
          name: "service_url.active_storage",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Service URL {marker.data.key}',
          data: [
            { key: "key", format: "string" },
            { key: "service", format: "string" }
          ]
        },
        {
          name: "service_upload.active_storage",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Service upload {marker.data.key}',
          data: [
            { key: "key", format: "string" },
            { key: "service", format: "string" }
          ]
        },
        {
          name: "service_mirror.active_storage",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Service mirror {marker.data.key}',
          data: [
            { key: "key", format: "string" },
            { key: "service", format: "string" }
          ]
        },
        {
          name: "service_download.active_storage",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Service download {marker.data.key}',
          data: [
            { key: "key", format: "string" },
            { key: "service", format: "string" }
          ]
        },
        {
          name: "service_download_chunk.active_storage",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Service download chunk {marker.data.key}',
          data: [
            { key: "key", format: "string" },
            { key: "service", format: "string" },
            { key: "range", format: "string" }
          ]
        },
        {
          name: "service_streaming_download.active_storage",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Service streaming download {marker.data.key}',
          data: [
            { key: "key", format: "string" },
            { key: "service", format: "string" }
          ]
        },
        {
          name: "service_update_metadata.active_storage",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Service update metadata {marker.data.key}',
          data: [
            { key: "key", format: "string" },
            { key: "service", format: "string" },
            { key: "content_type", format: "string" }
          ]
        },
        {
          name: "service_delete.active_storage",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Service delete {marker.data.key}',
          data: [
            { key: "key", format: "string" },
            { key: "service", format: "string" }
          ]
        },
        {
          name: "service_delete_prefixed.active_storage",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.prefix}',
          chartLabel:   '{marker.data.prefix}',
          tableLabel:   'Service delete prefixed {marker.data.prefix}',
          data: [
            { key: "prefix", format: "string" },
            { key: "service", format: "string" }
          ]
        },
        {
          name: "service_exist.active_storage",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.key}',
          chartLabel:   '{marker.data.key}',
          tableLabel:   'Service exist {marker.data.key}',
          data: [
            { key: "key", format: "string" },
            { key: "service", format: "string" },
            { key: "exist", format: "string" }
          ]
        },

        # Railties

        {
          name: "load_config_initializer.railties",
          display: [ "marker-chart", "marker-table" ],
          tooltipLabel: '{marker.data.initializer}',
          chartLabel:   '{marker.data.initializer}',
          tableLabel:   'Load config initializer {marker.data.initializer}',
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
