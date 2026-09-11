/*
 * The aarch64 EFI entry.  UEFI enters at start with X0 = ImageHandle,
 * X1 = SystemTable, the MMU on, the caches on, and the image wherever
 * the firmware decided to put it.
 */
TEXT start(SB), 1, $-4
	MOV	R30, R19		/* the firmware's return address */
	MOV	R0, R20			/* ImageHandle */
	MOV	R1, R21			/* SystemTable */

	/*
	 * Where are we?  A BL leaves the runtime address of the next
	 * instruction in R30, and MOV $sym(SB) is a PC-relative load of
	 * a literal whose contents are the link-time address -- so the
	 * two differ by however far the firmware moved us.
	 */
	BL	pcnow(SB)

TEXT pcnow(SB), 1, $-4
	MOV	R30, R2			/* runtime address of pcnow */
	MOV	$pcnow(SB), R3		/* link-time address of pcnow */
	SUB	R3, R2, R4		/* delta */

	/*
	 * Nothing to do if the firmware put us where we asked.  edk2 on
	 * aarch64 does: it honours ImageBase for an image with no
	 * relocation section, and then maps that image's pages
	 * read-only, so copying over ourselves is not a waste but a
	 * data abort -- "Permission fault, third level", which is edk2
	 * enforcing W^X on a section this loader declares as both.
	 */
	CBZ	R4, run

	/*
	 * Copy the image back to where it was linked.  The code is not
	 * position independent: globals are reached through R28, which
	 * holds an absolute address, and every MOV $sym(SB) loads one.
	 */
	MOV	$IMAGEBASE, R5		/* destination */
	ADD	R4, R5, R6		/* source */
	MOV	$end(SB), R7
	SUB	R5, R7, R7
	ADD	$7, R7
	AND	$~7, R7			/* length, rounded up to a word */
	MOV	R5, R22			/* keep, for the cache clean below */
	MOV	R7, R23

copy:
	MOV	(R6), R8
	MOV	R8, (R5)
	ADD	$8, R5
	ADD	$8, R6
	SUB	$8, R7
	CBNZ	R7, copy

	/*
	 * The instruction cache is not architecturally coherent with the
	 * data cache, so code written through the D-cache has to be
	 * cleaned to the point of unification before it is fetched.
	 * QEMU will not notice if this is missing; silicon will.  Sixty-
	 * four bytes a line is the smallest any aarch64 part uses, so
	 * stepping by that is safe whatever CTR_EL0 says.
	 */
	MOV	R22, R5
	MOV	R23, R7
clean:
	DC	R5, 3,7,11,1	/* DC CVAU, x5 */
	ADD	$64, R5
	SUB	$64, R7
	CMP	$0, R7
	BGT	clean
	DSB	$11			/* DSB ISH */
	IC	0,7,5,0		/* IC IALLU */
	DSB	$11
	ISB	$15

	/*
	 * Now branch to the copy.  R28 is the static base kencc code
	 * reaches globals through; setSB is a linker symbol in the data
	 * segment, and its absolute address is right once the image is
	 * where it was linked.
	 */
run:
	MOV	$setSB(SB), R28

	/*
	 * kencc passes the first argument in R0 and the rest in the
	 * caller's outgoing argument area at 16(RSP) and up -- an area
	 * this function has no frame for, and writing into it would be
	 * writing into the firmware's own stack.  So the entry takes one
	 * argument, the system table, and the image handle goes in a
	 * global.  R28 is set first because that global is reached
	 * through it.
	 */
	MOV	R20, imagehandle(SB)
	MOV	R21, R0
	MOV	R19, R30		/* so efistart can return to the firmware */
	MOV	$efistart(SB), R9
	B	(R9)

DATA	imagehandle+0(SB)/8, $0
GLOBL	imagehandle(SB), $8

/*
 * eficall(proc, a, b, ...) -- the firmware's calling convention is
 * AAPCS64, with arguments in X0 up, and kencc's is the first argument
 * in R0 and the rest on the stack from 16(RSP).  So: proc arrives in
 * R0, and the arguments it wants are the eight words above it.
 *
 * Eight are loaded whether the caller passed eight or two.  The extra
 * loads read the caller's frame, which is always mapped, and a
 * firmware function ignores the registers beyond its own arity.
 */
TEXT eficall(SB), 1, $-4
	MOV	R30, R24		/* R19..R28 survive an AAPCS64 call */
	MOV	R0, R9
	MOV	RSP, R25
	MOV	16(R25), R0
	MOV	24(R25), R1
	MOV	32(R25), R2
	MOV	40(R25), R3
	MOV	48(R25), R4
	MOV	56(R25), R5
	MOV	64(R25), R6
	MOV	72(R25), R7

	/*
	 * AAPCS64 wants SP 16-byte aligned at a call and SCTLR.SA makes
	 * that a fault rather than a convention.  kencc frame sizes are
	 * multiples of eight, so half the call sites arrive here with SP
	 * at 8 mod 16.
	 */
	SUB	$16, R25, R26
	AND	$~15, R26
	MOV	R26, RSP
	BL	(R9)
	MOV	R25, RSP
	MOV	R24, R30
	RETURN

/*
 * The image is where it was linked by the time any of this runs, so
 * nothing needs rebasing.  efi.c calls this on the function pointers it
 * stores because the arm64 firmware is allowed to move the image; here
 * the move has already been undone.
 */
TEXT rebase(SB), 1, $-4
	RETURN

/*
 * System-register encodings 7a's lexer does not know by name.  SPR() is
 * a.y's escape for an arbitrary SYSARG5-encoded special register; see
 * the same defines at the top of os/inferno/virtarm64/l.s.
 */
#define	SYSARG5(op0,op1,Cn,Cm,op2) ((op0)<<19|(op1)<<16|(Cn)<<12|(Cm)<<8|(op2)<<5)
#define	D_SCTLR_EL1	SYSARG5(3,0,1,0,0)

/*
 * cachewb(va, end) -- clean and invalidate to the point of coherency.
 *
 * The kernel image is written through the data cache with the MMU on
 * and then read with both off, so the lines holding it have to reach
 * memory before jump() turns the cache off.  Sixty-four bytes is the
 * smallest line any aarch64 part uses, so stepping by that is safe
 * whatever CTR_EL0 reports; stepping by more would skip lines.
 *
 * QEMU's caches are coherent and it will pass with this missing.  A
 * real machine will read whatever was in memory before the load.
 */
TEXT cachewb(SB), 1, $-4
	MOV	16(RSP), R1		/* end */
	AND	$~63, R0
wbline:
	DC	R0, 3,7,14,1		/* DC CIVAC, x0 */
	ADD	$64, R0
	CMP	R1, R0
	BLT	wbline
	DSB	$15
	RETURN

/*
 * jump(pc, args) -- hand the machine to the kernel.
 *
 * UEFI hands control over with the MMU on and the caches on, and every
 * arm64 kernel in this tree starts with them off: l.s sets a stack and
 * calls main(), and mmu.c builds the tables and enables translation
 * later.  So they have to be turned off here, in that order -- clear
 * M, C and I in SCTLR_EL1, then synchronise and invalidate the
 * instruction cache, so that nothing fetched afterwards came from a
 * translation that no longer exists.
 *
 * Execution survives clearing M because UEFI identity-maps DRAM: the
 * physical address of the instruction after the MSR is the virtual one
 * it was fetched at.  A firmware that mapped the loader anywhere else
 * would stop here, and there is no way to find that out from inside
 * this function.
 *
 * args goes in x0, which is where an arm64 kernel expects the device
 * tree, and conf in x1, where the Linux boot protocol requires a zero
 * and QEMU's -kernel path leaves one -- so a kernel that does not know
 * about it finds nothing there and a kernel that does gets the
 * configuration block.  Nothing returns.
 */
TEXT jump(SB), 1, $-4
	MOV	R0, R9			/* entry */
	MOV	16(RSP), R10		/* args, for x0 */
	MOV	24(RSP), R11		/* conf, for x1 */

	MRS	SPR(D_SCTLR_EL1), R1
	MOV	$0x1005, R2		/* M | C | I */
	BIC	R2, R1, R1
	MSR	R1, SPR(D_SCTLR_EL1)
	ISB	$15
	IC	0,7,5,0			/* IC IALLU */
	DSB	$15
	ISB	$15

	MOV	R10, R0
	MOV	R11, R1
	B	(R9)
