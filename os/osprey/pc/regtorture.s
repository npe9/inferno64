/*
 * regtorture for 386: does an interrupt on this machine give every
 * register back?
 *
 * The same question os/osprey/pc64/regtorture.s asks of the amd64 trap
 * entry, asked of this one.  The entry here is 9front's own 386
 * _strayintr and intrcommon, which save with PUSHAL and restore with
 * POPAL, and the occasion for the test was a bug of exactly that shape
 * in a sibling kernel: os/inferno/pc64's entry built the Ureg's segment
 * words through AX before it had saved AX, and handed every interrupted
 * program the DS selector in place of its own value.  Reading an entry
 * does not measure it, and a one-instruction window is what a reading
 * misses.
 *
 * Six registers are loaded with distinct values and compared in a spin
 * with interrupts enabled, so a clock tick that clobbers one is caught
 * where it happens.  BP is the counter.  Nothing is reserved on 386 the
 * way R14 and R15 carry m and up on amd64 - this machine keeps them in
 * memory - so the six are every register the loop is not using.
 * Answers 0 if all six survived, otherwise the register's index, 1 for
 * AX through 6 for DI, with the value it came back as in
 * regtorturebad, which is the half that names the cause: a selector, a
 * zero and a half-written word are three different bugs.
 *
 * What it does not cover, so that nobody reads more into a clean run
 * than is there: the system-call entry, which this kernel reaches only
 * from user mode (os/osprey/pc/userregtorture.s measures that one, from
 * a user program, since a kproc spinning here is only ever preempted
 * through _strayintr).  Nor the segment registers, the flags, or any of
 * the x87 and SSE state.  Nor BP, which this loop counts with.
 */
GLOBL regtorturebad+0(SB), $4

TEXT regtorture(SB), 1, $0
	MOVL	n+0(FP), BP		/* iteration count */
	MOVL	$0x11111111, AX
	MOVL	$0x22222222, BX
	MOVL	$0x33333333, CX
	MOVL	$0x44444444, DX
	MOVL	$0x55555555, SI
	MOVL	$0x66666666, DI

_rtloop:
	CMPL	AX, $0x11111111
	JNE	_rtbad1
	CMPL	BX, $0x22222222
	JNE	_rtbad2
	CMPL	CX, $0x33333333
	JNE	_rtbad3
	CMPL	DX, $0x44444444
	JNE	_rtbad4
	CMPL	SI, $0x55555555
	JNE	_rtbad5
	CMPL	DI, $0x66666666
	JNE	_rtbad6
	SUBL	$1, BP
	JNE	_rtloop
	MOVL	$0, AX
	RET

_rtbad1:
	MOVL	AX, regtorturebad+0(SB)
	MOVL	$1, AX
	RET
_rtbad2:
	MOVL	BX, regtorturebad+0(SB)
	MOVL	$2, AX
	RET
_rtbad3:
	MOVL	CX, regtorturebad+0(SB)
	MOVL	$3, AX
	RET
_rtbad4:
	MOVL	DX, regtorturebad+0(SB)
	MOVL	$4, AX
	RET
_rtbad5:
	MOVL	SI, regtorturebad+0(SB)
	MOVL	$5, AX
	RET
_rtbad6:
	MOVL	DI, regtorturebad+0(SB)
	MOVL	$6, AX
	RET

/*
 * The same loop with interrupts disabled.  If this one comes back clean
 * and regtorture() does not, the clobber is the interrupt path and not
 * the loop.  Keep the count small: nothing else runs while this spins.
 */
TEXT regtorturecli(SB), 1, $0
	CLI
	MOVL	n+0(FP), BP
	MOVL	$0x11111111, AX
	MOVL	$0x22222222, BX
	MOVL	$0x33333333, CX
	MOVL	$0x44444444, DX
	MOVL	$0x55555555, SI
	MOVL	$0x66666666, DI

_rtcloop:
	CMPL	AX, $0x11111111
	JNE	_rtcbad
	CMPL	BX, $0x22222222
	JNE	_rtcbad
	CMPL	CX, $0x33333333
	JNE	_rtcbad
	CMPL	DX, $0x44444444
	JNE	_rtcbad
	CMPL	SI, $0x55555555
	JNE	_rtcbad
	CMPL	DI, $0x66666666
	JNE	_rtcbad
	SUBL	$1, BP
	JNE	_rtcloop
	STI
	MOVL	$0, AX
	RET

_rtcbad:
	STI
	MOVL	$1, AX
	RET
