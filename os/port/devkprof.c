#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

#ifndef LRES
#define	LRES	3		/* log of PC resolution */
#endif

#define	SZ	4		/* sizeof of count cell; well known as 4 */

enum {
	SpecialTotalTicks,
	SpecialOutsideTicks,
	SpecialMicroSecondsPerTick,
	SpecialSamples,
	SpecialSampleSize,
	SpecialSampleLogBucketSize,
	SpecialMax
};

struct
{
	ulong	minpc;		/* ulong: LLP64 PCs at 0x80000000+ (not signed int) */
	ulong	maxpc;
	int	nbuf;
	int	time;
	ulong	*buf;
}kprof;

enum{
	Qdir,
	Qdata,
	Qctl,
	Kprofmaxqid,
};

Dirtab kproftab[]={
	".",		{Qdir, 0, QTDIR},	0,	0500,
	"kpdata",	{Qdata},		0,	0600,
	"kpctl",	{Qctl},		0,	0600,
};

void kproftimer(ulong);
void	(*kproftick)(ulong);

static void
kprofinit(void)
{
	if(SZ != sizeof kprof.buf[0])
		panic("kprof size");
}

static void
kprofbufinit(void)
{
	kprof.buf[SpecialMicroSecondsPerTick] = archkprofmicrosecondspertick();
	kprof.buf[SpecialSamples] = kprof.nbuf;
	kprof.buf[SpecialSampleSize] = SZ;
	kprof.buf[SpecialSampleLogBucketSize] = LRES;
}

static Chan *
kprofattach(char *spec)
{
	ulong n;

	/* allocate when first used */
	kproftick = kproftimer;
	kprof.minpc = KTZERO;
	kprof.maxpc = (ulong)etext;
	kprof.nbuf = (kprof.maxpc-kprof.minpc) >> LRES;
	n = kprof.nbuf*SZ;
	if(kprof.buf == 0) {
		kprof.buf = xalloc(n);
		if(kprof.buf == 0)
			error(Enomem);
	}
	kproftab[0].length = n;
	kprofbufinit();
	return devattach('K', spec);
}

static Walkqid*
kprofwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, kproftab, nelem(kproftab), devgen);
}

static int
kprofstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, kproftab, nelem(kproftab), devgen);
}

static Chan *
kprofopen(Chan *c, u32 omode)
{
	if(c->qid.type & QTDIR){
		if(omode != OREAD)
			error(Eperm);
	}
	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	return c;
}

void
kprofclose(Chan*)
{
}

/*
 * Print hottest PC buckets to the console (for virt serial / smoke logs).
 */
static void
kprofdump(void)
{
	ulong i, pc, hits, total, outside;
	int n, j;
	ulong top[16], topi[16];

	if(kprof.buf == nil){
		print("kprof: no buffer\n");
		return;
	}
	total = kprof.buf[SpecialTotalTicks];
	outside = kprof.buf[SpecialOutsideTicks];
	print("KPROF total ");
	print("%lud", total);
	print(" outside ");
	print("%lud\n", outside);
	for(j = 0; j < nelem(top); j++){
		top[j] = 0;
		topi[j] = 0;
	}
	for(i = SpecialMax; i < (ulong)kprof.nbuf; i++){
		hits = kprof.buf[i];
		if(hits == 0)
			continue;
		for(j = 0; j < nelem(top); j++){
			if(hits > top[j]){
				memmove(top+j+1, top+j, (nelem(top)-j-1)*sizeof(top[0]));
				memmove(topi+j+1, topi+j, (nelem(top)-j-1)*sizeof(topi[0]));
				top[j] = hits;
				topi[j] = i;
				break;
			}
		}
	}
	n = 0;
	for(j = 0; j < nelem(top) && top[j] != 0; j++){
		pc = kprof.minpc + (topi[j] << LRES);
		print("KPROF-TOP ");
		print("%lud ", top[j]);
		print("%#lux\n", pc);
		n++;
	}
	if(n == 0)
		print("KPROF-TOP none\n");
	/* Optional board hook (virt screen soft→fb / cursor path). */
	{
		extern void screenstats(void);

		screenstats();
	}
}

static int
kprofread(Chan *c, void *va, s32 n, s64 offset)
{
	ulong tabend;
	ulong w, *bp;
	uchar *a, *ea;

	switch((u64)c->qid.path){
	case Qdir:
		return devdirread(c, va, n, kproftab, nelem(kproftab), devgen);

	case Qdata:
		tabend = kprof.nbuf*SZ;
		if(offset & (SZ-1))
			error(Ebadarg);
		if(offset >= tabend){
			n = 0;
			break;
		}
		if(offset+n > tabend)
			n = tabend-offset;
		n &= ~(SZ-1);
		a = va;
		ea = a + n;
		bp = kprof.buf + offset/SZ;
		while(a < ea){
			w = *bp++;
			*a++ = w>>24;
			*a++ = w>>16;
			*a++ = w>>8;
			*a++ = w>>0;
		}
		break;

	default:
		n = 0;
		break;
	}
	return n;
}

static int
kprofwrite(Chan *c, void *vp, s32 n, s64 offset)
{
	char *a;
	USED(offset);

	a = vp;
	switch((u64)c->qid.path){
	case Qctl:
		if(strncmp(a, "startclr", 8) == 0){
			memset((char *)kprof.buf, 0, kprof.nbuf*SZ);
			kprofbufinit();
			archkprofenable(1);
			kprof.time = 1;
		}else if(strncmp(a, "start", 5) == 0) {
			archkprofenable(1);
			kprof.time = 1;
		}
		else if(strncmp(a, "stop", 4) == 0) {
			archkprofenable(0);
			kprof.time = 0;
		}
		else if(strncmp(a, "dump", 4) == 0) {
			kprofdump();
		}
		else
			error(Ebadctl);
		break;
	default:
		error(Ebadusefd);
	}
	return n;
}

void
kproftimer(ulong pc)
{
	extern void spldone(void);

	if(kprof.time == 0)
		return;
	/*
	 *  if the pc is coming out of spllo or splx,
	 *  use the pc saved when we went splhi.
	 */
//	if(pc>=(ulong)splx && pc<=(ulong)spldone)
//		pc = m->splpc;

	kprof.buf[SpecialTotalTicks]++;
	if(kprof.minpc + (SpecialMax << LRES) <= pc && pc < kprof.maxpc){
		pc -= kprof.minpc;
		pc >>= LRES;
		kprof.buf[pc]++;
	}else
		kprof.buf[SpecialOutsideTicks]++;
}

Dev kprofdevtab = {
	'K',
	"kprof",

	devreset,
	kprofinit,
	devshutdown,
	kprofattach,
	kprofwalk,
	kprofstat,
	kprofopen,
	devcreate,
	kprofclose,
	kprofread,
	devbread,
	kprofwrite,
	devbwrite,
	devremove,
	devwstat,
};
