#include <iostream>
#include <iomanip>
#include <vector>
#include <memory>
#include <algorithm>
#include <sstream>
#include <unordered_map>
#include <unordered_set>

#include "vernier.hh"
#include "stack.hh"
#include "ruby/debug.h"

using namespace std;

static VALUE rb_mVernier;

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
    std::unordered_map<Frame, int> frame_to_idx;
    std::unordered_map<FrameInfo, int> frame_info_to_idx;
    std::unordered_map<std::string, int> string_to_idx;

    std::vector<std::string> list;

    int string_index(const std::string str) {
        auto it = string_to_idx.find(str);
        if (it == string_to_idx.end()) {
            list.push_back(str);
            int idx = list.size() - 1;

            auto result = string_to_idx.insert({str, idx});
            it = result.first;
        }

        return it->second;
    }

    int frame_info_index(const FrameInfo info) {
        auto it = frame_info_to_idx.find(info);
        if (it == frame_info_to_idx.end()) {
            std::stringstream ss;
            ss << info;

            int idx = string_index(ss.str());

            auto result = frame_info_to_idx.insert({info, idx});
            it = result.first;
        }

        return it->second;
    }

    int frame_index(const Frame frame) {
        auto it = frame_to_idx.find(frame);
        if (it == frame_to_idx.end()) {
            int idx = frame_info_index(frame.info());

            auto result = frame_to_idx.insert({frame, idx});
            it = result.first;
        }

        return it->second;
    }

    void clear() {
        list.clear();
        frame_to_idx.clear();
        frame_info_to_idx.clear();
        string_to_idx.clear();
    }
};

struct StackTable {
    class Handle {
        int idx;
        Handle(int idx) : idx(idx) {}
    };

    std::unordered_map<VALUE, std::unique_ptr<Stack>> stack_map;
};

struct retained_collector {
    bool ignore_lines = true;

    bool running = false;

    std::unordered_set<VALUE> unique_frames;
    std::unordered_map<VALUE, std::unique_ptr<Stack>> object_frames;
    FrameList frame_list;

    bool start() {
        if (running) {
            return false;
        } else {
            running = true;
            return true;
        }
    }

    void reset() {
        unique_frames.clear();
        object_frames.clear();
        frame_list.clear();

        running = false;
    }

    void record(VALUE obj, VALUE *frames_buffer, int *lines_buffer, int n) {
        object_frames.emplace(
                obj,
                make_unique<Stack>(frames_buffer, lines_buffer, n)
                );
    }
};

static retained_collector _collector;

static VALUE tp_newobj;
static VALUE tp_freeobj;
static void
newobj_i(VALUE tpval, void *data) {
    retained_collector *collector = static_cast<retained_collector *>(data);
    TraceArg tp(tpval);

    VALUE frames_buffer[2048];
    int lines_buffer[2048];
    int n = rb_profile_frames(0, 2048, frames_buffer, lines_buffer);

    for (int i = 0; i < n; i++) {
        collector->unique_frames.insert(frames_buffer[i]);
    }

    if (collector->ignore_lines) {
        fill_n(lines_buffer, n, 0);
    }

    collector->record(tp.obj, frames_buffer, lines_buffer, n);
}

static void
freeobj_i(VALUE tpval, void *data) {
    retained_collector *collector = static_cast<retained_collector *>(data);
    TraceArg tp(tpval);

    collector->object_frames.erase(tp.obj);
}


static VALUE
trace_retained_start(VALUE self) {
    retained_collector *collector = &_collector;

    if (!collector->start()) {
        rb_raise(rb_eRuntimeError, "already running");
    }

    tp_newobj = rb_tracepoint_new(0, RUBY_INTERNAL_EVENT_NEWOBJ, newobj_i, collector);
    tp_freeobj = rb_tracepoint_new(0, RUBY_INTERNAL_EVENT_FREEOBJ, freeobj_i, collector);

    rb_tracepoint_enable(tp_newobj);
    rb_tracepoint_enable(tp_freeobj);

    return Qtrue;
}

#define sym(name) ID2SYM(rb_intern_const(name))

// HACK: This isn't public, but the objspace ext uses it
extern "C" size_t rb_obj_memsize_of(VALUE);

static const char *
ruby_object_type_name(VALUE obj) {
    enum ruby_value_type type = rb_type(obj);

#define TYPE_CASE(x) case (x): return (#x)

    // Many of these are impossible, but it's easier to just include them
    switch (type) {
        TYPE_CASE(T_OBJECT);
        TYPE_CASE(T_CLASS);
        TYPE_CASE(T_MODULE);
        TYPE_CASE(T_FLOAT);
        TYPE_CASE(T_STRING);
        TYPE_CASE(T_REGEXP);
        TYPE_CASE(T_ARRAY);
        TYPE_CASE(T_HASH);
        TYPE_CASE(T_STRUCT);
        TYPE_CASE(T_BIGNUM);
        TYPE_CASE(T_FILE);
        TYPE_CASE(T_DATA);
        TYPE_CASE(T_MATCH);
        TYPE_CASE(T_COMPLEX);
        TYPE_CASE(T_RATIONAL);

        TYPE_CASE(T_NIL);
        TYPE_CASE(T_TRUE);
        TYPE_CASE(T_FALSE);
        TYPE_CASE(T_SYMBOL);
        TYPE_CASE(T_FIXNUM);
        TYPE_CASE(T_UNDEF);

        TYPE_CASE(T_IMEMO);
        TYPE_CASE(T_NODE);
        TYPE_CASE(T_ICLASS);
        TYPE_CASE(T_ZOMBIE);
        TYPE_CASE(T_MOVED);

        default:
        return "unknown type";
    }
#undef TYPE_CASE
}

void index_frames(retained_collector *collector) {
    // Stringify all unique frames we've observed so far
    for (const auto& [obj, stack]: collector->object_frames) {
        for (int i = 0; i < stack->size(); i++) {
            Frame frame = stack->frame(i);
            collector->frame_list.frame_index(frame);
        }
    }
}

static VALUE
trace_retained_stop(VALUE self) {
    // GC before we start turning stacks into strings
    rb_gc();

    // Stop tracking any more new objects, but we'll continue tracking free'd
    // objects as we may be able to free some as we remove our own references
    // to stack frames.
    rb_tracepoint_disable(tp_newobj);

    retained_collector *collector = &_collector;

    std::vector<size_t> weights;

    FrameList &frame_list = collector->frame_list;

    index_frames(collector);

    std::unordered_map<VALUE, FrameInfo> frame_to_info;
    for (const auto &frame: collector->unique_frames) {
	    FrameInfo info(frame, 0);
	    frame_to_info.insert({frame, info});
    }

    // We should have collected info for all our frames, so no need to continue
    // marking them
    collector->unique_frames.clear();

    // GC a few times in hopes of freeing those references
    rb_gc();
    rb_gc();
    rb_gc();

    std::unordered_map<InfoStack, size_t> unique_stacks;
    for (auto& [obj, stack_ptr]: collector->object_frames) {
        const Stack &stack = *stack_ptr;
	InfoStack info_stack;
	//info_stack.push_back(FrameInfo{ruby_object_type_name(obj)});
	for (int i = 0; i < stack.size(); i++) {
		Frame frame = stack.frame(i);
		FrameInfo info = frame_to_info.at(frame.frame);
		info.line = frame.line;
		info_stack.push_back(info);
	}

        enum ruby_value_type type = BUILTIN_TYPE(obj);
        if (type == 0) {
            fprintf(stderr, "ignoring invalid type: %i of %p\n", type, (void *)obj);
            continue;
        }
        size_t memsize = rb_obj_memsize_of(obj);

        auto it = unique_stacks.find(info_stack);
        if (it == unique_stacks.end()) {
            unique_stacks.insert({info_stack, memsize});
        } else {
            it->second += memsize;
        }
    }

    rb_tracepoint_disable(tp_freeobj);

    std::stringstream ss;

    ss << "{\n";
    ss << R"(  "exporter": "speedscope@0.6.0",)" << "\n";
    ss << R"(  "$schema": "https://www.speedscope.app/file-format-schema.json",)" << "\n";

    ss << R"(  "profiles": [)" << "\n";
    ss << R"(    {)" << "\n";
    ss << R"(      "type":"sampled",)" << "\n";
    ss << R"(      "name":"retained",)" << "\n";
    ss << R"(      "unit":"bytes",)" << "\n";
    ss << R"(      "startValue":0,)" << "\n";
    ss << R"(      "endValue":0,)" << "\n";
    ss << R"(      "samples":[)" << "\n";

    bool first = true;
    for (auto& it: unique_stacks) {
        size_t memsize = it.second;
        const InfoStack &stack = it.first;

        ss << (first ? "[" : ",\n[");
        for (int i = stack.size() - 1; i >= 0; i--) {
            const FrameInfo &frame = stack.frame_info(i);
            int index = frame_list.frame_info_index(frame);
            ss << index;
            if (i > 0) ss << ",";
        }
        ss << "]";

        //size_t memsize = rb_obj_memsize_of(obj);
        //ss << ";" << ruby_object_type_name(obj);
        weights.push_back(memsize);

        first = false;
    }

    ss << "\n";
    ss << R"(      ],)" << "\n";
    ss << R"(      "weights":[)" << "\n";

    first = true;
    for (size_t w : weights) {
        if (!first) ss << "," ;
        ss << w;
        first = false;
    }

    ss << "\n";
    ss << R"(      ])" << "\n";
    ss << R"(    })" << "\n"; // sample object
    ss << R"(  ],)" << "\n";   // samples array
    ss << R"(  "shared": {)" << "\n";   // samples array
    ss << R"(    "frames": [)" << "\n";

    first = true;
    for (const std::string &s : frame_list.list) {
        if (!first) ss << ",\n";
        ss << R"(      {"name": )" << std::quoted(s) << "}";
        first = false;
    }

    ss << "\n";
    ss << R"(    ])" << "\n";
    ss << R"(  })" << "\n";   // samples array
    ss << R"(})" << "\n";

    std::string s = ss.str();
    VALUE str = rb_str_new(s.c_str(), s.size());

    collector->reset();

    return str;
}

static void
retained_collector_mark(void *data) {
    retained_collector *collector = static_cast<retained_collector *>(data);

    // We don't mark the objects, but we MUST mark the frames, otherwise they
    // can be garbage collected.
    // When we stop collection we will stringify the remaining frames, and then
    // clear them from the set, allowing them to be removed from out output.
    for (VALUE frame: collector->unique_frames) {
        rb_gc_mark(frame);
    }
}

extern "C" void
Init_vernier(void)
{
  rb_mVernier = rb_define_module("Vernier");

  rb_define_module_function(rb_mVernier, "trace_retained_start", trace_retained_start, 0);
  rb_define_module_function(rb_mVernier, "trace_retained_stop", trace_retained_stop, 0);

  static VALUE gc_hook = Data_Wrap_Struct(rb_cObject, retained_collector_mark, NULL, &_collector);
  rb_global_variable(&gc_hook);
}
