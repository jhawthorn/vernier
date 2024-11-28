require "bundler/inline"
gemfile do
  source 'https://rubygems.org'

  gem "async"
end

require "async"
require "async/queue"

def measure
  x = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - x
end

def fib(n)
  if n < 2
    n
  else
    fib(n-2) + fib(n-1)
  end
end

# find fib that takes ~50ms
fib_i = 50.times.find { |i| measure { fib(i) } >= 0.05 }
sleep_i = measure { fib(fib_i) }

Async {
  latch = Async::Queue.new

  workers = [
    Async {
      latch.pop # block until ready to measure

      100.times {
        sleep(sleep_i)
        # stalls happen here. This worker wants to be scheduled so it can
        # continue the loop, but will be blocked by another worker executing fib
      }
    },
    Async {
      latch.pop # block until ready to measure

      100.times { fib(fib_i) }
    },
  ]

  2.times { latch << nil }
  workers.each(&:wait)
}
