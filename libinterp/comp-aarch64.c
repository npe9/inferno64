/*
 * aarch64 (bare-metal virtarm64 board): no Dis JIT yet.
 *
 * Not to be confused with comp-arm64.c, which is the real, working
 * Apple Silicon JIT for the hosted macOS emu build -- OBJTYPE
 * "arm64" was already claimed by that hosted target when this
 * board's own OBJTYPE was picked, hence "aarch64" here rather than
 * a second "arm64" colliding with it (see doc/inferno-ports.ms).
 * The interpreter runs every module; compile() says it could not
 * compile one, which is what the loader does with a module the JIT
 * refuses, so this is the slow path and not a broken one.
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
