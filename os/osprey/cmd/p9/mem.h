#define	KZERO		0xffffffff80000000ULL
#define	BY2PG		4096
#define	BY2WD		8
#define	MAXSYSARG	5
#define	MAXMACH		128
#define	PTEPERTAB	512	/* PTEMAPMEM/BY2PG */
#define	SSEGMAPSIZE	16
#define	MB		(1024*1024)
#define	ROUND(s, sz)	(((s)+(sz)-1) & ~((ulong)(sz)-1))
