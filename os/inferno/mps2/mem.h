/*
 * ARM MPS2 with the AN500 FPGA image: a Cortex-M7 as QEMU models it.
 *
 * One image serves more than that one.  QEMU's AN385 (Cortex-M3), AN386
 * (Cortex-M4) and AN500 (Cortex-M7) models have the same memory map --
 * mps.ssram1 at 0, mps.ssram23 at 0x20000000, four megabytes each,
 * verified with "info mtree" on this host -- and the same CMSDK UART at
 * the bases below.  So the same imps2 binary boots on AN386 as on
 * AN500, and the only difference the kernel can see is the floating
 * point unit: the M7 has double precision and the M4 has FPv4-SP and
 * none.  qemu.sh runs the M7, qemu-m4.sh the M4; see
 * doc/armv7m-ports.ms for what the difference costs.
 *
 * There is no MMU, so every address here is both physical and virtual.
 * Two blocks of static RAM are wired up, four megabytes each, and the
 * kernel lives at the bottom of the first one because that is where the
 * core reads its vector table from after reset.
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
/*
 * 4K, not 16K.  Every process pays this twice over: the boot stack is
 * reserved in bss (os/inferno/armv7m/l.s) and every proc's kernel stack
 * is malloc(KSTACK) from the main pool (os/inferno/port/proc.c), which
 * os/inferno/port/alloc.c's #c/poolhist shows as the largest single
 * caller in the pool floor.  Verified to reach a shell at 4K on
 * mps2-an386 and mps2-an500.
 */
#define	KSTACK		(4*1024)
/*
 * Kernel processes.  Measured on mps2 with a shell, background jobs,
 * fptest and cvtchk, five were ever allocated; the array is
 * conf.nproc*sizeof(Proc) out of xalloc (os/inferno/port/proc.c:
 * /^procinit), which is 2740 bytes apiece and does not appear in
 * #c/memory because it is not pool memory.  16 is three times what was
 * measured.  See doc/xip.ms.
 */
#define	CONFNAME	"mps2"

#define	CPUHZ		25000000	/* QEMU's SYSCLK for this board */

/* the boot stack and the Mach, both reserved in os/inferno/armv7m/l.s */
#define	KSTKSIZE	(4*1024)
#define	MACHSIZE	4096

/* how many NVIC interrupts, and so how long the vector table is */
#define	NIRQ		64
#define	IRQVECTORS	V64

#define	SSRAM1		0x00000000
#define	SSRAM1SIZE	(4*1024*1024)
#define	SSRAM23		0x20000000
#define	SSRAM23SIZE	(4*1024*1024)

#define	KZERO		SSRAM1
#define	KTZERO		SSRAM1		/* link address: the vector table */
#define	KDZERO		SSRAM23		/* and where the data segment lives */
#define	TOPOFMEM	(SSRAM23+SSRAM23SIZE)
#define	USTKTOP		TOPOFMEM
#define	MACHADDR	0		/* mach0 is a GLOBL, not a fixed page */

/* CMSDK APB peripherals */
#define	UART0		0x40004000
#define	UART1		0x40005000
#define	UART0IRQ	0		/* receive; transmit is the next one */

/*
 * The Arduino-style expansion headers and the GPIO block beside them.
 * Shield0's PL022 is where os/inferno/mps2/spipl022.c looks for a radio
 * shield; GPIO0's combined interrupt is 6, which is the number the MPS2
 * application notes give.
 */
#define	SPISHIELD0	0x40026000
#define	SPISHIELD1	0x40027000
#define	GPIO0		0x40010000
#define	GPIO0IRQ	6
