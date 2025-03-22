#ifndef STACK_TABLE_HH
#define STACK_TABLE_HH STACK_TABLE_HH

#include "ruby/ruby.h"
#include "ruby/encoding.h"
#include "ruby/debug.h"

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

        if (rb_during_gc()) {
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

// TODO: Rename FuncInfo
struct FrameInfo {
    static const char *label_cstr(VALUE frame) {
        VALUE label = rb_profile_frame_full_label(frame);
        // Currently (2025-03-22, Ruby 3.4.2) this occurs when an iseq method
        // entry is replaced with a refinement
        if (NIL_P(label)) return "(nil)";
        return StringValueCStr(label);
    }

    static const char *file_cstr(VALUE frame) {
        VALUE file = rb_profile_frame_absolute_path(frame);
        if (NIL_P(file))
            file = rb_profile_frame_path(frame);
        if (NIL_P(file)) {
            return "(nil)";
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
    std::vector<StackNode> stack_node_list;
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

        // Ruby constants are in an arbitrary (ASCII compatible) encoding and
        // method names are in an arbitrary (ASCII compatible) encoding. These
        // can be mixed in the same program.
        //
        // However, by this point we've lost the chain of what the correct
        // encoding should be. Oops!
        //
        // Instead we'll just guess at UTF-8 which should satisfy most. It won't
        // necessarily be valid but that can be scrubbed on the Ruby side.
        //
        // In the future we might keep class and method name separate for
        // longer, preserve encodings, and defer formatting to the Ruby side.
        return rb_enc_interned_str(label.c_str(), label.length(), rb_utf8_encoding());
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

        // Technically filesystems are binary and then Ruby interprets that as
        // default_external encoding. But to keep things simple for now we are
        // going to assume UTF-8.
        return rb_enc_interned_str(filename.c_str(), filename.length(), rb_utf8_encoding());
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

#endif
