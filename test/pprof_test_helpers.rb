# frozen_string_literal: true

require "zlib"
require "tempfile"
require "open3"

# Decodes pprof output with its own protobuf reader, independent of the
# encoder in Vernier::Output::Pprof, and checks the invariants that pprof's
# profile.CheckValid enforces when it loads a profile.
module PprofTestHelpers
  # Generic protocol buffers wire format reader
  class WireReader
    def initialize(bytes)
      @bytes = bytes.b
      @pos = 0
    end

    def eof? = @pos >= @bytes.bytesize

    def varint
      result = 0
      shift = 0
      loop do
        raise "truncated varint" if eof?

        byte = @bytes.getbyte(@pos)
        @pos += 1
        result |= (byte & 0x7f) << shift
        shift += 7
        break if byte < 0x80
        raise "varint longer than 10 bytes" if shift > 70
      end
      result
    end

    def bytes(length)
      raise "truncated length-delimited field" if @pos + length > @bytes.bytesize

      slice = @bytes.byteslice(@pos, length)
      @pos += length
      slice
    end

    # Yields field number, wire type and raw value (Integer for varints,
    # String for everything else).
    def each_field
      until eof?
        tag = varint
        field = tag >> 3
        case (wire_type = tag & 7)
        when 0 then yield field, wire_type, varint
        when 1 then yield field, wire_type, bytes(8)
        when 2 then yield field, wire_type, bytes(varint)
        when 5 then yield field, wire_type, bytes(4)
        else raise "unexpected wire type #{wire_type} for field #{field}"
        end
      end
    end
  end

  # [name, type, repeated?] per field number, from profile.proto
  SCHEMA = {
    profile: {
      1 => [:sample_type, :value_type, true],
      2 => [:sample, :sample, true],
      3 => [:mapping, :mapping, true],
      4 => [:location, :location, true],
      5 => [:function, :function, true],
      6 => [:string_table, :string, true],
      7 => [:drop_frames, :int64],
      8 => [:keep_frames, :int64],
      9 => [:time_nanos, :int64],
      10 => [:duration_nanos, :int64],
      11 => [:period_type, :value_type],
      12 => [:period, :int64],
      13 => [:comment, :int64, true],
      14 => [:default_sample_type, :int64],
      15 => [:doc_url, :int64],
    },
    value_type: {
      1 => [:type, :int64],
      2 => [:unit, :int64],
    },
    sample: {
      1 => [:location_id, :uint64, true],
      2 => [:value, :int64, true],
      3 => [:label, :label, true],
    },
    label: {
      1 => [:key, :int64],
      2 => [:str, :int64],
      3 => [:num, :int64],
      4 => [:num_unit, :int64],
    },
    mapping: {
      1 => [:id, :uint64],
      2 => [:memory_start, :uint64],
      3 => [:memory_limit, :uint64],
      4 => [:file_offset, :uint64],
      5 => [:filename, :int64],
      6 => [:build_id, :int64],
      7 => [:has_functions, :bool],
      8 => [:has_filenames, :bool],
      9 => [:has_line_numbers, :bool],
      10 => [:has_inline_frames, :bool],
    },
    location: {
      1 => [:id, :uint64],
      2 => [:mapping_id, :uint64],
      3 => [:address, :uint64],
      4 => [:line, :line, true],
      5 => [:is_folded, :bool],
    },
    line: {
      1 => [:function_id, :uint64],
      2 => [:line, :int64],
      3 => [:column, :int64],
    },
    function: {
      1 => [:id, :uint64],
      2 => [:name, :int64],
      3 => [:system_name, :int64],
      4 => [:filename, :int64],
      5 => [:start_line, :int64],
    },
  }.freeze

  SCALAR_TYPES = %i[int64 uint64 bool string].freeze

  def decode_pprof(output)
    output = output.b
    output = Zlib.gunzip(output) if output.start_with?("\x1F\x8B".b)
    decode_pprof_message(:profile, output)
  end

  def decode_pprof_message(type, bytes)
    schema = SCHEMA.fetch(type)
    message = {}
    schema.each_value do |name, field_type, repeated|
      message[name] =
        if repeated
          []
        else
          case field_type
          when :int64, :uint64 then 0
          when :bool then false
          when :string then ""
          else nil
          end
        end
    end

    WireReader.new(bytes).each_field do |field, wire_type, raw|
      name, field_type, repeated = schema.fetch(field) { raise "unknown field #{field} in #{type}" }

      values =
        case field_type
        when :int64, :uint64, :bool
          ints =
            if wire_type == 0
              [raw]
            elsif wire_type == 2 && repeated
              # packed
              reader = WireReader.new(raw)
              packed = []
              packed << reader.varint until reader.eof?
              packed
            else
              raise "bad wire type #{wire_type} for #{type}.#{name}"
            end
          ints.map do |int|
            case field_type
            when :int64 then int >= (1 << 63) ? int - (1 << 64) : int
            when :uint64 then int
            when :bool then int != 0
            end
          end
        when :string
          raise "bad wire type #{wire_type} for #{type}.#{name}" unless wire_type == 2

          [raw.dup.force_encoding(Encoding::UTF_8)]
        else
          raise "bad wire type #{wire_type} for #{type}.#{name}" unless wire_type == 2

          [decode_pprof_message(field_type, raw)]
        end

      if repeated
        message[name].concat(values)
      else
        raise "non-repeated field #{type}.#{name} appeared twice" if message.key?(:"__seen_#{name}")

        message[:"__seen_#{name}"] = true
        message[name] = values.last
      end
    end

    message.delete_if { |k, _| k.start_with?("__seen_") }
    message
  end

  # Checks that the output is a well-formed pprof profile and returns the
  # decoded profile.
  def assert_valid_pprof(output)
    assert_kind_of(String, output)

    profile = decode_pprof(output)

    strings = profile[:string_table]
    refute_empty(strings)
    assert_equal("", strings[0], "string_table[0] must be the empty string")
    strings.each do |string|
      assert(string.valid_encoding?, "string table entry is not valid UTF-8: #{string.inspect}")
    end
    assert_equal(strings.uniq.size, strings.size, "string table has duplicates")
    string_index = ->(idx, what) do
      assert_includes(0...strings.size, idx, "#{what} string index #{idx} out of range")
      strings[idx]
    end

    refute_empty(profile[:sample_type], "profile has no sample types")
    sample_types = profile[:sample_type].map do |value_type|
      [string_index.(value_type[:type], "sample_type.type"), string_index.(value_type[:unit], "sample_type.unit")]
    end
    sample_types.each do |type, unit|
      refute_empty(type)
      refute_empty(unit)
    end

    mappings = profile[:mapping].to_h { |m| [m[:id], m] }
    assert_equal(profile[:mapping].size, mappings.size, "duplicate mapping ids")
    refute_includes(mappings, 0, "mapping id must not be zero")

    functions = profile[:function].to_h { |f| [f[:id], f] }
    assert_equal(profile[:function].size, functions.size, "duplicate function ids")
    refute_includes(functions, 0, "function id must not be zero")
    profile[:function].each do |function|
      string_index.(function[:name], "function.name")
      string_index.(function[:system_name], "function.system_name")
      string_index.(function[:filename], "function.filename")
      assert_operator(function[:start_line], :>=, 0)
    end

    locations = profile[:location].to_h { |l| [l[:id], l] }
    assert_equal(profile[:location].size, locations.size, "duplicate location ids")
    refute_includes(locations, 0, "location id must not be zero")
    profile[:location].each do |location|
      if location[:mapping_id] != 0
        assert_includes(mappings, location[:mapping_id], "location refers to missing mapping")
      end
      refute_empty(location[:line], "location without lines")
      location[:line].each do |line|
        assert_includes(functions, line[:function_id], "line refers to missing function")
        assert_operator(line[:line], :>=, 0)
      end
    end

    profile[:sample].each do |sample|
      assert_equal(sample_types.size, sample[:value].size, "sample has wrong number of values")
      refute_empty(sample[:location_id], "sample without locations")
      sample[:location_id].each do |location_id|
        assert_includes(locations, location_id, "sample refers to missing location")
      end
      sample[:label].each do |label|
        key = string_index.(label[:key], "label.key")
        refute_empty(key, "label with empty key")
        string_index.(label[:str], "label.str")
        string_index.(label[:num_unit], "label.num_unit")
        refute(label[:str] != 0 && (label[:num] != 0 || label[:num_unit] != 0), "label with both str and num")
      end
    end

    if (period_type = profile[:period_type])
      string_index.(period_type[:type], "period_type.type")
      string_index.(period_type[:unit], "period_type.unit")
    end
    assert_operator(profile[:period], :>=, 0)

    if profile[:default_sample_type] != 0
      default_type = string_index.(profile[:default_sample_type], "default_sample_type")
      assert_includes(sample_types.map(&:first), default_type, "default_sample_type is not a sample type")
    end

    profile[:comment].each { |idx| string_index.(idx, "comment") }

    assert_operator(profile[:time_nanos], :>=, 0)
    assert_operator(profile[:duration_nanos], :>=, 0)

    profile
  end

  def pprof_string(profile, idx) = profile[:string_table].fetch(idx)

  def pprof_sample_types(profile)
    profile[:sample_type].map { |t| [pprof_string(profile, t[:type]), pprof_string(profile, t[:unit])] }
  end

  # Labels of a sample as a hash of key => string or integer value
  def pprof_labels(profile, sample)
    sample[:label].to_h do |label|
      key = pprof_string(profile, label[:key])
      value = label[:str] != 0 ? pprof_string(profile, label[:str]) : label[:num]
      [key, value]
    end
  end

  # Function names of a sample's stack, leaf first
  def pprof_sample_stack(profile, sample)
    locations = profile[:location].to_h { |l| [l[:id], l] }
    functions = profile[:function].to_h { |f| [f[:id], f] }
    sample[:location_id].map do |location_id|
      line = locations.fetch(location_id)[:line].first
      function = functions.fetch(line[:function_id])
      [pprof_string(profile, function[:name]), pprof_string(profile, function[:filename]), line[:line]]
    end
  end

  # The decoded profile without the fields that depend on the wall clock at
  # the time of writing, for comparing two outputs of the same result.
  def pprof_without_times(profile)
    profile.reject { |key, _| %i[time_nanos duration_nanos].include?(key) }
  end

  # Sum of each sample type's value across all samples
  def pprof_totals(profile)
    types = pprof_sample_types(profile).map(&:first)
    totals = Hash.new(0)
    profile[:sample].each do |sample|
      sample[:value].each_with_index do |value, i|
        totals[types[i]] += value
      end
    end
    totals
  end

  # Command (as an argv array) to run the pprof tool, or nil if unavailable.
  # Set VERNIER_PPROF to override, e.g. VERNIER_PPROF="go tool pprof".
  def pprof_command
    return @pprof_command if defined?(@pprof_command)

    @pprof_command =
      if (override = ENV["VERNIER_PPROF"])
        override.split
      elsif executable_in_path?("pprof")
        ["pprof"]
      elsif executable_in_path?("go")
        %w[go tool pprof]
      end
  end

  def executable_in_path?(name)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
      path = File.join(dir, name)
      File.file?(path) && File.executable?(path)
    end
  end

  # Runs the pprof tool on the given output and returns stdout, failing on
  # a non-zero exit status or anything written to stderr.
  def run_pprof(output, *args)
    Tempfile.create(["vernier", ".pb.gz"]) do |file|
      file.binmode
      file.write(output)
      file.close

      env = { "HOME" => Dir.tmpdir, "PPROF_TMPDIR" => Dir.tmpdir }
      stdout, stderr, status = Open3.capture3(env, *pprof_command, *args, file.path)
      assert(status.success?, "pprof failed (#{status}):\n#{stderr}\n#{stdout}")
      assert_empty(stderr, "pprof wrote to stderr")
      stdout
    end
  end
end
