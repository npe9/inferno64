/*
 * riscv32: no Dis JIT yet.
 *
 * The interpreter runs every module; compile() says it could not
 * compile one, which is what the loader does with a module the JIT
 * refuses, so this is the slow path and not a broken one.  A real
 * compiler for this architecture goes here, and comp-arm64.c is the
 * nearest thing to model it on.
 */
#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "raise.h"

void (*comvec)(void);

int
compile(Module *m, int size, Modlink *ml)
{
	USED(m);
	USED(size);
	USED(ml);
	return 0;
}

void
preheat(void)
{
}
