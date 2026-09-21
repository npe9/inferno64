#define	HIOFFSET	4	/* byte offset of high-order word in little-endian vlongs */
#include	"comp-mips.c"

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

