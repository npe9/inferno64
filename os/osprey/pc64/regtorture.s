/*
 * regtorture: does an interrupt on this machine give every register
 * back?
 *
 * The microkernel's trap entry is the one thing every one of the seven
 * configurations runs through, and a register it failed to give back
 * would not look like a trap-entry fault from the outside.  It would
 * look like whatever the interrupted instruction was about to do with
 * that register, which is why the shape is worth testing directly
 * rather than waiting to recognise it: compiled code holds a called
 * function's return value in AX for the one or two instructions before
 * it stores it, so most interrupts land somewhere that does not care,
 * and the ones that do not turn into a nil where a pointer belonged, a
 * fault reading a struct at a small address, or an allocator asked for
 * a size with the top bit set.
 *
 * The occasion for it was a real one, in the sibling kernel rather than
 * this one: os/inferno/pc64's _intrcommon built the Ureg's segment
 * words with AX as its scratch before it pushed AX, and MOVW from a
 * segment register assembles to the 32-bit form, which zero-extends
 * over the whole of RAX.  Every interrupt handed the interrupted code
 * the DS selector - zero - in place of its AX.  This kernel's entry
 * does not have that shape: it is byte for byte 9front's, defers the
 * segment words with SUBQ rather than writing them through a register,
 * and saves AX before using it.  A reading is not a measurement,
 * though, and a one-instruction window is exactly what a reading
 * misses, so this measures.
 *
 * It loads twelve registers with distinct values and spins comparing
 * them with interrupts enabled, so a clock tick that clobbers one is
 * caught where it happens.  R13 is the counter, R14 and R15 are up and
 * m and are left alone.  Returns 0 if every register survived,
 * otherwise the register's index, 1 for AX through 12 for R12, with
 * the value it came back as in regtorturebad - which is the half that
 * names the cause: a selector, a zero and a half-written word are three
 * different bugs.
 *
 * What it does not cover, so that nobody reads more into a clean run
 * than is there: the syscall path, which on this kernel is its own code
 * and not 9front's, is never reached from here - a kproc spinning with
 * interrupts on is only ever preempted through _strayintr.  Nor the
 * segment registers, the flags, or any of the x87 and SSE state.  Nor
 * R13, R14 and R15, which this loop uses.
 *
 * The immediates are all under 2^31 on purpose: CMPQ with a 64-bit
 * immediate is not encodable.
 *
 * Copied from os/inferno/pc64/regtorture.s, which is where the bug it
 * was written for lived.  Copied rather than shared because kernels in
 * this tree are self-contained: no file under one flavour names
 * another's source directory.
 */
GLOBL regtorturebad+0(SB), $8

TEXT regtorture(SB), 1, $-4
	MOVQ	RARG, R13		/* iteration count */
	MOVQ	$0x11111111, AX
	MOVQ	$0x22222222, BX
	MOVQ	$0x33333333, CX
	MOVQ	$0x44444444, DX
	MOVQ	$0x55555555, SI
	MOVQ	$0x66666666, DI
	MOVQ	$0x77777777, BP
	MOVQ	$0x18888888, R8
	MOVQ	$0x19999999, R9
	MOVQ	$0x1aaaaaaa, R10
	MOVQ	$0x1bbbbbbb, R11
	MOVQ	$0x1ccccccc, R12

_rtloop:
	CMPQ	AX, $0x11111111
	JNE	_rtbad1
	CMPQ	BX, $0x22222222
	JNE	_rtbad2
	CMPQ	CX, $0x33333333
	JNE	_rtbad3
	CMPQ	DX, $0x44444444
	JNE	_rtbad4
	CMPQ	SI, $0x55555555
	JNE	_rtbad5
	CMPQ	DI, $0x66666666
	JNE	_rtbad6
	CMPQ	BP, $0x77777777
	JNE	_rtbad7
	CMPQ	R8, $0x18888888
	JNE	_rtbad8
	CMPQ	R9, $0x19999999
	JNE	_rtbad9
	CMPQ	R10, $0x1aaaaaaa
	JNE	_rtbad10
	CMPQ	R11, $0x1bbbbbbb
	JNE	_rtbad11
	CMPQ	R12, $0x1ccccccc
	JNE	_rtbad12
	SUBQ	$1, R13
	JNE	_rtloop
	MOVQ	$0, AX
	RET

_rtbad1:
	MOVQ	AX, regtorturebad+0(SB)
	MOVQ	$1, AX
	RET
_rtbad2:
	MOVQ	BX, regtorturebad+0(SB)
	MOVQ	$2, AX
	RET
_rtbad3:
	MOVQ	CX, regtorturebad+0(SB)
	MOVQ	$3, AX
	RET
_rtbad4:
	MOVQ	DX, regtorturebad+0(SB)
	MOVQ	$4, AX
	RET
_rtbad5:
	MOVQ	SI, regtorturebad+0(SB)
	MOVQ	$5, AX
	RET
_rtbad6:
	MOVQ	DI, regtorturebad+0(SB)
	MOVQ	$6, AX
	RET
_rtbad7:
	MOVQ	BP, regtorturebad+0(SB)
	MOVQ	$7, AX
	RET
_rtbad8:
	MOVQ	R8, regtorturebad+0(SB)
	MOVQ	$8, AX
	RET
_rtbad9:
	MOVQ	R9, regtorturebad+0(SB)
	MOVQ	$9, AX
	RET
_rtbad10:
	MOVQ	R10, regtorturebad+0(SB)
	MOVQ	$10, AX
	RET
_rtbad11:
	MOVQ	R11, regtorturebad+0(SB)
	MOVQ	$11, AX
	RET
_rtbad12:
	MOVQ	R12, regtorturebad+0(SB)
	MOVQ	$12, AX
	RET

/*
 * The same loop with interrupts disabled.  If this one comes back
 * clean and regtorture() does not, the clobber is the interrupt path
 * and not the loop.  Keep the count small: nothing else runs while
 * this spins.
 */
TEXT regtorturecli(SB), 1, $-4
	CLI
	MOVQ	RARG, R13
	MOVQ	$0x11111111, AX
	MOVQ	$0x22222222, BX
	MOVQ	$0x33333333, CX
	MOVQ	$0x44444444, DX
	MOVQ	$0x55555555, SI
	MOVQ	$0x66666666, DI
	MOVQ	$0x77777777, BP
	MOVQ	$0x18888888, R8
	MOVQ	$0x19999999, R9
	MOVQ	$0x1aaaaaaa, R10
	MOVQ	$0x1bbbbbbb, R11
	MOVQ	$0x1ccccccc, R12

_rtcloop:
	CMPQ	AX, $0x11111111
	JNE	_rtcbad
	CMPQ	BX, $0x22222222
	JNE	_rtcbad
	CMPQ	CX, $0x33333333
	JNE	_rtcbad
	CMPQ	DX, $0x44444444
	JNE	_rtcbad
	CMPQ	SI, $0x55555555
	JNE	_rtcbad
	CMPQ	DI, $0x66666666
	JNE	_rtcbad
	CMPQ	BP, $0x77777777
	JNE	_rtcbad
	CMPQ	R8, $0x18888888
	JNE	_rtcbad
	CMPQ	R9, $0x19999999
	JNE	_rtcbad
	CMPQ	R10, $0x1aaaaaaa
	JNE	_rtcbad
	CMPQ	R11, $0x1bbbbbbb
	JNE	_rtcbad
	CMPQ	R12, $0x1ccccccc
	JNE	_rtcbad
	SUBQ	$1, R13
	JNE	_rtcloop
	STI
	MOVQ	$0, AX
	RET

_rtcbad:
	STI
	MOVQ	$1, AX
	RET
