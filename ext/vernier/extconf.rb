# frozen_string_literal: true

require "mkmf"

$CXXFLAGS += " -fvisibility=hidden "
$CXXFLAGS += " -std=c++14 "
$CXXFLAGS += " -ggdb3 -Og "

# Make VERNIER_ASSERT always check, even if Ruby wasn't built with RUBY_DEBUG.
# Set by our CI; gem installs get RUBY_ASSERT (compiled out) by default.
$defs << "-DVERNIER_ALWAYS_ASSERT" if ["1", "true"].include?(ENV["VERNIER_ALWAYS_ASSERT"])

have_header("ruby/thread.h")

have_func("pthread_setname_np")
have_func("pthread_condattr_setclock")

create_makefile("vernier/vernier")
