#ifndef STACK_TABLE_HH
#define STACK_TABLE_HH STACK_TABLE_HH

#include <string>
#include <unordered_map>
#include <vector>

#include "ruby/ruby.h"
#include "ruby/encoding.h"
#include "ruby/debug.h"

struct Frame {
    VALUE frame;
    int line;
};

inline bool operator==(const Frame& lhs, const Frame& rhs) noexcept {
    return lhs.frame == rhs.frame && lhs.line == rhs.line;
}

inline bool operator!=(const Frame& lhs, const Frame& rhs) noexcept {
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

struct FuncInfo {
    static int first_lineno_int(VALUE frame) {
        VALUE first_lineno = rb_profile_frame_first_lineno(frame);
        return NIL_P(first_lineno) ? 0 : FIX2INT(first_lineno);
    }

    static std::string convert_rstring(VALUE rstring) {
        if (NIL_P(rstring)) {
            return "(nil)";
        } else {
            const char *cstring = StringValueCStr(rstring);
            return cstring;
        }
    }

    std::string full_label() const {
        std::string output;
        output.append(classpath);
        output.append(is_singleton ? "." : "#");
        output.append(method_name);
        return output;
    }

    FuncInfo(VALUE frame) :
        label(convert_rstring(rb_profile_frame_label(frame))),
        base_label(convert_rstring(rb_profile_frame_base_label(frame))),
        classpath(convert_rstring(rb_profile_frame_classpath(frame))),
        absolute_path(convert_rstring(rb_profile_frame_absolute_path(frame))),
        method_name(convert_rstring(rb_profile_frame_method_name(frame))),
        path(convert_rstring(rb_profile_frame_path(frame))),
        first_lineno(first_lineno_int(frame)),
        is_singleton(RTEST(rb_profile_frame_singleton_method_p(frame)))
    { }

    std::string label;
    std::string base_label;
    std::string classpath;
    std::string path;
    std::string absolute_path;
    std::string method_name;
    int first_lineno;
    bool is_singleton;
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
    std::vector<FuncInfo> func_info_list;

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
            func_info_list.push_back(FuncInfo(func));
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

    static VALUE stack_table_new();
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

StackTable *get_stack_table(VALUE obj);

#endif
