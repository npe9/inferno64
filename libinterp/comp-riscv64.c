/*
 * riscv64: no Dis JIT yet.
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

/*
 * Does this code generator update Heap.ref atomically?
 *
 * The reference count is emitted inline by the generator, and with
 * parallelvm=1 two executors really do touch the same object's count at
 * once.  A generator that emits a plain read-modify-write loses updates
 * exactly as a plain C ->ref++ does, and a lost decrement frees a live
 * object while a lost increment leaks one.  disinit() refuses to run
 * the JIT and the parallel VM together unless this says 1.
 */
int jitrefsatomic = 0;

/*
 * Is there a code generator here at all?
 *
 * compile() in this file returns 0 for everything: there is no JIT for
 * this architecture, only the declaration that keeps the link happy.  A
 * kernel built with cflag=1 therefore printed "jit 1" in its banner and
 * then interpreted every instruction, which is a boot option that reports
 * the opposite of what it did.  disinit() says so and clears cflag now.
 */
int jitpresent = 0;


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
