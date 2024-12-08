#ifndef TIMESTAMP_HH
#define TIMESTAMP_HH

#include <iostream>
#include <stdint.h>
#include <sys/time.h>
#include <unistd.h>

class TimeStamp {
    static const uint64_t nanoseconds_per_second = 1000000000;
    uint64_t value_ns;

    TimeStamp(uint64_t value_ns) : value_ns(value_ns) {}

    public:
    TimeStamp() : value_ns(0) {}

    static TimeStamp Now() {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        return TimeStamp(ts.tv_sec * nanoseconds_per_second + ts.tv_nsec);
    }

    static TimeStamp NowRealtime() {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        return TimeStamp(ts.tv_sec * nanoseconds_per_second + ts.tv_nsec);
    }

    static TimeStamp Zero() {
        return TimeStamp(0);
    }

    // SleepUntil a specified timestamp
    // Highly accurate manual sleep time
    static void SleepUntil(const TimeStamp &target_time) {
        if (target_time.zero()) return;
        struct timespec ts = target_time.timespec();

        int res;
        do {
            // do nothing until it's time :)
            sleep(0);
        } while (target_time > TimeStamp::Now());
    }

    static TimeStamp from_seconds(uint64_t s) {
        return TimeStamp::from_milliseconds(s * 1000);
    }

    static TimeStamp from_milliseconds(uint64_t ms) {
        return TimeStamp::from_microseconds(ms * 1000);
    }

    static TimeStamp from_microseconds(uint64_t us) {
        return TimeStamp::from_nanoseconds(us * 1000);
    }

    static TimeStamp from_nanoseconds(uint64_t ns) {
        return TimeStamp(ns);
    }

    TimeStamp operator-(const TimeStamp &other) const {
        TimeStamp result = *this;
        return result -= other;
    }

    TimeStamp &operator-=(const TimeStamp &other) {
        if (value_ns > other.value_ns) {
            value_ns = value_ns - other.value_ns;
        } else {
            // underflow
            value_ns = 0;
        }
        return *this;
    }

    TimeStamp operator+(const TimeStamp &other) const {
        TimeStamp result = *this;
        return result += other;
    }

    TimeStamp &operator+=(const TimeStamp &other) {
        uint64_t new_value = value_ns + other.value_ns;
        value_ns = new_value;
        return *this;
    }

    bool operator<(const TimeStamp &other) const {
        return value_ns < other.value_ns;
    }

    bool operator<=(const TimeStamp &other) const {
        return value_ns <= other.value_ns;
    }

    bool operator>(const TimeStamp &other) const {
        return value_ns > other.value_ns;
    }

    bool operator>=(const TimeStamp &other) const {
        return value_ns >= other.value_ns;
    }

    bool operator==(const TimeStamp &other) const {
        return value_ns == other.value_ns;
    }

    bool operator!=(const TimeStamp &other) const {
        return value_ns != other.value_ns;
    }

    uint64_t nanoseconds() const {
        return value_ns;
    }

    uint64_t microseconds() const {
        return value_ns / 1000;
    }

    bool zero() const {
        return value_ns == 0;
    }

    struct timespec timespec() const {
        struct timespec ts;
        ts.tv_sec = nanoseconds() / nanoseconds_per_second;
        ts.tv_nsec = (nanoseconds() % nanoseconds_per_second);
        return ts;
    }
};

inline std::ostream& operator<<(std::ostream& os, const TimeStamp& info) {
    os << info.nanoseconds() << "ns";
    return os;
}

#endif
