module Vernier
  class Middleware
    def initialize(app, permit: ->(_) { true })
      @app = app
      @permit = permit
    end

    def call(env)
      return @app.call(env) unless request.GET.has_key?("vernier")

      request = Rack::Request.new(env)
      permitted = @permit.call(request)
      return @app.call(env) unless permitted

      result = Vernier.trace(interval: 200, allocation_sample_rate: 100, hooks: [:rails]) do
        @app.call(env)
      end
      body = result.to_gecko
      filename = "#{request.path.gsub("/", "_")}_#{DateTime.now.strftime("%Y-%m-%d-%H-%M-%S")}.vernier.json"
      headers = {
        "Content-Type" => "application/json; charset=utf-8",
        "Content-Disposition" => "attachment; filename=\"#{filename}\"",
        "Content-Length" => body.bytesize.to_s
      }

      Rack::Response.new(body, 200, headers).finish
    end
  end
end
