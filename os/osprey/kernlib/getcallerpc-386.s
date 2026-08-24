/*
 * The 386 has no register argument: the pointer the caller passes is on
 * the stack, and the return address is the word below it.  The amd64
 * file beside this one does the same thing with the pointer in RARG.
 */
TEXT getcallerpc(SB), 1, $0
	MOVL	a+0(FP), AX
	MOVL	-4(AX), AX
	RET
