require "json"

module Vernier
  module Output
    class Cpuprofile
      def initialize(profile)
        @profile = profile
      end

      def output
        JSON.generate(data)
      end

      private

      attr_reader :profile

      def ns_to_us(timestamp)
        (timestamp / 1_000.0).to_i
      end

      def data
        # Get the main thread data (cpuprofile format is single-threaded)
        main_thread = profile.main_thread
        return empty_profile if main_thread.nil?

        samples = main_thread[:samples]
        timestamps = main_thread[:timestamps] || []

        nodes = build_nodes
        sample_node_ids = samples.map { |stack_idx| stack_to_node_id(stack_idx) }
        time_deltas = calculate_time_deltas(timestamps)

        {
          nodes: nodes,
          startTime: ns_to_us(profile.started_at),
          endTime: ns_to_us(profile.end_time),
          samples: sample_node_ids,
          timeDeltas: time_deltas
        }
      end

      def empty_profile
        {
          nodes: [root_node],
          startTime: 0,
          endTime: 0,
          samples: [],
          timeDeltas: []
        }
      end

      def build_nodes
        stack_table = profile.stack_table

        nodes = []
        @node_id_map = {}

        root = root_node
        nodes << root
        @node_id_map[nil] = 0

        stack_table.stack_count.times do |stack_idx|
          create_node_for_stack(stack_idx, nodes, stack_table)
        end

        nodes
      end

      def root_node
        {
          id: 0,
          callFrame: {
            functionName: "(root)",
            scriptId: "0",
            url: "",
            lineNumber: -1,
            columnNumber: -1,
          },
          hitCount: 0,
          children: []
        }
      end

      def create_node_for_stack(stack_idx, nodes, stack_table)
        return @node_id_map[stack_idx] if @node_id_map.key?(stack_idx)

        frame_idx = stack_table.stack_frame_idx(stack_idx)
        parent_stack_idx = stack_table.stack_parent_idx(stack_idx)

        parent_node_id = if parent_stack_idx.nil?
          0 # root node
        else
          create_node_for_stack(parent_stack_idx, nodes, stack_table)
        end

        func_idx = stack_table.frame_func_idx(frame_idx)
        line = stack_table.frame_line_no(frame_idx) - 1

        func_name = stack_table.func_name(func_idx)
        filename = stack_table.func_filename(func_idx)

        node_id = nodes.length
        node = {
          id: node_id,
          callFrame: {
            functionName: func_name || "(anonymous)",
            scriptId: func_idx.to_s,
            url: filename || "",
            lineNumber: line || 0,
            columnNumber: 0
          },
          hitCount: 0,
          children: []
        }

        nodes << node
        @node_id_map[stack_idx] = node_id

        parent_node = nodes[parent_node_id]
        parent_node[:children] << node_id unless parent_node[:children].include?(node_id)

        node_id
      end

      def stack_to_node_id(stack_idx)
        @node_id_map[stack_idx] || 0
      end

      def calculate_time_deltas(timestamps)
        return [] if timestamps.empty?

        deltas = []

        timestamps.each_with_index do |timestamp, i|
          if i == 0
            deltas << 0
          else
            deltas << ns_to_us(timestamp - timestamps[i - 1])
          end
        end

        deltas
      end
    end
  end
end
