/*
 * QEMU -M virt, 32-bit ARMv7-A (cortex-a15) -- one privilege level, MMU
 * off, identity/physical addressing throughout, the same "bare and
 * unmapped" model os/inferno/virt uses for riscv64.  Addresses verified
 * against this host's own QEMU (10.1.3) via
 * qemu-system-arm -M virt -machine dumpdtb=... ; dtc -I dtb -O dts,
 * not copied from documentation.  See doc/inferno-ports.ms.
 */
#define	BI2BY		8
#define	BI2WD		32
#define	BY2WD		4
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
#define	PHYSDRAM	0x40000000
#define	DRAMSIZE	(256*1024*1024)		/* matches -m 256 */
#define	KZERO		PHYSDRAM
#define	KTZERO		PHYSDRAM

/* pl011@9000000, from the real DTB */
#define	UART0		0x09000000

/* intc@8000000: "arm,cortex-a15-gic" == GICv2, dist then cpu interface */
#define	GICD		0x08000000
#define	GICC		0x08010000

/* virtio_mmio@a000000 .. a003e00, 32 slots step 0x200, SPI 16..47 */
#define	VIRTIO0		0x0a000000
#define	VIRTIO_SIZE	0x200
#define	VIRTIO_NDEV	32

/* Mach struct above typical kernel image */
#define	MACHADDR	(PHYSDRAM+0x100000)
#define	USTKTOP		(PHYSDRAM+DRAMSIZE)
