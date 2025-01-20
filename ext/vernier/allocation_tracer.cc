#include "vernier.hh"
#include "stack_table.hh"

static VALUE rb_cAllocationTracer;

static const rb_data_type_t rb_allocation_tracer_type = {
    .wrap_struct_name = "vernier/allocation_tracer",
    .function = {
        //.dmemsize = rb_collector_memsize,
        //.dmark = stack_table_mark,
        //.dfree = stack_table_free,
    },
};

class AllocationTracer {
  public:
    VALUE stack_table_value;
    StackTable *stack_table;

    std::unordered_map<VALUE, int> object_frames;
    std::vector<VALUE> object_list;

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

    void record_freeobj(VALUE obj) {
      object_frames.erase(obj);
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

    void stop() {
      if (RTEST(tp_newobj)) {
        rb_tracepoint_disable(tp_newobj);
        tp_newobj = Qnil;
      }
      if (RTEST(tp_freeobj)) {
        rb_tracepoint_disable(tp_freeobj);
        tp_freeobj = Qnil;
      }
    }

    static VALUE stop(VALUE self) {
      get(self)->stop();
      return self;
    }

    static VALUE stack_idx(VALUE self, VALUE obj) {
      int stack_index = get(self)->object_frames.at(obj);
      return INT2NUM(stack_index);
    }
};

void
Init_allocation_tracer() {
  rb_cAllocationTracer = rb_define_class_under(rb_mVernier, "AllocationTracer", rb_cObject);
  rb_define_method(rb_cAllocationTracer, "start", AllocationTracer::start, 0);
  rb_define_method(rb_cAllocationTracer, "stop", AllocationTracer::stop, 0);
  rb_define_method(rb_cAllocationTracer, "stack_idx", AllocationTracer::stack_idx, 1);
  rb_undef_alloc_func(rb_cAllocationTracer);
  rb_define_singleton_method(rb_cAllocationTracer, "_new", AllocationTracer::rb_new, 1);
}
