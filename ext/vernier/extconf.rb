# frozen_string_literal: true

require "mkmf"

$CXXFLAGS += " -std=c++14 "
$CXXFLAGS += " -ggdb3 -Og "

have_header("ruby/thread.h")
have_struct_member("rb_internal_thread_event_data_t", "thread", ["ruby/thread.h"])
create_makefile("vernier/vernier")
