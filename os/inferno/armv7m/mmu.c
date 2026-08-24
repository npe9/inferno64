#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

/*
 * An ARMv7-M core has no MMU at all; the most it has is an MPU, which
 * protects but does not translate.  Inferno's processes are kernel
 * threads in one address space, so there is nothing to translate and
 * nothing here to do.  KADDR and PADDR in the board's fns.h are the
 * identity.
 */
void
mmuinit(void)
{
}

ulong
va2pa(void *v)
{
	return (ulong)v;
}

int
segflush(void *p, ulong l)
{
	USED(p, l);
	return 1;
}
