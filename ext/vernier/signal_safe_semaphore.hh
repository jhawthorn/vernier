#ifndef SIGNAL_SAFE_SEMAPHORE_HH
#define SIGNAL_SAFE_SEMAPHORE_HH

#if defined(__APPLE__)
/* macOS */
#include <dispatch/dispatch.h>
#elif defined(__FreeBSD__)
/* FreeBSD */
#include <pthread_np.h>
#include <semaphore.h>
#else
/* Linux */
#include <semaphore.h>
#include <sys/syscall.h> /* for SYS_gettid */
#endif

// A basic semaphore built on sem_wait/sem_post
// post() is guaranteed to be async-signal-safe
class SignalSafeSemaphore {
#ifdef __APPLE__
    dispatch_semaphore_t sem;
#else
    sem_t sem;
#endif

    public:

    SignalSafeSemaphore(unsigned int value = 0) {
#ifdef __APPLE__
        sem = dispatch_semaphore_create(value);
#else
        sem_init(&sem, 0, value);
#endif
    };

    ~SignalSafeSemaphore() {
#ifdef __APPLE__
        dispatch_release(sem);
#else
        sem_destroy(&sem);
#endif
    };

    void wait() {
#ifdef __APPLE__
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
#else
        // Use sem_timedwait so that we get a crash instead of a deadlock for
        // easier debugging
        struct timespec ts = (TimeStamp::NowRealtime() + TimeStamp::from_seconds(5)).timespec();

        int ret;
        do {
            ret = sem_timedwait(&sem, &ts);
        } while (ret && errno == EINTR);
        if (ret != 0) {
            rb_bug("VERNIER: sem_timedwait waited over 5 seconds");
        }
        assert(ret == 0);
#endif
    }

    void post() {
#ifdef __APPLE__
        dispatch_semaphore_signal(sem);
#else
        sem_post(&sem);
#endif
    }
};

#endif
