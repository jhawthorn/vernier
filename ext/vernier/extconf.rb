# frozen_string_literal: true

require "mkmf"

$CXXFLAGS += " -std=c++14 "

create_makefile("vernier/vernier")
