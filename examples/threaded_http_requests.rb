require "vernier"

Vernier.trace(out: "http_requests.json", allocation_sample_rate: 100) do

require "net/http"
require "uri"
require "openssl"

urls = Queue.new
received = Queue.new

threads = 2.times.map do
  Thread.new do
    while url = urls.pop
      uri = URI.parse(url)
      response = Net::HTTP.get_response(uri)

      received << [url, response.code]
    end
  end
end

Thread.new do
  threads.each(&:join)
  received.close
end

urls << "http://example.com"
urls << "https://www.johnhawthorn.com"
urls << "https://tenderlovemaking.com/"
urls.close

while x = received.pop
  url, code = *x
  puts "#{url} #{code}"
end

end
