/*
 * Raspberry Pi 3 Model B: BCM2837, Cortex-A53, AArch64 EL1, identity
 * mapped (mmu.c).  RAM from 0; the kernel is loaded at 0x80000 by the
 * Pi firmware and by QEMU -M raspi3b alike.  Peripherals are the BCM2835
 * block at 0x3f000000 (bus 0x7e000000) and the BCM2836 per-core block at
 * 0x40000000.
 */
#define	BI2BY		8
#define	BI2WD		64
#define	BY2WD		8
#define	BY2V		8
#define	BY2PG		4096
#define	WD2PG		(BY2PG/BY2WD)
#define	PGSHIFT		12
#define	ROUND(s, sz)	(((s)+((sz)-1))&~((sz)-1))
#define	PGROUND(s)	ROUND(s, BY2PG)

#define	MIN(a, b)	((a) < (b)? (a): (b))
#define	MAX(a, b)	((a) > (b)? (a): (b))

#define	MAXMACH		1
#define	HZ		100
#define	KSTACK		(32*1024)

/* Physical = virtual (identity map) */
#define	PHYSDRAM	((uintptr)0x0)
#define	DRAMSIZE	(256*1024*1024)
#define	KZERO		PHYSDRAM
/*
 * KTZEROraw exists because l.s reads this header and 7a cannot parse a
 * cast; Cpupark below is built from it, and nothing else should be.
 */
#define	KTZEROraw	0x80000
#define	KTZERO		((uintptr)KTZEROraw)

/*
 * Where the JTAG restart trampoline lives: below KTZERO, so an image
 * loaded at KTZERO cannot overwrite the code that is about to jump to
 * it.  The firmware's own stub occupied this region and has no further
 * use for it once the ARM is running.  l.s's jtagstub is copied here
 * at boot; tools/jtag/README has the boot ABI it establishes.
 */
#define	Jtagstub	((uintptr)0x70000)

/*
 * What the trampoline leaves in x0, so the kernel can tell a warm
 * JTAG restart from a cold firmware boot.  Uncast, because l.s reads
 * this header too and 7a cannot parse the cast Jtagstub uses.  The
 * stub itself has to build the value with MOVZ/MOVK rather than name
 * it -- see the note there about literal pools.
 */
#define	Jtagmagic	0x4a544147		/* "JTAG" */

/*
 * The armstub8 spin table: one 64-bit slot per core, at these fixed low
 * addresses, which is where the Pi's firmware stub leaves cores 1-3
 * waiting for an address to branch to.  Core 0's slot (Spintab itself)
 * is never used; core n's is Spintab + 8*n.  It survives the kernel:
 * confinit() starts free memory at the end of the image, well above
 * this, and the only thing this kernel puts below KTZERO is the JTAG
 * trampoline at 0x70000.
 *
 * Cpupark is where a secondary goes to rest: the kernel's own entry
 * point, whose first four instructions send any core but core 0 into the
 * park loop.  Cpuparkwait is where it then sits, seven instructions in.
 * Both have to be constants rather than symbols, because a core parked
 * by one build keeps executing at that address when the next build is
 * loaded over it, so neither may move between builds.  l.s has the
 * argument in full; smpbcm.c checks at boot that the linker agrees
 * about Cpuparkwait and releases nothing if it does not.
 */
#define	Spintab		0xd8
#define	Cpupark		KTZEROraw
#define	Cpuparkwait	(KTZEROraw+0x1c)

#define	UART0		((uintptr)0x3f201000)	/* PL011 */
#define	AUX0		((uintptr)0x3f215000)	/* BCM2835 AUX: mini UART (UART1) */
#define	PM0		((uintptr)0x3f100000)	/* BCM2835 power manager / watchdog */

#define	BCMPERIPH	((uintptr)0x3f000000)
#define	IRQBASE		(BCMPERIPH + 0x00b200)	/* BCM2835 ARM IRQ controller */
#define	MBOX0		(BCMPERIPH + 0x00b880)	/* BCM2835 VideoCore mailbox 0 */
#define	GPIO0		(BCMPERIPH + 0x200000)	/* BCM2835 GPIO */
#define	SDHOST		(BCMPERIPH + 0x202000)	/* BCM2835 SDHOST (native SD) */
#define	EMMC		(BCMPERIPH + 0x300000)	/* Arasan SDHCI: the card, on the board */
#define	SDHCI		EMMC			/* the same block, as sdhcibcm.c names it */
#define	PMBASE		(BCMPERIPH + 0x100000)	/* BCM2835 power management + watchdog */
#define	RNG0		(BCMPERIPH + 0x104000)	/* BCM2835 hardware RNG */
#define	I2C0		(BCMPERIPH + 0x205000)	/* BCM2835 BSC0 (i2c-bus.0) */
#define	SPI0		(BCMPERIPH + 0x204000)	/* BCM2835 SPI0 */
#define	CPRMAN		(BCMPERIPH + 0x101000)	/* BCM2835 clock manager */
#define	PWM0		(BCMPERIPH + 0x20c000)	/* BCM2835 PWM */
#define	SYSTMR		(BCMPERIPH + 0x003000)	/* BCM2835 system timer, 1MHz */
#define	THERMAL		(BCMPERIPH + 0x212000)	/* BCM2835 temperature sensor */
#define	DMA0		(BCMPERIPH + 0x007000)	/* BCM2835 DMA, channels 0-14 */
#define	ARMTIMER	(BCMPERIPH + 0x00b400)	/* BCM2835 ARM timer (SP804-like) */
#define	I2S0		(BCMPERIPH + 0x203000)	/* BCM2835 I2S/PCM serialiser */
#define	SMI0		(BCMPERIPH + 0x600000)	/* BCM2835 secondary memory iface */
#define	BSCSL		(BCMPERIPH + 0x214000)	/* BCM2835 SPI/BSC slave */


/* Mach struct above typical kernel image */
#define	MACHADDR	((uintptr)(DRAMSIZE-0x10000))
#define	USTKTOP		(PHYSDRAM+DRAMSIZE)

