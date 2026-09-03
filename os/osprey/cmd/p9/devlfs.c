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
 * The device is #l.  Sector 0 is left for a checkpoint of the scan and
 * is not used; the log begins at sector 1.  The block driver
 * (blkvirtio.c) is reached through three plain-typed functions.
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

static Lfile files[Nlfs];
static uvlong head;			/* the next free sector */
static uvlong seq;
static int scanned;
static uchar sector[Lsector];

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

/* mount: read the log from its first sector to its end, latest version of each file */
static void
lfsscan(void)
{
	Lrec *r;
	Lfile *f;
	uvlong cap;
	int n;

	cap = blkcapacity();
	head = Lfirst;
	seq = 0;
	n = 0;
	for(;;){
		if(head >= cap || blkxfer(0, head, sector) < 0)
			break;
		r = (Lrec*)sector;
		if(r->magic != Lmagic || r->len > Lmaxdata)
			break;
		r->name[Lnamelen-1] = 0;
		f = lfslookup(r->name);
		if(f == nil)
			f = lfsnew(r->name);
		f->lba = head;
		f->len = r->len;
		f->vers = r->vers;
		seq = r->seq;
		n++;
		head += 1 + (r->len + Lsector-1)/Lsector;
	}
	scanned = 1;
	print("lfs: mounted the log: %d records in sectors %d-%llud of %llud\n", n, Lfirst, head-1, cap);
	for(f = files; f < &files[Nlfs]; f++)
		if(f->used)
			print("lfs: %s version %lud, %lud bytes, at sector %llud\n", f->name, f->vers, f->len, f->lba);
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

/* a new version: the header sector, then the data, appended at the head of the log */
static void
lfsappend(Lfile *f, uchar *buf, ulong len)
{
	Lrec *r;
	uvlong lba;
	ulong off, cnt;

	lba = head;
	if(lba + 1 + (len + Lsector-1)/Lsector > blkcapacity())
		error("the log is full");
	memset(sector, 0, Lsector);
	r = (Lrec*)sector;
	r->magic = Lmagic;
	r->seq = ++seq;
	r->vers = f->vers + 1;
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
	f->vers++;
	head = lba + 1 + (len + Lsector-1)/Lsector;
	print("lfs: committed %s version %lud, %lud bytes, at sector %llud\n", f->name, f->vers, f->len, f->lba);
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
