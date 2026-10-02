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
 * AND IT BREAKS ON PURPOSE.  The medium is the layer a filesystem's
 * durability argument rests on, and on this desk that layer has never been
 * testable: doc/open-issues-plan.ms item G1b asks why a superblock became
 * durable while a node it named did not, and says the test that would
 * settle it is to pull the power -- which needs a human at the board and
 * cannot be put in a suite.  A device that can be told to lose writes is
 * that test, repeatable, and it reaches cases a power cut cannot be aimed
 * at: lose the writes from transfer 40 onward, then from 41, then from 42.
 *
 * Four faults, each modelling something a real medium does:
 *
 *	fail n		transfer n returns an I/O error
 *	stop n		from transfer n on, a write is ACCEPTED and
 *			DISCARDED -- a power cut, where the device said
 *			yes and nothing landed
 *	tear n		transfer n writes its first sector and reports
 *			success -- a torn write across a sector boundary
 *	reorder n	hold up to n writes and apply them BACKWARDS, a
 *			volatile write cache that does not keep order
 *
 * "stop" is the one that matters for G1b, because it is the only one that
 * produces the state the plan is asking about.  "reorder" is the one that
 * tests whether efs's commit barrier is load-bearing or merely believed:
 * a filesystem whose ordering argument is right survives a reorder inside
 * one transaction and nothing else.
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

	/*
	 * How many writes "reorder" may hold.
	 *
	 * A real card's volatile cache is a few hundred KB and this is 64
	 * transfers, which for a 4KB filesystem block is 512KB -- the same
	 * order.  It is bounded rather than configurable because a queue
	 * that can hold a whole transaction would not be modelling a cache,
	 * and because every held write is a copy of its data.
	 */
	Maxheld		= 64,
};

typedef struct Held Held;
struct Held {
	uvlong	bno;
	long	nb;
	uchar*	data;
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

	/*
	 * Injected faults.  Each is a transfer NUMBER and not a
	 * probability, because a test that cannot say which transfer it
	 * broke cannot be run twice and get the same answer -- and
	 * "survives a loss at every point in turn" is the statement worth
	 * making, which needs the point to be nameable.
	 *
	 * nxfer counts transfers since the last "reset", so a test resets
	 * the counters and then names a transfer relative to its own
	 * workload rather than to whatever ran before it.
	 */
	uvlong	nxfer;
	uvlong	failat;			/* this transfer returns Eio */
	uvlong	failevery;		/* and every n'th one does */
	uvlong	stopat;			/* writes from here on are discarded */
	uvlong	tearat;			/* this one writes its first sector */
	int	nreorder;		/* hold this many writes, 0 = off */
	int	partial;		/* of a LOST queue, apply the newest n */
	Held	held[Maxheld];
	int	nheld;

	/* counters; "ops" are bio calls, "secs" are sectors moved */
	uvlong	nreadop, nwriteop;
	uvlong	nreadsec, nwritesec;
	uvlong	nzeroread;		/* reads served from the hole */
	uvlong	nfailed;
	uvlong	ndropped;		/* writes accepted and thrown away */
	uvlong	ntorn;
	uvlong	ninjected;		/* errors returned on purpose */
	uvlong	nreordered;		/* writes applied out of order */
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

/*
 * Move bytes between the sparse store and a buffer.
 *
 * Factored out of sdmembio because the held-write queue has to apply
 * through exactly the same path: a reordered write that took a different
 * route to the store would be testing the route and not the ordering.
 * Returns 0 if a chunk could not be had.
 */
static int
sdmemmove(Ctlr *c, int write, uchar *p, long nbytes, uvlong off)
{
	uchar *ch;
	ulong ci, co, n;
	long done;

	done = 0;
	while(done < nbytes){
		ci = (ulong)((off + done) >> Chunkshift);
		co = (ulong)((off + done) & (Chunksize - 1));
		n = Chunksize - co;
		if(n > nbytes - done)
			n = nbytes - done;
		ch = c->chunk[ci];
		if(write){
			if(ch == nil){
				if((ch = malloc(Chunksize)) == nil)
					return 0;
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
	return 1;
}

/*
 * Apply the held writes BACKWARDS and empty the queue.
 *
 * Newest first, so an older write to the same sectors wins -- which is
 * what a cache that does not keep order does to a filesystem, and the
 * only thing that distinguishes "the barrier is load-bearing" from "the
 * barrier is believed in".
 */
static void
sdmemdrain(Ctlr *c)
{
	int i;

	for(i = c->nheld - 1; i >= 0; i--){
		if(!sdmemmove(c, 1, c->held[i].data, c->held[i].nb * Secsize,
		    c->held[i].bno * Secsize))
			c->nfailed++;
		free(c->held[i].data);
		c->held[i].data = nil;
		c->nreordered++;
	}
	c->nheld = 0;
}

/*
 * Throw the held writes away, applying the newest "partial" of them first.
 *
 * What a power cut does to a volatile cache, and the reason "stop" and
 * "reorder" compose: a device told to lose writes from transfer n must
 * also lose whatever it was still holding, or the test is kinder than the
 * failure it models.
 *
 * AND "partial" IS WHY THIS IS NOT JUST A DELETE, which took four clean
 * trials to notice.  A whole queue lost is a kind failure for a
 * copy-on-write filesystem: every write in one transaction goes to a NEW
 * block, so whatever subset lands, the OLD superblock still names a
 * complete old tree.  efs came back clean at every cut point and both
 * superblocks checked, and it had to.
 *
 * The state doc/open-issues-plan.ms G1 is actually about -- a superblock
 * durable while a node it names is not -- needs the loss to fall INSIDE a
 * writeback: some of the queue applied and the rest not.  Backwards, so
 * the newest goes first, and the newest is the superblock, because efs
 * writes that last.  "partial 1" therefore puts the superblock on the
 * medium and loses the tree it names, which is the failure a power cut
 * mid-writeback produces and which no cut point alone can reach.
 */
static void
sdmemlose(Ctlr *c)
{
	int i, n;

	n = 0;
	for(i = c->nheld - 1; i >= 0; i--){
		if(n < c->partial){
			if(!sdmemmove(c, 1, c->held[i].data,
			    c->held[i].nb * Secsize, c->held[i].bno * Secsize))
				c->nfailed++;
			c->nreordered++;
			n++;
		}else
			c->ndropped++;
		free(c->held[i].data);
		c->held[i].data = nil;
	}
	c->nheld = 0;
}

/*
 * Zero the counters, AND the transfer number the faults are indexed by.
 *
 * The two cannot be separated: "fail transfer 40" means the fortieth
 * transfer of the workload under test, and a workload that does not get
 * to start counting from its own beginning cannot name one.  Resetting
 * does not clear the faults themselves -- they are a setting, not a
 * measurement -- so the usual order is to set them and then reset.
 */
static void
sdmemreset(Ctlr *c)
{
	c->nreadop = c->nwriteop = 0;
	c->nreadsec = c->nwritesec = 0;
	c->nzeroread = 0;
	c->nfailed = 0;
	c->ndropped = c->ntorn = c->ninjected = c->nreordered = 0;
	c->nxfer = 0;
}

/*
 * Forget every injected fault, applying nothing that is held.
 */
static void
sdmemnofault(Ctlr *c)
{
	sdmemlose(c);
	c->failat = c->failevery = c->stopat = c->tearat = 0;
	c->nreorder = 0;
	c->partial = 0;
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
	uchar *p = a;
	uvlong off, end, xfer;
	long nbytes;
	int i, j, torn;

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

	/*
	 * This transfer's number, counted BEFORE anything else, so that a
	 * transfer which fails still used one up.  A fault that moved
	 * depending on whether the previous fault fired would make the
	 * injection depend on itself.
	 */
	xfer = ++c->nxfer;
	off = bno * Secsize;
	nbytes = nb * Secsize;

	/*
	 * A HARD ERROR, which is what a medium does when it cannot do a
	 * transfer at all.  Counted as both failed and injected: a test
	 * reading the counters needs to tell the faults it asked for from
	 * the ones it did not.
	 */
	if((c->failat != 0 && xfer == c->failat) ||
	   (c->failevery != 0 && xfer % c->failevery == 0)){
		c->nfailed++;
		c->ninjected++;
		qunlock(c);
		error(Eio);
	}

	/*
	 * A POWER CUT.  From here on a write is accepted, reported
	 * successful, and thrown away; reads still work, because the
	 * machine has not stopped yet -- what has stopped is the medium
	 * keeping anything.
	 *
	 * Whatever was held goes too.  A device that loses new writes but
	 * carefully applies its cache is modelling nothing.
	 */
	if(c->stopat != 0 && xfer >= c->stopat){
		if(c->nheld > 0)
			sdmemlose(c);
		if(write){
			c->ndropped++;
			c->nwriteop++;
			c->nwritesec += nb;
			qunlock(c);
			return nbytes;
		}
	}

	/*
	 * A TORN WRITE: the first sector lands and the rest does not, and
	 * the device says it worked.  One sector is the unit a card
	 * guarantees, so a transfer longer than one has no atomicity to
	 * rely on -- which is a thing a format can be designed around and
	 * cannot be designed around if it is never tested.
	 */
	torn = 0;
	if(write && c->tearat != 0 && xfer == c->tearat && nb > 1){
		nbytes = Secsize;
		torn = 1;
		c->ntorn++;
	}

	/*
	 * HELD, to be applied backwards later.  The data is copied because
	 * the caller's buffer is its own again the moment this returns.
	 *
	 * A read has to see a held write, or this would be modelling a
	 * device that loses writes rather than one that reorders them.  The
	 * overlay runs oldest to newest so the newest wins, which is what a
	 * cache looked up in order does.
	 */
	if(write && c->nreorder > 0 && !torn){
		if(c->nheld >= c->nreorder || c->nheld >= Maxheld)
			sdmemdrain(c);
		i = c->nheld;
		if((c->held[i].data = malloc(nbytes)) == nil){
			c->nfailed++;
			qunlock(c);
			error(Enomem);
		}
		memmove(c->held[i].data, p, nbytes);
		c->held[i].bno = bno;
		c->held[i].nb = nb;
		c->nheld++;
		c->nwriteop++;
		c->nwritesec += nb;
		qunlock(c);
		return nbytes;
	}

	if(!sdmemmove(c, write, p, nbytes, off)){
		c->nfailed++;
		qunlock(c);
		error(Enomem);
	}
	if(!write && c->nheld > 0)
		for(i = 0; i < c->nheld; i++){
			uvlong hs, he, os, oe, s;

			hs = c->held[i].bno;
			he = hs + c->held[i].nb;
			os = bno;
			oe = bno + nb;
			if(he <= os || oe <= hs)
				continue;
			s = hs > os? hs: os;
			he = he < oe? he: oe;
			for(j = 0; s + j < he; j++)
				memmove(p + (s + j - os) * Secsize,
					c->held[i].data + (s + j - hs) * Secsize,
					Secsize);
		}

	if(write){
		c->nwriteop++;
		c->nwritesec += nb;
	}else{
		c->nreadop++;
		c->nreadsec += nb;
	}
	qunlock(c);
	return torn? nb * Secsize: nbytes;
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
	p = seprint(p, e, "sdmem xfer %llud fail %llud every %llud stop %llud tear %llud reorder %d partial %d held %d\n",
		c->nxfer, c->failat, c->failevery, c->stopat, c->tearat,
		c->nreorder, c->partial, c->nheld);
	p = seprint(p, e, "sdmem injected %llud dropped %llud torn %llud reordered %llud\n",
		c->ninjected, c->ndropped, c->ntorn, c->nreordered);
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
		sdmemlose(c);
		sdmemzero(c);
		qunlock(c);
		return 0;
	}
	if(strcmp(cb->f[0], "nofault") == 0){
		qlock(c);
		sdmemnofault(c);
		qunlock(c);
		return 0;
	}
	if(strcmp(cb->f[0], "flush") == 0){
		qlock(c);
		sdmemdrain(c);
		qunlock(c);
		return 0;
	}
	if(strcmp(cb->f[0], "lose") == 0){
		qlock(c);
		sdmemlose(c);
		qunlock(c);
		return 0;
	}
	if(strcmp(cb->f[0], "fail") == 0 || strcmp(cb->f[0], "failevery") == 0 ||
	   strcmp(cb->f[0], "stop") == 0 || strcmp(cb->f[0], "tear") == 0){
		if(cb->nf != 2)
			error(Ebadctl);
		v = strtoull(cb->f[1], nil, 0);
		qlock(c);
		if(strcmp(cb->f[0], "fail") == 0)
			c->failat = v;
		else if(strcmp(cb->f[0], "failevery") == 0)
			c->failevery = v;
		else if(strcmp(cb->f[0], "stop") == 0)
			c->stopat = v;
		else
			c->tearat = v;
		qunlock(c);
		return 0;
	}
	if(strcmp(cb->f[0], "partial") == 0){
		if(cb->nf != 2)
			error(Ebadctl);
		v = strtoull(cb->f[1], nil, 0);
		if(v > Maxheld)
			v = Maxheld;
		qlock(c);
		c->partial = (int)v;
		qunlock(c);
		return 0;
	}
	if(strcmp(cb->f[0], "reorder") == 0){
		if(cb->nf != 2)
			error(Ebadctl);
		v = strtoull(cb->f[1], nil, 0);
		if(v > Maxheld)
			v = Maxheld;
		qlock(c);
		/*
		 * Lowering the depth has to apply what is already held, or
		 * turning the fault off would lose writes -- which is the
		 * other fault, and a command should do one thing.
		 */
		if((int)v < c->nheld)
			sdmemdrain(c);
		c->nreorder = (int)v;
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
		sdmemlose(c);
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
