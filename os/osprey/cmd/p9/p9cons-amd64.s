/*
 * The one trap a loaded program makes.
 *
 * Descriptors 0, 1 and 2 of a program the personality loaded are the
 * machine's console, which the personality does not hold: it is the
 * microkernel's, and the way to it is the microkernel's pwrite, number
 * 51 in the Plan 9 table.  p9crt.c used to reach it by calling libc's
 * own pwrite stub, which was fine only for as long as p9crt.c did not
 * define pwrite itself - and it has to, because pwrite(2) on a file the
 * personality holds must go to the personality, not to the console.
 *
 * So the console call is given a name of its own here.  The stub is the
 * shape libc's are: the first argument back on the stack, the number in
 * RARG.
 *
 *	long p9conswrite(int fd, void *buf, long n, vlong off)
 */
TEXT	p9conswrite(SB), 1, $0
	MOVQ	RARG, a0+0(FP)
	MOVQ	$51, RARG
	SYSCALL
	RET
