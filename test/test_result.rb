# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "stringio"
require "zlib"

class TestResult < Minitest::Test
  include FirefoxTestHelpers
  include CpuprofileTestHelpers

  def setup
    @result = Vernier.trace do
      sleep 0.001
    end
  end

  def test_write_to_file_firefox_format
    Tempfile.open("vernier_test") do |tempfile|
      @result.write(out: tempfile.path, format: "firefox")
      tempfile.rewind
      content = tempfile.read
      assert_valid_firefox_profile(content)
    end
  end

  def test_write_to_file_cpuprofile_format
    Tempfile.open("vernier_test") do |tempfile|
      @result.write(out: tempfile.path, format: "cpuprofile")
      tempfile.rewind
      content = tempfile.read
      assert_valid_cpuprofile(content)
    end
  end

  def test_write_to_stringio_firefox_format
    stringio = StringIO.new
    @result.write(out: stringio, format: "firefox")
    stringio.rewind
    content = stringio.read
    assert_valid_firefox_profile(content)
  end

  def test_write_to_stringio_cpuprofile_format
    stringio = StringIO.new
    @result.write(out: stringio, format: "cpuprofile")
    stringio.rewind
    content = stringio.read
    assert_valid_cpuprofile(content)
  end

  def test_write_to_file_with_gz_extension
    Tempfile.open(["vernier_test", ".gz"]) do |tempfile|
      @result.write(out: tempfile.path, format: "firefox")
      tempfile.rewind
      content = tempfile.read
      decompressed = Zlib.gunzip(content)
      assert_valid_firefox_profile(decompressed)
    end
  end

  def test_write_to_stringio_ignores_gz_extension_logic
    stringio = StringIO.new
    @result.write(out: stringio, format: "firefox")
    stringio.rewind
    content = stringio.read
    assert_valid_firefox_profile(content)
  end

  def test_write_with_invalid_format_raises_error
    stringio = StringIO.new
    error = assert_raises(ArgumentError) do
      @result.write(out: stringio, format: "invalid")
    end
    assert_equal "unknown format: invalid", error.message
  end
end
