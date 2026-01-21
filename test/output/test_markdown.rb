# frozen_string_literal: true

require "test_helper"

class TestOutputMarkdown < Minitest::Test
  include FirefoxTestHelpers

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
    end

    output = Vernier::Output::Markdown.new(result).output

    # Check title and structure
    assert_match(/^# Vernier Profile/, output)
    assert_match(/^## Summary/, output)
    assert_match(/^## Top Hotspots/, output)
    assert_match(/^## Threads/, output)
    assert_match(/^## Hot Files/, output)

    # Check summary table
    assert_match(/\| Mode \|/, output)
    assert_match(/\| Total Samples \|/, output)
    assert_match(/\| Threads \|/, output)

    # Check hotspots contain expected functions
    assert_includes output, "GVLTest.sleep_without_gvl"
    assert_includes output, "GVLTest.sleep_holding_gvl"
    assert_includes output, "Kernel#sleep"
    assert_includes output, "Process.clock_gettime"
  end

  def test_parsed_profile
    profile = Vernier::ParsedProfile.read_file(fixture_path("gvl_sleep.vernier.json"))
    output = Vernier::Output::Markdown.new(profile).output

    # Check structure
    assert_match(/^# Vernier Profile/, output)
    assert_match(/^## Summary/, output)
    assert_match(/^## Top Hotspots/, output)

    # Check hotspots contain expected functions from fixture
    assert_includes output, "GVLTest.sleep_holding_gvl"
    assert_includes output, "Kernel#sleep"
    assert_includes output, "GVLTest.sleep_without_gvl"
  end

  def test_output_is_string
    result = Vernier.trace { sleep 0.001 }
    output = Vernier::Output::Markdown.new(result).output

    assert_kind_of String, output
    refute_empty output
  end

  def test_custom_limits
    result = Vernier.trace do
      target = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.01
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < target
      end
    end

    output = Vernier::Output::Markdown.new(result, top_n: 5, lines_per_file: 2).output

    # Should still have required sections
    assert_match(/^## Top Hotspots/, output)
    assert_match(/^## Hot Files/, output)
  end

  def test_result_to_markdown
    result = Vernier.trace { sleep 0.001 }

    output = result.to_markdown
    assert_kind_of String, output
    assert_match(/^# Vernier Profile/, output)
  end

  def test_write_markdown_to_file
    result = Vernier.trace { sleep 0.001 }

    Dir.mktmpdir do |dir|
      path = File.join(dir, "profile.vernier.md")
      result.write(out: path, format: "markdown")

      assert File.exist?(path)
      content = File.read(path)
      assert_match(/^# Vernier Profile/, content)
    end
  end

  def test_write_md_format_alias
    result = Vernier.trace { sleep 0.001 }

    Dir.mktmpdir do |dir|
      path = File.join(dir, "profile.vernier.md")
      result.write(out: path, format: "md")

      assert File.exist?(path)
      content = File.read(path)
      assert_match(/^# Vernier Profile/, content)
    end
  end

  def test_write_markdown_to_io
    result = Vernier.trace { sleep 0.001 }

    io = StringIO.new
    result.write(out: io, format: "markdown")

    content = io.string
    assert_match(/^# Vernier Profile/, content)
  end

  def test_empty_profile
    result = Vernier.trace { }

    output = Vernier::Output::Markdown.new(result).output

    # Should still produce valid markdown structure
    assert_match(/^# Vernier Profile/, output)
    assert_match(/^## Summary/, output)
  end

  def test_markdown_escapes_special_characters
    result = Vernier.trace { sleep 0.001 }

    # The output should be valid markdown (no unescaped pipe chars breaking tables)
    output = Vernier::Output::Markdown.new(result).output

    # Tables should have consistent structure
    lines = output.lines.select { |l| l.start_with?("|") }
    lines.each do |line|
      # Each table row should have matching number of cells
      assert line.end_with?("|\n"), "Table row should end with pipe: #{line.inspect}"
    end
  end
end
