/*
 * The one trap a loaded program makes, for 386.
 *
 * Descriptors 0, 1 and 2 of a program the personality loaded are the
 * machine's console, which the personality does not hold: it is the
 * microkernel's, and the way to it is the microkernel's pwrite, number
 * 51 in the Plan 9 table.  p9crt.c cannot reach it through libc's own
 * pwrite stub, because p9crt.c defines pwrite itself - pwrite(2) on a
 * file the personality holds must go to the personality - so the
 * console call has a name of its own.
 *
 * p9cons-amd64.s says the same in that object type's instructions.  On
 * 386 the arguments are already where the kernel reads them, so the
 * stub is the number and the interrupt.
 *
 *	long p9conswrite(int fd, void *buf, long n, vlong off)
 */
TEXT	p9conswrite(SB), 1, $0
	MOVL	$51, AX
	INT	$64
	RET
