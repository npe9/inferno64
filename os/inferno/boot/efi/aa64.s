/*
 * AArch64 half of the UEFI loader, the shape os/inferno/boot/efi/x64.s
 * has for amd64.  Three things are different from that file and each
 * is a property of the architecture rather than a choice:
 *
 * 1. UEFI enters an AArch64 image with AAPCS64 arguments, X0 =
 *    ImageHandle and X1 = SystemTable, and 7c takes its first argument
 *    in R0 and the rest off the stack (arg1 at 8(FP), which the caller
 *    writes at 16(RSP) -- verified with 7c -S).  So efimain(ih, st) is
 *    reached with ih in R0 and st stored where the callee looks.
 *
 * 2. eficall() has to build an AAPCS64 call out of a 7c one: the
 *    function in R0 and the arguments on the stack become X0..X7 with
 *    the ninth onwards back on the stack.  The most any caller passes
 *    is eleven (pxe->UdpWrite in ../efi/pxe.c), so eleven is what this
 *    marshals.
 *
 * 3. The copy to IMAGEBASE writes instructions through the data side,
 *    which on AArch64 the instruction fetch will not see without cache
 *    maintenance.  DC/IC are SYS aliases 7a has no rows for; the
 *    SYSARG5 forms below are the ones os/inferno/raspi3b/l.s already
 *    verified byte for byte with 7l -a.
 */

#define	SYSARG5(op0,op1,Cn,Cm,op2)	((op0)<<19|(op1)<<16|(Cn)<<12|(Cm)<<8|(op2)<<5)

GLOBL	jumpentry(SB), $8
DATA	jumpentry(SB)/8, $0

TEXT start(SB), 1, $-4
	MOV	R0, R19			/* ImageHandle */
	MOV	R1, R20			/* SystemTable */
	BL	reloc(SB)

/*
 * BL above leaves the runtime address of this instruction in R30, and
 * its link-time address is reloc(SB); the difference is where the
 * firmware put the image.  Copy the whole image down to IMAGEBASE,
 * which is where 7l linked it, and enter efimain there.
 */
TEXT reloc(SB), 1, $-4
	MOV	$reloc-IMAGEBASE(SB), R1
	SUB	R1, R30, R21		/* R21 = load address, kept across the call below */
	MOV	$IMAGEBASE, R3
	MOV	$edata-IMAGEBASE(SB), R4
	CBZ	R4, entry
	CMP	R21, R3
	BEQ	entry			/* already where it was linked */

	/*
	 * The destination is ordinary RAM as far as the firmware is
	 * concerned, and ArmVirtQemu marks free conventional memory
	 * non-executable, so the copy lands somewhere that cannot be
	 * entered -- an instruction abort, ESR 0x8600000E, at the first
	 * instruction of the copied image.  efiallocpages() in efi.c
	 * claims the range as EfiLoaderCode first.  R28 has to point at
	 * the loaded image for that call, since it reaches its globals
	 * through SB; the absolute value is set again at entry, from a
	 * literal rather than from R28, so this does not disturb it.
	 * R21, R19 and R20 are callee-saved in AAPCS64 and survive.
	 */
	MOV	$setSB-IMAGEBASE(SB), R1
	ADD	R21, R1, R28
	SUB	$32, RSP
	MOV	$IMAGEBASE, R1
	MOV	R1, 16(RSP)		/* addr */
	MOV	$end-IMAGEBASE(SB), R2	/* through bss, not just edata */
	ADD	$4095, R2
	LSR	$12, R2, R2
	MOV	R2, 24(RSP)		/* pages */
	MOV	R20, R0			/* the system table */
	BL	efiallocpages(SB)
	ADD	$32, RSP

	MOV	R21, R2			/* R2 = load address */
	MOV	$IMAGEBASE, R3
	MOV	$edata-IMAGEBASE(SB), R4
copy:
	MOVBU	(R2), R5
	MOVBU	R5, (R3)
	ADD	$1, R2
	ADD	$1, R3
	SUB	$1, R4
	CBNZ	R4, copy

	/*
	 * Zero the bss.  The a.out carries no image for it and the copy
	 * above stops at edata, so every uninitialised global would
	 * otherwise hold whatever the firmware left in the pages just
	 * allocated -- and configure() reads one as a pointer and hands
	 * it to memset, which is a data abort on a garbage address
	 * (FAR 0x1200, permission fault third level).  Nothing noticed
	 * while the image ran from a fixed address that happened to be
	 * zeroed RAM.
	 */
	MOV	$IMAGEBASE, R3
	MOV	$edata-IMAGEBASE(SB), R4
	ADD	R3, R4, R3		/* R3 = edata */
	MOV	$IMAGEBASE, R5
	MOV	$end-IMAGEBASE(SB), R6
	ADD	R5, R6, R6		/* R6 = end */
	MOV	$0, R7			/* 7a's ZR is R31, which a store reads as SP */
zero:
	CMP	R6, R3
	BGE	zeroed
	MOVBU	R7, (R3)
	ADD	$1, R3
	B	zero
zeroed:

	/*
	 * The copy was data writes.  Clean each line of the destination
	 * to the point of unification and invalidate the instruction
	 * cache, or the first fetch at IMAGEBASE may be stale.
	 */
	MOV	$IMAGEBASE, R3
	MOV	$edata-IMAGEBASE(SB), R4
	ADD	R3, R4, R6		/* R6 = end of the copy */
clean:
	SYS	R3, $SYSARG5(0,3,7,11,1)	/* DC CVAU, R3 */
	ADD	$64, R3
	CMP	R6, R3
	BLT	clean
	DSB	$11				/* ish */
	SYS	R0, $SYSARG5(0,0,7,5,0)		/* IC IALLU */
	DSB	$11
	ISB	$15

entry:
	/*
	 * R28 is SB, the static base every 7c-compiled reference to a
	 * global goes through, and nothing has set it: the firmware
	 * enters at start(SB) and reloc() copies the image, so there is
	 * no runtime startup to do it the way os/inferno/virtarm64/l.s's
	 * _main does before it calls main().  Without this, efimain's
	 * third instruction is "STR X0, [X28]" for `IH = ih' and takes a
	 * data abort at address 0 -- ESR 0x96000047, FAR 0, translation
	 * fault third level, at efimain+0x8.  This is safe here and not
	 * in reloc(): setSB is a link-time absolute address, and by the
	 * time entry runs the image has been copied to the base it was
	 * linked for.
	 */
	MOV	$setSB(SB), R28

	/*
	 * efimain(ih, st): 7c reads arg0 from R0 and arg1 from 8(FP),
	 * which is 16(RSP) at the call.  Take a little stack of our own
	 * rather than write into the firmware's frame.
	 */
	SUB	$64, RSP
	MOV	R20, 16(RSP)
	MOV	R19, R0
	MOV	$efimain(SB), R6
	BL	(R6)
	/* efimain does not return */
	B	,-4(PC)

/*
 * eficall(proc, ...): call an EFI service.  Everything is read out of
 * the 7c frame before RSP moves, because (FP) is resolved against the
 * entry RSP.
 */
/*
 * The link register and the stacked arguments used to be kept in R10
 * and R11 across the call.  Both are caller-saved in AAPCS64, so the
 * firmware is free to destroy them, and restoring RSP and R30 from
 * them afterwards returns to wherever the firmware happened to leave
 * X10 -- an instruction abort at a page in the firmware's own address
 * range.  Nothing had noticed because no EFI call had ever completed
 * on this port: the loader faulted before its first print.  Keep them
 * on the stack instead, which the firmware must leave alone.
 */
TEXT eficall(SB), 1, $-4
	MOV	R0, R9			/* the service */

	MOV	a9+72(FP), R12
	MOV	a10+80(FP), R13
	MOV	a11+88(FP), R14

	MOV	a1+8(FP), R0
	MOV	a2+16(FP), R1
	MOV	a3+24(FP), R2
	MOV	a4+32(FP), R3
	MOV	a5+40(FP), R4
	MOV	a6+48(FP), R5
	MOV	a7+56(FP), R6
	MOV	a8+64(FP), R7

	SUB	$48, RSP		/* AAPCS64 puts the ninth on and up */
	MOV	R12, 0(RSP)
	MOV	R13, 8(RSP)
	MOV	R14, 16(RSP)
	MOV	R30, 24(RSP)		/* BL below clobbers the link register */
	BL	(R9)

	MOV	24(RSP), R30
	ADD	$48, RSP
	RET	R30

/*
 * rebase(addr): the image is executing where it was linked, so an
 * address needs no adjustment.  Same as x64.s's, which returns its
 * argument unchanged.
 */
TEXT rebase(SB), 1, $-4
	RET	R30

#include "mem.h"

/*
 * Where the loader stages the boot line and the *e820=/*acpi= lines
 * for the kernel to read.  CONFADDR is os/inferno/boot/efi/mem.h's,
 * which is the amd64 kernel's low-memory address and means nothing to
 * an arm64 one; it is here so sub.c links, and it is one of the things
 * the kernel handover below has to settle.
 */
/*
 * confaddr is where sub.c writes the boot line and the parsed
 * plan9.ini -- BOOTLINE and BOOTARGS are defined in terms of it.  On
 * the PC it is CONFADDR, 0x1200, a fixed address in low memory that
 * the amd64 kernel reads by convention.  There is no such convention
 * on AArch64, and 0x1200 is not memory this loader owns: configure()
 * took a data abort writing there, FAR 0x1200, permission fault third
 * level, on the first thing it does.
 *
 * Point it at a page of the loader's own bss instead.  That is enough
 * for the loader to read plan9.ini and load a kernel, which is as far
 * as this port goes; how the kernel is told where the block is belongs
 * with jump() below, which is not written.  See
 * doc/inferno-cloud-plan.ms.
 */
GLOBL	confbuf(SB), $4096
GLOBL	confaddr(SB), $8
DATA	confaddr(SB)/8, $confbuf(SB)

#define	D_SCTLR_EL1	SYSARG5(3,0,1,0,0)

/*
 * jump(pc, args): enter the kernel.
 *
 * The firmware hands off with the MMU and the caches on and its own
 * identity map; os/inferno/virtarm64's l.s runs with the MMU off and
 * builds everything else itself, so clear SCTLR_EL1's M, C and I and
 * branch.  Clearing M does not move the instruction stream because the
 * firmware maps RAM one-to-one, which is what makes this safe to do
 * from code that is itself in RAM.
 *
 * X0 is the kernel's first argument, which its _main stores as
 * dtbptr.  Zero: a UEFI machine describes itself with ACPI, and the
 * RSDP is in the configuration block as *acpi= instead.  A kernel that
 * wants a device tree from this path has nothing to take one from.
 *
 * Not done, and it matters on real hardware rather than under QEMU:
 * the kernel image was written with the D-cache on and is not cleaned
 * to the point of unification before C is cleared, so a machine with
 * real caches may fetch stale lines.  QEMU models no cache, so a
 * clean loop here could not be exercised, and this tree does not ship
 * loops it cannot run -- the same reason os/inferno/raspi3b/l.s gives
 * for leaving its own CLIDR/CCSIDR walk out.
 */
TEXT jump(SB), 1, $-4
	MOV	R0, R9			/* the kernel entry */
	MOV	args+8(FP), R10		/* the configuration block, for x1 */

	MRS	SPR(D_SCTLR_EL1), R1
	MOV	$0x1005, R2		/* M(0) | C(2) | I(12) */
	BIC	R2, R1, R1
	MSR	R1, SPR(D_SCTLR_EL1)
	ISB	$15
	DSB	$15

	MOV	$0, R0			/* x0: no device tree, this is ACPI */
	MOV	R10, R1			/* x1: the configuration block */
	B	(R9)

jumpdead:
	B	jumpdead
