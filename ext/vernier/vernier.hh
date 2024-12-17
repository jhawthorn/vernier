#ifndef VERNIER_H
#define VERNIER_H 1

#include "ruby.h"

extern VALUE rb_mVernier;

void Init_memory();
void Init_stack_table();
void Init_allocation_tracer();

#endif /* VERNIER_H */
