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
#define	KTZERO		((uintptr)0x80000)

#define	UART0		((uintptr)0x3f201000)	/* PL011 */
#define	AUX0		((uintptr)0x3f215000)	/* BCM2835 AUX: mini UART (UART1) */
#define	PM0		((uintptr)0x3f100000)	/* BCM2835 power manager / watchdog */

#define	BCMPERIPH	((uintptr)0x3f000000)
#define	IRQBASE		(BCMPERIPH + 0x00b200)	/* BCM2835 ARM IRQ controller */
#define	MBOX0		(BCMPERIPH + 0x00b880)	/* BCM2835 VideoCore mailbox 0 */
#define	GPIO0		(BCMPERIPH + 0x200000)	/* BCM2835 GPIO */
#define	SDHOST		(BCMPERIPH + 0x202000)	/* BCM2835 SDHOST (native SD) */
#define	EMMC		(BCMPERIPH + 0x300000)	/* Arasan SDHCI (the other SD path) */
#define	I2C0		(BCMPERIPH + 0x205000)	/* BCM2835 BSC0 (i2c-bus.0) */
#define	SPI0		(BCMPERIPH + 0x204000)	/* BCM2835 SPI0 */


/* Mach struct above typical kernel image */
#define	MACHADDR	((uintptr)(DRAMSIZE-0x10000))
#define	USTKTOP		(PHYSDRAM+DRAMSIZE)

