/*
 * The system call a task makes its own requests with - reserve, tick -
 * number 60, above the Plan 9 table, which an unmodified Plan 9 binary
 * uses whole (its read is pread, 50).  The stub is the shape libc's
 * are: the first argument back on the stack, the number in RARG.
 */
TEXT	ospreyxcall(SB), 1, $0
	MOVQ	RARG, a0+0(FP)
	MOVQ	$60, RARG
	SYSCALL
	RET
