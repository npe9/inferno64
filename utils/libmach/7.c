/*
 * AArch64 (arm64) definition
 *
 * libmach knew arm64 object files (7obj.c) but not arm64 executables:
 * R_MAGIC had no exectab entry and there was no Mach, so crackhdr()
 * answered "Can't read header" for every 7l output and inm, acid and
 * srclist could say nothing about them.  This is the missing half.
 *
 * There is no arm64 disassembler here, so this file is deliberately
 * not wired into setmach.c's machines[] table: a Mach is enough for
 * crackhdr() and syminit(), which is what symbol lookup needs, and
 * claiming a Machdata would claim a disassembler that does not exist.
 */
#include <lib9.h>
#include <bio.h>
#include "ureg7.h"
#include <mach.h>

#define	REGOFF(x)	(u64int)(&((struct Ureg *) 0)->x)
#define	REGSIZE		sizeof(struct Ureg)
#define	FPREGSIZE	(8*32 + 8)	/* v0-v31 as doubles, plus FPSR */

Reglist arm64reglist[] = {
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
	{"SP",		REGOFF(sp),	RINT, 'Y'},
	{"PC",		REGOFF(pc),	RINT, 'Y'},
	{"LR",		REGOFF(r30),	RINT, 'Y'},	/* alias for acid */
	{"STATUS",	REGOFF(status),	RINT|RRDONLY, 'Y'},
	{"TYPE",	REGOFF(type),	RINT|RRDONLY, 'Y'},
	{"CAUSE",	REGOFF(cause),	RINT|RRDONLY, 'Y'},
	{"TVAL",	REGOFF(tval),	RINT|RRDONLY, 'Y'},
	{  0 }
};

	/* the machine description */
Mach marm64 =
{
	"arm64",
	MARM64,			/* machine type */
	arm64reglist,		/* register set */
	REGSIZE,		/* size of registers in bytes */
	FPREGSIZE,		/* size of fp registers in bytes */
	"PC",			/* name of PC */
	"SP",			/* name of SP */
	"R30",			/* name of link register */
	"setSB",		/* static base register name */
	0,			/* static base register value */
	0x1000,			/* page size */
	/*
	 * The TTBR1 half.  No board in this tree maps its kernel high --
	 * they all run at their physical address with the MMU off -- so
	 * commonboot()'s "entry & ktmask" test is false for every one of
	 * them and the a.out header is read intact, which is right.
	 */
	0xFFFF000000000000ULL,	/* kernel base */
	0xFFFF000000000000ULL,	/* kernel text mask */
	0x0000FFFFFFFFF000ULL,	/* user stack top */
	4,			/* quantization of pc */
	8,			/* szaddr */
	8,			/* szreg */
	4,			/* szfloat */
	8,			/* szdouble */
};
