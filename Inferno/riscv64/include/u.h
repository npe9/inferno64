#ifndef _INFERNO_RISCV64_U_H_
#define _INFERNO_RISCV64_U_H_

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
 * LLP64 like Inferno/amd64 and KenC jc (SZ_LONG=4, SZ_IND=8):
 * ulong/usize are 32-bit; pointers use uintptr.
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

/* FCR / FSR (RISC-V fcsr) */
#define	FPINEX	0
#define	FPUNFL	0
#define	FPOVFL	0
#define	FPZDIV	0
#define	FPINVAL	0
#define	FPRNR	(0<<5)
#define	FPRZ	(1<<5)
#define	FPRPINF	(3<<5)
#define	FPRNINF	(2<<5)
#define	FPRMASK	(15<<5)
#define	FPPEXT	0
#define	FPPSGL	0
#define	FPPDBL	0
#define	FPPMASK	0
#define	FPAINEX	(1<<0)
#define	FPAOVFL	(1<<2)
#define	FPAUNFL	(1<<1)
#define	FPAZDIV	(1<<3)
#define	FPAINVAL (1<<4)

union FPdbleword
{
	double	x;
	struct {	/* little endian */
		uint	lo;
		uint	hi;
	};
};

/* stdarg - little-endian, 8-byte slots (matches jc Aarg2 / amd64) */
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
