/*
 * disk.h from the imported tree, reachable by name for a host tool
 * without putting the whole of 9front-src/sys/include on the include
 * path.  Doing that would shadow the C library's own headers: 9front
 * has a <string.h> and it is the String library's, not the C one's.
 * The path is relative so nothing here names the build machine.
 */
#include "../../../../9front-src/sys/include/disk.h"
