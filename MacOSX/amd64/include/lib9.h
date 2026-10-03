/*
 * Redundant since the arm64 header below sets this itself; kept because
 * the #ifndef makes it harmless and this file is the one documenting why
 * the level has to be raised at all.
 */
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE 1
#endif
#include "../../arm64/include/lib9.h"
#include <sys/stat.h>

#define	DBG	if(debug)print
