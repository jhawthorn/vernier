#include "ruby.h"

#include <atomic>
#include "timestamp.hh"

class PeriodicThread {
    std::atomic_bool running;
    pthread_t pthread;
    TimeStamp interval;

    public:
        PeriodicThread(TimeStamp interval) : interval(interval), running(false) {
        }

        void set_interval(TimeStamp timestamp) {
            interval = timestamp;
        }

        static void *thread_entrypoint(void *arg) {
            static_cast<PeriodicThread *>(arg)->run();
            return NULL;
        }

        void run() {
#if HAVE_PTHREAD_SETNAME_NP
#ifdef __APPLE__
        pthread_setname_np("Vernier profiler");
#else
        pthread_setname_np(pthread_self(), "Vernier profiler");
#endif
#endif

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
            pthread_join(pthread, NULL);
        }
};

