/*
 * getcallerpc-Linux-arm64.c
 *
 * The same as the Linux/amd64 and MacOSX/arm64 ones: the compiler
 * knows the return address, and asking it is both shorter and more
 * portable than walking the frame by hand, which is what the older
 * per-architecture files in this directory do.
 */

#include <lib9.h>

uintptr
getcallerpc(void *x)
{
	USED(x);
	return (uintptr)__builtin_return_address(0);
}
