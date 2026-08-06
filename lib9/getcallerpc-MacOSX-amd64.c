#include "lib9.h"

uintptr
getcallerpc(void *arg)
{
	USED(arg);
	return (uintptr)__builtin_return_address(1);
}
