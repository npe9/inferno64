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
/*
 * The fallback, not the size.  The suite runs this board with -m 1G
 * and has for a long time, so the old "matches -m 256" was simply
 * wrong; archconfinit() now takes the real total from the device tree
 * and uses this only when there is no tree.  It is not a floor: it
 * was one briefly, and that rejected a tree reporting less than 256MB
 * and left the board claiming memory a smaller machine does not have.
 */
#define	DRAMSIZE	(256*1024*1024)
#define	KZERO		PHYSDRAM
/*
 * The kernel links 2MB above the base of RAM, and the gap is not
 * spare: it is where QEMU puts the device tree.  hw/arm/boot.c's
 * arm_setup_direct_kernel_boot() loads an ELF -kernel and then, only
 * if "image_low_addr > loader_start || image_high_addr <
 * loader_start", sets info->dtb_start = info->loader_start and writes
 * the generated tree there.  Linking at exactly loader_start
 * (0x40000000 on -M virt) makes that test false, so no tree is
 * written anywhere -- which is why this board read no device tree for
 * as long as KTZERO was PHYSDRAM.  x0 is still 0 on the ELF entry
 * path (QEMU only fills the arg pointer for a Linux-format image), so
 * the tree is found at PHYSDRAM by its magic, not by a handed-over
 * pointer.  QEMU's virt tree is 0x100000 bytes; 2MB leaves room and
 * keeps the kernel 2MB-aligned.
 *
 * Nothing else has to move: the MMU is off (mmu.c), so this is a pure
 * relink, and confinit() starts conf.base0 at PGROUND(end), so the
 * gap below the kernel is never in the allocator's pool and the tree
 * stays readable for the life of the boot.
 */
#define	KTZERO		(PHYSDRAM+0x200000)

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

/*
 * Vestigial: unlike the pc port, where dat.h defines up as
 * ((Mach*)MACHADDR)->externup, this board's m and up are plain
 * globals (main.c) and mach0 is a GLOBL in l.s.  Nothing reads this,
 * which is just as well -- the kernel image has long since grown past
 * PHYSDRAM+0x100000.
 */
#define	MACHADDR	(PHYSDRAM+0x100000)
/*
 * Vestigial, and deliberately left deriving from DRAMSIZE rather than
 * from the real top of memory, because nothing on this board reads
 * it.  Checked, in this board's link line and config: nothing calls
 * os/inferno/port/proc.c's kexit(), and portclock.c and devproc.c --
 * whose profiling tick and address check are the other two readers of
 * USTKTOP under os/inferno/port -- are not in the config at all
 * (clock.c is the board's own, devprog.c is linked and devproc.c is
 * not).  Were any of them to appear, this would need to become
 * conf.topofmem: since archconfinit() started sizing memory
 * from the device tree, PHYSDRAM+DRAMSIZE is no longer the top of RAM
 * but a point in the middle of the allocator's range.
 */
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
