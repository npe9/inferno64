#ifndef _INFERNO_THUMB_U_H_
#define _INFERNO_THUMB_U_H_

#define nil		((void*)0)
#ifndef NULL
#define NULL	nil
#endif
#ifndef SEEK_SET
#define SEEK_SET	0
#define SEEK_CUR	1
#define SEEK_END	2
#endif

/*
 * ILP32: an ARMv7-M core is 32 bit and tc is a 32 bit compiler, so long,
 * int and a pointer are all four bytes and uintptr is an unsigned long.
 */
typedef	unsigned short	ushort;
typedef	unsigned char	uchar;
typedef	unsigned long	ulong;
typedef	unsigned int	uint;
typedef	signed char	schar;
typedef	long long	vlong;
typedef	unsigned long long uvlong;
typedef	long		intptr;
typedef	unsigned long	uintptr;
typedef	unsigned long	usize;
typedef	uint		Rune;
typedef union FPdbleword FPdbleword;

typedef	uintptr	jmp_buf[2];
#define	JMPBUFSP	0
#define	JMPBUFPC	1
#define	JMPBUFDPC	0

typedef unsigned int	mpdigit;	/* for /sys/include/mp.h */

typedef unsigned char	u8int;
typedef unsigned short	u16int;
typedef unsigned int	u32int;
typedef unsigned long long u64int;
typedef signed char	s8int;
typedef signed short	s16int;
typedef signed int	s32int;
typedef signed long long s64int;
typedef unsigned char	u8;
typedef unsigned short	u16;
typedef unsigned int	u32;
typedef unsigned long long u64;
typedef signed char	s8;
typedef signed short	s16;
typedef signed int	s32;
typedef signed long long s64;

/*
 * FPSCR of the ARMv7-M floating point extension (FPv5).  The exception
 * enable bits are in the top half and the cumulative exception bits in
 * the bottom, which is the same shape the ARM port uses; the rounding
 * mode is bits 23:22 rather than the FPA's bits 1:0.
 */
/* FCR */
#define	FPINEX	(1<<12)
#define	FPUNFL	(1<<11)
#define	FPOVFL	(1<<10)
#define	FPZDIV	(1<<9)
#define	FPINVAL	(1<<8)
#define	FPRNR	(0<<22)
#define	FPRZ	(3<<22)
#define	FPRPINF	(1<<22)
#define	FPRNINF	(2<<22)
#define	FPRMASK	(3<<22)
#define	FPPEXT	0
#define	FPPSGL	0
#define	FPPDBL	0
#define	FPPMASK	0
/* FSR */
#define	FPAINEX	(1<<4)
#define	FPAUNFL	(1<<3)
#define	FPAOVFL	(1<<2)
#define	FPAZDIV	(1<<1)
#define	FPAINVAL	(1<<0)

union FPdbleword
{
	double	x;
	struct {	/* little endian: VFP, unlike the FPA, stores the low word first */
		ulong lo;
		ulong hi;
	};
};

typedef	char*	va_list;
#define va_start(list, start) list =\
	(sizeof(start) < 4?\
		(char*)((int*)&(start)+1):\
		(char*)(&(start)+1))
#define va_end(list)\
	USED(list)
#define va_arg(list, mode)\
	((sizeof(mode) == 1)?\
		((mode*)(list += 4))[-4]:\
	(sizeof(mode) == 2)?\
		((mode*)(list += 4))[-2]:\
		((mode*)(list += sizeof(mode)))[-1])

typedef intptr WORD;
typedef uintptr UWORD;

#endif
