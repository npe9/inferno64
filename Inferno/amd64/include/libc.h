/* Compatibility header for host-built native Inferno libraries. */
#include "../../../os/inferno/port/lib.h"
extern void* mallocz(ulong, int);
/*
 * lib.h defines assert() in terms of _assert(), which the kernel
 * declares in portfns.h and defines in devcons.c.  A library built
 * this way gets lib.h and not portfns.h, so the macro expanded to an
 * undeclared function and any kernel library using assert() would not
 * compile.  libaml does, so pc64 could not be built from a clean tree
 * at all -- it only appeared to build where an old libaml.a was
 * already sitting in Inferno/amd64/lib and mk had no reason to make
 * it again.
 */
extern void _assert(char*);
extern void free(void*);
