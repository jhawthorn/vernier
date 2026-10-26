# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# Loads our output into the Firefox profiler through its CLI
# (npm install -g @firefox-devtools/profiler-cli) and queries it. Only runs
# when PROFILER_CLI names the executable, which CI does.
class TestFirefoxProfilerCli < Minitest::Test
  def setup
    skip "set PROFILER_CLI to run" unless ENV["PROFILER_CLI"]
    @dir = Dir.mktmpdir("vernier-pq")
  end

  def teardown
    if @dir
      profiler_cli("stop", "--all", check: false)
      FileUtils.remove_entry(@dir)
    end
  end

  def test_profile_loads_in_firefox_profiler
    result = Vernier.trace(hooks: [:memory_usage]) do
      th = Thread.new { Thread.current.name = "worker"; busy_loop(0.02) }
      3.times { busy_loop(0.02); GC.start }
      th.join
    end
    path = File.join(@dir, "profile.json")
    File.write(path, Vernier::Output::Firefox.new(result).output)

    profiler_cli("load", path)

    threads = query("thread", "list").fetch("threads")
    assert_includes threads.map { _1["name"] }, "worker"

    functions = query("thread", "samples").fetch("topFunctionsBySelf")
    assert_includes functions.map { _1["name"] }, "TestFirefoxProfilerCli#busy_loop"

    markers = query("thread", "markers").fetch("byType")
    assert_includes markers.map { _1["markerName"] }, "GC pause"

    counters = query("counter", "list").fetch("counters")
    assert_equal ["memory"], counters.map { _1["name"] }
  end

  private

  def busy_loop(seconds)
    target = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < target
    end
  end

  def query(*args)
    JSON.parse(profiler_cli(*args, "--json"))
  end

  def profiler_cli(*args, check: true)
    env = { "PROFILER_CLI_SESSION_DIR" => @dir }
    out, err, status = Open3.capture3(env, ENV["PROFILER_CLI"], *args)
    assert status.success?, "profiler-cli #{args.join(" ")} failed:\n#{out}#{err}" if check
    out
  end
end
