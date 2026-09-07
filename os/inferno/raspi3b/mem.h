/*
 * QEMU -M virt, AArch64 (cortex-a72) -- EL1 only, MMU off, identity/
 * physical addressing throughout, the same "bare and unmapped" model
 * os/inferno/armv7 uses for 32-bit ARM.  Addresses verified against
 * this host's own QEMU (10.1.3) via
 * qemu-system-aarch64 -M virt -machine dumpdtb=... ; dtc -I dtb -O dts,
 * not assumed from armv7's board even though the QEMU "virt" machine
 * model turned out to be address-for-address identical regardless of
 * -cpu (cortex-a15 vs cortex-a72): same PHYSDRAM, same pl011, same
 * GICv2 (armv7's "arm,cortex-a15-gic" compatible string, unchanged),
 * same virtio-mmio layout.  See doc/inferno-ports.ms.
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
#define	DRAMSIZE	(256*1024*1024)
#define	KZERO		PHYSDRAM
#define	KTZERO		((uintptr)0x80000)

/* pl011@9000000, same as armv7's own board (same QEMU virt machine) */
#define	UART0		((uintptr)0x3f201000)	/* PL011 */
#define	RTC0		((uintptr)0x09010000)	/* arm,pl031 */

#define	BCMPERIPH	((uintptr)0x3f000000)
#define	IRQBASE		(BCMPERIPH + 0x00b200)	/* BCM2835 ARM IRQ controller */
#define	MBOX0		(BCMPERIPH + 0x00b880)	/* BCM2835 VideoCore mailbox 0 */
#define	GPIO0		(BCMPERIPH + 0x200000)	/* BCM2835 GPIO */
#define	SDHOST		(BCMPERIPH + 0x202000)	/* BCM2835 SDHOST (native SD) */
#define	SDHCI		(BCMPERIPH + 0x300000)	/* Arasan SDHCI ("EMMC"), SDIO for wifi */
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


/* Mach struct above typical kernel image */
#define	MACHADDR	((uintptr)(DRAMSIZE-0x10000))
#define	USTKTOP		(PHYSDRAM+DRAMSIZE)

