/*
 * MangoPi MQ-Pro: an Allwinner D1, which is a T-Head C906 -- RV64GC with
 * the vendor extensions this kernel does not use.  Identity mapped,
 * M-mode, one hart.
 *
 * KenC: build high addresses with shifts rather than 0x40000000ULL,
 * which it sign-extends from 32 bits.
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

#define	BOOT_HART	0		/* the D1 has one C906 */

/*
 * The MQ-Pro has either 512M or 1G of DDR3 depending on which one it is.
 * 512M is what every one of them has, so that is what this claims;
 * archmangopi.c is where a board with more would say so.
 */
#define	PHYSDRAM	((uintptr)4 << 28)	/* 0x40000000 */
#define	DRAMSIZE	(512*1024*1024)
#define	KZERO		PHYSDRAM
#define	KTZERO		PHYSDRAM

#define	CLINT		((uintptr)0x14000000)
#define	PLIC		((uintptr)0x10000000)

/*
 * The UARTs are DesignWare parts: the 16550 register set with the
 * registers four bytes apart and read a word at a time.  UART0 is the
 * one on the debug header.
 */
#define	UART0		((uintptr)0x02500000)
#define	UART1		((uintptr)0x02500400)
#define	UART2		((uintptr)0x02500800)
#define	UART3		((uintptr)0x02500c00)
#define	CCU		((uintptr)0x02001000)	/* clock control unit */
#define	GPIO		((uintptr)0x02000000)	/* pin controller */

#define	MACHADDR	(PHYSDRAM+0x100000)
#define	USTKTOP		(PHYSDRAM+DRAMSIZE)
