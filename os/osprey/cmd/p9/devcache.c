#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

/*
 * A caching file system, the talk's slide 23, as a device in this
 * personality's name space: #K, bound over /n, so that an open of
 * /n/hello here is answered from a copy of the server's file held in
 * this container, and kept current by the wire.  It is the replica of
 * p9ip.c generalised: an entry per name, fetched over the pi-p wire on
 * the first open (a session, a fid, its data and its committed version,
 * in one group), and thereafter a stream of the file's committed
 * version - "latest", every 100 ms, unasked - which a reader kproc takes
 * off the wire and notes against the entry.  An open finds the entry
 * current (the stream still says the version it holds) and answers from
 * the copy with nothing asked of the server, or stale, and refetches -
 * a new fid, since a fid's data is a snapshot, the old one closed and
 * the stream moved to the new.  Reads are of the copy.  The name space
 * above sees an ordinary directory of the names cached so far.
 *
 * The wire is one connection to the server's pi-p (pipwire in p9ip.c);
 * a group's replies come as one record and a stream's frames as
 * another, told apart by tag: a stream's tag is Streamtag plus the
 * entry's index, a group's tags are small.  One fetch at a time: the
 * opener puts the group and sleeps until the reader has the record.
 * What this is not: the copies are in this program's memory and go
 * with it, and writes are not taken - a write goes by another path
 * (9P over the ring) and the stream is how the cache learns of it.
 */
enum {
	Ncache	= 8,
	Cnamelen = 64,
	Cdatalen = 4096,
	Streamtag = 1000,
	Qroot	= 0,
	PipRsession = 101, PipRread = 105, PipRclose = 109, PipRerror = 112,
};

typedef struct Centry Centry;
struct Centry {
	int	used;
	char	name[Cnamelen];
	uchar	*data;			/* the copy, or nil before the first fetch */
	long	len;
	uvlong	vers;			/* the version the copy is of */
	uvlong	latest;			/* what the stream last said the committed version is */
	ulong	fid;			/* the fid on the server the stream is on */
	uchar	*draft;			/* what is being written through, until the close commits it */
	long	draftlen;
	int	dirty;
	int	nopen;			/* chans open on it: not evicted while any */
	uvlong	lastuse;		/* ms; the least recently used goes first */
	uvlong	lastframe;		/* ms; when the stream last spoke - silent past the lease, the entry is dropped */
	int	hits, misses, refetches;
};

static Centry cache[Ncache];
enum { Leasems = 3000 };	/* the server's fid lease: a stream silent that long has stopped */
static int evictions, writethroughs;

static uvlong
cnow(void)
{
	return TK2MS(MACHP(0)->ticks);
}
static int wfd = -1, dfd = -1;		/* the wire: data and ctl */
static uvlong sid;
static ulong nextfid = 1;
static int nexttag = 1;
static Rendez replyr;
static uchar replybuf[4096];
static long replyn;			/* a group's replies, when the reader has them */
static long frames;			/* stream frames taken off the wire */

extern int pipwire_connect(int*);			/* p9ip.c: a connection to the server's pi-p */
extern void pipwire_put(int, uchar*, long);
extern long pipwire_get(int, uchar*, long);
extern long pip_tsession(uchar*, int, uvlong);
extern long pip_topen(uchar*, int, ulong, ulong, int, char*);
extern long pip_tread(uchar*, int, ulong, long, char*);
extern long pip_tstream(uchar*, int, ulong, ulong, ulong, char*);
extern long pip_tclose(uchar*, int, ulong);
extern long pip_twrite(uchar*, int, ulong, char*, char*, long);
extern int pip_next(uchar*, long, long*, int*, int*, uchar**, long*);
extern uvlong pip_num(uchar*, int);

static int
replyready(void*)
{
	return replyn > 0;
}

/*
 * The reader: every record off the wire is a stream's frames or a
 * group's replies.  Frames go to their entries; replies go to whoever
 * is waiting for them.
 */
static void
cachestream(void*)
{
	uchar rg[4096], *body;
	long rn, off, blen;
	int type, tag, i;
	char show[32];

	for(;;){
		rn = pipwire_get(wfd, rg, sizeof rg);
		if(rn <= 0)
			break;
		off = 0;
		if(!pip_next(rg, rn, &off, &type, &tag, &body, &blen))
			continue;
		if(tag >= Streamtag){
			off = 0;
			while(pip_next(rg, rn, &off, &type, &tag, &body, &blen)){
				i = tag - Streamtag;
				if(type != PipRread || i < 0 || i >= Ncache || !cache[i].used)
					continue;
				frames++;
				snprint(show, sizeof show, "%.*s", (int)pip_num(body+8, 2), (char*)body+10);
				cache[i].latest = strtoull(show, nil, 10);
				cache[i].lastframe = cnow();
			}
			continue;
		}
		if(rn > (long)sizeof replybuf)
			rn = sizeof replybuf;
		memmove(replybuf, rg, rn);
		replyn = rn;
		wakeup(&replyr);
	}
	print("cache: the wire closed; %ld frames had come\n", frames);
	wfd = -1;
	pexit("cachestream", 0);
}

/* put a group, wait for its replies; they are in replybuf[0..replyn) */
static void
exchange(uchar *tg, long tn)
{
	replyn = 0;
	pipwire_put(wfd, tg, tn);
	sleep(&replyr, replyready, nil);
}

static void
cachewire(void)
{
	uchar tg[512], rg[512], *body;	/* a session and a ticket: sixty-four bytes held a session alone */
	long tn, rn, off, blen;
	int type, tag;

	if(wfd >= 0)
		return;
	wfd = pipwire_connect(&dfd);
	tn = pip_tsession(tg, nexttag++, 0);
	{
		extern char *pip_ticket(void);
		extern long pip_tauth(uchar*, int, char*);
		char *tk = pip_ticket();

		if(tk != nil)
			tn += pip_tauth(tg+tn, nexttag++, tk);	/* who I am: the files the cache holds are the personality's */
	}
	pipwire_put(wfd, tg, tn);
	rn = pipwire_get(wfd, rg, sizeof rg);	/* before the reader exists: read it here */
	for(off = 0; rn > 0 && pip_next(rg, rn, &off, &type, &tag, &body, &blen); )
		if(type == PipRsession)
			sid = pip_num(body, 8);
	if(sid == 0)
		error("no session on the wire");
	kproc("cachestream", cachestream, nil);
	print("cache: a session on the pi-p wire to the server, %llux; a reader takes the streams off it\n", sid);
}

/*
 * Fetch an entry: a new fid on the server's file, its data and its
 * committed version, the old fid closed, and the stream on the new fid.
 */
static void
cachefetch(Centry *e)
{
	uchar tg[512], *body;
	long tn, off, blen;
	int type, tag, t1, t2, t3, t4;
	ulong fid;
	char path[Cnamelen + 4], show[32];

	cachewire();
	fid = nextfid++;
	snprint(path, sizeof path, "/n/%s", e->name);
	tn = 0;
	tn += pip_tsession(tg+tn, t1 = nexttag++, sid);
	tn += pip_topen(tg+tn, t2 = nexttag++, 0, fid, 0, path);
	tn += pip_tread(tg+tn, t3 = nexttag++, fid, Cdatalen, "data");
	tn += pip_tread(tg+tn, t4 = nexttag++, fid, 32, "latest");
	if(e->fid != 0)
		tn += pip_tclose(tg+tn, nexttag++, e->fid);
	tn += pip_tstream(tg+tn, Streamtag + (e - cache), fid, 100, 0, "latest");
	if(nexttag >= Streamtag - 8)
		nexttag = 1;
	exchange(tg, tn);
	if(e->data == nil)
		e->data = smalloc(Cdatalen);
	for(off = 0; pip_next(replybuf, replyn, &off, &type, &tag, &body, &blen); ){
		if(type == PipRerror && tag == t2){
			snprint(show, sizeof show, "%.*s", (int)pip_num(body, 2), (char*)body+2);
			error(show);
		}
		if(type == PipRread && tag == t3){
			e->len = pip_num(body+8, 2);
			if(e->len > Cdatalen)
				e->len = Cdatalen;
			memmove(e->data, body+10, e->len);
		} else if(type == PipRread && tag == t4){
			snprint(show, sizeof show, "%.*s", (int)pip_num(body+8, 2), (char*)body+10);
			e->vers = e->latest = strtoull(show, nil, 10);
		}
	}
	e->fid = fid;
	e->lastframe = cnow();
}

/* what an entry holds on the server, let go: its fid closed on the wire, which stops its stream there */
static void
cachedrop(Centry *e)
{
	uchar tg[256];
	long tn;

	if(e->fid != 0 && wfd >= 0){
		tn = 0;
		tn += pip_tsession(tg+tn, nexttag++, sid);
		tn += pip_tclose(tg+tn, nexttag++, e->fid);
		if(nexttag >= Streamtag - 8)
			nexttag = 1;
		if(!waserror()){
			exchange(tg, tn);
			poperror();
		}
	}
	e->fid = 0;
	free(e->data);
	e->data = nil;
	free(e->draft);
	e->draft = nil;
	e->len = e->draftlen = 0;
	e->dirty = 0;
}

/*
 * A write through the cache: the draft goes to the server as a pi-p
 * write and close on a fid of its own, which commits it as a version
 * on the log; the copy becomes the draft, at the version the server
 * says, and the entry's stream will say the same.
 */
static void
cachecommit(Centry *e)
{
	uchar *tg, *body;		/* off the stack: a page-and-a-half frame, deep under namec, overflowed a kproc's 32 KB */
	long tn, off, blen;
	int type, tag, t4;
	ulong fid;
	uvlong v;
	char path[Cnamelen + 4], show[64];

	cachewire();
	tg = smalloc(Cdatalen + 512);
	if(waserror()){
		free(tg);
		nexterror();
	}
	fid = nextfid++;
	snprint(path, sizeof path, "/n/%s", e->name);
	tn = 0;
	tn += pip_tsession(tg+tn, nexttag++, sid);
	tn += pip_topen(tg+tn, nexttag++, 0, fid, 0, path);
	tn += pip_twrite(tg+tn, nexttag++, fid, "data", (char*)e->draft, e->draftlen);
	tn += pip_tclose(tg+tn, t4 = nexttag++, fid);
	if(nexttag >= Streamtag - 8)
		nexttag = 1;
	exchange(tg, tn);
	v = 0;
	for(off = 0; pip_next(replybuf, replyn, &off, &type, &tag, &body, &blen); ){
		if(type == PipRerror){
			snprint(show, sizeof show, "%.*s", (int)pip_num(body, 2), (char*)body+2);
			error(show);
		}
		if(type == PipRclose && tag == t4)
			v = pip_num(body, 8);
	}
	if(e->data == nil)
		e->data = smalloc(Cdatalen);
	memmove(e->data, e->draft, e->draftlen);
	e->len = e->draftlen;
	e->vers = e->latest = v;
	e->dirty = 0;
	writethroughs++;
	print("cache: /n/%s: written through - a pi-p write and close on the wire committed version %llud on the server\n", e->name, v);
	poperror();
	free(tg);
}

static Centry*
cachelookup(char *name)
{
	Centry *e;

	for(e = cache; e < &cache[Ncache]; e++)
		if(e->used && strcmp(e->name, name) == 0)
			return e;
	return nil;
}

/* a name walked to is an entry, fetched at its first open */
static Centry*
cachenew(char *name)
{
	Centry *e;

	if(strlen(name) >= Cnamelen)
		error(Ebadarg);
	for(e = cache; e < &cache[Ncache]; e++)
		if(!e->used){
			memset(e, 0, sizeof *e);
			e->used = 1;
			strcpy(e->name, name);
			return e;
		}
	/*
	 * Full: the entry least recently used, with no chan open on it and
	 * nothing being written through, is let go - its fid closed on the
	 * wire, its stream stopped - and the slot is this name's.
	 */
	{
		Centry *lru = nil;

		for(e = cache; e < &cache[Ncache]; e++)
			if(e->nopen == 0 && !e->dirty && (lru == nil || e->lastuse < lru->lastuse))
				lru = e;
		if(lru == nil)
			error("the cache is full, every entry open");
		print("cache: /n/%s evicted for /n/%s, the least recently used: its fid closed on the wire, its stream stopped\n", lru->name, name);
		cachedrop(lru);
		evictions++;
		memset(lru, 0, sizeof *lru);
		lru->used = 1;
		strcpy(lru->name, name);
		return lru;
	}
}

static int
cachegen(Chan *c, char *name, Dirtab*, int, int s, Dir *dp)
{
	Centry *e;
	Qid q;

	if(s == DEVDOTDOT){
		mkqid(&q, Qroot, 0, QTDIR);
		devdir(c, q, "#K", 0, eve, 0775, dp);
		return 1;
	}
	if((c->qid.type & QTDIR) == 0){
		if(c->qid.path < 1 || c->qid.path > Ncache)
			return -1;
		e = &cache[c->qid.path - 1];
		if(!e->used)
			return -1;
	} else if(name != nil){
		if((e = cachelookup(name)) == nil)
			e = cachenew(name);
	} else {
		/*
		 * The directory lists what the cache holds: an entry per file
		 * it has a copy of, its version and length as the cache knows
		 * them.  A cache is a window on the store, and its directory
		 * is that window, not the whole of the store.
		 */
		int j, seen;

		seen = 0;
		e = nil;
		for(j = 0; j < Ncache; j++)
			if(cache[j].used && cache[j].data != nil){
				if(seen++ == s){
					e = &cache[j];
					break;
				}
			}
		if(e == nil)
			return -1;
	}
	mkqid(&q, (e - cache) + 1, e->vers, QTFILE);
	devdir(c, q, e->name, e->len, eve, 0666, dp);
	return 1;
}

static Chan*
cacheattach(char *spec)
{
	Chan *c;

	c = devattach('K', spec);
	mkqid(&c->qid, Qroot, 0, QTDIR);
	return c;
}

static Walkqid*
cachewalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, cachegen);
}

static int
cachestat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, nil, 0, cachegen);
}

static Chan*
cacheopen(Chan *c, int omode)
{
	Centry *e;
	int writing;

	if((c->qid.type & QTDIR) != 0 && omode != OREAD)
		error(Eperm);
	if((c->qid.type & QTDIR) == 0){
		if(c->qid.path < 1 || c->qid.path > Ncache || !cache[c->qid.path-1].used)
			error(Enonexist);
		e = &cache[c->qid.path-1];
		writing = (omode & 3) == OWRITE || (omode & 3) == ORDWR;
		if(e->data != nil && e->fid != 0 && cnow() - e->lastframe > Leasems){
			print("cache: /n/%s: its stream has been silent %llud ms, past the lease: the entry is dropped and fetched afresh\n", e->name, cnow() - e->lastframe);
			cachedrop(e);
		}
		if(e->data == nil){
			e->misses++;
			if(waserror()){
				if(e->nopen == 0){
					cachedrop(e);
					e->used = 0;	/* nothing on the server by that name: no entry either */
				}
				nexterror();
			}
			cachefetch(e);
			poperror();
			print("cache: /n/%s: not held; fetched version %llud over the wire, and its committed version now streams\n", e->name, e->vers);
		} else if(e->latest != e->vers){
			uvlong said = e->latest, had = e->vers;

			e->refetches++;
			cachefetch(e);
			print("cache: /n/%s: the stream said version %llud, the copy is %llud: refetched over the wire - version %llud now\n", e->name, said, had, e->vers);
		} else {
			e->hits++;
			print("cache: /n/%s: answered from the copy, version %llud, nothing asked of the server\n", e->name, e->vers);
		}
		c->qid.vers = e->vers;
		if(writing){
			if(e->draft == nil)
				e->draft = smalloc(Cdatalen);
			if(omode & OTRUNC)
				e->draftlen = 0;
			else {
				memmove(e->draft, e->data, e->len);
				e->draftlen = e->len;
			}
		}
		e->nopen++;
		e->lastuse = cnow();
	}
	c->mode = openmode(omode);
	c->offset = 0;
	c->flag |= COPEN;
	return c;
}

static void
cacheclose(Chan *c)
{
	Centry *e;

	if((c->qid.type & QTDIR) != 0 || (c->flag & COPEN) == 0)
		return;
	if(c->qid.path < 1 || c->qid.path > Ncache || !cache[c->qid.path-1].used)
		return;
	e = &cache[c->qid.path-1];
	if(e->nopen > 0)
		e->nopen--;
	if((c->mode == OWRITE || c->mode == ORDWR) && e->dirty)
		cachecommit(e);		/* the close commits, as a pi-p close does */
}

static long
cacheread(Chan *c, void *a, long n, vlong off)
{
	Centry *e;

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, nil, 0, cachegen);
	e = &cache[c->qid.path - 1];
	if(e->data == nil || off >= e->len)
		return 0;
	if(n > e->len - off)
		n = e->len - off;
	memmove(a, e->data + off, n);
	return n;
}

static long
cachewrite(Chan *c, void *a, long n, vlong off)
{
	Centry *e;

	if(c->qid.type & QTDIR)
		error(Eperm);
	if(c->qid.path < 1 || c->qid.path > Ncache || !cache[c->qid.path-1].used)
		error(Enonexist);
	e = &cache[c->qid.path-1];
	if(e->draft == nil)
		error(Eperm);
	if(off < 0 || off + n > Cdatalen)
		error("the cache holds a file of a page");
	memmove(e->draft + off, a, n);
	if(off + n > e->draftlen)
		e->draftlen = off + n;
	e->dirty = 1;
	return n;
}

/* every held entry let go: its fid closed on the wire, its stream stopped on the server - so the test leaves no streams firing behind it */
void
cachestopall(void)
{
	Centry *e;

	for(e = cache; e < &cache[Ncache]; e++)
		if(e->used){
			if(e->nopen == 0 && !e->dirty)
				cachedrop(e);
			memset(e, 0, sizeof *e);
		}
}

/* what the cache has done beyond the reads, for the test's summary */
void
cachestats2(int *nevict, int *nwrite)
{
	*nevict = evictions;
	*nwrite = writethroughs;
}

/* what the cache has done, for the test's summary */
void
cachestats(int *hits, int *misses, int *refetches, long *nframes)
{
	Centry *e;

	*hits = *misses = *refetches = 0;
	for(e = cache; e < &cache[Ncache]; e++)
		if(e->used){
			*hits += e->hits;
			*misses += e->misses;
			*refetches += e->refetches;
		}
	*nframes = frames;
}

Dev cachedevtab = {
	'K',
	"cache",

	devreset,
	devinit,
	devshutdown,
	cacheattach,
	cachewalk,
	cachestat,
	cacheopen,
	devcreate,
	cacheclose,
	cacheread,
	devbread,
	cachewrite,
	devbwrite,
	devremove,
	devwstat,
};
