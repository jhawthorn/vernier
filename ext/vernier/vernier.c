#include "vernier.h"

VALUE rb_mVernier;

void
Init_vernier(void)
{
  rb_mVernier = rb_define_module("Vernier");
}
