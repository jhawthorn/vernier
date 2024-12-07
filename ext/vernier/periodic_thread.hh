#include "ruby.h"

#include <atomic>
#include "timestamp.hh"

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

