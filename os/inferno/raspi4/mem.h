/*
 * BCM2711, the Raspberry Pi 4 -- QEMU -M raspi4b.  EL1 only, MMU off,
 * identity addressing, the same bare model os/inferno/raspi3b uses.
 *
 * Two things move from the Pi 3B and everything else follows from
 * them.  The peripheral block is at 0xfe000000 rather than 0x3f000000
 * (hw/arm/bcm2838.c: bc_base->peri_base), so every offset below is the
 * same offset from a different base -- which is why raspi3b already
 * derived them all from BCMPERIPH, and why UART0, the one address that
 * was written out in full, is derived here too.
 *
 * And interrupts are a GIC-400, a GICv2, at ctrl_base 0xff800000 plus
 * BCM2838_GIC_BASE 0x40000.  This is the real difference: on the Pi 3B
 * the peripherals feed the legacy BCM controller's three pending
 * registers, and on the Pi 4 they are wired straight to the GIC as
 * SPIs (hw/arm/bcm2838.c connects uart0 to GIC_SPI_INTERRUPT_UART0
 * directly).  So trap.c's three-bank walk does not apply here and the
 * SPI numbers are their own map; see io.h.
 *
 * Addresses are taken from QEMU's own headers rather than guessed,
 * and are noted with the file they came from so they can be rechecked.
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

/* Physical / virtual (identity, MMU off) */
#define	PHYSDRAM	((uintptr)0x0)
#define	DRAMSIZE	(256*1024*1024)	/* raspi4b has 2G; this is what is used */
#define	KZERO		PHYSDRAM
#define	KTZERO		((uintptr)0x80000)

#define	BCMPERIPH	((uintptr)0xfe000000)	/* bcm2838.c: peri_base */
#define	UART0		(BCMPERIPH + 0x201000)	/* PL011 */
#define	RTC0		((uintptr)0x09010000)	/* arm,pl031; not on this board */

/*
 * GIC-400.  bcm2838.c puts ctrl_base at 0xff800000 and the GIC at
 * +0x40000 within it, with the distributor at +0x1000 and the CPU
 * interface at +0x2000 of that.  The legacy BCM controller still
 * exists at the offset below but nothing is wired to it here.
 */
#define	ARMCTRL		((uintptr)0xff800000)	/* bcm2838.c: ctrl_base */
#define	GICBASE		(ARMCTRL + 0x40000)	/* bcm2838.h: BCM2838_GIC_BASE */
#define	GICD		(GICBASE + 0x1000)	/* distributor */
#define	GICC		(GICBASE + 0x2000)	/* cpu interface */

#define	IRQBASE		(BCMPERIPH + 0x00b200)	/* legacy controller, unused here */
#define	MBOX0		(BCMPERIPH + 0x00b880)	/* BCM2835 VideoCore mailbox 0 */
#define	GPIO0		(BCMPERIPH + 0x200000)	/* BCM2835 GPIO */
#define	SDHOST		(BCMPERIPH + 0x202000)	/* BCM2835 SDHOST (native SD) */
#define	SDHCI		(BCMPERIPH + 0x300000)	/* Arasan ("EMMC1"), SDIO for wifi */
#define	EMMC2		(BCMPERIPH + 0x340000)	/* EMMC2: the microSD slot */
#define	PMBASE		(BCMPERIPH + 0x100000)	/* BCM2835 power management + watchdog */
#define	RNG0		(BCMPERIPH + 0x104000)	/* BCM2835 hardware RNG */
#define	I2C0		(BCMPERIPH + 0x205000)	/* BCM2835 BSC0 (i2c-bus.0) */
#define	SPI0		(BCMPERIPH + 0x204000)	/* BCM2835 SPI0 */
#define	CPRMAN		(BCMPERIPH + 0x101000)	/* BCM2835 clock manager */
#define	PWM0		(BCMPERIPH + 0x20c000)	/* BCM2835 PWM */
#define	SYSTMR		(BCMPERIPH + 0x003000)	/* BCM2835 system timer, 1MHz */
#define	THERMAL		(BCMPERIPH + 0x212000)	/* BCM2835 temperature sensor */
#define	DMA0		(BCMPERIPH + 0x007000)	/* BCM2835 DMA, channels 0-14 */
#define	AUX0		(BCMPERIPH + 0x215000)	/* BCM2835 AUX: mini UART, SPI1/2 */
#define	ARMTIMER	(BCMPERIPH + 0x00b400)	/* BCM2835 ARM timer (SP804-like) */
#define	I2S0		(BCMPERIPH + 0x203000)	/* BCM2835 I2S/PCM serialiser */
#define	SMI0		(BCMPERIPH + 0x600000)	/* BCM2835 secondary memory iface */
#define	BSCSL		(BCMPERIPH + 0x214000)	/* BCM2835 SPI/BSC slave */


/* Mach struct above typical kernel image */
#define	MACHADDR	((uintptr)(DRAMSIZE-0x10000))
#define	USTKTOP		(PHYSDRAM+DRAMSIZE)

