#ifdef __APPLE__

#include <stdio.h>

// Based loosely on https://github.com/zombocom/get_process_mem
#include <libproc.h>
#include <unistd.h>

#include "vernier.hh"

inline uint64_t memory_rss() {
    pid_t pid = getpid();

    struct proc_taskinfo tinfo;
    int st = proc_pidinfo(pid, PROC_PIDTASKINFO, 0,
                         &tinfo, sizeof(tinfo));

    if (st != sizeof(tinfo)) {
        fprintf(stderr, "VERNIER: warning: proc_pidinfo failed\n");
        return 0;
    }

    return tinfo.pti_resident_size;
}

#else

// Assume linux for now
inline uint64_t memory_rss() {
    // TODO: read /proc/self/statm
    return 0;
}

#endif


static VALUE rb_memory_rss(VALUE self) {
    return ULL2NUM(memory_rss());
}


void Init_memory() {
  rb_define_singleton_method(rb_mVernier, "memory_rss", rb_memory_rss, 0);
}
