/*
 * QEMU virt (riscv64) memory map — identity mapped, M-mode
 *
 * KenC does not treat 0x80000000ULL as a true 64-bit constant (sign-extends
 * from 32-bit).  Build high addresses with shifts instead.
 */
#define	BI2BY		8
#define	BI2WD		64
#define	BY2WD		8
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
/* Match pc64: traps use the interrupted kstack (TRAPPAD≈2KB) plus soft
 * cursor / draw under virtio input; 8KB overflowed → illegal insn at
 * heap/BSS PCs (cause 0x2) under Cocoa mouse load. */
#define	KSTACK		(32*1024)

/* Physical / virtual (identity) */
#define	PHYSDRAM	((uintptr)8 << 28)	/* 0x80000000 */
#define	DRAMSIZE	(256*1024*1024)		/* -m 256; headroom for Acme+Charon+Man */
#define	KZERO		PHYSDRAM
#define	KTZERO		PHYSDRAM		/* link address */
#define	UART0		((uintptr)1 << 28)	/* 0x10000000 NS16550A */
#define	VIRTIO0		((uintptr)0x10001000)	/* first virtio-mmio slot */
#define	VIRTIO_SIZE	0x1000
#define	VIRTIO_NDEV	8
#define	CLINT		((uintptr)0x02000000)
#define	PLIC		((uintptr)0xc << 24)	/* 0x0c000000 SiFive PLIC */

/* pci-host-ecam-generic (QEMU virt) — empty until -device … */
#define	PCIECAM		((uintptr)0x30000000)
#define	PCIECAMSZ	((uintptr)0x10000000)	/* 256 MiB config */
#define	PCIMMIO		((uintptr)0x40000000)
#define	PCIMMIOSZ	((uintptr)0x40000000)

/* Mach struct above typical kernel image */
#define	MACHADDR	(PHYSDRAM+0x100000)
#define	USTKTOP		(PHYSDRAM+DRAMSIZE)
