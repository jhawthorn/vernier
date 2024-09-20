module Vernier
  class Middleware
    def initialize(app, permit: ->(_) { true })
      @app = app
      @permit = permit
    end

    def call(env)
      request = Rack::Request.new(env)
      return @app.call(env) unless request.GET.has_key?("vernier")

      permitted = @permit.call(request)
      return @app.call(env) unless permitted

      interval = request.GET.fetch("vernier_interval", 200).to_i
      allocation_interval = request.GET.fetch("vernier_allocation_interval", 200).to_i

      result = Vernier.trace(interval:, allocation_interval:, hooks: [:rails]) do
        @app.call(env)
      end
      body = result.to_gecko(gzip: true)
      filename = "#{request.path.gsub("/", "_")}_#{DateTime.now.strftime("%Y-%m-%d-%H-%M-%S")}.vernier.json.gz"
      headers = {
        "Content-Type" => "application/octet-stream",
        "Content-Disposition" => "attachment; filename=\"#{filename}\"",
        "Content-Length" => body.bytesize.to_s
      }

      Rack::Response.new(body, 200, headers).finish
    end
  end
end
