#include	"dat.h"
#include	"fns.h"
#include	"error.h"

/*
 * References are managed as follows:
 * The channel to the server - a network connection or pipe - has one
 * reference for every Chan open on the server.  The server channel has
 * c->mux set to the Mnt used for muxing control to that server.  Mnts
 * have no reference count; they go away when c goes away.
 * Each channel derived from the mount point has mchan set to c,
 * and increfs/decrefs mchan to manage references on the server
 * connection.
 */

#define MAXRPC (IOHDRSZ+8192)

struct Mntrpc
{
	Chan*	c;		/* Channel for whom we are working */
	Mntrpc*	list;		/* Free/pending list */
	Fcall	request;	/* Outgoing file system protocol message */
	Fcall 	reply;		/* Incoming reply */
	Mnt*	m;		/* Mount device during rpc */
	Rendez	r;		/* Place to hang out */
	uchar*	rpc;		/* I/O Data buffer */
	uint		rpclen;	/* len of buffer */
	Block	*b;		/* reply blocks */
	char	done;		/* Rpc completed */
	uvlong	stime;		/* start time for mnt statistics */
	ulong	reqlen;		/* request length for mnt statistics */
	ulong	replen;		/* reply length for mnt statistics */
	Mntrpc*	flushed;	/* message this one flushes */
};

enum
{
	TAGSHIFT = 5,			/* ulong has to be 32 bits */
	TAGMASK = (1<<TAGSHIFT)-1,
	NMASK = (64*1024)>>TAGSHIFT,
};

int mntdebug = 0;

struct Mntalloc
{
	Lock	l;
	Mnt*	list;		/* Mount devices in use */
	Mnt*	mntfree;	/* Free list */
	Mntrpc*	rpcfree;
	int	nrpcfree;
	int	nrpcused;
	ulong	id;
	ulong	tagmask[NMASK];
}mntalloc;

void	mattach(Mnt*, Chan*, char*);
Mnt*	mntchk(Chan*);
void	mntdirfix(uchar*, Chan*);
Mntrpc*	mntflushalloc(Mntrpc*, ulong);
void	mntflushfree(Mnt*, Mntrpc*);
void	mntfree(Mntrpc*);
void	mntgate(Mnt*);
static void	mntwatchstart(void);
void	mntpntfree(Mnt*);
void	mntqrm(Mnt*, Mntrpc*);
Mntrpc*	mntralloc(Chan*, ulong);
long	mntrdwr(int, Chan*, void*, long, vlong);
int	mntrpcread(Mnt*, Mntrpc*);
void	mountio(Mnt*, Mntrpc*);
void	mountmux(Mnt*, Mntrpc*);
void	mountrpc(Mnt*, Mntrpc*);
int	rpcattn(void*);
Chan*	mntchan(void);

char	Esbadstat[] = "invalid directory entry received from server";
char Enoversion[] = "version not established for mount channel";


void (*mntstats)(int, Chan*, uvlong, ulong);

/*
 * Say when a mount's multiplexer has stopped, and say it in terms of
 * the mux's own state rather than a stack.
 *
 * Every rpc on a mount queues on m->queue and exactly one proc at a
 * time -- m->rip -- reads replies off the wire and hands them out.
 * When that arrangement breaks, every proc using the mount sleeps and
 * from outside the emu it looks like a server that has stopped
 * answering: connections accepted, their first message unread, nothing
 * burning CPU.  That is precisely the picture a wedged styxlisten
 * gives, and a sampling profile of it says only "everything is in
 * osblock", which is true of a healthy idle server too.
 *
 * So ask the mux.  Every two seconds, for each mount with something
 * queued, note the queue.  If the same rpcs are still queued, none of
 * them done, and the reader has not changed for three scans running,
 * the mux is not slow, it is stopped -- print who is reading, or that
 * nobody is, and every tag that is waiting.
 *
 * Costs one wakeup every two seconds and a short walk under the lock,
 * unlike INFERNO_MNTDEBUG which prints two lines per Styx message and
 * makes the server about thirty times slower -- slow enough to look
 * like the fault it is meant to find.
 */
int mntwatch = 0;

typedef struct Mntseen Mntseen;
struct Mntseen
{
	ulong	id;		/* which mount */
	ulong	sig;		/* the queue, as a hash of its tags */
	int	ripid;		/* who was reading it */
	int	n;		/* how many scans it has looked like this */
};

static void
mntwatcher(void *a)
{
	static Mntseen seen[32];
	Mnt *mv[nelem(seen)], *m;
	Mntseen *s;
	Mntrpc *r;
	int i, j, nm, nq, ndone, ripid;
	ulong sig;
	Proc *rip;

	USED(a);
	for(;;){
		osmillisleep(2000);
		/*
		 * Snapshot the mounts under mntalloc.l and let it go before
		 * touching m->l, so the two locks are never held at once and
		 * this can never be the thing that deadlocks.
		 */
		lock(&mntalloc.l);
		nm = 0;
		for(m = mntalloc.list; m != nil && nm < nelem(mv); m = m->list)
			mv[nm++] = m;
		unlock(&mntalloc.l);

		/*
		 * A tick, every scan, even when there is nothing wrong.
		 *
		 * Without it this watchdog prints only on the fault, so its
		 * silence means either "the mux is fine" or "the watcher never
		 * started" -- and those were indistinguishable for a whole
		 * round of measurements, during which its silence was written
		 * down as evidence that the mux was healthy.  An instrument
		 * that cannot say "I am here and I see nothing" is not an
		 * instrument.
		 */
		print("mntwatch: %d mounts\n", nm);

		for(i = 0; i < nm; i++){
			m = mv[i];
			lock(&m->l);
			nq = ndone = 0;
			sig = 0;
			for(r = m->queue; r != nil; r = r->list){
				nq++;
				if(r->done)
					ndone++;
				sig = sig*31 + r->request.tag;
			}
			rip = m->rip;
			ripid = rip != nil? rip->pid: -1;

			/* find this mount's row, or take a free one */
			s = nil;
			for(j = 0; j < nelem(seen); j++)
				if(seen[j].id == m->id){
					s = &seen[j];
					break;
				}
			if(s == nil)
				for(j = 0; j < nelem(seen); j++)
					if(seen[j].id == 0){
						s = &seen[j];
						s->id = m->id;
						s->sig = ~sig;
						s->n = 0;
						break;
					}
			if(s == nil){		/* no room; nothing to say */
				unlock(&m->l);
				continue;
			}
			/*
			 * Anything moving at all resets the count: a queue
			 * that empties, a different set of tags, a reply that
			 * lands, or the reader changing hands.  Only a mux
			 * that is bit for bit the same three scans running is
			 * reported, so a merely busy server is never accused.
			 */
			if(nq == 0 || ndone != 0 || sig != s->sig || ripid != s->ripid){
				s->sig = sig;
				s->ripid = ripid;
				s->n = nq == 0? 0: 1;
				unlock(&m->l);
				continue;
			}
			if(++s->n != 3){	/* report once, not every scan */
				unlock(&m->l);
				continue;
			}
			print("mntwatch: mount %lud MUX STOPPED: %d rpcs queued, "
				"none done, unchanged for 3 scans\n", m->id, nq);
			if(rip != nil)
				print("mntwatch:    reader is %s pid %d\n",
					rip->text, rip->pid);
			else
				print("mntwatch:    NOBODY is reading this mount\n");
			for(r = m->queue; r != nil; r = r->list)
				print("mntwatch:    waiting: tag %d T%d fid %d done %d\n",
					r->request.tag, r->request.type,
					r->request.fid, r->done);
			unlock(&m->l);
		}
	}
}

/*
 * Start the watcher on the first mount, once.
 *
 * mntinit cannot do it: it runs from chandevinit, before there is a
 * scheduler to run a kproc on.
 */
static void
mntwatchstart(void)
{
	static int started;

	if(!mntwatch)
		return;
	lock(&mntalloc.l);
	if(started){
		unlock(&mntalloc.l);
		return;
	}
	started = 1;
	unlock(&mntalloc.l);
	kproc("mntwatch", mntwatcher, nil, 0);
}

static void
mntinit(void)
{
	mntalloc.id = 1;
	if(getenv("INFERNO_MNTDEBUG") != nil)
		mntdebug = 1;
	if(getenv("INFERNO_MNTWATCH") != nil)
		mntwatch = 1;
	/*
	 * The watcher is NOT started here.  mntinit runs from
	 * chandevinit, before the first kproc, so it starts on the first
	 * mount instead -- see mntwatchstart.
	 */
	mntalloc.tagmask[0] = 1;			/* don't allow 0 as a tag */
	mntalloc.tagmask[NMASK-1] = 0x80000000UL;	/* don't allow NOTAG */
	fmtinstall('F', fcallfmt);
/*	fmtinstall('D', dirfmt); */
/*	fmtinstall('M', dirmodefmt);  */

	cinit();
}

/*
 * Version is not multiplexed: message sent only once per connection.
 */
long
mntversion(Chan *c, char *version, int msize, int returnlen)
{
	Fcall f;
	uchar *msg;
	Mnt *m;
	char *v;
	long k, l;
	uvlong oo;
	char buf[128];

	qlock(&c->umqlock);	/* make sure no one else does this until we've established ourselves */
	if(waserror()){
		qunlock(&c->umqlock);
		nexterror();
	}

	/* defaults */
	if(msize == 0)
		msize = MAXRPC;
	if(msize > c->iounit && c->iounit != 0)
		msize = c->iounit;
	v = version;
	if(v == nil || v[0] == '\0')
		v = VERSION9P;

	/* validity */
	if(msize < 0)
		error("bad iounit in version call");
	if(strncmp(v, VERSION9P, strlen(VERSION9P)) != 0)
		error("bad 9P version specification");

	m = c->mux;

	if(m != nil){
		qunlock(&c->umqlock);
		poperror();

		strecpy(buf, buf+sizeof buf, m->version);
		k = strlen(buf);
		if(strncmp(buf, v, k) != 0){
			snprint(buf, sizeof buf, "incompatible 9P versions %s %s", m->version, v);
			error(buf);
		}
		if(returnlen > 0){
			if(returnlen < k)
				error(Eshort);
			memmove(version, buf, k);
		}
		return k;
	}

	f.type = Tversion;
	f.tag = NOTAG;
	f.msize = msize;
	f.version = v;
	msg = malloc(8192+IOHDRSZ);
	if(msg == nil)
		exhausted("version memory");
	if(waserror()){
		free(msg);
		nexterror();
	}
	k = convS2M(&f, msg, 8192+IOHDRSZ);
	if(k == 0)
		error("bad fversion conversion on send");

	lock(&c->l);
	oo = c->offset;
	c->offset += k;
	unlock(&c->l);

	l = devtab[c->type]->write(c, msg, k, oo);

	if(l < k){
		lock(&c->l);
		c->offset -= k - l;
		unlock(&c->l);
		error("short write in fversion");
	}

	/* message sent; receive and decode reply */
	k = devtab[c->type]->read(c, msg, 8192+IOHDRSZ, c->offset);
	if(k <= 0)
		error("EOF receiving fversion reply");

	lock(&c->l);
	c->offset += k;
	unlock(&c->l);

	l = convM2S(msg, k, &f);
	if(l != k)
		error("bad fversion conversion on reply");
	if(f.type != Rversion){
		if(f.type == Rerror)
			error(f.ename);
		error("unexpected reply type in fversion");
	}
	if(f.msize > msize)
		error("server tries to increase msize in fversion");
	if(f.msize<256 || f.msize>1024*1024)
		error("nonsense value of msize in fversion");
	if(strncmp(f.version, v, strlen(f.version)) != 0)
		error("bad 9P version returned from server");

	/* now build Mnt associated with this connection */
	lock(&mntalloc.l);
	m = mntalloc.mntfree;
	if(m != 0)
		mntalloc.mntfree = m->list;
	else {
		m = malloc(sizeof(Mnt));
		if(m == 0) {
			unlock(&mntalloc.l);
			exhausted("mount devices");
		}
	}
	m->list = mntalloc.list;
	mntalloc.list = m;
	m->version = nil;
	kstrdup(&m->version, f.version);
	m->id = mntalloc.id++;
	m->q = qopen(10*MAXRPC, 0, nil, nil);
	m->msize = f.msize;
	unlock(&mntalloc.l);

	poperror();	/* msg */
	free(msg);

	lock(&m->l);
	m->queue = 0;
	m->rip = 0;

	c->flag |= CMSG;
	c->mux = m;
	m->c = c;
	unlock(&m->l);

	poperror();	/* c */
	qunlock(&c->umqlock);

	k = strlen(f.version);
	if(returnlen > 0){
		if(returnlen < k)
			error(Eshort);
		memmove(version, f.version, k);
	}

	return k;
}

Chan*
mntauth(Chan *c, char *spec)
{
	Mnt *m;
	Mntrpc *r;

	m = c->mux;

	if(m == nil){
		mntversion(c, VERSION9P, MAXRPC, 0);
		m = c->mux;
		if(m == nil)
			error(Enoversion);
	}

	c = mntchan();
	if(waserror()) {
		/* Close must not be called since it will
		 * call mnt recursively
		 */
		chanfree(c);
		nexterror();
	}

	r = mntralloc(0, m->msize);

	if(waserror()) {
		mntfree(r);
		nexterror();
	}

	r->request.type = Tauth;
	r->request.afid = c->fid;
	r->request.uname = up->env->user;
	r->request.aname = spec;
	mountrpc(m, r);

	c->qid = r->reply.aqid;
	c->mchan = m->c;
	incref(&m->c->r);
	c->mqid = c->qid;
	c->mode = ORDWR;

	poperror();	/* r */
	mntfree(r);

	poperror();	/* c */

	return c;

}

static Chan*
mntattach(char *muxattach)
{
	Mnt *m;
	Chan *c;
	Mntrpc *r;
	struct bogus{
		Chan	*chan;
		Chan	*authchan;
		char	*spec;
		int	flags;
	}bogus;

	mntwatchstart();

	bogus = *((struct bogus *)muxattach);
	c = bogus.chan;

	m = c->mux;

	if(m == nil){
		mntversion(c, nil, 0, 0);
		m = c->mux;
		if(m == nil)
			error(Enoversion);
	}

	c = mntchan();
	if(waserror()) {
		/* Close must not be called since it will
		 * call mnt recursively
		 */
		chanfree(c);
		nexterror();
	}

	r = mntralloc(0, m->msize);

	if(waserror()) {
		mntfree(r);
		nexterror();
	}

	r->request.type = Tattach;
	r->request.fid = c->fid;
	if(bogus.authchan == nil)
		r->request.afid = NOFID;
	else
		r->request.afid = bogus.authchan->fid;
	r->request.uname = up->env->user;
	r->request.aname = bogus.spec;
	mountrpc(m, r);

	c->qid = r->reply.qid;
	c->mchan = m->c;
	incref(&m->c->r);
	c->mqid = c->qid;

	poperror();	/* r */
	mntfree(r);

	poperror();	/* c */

	if(bogus.flags&MCACHE)
		c->flag |= CCACHE;
	return c;
}

Chan*
mntchan(void)
{
	Chan *c;

	c = devattach('M', 0);
	lock(&mntalloc.l);
	c->dev = mntalloc.id++;
	unlock(&mntalloc.l);

	if(c->mchan)
		panic("mntchan non-zero %p", c->mchan);
	return c;
}

static Walkqid*
mntwalk(Chan *c, Chan *nc, char **name, int nname)
{
	volatile int alloc;
	int i;
	Mnt *m;
	Mntrpc *r;
	Walkqid *wq;

	if(nc != nil)
		print("mntwalk: nc != nil\n");
	if(nname > MAXWELEM)
		error("devmnt: too many name elements");
	alloc = 0;
	wq = smalloc(sizeof(Walkqid)+(nname-1)*sizeof(Qid));
	if(waserror()){
		if(alloc && wq->clone!=nil)
			cclose(wq->clone);
		free(wq);
		return nil;
	}

	alloc = 0;
	m = mntchk(c);
	r = mntralloc(c, m->msize);
	if(nc == nil){
		nc = devclone(c);
		/*
		 * Until the other side accepts this fid, we can't mntclose it.
		 * Therefore set type to 0 for now; rootclose is known to be safe.
		 */
		nc->type = 0;
		alloc = 1;
	}
	wq->clone = nc;

	if(waserror()) {
		mntfree(r);
		nexterror();
	}
	r->request.type = Twalk;
	r->request.fid = c->fid;
	r->request.newfid = nc->fid;
	r->request.nwname = nname;
	memmove(r->request.wname, name, nname*sizeof(char*));

	mountrpc(m, r);

	if(r->reply.nwqid > nname)
		error("too many QIDs returned by walk");
	if(r->reply.nwqid < nname){
		if(alloc)
			cclose(nc);
		wq->clone = nil;
		if(r->reply.nwqid == 0){
			free(wq);
			wq = nil;
			goto Return;
		}
	}

	/* move new fid onto mnt device and update its qid */
	if(wq->clone != nil){
		if(wq->clone != c){
			wq->clone->type = c->type;
			wq->clone->mchan = c->mchan;
			incref(&c->mchan->r);
		}
		if(r->reply.nwqid > 0)
			wq->clone->qid = r->reply.wqid[r->reply.nwqid-1];
	}
	wq->nqid = r->reply.nwqid;
	for(i=0; i<wq->nqid; i++)
		wq->qid[i] = r->reply.wqid[i];

    Return:
	poperror();
	mntfree(r);
	poperror();
	return wq;
}

static int
mntstat(Chan *c, uchar *dp, int n)
{
	Mnt *m;
	Mntrpc *r;

	if(n < BIT16SZ)
		error(Eshortstat);
	m = mntchk(c);
	r = mntralloc(c, m->msize);
	if(waserror()) {
		mntfree(r);
		nexterror();
	}
	r->request.type = Tstat;
	r->request.fid = c->fid;
	mountrpc(m, r);

	if(r->reply.nstat > n){
		/* doesn't fit; just patch the count and return */
		PBIT16((uchar*)dp, r->reply.nstat);
		n = BIT16SZ;
	}else{
		n = r->reply.nstat;
		memmove(dp, r->reply.stat, n);
		validstat(dp, n);
		mntdirfix(dp, c);
	}
	poperror();
	mntfree(r);
	return n;
}

static Chan*
mntopencreate(int type, Chan *c, char *name, int omode, ulong perm)
{
	Mnt *m;
	Mntrpc *r;

	m = mntchk(c);
	r = mntralloc(c, m->msize);
	if(waserror()) {
		mntfree(r);
		nexterror();
	}
	r->request.type = type;
	r->request.fid = c->fid;
	r->request.mode = omode;
	if(type == Tcreate){
		r->request.perm = perm;
		r->request.name = name;
	}
	mountrpc(m, r);

	c->qid = r->reply.qid;
	c->offset = 0;
	c->mode = openmode(omode);
	c->iounit = r->reply.iounit;
	if(c->iounit == 0 || c->iounit > m->msize-IOHDRSZ)
		c->iounit = m->msize-IOHDRSZ;
	c->flag |= COPEN;
	poperror();
	mntfree(r);

	if(c->flag & CCACHE)
		copen(c);

	return c;
}

static Chan*
mntopen(Chan *c, int omode)
{
	return mntopencreate(Topen, c, nil, omode, 0);
}

static void
mntcreate(Chan *c, char *name, int omode, ulong perm)
{
	mntopencreate(Tcreate, c, name, omode, perm);
}

static void
mntclunk(Chan *c, int t)
{
	Mnt *m;
	Mntrpc *r;

	m = mntchk(c);
	r = mntralloc(c, m->msize);
	if(waserror()){
		mntfree(r);
		nexterror();
	}

	r->request.type = t;
	r->request.fid = c->fid;
	mountrpc(m, r);
	mntfree(r);
	poperror();
}

void
muxclose(Mnt *m)
{
	Mntrpc *q, *r;

	for(q = m->queue; q; q = r) {
		r = q->list;
		mntfree(q);
	}
	m->id = 0;
	free(m->version);
	m->version = nil;
	mntpntfree(m);
}

void
mntpntfree(Mnt *m)
{
	Mnt *f, **l;
	Queue *q;

	lock(&mntalloc.l);
	l = &mntalloc.list;
	for(f = *l; f; f = f->list) {
		if(f == m) {
			*l = m->list;
			break;
		}
		l = &f->list;
	}
	m->list = mntalloc.mntfree;
	mntalloc.mntfree = m;
	q = m->q;
	unlock(&mntalloc.l);

	qfree(q);
}

static void
mntclose(Chan *c)
{
	mntclunk(c, Tclunk);
}

static void
mntremove(Chan *c)
{
	mntclunk(c, Tremove);
}

static int
mntwstat(Chan *c, uchar *dp, int n)
{
	Mnt *m;
	Mntrpc *r;

	m = mntchk(c);
	r = mntralloc(c, m->msize);
	if(waserror()) {
		mntfree(r);
		nexterror();
	}
	r->request.type = Twstat;
	r->request.fid = c->fid;
	r->request.nstat = n;
	r->request.stat = dp;
	mountrpc(m, r);
	poperror();
	mntfree(r);
	return n;
}

static long
mntread(Chan *c, void *buf, long n, vlong off)
{
	uchar *p, *e;
	int nc, cache, isdir, dirlen;

	isdir = 0;
	cache = c->flag & CCACHE;
	if(c->qid.type & QTDIR) {
		cache = 0;
		isdir = 1;
	}

	p = buf;
	if(cache) {
		nc = cread(c, buf, n, off);
		if(nc > 0) {
			n -= nc;
			if(n == 0)
				return nc;
			p += nc;
			off += nc;
		}
		n = mntrdwr(Tread, c, p, n, off);
		cupdate(c, p, n, off);
		return n + nc;
	}

	n = mntrdwr(Tread, c, buf, n, off);
	if(isdir) {
		for(e = &p[n]; p+BIT16SZ < e; p += dirlen){
			dirlen = BIT16SZ+GBIT16(p);
			if(p+dirlen > e)
				break;
			validstat(p, dirlen);
			mntdirfix(p, c);
		}
		if(p != e)
			error(Esbadstat);
	}
	return n;
}

static long
mntwrite(Chan *c, void *buf, long n, vlong off)
{
	return mntrdwr(Twrite, c, buf, n, off);
}

long
mntrdwr(int type, Chan *c, void *buf, long n, vlong off)
{
	Mnt *m;
 	Mntrpc *r;	/* TO DO: volatile struct { Mntrpc *r; } r; */
	char *uba;
	int cache;
	ulong cnt, nr, nreq;

	m = mntchk(c);
	uba = buf;
	cnt = 0;
	cache = c->flag & CCACHE;
	if(c->qid.type & QTDIR)
		cache = 0;
	for(;;) {
		r = mntralloc(c, m->msize);
		if(waserror()) {
			mntfree(r);
			nexterror();
		}
		r->request.type = type;
		r->request.fid = c->fid;
		r->request.offset = off;
		r->request.data = uba;
		nr = n;
		if(nr > m->msize-IOHDRSZ)
			nr = m->msize-IOHDRSZ;
		r->request.count = nr;
		mountrpc(m, r);
		nreq = r->request.count;
		nr = r->reply.count;
		if(nr > nreq)
			nr = nreq;

		if(type == Tread)
			r->b = bl2mem((uchar*)uba, r->b, nr);
		else if(cache)
			cwrite(c, (uchar*)uba, nr, off);

		poperror();
		mntfree(r);
		off += nr;
		uba += nr;
		cnt += nr;
		n -= nr;
		if(nr != nreq || n == 0 || up->killed)
			break;
	}
	return cnt;
}

void
mountrpc(Mnt *m, Mntrpc *r)
{
	char *sn, *cn;
	int t;

	r->reply.tag = 0;
	r->reply.type = Tmax;	/* can't ever be a valid message type */

	mountio(m, r);

	t = r->reply.type;
	switch(t) {
	case Rerror:
		error(r->reply.ename);
	case Rflush:
		error(Eintr);
	default:
		if(t == r->request.type+1)
			break;
		sn = "?";
		if(m->c->name != nil)
			sn = m->c->name->s;
		cn = "?";
		if(r->c != nil && r->c->name != nil)
			cn = r->c->name->s;
		print("mnt: proc %s %ud: mismatch from %s %s rep 0x%p tag %d fid %d T%d R%d rp %d\n",
			up->text, up->pid, sn, cn,
			r, r->request.tag, r->request.fid, r->request.type,
			r->reply.type, r->reply.tag);
		error(Emountrpc);
	}
}

void
mountio(Mnt *m, Mntrpc *r)
{
	int n;

	while(waserror()) {
		if(m->rip == up)
			mntgate(m);
		if(strcmp(up->env->errstr, Eintr) != 0){
			mntflushfree(m, r);
			nexterror();
		}
		r = mntflushalloc(r, m->msize);
	}

	lock(&m->l);
	r->m = m;
	r->list = m->queue;
	m->queue = r;
	unlock(&m->l);

	/* Transmit a file system rpc */
	if(m->msize == 0)
		panic("msize");
	n = convS2M(&r->request, r->rpc, m->msize);
	if(n < 0)
		panic("bad message type in mountio");
	if(mntdebug)
		print("mnt: -> T%d tag %d fid %d (%s %ud)\n",
			r->request.type, r->request.tag, r->request.fid,
			up->text, up->pid);
	if(devtab[m->c->type]->write(m->c, r->rpc, n, 0) != n)
		error(Emountrpc);
/*	r->stime = fastticks(nil); */
	r->reqlen = n;

	/* Gate readers onto the mount point one at a time */
	for(;;) {
		lock(&m->l);
		if(m->rip == 0)
			break;
		unlock(&m->l);
		Sleep(&r->r, rpcattn, r);
		if(r->done){
			poperror();
			mntflushfree(m, r);
			return;
		}
	}
	m->rip = up;
	unlock(&m->l);
	if(mntdebug)
		print("mnt: reader is now %s %ud\n", up->text, up->pid);
	while(r->done == 0) {
		if(mntrpcread(m, r) < 0)
			error(Emountrpc);
		mountmux(m, r);
	}
	mntgate(m);
	poperror();
	mntflushfree(m, r);
}

static int
doread(Mnt *m, int len)
{
	Block *b;

	while(qlen(m->q) < len){
		b = devtab[m->c->type]->bread(m->c, m->msize, 0);
		if(b == nil)
			return -1;
		if(blocklen(b) == 0){
			freeblist(b);
			return -1;
		}
		qaddlist(m->q, b);
	}
	return 0;
}

int
mntrpcread(Mnt *m, Mntrpc *r)
{
	int i, t, len, hlen;
	Block *b, **l, *nb;

	r->reply.type = 0;
	r->reply.tag = 0;

	/* read at least length, type, and tag and pullup to a single block */
	if(doread(m, BIT32SZ+BIT8SZ+BIT16SZ) < 0)
		return -1;
	nb = pullupqueue(m->q, BIT32SZ+BIT8SZ+BIT16SZ);

	/* read in the rest of the message, avoid ridiculous (for now) message sizes */
	len = GBIT32(nb->rp);
	if(len > m->msize){
		qdiscard(m->q, qlen(m->q));
		return -1;
	}
	if(doread(m, len) < 0)
		return -1;

	/* pullup the header (i.e. everything except data) */
	t = nb->rp[BIT32SZ];
	switch(t){
	case Rread:
		hlen = BIT32SZ+BIT8SZ+BIT16SZ+BIT32SZ;
		break;
	default:
		hlen = len;
		break;
	}
	nb = pullupqueue(m->q, hlen);

	if(convM2S(nb->rp, len, &r->reply) <= 0){
		/* bad message, dump it */
		print("mntrpcread: convM2S failed\n");
		qdiscard(m->q, len);
		return -1;
	}

	if(mntdebug)
		print("mnt: <- R%d tag %d len %d (%s %ud)\n",
			r->reply.type, r->reply.tag, len, up->text, up->pid);

	/* hang the data off of the fcall struct */
	l = &r->b;
	*l = nil;
	do {
		b = qremove(m->q);
		if(hlen > 0){
			b->rp += hlen;
			len -= hlen;
			hlen = 0;
		}
		i = BLEN(b);
		if(i <= len){
			len -= i;
			*l = b;
			l = &(b->next);
		} else {
			/* split block and put unused bit back */
			nb = allocb(i-len);
			memmove(nb->wp, b->rp+len, i-len);
			b->wp = b->rp+len;
			nb->wp += i-len;
			qputback(m->q, nb);
			*l = b;
			return 0;
		}
	}while(len > 0);

	return 0;
}

void
mntgate(Mnt *m)
{
	Mntrpc *q;

	lock(&m->l);
	m->rip = 0;
	for(q = m->queue; q; q = q->list) {
		if(q->done == 0)
		if(Wakeup(&q->r))
			break;
	}
	unlock(&m->l);
}

void
mountmux(Mnt *m, Mntrpc *r)
{
	Mntrpc **l, *q;

	lock(&m->l);
	l = &m->queue;
	for(q = *l; q; q = q->list) {
		/* look for a reply to a message */
		if(q->request.tag == r->reply.tag) {
			*l = q->list;
			if(q != r) {
				/*
				 * Completed someone else.
				 * Trade pointers to receive buffer.
				 */
				q->reply = r->reply;
				q->b = r->b;
				r->b = nil;
			}
			q->done = 1;
			unlock(&m->l);
			if(mntstats != nil)
				(*mntstats)(q->request.type,
					m->c, q->stime,
					q->reqlen + r->replen);
			if(q != r)
				Wakeup(&q->r);
			return;
		}
		l = &q->list;
	}
	unlock(&m->l);
	if(r->reply.type == Rerror)
		print("mnt: unexpected reply tag %ud; type %d (error %q)\n", r->reply.tag, r->reply.type, r->reply.ename);
	else
		print("mnt: unexpected reply tag %ud; type %d\n", r->reply.tag, r->reply.type);
}

/*
 * Create a new flush request and chain the previous
 * requests from it
 */
Mntrpc*
mntflushalloc(Mntrpc *r, ulong iounit)
{
	Mntrpc *fr;

	fr = mntralloc(0, iounit);

	fr->request.type = Tflush;
	if(r->request.type == Tflush)
		fr->request.oldtag = r->request.oldtag;
	else
		fr->request.oldtag = r->request.tag;
	fr->flushed = r;

	return fr;
}

/*
 *  Free a chain of flushes.  Remove each unanswered
 *  flush and the original message from the unanswered
 *  request queue.  Mark the original message as done
 *  and if it hasn't been answered set the reply to to
 *  Rflush.
 */
void
mntflushfree(Mnt *m, Mntrpc *r)
{
	Mntrpc *fr;

	while(r){
		fr = r->flushed;
		if(!r->done){
			r->reply.type = Rflush;
			mntqrm(m, r);
		}
		if(fr)
			mntfree(r);
		r = fr;
	}
}

static int
alloctag(void)
{
	int i, j;
	ulong v;

	for(i = 0; i < NMASK; i++){
		v = mntalloc.tagmask[i];
		if(v == ~0UL)
			continue;
		for(j = 0; j < 1<<TAGSHIFT; j++)
			if((v & (1<<j)) == 0){
				mntalloc.tagmask[i] |= 1<<j;
				return (i<<TAGSHIFT) + j;
			}
	}
	/* panic("no devmnt tags left"); */
	return NOTAG;
}

static void
freetag(int t)
{
	mntalloc.tagmask[t>>TAGSHIFT] &= ~(1<<(t&TAGMASK));
}

Mntrpc*
mntralloc(Chan *c, ulong msize)
{
	Mntrpc *new;

	lock(&mntalloc.l);
	new = mntalloc.rpcfree;
	if(new == nil){
		new = malloc(sizeof(Mntrpc));
		if(new == nil) {
			unlock(&mntalloc.l);
			exhausted("mount rpc header");
		}
		/*
		 * The header is split from the data buffer as
		 * mountmux may swap the buffer with another header.
		 */
		new->rpc = mallocz(msize, 0);
		if(new->rpc == nil){
			free(new);
			unlock(&mntalloc.l);
			exhausted("mount rpc buffer");
		}
		new->rpclen = msize;
		new->request.tag = alloctag();
		if(new->request.tag == NOTAG){
			free(new);
			unlock(&mntalloc.l);
			exhausted("rpc tags");
		}
	}
	else {
		mntalloc.rpcfree = new->list;
		mntalloc.nrpcfree--;
		if(new->rpclen < msize){
			free(new->rpc);
			new->rpc = mallocz(msize, 0);
			if(new->rpc == nil){
				free(new);
				mntalloc.nrpcused--;
				unlock(&mntalloc.l);
				exhausted("mount rpc buffer");
			}
			new->rpclen = msize;
		}
	}
	mntalloc.nrpcused++;
	unlock(&mntalloc.l);
	new->c = c;
	/*
	 * m, not just done.
	 *
	 * A fresh Mntrpc comes from malloc(), not mallocz(), and a
	 * recycled one still carries the mount it was last used on -- so
	 * mntfree()'s "sent and never answered" test (r->m != nil &&
	 * r->done == 0) was reading uninitialised or stale memory and
	 * deciding whether to retire a tag on it.  mountio() sets r->m
	 * when it queues the request; until then it must be nil.
	 */
	new->m = nil;
	new->done = 0;
	new->flushed = nil;
	new->b = nil;
	return new;
}

void
mntfree(Mntrpc *r)
{
	if(r->b != nil)
		freeblist(r->b);
	lock(&mntalloc.l);
	/*
	 * NEVER recycle an rpc whose reply may still be coming.
	 *
	 * This is where a tag is really reused.  mntfree does not free
	 * the tag -- it puts the whole Mntrpc, tag and all, on
	 * mntalloc.rpcfree, and mntralloc hands the next caller that
	 * same struct with that same tag.  So an rpc abandoned with its
	 * request already on the wire gives its tag to the very next
	 * request, and when the server finally answers the dead one the
	 * reply is delivered to the live one:
	 *
	 *   mnt: proc released: mismatch ... tag 2 fid 44 T104 R117
	 *   mnt: proc exwork:   mismatch ... tag 2 fid 33 T120 R105
	 *
	 * A Tattach answered by an Rread, a Tclunk answered by an
	 * Rattach.  After that the session is off by one for good, and
	 * because styxlisten gives every client a mount of the SAME pipe
	 * to a single `export /', one client is enough to take the whole
	 * server down: every later mount fails with "mount rpc error",
	 * connections are accepted and never served, and from outside
	 * the server has just stopped answering.  Five clients killed
	 * mid-read did it reliably; the board does it once per reboot.
	 *
	 * r->m is set when the request is queued for transmission, so
	 * (m != nil && !done) is exactly "sent, unanswered, abandoned".
	 * Retire the tag rather than hand it on: 64K tags, a handful
	 * lost per dead client, against a session that cannot recover.
	 */
	if(r->m != nil && r->done == 0){
		if(mntdebug)
			print("mnt: retiring tag %d (T%d fid %d) abandoned unanswered\n",
				r->request.tag, r->request.type, r->request.fid);
		mntalloc.nrpcused--;
		unlock(&mntalloc.l);
		free(r->rpc);
		free(r);
		return;
	}
	if(mntalloc.nrpcfree >= 10){
		free(r->rpc);
		freetag(r->request.tag);
		free(r);
	}
	else{
		r->list = mntalloc.rpcfree;
		mntalloc.rpcfree = r;
		mntalloc.nrpcfree++;
	}
	mntalloc.nrpcused--;
	unlock(&mntalloc.l);
}

void
mntqrm(Mnt *m, Mntrpc *r)
{
	Mntrpc **l, *f;

	lock(&m->l);
	r->done = 1;

	l = &m->queue;
	for(f = *l; f; f = f->list) {
		if(f == r) {
			*l = r->list;
			break;
		}
		l = &f->list;
	}
	unlock(&m->l);
}

Mnt*
mntchk(Chan *c)
{
	Mnt *m;

	/* This routine is mostly vestiges of prior lives; now it's just sanity checking */

	if(c->mchan == nil)
		panic("mntchk 1: nil mchan c %s\n", c2name(c));

	m = c->mchan->mux;

	if(m == nil)
		print("mntchk 2: nil mux c %s c->mchan %s \n", c2name(c), c2name(c->mchan));

	/*
	 * Was it closed and reused (was error(Eshutdown); now, it can't happen)
	 */
	if(m->id == 0 || m->id >= c->dev)
		panic("mntchk 3: can't happen");

	return m;
}

/*
 * Rewrite channel type and dev for in-flight data to
 * reflect local values.  These entries are known to be
 * the first two in the Dir encoding after the count.
 */
void
mntdirfix(uchar *dirbuf, Chan *c)
{
	uint r;

	r = devtab[c->type]->dc;
	dirbuf += BIT16SZ;	/* skip count */
	PBIT16(dirbuf, r);
	dirbuf += BIT16SZ;
	PBIT32(dirbuf, c->dev);
}

int
rpcattn(void *v)
{
	Mntrpc *r;

	r = v;
	return r->done || r->m->rip == 0;
}

Dev mntdevtab = {
	'M',
	"mnt",

	mntinit,
	mntattach,
	mntwalk,
	mntstat,
	mntopen,
	mntcreate,
	mntclose,
	mntread,
	devbread,
	mntwrite,
	devbwrite,
	mntremove,
	mntwstat,
};
