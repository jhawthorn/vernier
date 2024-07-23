// vim: expandtab:ts=4:sw=4

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

#include <sys/time.h>
#include <signal.h>
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

#include "vernier.hh"

#include "ruby/ruby.h"
#include "ruby/debug.h"
#include "ruby/thread.h"

#undef assert
#define assert RUBY_ASSERT_ALWAYS

# define PTR2NUM(x)   (rb_int2inum((intptr_t)(void *)(x)))

// Internal TracePoint events we'll monitor during profiling
#define RUBY_INTERNAL_EVENTS \
  RUBY_INTERNAL_EVENT_GC_START | \
  RUBY_INTERNAL_EVENT_GC_END_MARK | \
  RUBY_INTERNAL_EVENT_GC_END_SWEEP | \
  RUBY_INTERNAL_EVENT_GC_ENTER | \
  RUBY_INTERNAL_EVENT_GC_EXIT

#define RUBY_NORMAL_EVENTS \
  RUBY_EVENT_THREAD_BEGIN | \
  RUBY_EVENT_THREAD_END

#define sym(name) ID2SYM(rb_intern_const(name))

// HACK: This isn't public, but the objspace ext uses it
extern "C" size_t rb_obj_memsize_of(VALUE);

using namespace std;

static VALUE rb_mVernier;
static VALUE rb_cVernierResult;
static VALUE rb_mVernierMarkerType;
static VALUE rb_cVernierCollector;
static VALUE rb_cStackTable;

static VALUE sym_state, sym_gc_by;

static const char *gvl_event_name(rb_event_flag_t event) {
    switch (event) {
      case RUBY_INTERNAL_THREAD_EVENT_STARTED:
        return "started";
      case RUBY_INTERNAL_THREAD_EVENT_READY:
        return "ready";
      case RUBY_INTERNAL_THREAD_EVENT_RESUMED:
        return "resumed";
      case RUBY_INTERNAL_THREAD_EVENT_SUSPENDED:
        return "suspended";
      case RUBY_INTERNAL_THREAD_EVENT_EXITED:
        return "exited";
    }
    return "no-event";
}

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

std::ostream& operator<<(std::ostream& os, const TimeStamp& info) {
    os << info.nanoseconds() << "ns";
    return os;
}

// TODO: Rename FuncInfo
struct FrameInfo {
    static const char *label_cstr(VALUE frame) {
        VALUE label = rb_profile_frame_full_label(frame);
        return StringValueCStr(label);
    }

    static const char *file_cstr(VALUE frame) {
        VALUE file = rb_profile_frame_absolute_path(frame);
        if (NIL_P(file))
            file = rb_profile_frame_path(frame);
        if (NIL_P(file)) {
            return "";
        } else {
            return StringValueCStr(file);
        }
    }

    static int first_lineno_int(VALUE frame) {
        VALUE first_lineno = rb_profile_frame_first_lineno(frame);
        return NIL_P(first_lineno) ? 0 : FIX2INT(first_lineno);
    }

    FrameInfo(VALUE frame) :
        label(label_cstr(frame)),
        file(file_cstr(frame)),
        first_lineno(first_lineno_int(frame)) { }

    std::string label;
    std::string file;
    int first_lineno;
};

bool operator==(const FrameInfo& lhs, const FrameInfo& rhs) noexcept {
    return
        lhs.label == rhs.label &&
        lhs.file == rhs.file &&
        lhs.first_lineno == rhs.first_lineno;
}

struct Frame {
    VALUE frame;
    int line;
};

bool operator==(const Frame& lhs, const Frame& rhs) noexcept {
    return lhs.frame == rhs.frame && lhs.line == rhs.line;
}

bool operator!=(const Frame& lhs, const Frame& rhs) noexcept {
    return !(lhs == rhs);
}

namespace std {
    template<>
    struct hash<Frame>
    {
        std::size_t operator()(Frame const& s) const noexcept
        {
            return s.frame ^ s.line;
        }
    };
}

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
        auto ts = (TimeStamp::Now() + TimeStamp::from_seconds(5)).timespec();

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

class RawSample {
    public:

    constexpr static int MAX_LEN = 2048;

    private:

    VALUE frames[MAX_LEN];
    int lines[MAX_LEN];
    int len;
    int offset;
    bool gc;

    public:

    RawSample() : len(0), gc(false), offset(0) { }

    int size() const {
        return len - offset;
    }

    Frame frame(int i) const {
        int idx = len - i - 1;
        if (idx < 0) throw std::out_of_range("VERNIER BUG: index out of range");
        const Frame frame = {frames[idx], lines[idx]};
        return frame;
    }

    void sample(int offset = 0) {
        clear();

        if (!ruby_native_thread_p()) {
            return;
        }

        if (false && rb_during_gc()) {
          gc = true;
        } else {
          len = rb_profile_frames(0, MAX_LEN, frames, lines);
          this->offset = std::min(offset, len);
        }
    }

    void clear() {
        len = 0;
        offset = 0;
        gc = false;
    }

    bool empty() const {
        return len <= offset;
    }
};

// Based very loosely on the design of Gecko's SigHandlerCoordinator
// This is used for communication between the profiler thread and the signal
// handlers in the observed thread.
struct LiveSample {
    RawSample sample;

    SignalSafeSemaphore sem_complete;

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

template <typename K>
class IndexMap {
    public:
        std::unordered_map<K, int> to_idx;
        std::vector<K> list;

        const K& operator[](int i) const noexcept {
            return list[i];
        }

        size_t size() const noexcept {
            return list.size();
        }

        int index(const K key) {
            auto it = to_idx.find(key);
            if (it == to_idx.end()) {
                int idx = list.size();
                list.push_back(key);

                auto result = to_idx.insert({key, idx});
                it = result.first;
            }

            return it->second;
        }

        void clear() {
            list.clear();
            to_idx.clear();
        }
};

struct StackTable {
    private:

    struct FrameWithInfo {
        Frame frame;
        FrameInfo info;
    };

    IndexMap<Frame> frame_map;

    IndexMap<VALUE> func_map;
    std::vector<FrameInfo> func_info_list;

    struct StackNode {
        std::unordered_map<Frame, int> children;
        Frame frame;
        int parent;
        int index;

        StackNode(Frame frame, int index, int parent) : frame(frame), index(index), parent(parent) {}

        // root
        StackNode() : frame(Frame{0, 0}), index(-1), parent(-1) {}
    };

    // This mutex guards the StackNodes only. The rest of the maps and vectors
    // should be guarded by the GVL
    std::mutex stack_mutex;

    StackNode root_stack_node;
    vector<StackNode> stack_node_list;
    int stack_node_list_finalized_idx = 0;

    StackNode *next_stack_node(StackNode *node, Frame frame) {
        auto search = node->children.find(frame);
        if (search == node->children.end()) {
            // insert a new node
            int next_node_idx = stack_node_list.size();
            node->children[frame] = next_node_idx;
            stack_node_list.emplace_back(
                    frame,
                    next_node_idx,
                    node->index
                    );
            return &stack_node_list[next_node_idx];
        } else {
            int node_idx = search->second;
            return &stack_node_list[node_idx];
        }
    }

    public:

    int stack_index(const RawSample &stack) {
        if (stack.empty()) {
            throw std::runtime_error("VERNIER BUG: empty stack");
        }

        const std::lock_guard<std::mutex> lock(stack_mutex);

        StackNode *node = &root_stack_node;
        for (int i = 0; i < stack.size(); i++) {
            Frame frame = stack.frame(i);
            node = next_stack_node(node, frame);
        }
        return node->index;
    }

    int stack_parent(int stack_idx) {
        const std::lock_guard<std::mutex> lock(stack_mutex);
        if (stack_idx < 0 || stack_idx >= stack_node_list.size()) {
            return -1;
        } else {
            return stack_node_list[stack_idx].parent;
        }
    }

    int stack_frame(int stack_idx) {
        const std::lock_guard<std::mutex> lock(stack_mutex);
        if (stack_idx < 0 || stack_idx >= stack_node_list.size()) {
            return -1;
        } else {
            return frame_map.index(stack_node_list[stack_idx].frame);
        }
    }

    // Converts Frames from stacks other tables. "Symbolicates" the frames
    // which allocates.
    void finalize() {
        {
            const std::lock_guard<std::mutex> lock(stack_mutex);
            for (int i = stack_node_list_finalized_idx; i < stack_node_list.size(); i++) {
                const auto &stack_node = stack_node_list[i];
                frame_map.index(stack_node.frame);
                func_map.index(stack_node.frame.frame);
                stack_node_list_finalized_idx = i;
            }
        }

        for (int i = func_info_list.size(); i < func_map.size(); i++) {
            const auto &func = func_map[i];
            // must not hold a mutex here
            func_info_list.push_back(FrameInfo(func));
        }
    }

    void mark_frames() {
        const std::lock_guard<std::mutex> lock(stack_mutex);

        for (auto stack_node: stack_node_list) {
            rb_gc_mark(stack_node.frame.frame);
        }
    }

    StackNode *convert_stack(StackTable &other, int original_idx) {
        if (original_idx < 0) {
            return &root_stack_node;
        }

        StackNode &original_node = other.stack_node_list[original_idx];
        StackNode *parent_node = convert_stack(other, original_node.parent);
        StackNode *node = next_stack_node(parent_node, original_node.frame);

        return node;
    }

    static VALUE stack_table_convert(VALUE self, VALUE other, VALUE original_stack);

    static VALUE stack_table_stack_count(VALUE self);
    static VALUE stack_table_frame_count(VALUE self);
    static VALUE stack_table_func_count(VALUE self);

    static VALUE stack_table_frame_line_no(VALUE self, VALUE idxval);
    static VALUE stack_table_frame_func_idx(VALUE self, VALUE idxval);
    static VALUE stack_table_func_name(VALUE self, VALUE idxval);
    static VALUE stack_table_func_filename(VALUE self, VALUE idxval);
    static VALUE stack_table_func_first_lineno(VALUE self, VALUE idxval);

    friend class SampleTranslator;
};

static void
stack_table_mark(void *data) {
    StackTable *stack_table = static_cast<StackTable *>(data);
    stack_table->mark_frames();
}

static void
stack_table_free(void *data) {
    StackTable *stack_table = static_cast<StackTable *>(data);
    delete stack_table;
}

static const rb_data_type_t rb_stack_table_type = {
    .wrap_struct_name = "vernier/stack_table",
    .function = {
        //.dmemsize = rb_collector_memsize,
        .dmark = stack_table_mark,
        .dfree = stack_table_free,
    },
};

static VALUE
stack_table_new(VALUE self) {
    StackTable *stack_table = new StackTable();
    VALUE obj = TypedData_Wrap_Struct(self, &rb_stack_table_type, stack_table);
    return obj;
}

static StackTable *get_stack_table(VALUE obj) {
    StackTable *stack_table;
    TypedData_Get_Struct(obj, StackTable, &rb_stack_table_type, stack_table);
    return stack_table;
}

static VALUE
stack_table_current_stack(int argc, VALUE *argv, VALUE self) {
    int offset;
    VALUE offset_v;

    rb_scan_args(argc, argv, "01", &offset_v);
    if (argc > 0) {
        offset = NUM2INT(offset_v) + 1;
    } else {
        offset = 1;
    }

    StackTable *stack_table = get_stack_table(self);
    RawSample stack;
    stack.sample(offset);
    int stack_index = stack_table->stack_index(stack);
    return INT2NUM(stack_index);
}

static VALUE
stack_table_stack_parent_idx(VALUE self, VALUE idxval) {
    StackTable *stack_table = get_stack_table(self);
    int idx = NUM2INT(idxval);
    int parent_idx = stack_table->stack_parent(idx);
    if (parent_idx < 0) {
        return Qnil;
    } else {
        return INT2NUM(parent_idx);
    }
}

static VALUE
stack_table_stack_frame_idx(VALUE self, VALUE idxval) {
    StackTable *stack_table = get_stack_table(self);
    //stack_table->finalize();
    int idx = NUM2INT(idxval);
    int frame_idx = stack_table->stack_frame(idx);
    return frame_idx < 0 ? Qnil : INT2NUM(frame_idx);
}

VALUE
StackTable::stack_table_stack_count(VALUE self) {
    StackTable *stack_table = get_stack_table(self);
    int count;
    {
        const std::lock_guard<std::mutex> lock(stack_table->stack_mutex);
        count = stack_table->stack_node_list.size();
    }
    return INT2NUM(count);
}

VALUE
StackTable::stack_table_convert(VALUE self, VALUE original_tableval, VALUE original_idxval) {
    StackTable *stack_table = get_stack_table(self);
    StackTable *original_table = get_stack_table(original_tableval);
    int original_idx = NUM2INT(original_idxval);

    if (original_idx == -1) {
        return original_idxval;
    }

    int original_size;
    {
        const std::lock_guard<std::mutex> lock(original_table->stack_mutex);
        original_size = original_table->stack_node_list.size();
    }

    if (original_idx >= original_size || original_idx < 0) {
        rb_raise(rb_eRangeError, "index out of range");
    }

    int result_idx;
    {
        const std::lock_guard<std::mutex> lock1(stack_table->stack_mutex);
        const std::lock_guard<std::mutex> lock2(original_table->stack_mutex);
        StackNode *node = stack_table->convert_stack(*original_table, original_idx);
        result_idx = node->index;
    }
    return INT2NUM(result_idx);
}

VALUE
StackTable::stack_table_frame_count(VALUE self) {
    StackTable *stack_table = get_stack_table(self);
    stack_table->finalize();
    int count = stack_table->frame_map.size();
    return INT2NUM(count);
}

VALUE
StackTable::stack_table_func_count(VALUE self) {
    StackTable *stack_table = get_stack_table(self);
    stack_table->finalize();
    int count = stack_table->func_map.size();
    return INT2NUM(count);
}

VALUE
StackTable::stack_table_frame_line_no(VALUE self, VALUE idxval) {
    StackTable *stack_table = get_stack_table(self);
    stack_table->finalize();
    int idx = NUM2INT(idxval);
    if (idx < 0 || idx >= stack_table->frame_map.size()) {
        return Qnil;
    } else {
        const auto &frame = stack_table->frame_map[idx];
        return INT2NUM(frame.line);
    }
}

VALUE
StackTable::stack_table_frame_func_idx(VALUE self, VALUE idxval) {
    StackTable *stack_table = get_stack_table(self);
    stack_table->finalize();
    int idx = NUM2INT(idxval);
    if (idx < 0 || idx >= stack_table->frame_map.size()) {
        return Qnil;
    } else {
        const auto &frame = stack_table->frame_map[idx];
        int func_idx = stack_table->func_map.index(frame.frame);
        return INT2NUM(func_idx);
    }
}

VALUE
StackTable::stack_table_func_name(VALUE self, VALUE idxval) {
    StackTable *stack_table = get_stack_table(self);
    stack_table->finalize();
    int idx = NUM2INT(idxval);
    auto &table = stack_table->func_info_list;
    if (idx < 0 || idx >= table.size()) {
        return Qnil;
    } else {
        const auto &func_info = table[idx];
        const std::string &label = func_info.label;
        return rb_interned_str(label.c_str(), label.length());
    }
}

VALUE
StackTable::stack_table_func_filename(VALUE self, VALUE idxval) {
    StackTable *stack_table = get_stack_table(self);
    stack_table->finalize();
    int idx = NUM2INT(idxval);
    auto &table = stack_table->func_info_list;
    if (idx < 0 || idx >= table.size()) {
        return Qnil;
    } else {
        const auto &func_info = table[idx];
        const std::string &filename = func_info.file;
        return rb_interned_str(filename.c_str(), filename.length());
    }
}

VALUE
StackTable::stack_table_func_first_lineno(VALUE self, VALUE idxval) {
    StackTable *stack_table = get_stack_table(self);
    stack_table->finalize();
    int idx = NUM2INT(idxval);
    auto &table = stack_table->func_info_list;
    if (idx < 0 || idx >= table.size()) {
        return Qnil;
    } else {
        const auto &func_info = table[idx];
        return INT2NUM(func_info.first_lineno);
    }
}

class SampleTranslator {
    public:
        int last_stack_index;

        Frame frames[RawSample::MAX_LEN];
        int frame_indexes[RawSample::MAX_LEN];
        int len;

        SampleTranslator() : len(0), last_stack_index(-1) {
        }

        int translate(StackTable &frame_list, const RawSample &sample) {
            int i = 0;
            for (; i < len && i < sample.size(); i++) {
                if (frames[i] != sample.frame(i)) {
                    break;
                }
            }

            const std::lock_guard<std::mutex> lock(frame_list.stack_mutex);
            StackTable::StackNode *node = i == 0 ? &frame_list.root_stack_node : &frame_list.stack_node_list[frame_indexes[i - 1]];

            for (; i < sample.size(); i++) {
                Frame frame = sample.frame(i);
                node = frame_list.next_stack_node(node, frame);

                frames[i] = frame;
                frame_indexes[i] = node->index;
            }
            len = i;

            last_stack_index = node->index;
            return last_stack_index;
        }
};

typedef uint64_t native_thread_id_t;
static native_thread_id_t get_native_thread_id() {
#if defined(__APPLE__)
    uint64_t thread_id;
    int e = pthread_threadid_np(pthread_self(), &thread_id);
    if (e != 0) rb_syserr_fail(e, "pthread_threadid_np");
    return thread_id;
#elif defined(__FreeBSD__)
    return pthread_getthreadid_np();
#else
    // gettid() is only available as of glibc 2.30
    pid_t tid = syscall(SYS_gettid);
    return tid;
#endif
}

union MarkerInfo {
    struct {
        VALUE gc_by;
        VALUE gc_state;
    } gc_data;
};

class Marker {
    public:
    enum Type {
        MARKER_GVL_THREAD_STARTED,
        MARKER_GVL_THREAD_EXITED,

        MARKER_GC_START,
        MARKER_GC_END_MARK,
        MARKER_GC_END_SWEEP,
        MARKER_GC_ENTER,
        MARKER_GC_EXIT,
        MARKER_GC_PAUSE,

        MARKER_THREAD_RUNNING,
        MARKER_THREAD_STALLED,
        MARKER_THREAD_SUSPENDED,

        MARKER_MAX,
    };

    // Must match phase types from Gecko
    enum Phase {
      INSTANT,
      INTERVAL,
      INTERVAL_START,
      INTERVAL_END
    };

    Type type;
    Phase phase;
    TimeStamp timestamp;
    TimeStamp finish;
    // VALUE ruby_thread_id;
    //native_thread_id_t thread_id;
    int stack_index = -1;

    MarkerInfo extra_info;

    VALUE to_array() {
        VALUE record[7] = {0};
        record[0] = Qnil; // FIXME
        record[1] = INT2NUM(type);
        record[2] = INT2NUM(phase);
        record[3] = ULL2NUM(timestamp.nanoseconds());

        if (phase == Marker::Phase::INTERVAL) {
            record[4] = ULL2NUM(finish.nanoseconds());
        }
        else {
            record[4] = Qnil;
        }
        record[5] = stack_index == -1 ? Qnil : INT2NUM(stack_index);

        if (type == Marker::MARKER_GC_PAUSE) {
            VALUE hash = rb_hash_new();
            record[6] = hash;

            rb_hash_aset(hash, sym_gc_by, extra_info.gc_data.gc_by);
            rb_hash_aset(hash, sym_state, extra_info.gc_data.gc_state);
        }
        return rb_ary_new_from_values(7, record);
    }
};

class MarkerTable {
    public:
        std::mutex mutex;
        std::vector<Marker> list;

        void record_interval(Marker::Type type, TimeStamp from, TimeStamp to, int stack_index = -1) {
            const std::lock_guard<std::mutex> lock(mutex);

            list.push_back({ type, Marker::INTERVAL, from, to, stack_index });
        }

        void record(Marker::Type type, int stack_index = -1, MarkerInfo extra_info = {}) {
            const std::lock_guard<std::mutex> lock(mutex);

            list.push_back({ type, Marker::INSTANT, TimeStamp::Now(), TimeStamp(), stack_index });
        }
};

class GCMarkerTable: public MarkerTable {
    TimeStamp last_gc_entry;

    public:
        void record_gc_start() {
            record(Marker::Type::MARKER_GC_START);
        }

        void record_gc_entered() {
          last_gc_entry = TimeStamp::Now();
        }

        void record_gc_leave() {
            VALUE gc_state = rb_gc_latest_gc_info(sym_state);
            VALUE gc_by = rb_gc_latest_gc_info(sym_gc_by);
            union MarkerInfo info = {
                .gc_data = {
                    .gc_by = gc_by,
                    .gc_state = gc_state
                }
            };
            list.push_back({ Marker::MARKER_GC_PAUSE, Marker::INTERVAL, last_gc_entry, TimeStamp::Now(), -1, info });
        }

        void record_gc_end_mark() {
            record_gc_leave();
            record(Marker::Type::MARKER_GC_END_MARK);
            record_gc_entered();
        }

        void record_gc_end_sweep() {
            record(Marker::Type::MARKER_GC_END_SWEEP);
        }
};

enum Category{
    CATEGORY_NORMAL,
    CATEGORY_IDLE,
    CATEGORY_STALLED,
    CATEGORY_GC
};

class ObjectSampleList {
    public:

        std::vector<int> stacks;
        std::vector<TimeStamp> timestamps;
        std::vector<int> weights;

        size_t size() {
            return stacks.size();
        }

        bool empty() {
            return size() == 0;
        }

        void record_sample(int stack_index, TimeStamp time, int weight) {
            stacks.push_back(stack_index);
            timestamps.push_back(time);
            weights.push_back(1);
        }

        void write_result(VALUE result) const {
            VALUE allocations = rb_hash_new();
            rb_hash_aset(result, sym("allocations"), allocations);

            VALUE samples = rb_ary_new();
            rb_hash_aset(allocations, sym("samples"), samples);
            for (auto& stack_index: this->stacks) {
                rb_ary_push(samples, INT2NUM(stack_index));
            }

            VALUE weights = rb_ary_new();
            rb_hash_aset(allocations, sym("weights"), weights);
            for (auto& weight: this->weights) {
                rb_ary_push(weights, INT2NUM(weight));
            }

            VALUE timestamps = rb_ary_new();
            rb_hash_aset(allocations, sym("timestamps"), timestamps);
            for (auto& timestamp: this->timestamps) {
                rb_ary_push(timestamps, ULL2NUM(timestamp.nanoseconds()));
            }
        }
};

class SampleList {
    public:

        std::vector<int> stacks;
        std::vector<TimeStamp> timestamps;
        std::vector<Category> categories;
        std::vector<int> weights;

        size_t size() {
            return stacks.size();
        }

        bool empty() {
            return size() == 0;
        }

        void record_sample(int stack_index, TimeStamp time, Category category) {
            if (
                    !empty() &&
                    stacks.back() == stack_index &&
                    categories.back() == category)
            {
                // We don't compare timestamps for de-duplication
                weights.back() += 1;
            } else {
                stacks.push_back(stack_index);
                timestamps.push_back(time);
                categories.push_back(category);
                weights.push_back(1);
            }
        }

        void write_result(VALUE result) const {
            VALUE samples = rb_ary_new();
            rb_hash_aset(result, sym("samples"), samples);
            for (auto& stack_index: this->stacks) {
                rb_ary_push(samples, INT2NUM(stack_index));
            }

            VALUE weights = rb_ary_new();
            rb_hash_aset(result, sym("weights"), weights);
            for (auto& weight: this->weights) {
                rb_ary_push(weights, INT2NUM(weight));
            }

            VALUE timestamps = rb_ary_new();
            rb_hash_aset(result, sym("timestamps"), timestamps);
            for (auto& timestamp: this->timestamps) {
                rb_ary_push(timestamps, ULL2NUM(timestamp.nanoseconds()));
            }

            VALUE sample_categories = rb_ary_new();
            rb_hash_aset(result, sym("sample_categories"), sample_categories);
            for (auto& cat: this->categories) {
                rb_ary_push(sample_categories, INT2NUM(cat));
            }
        }
};

class Thread {
    public:
        SampleList samples;
        ObjectSampleList allocation_samples;

        enum State {
            STARTED,
            RUNNING,
            READY,
            SUSPENDED,
            STOPPED,
            INITIAL,
        };

        VALUE ruby_thread;
        VALUE ruby_thread_id;
        pthread_t pthread_id;
        native_thread_id_t native_tid;
        State state;

        TimeStamp state_changed_at;
        TimeStamp started_at;
        TimeStamp stopped_at;

        int stack_on_suspend_idx;
        SampleTranslator translator;

        unique_ptr<MarkerTable> markers;

        // FIXME: don't use pthread at start
        Thread(State state, pthread_t pthread_id, VALUE ruby_thread) : pthread_id(pthread_id), ruby_thread(ruby_thread), state(state), stack_on_suspend_idx(-1) {
            ruby_thread_id = rb_obj_id(ruby_thread);
            //ruby_thread_id = ULL2NUM(ruby_thread);
            native_tid = get_native_thread_id();
            started_at = state_changed_at = TimeStamp::Now();
            markers = std::make_unique<MarkerTable>();

            if (state == State::STARTED) {
                markers->record(Marker::Type::MARKER_GVL_THREAD_STARTED);
            }
        }

        void record_newobj(VALUE obj, StackTable &frame_list) {
            RawSample sample;
            sample.sample();

            int stack_idx = translator.translate(frame_list, sample);
            allocation_samples.record_sample(stack_idx, TimeStamp::Now(), 1);
        }

        void set_state(State new_state) {
            if (state == Thread::State::STOPPED) {
                return;
            }
            if (new_state == Thread::State::SUSPENDED && state == new_state) {
                // on Ruby 3.2 (only?) we may see duplicate suspended states
                return;
            }

            TimeStamp from = state_changed_at;
            auto now = TimeStamp::Now();

            if (started_at.zero()) {
                started_at = now;
            }

            switch (new_state) {
                case State::INITIAL:
                    break;
                case State::STARTED:
                    markers->record(Marker::Type::MARKER_GVL_THREAD_STARTED);
                    return; // no mutation of current state
                    break;
                case State::RUNNING:
                    assert(state == INITIAL || state == State::READY || state == State::RUNNING);
                    pthread_id = pthread_self();
                    native_tid = get_native_thread_id();

                    // If the GVL is immediately ready, and we measure no times
                    // stalled, skip emitting the interval.
                    if (from != now) {
                        markers->record_interval(Marker::Type::MARKER_THREAD_STALLED, from, now);
                    }
                    break;
                case State::READY:
                    // The ready state means "I would like to do some work, but I can't
                    // do it right now either because I blocked on IO and now I want the GVL back,
                    // or because the VM timer put me to sleep"
                    //
                    // Threads can be preempted, which means they will have been in "Running"
                    // state, and then the VM was like "no I need to stop you from working,
                    // so I'll put you in the 'ready' (or stalled) state"
                    assert(state == State::INITIAL || state == State::STARTED || state == State::SUSPENDED || state == State::RUNNING);
                    if (state == State::SUSPENDED) {
                        markers->record_interval(Marker::Type::MARKER_THREAD_SUSPENDED, from, now, stack_on_suspend_idx);
                    }
                    else if (state == State::RUNNING) {
                        markers->record_interval(Marker::Type::MARKER_THREAD_RUNNING, from, now);
                    }
                    break;
                case State::SUSPENDED:
                    // We can go from RUNNING or STARTED to SUSPENDED
                    assert(state == State::INITIAL || state == State::RUNNING || state == State::STARTED || state == State::SUSPENDED);
                    markers->record_interval(Marker::Type::MARKER_THREAD_RUNNING, from, now);
                    break;
                case State::STOPPED:
                    // We can go from RUNNING or STARTED or SUSPENDED to STOPPED
                    assert(state == State::INITIAL || state == State::RUNNING || state == State::STARTED || state == State::SUSPENDED);
                    markers->record_interval(Marker::Type::MARKER_THREAD_RUNNING, from, now);
                    markers->record(Marker::Type::MARKER_GVL_THREAD_EXITED);

                    stopped_at = now;

                    break;
            }

            state = new_state;
            state_changed_at = now;
        }

        bool is_main() {
            return rb_thread_main() == ruby_thread;
        }

        bool is_start(VALUE start_thread) {
            return start_thread == ruby_thread;
        }

        bool running() {
            return state != State::STOPPED;
        }

        void mark() {
        }
};

class ThreadTable {
    public:
        StackTable &frame_list;

        std::vector<std::unique_ptr<Thread> > list;
        std::mutex mutex;

        ThreadTable(StackTable &frame_list) : frame_list(frame_list) {
        }

        void mark() {
            for (const auto &thread : list) {
                thread->mark();
            }
        }

        void initial(VALUE th) {
            set_state(Thread::State::INITIAL, th);
        }

        void started(VALUE th) {
            //list.push_back(Thread{pthread_self(), Thread::State::SUSPENDED});
            set_state(Thread::State::STARTED, th);
        }

        void ready(VALUE th) {
            set_state(Thread::State::READY, th);
        }

        void resumed(VALUE th) {
            set_state(Thread::State::RUNNING, th);
        }

        void suspended(VALUE th) {
            set_state(Thread::State::SUSPENDED, th);
        }

        void stopped(VALUE th) {
            set_state(Thread::State::STOPPED, th);
        }

    private:
        void set_state(Thread::State new_state, VALUE th) {
            const std::lock_guard<std::mutex> lock(mutex);

            //cerr << "set state=" << new_state << " thread=" << gettid() << endl;

            pid_t native_tid = get_native_thread_id();
            pthread_t pthread_id = pthread_self();

            //fprintf(stderr, "th %p (tid: %i) from %s to %s\n", (void *)th, native_tid, gvl_event_name(state), gvl_event_name(new_state));

            for (auto &threadptr : list) {
                auto &thread = *threadptr;
                if (thread_equal(th, thread.ruby_thread)) {
                    if (new_state == Thread::State::SUSPENDED || new_state == Thread::State::READY && (thread.state != Thread::State::SUSPENDED)) {

                        RawSample sample;
                        sample.sample();

                        thread.stack_on_suspend_idx = thread.translator.translate(frame_list, sample);
                        //cerr << gettid() << " suspended! Stack size:" << thread.stack_on_suspend.size() << endl;
                    }

                    thread.set_state(new_state);

                    if (thread.state == Thread::State::RUNNING) {
                        thread.pthread_id = pthread_self();
                        thread.native_tid = get_native_thread_id();
                    } else {
                        thread.pthread_id = 0;
                        thread.native_tid = 0;
                    }


                    return;
                }
            }

            //fprintf(stderr, "NEW THREAD: th: %p, state: %i\n", th, new_state);
            list.push_back(std::make_unique<Thread>(new_state, pthread_self(), th));
        }

        bool thread_equal(VALUE a, VALUE b) {
            return a == b;
        }
};

class BaseCollector {
    protected:

    virtual void reset() {
    }

    public:
    bool running = false;
    StackTable *stack_table;
    VALUE stack_table_value;

    VALUE start_thread;
    TimeStamp started_at;

    BaseCollector(VALUE stack_table_value) : stack_table_value(stack_table_value), stack_table(get_stack_table(stack_table_value)) {
    }
    virtual ~BaseCollector() {}

    virtual bool start() {
        if (running) {
            return false;
        }

        start_thread = rb_thread_current();
        started_at = TimeStamp::Now();

        running = true;
        return true;
    }

    virtual VALUE stop() {
        if (!running) {
            rb_raise(rb_eRuntimeError, "collector not running");
        }
        running = false;

        return Qnil;
    }

    virtual void write_meta(VALUE meta, VALUE result) {
        rb_hash_aset(meta, sym("started_at"), ULL2NUM(started_at.nanoseconds()));
        rb_hash_aset(meta, sym("interval"), Qnil);
        rb_hash_aset(meta, sym("allocation_sample_rate"), Qnil);

    }

    virtual VALUE build_collector_result() {
        VALUE result = rb_obj_alloc(rb_cVernierResult);

        VALUE meta = rb_hash_new();
        rb_ivar_set(result, rb_intern("@meta"), meta);
        write_meta(meta, result);

        return result;
    }

    virtual void sample() {
        rb_raise(rb_eRuntimeError, "collector doesn't support manual sampling");
    };

    virtual void mark() {
        //frame_list.mark_frames();
        rb_gc_mark(stack_table_value);
    };

    virtual VALUE get_markers() {
        return rb_ary_new();
    };
};

class CustomCollector : public BaseCollector {
    SampleList samples;

    void sample() {
        RawSample sample;
        sample.sample();
        int stack_index = stack_table->stack_index(sample);

        samples.record_sample(stack_index, TimeStamp::Now(), CATEGORY_NORMAL);
    }

    VALUE stop() {
        BaseCollector::stop();

        stack_table->finalize();

        VALUE result = build_collector_result();

        reset();

        return result;
    }

    VALUE build_collector_result() {
        VALUE result = BaseCollector::build_collector_result();

        VALUE threads = rb_hash_new();
        rb_ivar_set(result, rb_intern("@threads"), threads);

	VALUE thread_hash = rb_hash_new();
	samples.write_result(thread_hash);

	rb_hash_aset(threads, ULL2NUM(0), thread_hash);
	rb_hash_aset(thread_hash, sym("tid"), ULL2NUM(0));

        return result;
    }

    public:

    CustomCollector(VALUE stack_table) : BaseCollector(stack_table) { }
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
        if (sample.empty()) {
            // During thread allocation we allocate one object without a frame
            // (as of Ruby 3.3)
            // Ideally we'd allow empty samples to be represented
            return;
        }
        int stack_index = stack_table->stack_index(sample);

        object_list.push_back(obj);
        object_frames.emplace(obj, stack_index);
    }

    std::unordered_map<VALUE, int> object_frames;
    std::vector<VALUE> object_list;

    VALUE tp_newobj = Qnil;
    VALUE tp_freeobj = Qnil;

    static void newobj_i(VALUE tpval, void *data) {
        RetainedCollector *collector = static_cast<RetainedCollector *>(data);
        rb_trace_arg_t *tparg = rb_tracearg_from_tracepoint(tpval);
        VALUE obj = rb_tracearg_object(tparg);

        collector->record(obj);
    }

    static void freeobj_i(VALUE tpval, void *data) {
        RetainedCollector *collector = static_cast<RetainedCollector *>(data);
        rb_trace_arg_t *tparg = rb_tracearg_from_tracepoint(tpval);
        VALUE obj = rb_tracearg_object(tparg);

        collector->object_frames.erase(obj);
    }

    public:

    RetainedCollector(VALUE stack_table) : BaseCollector(stack_table) { }

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

        stack_table->finalize();

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
        StackTable &frame_list = *collector->stack_table;

        VALUE result = BaseCollector::build_collector_result();

        VALUE threads = rb_hash_new();
        rb_ivar_set(result, rb_intern("@threads"), threads);
        VALUE thread_hash = rb_hash_new();
        rb_hash_aset(threads, ULL2NUM(0), thread_hash);

        rb_hash_aset(thread_hash, sym("tid"), ULL2NUM(0));
        VALUE samples = rb_ary_new();
        rb_hash_aset(thread_hash, sym("samples"), samples);
        VALUE weights = rb_ary_new();
        rb_hash_aset(thread_hash, sym("weights"), weights);

        rb_hash_aset(thread_hash, sym("name"), rb_str_new_cstr("retained memory"));
        rb_hash_aset(thread_hash, sym("started_at"), ULL2NUM(collector->started_at.nanoseconds()));

        for (auto& obj: collector->object_list) {
            const auto search = collector->object_frames.find(obj);
            if (search != collector->object_frames.end()) {
                int stack_index = search->second;

                rb_ary_push(samples, INT2NUM(stack_index));
                rb_ary_push(weights, INT2NUM(rb_obj_memsize_of(obj)));
            }
        }

        return result;
    }

    void mark() {
        // We don't mark the objects, but we MUST mark the frames, otherwise they
        // can be garbage collected.
        // When we stop collection we will stringify the remaining frames, and then
        // clear them from the set, allowing them to be removed from out output.
        stack_table->mark_frames();
        rb_gc_mark(stack_table_value);

        rb_gc_mark(tp_newobj);
        rb_gc_mark(tp_freeobj);
    }
};

class GlobalSignalHandler {
    static LiveSample *live_sample;

    public:
        static GlobalSignalHandler *get_instance() {
            static GlobalSignalHandler instance;
            return &instance;
        }

        void install() {
            const std::lock_guard<std::mutex> lock(mutex);
            count++;

            if (count == 1) setup_signal_handler();
        }

        void uninstall() {
            const std::lock_guard<std::mutex> lock(mutex);
            count--;

            if (count == 0) clear_signal_handler();
        }

        bool record_sample(LiveSample &sample, pthread_t pthread_id) {
            const std::lock_guard<std::mutex> lock(mutex);

            assert(pthread_id);

            live_sample = &sample;
            int rc = pthread_kill(pthread_id, SIGPROF);
            if (rc) {
                fprintf(stderr, "VERNIER BUG: pthread_kill of %lu failed (%i)\n", (unsigned long)pthread_id, rc);
                live_sample = NULL;
                return false;
            } else {
                sample.wait();
                live_sample = NULL;
                return true;
            }
        }

    private:
        std::mutex mutex;
        int count;

        static void signal_handler(int sig, siginfo_t* sinfo, void* ucontext) {
            assert(live_sample);
            live_sample->sample_current_thread();
        }

        void setup_signal_handler() {
            struct sigaction sa;
            sa.sa_sigaction = signal_handler;
            sa.sa_flags = SA_RESTART | SA_SIGINFO;
            sigemptyset(&sa.sa_mask);
            sigaction(SIGPROF, &sa, NULL);
        }

        void clear_signal_handler() {
            struct sigaction sa;
            sa.sa_handler = SIG_IGN;
            sa.sa_flags = SA_RESTART;
            sigemptyset(&sa.sa_mask);
            sigaction(SIGPROF, &sa, NULL);
        }
};
LiveSample *GlobalSignalHandler::live_sample;

class TimeCollector : public BaseCollector {
    GCMarkerTable gc_markers;
    ThreadTable threads;

    pthread_t sample_thread;

    atomic_bool running;
    SignalSafeSemaphore thread_stopped;

    TimeStamp interval;
    unsigned int allocation_sample_rate;
    unsigned int allocation_sample_tick = 0;

    atomic_bool gc_running;

    VALUE tp_newobj = Qnil;

    static void newobj_i(VALUE tpval, void *data) {
        TimeCollector *collector = static_cast<TimeCollector *>(data);
        rb_trace_arg_t *tparg = rb_tracearg_from_tracepoint(tpval);
        VALUE obj = rb_tracearg_object(tparg);

        collector->record_newobj(obj);
    }

    public:
    TimeCollector(VALUE stack_table, TimeStamp interval, unsigned int allocation_sample_rate) : BaseCollector(stack_table), interval(interval), allocation_sample_rate(allocation_sample_rate), threads(*get_stack_table(stack_table)) {
    }

    void record_newobj(VALUE obj) {
        if (++allocation_sample_tick < allocation_sample_rate) {
            return;
        }
        allocation_sample_tick = 0;

        VALUE current_thread = rb_thread_current();
        threads.mutex.lock();
        for (auto &threadptr : threads.list) {
            auto &thread = *threadptr;
            if (current_thread == thread.ruby_thread) {
                thread.record_newobj(obj, threads.frame_list);
                break;
            }
        }
        threads.mutex.unlock();

    }

    void write_meta(VALUE meta, VALUE result) {
        BaseCollector::write_meta(meta, result);
        rb_hash_aset(meta, sym("interval"), ULL2NUM(interval.microseconds()));
        rb_hash_aset(meta, sym("allocation_sample_rate"), ULL2NUM(allocation_sample_rate));
    }

    void set_gc_running(bool value) {
        gc_running = value;
    }

    private:

    void record_sample(const RawSample &sample, TimeStamp time, Thread &thread, Category category) {
        if (!sample.empty()) {
            int stack_index = thread.translator.translate(*stack_table, sample);
            thread.samples.record_sample(
                    stack_index,
                    time,
                    category
                    );
        }
    }

    VALUE get_markers() {
        VALUE list = rb_ary_new();
        VALUE main_thread = rb_thread_main();
        VALUE main_thread_id = rb_obj_id(main_thread);

        for (auto& marker: this->gc_markers.list) {
            VALUE ary = marker.to_array();

            RARRAY_ASET(ary, 0, main_thread_id);
            rb_ary_push(list, ary);
        }
        for (auto &thread : threads.list) {
            for (auto& marker: thread->markers->list) {
                VALUE ary = marker.to_array();
                RARRAY_ASET(ary, 0, thread->ruby_thread_id);
                rb_ary_push(list, ary);
            }
        }

        return list;
    }

    void sample_thread_run() {
        LiveSample sample;

        TimeStamp next_sample_schedule = TimeStamp::Now();
        while (running) {
            TimeStamp sample_start = TimeStamp::Now();

            threads.mutex.lock();
            for (auto &threadptr : threads.list) {
                auto &thread = *threadptr;

                //if (thread.state == Thread::State::RUNNING) {
                //if (thread.state == Thread::State::RUNNING || (thread.state == Thread::State::SUSPENDED && thread.stack_on_suspend_idx < 0)) {
                if (thread.state == Thread::State::RUNNING) {
                    //fprintf(stderr, "sampling %p on tid:%i\n", thread.ruby_thread, thread.native_tid);
                    bool signal_sent = GlobalSignalHandler::get_instance()->record_sample(sample, thread.pthread_id);

                    if (!signal_sent) {
                        // The thread has died. We probably should have caught
                        // that by the GVL instrumentation, but let's try to get
                        // it to a consistent state and stop profiling it.
                        thread.set_state(Thread::State::STOPPED);
                    } else if (sample.sample.empty()) {
                        // fprintf(stderr, "skipping GC sample\n");
                    } else {
                        record_sample(sample.sample, sample_start, thread, gc_running ? CATEGORY_GC : CATEGORY_NORMAL);
                    }
                } else if (thread.state == Thread::State::SUSPENDED) {
                    thread.samples.record_sample(
                            thread.stack_on_suspend_idx,
                            sample_start,
                            CATEGORY_IDLE);
                } else if (thread.state == Thread::State::READY) {
                    thread.samples.record_sample(
                            thread.stack_on_suspend_idx,
                            sample_start,
                            CATEGORY_STALLED);
                } else {
                }
            }

            threads.mutex.unlock();

            TimeStamp sample_complete = TimeStamp::Now();

            next_sample_schedule += interval;

            // If sampling falls behind, restart, and check in another interval
            if (next_sample_schedule < sample_complete) {
                next_sample_schedule = sample_complete + interval;
            }

            TimeStamp::SleepUntil(next_sample_schedule);
        }

        thread_stopped.post();
    }

    static void *sample_thread_entry(void *arg) {
#if HAVE_PTHREAD_SETNAME_NP
#ifdef __APPLE__
        pthread_setname_np("Vernier profiler");
#else
        pthread_setname_np(pthread_self(), "Vernier profiler");
#endif
#endif
        TimeCollector *collector = static_cast<TimeCollector *>(arg);
        collector->sample_thread_run();
        return NULL;
    }

    static void internal_thread_event_cb(rb_event_flag_t event, VALUE data, VALUE self, ID mid, VALUE klass) {
        TimeCollector *collector = static_cast<TimeCollector *>((void *)NUM2ULL(data));

        switch (event) {
            case RUBY_EVENT_THREAD_BEGIN:
                collector->threads.started(self);
                break;
            case RUBY_EVENT_THREAD_END:
                collector->threads.stopped(self);
                break;
        }
    }

    static void internal_gc_event_cb(rb_event_flag_t event, VALUE data, VALUE self, ID mid, VALUE klass) {
        TimeCollector *collector = static_cast<TimeCollector *>((void *)NUM2ULL(data));

        switch (event) {
            case RUBY_INTERNAL_EVENT_GC_START:
                collector->gc_markers.record_gc_start();
                break;
            case RUBY_INTERNAL_EVENT_GC_END_MARK:
                collector->gc_markers.record_gc_end_mark();
                break;
            case RUBY_INTERNAL_EVENT_GC_END_SWEEP:
                collector->gc_markers.record_gc_end_sweep();
                break;
            case RUBY_INTERNAL_EVENT_GC_ENTER:
                collector->set_gc_running(true);
                collector->gc_markers.record_gc_entered();
                break;
            case RUBY_INTERNAL_EVENT_GC_EXIT:
                collector->set_gc_running(false);
                collector->gc_markers.record_gc_leave();
                break;
        }
    }

    static void internal_thread_event_cb(rb_event_flag_t event, const rb_internal_thread_event_data_t *event_data, void *data) {
        TimeCollector *collector = static_cast<TimeCollector *>(data);
        VALUE thread = Qnil;

#if HAVE_RB_INTERNAL_THREAD_EVENT_DATA_T_THREAD
        thread = event_data->thread;
#else
        // We may arrive here when starting a thread with
        // RUBY_INTERNAL_THREAD_EVENT_READY before the thread is actually set up.
        if (!ruby_native_thread_p()) return;

        thread = rb_thread_current();
#endif

        auto native_tid = get_native_thread_id();
        //cerr << "internal thread event" << event << " at " << TimeStamp::Now() << endl;
        //fprintf(stderr, "(%i) th %p to %s\n", native_tid, (void *)thread, gvl_event_name(event));


        switch (event) {
            case RUBY_INTERNAL_THREAD_EVENT_STARTED:
                collector->threads.started(thread);
                break;
            case RUBY_INTERNAL_THREAD_EVENT_EXITED:
                collector->threads.stopped(thread);
                break;
            case RUBY_INTERNAL_THREAD_EVENT_READY:
                collector->threads.ready(thread);
                break;
            case RUBY_INTERNAL_THREAD_EVENT_RESUMED:
                collector->threads.resumed(thread);
                break;
            case RUBY_INTERNAL_THREAD_EVENT_SUSPENDED:
                collector->threads.suspended(thread);
                break;

        }
    }

    rb_internal_thread_event_hook_t *thread_hook;

    bool start() {
        if (!BaseCollector::start()) {
            return false;
        }

        // Record one sample from each thread
        VALUE all_threads = rb_funcall(rb_path2class("Thread"), rb_intern("list"), 0);
        for (int i = 0; i < RARRAY_LEN(all_threads); i++) {
            VALUE thread = RARRAY_AREF(all_threads, i);
            this->threads.initial(thread);
        }

        if (allocation_sample_rate > 0) {
            tp_newobj = rb_tracepoint_new(0, RUBY_INTERNAL_EVENT_NEWOBJ, newobj_i, this);
            rb_tracepoint_enable(tp_newobj);
        }

        GlobalSignalHandler::get_instance()->install();

        running = true;

        int ret = pthread_create(&sample_thread, NULL, &sample_thread_entry, this);
        if (ret != 0) {
            perror("pthread_create");
            rb_bug("VERNIER: pthread_create failed");
        }

        // Set the state of the current Ruby thread to RUNNING, which we know it
        // is as it must have held the GVL to start the collector. We want to
        // have at least one thread in our thread list because it's possible
        // that the profile might be such that we don't get any thread switch
        // events and we need at least one
        this->threads.resumed(rb_thread_current());

        thread_hook = rb_internal_thread_add_event_hook(internal_thread_event_cb, RUBY_INTERNAL_THREAD_EVENT_MASK, this);
        rb_add_event_hook(internal_gc_event_cb, RUBY_INTERNAL_EVENTS, PTR2NUM((void *)this));
        rb_add_event_hook(internal_thread_event_cb, RUBY_NORMAL_EVENTS, PTR2NUM((void *)this));

        return true;
    }

    VALUE stop() {
        BaseCollector::stop();

        running = false;
        thread_stopped.wait();

        GlobalSignalHandler::get_instance()->uninstall();

        if (RTEST(tp_newobj)) {
            rb_tracepoint_disable(tp_newobj);
            tp_newobj = Qnil;
        }

        rb_internal_thread_remove_event_hook(thread_hook);
        rb_remove_event_hook(internal_gc_event_cb);
        rb_remove_event_hook(internal_thread_event_cb);

        stack_table->finalize();

        VALUE result = build_collector_result();

        reset();

        return result;
    }

    VALUE build_collector_result() {
        VALUE result = BaseCollector::build_collector_result();

        VALUE threads = rb_hash_new();
        rb_ivar_set(result, rb_intern("@threads"), threads);

        for (const auto& thread: this->threads.list) {
            VALUE hash = rb_hash_new();
            thread->samples.write_result(hash);
            thread->allocation_samples.write_result(hash);

            rb_hash_aset(threads, thread->ruby_thread_id, hash);
            rb_hash_aset(hash, sym("tid"), ULL2NUM(thread->native_tid));
            rb_hash_aset(hash, sym("started_at"), ULL2NUM(thread->started_at.nanoseconds()));
            if (!thread->stopped_at.zero()) {
                rb_hash_aset(hash, sym("stopped_at"), ULL2NUM(thread->stopped_at.nanoseconds()));
            }
            rb_hash_aset(hash, sym("is_main"), thread->is_main() ? Qtrue : Qfalse);
            rb_hash_aset(hash, sym("is_start"), thread->is_start(BaseCollector::start_thread) ? Qtrue : Qfalse);

        }

        return result;
    }

    void mark() {
        stack_table->mark_frames();
        rb_gc_mark(stack_table_value);
        threads.mark();

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
markers(VALUE self) {
    auto *collector = get_collector(self);

    return collector->get_markers();
}

static VALUE
collector_sample(VALUE self) {
    auto *collector = get_collector(self);

    collector->sample();
    return Qtrue;
}

static VALUE
collector_stack_table(VALUE self) {
    auto *collector = get_collector(self);

    return collector->stack_table_value;
}

static VALUE collector_new(VALUE self, VALUE mode, VALUE options) {
    BaseCollector *collector;

    VALUE stack_table = stack_table_new(rb_cStackTable);
    if (mode == sym("retained")) {
        collector = new RetainedCollector(stack_table);
    } else if (mode == sym("custom")) {
        collector = new CustomCollector(stack_table);
    } else if (mode == sym("wall")) {
        VALUE intervalv = rb_hash_aref(options, sym("interval"));
        TimeStamp interval;
        if (NIL_P(intervalv)) {
            interval = TimeStamp::from_microseconds(500);
        } else {
            interval = TimeStamp::from_microseconds(NUM2UINT(intervalv));
        }

        VALUE allocation_sample_ratev = rb_hash_aref(options, sym("allocation_sample_rate"));
        unsigned int allocation_sample_rate;
        if (NIL_P(allocation_sample_ratev)) {
            allocation_sample_rate = 0;
        } else {
            allocation_sample_rate = NUM2UINT(allocation_sample_ratev);
        }
        collector = new TimeCollector(stack_table, interval, allocation_sample_rate);
    } else {
        rb_raise(rb_eArgError, "invalid mode");
    }
    VALUE obj = TypedData_Wrap_Struct(self, &rb_collector_type, collector);
    rb_funcall(obj, rb_intern("initialize"), 2, mode, options);
    return obj;
}

static void
Init_consts(VALUE rb_mVernierMarkerPhase) {
#define MARKER_CONST(name) \
    rb_define_const(rb_mVernierMarkerType, #name, INT2NUM(Marker::Type::MARKER_##name))

    MARKER_CONST(GVL_THREAD_STARTED);
    MARKER_CONST(GVL_THREAD_EXITED);

    MARKER_CONST(GC_START);
    MARKER_CONST(GC_END_MARK);
    MARKER_CONST(GC_END_SWEEP);
    MARKER_CONST(GC_ENTER);
    MARKER_CONST(GC_EXIT);
    MARKER_CONST(GC_PAUSE);

    MARKER_CONST(THREAD_RUNNING);
    MARKER_CONST(THREAD_STALLED);
    MARKER_CONST(THREAD_SUSPENDED);

#undef MARKER_CONST

#define PHASE_CONST(name) \
    rb_define_const(rb_mVernierMarkerPhase, #name, INT2NUM(Marker::Phase::name))

    PHASE_CONST(INSTANT);
    PHASE_CONST(INTERVAL);
    PHASE_CONST(INTERVAL_START);
    PHASE_CONST(INTERVAL_END);
#undef PHASE_CONST
}

extern "C" void
Init_vernier(void)
{
    sym_state = sym("state");
    sym_gc_by = sym("gc_by");
    rb_gc_latest_gc_info(sym_state); // HACK: needs to be warmed so that it can be called during GC

  rb_mVernier = rb_define_module("Vernier");
  rb_cVernierResult = rb_define_class_under(rb_mVernier, "Result", rb_cObject);
  VALUE rb_mVernierMarker = rb_define_module_under(rb_mVernier, "Marker");
  VALUE rb_mVernierMarkerPhase = rb_define_module_under(rb_mVernierMarker, "Phase");
  rb_mVernierMarkerType = rb_define_module_under(rb_mVernierMarker, "Type");

  rb_cVernierCollector = rb_define_class_under(rb_mVernier, "Collector", rb_cObject);
  rb_undef_alloc_func(rb_cVernierCollector);
  rb_define_singleton_method(rb_cVernierCollector, "_new", collector_new, 2);
  rb_define_method(rb_cVernierCollector, "start", collector_start, 0);
  rb_define_method(rb_cVernierCollector, "sample", collector_sample, 0);
  rb_define_method(rb_cVernierCollector, "stack_table", collector_stack_table, 0);
  rb_define_private_method(rb_cVernierCollector, "finish",  collector_stop, 0);
  rb_define_private_method(rb_cVernierCollector, "markers",  markers, 0);

  rb_cStackTable = rb_define_class_under(rb_mVernier, "StackTable", rb_cObject);
  rb_undef_alloc_func(rb_cStackTable);
  rb_define_singleton_method(rb_cStackTable, "new", stack_table_new, 0);
  rb_define_method(rb_cStackTable, "current_stack", stack_table_current_stack, -1);
  rb_define_method(rb_cStackTable, "convert", StackTable::stack_table_convert, 2);
  rb_define_method(rb_cStackTable, "stack_parent_idx", stack_table_stack_parent_idx, 1);
  rb_define_method(rb_cStackTable, "stack_frame_idx", stack_table_stack_frame_idx, 1);
  rb_define_method(rb_cStackTable, "frame_line_no", StackTable::stack_table_frame_line_no, 1);
  rb_define_method(rb_cStackTable, "frame_func_idx", StackTable::stack_table_frame_func_idx, 1);
  rb_define_method(rb_cStackTable, "func_name", StackTable::stack_table_func_name, 1);
  rb_define_method(rb_cStackTable, "func_filename", StackTable::stack_table_func_filename, 1);
  rb_define_method(rb_cStackTable, "func_first_lineno", StackTable::stack_table_func_first_lineno, 1);
  rb_define_method(rb_cStackTable, "stack_count", StackTable::stack_table_stack_count, 0);
  rb_define_method(rb_cStackTable, "frame_count", StackTable::stack_table_frame_count, 0);
  rb_define_method(rb_cStackTable, "func_count", StackTable::stack_table_func_count, 0);

  Init_consts(rb_mVernierMarkerPhase);

  //static VALUE gc_hook = Data_Wrap_Struct(rb_cObject, collector_mark, NULL, &_collector);
  //rb_global_variable(&gc_hook);
}
