#ifndef VERNIER_H
#define VERNIER_H 1

#include "ruby.h"
#include "ruby/assert.h"

// VERNIER_ASSERT is RUBY_ASSERT, which is only active when Ruby itself was
// built with RUBY_DEBUG. Building with VERNIER_ALWAYS_ASSERT (see extconf.rb)
// makes it RUBY_ASSERT_ALWAYS. Use VERNIER_ASSERT_ALWAYS for checks that must
// run in every build.
#ifdef VERNIER_ALWAYS_ASSERT
# define VERNIER_ASSERT RUBY_ASSERT_ALWAYS
#else
# define VERNIER_ASSERT RUBY_ASSERT
#endif
#define VERNIER_ASSERT_ALWAYS RUBY_ASSERT_ALWAYS

// HACK: This isn't public, but the objspace ext uses it
extern "C" size_t rb_obj_memsize_of(VALUE);

#define sym(name) ID2SYM(rb_intern_const(name))

extern VALUE rb_mVernier;

void Init_memory();
void Init_stack_table();
void Init_heap_tracker();

#endif /* VERNIER_H */
