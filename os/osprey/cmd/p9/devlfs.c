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
		if(f == nil)
			f = lfsnew(r.name);
		f->lba = pos;
		f->len = r.len;
		f->vers = r.vers;
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
lfsput(Lfile *f, uchar *buf, ulong len, ulong vers)
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
	lfsput(f, buf, len, f->vers + 1);
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
		lfsput(f, movebuf, r.len, r.vers);
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
 * than half full, up to eight a tick, so that the task's reservation is
 * what pays for reclamation and a writer only pays when the log has
 * filled between two ticks.  One step a tick was enough while a client's
 * every request waited two milliseconds in its yield; a client answered
 * in a hundred microseconds writes faster than that, and made writers
 * pay.
 */
int
lfsreclaim(void)
{
	int n;

	if(!scanned)
		return 0;
	for(n = 0; n < 8 && lfsreclaimstep(0); n++)
		;
	return n > 0;
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
	if(o->dirty && !waserror()){
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

static void
lfsremove(Chan*)
{
	error(Eperm);			/* versions are immutable; a tombstone is not written yet */
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
	devwstat,
};
