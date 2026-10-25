# frozen_string_literal: true

require "test_helper"

class IntegrationTest < Minitest::Test
  include FirefoxTestHelpers

  LIB_DIR = File.expand_path("../lib", __dir__)

  def test_allocations
    result = run_vernier({allocation_interval: 1}, "-e", "")
    assert_valid_firefox_profile(result.to_json)
  end

  def test_vernier_run
    result = vernier_run("--", "ruby", "-e", "'sleep 1'")
    assert_valid_firefox_profile(result.to_json)
  end

  def test_vernier_run_with_metadata
    result = vernier_run("--metadata", "key1=val1",
                         "--metadata", "key2=val2",
                         "--", "ruby", "-e", "'sleep 1'")
    assert_valid_firefox_profile(result.to_json)
    assert_equal result["meta"]["vernierUserMetadata"]["key1"], "val1"
    assert_equal result["meta"]["vernierUserMetadata"]["key2"], "val2"
  end

  def test_vernier_run_with_metadata_last_value_takes_precedence
    result = vernier_run("--metadata", "key1=val1",
                         "--metadata", "key2=val2",
                         "--metadata", "key1=val3",
                         "--", "ruby", "-e", "'sleep 1'")
    assert_valid_firefox_profile(result.to_json)
    assert_equal result["meta"]["vernierUserMetadata"]["key2"], "val2"
    assert_equal result["meta"]["vernierUserMetadata"]["key1"], "val3"
  end

  def test_vernier_run_with_metadata_writes_extra_metadata_for_display
    result = vernier_run("--metadata", "key1=val1",
                         "--metadata", "key2=val2",
                         "--", "ruby", "-e", "'sleep 1'")
    assert_valid_firefox_profile(result.to_json)
    assert_equal result["meta"]["vernierUserMetadata"]["key1"], "val1"
    assert_equal result["meta"]["vernierUserMetadata"]["key2"], "val2"
    assert_equal result["meta"]["extra"].first["entries"].detect{ |k| k["label"] == "key1"}["value"], "val1"
    assert_equal result["meta"]["extra"].first["entries"].detect{ |k| k["label"] == "key2"}["value"], "val2"
  end

  def test_vernier_run_embeds_sources_by_default
    with_script do |script|
      result = vernier_run("--", "ruby", script.path)
      assert_valid_firefox_profile(result.to_json)
      assert_equal File.read(script.path), firefox_profile_sources(result).fetch(script.path)
    end
  end

  def test_vernier_run_without_embedded_sources
    with_script do |script|
      result = vernier_run("--no-embed-sources", "--", "ruby", script.path)
      assert_valid_firefox_profile(result.to_json)
      sources = firefox_profile_sources(result)
      assert_includes sources.keys, script.path
      assert sources.values.all?(&:nil?), "no source content should be embedded"
    end
  end

  def test_autorun_embeds_sources_by_default
    with_script do |script|
      result = run_vernier({}, script.path)
      assert_valid_firefox_profile(result.to_json)
      assert_equal File.read(script.path), firefox_profile_sources(result).fetch(script.path)
    end
  end

  def test_autorun_without_embedded_sources
    with_script do |script|
      result = run_vernier({embed_sources: false}, script.path)
      assert_valid_firefox_profile(result.to_json)
      assert_nil firefox_profile_sources(result).fetch(script.path)
    end
  end

  # A script which does enough work to be sampled, in a directory outside of
  # the project so its path appears unchanged in the profile.
  def with_script
    Tempfile.create(["vernier_script", ".rb"], File.realpath(Dir.tmpdir)) do |script|
      script.write(<<~RUBY)
        def busy_wait(seconds)
          target = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
          while Process.clock_gettime(Process::CLOCK_MONOTONIC) < target
          end
        end

        busy_wait(0.05)
      RUBY
      script.flush
      yield script
    end
  end

  # Explicitly call the "vernier run" executable
  def vernier_run(*argv)
    result_json = nil
    Tempfile.open('vernier') do |tempfile|
      system('vernier', 'run', '--output', tempfile.path, *argv, out: '/dev/null', err: '/dev/null')
      tempfile.rewind
      result_json = tempfile.read
    end
    result = JSON.parse(result_json)
    result
  end

  # Directly call autoload, mimicking the behaviour of vernier run
  def run_vernier(options, *argv)
    result_json = nil
    Tempfile.open('vernier') do |tempfile|
      options = {
        quiet: true,
        output: tempfile.path,
      }.merge(options)
      env = options.map do |k, v|
        ["VERNIER_#{k.to_s.upcase}", v.to_s]
      end.to_h
      system(env, RbConfig.ruby, "-I", LIB_DIR, "-r", "vernier/autorun", *argv, exception: true, out: '/dev/null', err: '/dev/null')
      tempfile.rewind
      result_json = tempfile.read
    end
    result = JSON.parse(result_json)
    result
  end
end
