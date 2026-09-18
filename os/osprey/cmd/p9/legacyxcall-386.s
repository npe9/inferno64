/*
 * The legacy program's one request of its own: number 60, above the
 * Plan 9 table (see xcall-386.s), here so that an unmodified Plan 9
 * binary can ask the microkernel to move it.  The amd64 file beside
 * this one is legacyxcall-amd64.s.
 */
TEXT	ospreyxcall(SB), 1, $0
	MOVL	$60, AX
	INT	$64
	RET
