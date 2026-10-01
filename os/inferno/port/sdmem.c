/*
 * sdmem - a block device in RAM, for benchmarking filesystems.
 *
 * WHY THIS EXISTS.  Every filesystem measurement on this board has had two
 * costs mixed together: what the filesystem does, and what the medium
 * charges for it.  They are not close to each other.  Ten file creates
 * straight onto the FAT partition cost 38.8ms EACH through dossrv and the
 * SD card, against 0.95 SECONDS for three hundred efs creates under host
 * emu -- so on silicon a durable metadata update is tens of milliseconds
 * and the filesystem's own work disappears underneath it.  Two sessions'
 * worth of conclusions in doc/open-issues-plan.ms items B1, B1a and F1
 * were reached by pulling those two apart by arithmetic, which works but
 * is not how it should have to be done.
 *
 * On this device the medium costs nothing, so a measurement is the
 * filesystem.  And because the medium is a parameter rather than a fact,
 * "delay" puts the cost back, in microseconds per transfer, so the same
 * filesystem can be run against an SD card's latency, an NVMe's, or none
 * at all -- which is what turns "efs does 69 reads per commit" into a
 * prediction that can be checked instead of multiplied out by hand.
 *
 * THE COUNTERS ARE HERE, NOT IN THE FILESYSTEM, and that is the point of
 * putting them in a driver.  Attributing efs's reads needed counters
 * patched into appl/lib/efs.b twice, built, measured and reverted both
 * times.  Anything layered on this device -- efs, kfs, dossrv, a raw
 * dd -- is counted for free and counted the same way, so two filesystems'
 * numbers can be compared without trusting that their instruments agree.
 *
 * SPARSE, and deliberately.  Chunks are allocated on first write, so an
 * unwritten disk costs its chunk table and nothing else, and a 16MB disk
 * on a board whose main pool is about 50MB does not have to be paid for
 * up front.  A read of a chunk that was never written returns zeros,
 * which is also what a freshly made disk should look like to anything
 * that checks whether a region is clear before writing it -- mkefs does
 * exactly that, and would refuse on uninitialised RAM that held garbage.
 *
 * NOT A RAM DISK FOR STORING THINGS.  It is cleared by a reboot and there
 * is no attempt to make it survive one.  Nothing in a boot script should
 * mount it.
 */

#include "u.h"
#include "../port/lib.h"
#include "../port/error.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"

#include "../port/sd.h"

enum {
	Secsize		= 512,
	Chunkshift	= 12,			/* 4096 bytes */
	Chunksize	= 1 << Chunkshift,
	Secperchunk	= Chunksize / Secsize,

	/*
	 * Default size, in sectors: 16MB.
	 *
	 * Chosen against this board rather than as a round number.  The
	 * chunk table is one pointer per 4KB, so 16MB costs 32KB of table
	 * whether or not anything is written; a fully written 16MB disk
	 * costs 16MB of the main pool, which is about a third of it, and
	 * that is the real bound.  An efs image big enough to show B1's
	 * quadratic is 4096 blocks, 16MB, and does not write all of it.
	 * Change it with "echo size <sectors> >/dev/sdX0/ctl" before
	 * anything opens the data file.
	 */
	Defsectors	= 16*1024*1024 / Secsize,

	/* a sanity bound, not a policy: refuse a disk that cannot be held */
	Maxsectors	= 256*1024*1024 / Secsize,
};

typedef struct Ctlr Ctlr;
struct Ctlr {
	QLock;
	int	inited;
	uvlong	sectors;
	uchar**	chunk;			/* nil until written */
	ulong	nchunk;
	ulong	nalloced;		/* chunks holding data */

	int	delayus;		/* charged per transfer, 0 by default */

	/* counters; "ops" are bio calls, "secs" are sectors moved */
	uvlong	nreadop, nwriteop;
	uvlong	nreadsec, nwritesec;
	uvlong	nzeroread;		/* reads served from the hole */
	uvlong	nfailed;
};

static Ctlr sdmemctlr;

extern SDifc sdmemifc;

/*
 * Give the disk a size, dropping whatever it held.
 *
 * Returns 0 and leaves the old disk alone if the table cannot be had, so
 * a size that is too large is refused rather than leaving no disk at all.
 */
static int
sdmemsize(Ctlr *c, uvlong nsec)
{
	uchar **t;
	ulong n, i;

	if(nsec == 0 || nsec > Maxsectors)
		return 0;
	n = (nsec + Secperchunk - 1) / Secperchunk;
	if((t = malloc(n * sizeof(uchar*))) == nil)
		return 0;
	if(c->chunk != nil){
		for(i = 0; i < c->nchunk; i++)
			if(c->chunk[i] != nil)
				free(c->chunk[i]);
		free(c->chunk);
	}
	memset(t, 0, n * sizeof(uchar*));
	c->chunk = t;
	c->nchunk = n;
	c->nalloced = 0;
	c->sectors = nsec;
	return 1;
}

static void
sdmemzero(Ctlr *c)
{
	ulong i;

	for(i = 0; i < c->nchunk; i++)
		if(c->chunk[i] != nil){
			free(c->chunk[i]);
			c->chunk[i] = nil;
		}
	c->nalloced = 0;
}

static void
sdmemreset(Ctlr *c)
{
	c->nreadop = c->nwriteop = 0;
	c->nreadsec = c->nwritesec = 0;
	c->nzeroread = 0;
	c->nfailed = 0;
}

static SDev*
sdmempnp(void)
{
	SDev *s;

	if((s = malloc(sizeof(*s))) == nil)
		return nil;
	s->ctlr = &sdmemctlr;
	/*
	 * 'Z' so it sorts after the real controllers and cannot take
	 * /dev/sdM0 or /dev/sdN0 from the card this board boots off.
	 */
	s->idno = 'Z';
	s->ifc = &sdmemifc;
	s->nunit = 1;
	return s;
}

static int
sdmemverify(SDunit *u)
{
	USED(u);
	return 1;
}

static int
sdmemonline(SDunit *u)
{
	Ctlr *c = u->dev->ctlr;
	int first;

	qlock(c);
	first = 0;
	if(!c->inited){
		if(!sdmemsize(c, Defsectors)){
			qunlock(c);
			return 0;		/* no memory: no media */
		}
		c->inited = 1;
		first = 1;
	}
	/*
	 * Repopulate every call.  sdinitpart() zeroes unit->sectors before
	 * each one, so a re-init that does not restore them loses the data
	 * partition -- the same rule the card drivers here record learning.
	 */
	u->secsize = Secsize;
	u->sectors = c->sectors;
	qunlock(c);
	return first? 2: 1;
}

/*
 * One transfer.  Walks chunks, so a request may span any number of them.
 *
 * A read of a hole returns zeros and allocates nothing: a benchmark that
 * reads far more than it writes should not be made to pay for the whole
 * disk, and a filesystem reading an unwritten block is reading what a
 * fresh disk holds.
 */
static long
sdmembio(SDunit *u, int lun, int write, void *a, long nb, uvlong bno)
{
	Ctlr *c = u->dev->ctlr;
	uchar *p = a, *ch;
	uvlong off, end;
	ulong ci, co, n;
	long done;

	USED(lun);
	if(nb <= 0)
		return 0;
	qlock(c);
	if(!c->inited || c->chunk == nil){
		c->nfailed++;
		qunlock(c);
		error(Eio);
	}
	end = bno + nb;
	if(end > c->sectors || end < bno){
		c->nfailed++;
		qunlock(c);
		error(Eio);
	}

	/*
	 * The modelled medium is charged ONCE per transfer, not per sector.
	 * A card's cost is dominated by the command, not by the bytes, which
	 * is why a FAT create costs 38.8ms while the card streams megabytes
	 * a second -- and a per-sector charge would model bandwidth, which
	 * is the term that was already shown not to matter.
	 */
	if(c->delayus > 0)
		microdelay(c->delayus);

	off = bno * Secsize;
	done = 0;
	while(done < nb * Secsize){
		ci = (ulong)((off + done) >> Chunkshift);
		co = (ulong)((off + done) & (Chunksize - 1));
		n = Chunksize - co;
		if(n > nb * Secsize - done)
			n = nb * Secsize - done;
		ch = c->chunk[ci];
		if(write){
			if(ch == nil){
				if((ch = malloc(Chunksize)) == nil){
					c->nfailed++;
					qunlock(c);
					error(Enomem);
				}
				memset(ch, 0, Chunksize);
				c->chunk[ci] = ch;
				c->nalloced++;
			}
			memmove(ch + co, p + done, n);
		}else if(ch == nil){
			memset(p + done, 0, n);
			c->nzeroread++;
		}else
			memmove(p + done, ch + co, n);
		done += n;
	}

	if(write){
		c->nwriteop++;
		c->nwritesec += nb;
	}else{
		c->nreadop++;
		c->nreadsec += nb;
	}
	qunlock(c);
	return done;
}

static char*
sdmemrctl(SDunit *u, char *p, char *e)
{
	Ctlr *c = u->dev->ctlr;

	qlock(c);
	p = seprint(p, e, "geometry %llud %lud\n", u->sectors, u->secsize);
	p = seprint(p, e, "sdmem delay %dus chunks %lud of %lud (%ludKB held)\n",
		c->delayus, c->nalloced, c->nchunk,
		(c->nalloced * Chunksize) / 1024);
	p = seprint(p, e, "sdmem reads %llud ops %llud secs, writes %llud ops %llud secs\n",
		c->nreadop, c->nreadsec, c->nwriteop, c->nwritesec);
	p = seprint(p, e, "sdmem holeread %llud failed %llud\n",
		c->nzeroread, c->nfailed);
	qunlock(c);
	return p;
}

static int
sdmemwctl(SDunit *u, Cmdbuf *cb)
{
	Ctlr *c = u->dev->ctlr;
	uvlong v;

	if(strcmp(cb->f[0], "reset") == 0){
		qlock(c);
		sdmemreset(c);
		qunlock(c);
		return 0;
	}
	if(strcmp(cb->f[0], "zero") == 0){
		qlock(c);
		sdmemzero(c);
		qunlock(c);
		return 0;
	}
	if(strcmp(cb->f[0], "delay") == 0){
		if(cb->nf != 2)
			error(Ebadctl);
		qlock(c);
		c->delayus = atoi(cb->f[1]);
		if(c->delayus < 0)
			c->delayus = 0;
		qunlock(c);
		return 0;
	}
	if(strcmp(cb->f[0], "size") == 0){
		if(cb->nf != 2)
			error(Ebadctl);
		v = strtoull(cb->f[1], nil, 0);
		qlock(c);
		if(!sdmemsize(c, v)){
			qunlock(c);
			error("sdmem: cannot size that disk");
		}
		sdmemreset(c);
		/*
		 * The unit's geometry is stale now.  sdinitpart() runs from
		 * online(), so bump the version and let devsd notice rather
		 * than rewriting the partition table from here.
		 */
		u->sectors = c->sectors;
		u->vers++;
		qunlock(c);
		return 0;
	}
	error(Ebadctl);
	return -1;
}

SDifc sdmemifc = {
	"sdmem",			/* name */

	sdmempnp,			/* pnp */
	nil,				/* enable */
	nil,				/* disable */

	sdmemverify,			/* verify */
	sdmemonline,			/* online */
	nil,				/* rio */
	sdmemrctl,			/* rctl */
	sdmemwctl,			/* wctl */

	sdmembio,			/* bio */
	nil,				/* probe */
	nil,				/* clear */
	nil,				/* rtopctl */
	nil,				/* wtopctl */
};
