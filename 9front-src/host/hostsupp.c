/*
 * What a host tool needs that this tree's host lib9 does not have.
 * 9front's libc provides _assert, which assert() expands to; lib9
 * does not.
 */
#include <lib9.h>

void
_assert(char *s)
{
	fprint(2, "assert failed: %s\n", s);
	abort();
}
