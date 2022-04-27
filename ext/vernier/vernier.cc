#include <iostream>
#include <vector>
#include <memory>
#include <algorithm>
#include <unordered_map>

#include "vernier.hh"
#include "stack.hh"
#include "ruby/debug.h"

using namespace std;

#define numberof(array) ((int)(sizeof(array) / sizeof((array)[0])))

static VALUE rb_mVernier;

struct retained_collector {
    int allocated_objects = 0;
    int freed_objects = 0;

    std::unordered_map<VALUE, std::unique_ptr<Stack>> object_frames;
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

static retained_collector _collector;

static VALUE tp_newobj;
static VALUE tp_freeobj;
static void
newobj_i(VALUE tpval, void *data) {
    retained_collector *collector = static_cast<retained_collector *>(data);
    TraceArg tp(tpval);
    collector->allocated_objects++;

    VALUE frames_buffer[2048];
    int lines_buffer[2048];
    int n = rb_profile_frames(0, 2048, frames_buffer, lines_buffer);

    collector->object_frames.emplace(
            tp.obj,
            make_unique<Stack>(frames_buffer, lines_buffer, n)
            );
}

static void
freeobj_i(VALUE tpval, void *data) {
    retained_collector *collector = static_cast<retained_collector *>(data);
    TraceArg tp(tpval);
    collector->freed_objects++;

    collector->object_frames.erase(tp.obj);
}


static VALUE
trace_retained_start(VALUE self) {
    retained_collector *collector = &_collector;

    tp_newobj = rb_tracepoint_new(0, RUBY_INTERNAL_EVENT_NEWOBJ, newobj_i, collector);
    tp_freeobj = rb_tracepoint_new(0, RUBY_INTERNAL_EVENT_FREEOBJ, freeobj_i, collector);

    rb_tracepoint_enable(tp_newobj);
    rb_tracepoint_enable(tp_freeobj);

    return Qtrue;
}

#define sym(name) ID2SYM(rb_intern_const(name))

// HACK: This isn't public, but the objspace ext uses it
extern "C" size_t rb_obj_memsize_of(VALUE);

static VALUE
trace_retained_stop(VALUE self) {
    rb_tracepoint_disable(tp_newobj);
    rb_tracepoint_disable(tp_freeobj);

    retained_collector *collector = &_collector;
    VALUE hash = rb_hash_new();
    rb_hash_aset(hash, sym("allocated_objects"), INT2NUM(collector->allocated_objects));
    rb_hash_aset(hash, sym("freed_objects"), INT2NUM(collector->freed_objects));

    for (auto& it: collector->object_frames) {
        VALUE obj = it.first;
        const Stack &stack = *it.second;

        for (int i = stack.size() - 1; i >= 0; i--) {
            const Frame &frame = stack.frame(i);
            cout << frame;
            if (i > 0) cout << ";";
        }
        cout << " " << rb_obj_memsize_of(obj) << endl;
        //cout << stack << endl;
    }

    return hash;
}

static void
retained_collector_mark(void *data) {
    retained_collector *collector = static_cast<retained_collector *>(data);

    // We don't mark the objects, but we MUST mark the frames, otherwise they
    // can be garbage collected.
    // This may lead to method entries being unnecessarily retained.
    for (auto& it: collector->object_frames) {
        const Stack &stack = *it.second;

        for (int i = 0; i < stack.size(); i++) {
            rb_gc_mark(stack.frames[i]);
        }
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
