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

#include "vernier.hh"
#include "timestamp.hh"
#include "periodic_thread.hh"
#include "signal_safe_semaphore.hh"
#include "stack_table.hh"

#include "ruby/ruby.h"
#include "ruby/encoding.h"
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
  RUBY_EVENT_FIBER_SWITCH | \
  RUBY_EVENT_THREAD_END

#define sym(name) ID2SYM(rb_intern_const(name))

// HACK: This isn't public, but the objspace ext uses it
extern "C" size_t rb_obj_memsize_of(VALUE);

using namespace std;

VALUE rb_mVernier;
static VALUE rb_cVernierResult;
static VALUE rb_mVernierMarkerType;
static VALUE rb_cVernierCollector;

static VALUE sym_state, sym_gc_by, sym_fiber_id;

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
    struct {
        VALUE fiber_id;
    } fiber_data;
};

#define EACH_MARKER(XX) \
    XX(GVL_THREAD_STARTED) \
    XX(GVL_THREAD_EXITED) \
\
    XX(GC_START) \
    XX(GC_END_MARK) \
    XX(GC_END_SWEEP) \
    XX(GC_ENTER) \
    XX(GC_EXIT) \
    XX(GC_PAUSE) \
\
    XX(THREAD_RUNNING) \
    XX(THREAD_STALLED) \
    XX(THREAD_SUSPENDED) \
\
    XX(FIBER_SWITCH)


class Marker {
    public:
    enum Type {
#define XX(name) MARKER_ ## name,
        EACH_MARKER(XX)
#undef XX
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

    VALUE to_array() const {
        VALUE record[6] = {0};
        record[0] = INT2NUM(type);
        record[1] = INT2NUM(phase);
        record[2] = ULL2NUM(timestamp.nanoseconds());

        if (phase == Marker::Phase::INTERVAL) {
            record[3] = ULL2NUM(finish.nanoseconds());
        }
        else {
            record[3] = Qnil;
        }
        record[4] = stack_index == -1 ? Qnil : INT2NUM(stack_index);

        if (type == Marker::MARKER_GC_PAUSE) {
            VALUE hash = rb_hash_new();
            record[5] = hash;

            rb_hash_aset(hash, sym_gc_by, extra_info.gc_data.gc_by);
            rb_hash_aset(hash, sym_state, extra_info.gc_data.gc_state);
        } else if (type == Marker::MARKER_FIBER_SWITCH) {
            VALUE hash = rb_hash_new();
            record[5] = hash;

            rb_hash_aset(hash, sym_fiber_id, extra_info.fiber_data.fiber_id);
        }
        return rb_ary_new_from_values(6, record);
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

            list.push_back({ type, Marker::INSTANT, TimeStamp::Now(), TimeStamp(), stack_index, extra_info });
        }

        VALUE to_array() const {
            VALUE ary = rb_ary_new();
            for (auto& marker: list) {
                rb_ary_push(ary, marker.to_array());
            }
            return ary;
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
    CATEGORY_STALLED
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
          // FIXME: probably better to avoid generating -1 higher up.
          // Currently this happens when we measure an empty stack. Ideally we would have a better representation
          if (stack_index < 0)
            return;

          if (!empty() && stacks.back() == stack_index &&
              categories.back() == category) {
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
            if (stack_idx >= 0) {
                allocation_samples.record_sample(stack_idx, TimeStamp::Now(), 1);
            } else {
                // TODO: should we log an empty frame?
            }
        }

        void record_fiber(VALUE fiber, StackTable &frame_list) {
            RawSample sample;
            sample.sample();

            int stack_idx = translator.translate(frame_list, sample);
            VALUE fiber_id = rb_obj_id(fiber);
            markers->record(Marker::Type::MARKER_FIBER_SWITCH, stack_idx, { .fiber_data = { .fiber_id = fiber_id } });
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
        rb_hash_aset(meta, sym("allocation_interval"), Qnil);

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

    virtual void compact() {
    };
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

    void compact() {
        RetainedCollector *collector = this;
        for (auto& obj: collector->object_list) {
            VALUE reloc_obj = rb_gc_location(obj);
            
            const auto search = collector->object_frames.find(obj);
            if (search != collector->object_frames.end()) {
                int stack_index = search->second;
                
                collector->object_frames.erase(search);
                collector->object_frames.emplace(reloc_obj, stack_index);
            }
            
            obj = reloc_obj;
        }
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
    class TimeCollectorThread : public PeriodicThread {
        TimeCollector &time_collector;

        void run_iteration() {
            time_collector.run_iteration();
        }

        public:

        TimeCollectorThread(TimeCollector &tc, TimeStamp interval) : PeriodicThread(interval), time_collector(tc) {
        };
    };

    GCMarkerTable gc_markers;
    ThreadTable threads;

    pthread_t sample_thread;

    atomic_bool running;
    SignalSafeSemaphore thread_stopped;

    TimeStamp interval;
    unsigned int allocation_interval;
    unsigned int allocation_tick = 0;

    VALUE tp_newobj = Qnil;

    static void newobj_i(VALUE tpval, void *data) {
        TimeCollector *collector = static_cast<TimeCollector *>(data);
        rb_trace_arg_t *tparg = rb_tracearg_from_tracepoint(tpval);
        VALUE obj = rb_tracearg_object(tparg);

        collector->record_newobj(obj);
    }

    TimeCollectorThread collector_thread;

    public:
    TimeCollector(VALUE stack_table, TimeStamp interval, unsigned int allocation_interval) : BaseCollector(stack_table), interval(interval), allocation_interval(allocation_interval), threads(*get_stack_table(stack_table)), collector_thread(*this, interval) {
    }

    void record_newobj(VALUE obj) {
        if (++allocation_tick < allocation_interval) {
            return;
        }
        allocation_tick = 0;

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

    void record_fiber(VALUE th, VALUE fiber) {
        threads.mutex.lock();
        for (auto &threadptr : threads.list) {
            auto &thread = *threadptr;
            if (th == thread.ruby_thread) {
                thread.record_fiber(fiber, threads.frame_list);
                break;
            }
        }
        threads.mutex.unlock();
    }

    void write_meta(VALUE meta, VALUE result) {
        BaseCollector::write_meta(meta, result);
        rb_hash_aset(meta, sym("interval"), ULL2NUM(interval.microseconds()));
        rb_hash_aset(meta, sym("allocation_interval"), ULL2NUM(allocation_interval));

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

    void run_iteration() {
        TimeStamp sample_start = TimeStamp::Now();

        LiveSample sample;

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
                    record_sample(sample.sample, sample_start, thread, CATEGORY_NORMAL);
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
    }

    static void internal_thread_event_cb(rb_event_flag_t event, VALUE data, VALUE self, ID mid, VALUE klass) {
        TimeCollector *collector = static_cast<TimeCollector *>((void *)NUM2ULL(data));

        switch (event) {
            case RUBY_EVENT_FIBER_SWITCH:
                collector->record_fiber(rb_thread_current(), rb_fiber_current());
                break;
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
                collector->gc_markers.record_gc_entered();
                break;
            case RUBY_INTERNAL_EVENT_GC_EXIT:
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

        if (allocation_interval > 0) {
            tp_newobj = rb_tracepoint_new(0, RUBY_INTERNAL_EVENT_NEWOBJ, newobj_i, this);
            rb_tracepoint_enable(tp_newobj);
        }

        GlobalSignalHandler::get_instance()->install();

        running = true;

        collector_thread.start();

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

        collector_thread.stop();

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

        rb_ivar_set(result, rb_intern("@gc_markers"), this->gc_markers.to_array());

        VALUE threads = rb_hash_new();
        rb_ivar_set(result, rb_intern("@threads"), threads);

        for (const auto& thread: this->threads.list) {
            VALUE hash = rb_hash_new();
            thread->samples.write_result(hash);
            thread->allocation_samples.write_result(hash);
            rb_hash_aset(hash, sym("markers"), thread->markers->to_array());
            rb_hash_aset(hash, sym("tid"), ULL2NUM(thread->native_tid));
            rb_hash_aset(hash, sym("started_at"), ULL2NUM(thread->started_at.nanoseconds()));
            if (!thread->stopped_at.zero()) {
                rb_hash_aset(hash, sym("stopped_at"), ULL2NUM(thread->stopped_at.nanoseconds()));
            }
            rb_hash_aset(hash, sym("is_main"), thread->is_main() ? Qtrue : Qfalse);
            rb_hash_aset(hash, sym("is_start"), thread->is_start(BaseCollector::start_thread) ? Qtrue : Qfalse);

            rb_hash_aset(threads, thread->ruby_thread_id, hash);
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

static void
collector_compact(void *data) {
    BaseCollector *collector = static_cast<BaseCollector *>(data);
    collector->compact();
}

static const rb_data_type_t rb_collector_type = {
    .wrap_struct_name = "vernier/collector",
    .function = {
        //.dmemsize = rb_collector_memsize,
        .dmark = collector_mark,
        .dfree = collector_free,
        .dsize = NULL,
        .dcompact = collector_compact,
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
        rb_raise(rb_eRuntimeError, "collector already running");
    }

    return Qtrue;
}

static VALUE
collector_stop(VALUE self) {
    auto *collector = get_collector(self);

    VALUE result = collector->stop();
    return result;
}

static VALUE collector_new(VALUE self, VALUE mode, VALUE options) {
    BaseCollector *collector;

    VALUE stack_table = StackTable::stack_table_new();
    if (mode == sym("retained")) {
        collector = new RetainedCollector(stack_table);
    } else if (mode == sym("wall")) {
        VALUE intervalv = rb_hash_aref(options, sym("interval"));
        TimeStamp interval;
        if (NIL_P(intervalv)) {
            interval = TimeStamp::from_microseconds(500);
        } else {
            interval = TimeStamp::from_microseconds(NUM2UINT(intervalv));
        }

        VALUE allocation_intervalv = rb_hash_aref(options, sym("allocation_interval"));
        if (NIL_P(allocation_intervalv))
            allocation_intervalv = rb_hash_aref(options, sym("allocation_sample_rate"));

        unsigned int allocation_interval;
        if (NIL_P(allocation_intervalv)) {
            allocation_interval = 0;
        } else {
            allocation_interval = NUM2UINT(allocation_intervalv);
        }
        collector = new TimeCollector(stack_table, interval, allocation_interval);
    } else {
        rb_raise(rb_eArgError, "invalid mode");
    }
    VALUE obj = TypedData_Wrap_Struct(self, &rb_collector_type, collector);
    rb_ivar_set(obj, rb_intern("@stack_table"), stack_table);
    rb_funcall(obj, rb_intern("initialize"), 2, mode, options);
    return obj;
}

static void
Init_consts(VALUE rb_mVernierMarkerPhase) {
#define XX(name) \
    rb_define_const(rb_mVernierMarkerType, #name, INT2NUM(Marker::Type::MARKER_##name));
    EACH_MARKER(XX)
#undef XX

#define PHASE_CONST(name) \
    rb_define_const(rb_mVernierMarkerPhase, #name, INT2NUM(Marker::Phase::name))

    PHASE_CONST(INSTANT);
    PHASE_CONST(INTERVAL);
    PHASE_CONST(INTERVAL_START);
    PHASE_CONST(INTERVAL_END);
#undef PHASE_CONST
}

extern "C" __attribute__ ((__visibility__("default"))) void
Init_vernier(void)
{
    sym_state = sym("state");
    sym_gc_by = sym("gc_by");
    sym_fiber_id = sym("fiber_id");
    rb_gc_latest_gc_info(sym_state); // HACK: needs to be warmed so that it can be called during GC

  rb_mVernier = rb_define_module("Vernier");
  rb_cVernierResult = rb_define_class_under(rb_mVernier, "Result", rb_cObject);
  VALUE rb_mVernierMarker = rb_define_module_under(rb_mVernier, "Marker");
  VALUE rb_mVernierMarkerPhase = rb_define_module_under(rb_mVernierMarker, "Phase");
  rb_mVernierMarkerType = rb_define_module_under(rb_mVernierMarker, "Type");

  rb_cVernierCollector = rb_define_class_under(rb_mVernier, "Collector", rb_cObject);
  //rb_undef_alloc_func(rb_cVernierCollector);
  rb_define_singleton_method(rb_cVernierCollector, "_new", collector_new, 2);
  rb_define_method(rb_cVernierCollector, "start", collector_start, 0);
  rb_define_private_method(rb_cVernierCollector, "finish",  collector_stop, 0);

  Init_consts(rb_mVernierMarkerPhase);
  Init_memory();
  Init_stack_table();
  Init_allocation_tracer();

  //static VALUE gc_hook = Data_Wrap_Struct(rb_cObject, collector_mark, NULL, &_collector);
  //rb_global_variable(&gc_hook);
}
