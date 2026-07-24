#include <sys/types.h>

#include "dat.h"

int
segflush(void *a, ulong n)
{
	USED(a);
	USED(n);
	__asm__ volatile("fence.i" ::: "memory");
	return 0;
}
