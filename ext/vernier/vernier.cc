#include <iostream>
#include <iomanip>
#include <vector>
#include <memory>
#include <algorithm>
#include <sstream>
#include <unordered_map>
#include <unordered_set>
#include <cassert>
#include <atomic>
#include <mutex>
#include <optional>

#include <sys/time.h>
#include <signal.h>
#ifdef __APPLE__
#include <dispatch/dispatch.h>
#else
#include <semaphore.h>
#endif

#include "vernier.hh"
#include "stack.hh"

#include "ruby/ruby.h"
#include "ruby/debug.h"
#include "ruby/thread.h"

// GC event's we'll monitor during profiling
#define RUBY_GC_PHASE_EVENTS \
  RUBY_INTERNAL_EVENT_GC_START | \
  RUBY_INTERNAL_EVENT_GC_END_MARK | \
  RUBY_INTERNAL_EVENT_GC_END_SWEEP | \
  RUBY_INTERNAL_EVENT_GC_ENTER | \
  RUBY_INTERNAL_EVENT_GC_EXIT

#define sym(name) ID2SYM(rb_intern_const(name))

// HACK: This isn't public, but the objspace ext uses it
extern "C" size_t rb_obj_memsize_of(VALUE);

using namespace std;

static VALUE rb_mVernier;
static VALUE rb_cVernierResult;
static VALUE rb_mVernierMarkerType;
static VALUE rb_cVernierCollector;

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

    static TimeStamp Zero() {
        return TimeStamp(0);
    }

    static void Sleep(const TimeStamp &time) {
        struct timespec ts = time.timespec();

        int res;
        do {
            res = nanosleep(&ts, &ts);
        } while (res && errno == EINTR);
    }

    static TimeStamp from_microseconds(uint64_t us) {
        return TimeStamp(us * 1000);
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

std::ostream& operator<<(std::ostream& os, const TimeStamp& info) {
    os << info.nanoseconds() << "ns";
    return os;
}

// A basic semaphore built on sem_wait/sem_post
// post() is guaranteed to be async-signal-safe
class SamplerSemaphore {
#ifdef __APPLE__
    dispatch_semaphore_t sem;
#else
    sem_t sem;
#endif

    public:

    SamplerSemaphore(unsigned int value = 0) {
#ifdef __APPLE__
        sem = dispatch_semaphore_create(value);
#else
        sem_init(&sem, 0, value);
#endif
    };

    ~SamplerSemaphore() {
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
        int ret;
        do {
            ret = sem_wait(&sem);
        } while (ret && errno == EINTR);
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

struct RawSample {
    constexpr static int MAX_LEN = 2048;
    VALUE frames[MAX_LEN];
    int lines[MAX_LEN];
    int len;
    bool gc;

    RawSample() : len(0), gc(false) { }

    int size() const {
        return len;
    }

    Frame frame(int i) const {
        const Frame frame = {frames[i], lines[i]};
        return frame;
    }

    void sample() {
        if (!ruby_native_thread_p()) {
            clear();
            return;
        }

        if (rb_during_gc()) {
          gc = true;
          len = 0;
        } else {
          gc = false;
          len = rb_profile_frames(0, MAX_LEN, frames, lines);
        }
    }

    void clear() {
        len = 0;
        gc = false;
    }

    bool empty() const {
        return len == 0;
    }
};

// Based very loosely on the design of Gecko's SigHandlerCoordinator
// This is used for communication between the profiler thread and the signal
// handlers in the observed thread.
struct LiveSample {
    RawSample sample;

    SamplerSemaphore sem_complete;

    // Wait for a sample to be collected by the signal handler on another thread
    void wait() {
        sem_complete.wait();
    }

    int size() const {
        return sample.size();
    }

    Frame frame(int i) const {
        return sample.frame(i);
    }

    // Called from a signal handler in the observed thread in order to take a
    // sample and signal to the proifiler thread that the sample is ready.
    //
    // CRuby doesn't guarantee that rb_profile_frames can be used as
    // async-signal-safe but in practice it seems to be.
    // sem_post is safe in an async-signal-safe context.
    void sample_current_thread() {
        sample.sample();
        sem_complete.post();
    }
};

struct TraceArg {
    rb_trace_arg_t *tparg;
    VALUE obj;
    VALUE path;
    VALUE line;
    VALUE mid;
    VALUE klass;

    TraceArg(VALUE tpval) {
        tparg = rb_tracearg_from_tracepoint(tpval);
        obj = rb_tracearg_object(tparg);
        path = rb_tracearg_path(tparg);
        line = rb_tracearg_lineno(tparg);
        mid = rb_tracearg_method_id(tparg);
        klass = rb_tracearg_defined_class(tparg);
    }
};

struct FrameList {
    std::unordered_map<std::string, int> string_to_idx;
    std::vector<std::string> string_list;

    int string_index(const std::string str) {
        auto it = string_to_idx.find(str);
        if (it == string_to_idx.end()) {
            int idx = string_list.size();
            string_list.push_back(str);

            auto result = string_to_idx.insert({str, idx});
            it = result.first;
        }

        return it->second;
    }

    struct FrameWithInfo {
        Frame frame;
        FrameInfo info;
    };

    std::unordered_map<Frame, int> frame_to_idx;
    std::vector<Frame> frame_list;
    std::vector<FrameWithInfo> frame_with_info_list;
    int frame_index(const Frame frame) {
        auto it = frame_to_idx.find(frame);
        if (it == frame_to_idx.end()) {
            int idx = frame_list.size();
            frame_list.push_back(frame);
            auto result = frame_to_idx.insert({frame, idx});
            it = result.first;
        }
        return it->second;
    }

    struct StackNode {
        std::unordered_map<Frame, int> children;
        Frame frame;
        int parent;
        int index;

        StackNode(Frame frame, int index, int parent) : frame(frame), index(index), parent(parent) {}

        // root
        StackNode() : frame(Frame{0, 0}), index(-1), parent(-1) {}
    };

    StackNode root_stack_node;
    vector<StackNode> stack_node_list;

    int stack_index(const RawSample &stack) {
        if (stack.empty()) {
            throw std::runtime_error("empty stack");
        }

        StackNode *node = &root_stack_node;
        for (int i = stack.size() - 1; i >= 0; i--) {
            const Frame &frame = stack.frame(i);
            node = next_stack_node(node, frame);
        }
        return node->index;
    }

    StackNode *next_stack_node(StackNode *node, const Frame &frame) {
        int next_node_idx = node->children[frame];
        if (next_node_idx == 0) {
            // insert a new node
            next_node_idx = stack_node_list.size();
            node->children[frame] = next_node_idx;
            stack_node_list.emplace_back(
                    frame,
                    next_node_idx,
                    node->index
                    );
        }

        return &stack_node_list[next_node_idx];
    }

    // Converts Frames from stacks other tables. "Symbolicates" the frames
    // which allocates.
    void finalize() {
        for (const auto &stack_node : stack_node_list) {
            frame_index(stack_node.frame);
        }
        for (const auto &frame : frame_list) {
            frame_with_info_list.push_back(FrameWithInfo{frame, frame.info()});
        }
    }

    void mark_frames() {
        for (auto stack_node: stack_node_list) {
            rb_gc_mark(stack_node.frame.frame);
        }
    }

    void clear() {
        string_list.clear();
        frame_list.clear();
        stack_node_list.clear();
        frame_with_info_list.clear();

        string_to_idx.clear();
        frame_to_idx.clear();
        root_stack_node.children.clear();
    }

    void write_result(VALUE result) {
        FrameList &frame_list = *this;

        VALUE stack_table = rb_hash_new();
        rb_ivar_set(result, rb_intern("@stack_table"), stack_table);
        VALUE stack_table_parent = rb_ary_new();
        VALUE stack_table_frame = rb_ary_new();
        rb_hash_aset(stack_table, sym("parent"), stack_table_parent);
        rb_hash_aset(stack_table, sym("frame"), stack_table_frame);
        for (const auto &stack : frame_list.stack_node_list) {
            VALUE parent_val = stack.parent == -1 ? Qnil : INT2NUM(stack.parent);
            rb_ary_push(stack_table_parent, parent_val);
            rb_ary_push(stack_table_frame, INT2NUM(frame_list.frame_index(stack.frame)));
        }

        VALUE frame_table = rb_hash_new();
        rb_ivar_set(result, rb_intern("@frame_table"), frame_table);
        VALUE frame_table_func = rb_ary_new();
        VALUE frame_table_line = rb_ary_new();
        rb_hash_aset(frame_table, sym("func"), frame_table_func);
        rb_hash_aset(frame_table, sym("line"), frame_table_line);
        //for (const auto &frame : frame_list.frame_list) {
        for (int i = 0; i < frame_list.frame_with_info_list.size(); i++) {
            const auto &frame = frame_list.frame_with_info_list[i];
            rb_ary_push(frame_table_func, INT2NUM(i));
            rb_ary_push(frame_table_line, INT2NUM(frame.frame.line));
        }

        // TODO: dedup funcs before this step
        VALUE func_table = rb_hash_new();
        rb_ivar_set(result, rb_intern("@func_table"), func_table);
        VALUE func_table_name = rb_ary_new();
        VALUE func_table_filename = rb_ary_new();
        VALUE func_table_first_line = rb_ary_new();
        rb_hash_aset(func_table, sym("name"), func_table_name);
        rb_hash_aset(func_table, sym("filename"), func_table_filename);
        rb_hash_aset(func_table, sym("first_line"), func_table_first_line);
        for (const auto &frame : frame_list.frame_with_info_list) {
            const std::string label = frame.info.label;
            const std::string filename = frame.info.file;
            const int first_line = frame.info.first_lineno;

            rb_ary_push(func_table_name, rb_str_new(label.c_str(), label.length()));
            rb_ary_push(func_table_filename, rb_str_new(filename.c_str(), filename.length()));
            rb_ary_push(func_table_first_line, INT2NUM(first_line));
        }
    }
};

class BaseCollector {
    protected:

    virtual void reset() {
        frame_list.clear();
    }

    public:
    bool running = false;
    FrameList frame_list;

    virtual bool start() {
        if (running) {
            return false;
        } else {
            running = true;
            return true;
        }
    }

    virtual VALUE stop(VALUE self) {
        if (!running) {
            rb_raise(rb_eRuntimeError, "collector not running");
        }
        running = false;

        return Qnil;
    }

    virtual void sample() {
        rb_raise(rb_eRuntimeError, "collector doesn't support manual sampling");
    };

    virtual void mark() {
        frame_list.mark_frames();
    };
};

class CustomCollector : public BaseCollector {
    std::vector<int> samples;

    void sample() {
        RawSample sample;
        sample.sample();
        int stack_index = frame_list.stack_index(sample);

        samples.push_back(stack_index);
    }

    VALUE stop(VALUE self) {
        BaseCollector::stop(self);

        frame_list.finalize();

        VALUE result = build_collector_result(self);

        reset();

        return result;
    }

    VALUE build_collector_result(VALUE self) {
        VALUE result = rb_obj_alloc(rb_cVernierResult);

        VALUE samples = rb_ary_new();
        rb_ivar_set(result, rb_intern("@samples"), samples);
        VALUE weights = rb_ary_new();
        rb_ivar_set(result, rb_intern("@weights"), weights);

        for (auto& stack_index: this->samples) {
            rb_ary_push(samples, INT2NUM(stack_index));
            rb_ary_push(weights, INT2NUM(1));
        }

        frame_list.write_result(result);

        return result;
    }
};

class RetainedCollector : public BaseCollector {
    void reset() {
        object_frames.clear();
        object_list.clear();

        BaseCollector::reset();
    }

    void record(VALUE obj) {
        RawSample sample;
        sample.sample();
        int stack_index = frame_list.stack_index(sample);

        object_list.push_back(obj);
        object_frames.emplace(obj, stack_index);
    }

    std::unordered_map<VALUE, int> object_frames;
    std::vector<VALUE> object_list;

    VALUE tp_newobj = Qnil;
    VALUE tp_freeobj = Qnil;

    static void newobj_i(VALUE tpval, void *data) {
        RetainedCollector *collector = static_cast<RetainedCollector *>(data);
        TraceArg tp(tpval);

        collector->record(tp.obj);
    }

    static void freeobj_i(VALUE tpval, void *data) {
        RetainedCollector *collector = static_cast<RetainedCollector *>(data);
        TraceArg tp(tpval);

        collector->object_frames.erase(tp.obj);
    }

    public:

    bool start() {
        if (!BaseCollector::start()) {
            return false;
        }

        tp_newobj = rb_tracepoint_new(0, RUBY_INTERNAL_EVENT_NEWOBJ, newobj_i, this);
        tp_freeobj = rb_tracepoint_new(0, RUBY_INTERNAL_EVENT_FREEOBJ, freeobj_i, this);

        rb_tracepoint_enable(tp_newobj);
        rb_tracepoint_enable(tp_freeobj);

        return true;
    }

    VALUE stop(VALUE self) {
        BaseCollector::stop(self);

        // GC before we start turning stacks into strings
        rb_gc();

        // Stop tracking any more new objects, but we'll continue tracking free'd
        // objects as we may be able to free some as we remove our own references
        // to stack frames.
        rb_tracepoint_disable(tp_newobj);
        tp_newobj = Qnil;

        frame_list.finalize();

        // We should have collected info for all our frames, so no need to continue
        // marking them
        // FIXME: previously here we cleared the list of frames so we would stop
        // marking them. Maybe now we should set a flag so that we stop marking them

        // GC again
        rb_gc();

        rb_tracepoint_disable(tp_freeobj);
        tp_freeobj = Qnil;

        VALUE result = build_collector_result(self);

        reset();

        return result;
    }

    VALUE build_collector_result(VALUE self) {
        RetainedCollector *collector = this;
        FrameList &frame_list = collector->frame_list;

        VALUE result = rb_obj_alloc(rb_cVernierResult);

        VALUE samples = rb_ary_new();
        rb_ivar_set(result, rb_intern("@samples"), samples);
        VALUE weights = rb_ary_new();
        rb_ivar_set(result, rb_intern("@weights"), weights);

        for (auto& obj: collector->object_list) {
            const auto search = collector->object_frames.find(obj);
            if (search != collector->object_frames.end()) {
                int stack_index = search->second;

                rb_ary_push(samples, INT2NUM(stack_index));
                rb_ary_push(weights, INT2NUM(rb_obj_memsize_of(obj)));
            }
        }

        frame_list.write_result(result);

        return result;
    }

    void mark() {
        // We don't mark the objects, but we MUST mark the frames, otherwise they
        // can be garbage collected.
        // When we stop collection we will stringify the remaining frames, and then
        // clear them from the set, allowing them to be removed from out output.
        frame_list.mark_frames();

        rb_gc_mark(tp_newobj);
        rb_gc_mark(tp_freeobj);
    }
};

typedef uint64_t native_thread_id_t;

class Thread {
    public:
        static native_thread_id_t get_native_thread_id() {
#ifdef __APPLE__
            uint64_t thread_id;
            int e = pthread_threadid_np(pthread_self(), &thread_id);
            if (e != 0) rb_syserr_fail(e, "pthread_threadid_np");
            return thread_id;
#else
            return gettid();
#endif
        }

        enum State {
            STARTED,
            RUNNING,
            SUSPENDED,
            STOPPED
        };

        pthread_t pthread_id;
        native_thread_id_t native_tid;
        State state;

        TimeStamp state_changed_at;
        TimeStamp started_at;
        TimeStamp stopped_at;

        RawSample stack_on_suspend;

        std::string name;

        Thread(State state) : state(state) {
            pthread_id = pthread_self();
            native_tid = get_native_thread_id();
            started_at = state_changed_at = TimeStamp::Now();
        }

        void set_state(State new_state) {
            if (state == Thread::State::STOPPED) {
                return;
            }

            auto now = TimeStamp::Now();

            state = new_state;
            state_changed_at = now;
            if (new_state == State::STARTED) {
                started_at = now;
            } else if (new_state == State::STOPPED) {
                stopped_at = now;

                capture_name();
            }
        }

        bool running() {
            return state != State::STOPPED;
        }

        void capture_name() {
            char buf[128];
            int rc = pthread_getname_np(pthread_id, buf, sizeof(buf));
            if (rc == 0)
                name = std::string(buf);
        }
};

class Marker {
    public:
    enum Type {
        MARKER_GVL_THREAD_STARTED,
        MARKER_GVL_THREAD_READY,
        MARKER_GVL_THREAD_RESUMED,
        MARKER_GVL_THREAD_SUSPENDED,
        MARKER_GVL_THREAD_EXITED,

        MARKER_GC_START,
        MARKER_GC_END_MARK,
        MARKER_GC_END_SWEEP,
        MARKER_GC_ENTER,
        MARKER_GC_EXIT,

        MARKER_MAX,
    };
    Type type;
    TimeStamp timestamp;
    native_thread_id_t thread_id;
};

class MarkerTable {
    public:
        std::vector<Marker> list;
        std::mutex mutex;

        void record(Marker::Type type) {
            const std::lock_guard<std::mutex> lock(mutex);

            list.push_back({ type, TimeStamp::Now(), Thread::get_native_thread_id() });
        }
};

extern "C" int ruby_thread_has_gvl_p(void);

class ThreadTable {
    public:
        std::vector<Thread> list;
        std::mutex mutex;

        void started() {
            //const std::lock_guard<std::mutex> lock(mutex);

            //list.push_back(Thread{pthread_self(), Thread::State::SUSPENDED});
            set_state(Thread::State::STARTED);
        }

        void set_state(Thread::State new_state) {
            const std::lock_guard<std::mutex> lock(mutex);

            pthread_t current_thread = pthread_self();
            //cerr << "set state=" << new_state << " thread=" << gettid() << endl;

            for (auto &thread : list) {
                if (pthread_equal(current_thread, thread.pthread_id)) {
                    if (new_state == Thread::State::STARTED) {
                        throw std::runtime_error("started event on existing thread");
                    }

                    thread.set_state(new_state);

                    if (new_state == Thread::State::SUSPENDED) {
                        thread.stack_on_suspend.sample();
                        //cerr << gettid() << " suspended! Stack size:" << thread.stack_on_suspend.size() << endl;
                    }
                    return;
                }
            }

            pid_t native_tid = Thread::get_native_thread_id();
            list.emplace_back(new_state);
        }

        std::optional<pthread_t> get_active() {
            const std::lock_guard<std::mutex> lock(mutex);

            for (auto thread : list) {
                if (thread.state == Thread::State::RUNNING) {
                    cerr << "active thread=" << thread.pthread_id << endl;
                    return thread.pthread_id;
                }
            }
            cerr << "not found :(" << endl;

            return {};
        }
};

enum Category{
	CATEGORY_NORMAL,
	CATEGORY_IDLE
};

class TimeCollector : public BaseCollector {
    std::vector<int> samples;
    std::vector<TimeStamp> timestamps;
    std::vector<native_thread_id_t> sample_threads;
    std::vector<Category> sample_categories;

    MarkerTable markers;
    ThreadTable threads;

    pthread_t sample_thread;

    atomic_bool running;
    SamplerSemaphore thread_stopped;

    static inline LiveSample *live_sample;

    TimeStamp started_at;

    void record_sample(const RawSample &sample, TimeStamp time, const Thread &thread, Category category) {
        if (!sample.empty()) {
            int stack_index = frame_list.stack_index(sample);
            samples.push_back(stack_index);
            timestamps.push_back(time);
            sample_threads.push_back(thread.native_tid);
            sample_categories.push_back(category);
        }
    }

    static void signal_handler(int sig, siginfo_t* sinfo, void* ucontext) {
        assert(live_sample);
        live_sample->sample_current_thread();
    }

    void sample_thread_run() {
        LiveSample sample;
        live_sample = &sample;

        TimeStamp interval = TimeStamp::from_microseconds(500);
        TimeStamp next_sample_schedule = TimeStamp::Now();
        while (running) {
            TimeStamp sample_start = TimeStamp::Now();

            threads.mutex.lock();
            for (auto thread : threads.list) {
                //if (thread.state == Thread::State::RUNNING) {
                if (thread.state == Thread::State::RUNNING || (thread.state == Thread::State::SUSPENDED && thread.stack_on_suspend.size() == 0)) {
                    if (pthread_kill(thread.pthread_id, SIGPROF)) {
                        rb_bug("pthread_kill failed");
                    }
                    sample.wait();

                    if (sample.sample.gc) {
                        // fprintf(stderr, "skipping GC sample\n");
                    } else {
                        record_sample(sample.sample, sample_start, thread, CATEGORY_NORMAL);
                    }
                } else if (thread.state == Thread::State::SUSPENDED) {
                    record_sample(thread.stack_on_suspend, sample_start, thread, CATEGORY_IDLE);
                } else {
                }
            }
            threads.mutex.unlock();

            TimeStamp sample_complete = TimeStamp::Now();

            next_sample_schedule += interval;
            TimeStamp sleep_time = next_sample_schedule - sample_complete;
            TimeStamp::Sleep(sleep_time);
        }

        live_sample = NULL;

        thread_stopped.post();
    }

    static void *sample_thread_entry(void *arg) {
        TimeCollector *collector = static_cast<TimeCollector *>(arg);
        collector->sample_thread_run();
        return NULL;
    }

    static void internal_gc_event_cb(VALUE tpval, void *data) {
        TimeCollector *collector = static_cast<TimeCollector *>(data);
        rb_trace_arg_t *tparg = rb_tracearg_from_tracepoint(tpval);
        int event = rb_tracearg_event_flag(tparg);

        switch (event) {
            case RUBY_INTERNAL_EVENT_GC_START:
                collector->markers.record(Marker::Type::MARKER_GC_START);
                break;
            case RUBY_INTERNAL_EVENT_GC_END_MARK:
                collector->markers.record(Marker::Type::MARKER_GC_END_MARK);
                break;
            case RUBY_INTERNAL_EVENT_GC_END_SWEEP:
                collector->markers.record(Marker::Type::MARKER_GC_END_SWEEP);
                break;
            case RUBY_INTERNAL_EVENT_GC_ENTER:
                collector->markers.record(Marker::Type::MARKER_GC_ENTER);
                break;
            case RUBY_INTERNAL_EVENT_GC_EXIT:
                collector->markers.record(Marker::Type::MARKER_GC_EXIT);
                break;
        }
    }

    static void internal_thread_event_cb(rb_event_flag_t event, const rb_internal_thread_event_data_t *event_data, void *data) {
        TimeCollector *collector = static_cast<TimeCollector *>(data);
        //cerr << "internal thread event" << event << " at " << TimeStamp::Now() << endl;

        switch (event) {
            case RUBY_INTERNAL_THREAD_EVENT_STARTED:
                collector->markers.record(Marker::Type::MARKER_GVL_THREAD_STARTED);
                collector->threads.started();
                break;
            case RUBY_INTERNAL_THREAD_EVENT_READY:
                collector->markers.record(Marker::Type::MARKER_GVL_THREAD_READY);
                break;
            case RUBY_INTERNAL_THREAD_EVENT_RESUMED:
                collector->markers.record(Marker::Type::MARKER_GVL_THREAD_RESUMED);
                collector->threads.set_state(Thread::State::RUNNING);
                break;
            case RUBY_INTERNAL_THREAD_EVENT_SUSPENDED:
                collector->markers.record(Marker::Type::MARKER_GVL_THREAD_SUSPENDED);
                collector->threads.set_state(Thread::State::SUSPENDED);
                break;
            case RUBY_INTERNAL_THREAD_EVENT_EXITED:
                collector->markers.record(Marker::Type::MARKER_GVL_THREAD_EXITED);
                collector->threads.set_state(Thread::State::STOPPED);
                break;

        }
    }

    rb_internal_thread_event_hook_t *thread_hook;
    VALUE gc_hook;

    bool start() {
        if (!BaseCollector::start()) {
            return false;
        }

	started_at = TimeStamp::Now();

        struct sigaction sa;
        sa.sa_sigaction = signal_handler;
        sa.sa_flags = SA_RESTART | SA_SIGINFO;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGPROF, &sa, NULL);

        running = true;

        int ret = pthread_create(&sample_thread, NULL, &sample_thread_entry, this);
        if (ret != 0) {
            perror("pthread_create");
            rb_bug("pthread_create");
        }

        // Set the state of the current Ruby thread to RUNNING.
        // We want to have at least one thread in our thread list because it's
        // possible that the profile might be such that we don't get any
        // thread switch events and we need at least one
        this->threads.set_state(Thread::State::RUNNING);

        thread_hook = rb_internal_thread_add_event_hook(internal_thread_event_cb, RUBY_INTERNAL_THREAD_EVENT_MASK, this);
        gc_hook = rb_tracepoint_new(0, RUBY_GC_PHASE_EVENTS, internal_gc_event_cb, (void *)this);
        rb_tracepoint_enable(gc_hook);

        return true;
    }

    VALUE stop(VALUE self) {
        BaseCollector::stop(self);

        running = false;
        thread_stopped.wait();

        struct sigaction sa;
        sa.sa_handler = SIG_IGN;
        sa.sa_flags = SA_RESTART;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGPROF, &sa, NULL);

        rb_internal_thread_remove_event_hook(thread_hook);
        rb_tracepoint_disable(gc_hook);

        // capture thread names
        for (auto& thread: this->threads.list) {
            if (thread.running()) {
                thread.capture_name();
            }
        }

        frame_list.finalize();

        VALUE result = build_collector_result(self);

        reset();

        return result;
    }

    VALUE build_collector_result(VALUE self) {
        VALUE result = rb_obj_alloc(rb_cVernierResult);

        VALUE meta = rb_hash_new();
        rb_ivar_set(result, rb_intern("@meta"), meta);
        rb_hash_aset(meta, sym("started_at"), ULL2NUM(started_at.nanoseconds()));

        VALUE samples = rb_ary_new();
        rb_ivar_set(result, rb_intern("@samples"), samples);
        VALUE weights = rb_ary_new();
        rb_ivar_set(result, rb_intern("@weights"), weights);
        for (auto& stack_index: this->samples) {
            rb_ary_push(samples, INT2NUM(stack_index));
            rb_ary_push(weights, INT2NUM(1));
        }

        VALUE timestamps = rb_ary_new();
        rb_ivar_set(result, rb_intern("@timestamps"), timestamps);

        for (auto& timestamp: this->timestamps) {
            rb_ary_push(timestamps, ULL2NUM(timestamp.nanoseconds()));
        }

        VALUE sample_threads = rb_ary_new();
        rb_ivar_set(result, rb_intern("@sample_threads"), sample_threads);
        for (auto& thread: this->sample_threads) {
            rb_ary_push(sample_threads, ULL2NUM(thread));
        }

        VALUE sample_categories = rb_ary_new();
        rb_ivar_set(result, rb_intern("@sample_categories"), sample_categories);
        for (auto& cat: this->sample_categories) {
            rb_ary_push(sample_categories, INT2NUM(cat));
        }

        VALUE marker_timestamps = rb_ary_new();
        VALUE marker_threads = rb_ary_new();
        VALUE marker_ids = rb_ary_new();
        rb_ivar_set(result, rb_intern("@marker_timestamps"), marker_timestamps);
        rb_ivar_set(result, rb_intern("@marker_threads"), marker_threads);
        rb_ivar_set(result, rb_intern("@marker_strings"), rb_ivar_get(self, rb_intern("@marker_strings")));
        rb_ivar_set(result, rb_intern("@marker_ids"), marker_ids);
        for (auto& marker: this->markers.list) {
            rb_ary_push(marker_timestamps, ULL2NUM(marker.timestamp.nanoseconds()));
            rb_ary_push(marker_ids, INT2NUM(marker.type));
            rb_ary_push(marker_threads, ULL2NUM(marker.thread_id));
        }

        VALUE threads = rb_hash_new();
        rb_ivar_set(result, rb_intern("@threads"), threads);

        for (const auto& thread: this->threads.list) {
            VALUE hash = rb_hash_new();
            rb_hash_aset(threads, ULL2NUM(thread.native_tid), hash);
            rb_hash_aset(hash, sym("tid"), ULL2NUM(thread.native_tid));
            rb_hash_aset(hash, sym("started_at"), ULL2NUM(thread.started_at.nanoseconds()));
            if (!thread.stopped_at.zero()) {
                rb_hash_aset(hash, sym("stopped_at"), ULL2NUM(thread.stopped_at.nanoseconds()));
            }
            rb_hash_aset(hash, sym("name"), rb_str_new(thread.name.data(), thread.name.length()));

        }

        frame_list.write_result(result);

        return result;
    }

    void mark() {
        frame_list.mark_frames();
        rb_gc_mark(gc_hook);

        //for (int i = 0; i < queued_length; i++) {
        //    rb_gc_mark(queued_frames[i]);
        //}

        // FIXME: How can we best mark buffered or pending frames?
    }
};

static void
collector_mark(void *data) {
    BaseCollector *collector = static_cast<BaseCollector *>(data);
    collector->mark();
}

static void
collector_free(void *data) {
    BaseCollector *collector = static_cast<BaseCollector *>(data);
    delete collector;
}

static const rb_data_type_t rb_collector_type = {
    .wrap_struct_name = "vernier/collector",
    .function = {
        //.dmemsize = rb_collector_memsize,
        .dmark = collector_mark,
        .dfree = collector_free,
    },
};

static BaseCollector *get_collector(VALUE obj) {
    BaseCollector *collector;
    TypedData_Get_Struct(obj, BaseCollector, &rb_collector_type, collector);
    return collector;
}

static VALUE
collector_start(VALUE self) {
    auto *collector = get_collector(self);

    if (!collector->start()) {
        rb_raise(rb_eRuntimeError, "already running");
    }

    return Qtrue;
}

static VALUE
collector_stop(VALUE self) {
    auto *collector = get_collector(self);

    VALUE result = collector->stop(self);
    return result;
}

static VALUE
collector_sample(VALUE self) {
    auto *collector = get_collector(self);

    collector->sample();
    return Qtrue;
}

static VALUE collector_new(VALUE self, VALUE mode) {
    BaseCollector *collector;
    if (mode == sym("retained")) {
        collector = new RetainedCollector();
    } else if (mode == sym("custom")) {
        collector = new CustomCollector();
    } else if (mode == sym("wall")) {
        collector = new TimeCollector();
    } else {
        rb_raise(rb_eArgError, "invalid mode");
    }
    VALUE obj = TypedData_Wrap_Struct(self, &rb_collector_type, collector);
    rb_funcall(obj, rb_intern("initialize"), 1, mode);
    return obj;
}

static void
Init_consts() {
#define MARKER_CONST(name) \
    rb_define_const(rb_mVernierMarkerType, #name, INT2NUM(Marker::Type::MARKER_##name))

    MARKER_CONST(GVL_THREAD_STARTED);
    MARKER_CONST(GVL_THREAD_READY);
    MARKER_CONST(GVL_THREAD_RESUMED);
    MARKER_CONST(GVL_THREAD_SUSPENDED);
    MARKER_CONST(GVL_THREAD_EXITED);

    MARKER_CONST(GC_START);
    MARKER_CONST(GC_END_MARK);
    MARKER_CONST(GC_END_SWEEP);
    MARKER_CONST(GC_ENTER);
    MARKER_CONST(GC_EXIT);

#undef MARKER_CONST
}

extern "C" void
Init_vernier(void)
{
  rb_mVernier = rb_define_module("Vernier");
  rb_cVernierResult = rb_define_class_under(rb_mVernier, "Result", rb_cObject);
  VALUE rb_mVernierMarker = rb_define_module_under(rb_mVernier, "Marker");
  rb_mVernierMarkerType = rb_define_module_under(rb_mVernierMarker, "Type");

  rb_cVernierCollector = rb_define_class_under(rb_mVernier, "Collector", rb_cObject);
  rb_undef_alloc_func(rb_cVernierCollector);
  rb_define_singleton_method(rb_cVernierCollector, "new", collector_new, 1);
  rb_define_method(rb_cVernierCollector, "start", collector_start, 0);
  rb_define_method(rb_cVernierCollector, "stop",  collector_stop, 0);
  rb_define_method(rb_cVernierCollector, "sample", collector_sample, 0);

  Init_consts();

  //static VALUE gc_hook = Data_Wrap_Struct(rb_cObject, collector_mark, NULL, &_collector);
  //rb_global_variable(&gc_hook);
}
