#pragma once

inline const char *
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
