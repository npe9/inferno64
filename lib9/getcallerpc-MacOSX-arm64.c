/*
 * getcallerpc-MacOSX-arm64.c
 * 
 * getcallerpc() implementation for macOS ARM64
 * This function returns the return address of the calling function
 */

#include "lib9.h"

uintptr
getcallerpc(void *arg)
{
	/*
	 * ONE, not zero.
	 *
	 * __builtin_return_address(0) is the return address of THIS
	 * function -- a point inside whoever called getcallerpc -- and
	 * getcallerpc is supposed to return the address inside ITS
	 * caller's caller.  With (0), "panic: decref, pc=..." printed an
	 * address 0x3c into decref itself, which names nobody, and the
	 * same is true of every poolfault in include/pool.h: on this
	 * platform every allocator and refcount diagnostic has been
	 * pointing at the reporting function rather than the culprit.
	 *
	 * The amd64 file beside this one has had (1) all along; this was
	 * a transcription slip when the arm64 port was added, and it
	 * silently disabled the diagnostics that exist for exactly the
	 * bugs that are hardest to find.
	 */
	USED(arg);
	return (uintptr)__builtin_return_address(1);
}
