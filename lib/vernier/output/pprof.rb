# frozen_string_literal: true

require_relative "../output_helpers"

module Vernier
  module Output
    # Writes a profile in the pprof format consumed by `go tool pprof` and
    # many other tools:
    #
    #   https://github.com/google/pprof/blob/main/proto/profile.proto
    #
    # The protobuf wire format is written by the small encoder below so that
    # vernier doesn't need to depend on google-protobuf.
    #
    # Mapping from a Vernier::Result:
    #
    # * Each unique (thread, stack, sample category) becomes one pprof Sample,
    #   with labels for the thread name ("thread"), native thread id ("tid")
    #   and, in wall mode, the sample state ("state": running/idle/stalled).
    # * Each frame of the stack table becomes a Location and each function a
    #   Function.
    # * Sample types depend on the profiling mode:
    #     wall:     samples/count, wall/nanoseconds (sample weight × interval)
    #               and, when allocation sampling was enabled,
    #               allocations/count (sampled allocations × allocation interval)
    #     retained: objects/count, retained/bytes
    #     custom:   samples/count
    class Pprof
      include OutputHelpers

      # Minimal protocol buffers (proto3) wire format encoder.
      #
      # Only what profile.proto needs is implemented: varint scalars
      # (int64/uint64/bool), length-delimited strings and sub-messages, and
      # packed repeated varints. Scalar fields set to their default value
      # are omitted, as proto3 does.
      module Protobuf
        WIRE_VARINT = 0
        WIRE_LENGTH_DELIMITED = 2

        UINT64_MASK = (1 << 64) - 1

        module_function

        def new_buffer
          String.new(encoding: Encoding::BINARY)
        end

        # Appends +value+ (0 <= value < 2**64) as a base-128 varint.
        def varint(buf, value)
          while value > 0x7f
            buf << ((value & 0x7f) | 0x80)
            value >>= 7
          end
          buf << value
        end

        # int64 and uint64 both use the varint wire type. Negative int64
        # values are encoded as their 64-bit two's complement, which is 10
        # bytes long.
        def write_int(buf, field, value)
          return if value == 0

          varint(buf, (field << 3) | WIRE_VARINT)
          varint(buf, int_bits(value))
        end

        # Checks range and converts negative values to their two's complement
        def int_bits(value)
          unless value >= -(1 << 63) && value <= UINT64_MASK
            raise ArgumentError, "integer out of range for int64/uint64: #{value}"
          end

          value < 0 ? value & UINT64_MASK : value
        end

        def write_bool(buf, field, value)
          return unless value

          varint(buf, (field << 3) | WIRE_VARINT)
          buf << 1
        end

        # Strings (which must be valid UTF-8) and embedded messages share the
        # length-delimited wire type. Always written, even when empty, since
        # this is used for repeated fields and for messages whose presence
        # matters.
        def write_bytes(buf, field, bytes)
          varint(buf, (field << 3) | WIRE_LENGTH_DELIMITED)
          varint(buf, bytes.bytesize)
          buf << bytes
        end

        def write_string(buf, field, string)
          bytes = string.b
          unless bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding?
            raise ArgumentError, "string must be valid UTF-8: #{string.inspect}"
          end

          write_bytes(buf, field, bytes)
        end

        # Packed repeated int64/uint64. Empty lists are omitted.
        def write_packed_ints(buf, field, values)
          return if values.empty?

          packed = new_buffer
          values.each do |value|
            varint(packed, int_bits(value))
          end
          write_bytes(buf, field, packed)
        end
      end

      # Field numbers from profile.proto
      module Fields
        module Profile
          SAMPLE_TYPE = 1
          SAMPLE = 2
          MAPPING = 3
          LOCATION = 4
          FUNCTION = 5
          STRING_TABLE = 6
          TIME_NANOS = 9
          DURATION_NANOS = 10
          PERIOD_TYPE = 11
          PERIOD = 12
          COMMENT = 13
          DEFAULT_SAMPLE_TYPE = 14
        end

        module ValueType
          TYPE = 1
          UNIT = 2
        end

        module Sample
          LOCATION_ID = 1
          VALUE = 2
          LABEL = 3
        end

        module Label
          KEY = 1
          STR = 2
          NUM = 3
          NUM_UNIT = 4
        end

        module Mapping
          ID = 1
          MEMORY_START = 2
          MEMORY_LIMIT = 3
          FILE_OFFSET = 4
          FILENAME = 5
          BUILD_ID = 6
          HAS_FUNCTIONS = 7
          HAS_FILENAMES = 8
          HAS_LINE_NUMBERS = 9
          HAS_INLINE_FRAMES = 10
        end

        module Location
          ID = 1
          MAPPING_ID = 2
          ADDRESS = 3
          LINE = 4
        end

        module Line
          FUNCTION_ID = 1
          LINE = 2
        end

        module Function
          ID = 1
          NAME = 2
          SYSTEM_NAME = 3
          FILENAME = 4
          START_LINE = 5
        end
      end

      # Sample categories recorded by the collector (see enum Category in
      # ext/vernier/vernier.cc).
      SAMPLE_STATES = {
        0 => "running",
        1 => "idle",
        2 => "stalled",
      }.freeze

      # pprof requires at least one mapping for locations to belong to. We
      # have no binary addresses, so a single synthetic mapping is used.
      MAPPING_ID = 1

      def initialize(profile)
        @profile = profile
      end

      def output(gzip: false)
        result = encode
        if gzip
          require "zlib"
          result = Zlib.gzip(result)
        end
        result
      end

      private

      attr_reader :profile

      Sample = Struct.new(:location_ids, :values, :labels)
      Label = Struct.new(:key, :str, :num)

      def mode
        profile.meta[:mode]
      end

      def interval_nanos
        interval_us = profile.meta[:interval]
        interval_us ? interval_us * 1_000 : 0
      end

      def allocation_interval
        interval = profile.meta[:allocation_interval]
        interval && interval > 0 ? interval : 1
      end

      def allocations?
        profile.threads.each_value.any? do |thread|
          allocations = thread[:allocations]
          allocations && !allocations[:samples].empty?
        end
      end

      def encode
        @strings = Hash.new { |h, k| h[k] = h.size }
        @strings[""] # index 0 must be the empty string
        @used_frames = {}
        @location_ids = {}

        sample_types = build_sample_types
        samples = build_samples
        locations = build_locations
        functions = build_functions(locations)

        buf = Protobuf.new_buffer

        sample_types.each do |type, unit|
          Protobuf.write_bytes(buf, Fields::Profile::SAMPLE_TYPE, encode_value_type(type, unit))
        end

        samples.each do |sample|
          Protobuf.write_bytes(buf, Fields::Profile::SAMPLE, encode_sample(sample))
        end

        Protobuf.write_bytes(buf, Fields::Profile::MAPPING, encode_mapping)

        locations.each do |frame_idx|
          Protobuf.write_bytes(buf, Fields::Profile::LOCATION, encode_location(frame_idx))
        end

        functions.each do |func_idx|
          Protobuf.write_bytes(buf, Fields::Profile::FUNCTION, encode_function(func_idx))
        end

        time_nanos = profile.started_at
        duration_nanos = profile.end_time ? profile.end_time - time_nanos : 0
        duration_nanos = 0 if duration_nanos < 0

        Protobuf.write_int(buf, Fields::Profile::TIME_NANOS, time_nanos)
        Protobuf.write_int(buf, Fields::Profile::DURATION_NANOS, duration_nanos)

        if mode == :wall && interval_nanos > 0
          Protobuf.write_bytes(buf, Fields::Profile::PERIOD_TYPE, encode_value_type("wall", "nanoseconds"))
          Protobuf.write_int(buf, Fields::Profile::PERIOD, interval_nanos)
        end

        comments.each do |comment|
          Protobuf.write_int(buf, Fields::Profile::COMMENT, intern(comment))
        end

        # The default is otherwise the last sample type; make it explicit so
        # the primary measurement of the mode is shown regardless of the
        # presence of other sample types.
        default_type = default_sample_type(sample_types)
        Protobuf.write_int(buf, Fields::Profile::DEFAULT_SAMPLE_TYPE, intern(default_type)) if default_type

        # String indexes are referenced by everything above, so the string
        # table is written last once it is complete.
        string_table = @strings.keys
        string_table.each do |string|
          Protobuf.write_string(buf, Fields::Profile::STRING_TABLE, string)
        end

        buf
      end

      def intern(string)
        @strings[sanitize_string(string)]
      end

      def build_sample_types
        @sample_types ||= case mode
        when :wall
          types = [["samples", "count"]]
          types << ["wall", "nanoseconds"] if interval_nanos > 0
          types << ["allocations", "count"] if allocations?
          types
        when :retained
          [["objects", "count"], ["retained", "bytes"]]
        else
          [["samples", "count"]]
        end
      end

      def default_sample_type(sample_types)
        case mode
        when :wall
          sample_types.include?(["wall", "nanoseconds"]) ? "wall" : "samples"
        when :retained
          "retained"
        else
          "samples"
        end
      end

      def comments
        metadata = profile.meta[:user_metadata] || {}
        metadata.map { |key, value| "#{key}: #{value}" }
      end

      def build_samples
        samples = []
        sample_types = build_sample_types
        has_wall = sample_types.include?(["wall", "nanoseconds"])
        has_allocations = sample_types.include?(["allocations", "count"])

        profile.threads.each_value do |thread|
          thread_labels = [Label.new("thread", thread[:name].to_s, nil)]
          tid = thread[:tid]
          thread_labels << Label.new("tid", nil, tid) if tid && tid != 0

          # Collapse samples sharing a stack (and state) into one pprof
          # sample, as retained-mode profiles in particular have one sample
          # per object. Tracks the total weight and number of samples.
          stack_samples = thread[:samples]
          weights = thread[:weights]
          categories = thread[:sample_categories]
          collapsed = Hash.new { |h, k| h[k] = [0, 0] }
          stack_samples.each_with_index do |stack_idx, i|
            category = categories ? categories[i] : 0
            entry = collapsed[[stack_idx, category]]
            entry[0] += weights[i]
            entry[1] += 1
          end

          collapsed.each do |(stack_idx, category), (weight, count)|
            values =
              case mode
              when :wall
                values = [weight]
                values << weight * interval_nanos if has_wall
                values << 0 if has_allocations
                values
              when :retained
                [count, weight]
              else
                [weight]
              end

            labels = thread_labels
            if mode == :wall
              labels += [Label.new("state", SAMPLE_STATES.fetch(category, "unknown"), nil)]
            end

            samples << Sample.new(location_ids_for(stack_idx), values, labels)
          end

          next unless has_allocations

          allocations = thread[:allocations]
          next unless allocations

          collapsed = Hash.new(0)
          allocations[:samples].each_with_index do |stack_idx, i|
            collapsed[stack_idx] += allocations[:weights][i]
          end

          collapsed.each do |stack_idx, weight|
            values = [0]
            values << 0 if has_wall
            values << weight * allocation_interval

            samples << Sample.new(location_ids_for(stack_idx), values, thread_labels)
          end
        end

        samples
      end

      # pprof wants the leaf first, which is the order Vernier's stack table
      # is walked in.
      def location_ids_for(stack_idx)
        @location_ids[stack_idx] ||= begin
          stack_table = profile.stack_table
          location_ids = []
          while stack_idx
            frame_idx = stack_table.stack_frame_idx(stack_idx)
            @used_frames[frame_idx] = true
            location_ids << location_id(frame_idx)
            stack_idx = stack_table.stack_parent_idx(stack_idx)
          end
          location_ids.freeze
        end
      end

      # IDs must be non-zero
      def location_id(frame_idx) = frame_idx + 1
      def function_id(func_idx) = func_idx + 1

      def build_locations
        @used_frames.keys.sort
      end

      def build_functions(frame_idxs)
        stack_table = profile.stack_table
        frame_idxs.map { |frame_idx| stack_table.frame_func_idx(frame_idx) }.uniq.sort
      end

      def encode_value_type(type, unit)
        buf = Protobuf.new_buffer
        Protobuf.write_int(buf, Fields::ValueType::TYPE, intern(type))
        Protobuf.write_int(buf, Fields::ValueType::UNIT, intern(unit))
        buf
      end

      def encode_sample(sample)
        buf = Protobuf.new_buffer
        Protobuf.write_packed_ints(buf, Fields::Sample::LOCATION_ID, sample.location_ids)
        Protobuf.write_packed_ints(buf, Fields::Sample::VALUE, sample.values)
        sample.labels.each do |label|
          Protobuf.write_bytes(buf, Fields::Sample::LABEL, encode_label(label))
        end
        buf
      end

      def encode_label(label)
        buf = Protobuf.new_buffer
        Protobuf.write_int(buf, Fields::Label::KEY, intern(label.key))
        Protobuf.write_int(buf, Fields::Label::STR, intern(label.str)) if label.str
        Protobuf.write_int(buf, Fields::Label::NUM, label.num) if label.num
        buf
      end

      def encode_mapping
        buf = Protobuf.new_buffer
        Protobuf.write_int(buf, Fields::Mapping::ID, MAPPING_ID)
        Protobuf.write_bool(buf, Fields::Mapping::HAS_FUNCTIONS, true)
        Protobuf.write_bool(buf, Fields::Mapping::HAS_FILENAMES, true)
        Protobuf.write_bool(buf, Fields::Mapping::HAS_LINE_NUMBERS, true)
        buf
      end

      def encode_location(frame_idx)
        stack_table = profile.stack_table
        func_idx = stack_table.frame_func_idx(frame_idx)

        line = Protobuf.new_buffer
        Protobuf.write_int(line, Fields::Line::FUNCTION_ID, function_id(func_idx))
        Protobuf.write_int(line, Fields::Line::LINE, stack_table.frame_line_no(frame_idx))

        buf = Protobuf.new_buffer
        Protobuf.write_int(buf, Fields::Location::ID, location_id(frame_idx))
        Protobuf.write_int(buf, Fields::Location::MAPPING_ID, MAPPING_ID)
        Protobuf.write_bytes(buf, Fields::Location::LINE, line)
        buf
      end

      def encode_function(func_idx)
        stack_table = profile.stack_table
        name = intern(stack_table.func_name(func_idx) || "")
        filename = intern(stack_table.func_filename(func_idx) || "")

        # system_name is deliberately left unset. Ruby has no mangled names,
        # and when a function's name equals its system_name pprof assumes it
        # still needs demangling and applies C++ heuristics that strip
        # "<main>" and "(2 levels)" from names like "block (2 levels) in <main>".
        buf = Protobuf.new_buffer
        Protobuf.write_int(buf, Fields::Function::ID, function_id(func_idx))
        Protobuf.write_int(buf, Fields::Function::NAME, name)
        Protobuf.write_int(buf, Fields::Function::FILENAME, filename)
        Protobuf.write_int(buf, Fields::Function::START_LINE, stack_table.func_first_lineno(func_idx))
        buf
      end
    end
  end
end
