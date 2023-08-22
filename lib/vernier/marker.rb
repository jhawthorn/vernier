# frozen_string_literal: true

require_relative "vernier" # Make sure constants are loaded

module Vernier
  module Marker
    MARKER_SYMBOLS = []
    Type.constants.each do |name|
      MARKER_SYMBOLS[Type.const_get(name)] = name
    end
    MARKER_SYMBOLS.freeze

    MARKER_STRINGS = []

    MARKER_STRINGS[Type::GVL_THREAD_STARTED] = "Thread started"
    MARKER_STRINGS[Type::GVL_THREAD_EXITED] = "Thread exited"

    MARKER_STRINGS[Type::GC_START] = "GC start"
    MARKER_STRINGS[Type::GC_END_MARK] = "GC end marking"
    MARKER_STRINGS[Type::GC_END_SWEEP] = "GC end sweeping"
    MARKER_STRINGS[Type::GC_ENTER] = "GC enter"
    MARKER_STRINGS[Type::GC_EXIT] = "GC exit"
    MARKER_STRINGS[Type::GC_PAUSE] = "GC pause"

    MARKER_STRINGS[Type::THREAD_RUNNING] = "Thread Running"
    MARKER_STRINGS[Type::THREAD_STALLED] = "Thread Stalled"
    MARKER_STRINGS[Type::THREAD_SUSPENDED] = "Thread Suspended"

    MARKER_STRINGS.freeze

    ##
    # Return an array of marker names.  The index of the string maps to the
    # value of the corresponding constant
    def self.name_table
      MARKER_STRINGS
    end
  end
end
