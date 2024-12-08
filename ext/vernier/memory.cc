#include <mutex>
#include <stdio.h>
#include <unistd.h>
#include <vector>

#include "vernier.hh"
#include "timestamp.hh"
#include "periodic_thread.hh"

#if defined(__APPLE__)

// Based loosely on https://github.com/zombocom/get_process_mem
#include <libproc.h>

uint64_t memory_rss() {
    pid_t pid = getpid();

    struct proc_taskinfo tinfo;
    int st = proc_pidinfo(pid, PROC_PIDTASKINFO, 0,
                         &tinfo, sizeof(tinfo));

    if (st != sizeof(tinfo)) {
        fprintf(stderr, "VERNIER: warning: proc_pidinfo failed\n");
        return 0;
    }

    return tinfo.pti_resident_size;
}

#elif defined(__linux__)

uint64_t memory_rss() {
    long rss = 0;

    // I'd heard that you shouldn't read /proc/*/smaps with fopen and family,
    // but maybe it's fine for statm which is much smaller and will almost
    // certainly fit in any internal buffer.
    FILE *file = fopen("/proc/self/statm", "r");
    if (!file) return 0;
    if (fscanf(file, "%*s%ld", &rss) != 1) {
        fclose(file);
        return 0;
    }
    fclose(file);
    return rss * sysconf(_SC_PAGESIZE);
}

#else

// Unsupported
uint64_t memory_rss() {
    return 0;
}

#endif

VALUE rb_cMemoryTracker;

static VALUE rb_memory_rss(VALUE self) {
    return ULL2NUM(memory_rss());
}

class MemoryTracker : public PeriodicThread {
    public:
        struct Record {
            TimeStamp timestamp;
            uint64_t memory_rss;
        };
        std::vector<Record> results;
        std::mutex mutex;

        MemoryTracker() : PeriodicThread(TimeStamp::from_milliseconds(10)) {
        }

        void run_iteration() {
            record();
        }

        void record() {
            const std::lock_guard<std::mutex> lock(mutex);
            results.push_back(Record{TimeStamp::Now(), memory_rss()});
        }
};

static const rb_data_type_t rb_memory_tracker_type = {
    .wrap_struct_name = "vernier/memory_tracker",
    .function = {
        //.dmemsize = memory_tracker_memsize,
        //.dmark = memory_tracker_mark,
        //.dfree = memory_tracker_free,
    },
};

VALUE memory_tracker_start(VALUE self) {
    MemoryTracker *memory_tracker;
    TypedData_Get_Struct(self, MemoryTracker, &rb_memory_tracker_type, memory_tracker);
    memory_tracker->start();
    return self;
}

VALUE memory_tracker_stop(VALUE self) {
    MemoryTracker *memory_tracker;
    TypedData_Get_Struct(self, MemoryTracker, &rb_memory_tracker_type, memory_tracker);

    memory_tracker->stop();
    return self;
}

VALUE memory_tracker_record(VALUE self) {
    MemoryTracker *memory_tracker;
    TypedData_Get_Struct(self, MemoryTracker, &rb_memory_tracker_type, memory_tracker);
    memory_tracker->record();
    return self;
}

VALUE memory_tracker_results(VALUE self) {
    MemoryTracker *memory_tracker;
    TypedData_Get_Struct(self, MemoryTracker, &rb_memory_tracker_type, memory_tracker);
    VALUE timestamps = rb_ary_new();
    VALUE memory = rb_ary_new();
    for (const auto& record: memory_tracker->results) {
        rb_ary_push(timestamps, ULL2NUM(record.timestamp.nanoseconds()));
        rb_ary_push(memory, ULL2NUM(record.memory_rss));
    }
    return rb_ary_new_from_args(2, timestamps, memory);
}

VALUE memory_tracker_alloc(VALUE self) {
    auto memory_tracker = new MemoryTracker();
    VALUE obj = TypedData_Wrap_Struct(self, &rb_memory_tracker_type, memory_tracker);
    return obj;
}

void Init_memory() {
  rb_cMemoryTracker = rb_define_class_under(rb_mVernier, "MemoryTracker", rb_cObject);
  rb_define_alloc_func(rb_cMemoryTracker, memory_tracker_alloc);

  rb_define_method(rb_cMemoryTracker, "start", memory_tracker_start, 0);
  rb_define_method(rb_cMemoryTracker, "stop", memory_tracker_stop, 0);
  rb_define_method(rb_cMemoryTracker, "results", memory_tracker_results, 0);
  rb_define_method(rb_cMemoryTracker, "record", memory_tracker_record, 0);

  rb_define_singleton_method(rb_mVernier, "memory_rss", rb_memory_rss, 0);
}
