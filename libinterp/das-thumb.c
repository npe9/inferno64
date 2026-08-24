/*
 * das disassembles what the Dis JIT generated.  There is no JIT for
 * thumb (see ../libinterp/comp-thumb.c), so there is nothing to
 * disassemble.
 */
#include <lib9.h>
#include <kernel.h>

void
das(uchar *x, int n)
{
	USED(x);
	USED(n);
}
