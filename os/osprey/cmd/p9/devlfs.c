#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

/*
 * A log-structured file store on the block device the microkernel
 * exposed, as a device in this personality's name space: the file
 * system as a service above the kernel, which is what the plan's
 * storage section asks for, in the shape it says storage on this system
 * should have.  The disk is a log.  A file's version is one record -
 * a header sector naming the file, its version and its length, then
 * its data in the sectors that follow - appended at the head of the
 * log and never changed: a version is immutable once written, and it
 * is written when the file is closed, which is what pi-p says of a
 * file.  Mounting is a scan of the log from its first sector to the
 * first sector that is not a record, taking each file's latest version
 * as it goes; nothing is written in place, so a power loss leaves a
 * log that ends one record shorter, never a torn file.  What is not
 * here yet is reclamation - copying live versions forward and reusing
 * the space behind them - which the plan makes a scheduled task with a
 * reservation of its own; until it exists the log only grows.
 *
 * Reclamation makes the log a ring: the oldest record is either the
 * latest version of its file, in which case it is copied to the head
 * of the log and the copy is the file's, or it is dead, and either way
 * the start of the log moves past it, so the space comes round to be
 * written again.  One record per step; a step is taken on the clock
 * tick the server task waits on (p9pairsrv.c) when the log is more
 * than half full, and by a writer that finds no room, so that the
 * task's reservation is what normally pays for it and a full log only
 * ever costs the writer.  Sector 0 holds a checkpoint - where the log
 * starts and ends, and the last record number - rewritten in place
 * after every commit and every step; it is the one sector written in
 * place, and a disk without one is scanned from sector 1 as before.
 * The last sector is not the log's: the block driver's own check writes
 * it.
 *
 * The device is #l.  The block driver (blkvirtio.c) is reached through
 * three plain-typed functions.
 */
enum {
	Lmagic	= 0x4f534c4653ULL,	/* "OSLFS" */
	Lfirst	= 1,
	Lnamelen = 64,
	Lsector	= 512,
	Lmaxdata = 16*Lsector,		/* one version is at most 8 KB */
	Nlfs	= 32,
	Qroot	= 0,
};

typedef struct Lrec Lrec;
struct Lrec {				/* the header sector of a record */
	uvlong	magic;
	uvlong	seq;			/* the record's number in the log */
	uvlong	vers;			/* which version of the file it is */
	uvlong	len;			/* bytes of data in the sectors after it */
	char	name[Lnamelen];
	/*
	 * A tombstone: this record says the file is gone rather than
	 * carrying a version of it.  It is after the name and not before
	 * it so that a disk written before tombstones existed still reads:
	 * a header sector is written from a zeroed buffer, so an old
	 * record has a zero here and is a version, which is what it is.
	 */
	uvlong	dead;
};

typedef struct Lfile Lfile;
struct Lfile {
	int	used;
	char	name[Lnamelen];
	uvlong	lba;			/* header sector of the latest version; 0 for none on disk */
	ulong	len;
	ulong	vers;
};

typedef struct Lopen Lopen;
struct Lopen {				/* an open file: its bytes, and whether they changed */
	uchar	*buf;
	ulong	len;
	int	dirty;
	Lfile	*f;
	/*
	 * The name it was opened by.  A file removed while it is open
	 * leaves its entry free for the next file made, and committing on
	 * the close of the first would then write the second's name; so
	 * the close commits only if the entry is still this file's.
	 */
	char	name[Lnamelen];
};

extern int blkready(void);
extern uvlong blkcapacity(void);
extern int blkxfer(int, uvlong, void*);

typedef struct Lcp Lcp;
struct Lcp {				/* the checkpoint, sector 0 */
	uvlong	magic;
	uvlong	start;
	uvlong	head;
	uvlong	seq;
};
enum { Lcpmagic = 0x4f534c465343ULL };	/* "OSLFSC" */

static Lfile files[Nlfs];
static uvlong start;			/* the oldest record */
static uvlong head;			/* the next free sector */
static uvlong limit;			/* one past the last sector the log may use */
static uvlong seq;
static int scanned;
static ulong nreclaimed;
static uchar sector[Lsector];
static uchar movebuf[Lmaxdata];

static uvlong
lfssectors(ulong len)
{
	return 1 + (len + Lsector-1)/Lsector;
}

/* sectors free between the head and the start, keeping one so full and empty differ */
static uvlong
lfsfree(void)
{
	if(head >= start)
		return (limit - head) + (start - Lfirst) - 1;
	return start - head - 1;
}

/*
 * Where a record of n sectors would go, or 0 when there is no room.
 * The free count is the gate, so the head never comes round onto the
 * start - which would read as an empty log and be a full one.
 */
static uvlong
lfsroom(uvlong n)
{
	if(lfsfree() < n)
		return 0;
	if(head >= start){
		if(head + n <= limit)
			return head;
		if(Lfirst + n < start)
			return Lfirst;		/* wrap: the tail of the log is skipped */
		return 0;
	}
	return head;
}

static void
lfscheckpoint(void)
{
	Lcp *cp;

	memset(sector, 0, Lsector);
	cp = (Lcp*)sector;
	cp->magic = Lcpmagic;
	cp->start = start;
	cp->head = head;
	cp->seq = seq;
	blkxfer(1, 0, sector);
}

/* the record at pos, if there is one; -1 for a sector that is not a record */
static int
lfsheader(uvlong pos, Lrec *r)
{
	if(pos < Lfirst || pos >= limit || blkxfer(0, pos, sector) < 0)
		return -1;
	memmove(r, sector, sizeof *r);
	if(r->magic != Lmagic || r->len > Lmaxdata || pos + lfssectors(r->len) > limit)
		return -1;
	r->name[Lnamelen-1] = 0;
	return 0;
}

static Lfile*
lfslookup(char *name)
{
	int i;

	for(i = 0; i < Nlfs; i++)
		if(files[i].used && strcmp(files[i].name, name) == 0)
			return &files[i];
	return nil;
}

static Lfile*
lfsnew(char *name)
{
	int i;

	if(strlen(name) >= Lnamelen)
		error(Etoolong);
	for(i = 0; i < Nlfs; i++)
		if(!files[i].used){
			memset(&files[i], 0, sizeof files[i]);
			files[i].used = 1;
			strcpy(files[i].name, name);
			return &files[i];
		}
	error("no room in the store");
	return nil;
}

/*
 * Mount: the checkpoint says where the log starts and ends, and the
 * records between are read in order, so the latest version of each file
 * is the last seen; a sector that is not a record before the head means
 * the writer wrapped there.  Without a checkpoint the log is read from
 * sector 1 to the first sector that is not a record, as a disk written
 * before there were checkpoints must be.
 */
static void
lfsscan(void)
{
	Lrec r;
	Lfile *f;
	Lcp cp;
	uvlong pos;
	int n, checkpointed;

	limit = blkcapacity() - 1;
	memset(&cp, 0, sizeof cp);
	if(blkxfer(0, 0, sector) == 0)
		memmove(&cp, sector, sizeof cp);
	checkpointed = cp.magic == Lcpmagic && cp.start >= Lfirst && cp.start < limit && cp.head >= Lfirst && cp.head < limit;
	if(checkpointed){
		start = cp.start;
		head = cp.head;
		seq = cp.seq;
	} else {
		start = Lfirst;
		head = Lfirst;
		seq = 0;
	}
	n = 0;
	pos = start;
	for(;;){
		if(checkpointed && pos == head)
			break;
		if(lfsheader(pos, &r) < 0){
			if(checkpointed && pos != Lfirst){
				pos = Lfirst;	/* the writer wrapped here */
				continue;
			}
			break;
		}
		f = lfslookup(r.name);
		if(r.dead){
			/*
			 * The file was removed after every version before
			 * this record, so it is not in the store - and a
			 * record after this one with the same name is a file
			 * made again, which the lookup will not find and
			 * will make anew.  This is the whole of what a
			 * tombstone is for: without it a mount is a
			 * resurrection.
			 */
			if(f != nil)
				f->used = 0;
		} else {
			if(f == nil)
				f = lfsnew(r.name);
			f->lba = pos;
			f->len = r.len;
			f->vers = r.vers;
		}
		if(r.seq > seq)
			seq = r.seq;
		n++;
		pos += lfssectors(r.len);
		if(pos >= limit)
			pos = Lfirst;
	}
	if(!checkpointed)
		head = pos;
	scanned = 1;
	print("lfs: mounted the log: %d records, start %llud head %llud of %llud, %llud sectors free, %s\n",
		n, start, head, limit, lfsfree(), checkpointed ? "from the checkpoint" : "no checkpoint, scanned from sector 1");
	for(f = files; f < &files[Nlfs]; f++)
		if(f->used)
			print("lfs: %s version %lud, %lud bytes, at sector %llud\n", f->name, f->vers, f->len, f->lba);
	if(!checkpointed)
		lfscheckpoint();
}

static void
lfsload(Lfile *f, uchar *buf)
{
	ulong off, cnt;

	if(f->lba == 0)
		return;
	for(off = 0; off < f->len; off += cnt){
		if(blkxfer(0, f->lba + 1 + off/Lsector, sector) < 0)
			error(Eio);
		cnt = f->len - off < Lsector ? f->len - off : Lsector;
		memmove(buf + off, sector, cnt);
	}
}

static int lfsreclaimstep(int force);

/*
 * A record at the head of the log: the header sector, then the data.
 * vers is the version it carries: the file's next for a commit, its
 * current for a copy reclamation moves forward.  A writer that finds no
 * room reclaims until there is some, or the log is full of live data.
 */
static void
lfsput(Lfile *f, uchar *buf, ulong len, ulong vers, int dead)
{
	Lrec *r;
	uvlong lba, n;
	ulong off, cnt;

	n = lfssectors(len);
	while((lba = lfsroom(n)) == 0)
		if(!lfsreclaimstep(1))
			error("the log is full");
	memset(sector, 0, Lsector);
	r = (Lrec*)sector;
	r->magic = Lmagic;
	r->seq = ++seq;
	r->vers = vers;
	r->len = len;
	r->dead = dead;
	strcpy(r->name, f->name);
	if(blkxfer(1, lba, sector) < 0)
		error(Eio);
	for(off = 0; off < len; off += cnt){
		cnt = len - off < Lsector ? len - off : Lsector;
		memset(sector, 0, Lsector);
		memmove(sector, buf + off, cnt);
		if(blkxfer(1, lba + 1 + off/Lsector, sector) < 0)
			error(Eio);
	}
	f->lba = lba;
	f->len = len;
	f->vers = vers;
	head = lba + n;
	if(head >= limit)
		head = Lfirst;
	lfscheckpoint();
}

static void
lfsappend(Lfile *f, uchar *buf, ulong len)
{
	lfsput(f, buf, len, f->vers + 1, 0);
	print("lfs: committed %s version %lud, %lud bytes, at sector %llud, %llud sectors free\n",
		f->name, f->vers, f->len, f->lba, lfsfree());
}

/*
 * One step of reclamation: the oldest record is copied forward if it is
 * the latest version of its file and dropped if it is not, and the start
 * of the log moves past it.  Taken on the tick when the log is more than
 * half full, and by a writer that finds no room (force).  Returns 1 when
 * a record was reclaimed.
 */
static int
lfsreclaimstep(int force)
{
	Lrec r;
	Lfile *f;
	uvlong n;

	if(!scanned || start == head)
		return 0;
	if(!force && lfsfree() > (limit - Lfirst)/2)
		return 0;
	if(lfsheader(start, &r) < 0){
		if(start != Lfirst){		/* the writer wrapped: the tail is not records */
			start = Lfirst;
			lfscheckpoint();
			return lfsreclaimstep(force);
		}
		return 0;
	}
	n = lfssectors(r.len);
	f = lfslookup(r.name);
	if(f != nil && f->lba == start){
		/* live: it moves forward, the same version, before the start passes it */
		if(lfsroom(n) == 0 || lfsroom(n) == start)
			return 0;		/* nowhere to put it: the log is full of live data */
		memset(movebuf, 0, sizeof movebuf);
		lfsload(f, movebuf);
		start += n;
		if(start >= limit)
			start = Lfirst;
		lfsput(f, movebuf, r.len, r.vers, 0);
		nreclaimed++;
		print("lfs: reclaim %s: moved %s version %llud forward to sector %llud, start now %llud, %llud sectors free\n",
			force ? "for a writer" : "on the tick", r.name, r.vers, f->lba, start, lfsfree());
		return 1;
	}
	start += n;
	if(start >= limit)
		start = Lfirst;
	lfscheckpoint();
	nreclaimed++;
	print("lfs: reclaim %s: dropped %s version %llud, dead, start now %llud, %llud sectors free\n",
		force ? "for a writer" : "on the tick", r.name, r.vers, start, lfsfree());
	return 1;
}

/*
 * The serve loop's call, on the clock tick: steps while the log is more
 * than half full and the reservation has room for it this period, so
 * that the task's reservation is what pays for reclamation and a writer
 * only pays when the log has filled between two ticks.  The tick asks
 * the kernel what the reservation is and which period this is
 * (ReqAccount), measures what each step costs by the cycle counter, and
 * steps while what reclamation has spent this period is under three
 * quarters of the budget.  It is reclamation's own spending that is
 * measured, not the container's: the server personality serves the
 * client out of the same reservation and is at its budget most periods,
 * and measured that way the reclaim never got a step and writers paid.
 * One step a tick, then eight, were numbers compiled in; this is the
 * reservation.
 */
extern long ospreyxcall(int op, uvlong *args, long n);
extern void ospreycycles(uvlong*);
static uvlong lfssteps, lfsticksbusy, lfsspent, lfsperiod;

int
lfsreclaim(void)
{
	uvlong a[5], t0, t1;
	int n;

	if(!scanned)
		return 0;
	a[0] = a[1] = a[2] = a[3] = a[4] = 0;
	if(ospreyxcall(32, a, 0) < 0)
		a[0] = 0;
	if(a[4] != lfsperiod){		/* a new period: the reservation is whole again */
		lfsperiod = a[4];
		lfsspent = 0;
	}
	for(n = 0; n < 64; n++){
		if(a[0] != 0 && lfsspent >= a[0] - a[0]/4)
			break;			/* reclamation has spent its share of this period */
		ospreycycles(&t0);
		if(!lfsreclaimstep(0))
			break;
		ospreycycles(&t1);
		lfsspent += t1 - t0;
		lfssteps++;
	}
	if(n > 0){
		lfsticksbusy++;
		print("lfs: reclaim on the tick: %d step%s, spent %llud cycles of the %llud this period\n",
			n, n == 1 ? "" : "s", lfsspent, a[0]);
	}
	return n > 0;
}

/* what the tick has done, for the record: steps, and ticks that took any */
void
lfsreclaimstats(uvlong *steps, uvlong *ticks)
{
	*steps = lfssteps;
	*ticks = lfsticksbusy;
}

static int
lfsgen(Chan *c, char *name, Dirtab*, int, int s, Dir *dp)
{
	Lfile *f;
	Qid q;

	if(s == DEVDOTDOT){
		mkqid(&q, Qroot, 0, QTDIR);
		devdir(c, q, "#l", 0, eve, 0775, dp);
		return 1;
	}
	if((c->qid.type & QTDIR) == 0){
		if(c->qid.path < 1 || c->qid.path > Nlfs)
			return -1;
		f = &files[c->qid.path - 1];
		if(!f->used)
			return -1;
	} else if(name != nil){
		if((f = lfslookup(name)) == nil)
			return -1;
	} else {
		if(s >= Nlfs)
			return -1;
		f = &files[s];
		if(!f->used)
			return 0;
	}
	mkqid(&q, (f - files) + 1, f->vers, QTFILE);
	devdir(c, q, f->name, f->len, eve, 0666, dp);
	return 1;
}

static Chan*
lfsattach(char *spec)
{
	Chan *c;

	if(!blkready())
		error("no block device");
	if(!scanned)
		lfsscan();
	c = devattach('l', spec);
	mkqid(&c->qid, Qroot, 0, QTDIR);
	return c;
}

static Walkqid*
lfswalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, lfsgen);
}

static int
lfsstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, nil, 0, lfsgen);
}

static Lopen*
lfsopenfile(Lfile *f, int trunc)
{
	Lopen *o;

	o = smalloc(sizeof(Lopen));
	o->buf = smalloc(Lmaxdata);
	o->f = f;
	strcpy(o->name, f->name);
	if(trunc){
		o->len = 0;
		o->dirty = 1;
	} else {
		if(waserror()){
			free(o->buf);
			free(o);
			nexterror();
		}
		lfsload(f, o->buf);
		poperror();
		o->len = f->len;
	}
	return o;
}

static Chan*
lfsopen(Chan *c, int omode)
{
	if(c->qid.type & QTDIR){
		if(omode != OREAD)
			error(Eperm);
		c->aux = nil;
	} else {
		if(c->qid.path < 1 || c->qid.path > Nlfs || !files[c->qid.path-1].used)
			error(Enonexist);
		c->aux = lfsopenfile(&files[c->qid.path-1], omode & OTRUNC);
	}
	c->mode = openmode(omode);
	c->offset = 0;
	c->flag |= COPEN;
	return c;
}

static Chan*
lfscreate(Chan *c, char *name, int omode, ulong)
{
	Lfile *f;

	if((c->qid.type & QTDIR) == 0)
		error(Eperm);
	if(lfslookup(name) != nil)
		error(Eexist);
	f = lfsnew(name);
	mkqid(&c->qid, (f - files) + 1, 0, QTFILE);
	c->aux = lfsopenfile(f, 1);
	c->mode = openmode(omode);
	c->offset = 0;
	c->flag |= COPEN;
	return c;
}

/* close is commit: a changed file becomes a new version on the log */
static void
lfsclose(Chan *c)
{
	Lopen *o;

	if((c->flag & COPEN) == 0 || (c->qid.type & QTDIR) || (o = c->aux) == nil)
		return;
	c->aux = nil;
	/*
	 * A file removed while it was open does not come back on its
	 * close: the entry is free, or is another file's by now.
	 */
	if(o->dirty && o->f->used && strcmp(o->f->name, o->name) == 0
	&& !waserror()){
		lfsappend(o->f, o->buf, o->len);
		poperror();
	}
	free(o->buf);
	free(o);
}

static long
lfsread(Chan *c, void *a, long n, vlong off)
{
	Lopen *o;

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, nil, 0, lfsgen);
	o = c->aux;
	if(o == nil || off >= o->len)
		return 0;
	if(n > o->len - off)
		n = o->len - off;
	memmove(a, o->buf + off, n);
	return n;
}

static long
lfswrite(Chan *c, void *a, long n, vlong off)
{
	Lopen *o;

	if(c->qid.type & QTDIR)
		error(Eperm);
	o = c->aux;
	if(o == nil)
		error(Ebadusefd);
	if(off + n > Lmaxdata)
		error("a version is at most 8 KB");
	memmove(o->buf + off, a, n);
	if(off + n > o->len)
		o->len = off + n;
	o->dirty = 1;
	return n;
}

/*
 * Remove is a record like any other: a tombstone at the head of the log
 * saying this file is gone.  Nothing is written in place and no version
 * is changed, which is what makes a version immutable; what a remove
 * adds is the last record the file will have.
 *
 * The entry goes from the table at once, so the file is out of the
 * directory now, and it stays out across a mount because the scan reads
 * the tombstone.  A file made again with the same name is a new file:
 * a new entry, its versions starting over, the tombstone between it and
 * the old one.
 */
static void
lfsremove(Chan *c)
{
	Lfile *f;
	ulong was;

	if(c->qid.type & QTDIR)
		error(Eperm);
	if(c->qid.path < 1 || c->qid.path > Nlfs)
		error(Enonexist);
	f = &files[c->qid.path - 1];
	if(!f->used)
		error(Enonexist);
	was = f->vers;
	lfsput(f, nil, 0, f->vers + 1, 1);
	print("lfs: removed %s after version %lud: a tombstone at sector %llud, %llud sectors free\n",
		f->name, was, f->lba, lfsfree());
	f->used = 0;
}

/*
 * wstat, which this store answered with "permission denied" because
 * devwstat is what it had.  A rename is the one thing a log can express
 * without reading like a lie: a version of the file under the new name,
 * and a tombstone for the old, which is what every other change here is
 * too.  The bytes are carried over because that is where they live - the
 * record holds them - so a rename costs a copy, which for this store's
 * files is one sector.
 *
 * Everything else a wstat can ask for is refused by name rather than
 * accepted and dropped: there are no owners here (the whole store is the
 * personality's), the mode is what the device says it is, and a length
 * change is a write's business.  A caller told its wstat succeeded when
 * nothing happened is worse off than one told it cannot be done.
 */
static int
lfswstat(Chan *c, uchar *dp, int n)
{
	Lfile *f, *nf;
	Dir d;
	char strs[512];
	uchar *buf;
	ulong len, i;
	int was;

	if(c->qid.type & QTDIR)
		error(Eperm);
	if(c->qid.path < 1 || c->qid.path > Nlfs)
		error(Enonexist);
	f = &files[c->qid.path - 1];
	if(!f->used)
		error(Enonexist);
	if(convM2D(dp, n, &d, strs) != n)
		error(Eshortstat);
	if(d.mode != (ulong)~0 && d.mode != (DMDIR|0666) && d.mode != 0666)
		error("lfs: the mode here is the device's, not a file's");
	if(d.length != (vlong)~0 && d.length != (vlong)f->len)
		error("lfs: a length is changed by writing, not by wstat");
	if(d.name == nil || d.name[0] == 0)
		return n;			/* nothing asked for */
	if(strcmp(d.name, f->name) == 0)
		return n;			/* the name it has */
	if(strlen(d.name) >= Lnamelen)
		error("lfs: that name is too long for a record");
	for(i = 0; i < Nlfs; i++)
		if(files[i].used && strcmp(files[i].name, d.name) == 0)
			error(Eexist);
	nf = nil;
	for(i = 0; i < Nlfs; i++)
		if(!files[i].used){
			nf = &files[i];
			break;
		}
	if(nf == nil)
		error("lfs: no room for another file");

	buf = smalloc(Lmaxdata);
	if(waserror()){
		free(buf);
		nexterror();
	}
	lfsload(f, buf);
	len = f->len;
	was = f->vers;
	memset(nf, 0, sizeof *nf);
	nf->used = 1;
	strcpy(nf->name, d.name);
	lfsput(nf, buf, len, 1, 0);
	poperror();
	free(buf);

	lfsput(f, nil, 0, f->vers + 1, 1);
	print("lfs: renamed %s to %s after version %d: %lud bytes carried over, "
		"a tombstone at sector %llud, %llud sectors free\n",
		f->name, nf->name, was, len, f->lba, lfsfree());
	f->used = 0;
	return n;
}

Dev lfsdevtab = {
	'l',
	"lfs",

	devreset,
	devinit,
	devshutdown,
	lfsattach,
	lfswalk,
	lfsstat,
	lfsopen,
	lfscreate,
	lfsclose,
	lfsread,
	devbread,
	lfswrite,
	devbwrite,
	lfsremove,
	lfswstat,
};
