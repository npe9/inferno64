/*
 * QEMU -M sifive_u (FU540 / HiFive Unleashed) — identity mapped, M-mode.
 *
 * Boot on hart 1 (U54 + FPU).  Hart 0 is E51 (no F/D); parked in l.s.
 * KenC: build high addresses with shifts (not 0x80000000ULL).
 */
#define	BI2BY		8
#define	BI2WD		64
#define	BY2WD		8
#define	BY2V		8
#define	BY2PG		4096
#define	WD2PG		(BY2PG/BY2WD)
#define	PGSHIFT		12
#define	ROUND(s, sz)	(((s)+(sz-1))&~(sz-1))
#define	PGROUND(s)	ROUND(s, BY2PG)

#define	MIN(a, b)	((a) < (b)? (a): (b))
#define	MAX(a, b)	((a) > (b)? (a): (b))

#define	MAXMACH		1
#define	HZ		100
#define	KSTACK		(32*1024)

#define	BOOT_HART	1		/* first U54 */

#define	PHYSDRAM	((uintptr)8 << 28)	/* 0x80000000 */
#define	DRAMSIZE	(128*1024*1024)		/* QEMU default; -m ok */
#define	KZERO		PHYSDRAM
#define	KTZERO		PHYSDRAM

#define	CLINT		((uintptr)0x02000000)
#define	PLIC		((uintptr)0xc << 24)	/* 0x0c000000 */

#define	UART0		((uintptr)0x10010000)	/* serial@10010000 */
#define	UART1		((uintptr)0x10011000)
#define	PWM0		((uintptr)0x10020000)
#define	PWM1		((uintptr)0x10021000)
#define	SPI0		((uintptr)0x10040000)	/* NOR */
#define	SPI1		((uintptr)0x10050000)	/* MMC-SPI */
#define	GPIO0		((uintptr)0x10060000)
#define	OTP0		((uintptr)0x10070000)
#define	GEM0		((uintptr)0x10090000)
#define	PRCI		((uintptr)0x10000000)

#define	MACHADDR	(PHYSDRAM+0x100000)
#define	USTKTOP		(PHYSDRAM+DRAMSIZE)
