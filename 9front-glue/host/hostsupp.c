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

/*
 * libmp calls mallocz, which 9front's libc has and lib9 does not.
 * mpc, the generator libsec and libauthsrv run over their .mp
 * sources, is linked against this tree's host libmp and wants it.
 */
void*
mallocz(ulong size, int clr)
{
	void *v;

	v = malloc(size);
	if(clr && v != nil)
		memset(v, 0, size);
	return v;
}
