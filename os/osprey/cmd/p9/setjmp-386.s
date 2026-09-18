/*
 * setjmp and longjmp for 386, which 9front's libc here has for amd64
 * only (9front/src/libc/amd64/setjmp.s).  The same two words in the
 * same order - u.h says jmp_buf is two longs, JMPBUFSP first and
 * JMPBUFPC second - and the same convention as the personality's own
 * setlabel and gotolabel beside them in xcall-386.s.
 *
 * The difference from the amd64 file is where the arguments are: 6c
 * passes the first in a register (RARG) and 8c passes every one on the
 * stack.
 */
TEXT	longjmp(SB), $0
	MOVL	l+0(FP), AX
	MOVL	r+4(FP), BX
	CMPL	BX, $0
	JNE	ok		/* ansi: "longjmp(0) => longjmp(1)" */
	MOVL	$1, BX		/* bless their pointed heads */
ok:
	MOVL	0(AX), SP	/* restore sp */
	MOVL	4(AX), CX	/* put return pc on the stack */
	MOVL	CX, 0(SP)
	MOVL	BX, AX		/* the value setjmp answers with */
	RET

TEXT	setjmp(SB), $0
	MOVL	l+0(FP), AX
	MOVL	SP, 0(AX)	/* store sp */
	MOVL	0(SP), BX	/* store return pc */
	MOVL	BX, 4(AX)
	MOVL	$0, AX		/* return 0 */
	RET
