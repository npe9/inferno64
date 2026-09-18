/*
 * Teensy 4.1: an NXP i.MX RT1062, a Cortex-M7 with eight megabytes of
 * serial NOR flash and a megabyte of RAM.  No MMU, so every address here
 * is both physical and virtual.
 *
 * The kernel runs its text out of the flash, where the boot ROM maps it,
 * and keeps everything else in RAM.  The RAM is in two pieces that are
 * not next to each other:
 *
 *	0x20000000	DTCM, out of the 512K of FlexRAM, which
 *			os/inferno/teensy41/archteensy41.c gives over to
 *			data entirely -- this kernel runs no code from
 *			ITCM, so there is no reason to keep any.
 *	0x20200000	OCRAM2, 512K, always there and not configurable.
 *
 * The data segment is linked into OCRAM2 and the DTCM is a second bank.
 */
#define	BI2BY		8
#define	BI2WD		32
#define	BY2WD		4
#define	BY2V		8
#define	BY2PG		4096
#define	WD2PG		(BY2PG/BY2WD)
#define	PGSHIFT		12
#define	ROUND(s, sz)	(((s)+(sz-1))&~(sz-1))
#define	PGROUND(s)	ROUND(s, BY2PG)

#define	MIN(a, b)	((a) < (b)? (a): (b))
#define	MAX(a, b)	((a) > (b)? (a): (b))

/*
 * The console log.  16K is the default in os/inferno/port/portdat.h and
 * is a lot of a part with a couple of hundred kilobytes of SRAM; 2K
 * still holds the last of the boot.
 */
#define	KMESGSIZE	2048
#define	MAXMACH		1
#define	HZ		100
/*
 * 4K, not 16K.  Every process pays this twice over: the boot stack is
 * reserved in bss (os/inferno/armv7m/l.s) and every proc's kernel stack
 * is malloc(KSTACK) from the main pool (os/inferno/port/proc.c), which
 * os/inferno/port/alloc.c's #c/poolhist shows as the largest single
 * caller in the pool floor.  Verified to reach a shell at 4K on
 * mps2-an386 and mps2-an500.
 */
#define	KSTACK		(4*1024)
#define	NPROC		32
#define	CONFNAME	"teensy41"

/*
 * The core clock this kernel sets up in archreset; SysTick counts at it.
 * 600MHz is what the part is rated for and what the Teensy's own
 * software runs it at.
 */
#define	CPUHZ		600000000

/* the boot stack and the Mach, both reserved in os/inferno/armv7m/l.s */
#define	KSTKSIZE	(4*1024)
#define	MACHSIZE	4096

/*
 * The i.MX RT1062 has 160 interrupts, which is how long the vector table
 * has to be.  Table 3-1 of the reference manual numbers them.
 */
#define	NIRQ		160
#define	IRQVECTORS	V64; V64; V16; V16

#define	FLASHBASE	0x60000000
#define	FLASHSIZE	(8*1024*1024)
#define	BOOTHEADERS	0x2000		/* what tools/aout2imxrt puts first */

#define	ITCM		0x00000000
#define	DTCM		0x20000000
#define	FLEXRAMSIZE	(512*1024)
#define	OCRAM		0x20200000
#define	OCRAMSIZE	(512*1024)

#define	KZERO		FLASHBASE
#define	KTZERO		(FLASHBASE+BOOTHEADERS)	/* link address: the vector table */
#define	KDZERO		OCRAM			/* and where the data segment lives */
#define	TOPOFMEM	(OCRAM+OCRAMSIZE)
#define	USTKTOP		TOPOFMEM
#define	MACHADDR	0		/* mach0 is a GLOBL, not a fixed page */

/* the console: LPUART6, which is what pins 0 and 1 are wired to */
#define	UART0		0x40198000
#define	UART0IRQ	(30-16)		/* interrupt 30, LPUART6; NVIC counts from 16 */
#define	UARTBAUD	115200
