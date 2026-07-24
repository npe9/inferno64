#include <lib9.h>

uintptr
getcallerpc(void *x)
{
	USED(x);
	return (uintptr) __builtin_return_address(0);
}
