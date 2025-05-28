# frozen_string_literal: true

require "test_helper"

class TestOutputCpuprofile < Minitest::Test
  include CpuprofileTestHelpers

  def test_complex_profile
    result = Vernier.trace do
      # Proper Ruby sleep
      sleep 0.01

      # Sleep inside rb_thread_call_without_gvl
      GVLTest.sleep_without_gvl(0.01)

      # Sleep with GVL held
      GVLTest.sleep_holding_gvl(0.01)

      # Ruby busy sleep
      target = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.01
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < target
      end

      # Short sleeps (likely) create markers without matching sampling stacks
      1.times { sleep 0.00001 }
      1.times { sleep 0.00001 }
      1.times { sleep 0.00001 }

      # Some GC time
      GC.start
    end

    cpuprofile_output = Vernier::Output::Cpuprofile.new(result).output

    File.write("tmp/foo.cpuprofile", cpuprofile_output)

    assert_valid_cpuprofile(cpuprofile_output)
  end

  def test_empty_block
    result = Vernier.trace do
    end
    output = Vernier::Output::Cpuprofile.new(result).output
    assert_valid_cpuprofile(output)
  end

  def test_timed_firefox_output
    result = Vernier.trace do
      i = 0
      while i < 1_000_000
        i += 1
      end
    end

    output = Vernier::Output::Cpuprofile.new(result).output

    assert_valid_cpuprofile(output)
  end

  # Cpuprofile only profiles the main thread
  def test_threaded_timed_firefox_output
    result = Vernier.trace do
      th1 = Thread.new { sleep 0.01 }
      th2 = Thread.new { sleep 0.02 }
      th1.join
      th2.join
    end

    output = Vernier::Output::Cpuprofile.new(result).output

    assert_valid_cpuprofile(output)
  end

  def test_allocation_samples
    result = Vernier.trace(allocation_interval: 1) do
      JSON.parse(%{{ "foo": { "bar": ["baz", 123] } }})
    end

    output = Vernier::Output::Cpuprofile.new(result).output
    assert_valid_cpuprofile(output)
  end

  def test_profile_with_various_encodings
    result = Vernier.trace(mode: :custom) do |profiler|
      sample = -> { profiler.sample }

      encoded_method("ASCII", name: "ascii").call(&sample)
      encoded_method("UTF-8").call(&sample)
      encoded_method("BINARY").call(&sample)

      # This doesn't quite work how I'd like, as we just interpret bytes as
      # UTF-8, but what's most important is that we don't crash
      encoded_method("Shift_JIS").call(&sample)
    end

    output = Vernier::Output::Cpuprofile.new(result).output
    assert_valid_cpuprofile(output)
  end

end
