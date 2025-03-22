#include "vernier.hh"
#include "stack_table.hh"

static VALUE rb_cAllocationTracer;

static void allocation_tracer_mark(void *data);
static void allocation_tracer_free(void *data);
static void allocation_tracer_compact(void *data);

static const rb_data_type_t rb_allocation_tracer_type = {
    .wrap_struct_name = "vernier/allocation_tracer",
    .function = {
        .dmark = allocation_tracer_mark,
        .dfree = allocation_tracer_free,
        .dsize = nullptr,
        .dcompact = allocation_tracer_compact,
    },
};

class AllocationTracer {
  public:
    VALUE stack_table_value;
    StackTable *stack_table;

    unsigned long long objects_freed = 0;
    unsigned long long objects_allocated = 0;

    std::unordered_map<VALUE, int> object_index;
    std::vector<VALUE> object_list;
    std::vector<int> frame_list;

    static VALUE rb_new(VALUE self, VALUE stack_table_value) {
      AllocationTracer *allocation_tracer = new AllocationTracer();
      allocation_tracer->stack_table_value = stack_table_value;
      allocation_tracer->stack_table = get_stack_table(stack_table_value);
      VALUE obj = TypedData_Wrap_Struct(rb_cAllocationTracer, &rb_allocation_tracer_type, allocation_tracer);
      rb_ivar_set(obj, rb_intern("@stack_table"), stack_table_value);
      return obj;
    }

    static AllocationTracer *get(VALUE obj) {
      AllocationTracer *allocation_tracer;
      TypedData_Get_Struct(obj, AllocationTracer, &rb_allocation_tracer_type, allocation_tracer);
      return allocation_tracer;
    }

    void record_newobj(VALUE obj) {
      objects_allocated++;

      RawSample sample;
      sample.sample();
      if (sample.empty()) {
        // During thread allocation we allocate one object without a frame
        // (as of Ruby 3.3)
        // Ideally we'd allow empty samples to be represented
        return;
      }
      int stack_index = stack_table->stack_index(sample);

      int idx = object_list.size();
      object_list.push_back(obj);
      frame_list.push_back(stack_index);
      object_index.emplace(obj, idx);

      assert(objects_allocated == frame_list.size());
      assert(objects_allocated == object_list.size());
    }

    void record_freeobj(VALUE obj) {
      auto it = object_index.find(obj);
      if (it != object_index.end()) {
        int index = it->second;
        object_list[index] = Qfalse;
        objects_freed++;
        object_index.erase(it);
      }
    }

    static void newobj_i(VALUE tpval, void *data) {
        AllocationTracer *tracer = static_cast<AllocationTracer *>(data);
        rb_trace_arg_t *tparg = rb_tracearg_from_tracepoint(tpval);
        VALUE obj = rb_tracearg_object(tparg);

        tracer->record_newobj(obj);
    }

    static void freeobj_i(VALUE tpval, void *data) {
        AllocationTracer *tracer = static_cast<AllocationTracer *>(data);
        rb_trace_arg_t *tparg = rb_tracearg_from_tracepoint(tpval);
        VALUE obj = rb_tracearg_object(tparg);

        tracer->record_freeobj(obj);
    }

    bool stopped = false;
    VALUE tp_newobj = Qnil;
    VALUE tp_freeobj = Qnil;

    void start() {
      if (!RTEST(tp_newobj)) {
        tp_newobj = rb_tracepoint_new(0, RUBY_INTERNAL_EVENT_NEWOBJ, newobj_i, this);
        tp_freeobj = rb_tracepoint_new(0, RUBY_INTERNAL_EVENT_FREEOBJ, freeobj_i, this);

        rb_tracepoint_enable(tp_newobj);
        rb_tracepoint_enable(tp_freeobj);
      }
    }
    static VALUE start(VALUE self) {
      get(self)->start();
      return self;
    }

    void pause() {
      if (RTEST(tp_newobj)) {
        rb_tracepoint_disable(tp_newobj);
        tp_newobj = Qnil;
      }
    }

    static VALUE pause(VALUE self) {
      get(self)->pause();
      return self;
    }

    void stop() {
      pause();
      if (RTEST(tp_freeobj)) {
        rb_tracepoint_disable(tp_freeobj);
        tp_freeobj = Qnil;
      }
      stopped = true;
    }

    static VALUE stop(VALUE self) {
      get(self)->stop();
      return self;
    }

    static VALUE stack_idx(VALUE self, VALUE obj) {
      auto tracer = get(self);
      auto iter = tracer->object_index.find(obj);
      if (iter == tracer->object_index.end()) {
        return Qnil;
      } else {
        int index = iter->second;
        return INT2NUM(tracer->frame_list[index]);
      }
    }

    VALUE data() {
      // TOOD: should this ensure we are paused or stopped?
      VALUE hash = rb_hash_new();
      VALUE samples = rb_ary_new();
      rb_hash_aset(hash, sym("samples"), samples);
      VALUE weights = rb_ary_new();
      rb_hash_aset(hash, sym("weights"), weights);

      for (int i = 0; i < object_list.size(); i++) {
        VALUE obj = object_list[i];
        VALUE stack_index = frame_list[i];
        if (obj == Qfalse) continue;

        rb_ary_push(samples, INT2NUM(stack_index));
        rb_ary_push(weights, INT2NUM(rb_obj_memsize_of(obj)));
      }
      return hash;
    }

    static VALUE data(VALUE self) {
      return get(self)->data();
    }

    static VALUE allocated_objects(VALUE self) {
      return ULL2NUM(get(self)->objects_allocated);
    }

    static VALUE freed_objects(VALUE self) {
      return ULL2NUM(get(self)->objects_freed);
    }

    void mark() {
      rb_gc_mark(stack_table_value);

      rb_gc_mark(tp_newobj);
      rb_gc_mark(tp_freeobj);

      if (stopped) {
        for (auto obj: object_list) {
          rb_gc_mark_movable(obj);
        }
      }
    }

    void compact() {
      object_index.clear();
      for (int i = 0; i < object_list.size(); i++) {
        VALUE obj = object_list[i];
        VALUE reloc_obj = rb_gc_location(obj);

        object_list[i] = reloc_obj;
        object_index.emplace(reloc_obj, i);
      }
    }
};

static void
allocation_tracer_mark(void *data) {
    AllocationTracer *allocation_tracer = static_cast<AllocationTracer *>(data);
    allocation_tracer->mark();
}

static void
allocation_tracer_free(void *data) {
    AllocationTracer *allocation_tracer = static_cast<AllocationTracer *>(data);
    delete allocation_tracer;
}

static void
allocation_tracer_compact(void *data) {
    AllocationTracer *allocation_tracer = static_cast<AllocationTracer *>(data);
    allocation_tracer->compact();
}

void
Init_allocation_tracer() {
  rb_cAllocationTracer = rb_define_class_under(rb_mVernier, "AllocationTracer", rb_cObject);
  rb_define_method(rb_cAllocationTracer, "start", AllocationTracer::start, 0);
  rb_define_method(rb_cAllocationTracer, "pause", AllocationTracer::pause, 0);
  rb_define_method(rb_cAllocationTracer, "stop", AllocationTracer::stop, 0);
  rb_define_method(rb_cAllocationTracer, "data", AllocationTracer::data, 0);
  rb_define_method(rb_cAllocationTracer, "stack_idx", AllocationTracer::stack_idx, 1);
  rb_undef_alloc_func(rb_cAllocationTracer);
  rb_define_singleton_method(rb_cAllocationTracer, "_new", AllocationTracer::rb_new, 1);

  rb_define_method(rb_cAllocationTracer, "allocated_objects", AllocationTracer::allocated_objects, 0);
  rb_define_method(rb_cAllocationTracer, "freed_objects", AllocationTracer::freed_objects, 0);
}
