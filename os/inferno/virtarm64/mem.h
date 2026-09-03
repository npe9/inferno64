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
#define	PHYSDRAM	((uintptr)0x40000000)
#define	DRAMSIZE	(256*1024*1024)		/* matches -m 256 */
#define	KZERO		PHYSDRAM
#define	KTZERO		PHYSDRAM

/* pl011@9000000, same as armv7's own board (same QEMU virt machine) */
#define	UART0		((uintptr)0x09000000)

/* intc@8000000: "arm,cortex-a15-gic" == GICv2, dist then cpu interface */
#define	GICD		((uintptr)0x08000000)
#define	GICC		((uintptr)0x08010000)

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
