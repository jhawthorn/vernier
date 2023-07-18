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

#include <sys/time.h>
#include <signal.h>
#include <semaphore.h>

#include "vernier.hh"
#include "stack.hh"

#include "ruby/debug.h"
#include "ruby/thread.h"

#define sym(name) ID2SYM(rb_intern_const(name))

// HACK: This isn't public, but the objspace ext uses it
extern "C" size_t rb_obj_memsize_of(VALUE);

using namespace std;

static VALUE rb_mVernier;
static VALUE rb_cVernierResult;
static VALUE rb_cVernierCollector;

class TimeStamp {
    static const uint64_t nanoseconds_per_second = 1000000000;
    uint64_t value_ns;

    TimeStamp(uint64_t value_ns) : value_ns(value_ns) {}

    public:
    static TimeStamp Now() {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        return TimeStamp(ts.tv_sec * nanoseconds_per_second + ts.tv_nsec);
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
    sem_t sem;

    public:

    SamplerSemaphore(unsigned int value = 0) {
        sem_init(&sem, 0, value);
    };

    ~SamplerSemaphore() {
        sem_destroy(&sem);
    };

    void wait() {
        int ret;
        do {
            ret = sem_wait(&sem);
        } while (ret && errno == EINTR);
        assert(ret == 0);
    }

    void post() {
        sem_post(&sem);
    }
};

struct RawSample {
    constexpr static int MAX_LEN = 2048;
    VALUE frames[MAX_LEN];
    int lines[MAX_LEN];
    int len;

    int size() const {
        return len;
    }

    Frame frame(int i) const {
        const Frame frame = {frames[i], lines[i]};
        return frame;
    }

    void sample() {
        assert(!len);
        len = rb_profile_frames(0, MAX_LEN, frames, lines);
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
        StackNode *node = &root_stack_node;
        //for (int i = 0; i < stack.size(); i++) {
        for (int i = stack.size() - 1; i >= 0; i--) {
            const Frame &frame = stack.frame(i);
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

            node = &stack_node_list[next_node_idx];
        }
        return node->index;
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

    virtual VALUE stop() {
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

    VALUE stop() {
        BaseCollector::stop();

        frame_list.finalize();

        VALUE result = build_collector_result();

        reset();

        return result;
    }

    VALUE build_collector_result() {
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

    VALUE stop() {
        BaseCollector::stop();

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

        VALUE result = build_collector_result();

        reset();

        return result;
    }

    VALUE build_collector_result() {
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

class Marker {
    public:
    enum Type {
        MARKER_GVL_THREAD_STARTED,
        MARKER_GVL_THREAD_READY,
        MARKER_GVL_THREAD_RESUMED,
        MARKER_GVL_THREAD_SUSPENDED,
        MARKER_GVL_THREAD_EXITED,

        MARKER_MAX,
    };
    Type type;
    TimeStamp timestamp;
};

class TimeCollector : public BaseCollector {
    std::vector<int> samples;
    std::vector<TimeStamp> timestamps;

    std::vector<Marker> markers;

    pthread_t target_thread;
    pthread_t sample_thread;

    atomic_bool running;
    SamplerSemaphore thread_stopped;

    static inline LiveSample *live_sample;

    void record_sample(const LiveSample &sample) {
        int stack_index = frame_list.stack_index(sample.sample);
        samples.push_back(stack_index);
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

            pthread_kill(target_thread, SIGPROF);
            sample.wait();

            record_sample(sample);
            timestamps.push_back(sample_start);

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

    static void internal_thread_event_cb(rb_event_flag_t event, const rb_internal_thread_event_data_t *event_data, void *data) {
        TimeCollector *collector = static_cast<TimeCollector *>(data);
        //cerr << "internal thread event" << event << " at " << TimeStamp::Now() << endl;

        switch (event) {
            case RUBY_INTERNAL_THREAD_EVENT_STARTED:
                collector->markers.push_back(Marker{Marker::Type::MARKER_GVL_THREAD_STARTED, TimeStamp::Now()});
                break;
            case RUBY_INTERNAL_THREAD_EVENT_READY:
                collector->markers.push_back(Marker{Marker::Type::MARKER_GVL_THREAD_READY, TimeStamp::Now()});
                break;
            case RUBY_INTERNAL_THREAD_EVENT_RESUMED:
                collector->markers.push_back(Marker{Marker::Type::MARKER_GVL_THREAD_RESUMED, TimeStamp::Now()});

                // Look at me! I have the GVL!
                collector->target_thread = pthread_self();
                break;
            case RUBY_INTERNAL_THREAD_EVENT_SUSPENDED:
                collector->markers.push_back(Marker{Marker::Type::MARKER_GVL_THREAD_SUSPENDED, TimeStamp::Now()});
                break;
            case RUBY_INTERNAL_THREAD_EVENT_EXITED:
                collector->markers.push_back(Marker{Marker::Type::MARKER_GVL_THREAD_EXITED, TimeStamp::Now()});
                break;

        }
    }

    rb_internal_thread_event_hook_t *thread_hook;

    bool start() {
        if (!BaseCollector::start()) {
            return false;
        }

        target_thread = pthread_self();

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

        thread_hook = rb_internal_thread_add_event_hook(internal_thread_event_cb, RUBY_INTERNAL_THREAD_EVENT_MASK, this);

        return true;
    }

    VALUE stop() {
        BaseCollector::stop();

        running = false;
        thread_stopped.wait();

        struct sigaction sa;
        sa.sa_handler = SIG_IGN;
        sa.sa_flags = SA_RESTART;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGPROF, &sa, NULL);

        rb_internal_thread_remove_event_hook(thread_hook);

        frame_list.finalize();

        VALUE result = build_collector_result();

        reset();

        return result;
    }

    VALUE build_collector_result() {
        VALUE result = rb_obj_alloc(rb_cVernierResult);

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

        VALUE marker_strings[Marker::Type::MARKER_MAX] = {0};
        marker_strings[Marker::Type::MARKER_GVL_THREAD_STARTED] = rb_str_new_lit("thread started");
        marker_strings[Marker::Type::MARKER_GVL_THREAD_READY] = rb_str_new_lit("thread ready");
        marker_strings[Marker::Type::MARKER_GVL_THREAD_RESUMED] = rb_str_new_lit("thread resumed");
        marker_strings[Marker::Type::MARKER_GVL_THREAD_SUSPENDED] = rb_str_new_lit("thread suspended");
        marker_strings[Marker::Type::MARKER_GVL_THREAD_EXITED] = rb_str_new_lit("thread exited");

        VALUE marker_timestamps = rb_ary_new();
        VALUE marker_names = rb_ary_new();
        rb_ivar_set(result, rb_intern("@marker_timestamps"), marker_timestamps);
        rb_ivar_set(result, rb_intern("@marker_names"), marker_names);
        for (auto& marker: this->markers) {
            rb_ary_push(marker_timestamps, ULL2NUM(marker.timestamp.nanoseconds()));
            rb_ary_push(marker_names, marker_strings[marker.type]);
        }

        frame_list.write_result(result);

        return result;
    }

    void mark() {
        frame_list.mark_frames();

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

    VALUE result = collector->stop();
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
    return TypedData_Wrap_Struct(self, &rb_collector_type, collector);
}

extern "C" void
Init_vernier(void)
{
  rb_mVernier = rb_define_module("Vernier");
  rb_cVernierResult = rb_define_class_under(rb_mVernier, "Result", rb_cObject);

  rb_cVernierCollector = rb_define_class_under(rb_mVernier, "Collector", rb_cObject);
  rb_undef_alloc_func(rb_cVernierCollector);
  rb_define_singleton_method(rb_cVernierCollector, "new", collector_new, 1);
  rb_define_method(rb_cVernierCollector, "start", collector_start, 0);
  rb_define_method(rb_cVernierCollector, "stop",  collector_stop, 0);
  rb_define_method(rb_cVernierCollector, "sample", collector_sample, 0);

  //static VALUE gc_hook = Data_Wrap_Struct(rb_cObject, collector_mark, NULL, &_collector);
  //rb_global_variable(&gc_hook);
}
