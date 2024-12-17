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
      def initialize(thread_data)
        @stack_parents = thread_data["stackTable"]["prefix"]
        @stack_frames  = thread_data["stackTable"]["frame"]
        @frame_funcs   = thread_data["frameTable"]["func"]
        @frame_lines   = thread_data["frameTable"]["line"]
        @func_names    = thread_data["funcTable"]["name"]
        @func_filenames = thread_data["funcTable"]["fileName"]
        #@func_first_linenos = thread_data["funcTable"]["first"]
        @strings  = thread_data["stringArray"]
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
      def func_filename(idx) = @strings[func_filename_idx(idx)]
      def func_first_lineno(idx) = @func_first_lineno[idx]

      include StackTableHelpers
    end

    class Thread
      attr_reader :data

      def initialize(data)
        @data = data
      end

      def stack_table
        @stack_table ||= StackTable.new(@data)
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

    def threads
      @threads ||=
        @data["threads"].map do |thread_data|
          Thread.new(thread_data)
        end
    end

    def main_thread
      threads.detect(&:main_thread?)
    end
  end
end
