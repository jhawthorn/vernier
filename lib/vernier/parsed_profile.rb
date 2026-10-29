# frozen_string_literal: true

require "json"
require_relative "stack_table_helpers"

module Vernier
  class ParsedProfile
    def self.read_file(filename)
      # Print the inverted tree from a Vernier profile
      is_gzip = File.binread(filename, 2) == "\x1F\x8B".b # check for gzip header

      json = if is_gzip
        require "zlib"
        Zlib::GzipReader.open(filename) { |gz| gz.read }
      else
        File.read filename
      end

      info = JSON.load json

      new(info)
    end

    class StackTable
      # Bits of the frameTable and funcTable "flags" columns. See
      # Vernier::Output::Firefox.
      FRAME_FLAG_HAS_LINE = 1 << 4
      FUNC_FLAG_HAS_SOURCE = 1 << 3
      FUNC_FLAG_HAS_LINE = 1 << 4

      # Tables under "shared" in the current format, where stacks are shared
      # by all threads. See Vernier::Output::Firefox for how they are written.
      def self.from_shared(shared)
        stack_table = shared["stackTable"]
        frame_table = shared["frameTable"]
        func_table = shared["funcTable"]
        sources = shared["sources"]

        stack_parents = stack_table["prefixOffset"].each_with_index.map do |offset, idx|
          offset == 0 ? nil : idx - offset
        end

        frame_flags = frame_table["flags"]
        frame_lines = frame_table["line"].each_with_index.map do |line, idx|
          frame_flags[idx] & FRAME_FLAG_HAS_LINE == 0 ? 0 : line
        end

        func_flags = func_table["flags"]
        func_filenames = func_table["source"].each_with_index.map do |source_idx, idx|
          sources["filename"][source_idx] unless func_flags[idx] & FUNC_FLAG_HAS_SOURCE == 0
        end
        func_first_linenos = func_table["lineNumber"].each_with_index.map do |line, idx|
          func_flags[idx] & FUNC_FLAG_HAS_LINE == 0 ? 0 : line
        end

        new(
          stack_parents: stack_parents,
          stack_frames: stack_table["frame"],
          frame_funcs: frame_table["func"],
          frame_lines: frame_lines,
          func_names: func_table["name"],
          func_filenames: func_filenames,
          func_first_linenos: func_first_linenos,
          strings: shared["stringArray"]
        )
      end

      # Per-thread tables, as written by older versions of Vernier
      def self.from_thread(thread_data)
        new(
          stack_parents: thread_data["stackTable"]["prefix"],
          stack_frames: thread_data["stackTable"]["frame"],
          frame_funcs: thread_data["frameTable"]["func"],
          frame_lines: thread_data["frameTable"]["line"],
          func_names: thread_data["funcTable"]["name"],
          func_filenames: thread_data["funcTable"]["fileName"],
          func_first_linenos: thread_data["funcTable"]["lineNumber"],
          strings: thread_data["stringArray"]
        )
      end

      def initialize(stack_parents:, stack_frames:, frame_funcs:, frame_lines:, func_names:, func_filenames:, func_first_linenos:, strings:)
        @stack_parents = stack_parents
        @stack_frames = stack_frames
        @frame_funcs = frame_funcs
        @frame_lines = frame_lines
        @func_names = func_names
        @func_filenames = func_filenames
        @func_first_linenos = func_first_linenos
        @strings = strings
      end

      attr_reader :strings

      def stack_count = @stack_parents.length
      def frame_count = @frame_funcs.length
      def func_count = @func_names.length

      def stack_parent_idx(idx) = @stack_parents[idx]
      def stack_frame_idx(idx) = @stack_frames[idx]

      def frame_func_idx(idx) = @frame_funcs[idx]
      def frame_line_no(idx) = @frame_lines[idx]

      def func_name_idx(idx) = @func_names[idx]
      def func_filename_idx(idx) = @func_filenames[idx]
      def func_name(idx) = @strings[func_name_idx(idx)]
      def func_first_lineno(idx) = @func_first_linenos[idx]

      def func_filename(idx)
        filename_idx = func_filename_idx(idx)
        filename_idx ? @strings[filename_idx] : ""
      end
      alias func_path func_filename

      include StackTableHelpers
    end

    class Thread
      attr_reader :data

      def initialize(data, shared_stack_table = nil)
        @data = data
        @stack_table = shared_stack_table
      end

      def stack_table
        @stack_table ||= StackTable.from_thread(@data)
      end

      def main_thread?
        @data["isMainThread"]
      end

      def samples
        @data["samples"]["stack"]
      end

      def weights
        @data["samples"]["weight"]
      end

      # Emulate hash
      def [](name)
        send(name)
      end
    end

    attr_reader :data
    def initialize(data)
      @data = data
    end

    # The stack table shared by all threads, or nil for profiles written by
    # older versions of Vernier, which had one per thread.
    def stack_table
      return @stack_table if defined?(@stack_table)

      shared = @data["shared"]
      @stack_table = shared && StackTable.from_shared(shared)
    end

    def threads
      @threads ||=
        @data["threads"].map do |thread_data|
          Thread.new(thread_data, stack_table)
        end
    end

    def main_thread
      threads.detect(&:main_thread?)
    end
  end
end
