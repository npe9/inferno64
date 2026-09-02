#ifndef _INFERNO_AARCH64_U_H_
#define _INFERNO_AARCH64_U_H_

#define nil		((void*)0)
#ifndef NULL
#define NULL	nil
#endif
#ifndef SEEK_SET
#define SEEK_SET	0
#define SEEK_CUR	1
#define SEEK_END	2
#endif
typedef	unsigned short	ushort;
typedef	unsigned char	uchar;
/*
 * LP64, like jc's own riscv64 u.h calls "LLP64" -- ulong/usize are
 * 32-bit tree-wide (see memory: plan9-long-is-32-bits), pointers use
 * uintptr.  7c/7.out.h: SZ_IND is 8 (real AArch64 64-bit pointers).
 */
typedef	unsigned long	ulong;
typedef	unsigned int	uint;
typedef	signed char	schar;
typedef	long long	vlong;
typedef	unsigned long long uvlong;
typedef long long	intptr;
typedef unsigned long long uintptr;
typedef unsigned long	usize;
typedef	uint		Rune;
typedef union FPdbleword FPdbleword;

typedef uintptr	jmp_buf[2];
#define	JMPBUFSP	0
#define	JMPBUFPC	1
#define	JMPBUFDPC	0
typedef unsigned int	mpdigit;	/* for /sys/include/mp.h */

typedef unsigned char u8int;
typedef unsigned short u16int;
typedef unsigned int	u32int;
typedef unsigned long long u64int;
typedef signed char s8int;
typedef signed short s16int;
typedef signed int s32int;
typedef signed long long s64int;
typedef unsigned char	u8;
typedef unsigned short	u16;
typedef unsigned int	u32;
typedef unsigned long long u64;
typedef signed char s8;
typedef signed short s16;
typedef signed int s32;
typedef signed long long s64;

/*
 * FCR/FSR -- real AArch64 FPCR/FPSR bit positions (ARM Architecture
 * Reference Manual), unlike riscv64/virt's own u.h which zeroes these
 * since jc's target had no working float support to speak of at the
 * time.  7c has a real F/D register file; these matter once
 * FPcontrol/FPstatus (libmath/FPcontrol-Inferno.c) actually gets
 * exercised.  Not yet verified against a live fault -- no board boots
 * far enough yet to raise one -- so treat as "encoded correctly from
 * the architecture manual," not "confirmed against real hardware
 * behavior" the way this tree verifies most things.
 */
#define	FPINEX	0
#define	FPUNFL	0
#define	FPOVFL	0
#define	FPZDIV	0
#define	FPINVAL	0
#define	FPRNR	(0<<22)		/* FPCR.RMode: round to nearest */
#define	FPRPINF	(1<<22)		/* round toward +inf */
#define	FPRNINF	(2<<22)		/* round toward -inf */
#define	FPRZ	(3<<22)		/* round toward zero */
#define	FPRMASK	(3<<22)
#define	FPPEXT	0
#define	FPPSGL	0
#define	FPPDBL	0
#define	FPPMASK	0
#define	FPAINEX		(1<<4)	/* FPSR.IXC */
#define	FPAUNFL		(1<<3)	/* FPSR.UFC */
#define	FPAOVFL		(1<<2)	/* FPSR.OFC */
#define	FPAZDIV		(1<<1)	/* FPSR.DZC */
#define	FPAINVAL	(1<<0)	/* FPSR.IOC */

union FPdbleword
{
	double	x;
	struct {	/* little endian */
		uint	lo;
		uint	hi;
	};
};

/* stdarg - little-endian, 8-byte slots (real AArch64 AAPCS64 stack layout) */
typedef	char*	va_list;
#define va_start(list, start) list =\
	(sizeof(start) < 8?\
		(char*)((vlong*)&(start)+1):\
		(char*)(&(start)+1))
#define va_end(list)\
	USED(list)
#define va_arg(list, mode)\
	((sizeof(mode) == 1)?\
		((list += 8), (mode*)list)[-8]:\
	(sizeof(mode) == 2)?\
		((list += 8), (mode*)list)[-4]:\
	(sizeof(mode) == 4)?\
		((list += 8), (mode*)list)[-2]:\
		((list += sizeof(mode)), (mode*)list)[-1])

typedef intptr WORD;
typedef uintptr UWORD;

#endif
