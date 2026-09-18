/*
 * The legacy program's one request of its own: number 60, above the
 * Plan 9 table (see ../p9/xcall.s), here so that an unmodified Plan 9
 * binary can ask the microkernel to move it.
 */
TEXT	ospreyxcall(SB), 1, $0
	MOVQ	RARG, a0+0(FP)
	MOVQ	$60, RARG
	SYSCALL
	RET
