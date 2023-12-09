# frozen_string_literal: true

require "mkmf"

$CXXFLAGS += " -std=c++14 "
$CXXFLAGS += " -ggdb3 -Og "

have_header("ruby/thread.h")
have_struct_member("rb_internal_thread_event_data_t", "thread", ["ruby/thread.h"])

have_func("rb_profile_thread_frames", "ruby/debug.h")

have_func("pthread_setname_np")

create_makefile("vernier/vernier")
