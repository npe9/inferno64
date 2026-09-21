/*
 * ST NUCLEO-F303RE: an STM32F303RE, which is a Cortex-M4 with the
 * single precision floating point extension.  512K of flash and 80K of
 * RAM in two pieces.
 *
 * No MMU, so every address here is both physical and virtual.
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

/*
 * waserror() nesting depth, and so the size of Proc.errlab at 8 bytes
 * an entry, times NPROC.  64 is the portable default (os/inferno/port/
 * portdat.h); measured on mps2 over a shell, failing opens, background
 * jobs, fptest and cvtchk, the deepest nesting reached was 8.  24 is
 * three times that, and saves 320 bytes in every Proc.
 */
#define	NERR		24
#define	MAXMACH		1
#define	HZ		100
#define	KSTACK		(4*1024)
#define	NPROC		8
#define	CONFNAME	"nucleof303"

#define	CPUHZ		64000000	/* HSI/2 * 16 */

#define	KSTKSIZE	(4*1024)
#define	MACHSIZE	1024

#define	NIRQ		96
#define	IRQVECTORS	V64; V16; V16

#define	FLASHBASE	0x08000000
#define	FLASHSIZE	(512*1024)
#define	SRAM		0x20000000
#define	SRAMSIZE	(64*1024)
#define	CCMRAM		0x10000000
#define	CCMRAMSIZE	(16*1024)

#define	KZERO		FLASHBASE
#define	KTZERO		FLASHBASE	/* link address: the vector table */
#define	KDZERO		SRAM
#define	TOPOFMEM	(SRAM+SRAMSIZE)
#define	USTKTOP		TOPOFMEM
#define	MACHADDR	0

#define	UART0		0x40004400	/* USART2, the ST-LINK virtual port */
#define	UART0IRQ	38		/* USART2's NVIC interrupt number */
#define	UARTBAUD	115200
