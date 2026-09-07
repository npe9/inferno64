/*
 * getcallerpc-MacOSX-arm64.c
 *
 * getcallerpc() implementation for macOS ARM64
 */

#include "lib9.h"

/*
 * Plan 9's getcallerpc(&arg) returns the return address of the function
 * that called the one holding arg - so malloc()'s getcallerpc(&size) names
 * malloc's CALLER, which is the whole point: alloc.c stores it in every
 * block header as allocpc, POOLPOISON reports it, and /dev/memleak
 * histograms live blocks by it.
 *
 * This is a real out-of-line function, so __builtin_return_address(0) is
 * the address inside malloc itself - one frame too shallow, and it made
 * every allocation in the system appear to come from four sites inside
 * alloc.c.  Level 1 is malloc's caller.  arm64 macOS keeps the frame
 * pointer in x29, so the walk is reliable here; if a frame is missing the
 * builtin returns nil and level 0 is still better than nothing.
 */
uintptr
getcallerpc(void *arg)
{
	void *pc;

	USED(arg);
	pc = __builtin_return_address(1);
	if(pc == nil)
		pc = __builtin_return_address(0);
	return (uintptr)pc;
}
