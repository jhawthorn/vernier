# Different (bad) ways to sleep

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'

  gem "gvltest"
end

def cfunc_sleep_gvl
  GVLTest.sleep_holding_gvl(1)
end

def cfunc_sleep_idle
  GVLTest.sleep_without_gvl(1)
end

def ruby_sleep_gvl
  target = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) + 1000
  while Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) < target
    i = 0
    while i < 1000
      i += 1
    end
  end
end

def sleep_idle
  sleep 1
end

def run(name)
  STDOUT.print "#{name}..."
  STDOUT.flush

  before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  send(name)
  after = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  STDOUT.puts " %.2fs" % (after - before)
end

run(:cfunc_sleep_gvl)
run(:cfunc_sleep_idle)
run(:ruby_sleep_gvl)
run(:sleep_idle)
