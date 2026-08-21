/* Compatibility header for host-built native Inferno libraries. */
#include "../../../os/inferno/lib.h"
extern void* mallocz(ulong, int);
extern void free(void*);
