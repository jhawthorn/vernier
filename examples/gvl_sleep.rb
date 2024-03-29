# Different (bad) ways to sleep

File.write("#{__dir__}/my_sleep.c", <<~EOF)
#include <time.h>
#include <sys/errno.h>

void my_sleep() {
  struct timespec ts;
  ts.tv_sec = 1;
  ts.tv_nsec = 0;

  int rc;
  do {
    rc = nanosleep(&ts, &ts);
  } while (rc < 0 && errno == EINTR);
}
EOF

soext = RbConfig::CONFIG["SOEXT"]
system("gcc", "-shared", "-fPIC", "#{__dir__}/my_sleep.c", "-o", "#{__dir__}/my_sleep.#{soext}")

require "fiddle"

SLEEP_LIB = Fiddle.dlopen("./my_sleep.#{soext}")

def cfunc_sleep_gvl
  Fiddle::Function.new(SLEEP_LIB['my_sleep'], [], Fiddle::TYPE_VOID, need_gvl: true).call
end

def cfunc_sleep_idle
  Fiddle::Function.new(SLEEP_LIB['my_sleep'], [], Fiddle::TYPE_VOID, need_gvl: true).call
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
