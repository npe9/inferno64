#include	"dat.h"

/*
 * Hosted: the compiler has a word for this, and it is the same
 * instruction a native kernel writes by hand in libkern.  The native
 * ones are assembly because the Ken compilers have no such word; see
 * libkern/ainc-amd64.s and libkern/ainc-riscv64.s.
 */
int
ainc(int *p)
{
	return __atomic_add_fetch(p, 1, __ATOMIC_SEQ_CST);
}

int
adec(int *p)
{
	return __atomic_sub_fetch(p, 1, __ATOMIC_SEQ_CST);
}

/*
 * Read and clear, indivisibly.  The collector's nprop flag is tested
 * and then cleared, and a mark landing between those two steps is lost
 * -- at an epoch boundary that ends the epoch with a grey object.
 */
int
aclr(int *p)
{
	return __atomic_exchange_n(p, 0, __ATOMIC_SEQ_CST);
}
