/*
 * thumb (ARMv7-M): no Dis JIT.
 *
 * The interpreter runs every module; compile() says it could not
 * compile one, which is what the loader does with a module the JIT
 * refuses, so this is the slow path and not a broken one.  The same
 * arrangement as comp-riscv64.c.
 *
 * A compiler here would also have to find somewhere to put what it
 * generates.  The boards this is for run their text from flash and have
 * their RAM measured in hundreds of kilobytes, so compiled code would be
 * competing with the heap for the scarcest thing on the board.
 * comp-arm.c is the nearest thing to model one on if that changes.
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
