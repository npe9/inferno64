/*
 * _tas for the 386 libc the embedded programs link against.  9front's
 * libc here has only an amd64 machine directory, whose _tas takes its
 * argument in RARG; on 386 it is on the stack.  Otherwise the same:
 * swap a non-zero word in and answer what was there.
 */
TEXT	_tas(SB), 1, $0
	MOVL	$0xdeaddead, AX
	MOVL	l+0(FP), BX
	XCHGL	AX, (BX)
	RET
