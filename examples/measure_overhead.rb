require "benchmark/ips"
require "vernier"

def compare(**options, &block)
  block.call

  Benchmark.ips do |x|
    x.report "no profiler" do |n|
      n.times do
        block.call
      end
    end

    x.report "vernier" do |n|
      Vernier.profile(**options) do
        n.times do
          block.call
        end
      end
    end

    x.compare!
  end
end

compare do
  i = 0
  while i < 10_000
    i += 1
  end
end

compare(allocation_sample_rate: 1000) do
  Object.new
end

compare(allocation_sample_rate: 1) do
  Object.new
end
