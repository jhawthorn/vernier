#ifndef VERNIER_H
#define VERNIER_H 1

#include "ruby.h"

// HACK: This isn't public, but the objspace ext uses it
extern "C" size_t rb_obj_memsize_of(VALUE);

#define sym(name) ID2SYM(rb_intern_const(name))

extern VALUE rb_mVernier;

void Init_memory();
void Init_stack_table();
void Init_heap_tracker();

#endif /* VERNIER_H */
