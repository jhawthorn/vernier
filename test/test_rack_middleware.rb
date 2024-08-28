# frozen_string_literal: true

require "test_helper"
require "firefox_test_helpers"

require "rack"

class TestOutputFirefox < Minitest::Test
  include FirefoxTestHelpers

  def test_middleware_disabled
    app = lambda { |env| [200, { 'content-type' => 'text/plain' }, ["Hello, World!"]] }
    response = build_app(app).call(request)
    assert_equal ["Hello, World!"], response[2].to_enum.to_a
  end

  def test_middleware_enabled
    app = lambda { |env| [200, { 'content-type' => 'text/plain' }, ["Hello, World!"]] }
    response = build_app(app).call(request(params: { vernier: 1 }))
    status, headers, body = response
    assert_equal 200, status
    assert_equal "application/octet-stream", headers["content-type"]
    assert_match(/\Aattachment; filename="/, headers["content-disposition"])

    profile_gzip = body.to_enum.to_a[0]
    profile_json = Zlib.gunzip(profile_gzip)
    assert_valid_firefox_profile(profile_json)
  end

  private

  def build_app(...)
    Rack::Lint.new(Vernier::Middleware.new(...))
  end

  def request(opts = {})
    Rack::MockRequest.env_for("", opts)
  end
end
