#ifdef __APPLE__

#include <vector>
#include <stdio.h>

// Based loosely on https://github.com/zombocom/get_process_mem
#include <libproc.h>
#include <unistd.h>

#include "vernier.hh"

inline uint64_t memory_rss() {
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

#else

// Assume linux for now
inline uint64_t memory_rss() {
    // TODO: read /proc/self/statm
    return 0;
}

#endif

VALUE rb_cMemoryTracker;

static VALUE rb_memory_rss(VALUE self) {
    return ULL2NUM(memory_rss());
}

class MemoryTracker {
    public:
        struct Record {
            uint64_t memory_rss;
        };
        std::vector<Record> results;

        void start() {
        }

        void stop() {
        }

        void record() {
            results.push_back(Record{memory_rss()});
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
    VALUE arr = rb_ary_new();
    for (const auto& record: memory_tracker->results) {
        rb_ary_push(arr, ULL2NUM(record.memory_rss));
    }
    return arr;
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
