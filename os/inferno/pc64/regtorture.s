#include "mem.h"

/*
 * regtorture: does an interrupt on this machine give every register
 * back?
 *
 * Every capture in doc/inferno-cloud-plan.ms section 6's batch had the
 * corrupted word equal to R.d and the opcode one that stores an
 * allocator's return value -- INEW writing 0x18, which is H2D() of a
 * nil Heap*, and IADDC, ISLICEC and IINSC each writing 0.  heap(),
 * nheap() and heapz() cannot return nil (they error(exHeap), and
 * error() ends in gotolabel), and os/inferno/pc64/l.s's own OP(new)
 * codegen checks and stores the same register.  That leaves the value
 * being lost between the callee's RET and the caller's store, which on
 * this port can only be an interrupt that does not restore what it
 * saved.
 *
 * This loads twelve registers with distinct values and spins comparing
 * them with interrupts enabled, so a clock tick that clobbers one is
 * caught directly instead of waiting for it to land in the four
 * instructions of OP(new) that matter.  R13 is the counter, R14 and
 * R15 are up and m and are left alone.  Returns 0 if every register
 * survived, otherwise the register's index, 1 for AX through 12 for
 * R12.  Temporary; see doc/inferno-cloud-plan.ms.
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
