#include <iostream>
#include <iomanip>
#include <vector>
#include <memory>
#include <algorithm>
#include <sstream>
#include <map>
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

    int stack_index(const Stack &stack) {
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


    void clear() {
        string_list.clear();
        frame_list.clear();
        stack_node_list.clear();
        frame_with_info_list.clear();

        string_to_idx.clear();
        frame_to_idx.clear();
        root_stack_node.children.clear();
    }
};

struct retained_collector {
    bool running = false;

    std::map<VALUE, int> object_frames;
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
        object_frames.clear();
        frame_list.clear();

        running = false;
    }

    void record(VALUE obj, VALUE *frames_buffer, int *lines_buffer, int n) {
        Stack stack(frames_buffer, lines_buffer, n);

        int stack_index = frame_list.stack_index(stack);

        object_frames.emplace(obj, stack_index);
    }
};

static retained_collector _collector;

static VALUE tp_newobj = Qnil;
static VALUE tp_freeobj = Qnil;

static void
newobj_i(VALUE tpval, void *data) {
    retained_collector *collector = static_cast<retained_collector *>(data);
    TraceArg tp(tpval);

    VALUE frames_buffer[2048];
    int lines_buffer[2048];
    int n = rb_profile_frames(0, 2048, frames_buffer, lines_buffer);

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

static VALUE
build_collector_result(retained_collector *collector) {
    FrameList &frame_list = collector->frame_list;

#define sym(name) ID2SYM(rb_intern_const(name))
    VALUE result = rb_hash_new();

    VALUE samples = rb_ary_new();
    rb_hash_aset(result, sym("samples"), samples);
    VALUE weights = rb_ary_new();
    rb_hash_aset(result, sym("weights"), weights);

    for (auto& it: collector->object_frames) {
        VALUE obj = it.first;
        //const Stack &stack = *it.second;
        //int stack_index = frame_list.stack_index(stack);
        int stack_index = it.second;

        rb_ary_push(samples, INT2NUM(stack_index));
        rb_ary_push(weights, INT2NUM(rb_obj_memsize_of(obj)));
    }

    VALUE stack_table = rb_hash_new();
    VALUE stack_table_parent = rb_ary_new();
    VALUE stack_table_frame = rb_ary_new();
    rb_hash_aset(stack_table, sym("parent"), stack_table_parent);
    rb_hash_aset(stack_table, sym("frame"), stack_table_frame);
    for (const auto &stack : frame_list.stack_node_list) {
        VALUE parent_val = stack.parent == -1 ? Qnil : INT2NUM(stack.parent);
        rb_ary_push(stack_table_parent, parent_val);
        rb_ary_push(stack_table_frame, INT2NUM(frame_list.frame_index(stack.frame)));
    }
    rb_hash_aset(result, sym("stack_table"), stack_table);

    VALUE frame_table = rb_hash_new();
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
    rb_hash_aset(result, sym("frame_table"), frame_table);

    // TODO: dedup funcs before this step
    VALUE func_table = rb_hash_new();
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
    rb_hash_aset(result, sym("func_table"), func_table);

    return result;
}

static VALUE
trace_retained_stop(VALUE self) {
    retained_collector *collector = &_collector;

    if (!collector->running) {
        rb_raise(rb_eRuntimeError, "collector not running");
    }

    // GC before we start turning stacks into strings
    rb_gc();

    // Stop tracking any more new objects, but we'll continue tracking free'd
    // objects as we may be able to free some as we remove our own references
    // to stack frames.
    rb_tracepoint_disable(tp_newobj);
    tp_newobj = Qnil;

    FrameList &frame_list = collector->frame_list;

    collector->frame_list.finalize();

    // We should have collected info for all our frames, so no need to continue
    // marking them
    // FIXME: previously here we cleared the list of frames so we would stop
    // marking them. Maybe now we should set a flag so that we stop marking them

    // GC again
    rb_gc();

    rb_tracepoint_disable(tp_freeobj);
    tp_freeobj = Qnil;

    VALUE result = build_collector_result(collector);

    collector->reset();

    return result;
}

static void
retained_collector_mark(void *data) {
    retained_collector *collector = static_cast<retained_collector *>(data);

    // We don't mark the objects, but we MUST mark the frames, otherwise they
    // can be garbage collected.
    // When we stop collection we will stringify the remaining frames, and then
    // clear them from the set, allowing them to be removed from out output.
    for (auto stack_node: collector->frame_list.stack_node_list) {
        rb_gc_mark(stack_node.frame.frame);
    }

    rb_gc_mark(tp_newobj);
    rb_gc_mark(tp_freeobj);
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
