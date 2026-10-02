/*
 * AArch64 definition, so libmach can read an arm64 executable at all.
 *
 * WITHOUT THIS NOTHING CAN NAME AN ARM64 ADDRESS.  libmach had 7obj.c, the
 * object-file reader, and no machine description and no entry in
 * executable.c's table -- so R_MAGIC was an unknown header and inm, acid
 * and idb all refused every aarch64 binary with "Can't read header".
 * That is why a kernel PC on the Pi 3B could not be turned into a
 * function name: doc/parallel-allocator-survey.ms records the longest
 * ilock hold at 0x1af054 and no way to find out what it is.
 *
 * Modelled on j.c, which is the most recent 64-bit machine added here.
 */
#include <lib9.h>
#include <bio.h>
#include "ureg7.h"
#include <mach.h>

#define	REGOFF(x)	(u64int)(&((struct Ureg *) 0)->x)
#define	REGSIZE		sizeof(struct Ureg)

/*
 * The FP registers are NOT in Ureg.
 *
 * AArch64's v0..v31 are 128 bits each and this kernel does not save them
 * on a trap -- os/inferno/aarch64 has no FP save area in Ureg at all, and
 * a register list that claimed otherwise would have a debugger reading
 * whatever follows the struct.  So the list is the integer state, which
 * is what the kernel actually has, and FPREGSIZE is 0.
 */
#define	FPREGSIZE	0

Reglist arm64reglist[] = {
	{"PC",		REGOFF(pc),	RINT, 'Y'},
	{"SP",		REGOFF(sp),	RINT, 'Y'},
	{"STATUS",	REGOFF(status),	RINT|RRDONLY, 'Y'},
	{"TYPE",	REGOFF(type),	RINT|RRDONLY, 'Y'},
	{"CAUSE",	REGOFF(cause),	RINT|RRDONLY, 'Y'},
	{"TVAL",	REGOFF(tval),	RINT|RRDONLY, 'Y'},
	{"R0",		REGOFF(r0),	RINT, 'Y'},
	{"R1",		REGOFF(r1),	RINT, 'Y'},
	{"R2",		REGOFF(r2),	RINT, 'Y'},
	{"R3",		REGOFF(r3),	RINT, 'Y'},
	{"R4",		REGOFF(r4),	RINT, 'Y'},
	{"R5",		REGOFF(r5),	RINT, 'Y'},
	{"R6",		REGOFF(r6),	RINT, 'Y'},
	{"R7",		REGOFF(r7),	RINT, 'Y'},
	{"R8",		REGOFF(r8),	RINT, 'Y'},
	{"R9",		REGOFF(r9),	RINT, 'Y'},
	{"R10",		REGOFF(r10),	RINT, 'Y'},
	{"R11",		REGOFF(r11),	RINT, 'Y'},
	{"R12",		REGOFF(r12),	RINT, 'Y'},
	{"R13",		REGOFF(r13),	RINT, 'Y'},
	{"R14",		REGOFF(r14),	RINT, 'Y'},
	{"R15",		REGOFF(r15),	RINT, 'Y'},
	{"R16",		REGOFF(r16),	RINT, 'Y'},
	{"R17",		REGOFF(r17),	RINT, 'Y'},
	{"R18",		REGOFF(r18),	RINT, 'Y'},
	{"R19",		REGOFF(r19),	RINT, 'Y'},
	{"R20",		REGOFF(r20),	RINT, 'Y'},
	{"R21",		REGOFF(r21),	RINT, 'Y'},
	{"R22",		REGOFF(r22),	RINT, 'Y'},
	{"R23",		REGOFF(r23),	RINT, 'Y'},
	{"R24",		REGOFF(r24),	RINT, 'Y'},
	{"R25",		REGOFF(r25),	RINT, 'Y'},
	{"R26",		REGOFF(r26),	RINT, 'Y'},
	{"R27",		REGOFF(r27),	RINT, 'Y'},
	{"R28",		REGOFF(r28),	RINT, 'Y'},
	{"R29",		REGOFF(r29),	RINT, 'Y'},
	{"R30",		REGOFF(r30),	RINT, 'Y'},
	{  0 }
};

	/* the machine description */
Mach marm64 =
{
	"arm64",
	MARM64,		/* machine type */
	arm64reglist,	/* register set */
	REGSIZE,	/* register set size */
	FPREGSIZE,	/* FP register set size */
	"PC",		/* name of PC */
	"SP",		/* name of SP */
	"R30",		/* name of link register */
	"setSB",	/* static base register name */
	0,		/* static base register value */
	0x1000,		/* page size */
	/*
	 * The kernel is linked at 0x80000 on this board (raspi3b's mkfile
	 * passes -T0x80000) and runs on the identity map, so there is no
	 * high kernel window to mask off the way Sv39 riscv has.  A kernel
	 * base of 0 and a mask of ~0 mean "believe the address", which is
	 * the truth here and is what lets a PC from /dev/ilock be looked up.
	 */
	0,		/* kernel base */
	~(uvlong)0,	/* kernel text mask */
	0x0000ffffffffffffULL,	/* user stack top */
	4,		/* quantization of pc: every instruction is 4 bytes */
	8,		/* szaddr */
	8,		/* szreg */
	4,		/* szfloat */
	8,		/* szdouble */
};
