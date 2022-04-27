# frozen_string_literal: true

require "mkmf"

$CXXFLAGS += " -std=c++14 "
$CXXFLAGS += " -ggdb3 -Og "

create_makefile("vernier/vernier")
