#include "vernier.hh"
#include "stack_table.hh"

static VALUE rb_cStackTable;

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

VALUE
StackTable::stack_table_new() {
    StackTable *stack_table = new StackTable();
    VALUE obj = TypedData_Wrap_Struct(rb_cStackTable, &rb_stack_table_type, stack_table);
    return obj;
}

StackTable *get_stack_table(VALUE obj) {
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
        std::string label = func_info.full_label();

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
        std::string filename = func_info.absolute_path;
        if (filename.empty()) filename = func_info.path;

        // Technically filesystems are binary and then Ruby interprets that as
        // default_external encoding. But to keep things simple for now we are
        // going to assume UTF-8.
        return rb_enc_interned_str(filename.c_str(), filename.length(), rb_utf8_encoding());
    }
}

VALUE
StackTable::stack_table_func_path(VALUE self, VALUE idxval) {
    StackTable *stack_table = get_stack_table(self);
    stack_table->finalize();
    int idx = NUM2INT(idxval);
    auto &table = stack_table->func_info_list;
    if (idx < 0 || idx >= table.size()) {
        return Qnil;
    } else {
        const auto &func_info = table[idx];
        std::string filename = func_info.path;

        // Technically filesystems are binary and then Ruby interprets that as
        // default_external encoding. But to keep things simple for now we are
        // going to assume UTF-8.
        return rb_enc_interned_str(filename.c_str(), filename.length(), rb_utf8_encoding());
    }
}

VALUE
StackTable::stack_table_func_absolute_path(VALUE self, VALUE idxval) {
    StackTable *stack_table = get_stack_table(self);
    stack_table->finalize();
    int idx = NUM2INT(idxval);
    auto &table = stack_table->func_info_list;
    if (idx < 0 || idx >= table.size()) {
        return Qnil;
    } else {
        const auto &func_info = table[idx];
        std::string filename = func_info.absolute_path;

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

VALUE stack_table_new(VALUE self) {
    return StackTable::stack_table_new();
}

void Init_stack_table() {
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
  rb_define_method(rb_cStackTable, "func_path", StackTable::stack_table_func_path, 1);
  rb_define_method(rb_cStackTable, "func_absolute_path", StackTable::stack_table_func_absolute_path, 1);
  rb_define_method(rb_cStackTable, "func_filename", StackTable::stack_table_func_filename, 1);
  rb_define_method(rb_cStackTable, "func_first_lineno", StackTable::stack_table_func_first_lineno, 1);
  rb_define_method(rb_cStackTable, "stack_count", StackTable::stack_table_stack_count, 0);
  rb_define_method(rb_cStackTable, "frame_count", StackTable::stack_table_frame_count, 0);
  rb_define_method(rb_cStackTable, "func_count", StackTable::stack_table_func_count, 0);
}
