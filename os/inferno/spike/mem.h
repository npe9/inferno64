/*
 * QEMU -M spike — CLINT + HTIF, identity mapped M-mode.
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
#define	KSTACK		(32*1024)
#define	BOOT_HART	0

#define	PHYSDRAM	((uintptr)8 << 28)	/* 0x80000000 */
/*
 * The fallback, not the size.  archconfinit() takes the real total
 * from the device tree QEMU hands the kernel in a1, and uses this only
 * when there is no tree.  It happens to equal QEMU's default -m for
 * this machine, which is why it was right for as long as nobody passed
 * -m.
 */
#define	DRAMSIZE	(128*1024*1024)
#define	KZERO		PHYSDRAM
#define	KTZERO		PHYSDRAM

#define	CLINT		((uintptr)0x02000000)
/*
 * Vestigial, and kept only so the tree can be reported against
 * something.  QEMU maps HTIF over this fixed window only for a kernel
 * whose ELF has no tohost symbol; elf-htif-syms.py puts tohost and
 * fromhost into this one after the link, so QEMU maps HTIF over the
 * kernel's own two cells instead and htif.c reaches the console
 * through &tohost.  The device tree says as much: with this kernel
 * loaded the htif node arrives carrying a compatible and no reg at
 * all, and with a kernel lacking the symbols the same QEMU gives it
 * reg = <0 0x1000000 0 0x1000>.
 */
#define	HTIF_TOHOST	((uintptr)0x01000000)	/* ucb,htif0 */
#define	HTIF_FROMHOST	(HTIF_TOHOST + 8)

#define	MACHADDR	(PHYSDRAM+0x100000)
/*
 * Vestigial, and left deriving from DRAMSIZE rather than from the real
 * top of memory because nothing on this board reads it.  Checked
 * against this board's config and link line: proc.c is linked but
 * nothing calls its kexit(), and portclock.c and devproc.c -- the
 * other two readers of USTKTOP under os/inferno/port -- are not in the
 * config.  Were any of them to appear this would have to become
 * conf.topofmem, which since archconfinit() started sizing memory from
 * the tree is no longer PHYSDRAM+DRAMSIZE.
 */
#define	USTKTOP		(PHYSDRAM+DRAMSIZE)
