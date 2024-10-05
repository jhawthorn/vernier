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

    MARKER_STRINGS[Type::GVL_THREAD_STARTED] = "\u2001Thread started"
    MARKER_STRINGS[Type::GVL_THREAD_EXITED] = "\u2002Thread exited"

    MARKER_STRINGS[Type::GC_ENTER] = "\u2001GC enter"
    MARKER_STRINGS[Type::GC_START] = "\u2002GC start"
    MARKER_STRINGS[Type::GC_PAUSE] = "\u2003GC pause"
    MARKER_STRINGS[Type::GC_END_MARK] = "\u2004GC end marking"
    MARKER_STRINGS[Type::GC_END_SWEEP] = "\u2005GC end sweeping"
    MARKER_STRINGS[Type::GC_EXIT] = "\u2006GC exit"

    MARKER_STRINGS[Type::THREAD_RUNNING] = "\u2001Thread Running"
    MARKER_STRINGS[Type::THREAD_STALLED] = "\u2002Thread Stalled"
    MARKER_STRINGS[Type::THREAD_SUSPENDED] = "\u2003Thread Suspended"

    MARKER_STRINGS.freeze

    ##
    # Return an array of marker names.  The index of the string maps to the
    # value of the corresponding constant
    def self.name_table
      MARKER_STRINGS
    end
  end
end
