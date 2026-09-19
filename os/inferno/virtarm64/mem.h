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

/*
 * MAXMACH is how many Mach structures may exist, not how many
 * processors schedule: conf.nmach is still 1 and only machno 0 runs
 * anything.  It bounds machp[] in dat.h and active.machs[], and it is
 * 8 because that is more than QEMU's virt is usually asked for and
 * each unused slot costs one nil pointer.  A machine with more
 * processors than this gets the first MAXMACH of them; startcpus()
 * says so when it clips.
 */
#define	MAXMACH		8
#define	HZ		100
#define	KSTACK		(32*1024)

/* Physical / virtual (identity, MMU off) */
#define	PHYSDRAM	((uintptr)0x40000000)
#define	DRAMSIZE	(256*1024*1024)		/* matches -m 256 */
#define	KZERO		PHYSDRAM
#define	KTZERO		PHYSDRAM

/* pl011@9000000, same as armv7's own board (same QEMU virt machine) */
#define	UART0		((uintptr)0x09000000)
#define	RTC0		((uintptr)0x09010000)	/* arm,pl031 */

/*
 * intc@8000000: with -M virt (default) this is "arm,cortex-a15-gic"
 * == GICv2 (distributor then MMIO cpu interface); with
 * -M virt,gic-version=3 it is "arm,gic-v3" and GICC is unused (the
 * cpu interface is the ICC_* system registers) while a redistributor
 * region appears at GICR.  The distributor sits at 0x08000000 either
 * way, so trap.c reads GICD_PIDR2's architecture-revision field there
 * to tell the two apart at boot.  GICR base/size are the GICv3 DTB's
 * second reg entry (redistributor-regions=1, 0xf60000 == 123 * 128K,
 * one 128K RD_base+SGI_base pair per possible cpu).
 */
#define	GICD		((uintptr)0x08000000)
#define	GICC		((uintptr)0x08010000)
#define	GICR		((uintptr)0x080a0000)

/* virtio_mmio@a000000 .. a003e00, 32 slots step 0x200, SPI 16..47 */
#define	VIRTIO0		((uintptr)0x0a000000)
#define	VIRTIO_SIZE	0x200
#define	VIRTIO_NDEV	32

/* Mach struct above typical kernel image */
#define	MACHADDR	(PHYSDRAM+0x100000)
#define	USTKTOP		(PHYSDRAM+DRAMSIZE)

/* PCIe (pci-host-ecam-generic) from QEMU -M virt's device tree:
 * ECAM at 0x4010000000, 32-bit MMIO window at 0x10000000, I/O at
 * 0x3eff0000, INTx pins on GIC SPIs 3..6 (irq 35..38). */
#define	PCIECAM		((uintptr)0x4010000000ULL)	/* >32 bits: needs the ULL or kencc truncates */
#define	PCIECAMSZ	((uintptr)0x10000000)
#define	PCIMMIO		((uintptr)0x10000000)
#define	PCIMMIOSZ	((uintptr)0x2eff0000)
#define	PCIPIO		((uintptr)0x3eff0000)
#define	PCIPIOSZ	((uintptr)0x10000)
#define	PCIINTXBASE	35
