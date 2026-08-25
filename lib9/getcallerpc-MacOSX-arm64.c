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
	 * On ARM64, we can use __builtin_return_address(0) to get
	 * the return address of the current function, which is what
	 * getcallerpc is supposed to return.
	 */
	return (uintptr)__builtin_return_address(0);
}
