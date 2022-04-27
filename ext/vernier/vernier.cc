#include <iostream>
#include <vector>
#include <memory>
#include <algorithm>

#include "vernier.hh"
#include "ruby/debug.h"

using namespace std;

#define numberof(array) ((int)(sizeof(array) / sizeof((array)[0])))

static VALUE rb_mVernier;

struct retained_collector {
    int allocated_objects = 0;
    int freed_objects = 0;
    std::vector<VALUE> raw_frames;
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

struct Frame {
    VALUE frame;
    int line;

    VALUE full_label() const {
        return rb_profile_frame_full_label(frame);
    }

    VALUE absolute_path() const {
        return rb_profile_frame_absolute_path(frame);
    }

    VALUE path() const {
        return rb_profile_frame_path(frame);
    }

    VALUE file() const {
        VALUE file = absolute_path();
        return NIL_P(file) ? path() : file;
    }

    VALUE first_lineno() const {
        return rb_profile_frame_first_lineno(frame);
    }
};

struct Stack {
    std::unique_ptr<VALUE[]> frames;
    std::unique_ptr<int[]> lines;
    int size;

    Stack(const VALUE *_frames, const int *_lines, int size) :
        size(size),
        frames(std::make_unique<VALUE[]>(size)),
        lines(std::make_unique<int[]>(size))
    {
        std::copy_n(_frames, size, &frames[0]);
        std::copy_n(_lines, size, &lines[0]);
    }

    Frame frame(int i) const {
        return Frame{frames[i], lines[i]};
    }
};

ostream& operator<<(ostream& os, const Frame& frame)
{
    VALUE label = frame.full_label();
    VALUE file = frame.absolute_path();
    const char *file_cstr = NIL_P(file) ? "" : StringValueCStr(file);
    os << file_cstr << ":" << frame.line << ":in `" << StringValueCStr(label) << "'";
    return os;
}

ostream& operator<<(ostream& os, const Stack& stack)
{
    for (int i = 0; i < stack.size; i++) {
        Frame frame = stack.frame(i);
        cout << frame << "\n";
        //name = rb_profile_frame_full_label(frame);
    }

    return os;
}

static void
newobj_i(VALUE tpval, void *data) {
    retained_collector *collector = static_cast<retained_collector *>(data);
    TraceArg tp(tpval);
    collector->allocated_objects++;

    VALUE frames_buffer[2048];
    int lines_buffer[2048];
    int n = rb_profile_frames(0, 2048, frames_buffer, lines_buffer);
    Stack stack(frames_buffer, lines_buffer, n);
    std::cout << stack << std::endl;
}

static void
freeobj_i(VALUE tpval, void *data) {
    retained_collector *collector = static_cast<retained_collector *>(data);
    TraceArg tp(tpval);
    collector->freed_objects++;
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

static VALUE
trace_retained_stop(VALUE self) {
    rb_tracepoint_disable(tp_newobj);
    rb_tracepoint_disable(tp_freeobj);

    retained_collector *collector = &_collector;
    VALUE hash = rb_hash_new();
    rb_hash_aset(hash, sym("allocated_objects"), INT2NUM(collector->allocated_objects));
    rb_hash_aset(hash, sym("freed_objects"), INT2NUM(collector->freed_objects));

    return hash;
}

extern "C" void
Init_vernier(void)
{
  rb_mVernier = rb_define_module("Vernier");

  rb_define_module_function(rb_mVernier, "trace_retained_start", trace_retained_start, 0);
  rb_define_module_function(rb_mVernier, "trace_retained_stop", trace_retained_stop, 0);
}
