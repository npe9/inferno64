/*
 * RISC-V 64 Dis JIT stub for KenC / native Inferno.
 * Hosted Linux builds compile comp-riscv64-jit.c as comp-riscv64.o
 * (see libinterp/mkfile).
 */
#include "lib9.h"
#include "isa.h"
#include "interp.h"

void	(*comvec)(void);

int
compile(Module *m, int size, Modlink *ml)
{
	USED(m);
	USED(size);
	USED(ml);
	return 0;
}

void
freecode(void *p)
{
	free(p);
}
