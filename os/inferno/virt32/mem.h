/*
 * QEMU virt (riscv32) memory map -- identity mapped, M-mode.
 * Same QEMU virt board as os/inferno/virt (riscv64); verified this is
 * the same memory map regardless of XLEN via
 * qemu-system-riscv32 -M virt -machine dumpdtb=...  ; dtc -I dtb -O dts,
 * not assumed from the riscv64 board.  See doc/inferno-ports.ms.
 *
 * 0x80000000 is INT32_MIN as a 32-bit signed immediate; build it with a
 * shift the same way virt/mem.h builds it for riscv64, since zc's
 * constant handling around the sign bit hasn't been checked either way.
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

#define	MAXMACH		1
#define	HZ		100
#define	KSTACK		(32*1024)

/* Physical / virtual (identity) */
#define	PHYSDRAM	((uintptr)8 << 28)	/* 0x80000000 */
#define	DRAMSIZE	(256*1024*1024)		/* -m 256 */
#define	KZERO		PHYSDRAM
#define	KTZERO		PHYSDRAM		/* link address */
#define	UART0		((uintptr)1 << 28)	/* 0x10000000 NS16550A */
#define	VIRTIO0		((uintptr)0x10001000)	/* first virtio-mmio slot */
#define	VIRTIO_SIZE	0x1000
#define	VIRTIO_NDEV	8
#define	CLINT		((uintptr)0x02000000)
#define	PLIC		((uintptr)0xc << 24)	/* 0x0c000000 SiFive PLIC */

/* pci-host-ecam-generic (QEMU virt) -- empty until -device ... */
#define	PCIECAM		((uintptr)0x30000000)
#define	PCIECAMSZ	((uintptr)0x10000000)	/* 256 MiB config */
#define	PCIMMIO		((uintptr)0x40000000)
#define	PCIMMIOSZ	((uintptr)0x40000000)

/* Mach struct above typical kernel image */
#define	MACHADDR	(PHYSDRAM+0x100000)
#define	USTKTOP		(PHYSDRAM+DRAMSIZE)
