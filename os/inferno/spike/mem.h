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
#define	DRAMSIZE	(128*1024*1024)
#define	KZERO		PHYSDRAM
#define	KTZERO		PHYSDRAM

#define	CLINT		((uintptr)0x02000000)
#define	HTIF_TOHOST	((uintptr)0x01000000)	/* ucb,htif0 */
#define	HTIF_FROMHOST	(HTIF_TOHOST + 8)

#define	MACHADDR	(PHYSDRAM+0x100000)
#define	USTKTOP		(PHYSDRAM+DRAMSIZE)
