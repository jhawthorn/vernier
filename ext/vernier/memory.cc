#ifdef __APPLE__

#include <vector>
#include <stdio.h>

// Based loosely on https://github.com/zombocom/get_process_mem
#include <libproc.h>
#include <unistd.h>

#include "vernier.hh"
#include "timestamp.hh"

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

class PeriodicThread {
    std::atomic<bool> running;
    pthread_t pthread;
    TimeStamp interval;

    public:
        PeriodicThread() : interval(TimeStamp::from_milliseconds(10)) {
        }

        void set_interval(TimeStamp timestamp) {
            interval = timestamp;
        }

        static void *thread_entrypoint(void *arg) {
            static_cast<PeriodicThread *>(arg)->run();
            return NULL;
        }

        void run() {
            TimeStamp next_sample_schedule = TimeStamp::Now();
            while (running) {
                TimeStamp sample_complete = TimeStamp::Now();

                run_iteration();

                next_sample_schedule += interval;

                if (next_sample_schedule < sample_complete) {
                    next_sample_schedule = sample_complete + interval;
                }

                TimeStamp::SleepUntil(next_sample_schedule);
            }
        }

        virtual void run_iteration() = 0;

        void start() {
            if (running) return;

            running = true;

            int ret = pthread_create(&pthread, NULL, &thread_entrypoint, this);
            if (ret != 0) {
                perror("pthread_create");
                rb_bug("VERNIER: pthread_create failed");
            }
        }

        void stop() {
            if (!running) return;

            running = false;
        }
};

class MemoryTracker : public PeriodicThread {
    public:
        struct Record {
            TimeStamp timestamp;
            uint64_t memory_rss;
        };
        std::vector<Record> results;
        std::mutex mutex;

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
