/*
 * #O - the Osprey resource containers, per-core EDF run queues and
 * asynchronous request rings, as an Inferno device.
 *
 * doc/osprey-plan.ms asks for request and reply rings reachable from
 * user processes and for a portable request dispatcher.  Exposing them
 * through Chan operations rather than through new system calls keeps the
 * contract the same for a native kernel and for a hosted adapter, and
 * lets the rings be driven and inspected from the shell.
 *
 * The policy layer holds no locks of its own, so every entry point here
 * is serialised by one qlock.
 */
#include	"u.h"
#include	"lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"error.h"

#include	"../netif.h"
#include	"etherif.h"

#include	"osprey.h"
#include	<libsec.h>
#include	<mp.h>
#include	"pip.h"

enum {
	Qdir,
	Qctl,
	Qstatus,
	Qreply,
	Qarena,
	Qpip,
	Qsnap,
	Qticket,
	Qbench,

	Statuslen	= 32*1024,	/* every core and container line */
	Snaplen		= 64*1024,	/* every container as a checkpoint */
	Nfd		= 16,		/* chans a container may hold open */
	Rbtlr		= 16,		/* allocb's trailer room, kept clear of */
	Pipethertype	= 0x910a,	/* frames that carry a pi-p group */
	Pairethertype	= 0x910b,	/* and that agree a key */
	Pipframe	= 1514,
	Etherhdr	= 14,
	Minframe	= 60,
	Namelen		= 256,		/* longest path a request may name */
};

/*
 * The operation numbers are the portable layer's, which this file may not
 * include; they are named here so the dispatcher can switch on them.
 */
enum {
	OpRead,
	OpWrite,
	OpOpen,
	OpClose,
	OpWait,
	OpSend,
	OpRecv,
	OpStat,
	OpBind,
	OpAlloc,
	OpYield,
	OpPoll,
};

enum {
	StatusPending,
	StatusDone,
	StatusError,
	StatusBlocked,
	StatusRetry,
};

static Dirtab ospreydir[] = {
	".",		{Qdir, 0, QTDIR},	0,	DMDIR|0555,
	"ctl",		{Qctl},			0,	0664,
	"status",	{Qstatus},		0,	0444,
	"reply",	{Qreply},		0,	0444,
	"arena",	{Qarena},		0,	0660,
	"pip",		{Qpip},			0,	0660,
	"snap",		{Qsnap},		0,	0660,
	"ticket",	{Qticket},		0,	0660,
	"bench",	{Qbench},		0,	0660,
};

/*
 * pi-p.  A session holds fids and outlives the connection that made it,
 * so a client that loses one opens another and says which session it is
 * resuming.  Writing a group of T messages leaves the R messages for the
 * next read: one round trip for as many transactions as fit.
 */
enum {
	Nsession	= 8,
	Nfid		= 16,
};

typedef struct Pipfid Pipfid;
typedef struct Pipsession Pipsession;

struct Pipfid {
	int	used;
	ulong	fid;
	uvlong	id;		/* the container it names, or 0 for the root */
	int	open;
	uvlong	lease;		/* good until this many milliseconds */

	/*
	 * The version this fid is making.  A write changes it and nobody
	 * else can see it; closing the fid commits it, unless what it was
	 * made from has been committed over since.
	 */
	int	dirty;
	uvlong	base;		/* the version it was made from */
	char	name[8][32];
	char	val[8][32];
	int	nval;
};

struct Pipsession {
	int	used;
	uvlong	sid;
	uvlong	lease;
	char	user[Pipmaxname+1];	/* proven by a ticket, or empty */
	uvlong	authid;			/* the container the ticket is for */
	Pipfid	fid[Nfid];
	uchar	reply[Pipmaxmsg];
	long	nreply;
	long	rp;
	int	overflow;	/* a reply would not fit and was not made */
};

/*
 * A stream: an attribute that keeps arriving at a rate, rather than one
 * that is asked for.  It belongs to a fid, it goes to the address the
 * request came from, and it needs a wire -- over a file nothing can
 * arrive that was not read for.
 */
typedef struct Pipstream Pipstream;
struct Pipstream {
	int	used;
	uvlong	sid;
	ulong	fid;
	int	tag;
	uvlong	period;		/* milliseconds between frames */
	long	left;		/* frames still to send, -1 for no end */
	uvlong	due;		/* when the next one goes */
	char	attr[Pipmaxname+1];
	uchar	ea[6];		/* whoever asked for it */
};

/*
 * Proving who is asking.  A name on its own is only worth what the
 * machine it was said on is worth: over a wire, or in a checkpoint that
 * came from somewhere else, anyone may say anything.  So a machine holds
 * a key, and what it signs with that key it will believe again -- and so
 * will any other machine holding the same key.  This is devcap's trick
 * with a different shape: not a hash to be presented once, but a ticket
 * that says who, for which container, until when.
 */
enum {
	Keylen		= SHA1dlen,
	Ticketlen	= 256,
	Sigchars	= 2*SHA1dlen,
};

static uchar ospreykey[Keylen];
static int ospreykeyset;

/*
 * The key agreed rather than typed in twice.  Two machines each pick a
 * number they keep, send what it makes of a public one, and arrive at
 * the same secret without it ever crossing the wire.  This is Oakley
 * group 2 -- RFC 2409's 1024-bit prime, and 2 -- which is published
 * exactly so that everybody may use the same one.
 *
 * What this does not do is say who is on the other end.  Whoever answers
 * first is whom the key is agreed with, so both machines say what
 * fingerprint they arrived at and somebody who can see both compares
 * them.  That is the whole of the authentication and it is a person.
 */
static char *pairprime =
	"FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1"
	"29024E088A67CC74020BBEA63B139B22514A08798E3404DD"
	"EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245"
	"E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
	"EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381"
	"FFFFFFFFFFFFFFFF";

static void ospreyhex(uchar*, int, char*);
static Chan *etherconv(char*, int, Chan**);

static char ospreyfinger[2*8+1];	/* what key this machine arrived at */

static void
pairgen(uchar *p, int n)
{
	randomread(p, n);
}

/*
 * What this machine offers: g**x mod p, keeping x.  The caller frees
 * nothing; what is kept is returned and what is not is let go here.
 */
static int
pairoffer(mpint **xp, mpint **pp, uchar *out, int nout)
{
	mpint *p, *g, *x, *y;
	int n;

	p = strtomp(pairprime, nil, 16, nil);
	g = uitomp(2, nil);
	x = mprand(256, pairgen, nil);
	y = mpnew(0);
	if(p == nil || g == nil || x == nil || y == nil)
		return -1;
	if(mpcmp(p, mpzero) == 0)	/* the group did not parse */
		return -1;
	mpexp(g, x, p, y);
	n = mptobe(y, out, nout, nil);
	mpfree(g);
	mpfree(y);
	*xp = x;
	*pp = p;
	return n;
}

/*
 * And what it makes of what it was offered: the same secret on both
 * sides, having crossed nothing.  The key is what SHA1 makes of it.
 */
static void
pairfinish(mpint *x, mpint *p, uchar *in, int n)
{
	mpint *ytheirs, *z;
	uchar *b;
	int k;

	ytheirs = betomp(in, n, nil);
	z = mpnew(0);
	if(ytheirs == nil || z == nil)
		return;
	mpexp(ytheirs, x, p, z);
	b = smalloc(256);
	k = mptobe(z, b, 256, nil);
	if(k > 0){
		uchar h[SHA1dlen];

		ospreykeyset = 0;	/* nothing checks against half a key */
		sha1(b, k, ospreykey, nil);
		sha1(ospreykey, Keylen, h, nil);
		ospreyhex(h, 8, ospreyfinger);
		ospreykeyset = 1;
	}
	free(b);
	mpfree(ytheirs);
	mpfree(z);
}

typedef struct Pairarg Pairarg;
struct Pairarg {
	char	ifc[32];
	int	offer;
};

/*
 * Agree a key with whoever is on the other end of an interface.  One
 * machine listens and one offers; both end up holding the same key and
 * saying the same fingerprint, and neither of them has been told what
 * the other is called.
 */
static void
pairproc(void *a)
{
	Pairarg *pa;
	Chan *dc, *cc;
	mpint *x, *p;
	uchar *in, *out;
	long n;
	int k;

	pa = a;
	in = out = nil;
	dc = cc = nil;
	x = p = nil;
	if(waserror())
		goto done;
	in = smalloc(Pipframe);
	out = smalloc(Pipframe);
	dc = etherconv(pa->ifc, Pairethertype, &cc);
	if((k = pairoffer(&x, &p, out+Etherhdr+3, Pipframe-Etherhdr-3)) <= 0)
		error("cannot make an offer");
	memset(out, 0xff, 6);		/* to whoever is out there */
	memset(out+6, 0, 6);
	out[12] = Pairethertype >> 8;
	out[13] = Pairethertype;
	out[Etherhdr] = pa->offer ? 1 : 2;
	out[Etherhdr+1] = k >> 8;
	out[Etherhdr+2] = k;
	n = Etherhdr + 3 + k;
	while(n < Minframe)
		out[n++] = 0;

	if(pa->offer)
		devtab[dc->type]->write(dc, out, n, 0);
	for(;;){
		k = devtab[dc->type]->read(dc, in, Pipframe, 0);
		if(k <= Etherhdr + 3)
			continue;
		if(in[Etherhdr] != (pa->offer ? 2 : 1))
			continue;	/* our own frame, or the wrong half */
		break;
	}
	if(!pa->offer){
		memmove(out, in+6, 6);	/* back to whoever asked */
		devtab[dc->type]->write(dc, out, n, 0);
	}
	k = (in[Etherhdr+1]<<8) | in[Etherhdr+2];
	if(k > 0 && Etherhdr + 3 + k <= Pipframe)
		pairfinish(x, p, in+Etherhdr+3, k);
	poperror();
done:
	if(x != nil)
		mpfree(x);
	if(p != nil)
		mpfree(p);
	if(dc != nil)
		cclose(dc);
	if(cc != nil)
		cclose(cc);
	free(in);
	free(out);
	free(pa);
	pexit("osprey pair", 1);
}

static void
ospreyhex(uchar *h, int n, char *out)
{
	static char x[] = "0123456789abcdef";
	int i;

	for(i = 0; i < n; i++){
		*out++ = x[h[i]>>4];
		*out++ = x[h[i]&0xF];
	}
	*out = '\0';
}

/* the signature over some text, or nothing if this machine holds no key */
static int
ospreysign(char *text, char *out, int nout)
{
	uchar h[SHA1dlen];

	if(ospreykeyset == 0 || nout <= Sigchars)
		return -1;
	hmac_sha1((uchar*)text, strlen(text), ospreykey, Keylen, h, nil);
	ospreyhex(h, SHA1dlen, out);
	return Sigchars;
}

/* whether that signature is the one this key makes over that text */
static int
ospreysigok(char *text, char *sig)
{
	char want[Sigchars+1];
	int i, d;

	if(ospreykeyset == 0 || sig == nil)
		return 0;
	if((long)strlen(sig) != Sigchars)	/* before reading that far */
		return 0;
	if(ospreysign(text, want, sizeof want) < 0)
		return 0;
	/* the whole string every time: a compare that stops early tells */
	for(d = 0, i = 0; i < Sigchars; i++)
		d |= want[i] ^ sig[i];
	return d == 0;
}

/*
 * A ticket is its own text and the signature over it:
 *	user id expiry signature
 * Expiry is in seconds since the epoch, so that it means the same on the
 * machine that reads it as on the machine that wrote it.
 */
static int
ospreyticket(char *user, uvlong id, uvlong expiry, char *out, int nout)
{
	char text[Ticketlen];
	int n;

	n = snprint(text, sizeof text, "%s %llud %llud", user, id, expiry);
	if(n < 0 || n + 1 + Sigchars >= nout)
		return -1;
	strcpy(out, text);
	out[n] = ' ';
	return ospreysign(text, out+n+1, nout-n-1) < 0 ? -1 : n+1+Sigchars;
}

/*
 * What a ticket says, if it says it truthfully and still holds.  The
 * name is copied out; nothing of the caller's is trusted afterwards.
 */
static int
ospreyticketok(char *t, char *user, int nuser, uvlong *id)
{
	char buf[Ticketlen], text[Ticketlen], *f[4];
	uvlong expiry;
	int nf;

	if(ospreykeyset == 0 || strlen(t) >= sizeof buf)
		return -1;
	strcpy(buf, t);
	nf = tokenize(buf, f, nelem(f));
	if(nf != 4)
		return -1;
	/* the text as it was signed, put back rather than patched up */
	if(snprint(text, sizeof text, "%s %s %s", f[0], f[1], f[2]) < 0)
		return -1;
	if(!ospreysigok(text, f[3]))
		return -1;
	expiry = strtoull(f[2], nil, 10);
	if(expiry != 0 && expiry < (uvlong)seconds())
		return -1;
	*id = strtoull(f[1], nil, 10);
	strncpy(user, f[0], nuser-1);
	user[nuser-1] = '\0';
	return 0;
}

static Pipsession pipsession[Nsession];
static Pipstream pipstream[Pipmaxstream];
static uchar pipfrom[6];	/* the address the group in hand came from */
static int pipviafile;		/* the group in hand came through #O/pip */
static Chan *pipetherchan;	/* the wire, while there is one */
static Rendez pipetherrend;	/* woken when the wire has been given back */
static int pipetherprocs;	/* how many processes are answering on it */
static int pipserving;		/* a wire is being answered on */
static uvlong pipnextsid = 1;
static QLock piplock;

static uvlong
pipnow(void)
{
	return TK2MS(MACHP(0)->ticks);
}

/* let go of everything whose lease has run out */
static void
pipexpire(void)
{
	uvlong now;
	int i, j;

	now = pipnow();
	for(i = 0; i < Nsession; i++){
		if(pipsession[i].used == 0)
			continue;
		if(pipsession[i].lease < now){
			pipsession[i].used = 0;
			continue;
		}
		for(j = 0; j < Nfid; j++)
			if(pipsession[i].fid[j].used
			&& pipsession[i].fid[j].lease < now)
				pipsession[i].fid[j].used = 0;
	}
}

enum {
	CMreset,
	CMcreate,
	CMattach,
	CMdetach,
	CMexit,
	CMbalance,
	CMlimit,
	CMschedule,
	CMcharge,
	CMsubmit,
	CMservice,
	CMbind,
	CMunbind,
	CMwait,
	CMpoke,
	CMcheckpoint,
	CMrestore,
	CMmigrate,
	CMnetcharge,
	CMnetfree,
	CMbindproc,
	CMunbindproc,
	CMserve,
	CMmode,
	CMsemup,
	CMselect,
	CMtick,
	CMuart,
	CMether,
	CMdelegate,
	CMpage,
	CMflip,
	CMgrant,
	CMrevoke,
	CMpipether,
	CMkey,
	CMpair,
	CMoutput,
};

static Cmdtab ospreycmd[] = {
	CMreset,	"reset",	1,
	CMcreate,	"create",	5,
	CMattach,	"attach",	3,
	CMdetach,	"detach",	2,
	CMexit,		"exit",		2,
	CMbalance,	"balance",	1,
	CMlimit,	"limit",	5,
	CMschedule,	"schedule",	2,
	CMcharge,	"charge",	3,
	CMsubmit,	"submit",	0,
	CMservice,	"service",	0,
	CMbind,		"bind",		4,
	CMunbind,	"unbind",	3,
	CMwait,		"wait",		2,
	CMpoke,		"poke",		4,
	CMcheckpoint,	"checkpoint",	2,
	CMrestore,	"restore",	2,
	CMmigrate,	"migrate",	3,
	CMbindproc,	"bindproc",	3,
	CMserve,	"serve",	2,
	CMmode,		"mode",		3,
	CMsemup,	"semup",	3,
	CMselect,	"select",	4,
	CMtick,		"tick",		3,
	CMuart,		"uart",		4,
	CMether,	"ether",	4,
	CMdelegate,	"delegate",	3,
	CMpage,		"page",		3,
	CMflip,		"flip",		4,
	CMgrant,	"grant",	3,
	CMrevoke,	"revoke",	3,
	CMpipether,	"pipether",	3,
	CMkey,		"key",		2,
	CMpair,		"pair",		3,
	CMoutput,	"output",	4,
	CMunbindproc,	"unbindproc",	2,
	CMnetcharge,	"netcharge",	4,
	CMnetfree,	"netfree",	4,
};

static QLock ospreylock;
/*
 * One pair of rendezvous points per container: sleep() allows a single
 * sleeper on a Rendez, and a room-waiter and a reply-waiter must not
 * share one.  A ring still has one producer and one consumer.
 */
static Rendez ospreyroomrend[16];
static Rendez ospreyreplyrend[16];

/*
 * One lock per core.  The clock path takes only the lock of the core it
 * ticks; the adapter takes them all, in index order, when it moves a task
 * between cores.  They are ilocks because hzclock() runs with no process.
 */
static Lock ospreysemlock;		/* semaphores, given from interrupts */
static Lock ospreycorelock[8];
static uvlong ospreylastticks[8];
static uvlong ospreyhz;			/* machine cycles a second */

void
ospreylockcore(ulong core)
{
	if(core < nelem(ospreycorelock))
		ilock(&ospreycorelock[core]);
}

void
ospreyunlockcore(ulong core)
{
	if(core < nelem(ospreycorelock))
		iunlock(&ospreycorelock[core]);
}

void
ospreylocksem(void)
{
	ilock(&ospreysemlock);
}

void
ospreyunlocksem(void)
{
	iunlock(&ospreysemlock);
}
static uchar *ospreybase;		/* the shared arena */
/*
 * SG_PHYSICAL is a value of the SG_TYPE field, not a flag beside it.
 * Each container's slice is a segment of its own, and so is each page
 * that may be handed between them, so that attaching one gets that
 * memory and nobody else's.
 */
static Physseg ospreyseg[16+32];
static int ospreynseg;
static Chan *ospreyfd[16][Nfd];		/* per container, indexed as procs are */
static Proc *ospreyprocs[16];		/* the process bound to each container */
static Rendez ospreyservrend[16];	/* wakes a container's service process */
static Rendez ospreyselrend[16];	/* wakes a container's select */
static int ospreyserving[16];		/* a service process is running for it */
static uvlong ospreyservingid[16];	/* and which container it was started for */
static Pgrp *ospreypgrp[16];		/* the namespace it is to run in */
static int ospreystopped[16];		/* we stopped that container's process */
static int ospreyticksem[16];		/* semaphore the clock gives, or -1 */
static Uart *ospreyuart[16];		/* a uart this container serves */
static int ospreyuartsem[16];		/* the semaphore its interrupt gives */
static int ospreyuarting[16];		/* its driver task is running */
static uvlong ospreyuartoff[16];	/* what is left of the last work taken */
static long ospreyuartlen[16];
static void *ospreyether[16];		/* an interface this container has */
static int ospreyethersem[16];		/* the semaphore its packets give */
static Bpool ospreyrbpool[16];		/* its receive buffers, in the span */
static Block *ospreyheld[16];		/* the packet the container is reading */
static ulong ospreydirect[16];		/* packets that arrived in the span */
static ulong ospreycopied[16];		/* and packets that had to be moved */

/*
 * Lend the interface receive buffers out of the container's own slice.
 * The driver takes them from the pool as it would its own, the card
 * writes the packet straight into memory the container has mapped, and
 * freeing one puts it back.  Nothing is copied on the way in or out.
 */
static int
ospreylendbufs(Ospreyproc *p, int x)
{
	Bpool *pool;
	Block *b;
	uchar *a;
	uvlong off, size, n, i;

	if(ospreymapsizes(p, &off, &n, &size) < 0 || n == 0)
		return -1;
	pool = &ospreyrbpool[x];
	memset(pool, 0, sizeof *pool);
	pool->size = size - Rbtlr;
	pool->align = 8;
	for(i = 0; i < n; i++){
		if((a = ospreyat_off(p, off + i*size, size)) == nil)
			return -1;
		if((b = mallocz(sizeof(Block), 1)) == nil)
			return -1;
		b->base = a;
		b->lim = a + size;
		b->rp = b->wp = a;
		b->pool = pool;
		b->flag = BINTR;
		b->list = pool->head;
		pool->head = b;
	}
	return 0;
}

void
queuebarrier(void)
{
	coherence();
}

/*
 * One tick of this core's clock, from hzclock().  The elapsed machine
 * cycles are billed to whatever container the core is running; a gap
 * longer than a second is clamped, so a core that was idle in the monitor
 * does not throw everything off its queue at once.
 */
static void ospreywakeup(void);
static void ospreyrelease(Proc*, int);
static Chan *etherconv(char*, int, Chan**);
static long pipserve(uchar*, long, uchar*, long);
static int ospreyarmready(void*);

/*
 * Called from etheriq, in the driver's interrupt or its input task.  A
 * packet for a container that has claimed this interface is charged
 * against its network caps and put on its queue whole; the block is not
 * copied and not freed here.  A container over its caps, or with no
 * room, refuses it and the driver disposes of it as it would have.
 */
/*
 * Take one of the container's own buffers, or nothing.  iallocbp would
 * make a new block out of kernel memory when the pool ran dry, which is
 * exactly the memory these buffers exist to avoid.
 */
static ulong
ospreycountdirect(Ospreyproc *p)
{
	int x;

	x = ospreyindex(p);
	return x < 0 || x >= nelem(ospreydirect) ? 0 : ospreydirect[x];
}

static ulong
ospreycountcopied(Ospreyproc *p)
{
	int x;

	x = ospreyindex(p);
	return x < 0 || x >= nelem(ospreycopied) ? 0 : ospreycopied[x];
}

static Block*
ospreytakebuf(int x)
{
	Bpool *pool;
	Block *b;

	pool = &ospreyrbpool[x];
	ilock(pool);
	if((b = pool->head) != nil){
		pool->head = b->list;
		b->list = nil;
	}
	iunlock(pool);
	return b;
}

static int
ospreyethergive(void *ether, Block *bp)
{
	Ospreyproc *p;
	Block *nb;
	long n;
	int i;

	for(i = 0; i < nelem(ospreyether); i++){
		if(ospreyether[i] != ether)
			continue;
		if((p = ospreyat(i)) == nil)
			return 0;
		/*
		 * A packet the card wrote into one of the container's own
		 * buffers is already where it belongs.  One that arrived in
		 * a buffer the driver had queued before the interface was
		 * given away is moved into one, so that what the container
		 * is told is always a place in the span; as the driver's
		 * own buffers are used up and replaced from the pool, this
		 * stops happening.
		 */
		n = BLEN(bp);
		if(ospreyoff_at(p, bp->rp) == ~0ULL){
			if((nb = ospreytakebuf(i)) == nil)
				return 0;
			if(n > nb->lim - nb->wp)
				n = nb->lim - nb->wp;
			memmove(nb->wp, bp->rp, n);
			nb->wp += n;
			freeb(bp);
			bp = nb;
			ospreycopied[i]++;
		} else
			ospreydirect[i]++;
		if(ospreypktput(p, bp, n) < 0){
			freeb(bp);
			return 1;
		}
		ospreysemgive(p, ospreyethersem[i]);
		wakeup(&ospreyselrend[i]);
		wakeup(&ospreyservrend[i]);
		return 1;
	}
	return 0;
}

/*
 * Called from a uart's interrupt handler.  Everything the handler does
 * for a claimed uart is here: give the task's semaphore and wake it.  The
 * handler masks the device and returns; the task does the work.
 */
static int
ospreyuartgive(Uart *uart)
{
	Ospreyproc *p;
	int i;

	for(i = 0; i < nelem(ospreyuart); i++){
		if(ospreyuart[i] != uart || ospreyuarting[i] == 0)
			continue;
		if((p = ospreyat(i)) == nil)
			return 0;
		ospreysemgive(p, ospreyuartsem[i]);
		wakeup(&ospreyselrend[i]);
		return 1;
	}
	return 0;
}

/*
 * What is left of the work last taken off the output queue, pushed as
 * far as the transmitter will take it now.  Returns what is still left.
 */
static long
ospreyuartpush(Ospreyproc *p, Uart *uart, int x)
{
	uchar *b;
	int k;

	if(ospreyuartlen[x] <= 0)
		return 0;
	if(uart->phys->send == nil){	/* nothing to push it with */
		ospreyuartlen[x] = 0;
		return 0;
	}
	b = ospreydata(p, ospreyuartoff[x], ospreyuartlen[x]);
	if(b == nil){
		ospreyuartlen[x] = 0;
		return 0;
	}
	k = (*uart->phys->send)(uart, b, ospreyuartlen[x]);
	if(k > 0){
		ospreyuartoff[x] += k;
		ospreyuartlen[x] -= k;
	}
	return ospreyuartlen[x];
}

/*
 * A uart served by a task, as the presentation has it.  The task waits
 * on three things at once, which is the shape the talk gives a driver:
 * the messages sent to it on its container's request ring, the semaphore
 * its interrupt gives, and the output queue it takes work from.  When
 * the interrupt is what fired it does the work the handler would have
 * done and lets the device interrupt again.  It is a kernel task, so no
 * trap is taken for the wait or for the work.
 *
 * The output arm is turned off in place -- MSnoop, not a rebuilt array
 * -- while what was last taken is still going out, which is what
 * select(2) of the talk describes a driver doing with a full fifo.
 */
static void
ospreyuarttask(void *a)
{
	Ospreyproc *p = a;
	Ospreyarm *arm;
	Uart *uart;
	uvlong arg[Ospreynarg], op, msg, out;
	int x, n;

	if(waserror())
		goto done;
	for(;;){
		if((x = ospreyindex(p)) < 0 || (uart = ospreyuart[x]) == nil)
			break;

		ospreyuartpush(p, uart, x);

		/*
		 * The arms go in the container's data area, where a select
		 * from anywhere else puts them, and so do the two messages
		 * they are taken into.
		 */
		if((arm = ospreydata(p, 0, 3*sizeof(Ospreyarm))) == nil)
			break;
		msg = 3*sizeof(Ospreyarm);
		out = msg + ospreymsgsize();
		arm[0].op = OSget;
		arm[0].obj = 0;			/* the request ring */
		arm[0].buf = msg;
		arm[1].op = OSdown;
		arm[1].obj = ospreyuartsem[x];	/* the interrupt */
		arm[1].buf = 0;
		arm[2].op = ospreyuartlen[x] > 0 ? OSnoop : OSget;
		arm[2].obj = 2;			/* the output queue */
		arm[2].buf = out;

		qlock(&ospreylock);
		n = ospreyselect(p, 0, 3);
		qunlock(&ospreylock);

		if(n == 1){
			(*uart->phys->interrupt)(uart);
			(*uart->phys->intrmask)(uart, 1);
			continue;
		}
		if(n == 2){
			/* work: a place in the container's own data area */
			qlock(&ospreylock);
			if(ospreymessage(p, out, &op, arg) == 0){
				ospreyuartoff[x] = arg[0];
				ospreyuartlen[x] = (long)arg[1];
			}
			qunlock(&ospreylock);
			continue;
		}
		if(n == 0){
			/*
			 * A control message.  What a task holding a uart can
			 * do with one is set its line speed and give it back;
			 * anything else is refused, and every one is answered
			 * on the reply ring.
			 */
			long status;

			status = ospreystatusof("error");
			qlock(&ospreylock);
			if(ospreymessage(p, msg, &op, arg) == 0){
				char *name = ospreyopname(op);

				if(strcmp(name, "open") == 0){
					if(arg[0] != 0 && uart->phys->baud != nil
					&& (*uart->phys->baud)(uart, (int)arg[0]) < 0)
						status = ospreystatusof("error");
					else
						status = ospreystatusof("done");
				} else if(strcmp(name, "close") == 0){
					status = ospreystatusof("done");
					/* give it back as ctl uart off does */
					if(uart->phys->taskenable != nil)
						(*uart->phys->taskenable)(uart, 0);
					(*uart->phys->intrmask)(uart, 1);
					ospreyuart[x] = nil;
				}
			}
			ospreyanswer(p, msg, status);
			qunlock(&ospreylock);
			ospreywakeup();
			continue;
		}
		/*
		 * Nothing to do.  With work still going out there is no arm
		 * to wake on -- the transmit interrupt is not enabled, since
		 * an enabled one with an idle transmitter never stops -- so
		 * look again shortly instead.
		 */
		if(ospreyuartlen[x] > 0)
			tsleep(&up->sleep, return0, nil, 5);
		else
			sleep(&ospreyselrend[x], ospreyarmready, p);
	}
	poperror();
done:
	if((x = ospreyindex(p)) >= 0 && x < nelem(ospreyuarting)){
		ospreyuarting[x] = 0;
		ospreyuartlen[x] = 0;
		if(ospreyuart[x] != nil)
			(*ospreyuart[x]->phys->intrmask)(ospreyuart[x], 1);
		ospreyuart[x] = nil;
	}
	pexit("osprey uart", 1);
}

/* the uart task waits for one of its arms, or for its uart to be taken */
static int
ospreyarmready(void *a)
{
	Ospreyproc *p = a;
	int x;

	if((x = ospreyindex(p)) < 0 || ospreyuart[x] == nil)
		return 1;
	return ospreyselectready(p, 0, 3) >= 0;
}

/*
 * A select waits here.  The arms it offered stay in the shared span, so
 * the predicate looks at them again each time rather than at a snapshot:
 * an arm may have been turned off, or its ring filled, while we slept.
 */
typedef struct Selwait Selwait;
struct Selwait {
	Ospreyproc *p;
	uvlong	armoff;
	int	narms;
};

static int
ospreyselok(void *a)
{
	Selwait *w = a;

	return ospreyindex(w->p) < 0
		|| ospreyselectready(w->p, w->armoff, w->narms) != -1;
}

static int
ospreyhaswork(void *a)
{
	Ospreyproc *p = a;

	return ospreyindex(p) < 0 || ospreyrequestready(p);
}

/*
 * Wake the service process of any container that has a request waiting,
 * and of no other.  Waking them all is what a service process itself
 * would do at the end of its round, and then each of the others would
 * wake all of them again: eight idle containers kept a core busy that
 * way.
 */
static void
ospreywakeservers(int except)
{
	Ospreyproc *q;
	int i;

	for(i = 0; i < nelem(ospreyservrend); i++)
		if(i != except && ospreyserving[i] && (q = ospreyat(i)) != nil
		&& ospreyrequestready(q))
			wakeup(&ospreyservrend[i]);
}

/*
 * A container's service process.  It answers requests from that
 * container's ring and sleeps when there are none; the clock wakes it
 * when a process that has mapped the ring puts one there, so an ordinary
 * request costs the caller no trap at all.  It runs in the namespace of
 * whoever asked for it, which is where a container's file names mean
 * what they say.
 */
static void
ospreyserver(void *a)
{
	Ospreyproc *p = a;
	Pgrp *pg;
	uvlong myid;
	int x, myx;

	/*
	 * The slot and the container are remembered here: once the
	 * container has gone, ospreyindex says nothing, and the flag that
	 * says a server is running for this slot would never be cleared.
	 * A slot left marked that way takes no new server ever again, and
	 * says nothing about it either.
	 */
	myx = ospreyindex(p);
	myid = ospreyid(p);

	/*
	 * kproc leaves a kernel process in the shared kernel name space,
	 * where a container's file names mean nothing.  Take the name space
	 * of the process that asked for the server instead; it already
	 * holds the reference for us.
	 */
	if((x = ospreyindex(p)) >= 0 && (pg = ospreypgrp[x]) != nil){
		ospreypgrp[x] = nil;
		closepgrp(up->pgrp);
		up->pgrp = pg;
	}

	if(waserror())
		goto done;
	for(;;){
		if((x = ospreyindex(p)) < 0)
			break;
		qlock(&ospreylock);
		if(waserror()){
			qunlock(&ospreylock);
			break;
		}
		while(ospreyservicep(p, fastticks(nil)) > 0)
			;
		ospreyroute(p);
		poperror();
		qunlock(&ospreylock);
		ospreywakeup();
		/* a request routed to somebody else's ring is theirs to answer */
		ospreywakeservers(x);
		if(ospreyindex(p) < 0)
			break;
		sleep(&ospreyservrend[x], ospreyhaswork, p);
	}
	poperror();
done:
	if(myx >= 0 && myx < nelem(ospreyserving)
	&& ospreyservingid[myx] == myid)
		ospreyserving[myx] = 0;
	pexit("osprey server", 1);
}

static void
ospreyclock(int core)
{
	Ospreyproc *p;
	Proc *q;
	uvlong now, d;
	int i;

	if(ospreybase == nil || core < 0 || core >= nelem(ospreylastticks))
		return;
	now = fastticks(nil);
	d = now - ospreylastticks[core];
	ospreylastticks[core] = now;
	if(ospreyhz != 0 && d > ospreyhz)
		d = ospreyhz;

	q = m->proc;
	ospreytick(core, q != nil ? q->osprey : nil, d, now);

	/*
	 * Hand this tick to any container that asked for it, the way a
	 * device interrupt hands work to the task that serves it: give a
	 * semaphore and wake whoever is waiting on it.  The interrupt does
	 * no more than that; the task runs in the scheduler like any other.
	 */
	for(i = 0; i < nelem(ospreyticksem); i++){
		if(ospreyticksem[i] < 0)
			continue;
		if((p = ospreyat(i)) == nil || ospreycoreof(p) != (ulong)core)
			continue;
		ospreysemgive(p, ospreyticksem[i]);
		wakeup(&ospreyselrend[i]);
		wakeup(&ospreyservrend[i]);
	}

	/*
	 * Wake the service process of any container that has a request
	 * waiting.  A process that submitted through the mapped ring never
	 * entered the kernel, so the clock is what notices.
	 */
	for(i = 0; i < nelem(ospreyservrend); i++)
		if(ospreyserving[i] && (p = ospreyat(i)) != nil
		&& ospreyrequestready(p))
			wakeup(&ospreyservrend[i]);

	/*
	 * Stop a throttled container's process until its period refills.
	 * procctl is examined on the way out of every trap, so a process
	 * that has run out of budget stops at the end of this very clock
	 * interrupt, and a budget is a limit rather than a preference.
	 * Only processes stopped here are started again here.
	 */
	for(i = 0; i < nelem(ospreyprocs); i++){
		if((q = ospreyprocs[i]) == nil)
			continue;
		if((p = q->osprey) == nil){
			/*
			 * pexit cleared it, so the process is gone and its
			 * Proc will be handed to another pid.  Let go of it
			 * here rather than leave a stale stop behind.
			 */
			ospreystopped[i] = 0;
			ospreyprocs[i] = nil;
			continue;
		}
		/* the container's own core decides, so the cores do not fight */
		if(ospreycoreof(p) != (ulong)core)
			continue;
		if(ospreystrict(p)){
			/*
			 * Held to the reservation: the process stops when it
			 * is spent and starts again when the period refills.
			 */
			if(ospreythrottled(p)){
				if(ospreystopped[i] == 0 && q->state != Stopped
				&& q->state != Dead && q->state != Moribund){
					ospreystopped[i] = 1;
					q->procctl = Proc_stopme;
					if(q == m->proc)
						q->delaysched++;
				}
			} else if(ospreystopped[i])
				ospreyrelease(q, i);
		} else {
			/*
			 * Best effort past the reservation: the process keeps
			 * the core when nothing with time left wants it, and
			 * the time it takes is counted apart.
			 */
			if(ospreystopped[i])
				ospreyrelease(q, i);
			if(ospreyover(p)){
				if(q->fixedpri == 0){
					procpriority(q, 0, 1);
					if(q == m->proc)
						q->delaysched++;
				}
			} else if(q->fixedpri)
				procpriority(q, PriNormal, 0);
		}
	}
}

static uvlong
ospreynow(void)
{
	return fastticks(&ospreyhz);
}

/*
 * Sleep predicates.  Both are read without the qlock, so they only look
 * at the ring indices the barrier already orders.  A container that has
 * gone away wakes its waiters so they can fail rather than hang.
 */
static int
ospreyroom(void *a)
{
	Ospreyproc *p = a;

	return ospreyindex(p) < 0 || !ospreyrequestfull(p);
}

static int
ospreyreply(void *a)
{
	Ospreyproc *p = a;

	return ospreyindex(p) < 0 || ospreyreplyready(p);
}

static void
ospreywakeup(void)
{
	int i;

	for(i = 0; i < nelem(ospreyroomrend); i++){
		wakeup(&ospreyroomrend[i]);
		wakeup(&ospreyreplyrend[i]);
		wakeup(&ospreyselrend[i]);
	}
}

/*
 * Name every part of the span: a segment for each container's slice and
 * one for each page.  They are published once, when the span is made.
 */
/*
 * Whether this process may attach one of these segments.  A container's
 * memory is the process bound to it and the processes it started; a page
 * is whichever container holds it.  Nothing else may have either, so a
 * name is a capability and not merely a name.
 */
static int
ospreyentitled(int slot)
{
	Proc *q, *r;
	int i;

	if(slot < 0 || slot >= nelem(ospreyprocs))
		return 0;
	/*
	 * Whoever the container is for may have it, wherever they are
	 * running; so may the process bound to it and the processes that
	 * one started, which is how a container reaches its own memory
	 * before anyone has been named.
	 */
	if(ospreymay(ospreyat(slot), up != nil ? up->user : nil))
		return 1;
	if((q = ospreyprocs[slot]) == nil)
		return 0;
	for(r = up, i = 0; r != nil && i < 64; r = r->parent, i++)
		if(r == q)
			return 1;
	return 0;
}

static int
ospreysegentitled(char *name)
{
	Ospreyproc *p;
	uvlong off;
	int i, n;

	if(strncmp(name, "osprey", 6) != 0)
		return 1;		/* not ours to say */
	name += 6;
	if(strncmp(name, "page", 4) == 0){
		off = ospreypageoff(strtoul(name+4, nil, 10));
		if(off == ~0ULL)
			return 0;
		for(i = 0; i < ospreynproc(); i++)
			if((p = ospreyat(i)) != nil && ospreyholdspage(p, off))
				return ospreyentitled(i);
		return 0;	/* a page nobody holds is nobody's */
	}
	n = (int)strtoul(name, nil, 10);
	return ospreyentitled(n);
}

static void
ospreypublish(void)
{
	Ospreyproc *p;
	Physseg *ps;
	uvlong off, n, sz;
	int i;

	sz = ospreyslicesize();
	for(i = 0; i < ospreynproc(); i++){
		if((p = ospreyat(i)) == nil)
			continue;
		USED(p);
	}
	/*
	 * The containers do not exist yet, so their segments are named
	 * from the same rule the adapter uses.
	 */
	for(i = 0; i < ospreynproc() && ospreynseg < nelem(ospreyseg); i++){
		ps = &ospreyseg[ospreynseg];
		ps->attr = SG_PHYSICAL;
		ps->name = smalloc(16);
		snprint(ps->name, 16, "osprey%d", i);
		ps->pa = PADDR(ospreybase) + (uvlong)i*sz;
		ps->size = sz;
		if(addphysseg(ps) != nil)
			ospreynseg++;
	}
	off = (uvlong)ospreynproc() * sz;
	off = (off + BY2PG-1) & ~((uvlong)BY2PG-1);
	for(n = 0; ospreynseg < nelem(ospreyseg); n++){
		if(off + (n+1)*BY2PG > ospreyarenasize())
			break;
		ps = &ospreyseg[ospreynseg];
		ps->attr = SG_PHYSICAL;
		ps->name = smalloc(16);
		snprint(ps->name, 16, "ospreypage%llud", n);
		ps->pa = PADDR(ospreybase) + off + n*BY2PG;
		ps->size = BY2PG;
		if(addphysseg(ps) != nil)
			ospreynseg++;
	}
}

static void
ospreyinit(void)
{
	uvlong size;
	int i;

	if(ospreybase != nil)
		return;
	size = PGROUND(ospreyarenasize());
	ospreybase = xspanalloc(size, BY2PG, 0);
	if(ospreybase == nil)
		return;
	if(ospreyarena(ospreybase, size) < 0){
		ospreybase = nil;
		return;
	}
	ospreypublish();

	if(ospreyncore() > nelem(ospreycorelock)){
		print("osprey: %d cores but %d locks\n",
			ospreyncore(), (int)nelem(ospreycorelock));
		return;
	}
	fastticks(&ospreyhz);
	for(i = 0; i < nelem(ospreyticksem); i++)
		ospreyticksem[i] = -1;
	ospreyuartintr = ospreyuartgive;
	ospreyetheriq = ospreyethergive;
	ospreysegok = ospreysegentitled;
	ospreypktdirect = ospreycountdirect;
	ospreypktcopied = ospreycountcopied;
	ospreyreset();		/* so no tick can find it uninitialised */
	ospreytimer = ospreyclock;
}

/*
 * The operations that need a Chan.  They run in the namespace of whatever
 * process drove the dispatcher, which is the process that wrote service to
 * ctl; a container does not yet have a namespace of its own beyond the
 * name table the policy layer keeps.  Each one catches its own errors so
 * that a failed request becomes a reply rather than unwinding the service
 * loop with the request already off the ring.
 */
long
ospreykernop(Ospreyproc *p, uvlong op, uvlong *arg, uvlong *result)
{
	char *a, *e;
	Chan *c;
	void *bl;
	ulong blen;
	long n;
	int i, x;

	if((x = ospreyindex(p)) < 0 || x >= nelem(ospreyfd))
		return StatusError;

	switch(op){
	case OpOpen:
		if((a = ospreydata(p, arg[0], 1)) == nil)
			return StatusError;
		n = ospreydatalen(p) - arg[0];
		if(n > Namelen)
			n = Namelen;
		if((e = memchr(a, 0, n)) == nil || e == a)
			return StatusError;
		for(i = 0; i < Nfd; i++)
			if(ospreyfd[x][i] == nil)
				break;
		if(i == Nfd)
			return StatusError;
		if(waserror())
			return StatusError;
		c = namec(a, Aopen, (int)arg[1], 0);
		poperror();
		ospreyfd[x][i] = c;
		result[0] = i;
		return StatusDone;

	case OpRead:
	case OpWrite:
		i = (int)arg[0];
		if(i < 0 || i >= Nfd || (c = ospreyfd[x][i]) == nil)
			return StatusError;
		n = (long)arg[2];
		if(n < 0 || (a = ospreydata(p, arg[1], n)) == nil)
			return StatusError;
		if(waserror())
			return StatusError;
		if(op == OpRead)
			n = devtab[c->type]->read(c, a, n, c->offset);
		else
			n = devtab[c->type]->write(c, a, n, c->offset);
		poperror();
		c->offset += n;
		result[0] = n;
		return StatusDone;

	case OpStat:
		i = (int)arg[0];
		if(i < 0 || i >= Nfd || (c = ospreyfd[x][i]) == nil)
			return StatusError;
		n = (long)arg[2];
		if(n < 0 || (a = ospreydata(p, arg[1], n)) == nil)
			return StatusError;
		if(waserror())
			return StatusError;
		n = devtab[c->type]->stat(c, (uchar*)a, n);
		poperror();
		result[0] = n;
		return StatusDone;

	case OpRecv:
		/*
		 * Take the next packet the interface gave this container and
		 * answer with where it is in the span and how long it is.
		 * The card wrote it there; nothing copies it.  The buffer is
		 * the container's until it asks for the next packet, which
		 * is when the one before it goes back to the interface.
		 */
		if((x = ospreyindex(p)) < 0 || x >= nelem(ospreyheld))
			return StatusError;
		if(ospreyheld[x] != nil){
			freeb(ospreyheld[x]);
			ospreyheld[x] = nil;
		}
		if(ospreypktget(p, &bl, &blen) < 0)
			return StatusError;
		ospreyheld[x] = bl;
		result[0] = ospreyoff_at(p, ((Block*)bl)->rp);
		result[1] = blen;
		if(result[0] == ~0ULL)
			return StatusError;
		return StatusDone;

	case OpClose:
		i = (int)arg[0];
		if(i < 0 || i >= Nfd || (c = ospreyfd[x][i]) == nil)
			return StatusError;
		ospreyfd[x][i] = nil;
		if(waserror())
			return StatusError;
		cclose(c);
		poperror();
		return StatusDone;
	}
	return StatusError;
}

/* drop every chan a container still holds */
/* let go of the process a container was billing */
/* undo a stop this device imposed, so nothing is left frozen */
static void
ospreyrelease(Proc *q, int x)
{
	int s;

	if(x < 0 || x >= nelem(ospreystopped))
		return;
	ospreystopped[x] = 0;
	if(q == nil)
		return;
	/*
	 * splhi so the tick on this core cannot be part way through the
	 * same decision.  A tick on another core can still be, but it
	 * checks the state too, and the worst of losing that race is the
	 * diagnostic ready() prints for a process already queued.
	 */
	s = splhi();
	if(q->procctl == Proc_stopme)
		q->procctl = 0;
	if(q->state == Stopped){
		q->procctl = 0;
		ready(q);
	}
	splx(s);
}

/*
 * Let go of an interface a container had claimed.  The card takes its
 * receive buffers from that container's slice, so leaving the pool
 * named after the container has gone would have it writing packets into
 * memory that belongs to whatever comes next.
 */
static void
ospreyputether(Ospreyproc *p)
{
	int x;

	if((x = ospreyindex(p)) < 0 || x >= nelem(ospreyether))
		return;
	if(ospreyether[x] != nil){
		((Ether*)ospreyether[x])->rbpool = nil;
		ospreyether[x] = nil;
	}
	if(ospreyheld[x] != nil){
		freeb(ospreyheld[x]);
		ospreyheld[x] = nil;
	}
	wakeup(&ospreyselrend[x]);
}

/* and a uart, which is left quiet rather than interrupting nobody */
static void
ospreyputuart(Ospreyproc *p)
{
	Uart *u;
	int x;

	if((x = ospreyindex(p)) < 0 || x >= nelem(ospreyuart))
		return;
	if((u = ospreyuart[x]) != nil){
		ospreyuart[x] = nil;
		ospreyuartlen[x] = 0;
		if(u->phys->taskenable != nil)
			(*u->phys->taskenable)(u, 0);
		if(u->phys->intrmask != nil)
			(*u->phys->intrmask)(u, 1);
	}
	wakeup(&ospreyselrend[x]);
}

/* let go of a container's service process */
static void
ospreyputserver(Ospreyproc *p)
{
	int x;

	if((x = ospreyindex(p)) < 0 || x >= nelem(ospreyservrend))
		return;
	ospreyticksem[x] = -1;
	wakeup(&ospreyservrend[x]);
	wakeup(&ospreyselrend[x]);
}

static void
ospreyputproc(Ospreyproc *p)
{
	Proc *q;
	int x;

	if((x = ospreyindex(p)) < 0 || x >= nelem(ospreyprocs))
		return;
	if((q = ospreyprocs[x]) != nil){
		if(q->fixedpri)
			procpriority(q, PriNormal, 0);
		ospreyrelease(q, x);
		q->osprey = nil;
		ospreyprocs[x] = nil;
	}
}

static void
ospreyclosefds(Ospreyproc *p)
{
	Chan *c;
	int i, x;

	if((x = ospreyindex(p)) < 0 || x >= nelem(ospreyfd))
		return;
	for(i = 0; i < Nfd; i++)
		if((c = ospreyfd[x][i]) != nil){
			ospreyfd[x][i] = nil;
			if(waserror())
				continue;
			cclose(c);
			poperror();
		}
}

static Ospreyproc*
ospreyproc(char *s)
{
	Ospreyproc *p;

	p = ospreylookup(strtoull(s, nil, 0));
	if(p == nil)
		error(Enonexist);
	return p;
}

/*
 * The container that name says, if it is the caller's to touch.  A
 * container is for whoever it is for, which the kernel enforced at a
 * segment and at a pi-p open and not here: anyone who could write ctl
 * could take another user's pages, stop its process or destroy it
 * outright.
 */
static Ospreyproc*
ospreymine(char *name)
{
	Ospreyproc *p;

	p = ospreyproc(name);
	if(!ospreymay(p, up != nil ? up->user : nil))
		error(Eperm);
	return p;
}

static Chan*
ospreyattachdev(char *spec)
{
	return devattach('O', spec);
}

static Walkqid*
ospreywalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, ospreydir, nelem(ospreydir), devgen);
}

static int
ospreystat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, ospreydir, nelem(ospreydir), devgen);
}

static Chan*
ospreyopen(Chan *c, int omode)
{
	return devopen(c, omode, ospreydir, nelem(ospreydir), devgen);
}

static void
ospreyclose(Chan *c)
{
	/* a ticket is the chan's own; the pip session is not */
	if(((ulong)c->qid.path == Qticket
	|| (ulong)c->qid.path == Qbench) && c->aux != nil){
		free(c->aux);
		c->aux = nil;
	}
}


static uvlong
pipget(uchar *p, int n)
{
	uvlong v;
	int i;

	v = 0;
	for(i = n; i-- > 0; )
		v = (v<<8) | p[i];
	return v;
}

static void
pipput(uchar *p, int n, uvlong v)
{
	int i;

	for(i = 0; i < n; i++, v >>= 8)
		p[i] = v;
}

static Pipsession*
pipfind(uvlong sid)
{
	int i;

	for(i = 0; i < Nsession; i++)
		if(pipsession[i].used && pipsession[i].sid == sid)
			return &pipsession[i];
	return nil;
}

/*
 * Who a session asks as.  A ticket says so and is signed; without one it
 * is whoever the transport says, which on a wire is nobody -- a frame
 * may say anything, so it says nothing.
 */
static char*
pipwho(Pipsession *ps)
{
	if(ps->user[0] != '\0')
		return ps->user;
	return pipviafile && up != nil ? up->user : nil;
}

/*
 * Whether the container a fid names is still that session's to have.
 * Asked again at every use, not only at the open: a grant taken back
 * while a fid is open takes effect at the next thing done with it.
 */
static int
pipstill(Pipsession *ps, Pipfid *f)
{
	if(f->id == 0)		/* the root is nobody's */
		return 1;
	if(!ospreymay(ospreylookup(f->id), pipwho(ps)))
		return 0;
	if(ps->user[0] != '\0' && ps->authid != f->id)
		return 0;
	return 1;
}

static Pipfid*
pipfid(Pipsession *ps, ulong fid)
{
	int i;

	for(i = 0; i < Nfid; i++)
		if(ps->fid[i].used && ps->fid[i].fid == fid)
			return &ps->fid[i];
	return nil;
}

static Pipfid*
pipnewfid(Pipsession *ps, ulong fid)
{
	int i;

	if(pipfid(ps, fid) != nil)
		return nil;
	for(i = 0; i < Nfid; i++)
		if(ps->fid[i].used == 0){
			memset(&ps->fid[i], 0, sizeof ps->fid[i]);
			ps->fid[i].used = 1;
			ps->fid[i].fid = fid;
			ps->fid[i].lease = pipnow() + Pipfidlease;
			return &ps->fid[i];
		}
	return nil;
}

/*
 * A fid's own version of an attribute, if it has written one.  What a
 * fid writes is its own until the fid is closed.
 */
static char*
pipdraft(Pipfid *f, char *name)
{
	int i;

	for(i = 0; i < f->nval; i++)
		if(strcmp(f->name[i], name) == 0)
			return f->val[i];
	return nil;
}

static int
pipsetdraft(Pipfid *f, char *name, char *val)
{
	int i;

	if(strlen(val) >= sizeof f->val[0] || strlen(name) >= sizeof f->name[0])
		return -1;
	for(i = 0; i < f->nval; i++)
		if(strcmp(f->name[i], name) == 0)
			break;
	if(i == f->nval){
		if(f->nval >= nelem(f->name))
			return -1;
		f->nval++;
		strcpy(f->name[i], name);
	}
	strcpy(f->val[i], val);
	f->dirty = 1;
	return 0;
}

/*
 * Commit what a fid has written, all of it or none of it.  A version
 * made from one that has since been committed over is refused: what it
 * was written against is not what is there any more.
 */
static int
pipcommit(Pipfid *f, uvlong *version)
{
	Ospreyproc *p;
	int i;

	*version = 0;
	if(f->dirty == 0 || f->id == 0)
		return 0;
	if((p = ospreylookup(f->id)) == nil)
		return -1;
	if(ospreyversion(p) != f->base)
		return -1;
	for(i = 0; i < f->nval; i++)
		if(ospreysetattr(p, f->name[i], f->val[i]) < 0)
			return -1;
	*version = ospreyversion(p);
	return 0;
}

/* room for one more reply, and where it goes */
static uchar*
pipreply(Pipsession *ps, int type, int tag, long n)
{
	uchar *r;

	if(ps->nreply + Pipheader + n > sizeof ps->reply){
		/*
		 * Saying nothing here would answer a group with fewer
		 * replies than it had messages, and the client would match
		 * them up wrongly.  The group is answered with one error
		 * instead; pipfits does that.
		 */
		ps->overflow = 1;
		return nil;
	}
	r = ps->reply + ps->nreply;
	pipput(r, 4, Pipheader + n);
	r[4] = type;
	pipput(r+5, 2, tag);
	ps->nreply += Pipheader + n;
	return r + Pipheader;
}

/*
 * Whether what a group produced can be sent.  A reply that did not fit
 * the buffer, or a whole reply that will not fit the transport carrying
 * it, is replaced by one error: a client is better told than handed
 * half of what it asked for.
 */
static void piperror(Pipsession*, int, char*);

static long
pipfits(Pipsession *ps, long room)
{
	if(ps->overflow == 0 && (room <= 0 || ps->nreply <= room))
		return ps->nreply;
	ps->nreply = ps->rp = 0;
	ps->overflow = 0;
	piperror(ps, 0, "the replies to that group do not fit");
	return ps->nreply;
}

static void
piperror(Pipsession *ps, int tag, char *e)
{
	uchar *r;
	long n;

	n = strlen(e);
	if(n > Pipmaxname)
		n = Pipmaxname;
	if((r = pipreply(ps, PipRerror, tag, 2 + n)) == nil)
		return;
	pipput(r, 2, n);
	memmove(r+2, e, n);
}

/* the name a PipTopen walks: empty or / is the root, /N or N a container */
static uvlong
pipwalk(char *name, long n)
{
	char buf[32];
	long i;

	while(n > 0 && *name == '/')
		name++, n--;
	if(n == 0)
		return 0;
	if(n >= sizeof buf)
		return ~0ULL;
	for(i = 0; i < n; i++){
		if(name[i] < '0' || name[i] > '9')
			return ~0ULL;
		buf[i] = name[i];
	}
	buf[n] = 0;
	return strtoull(buf, nil, 10);
}

/*
 * One T message.  Returns the bytes it consumed, or -1 if the group is
 * malformed and nothing more of it can be trusted.
 */
static long
pipmsg(Pipsession **psp, uchar *m, long n)
{
	Pipsession *ps;
	Pipfid *f, *nf;
	Ospreyproc *p;
	char attr[Pipmaxname+1], val[Pipmaxname+1];
	uchar *r;
	uvlong sz, sid, id;
	long alen, vlen, cnt, k;
	ulong fid, nfid;
	int type, tag, i;

	if(n < Pipheader)
		return -1;
	sz = pipget(m, 4);
	if(sz < Pipheader || sz > n)
		return -1;
	type = m[4];
	tag = pipget(m+5, 2);
	ps = *psp;

	if(type == PipTsession){
		if(sz < Pipheader + 8)
			return -1;
		sid = pipget(m+Pipheader, 8);
		pipexpire();
		if(sid != 0){
			if((ps = pipfind(sid)) == nil){
				if(*psp == nil)
					return -1;
				piperror(*psp, tag, "no such session");
				return sz;
			}
		} else {
			for(i = 0; i < Nsession; i++)
				if(pipsession[i].used == 0)
					break;
			if(i == Nsession){
				if(*psp != nil)
					piperror(*psp, tag, "no free sessions");
				return sz;
			}
			ps = &pipsession[i];
			memset(ps, 0, sizeof *ps);
			ps->used = 1;
			/*
			 * not in order: a session carries what a ticket
			 * proved, so a sid that can be guessed is a way in.
			 */
			randomread(&ps->sid, sizeof ps->sid);
			if(ps->sid == 0)
				ps->sid = pipnextsid;
			pipnextsid++;
		}
		ps->lease = pipnow() + Pipsesslease;	/* renegotiated */
		*psp = ps;
		ps->nreply = ps->rp = 0;	/* this group's replies */
		ps->overflow = 0;
		if((r = pipreply(ps, PipRsession, tag, 8)) != nil)
			pipput(r, 8, ps->sid);
		return sz;
	}

	if(ps == nil)
		return -1;

	switch(type){
	case PipTopen:
		if(sz < Pipheader + 4+4+1+2)
			return -1;
		fid = pipget(m+Pipheader, 4);
		nfid = pipget(m+Pipheader+4, 4);
		k = Pipheader + 4+4+1;
		alen = pipget(m+k, 2);
		k += 2;
		if(k + alen > sz)
			return -1;
		USED(fid);
		id = pipwalk((char*)m+k, alen);
		if(id == ~0ULL){
			piperror(ps, tag, "bad name");
			break;
		}
		if(id != 0 && ospreylookup(id) == nil){
			piperror(ps, tag, "no such container");
			break;
		}
		/*
		 * Who is asking.  A ticket says so and is signed; without
		 * one it is whoever the transport says, which on a wire is
		 * nobody -- a frame may say anything, so it says nothing.
		 */
		if(id != 0){
			if(!ospreymay(ospreylookup(id), pipwho(ps))){
				piperror(ps, tag, "not yours");
				break;
			}
			if(ps->user[0] != '\0' && ps->authid != id){
				piperror(ps, tag, "ticket is for another container");
				break;
			}
		}
		if((nf = pipnewfid(ps, nfid)) == nil){
			piperror(ps, tag, "fid in use or no free fids");
			break;
		}
		nf->id = id;
		nf->open = 1;
		nf->base = id == 0 ? 0 : ospreyversion(ospreylookup(id));
		if((r = pipreply(ps, PipRopen, tag, 24)) != nil){
			pipput(r, 8, id);
			pipput(r+8, 8, nf->base);
			pipput(r+16, 8, nf->lease - pipnow());
		}
		break;

	case PipTread:
		if(sz < Pipheader + 4+4+2)
			return -1;
		fid = pipget(m+Pipheader, 4);
		cnt = pipget(m+Pipheader+4, 4);
		k = Pipheader + 8;
		alen = pipget(m+k, 2);
		k += 2;
		if(k + alen > sz || alen > Pipmaxname)
			return -1;
		memmove(attr, m+k, alen);
		attr[alen] = 0;
		if((f = pipfid(ps, fid)) == nil || f->open == 0){
			piperror(ps, tag, "fid not open");
			break;
		}
		if(!pipstill(ps, f)){
			piperror(ps, tag, "not yours");
			break;
		}
		if(f->id == 0){
			/* the root: its attribute is the list of containers */
			if(strcmp(attr, "*") != 0){
				piperror(ps, tag, "no such attribute");
				break;
			}
			k = 0;
			for(p = ospreynext(nil); p != nil; p = ospreynext(p))
				k += snprint(val+k, sizeof val - k,
					k == 0 ? "%llud" : " %llud", ospreyid(p));
			if(cnt >= 0 && k > cnt)
				k = cnt;
			if((r = pipreply(ps, PipRread, tag, 8+2+k)) != nil){
				pipput(r, 8, 0);
				pipput(r+8, 2, k);
				memmove(r+10, val, k);
			}
			break;
		}
		if((p = ospreylookup(f->id)) == nil){
			piperror(ps, tag, "container is gone");
			break;
		}
		{
			char *b, *s;

			b = smalloc(Pipmaxmsg/2);
			if(waserror()){
				free(b);
				nexterror();
			}
			s = pipdraft(f, attr);
			k = s != nil ? snprint(b, Pipmaxmsg/2, "%s", s)
				: ospreyattr(p, attr, b, Pipmaxmsg/2);
			if(k < 0)
				piperror(ps, tag, "no such attribute");
			else {
				if(cnt >= 0 && k > cnt)
					k = cnt;
				if((r = pipreply(ps, PipRread, tag, 8+2+k)) != nil){
					pipput(r, 8, f->dirty ? f->base + 1
						: ospreyversion(p));
					pipput(r+8, 2, k);
					memmove(r+10, b, k);
				}
			}
			poperror();
			free(b);
		}
		break;

	case PipTwrite:
		if(sz < Pipheader + 4+2)
			return -1;
		fid = pipget(m+Pipheader, 4);
		k = Pipheader + 4;
		alen = pipget(m+k, 2);
		k += 2;
		if(k + alen > sz || alen > Pipmaxname)
			return -1;
		memmove(attr, m+k, alen);
		attr[alen] = 0;
		k += alen;
		if(k + 2 > sz)
			return -1;
		vlen = pipget(m+k, 2);
		k += 2;
		if(k + vlen > sz || vlen > Pipmaxname)
			return -1;
		memmove(val, m+k, vlen);
		val[vlen] = 0;
		if((f = pipfid(ps, fid)) == nil || f->open == 0 || f->id == 0){
			piperror(ps, tag, "fid not open");
			break;
		}
		if(!pipstill(ps, f)){
			piperror(ps, tag, "not yours");
			break;
		}
		if((p = ospreylookup(f->id)) == nil){
			piperror(ps, tag, "container is gone");
			break;
		}
		USED(p);
		if(!ospreyattrwritable(attr)){
			piperror(ps, tag, "attribute is not writable");
			break;
		}
		if(pipsetdraft(f, attr, val) < 0){
			piperror(ps, tag, "no room for another attribute");
			break;
		}
		if((r = pipreply(ps, PipRwrite, tag, 8)) != nil)
			pipput(r, 8, f->base + 1);
		break;

	case PipTclose:
		if(sz < Pipheader + 4)
			return -1;
		fid = pipget(m+Pipheader, 4);
		if((f = pipfid(ps, fid)) == nil){
			piperror(ps, tag, "no such fid");
			break;
		}
		if(f->dirty && !pipstill(ps, f)){
			/* what it may not have, it may not commit over */
			f->used = 0;
			piperror(ps, tag, "not yours");
			break;
		}
		if(pipcommit(f, &sid) < 0){
			f->used = 0;
			piperror(ps, tag, "what it was written against has changed");
			break;
		}
		f->used = 0;
		if((r = pipreply(ps, PipRclose, tag, 8)) != nil)
			pipput(r, 8, sid);
		break;

	case PipTlease:
		if(sz < Pipheader + 4)
			return -1;
		fid = pipget(m+Pipheader, 4);
		if((f = pipfid(ps, fid)) == nil){
			piperror(ps, tag, "no such fid");
			break;
		}
		f->lease = pipnow() + Pipfidlease;
		ps->lease = pipnow() + Pipsesslease;
		if((r = pipreply(ps, PipRlease, tag, 8)) != nil)
			pipput(r, 8, (uvlong)Pipfidlease);
		break;

	case PipTauth:
		if(sz < Pipheader + 2)
			return -1;
		alen = pipget(m+Pipheader, 2);
		if(Pipheader + 2 + alen > sz || alen > Pipmaxname){
			piperror(ps, tag, "bad ticket");
			break;
		}
		{
			char t[Ticketlen], who[Pipmaxname+1];
			uvlong who_id;

			if(alen >= sizeof t){
				piperror(ps, tag, "bad ticket");
				break;
			}
			memmove(t, m+Pipheader+2, alen);
			t[alen] = '\0';
			if(ospreyticketok(t, who, sizeof who, &who_id) < 0){
				ps->user[0] = '\0';
				ps->authid = 0;
				piperror(ps, tag, "ticket does not check out");
				break;
			}
			strncpy(ps->user, who, sizeof ps->user - 1);
			ps->user[sizeof ps->user - 1] = '\0';
			ps->authid = who_id;
			k = strlen(ps->user);
			if((r = pipreply(ps, PipRauth, tag, 2+k)) != nil){
				pipput(r, 2, k);
				memmove(r+2, ps->user, k);
			}
		}
		break;

	case PipTstream:
		if(sz < Pipheader + 4+4+4+2)
			return -1;
		fid = pipget(m+Pipheader, 4);
		k = Pipheader + 4;
		{
			uvlong period;
			long count;
			int j, slot;

			period = pipget(m+k, 4);
			count = (long)pipget(m+k+4, 4);
			k += 8;
			alen = pipget(m+k, 2);
			k += 2;
			if(k + alen > sz || alen > Pipmaxname)
				return -1;
			memmove(attr, m+k, alen);
			attr[alen] = 0;
			if((f = pipfid(ps, fid)) == nil || f->open == 0){
				piperror(ps, tag, "fid not open");
				break;
			}
			if(!pipstill(ps, f)){
				piperror(ps, tag, "not yours");
				break;
			}
			/* one stream to a fid: a second says what the first said */
			slot = -1;
			for(j = 0; j < Pipmaxstream; j++){
				if(pipstream[j].used && pipstream[j].sid == ps->sid
				&& pipstream[j].fid == fid){
					slot = j;
					break;
				}
			}
			if(period == 0){
				if(slot >= 0)
					pipstream[slot].used = 0;
				if((r = pipreply(ps, PipRstream, tag, 8)) != nil)
					pipput(r, 8, 0);
				break;
			}
			if(pipetherchan == nil){
				piperror(ps, tag, "no wire to stream on");
				break;
			}
			if(slot < 0){
				for(j = 0; j < Pipmaxstream; j++)
					if(pipstream[j].used == 0){
						slot = j;
						break;
					}
			}
			if(slot < 0){
				piperror(ps, tag, "no room for another stream");
				break;
			}
			memset(&pipstream[slot], 0, sizeof(Pipstream));
			pipstream[slot].used = 1;
			pipstream[slot].sid = ps->sid;
			pipstream[slot].fid = fid;
			pipstream[slot].tag = tag;
			pipstream[slot].period = period;
			pipstream[slot].left = count == 0 ? -1 : count;
			pipstream[slot].due = pipnow() + period;
			strncpy(pipstream[slot].attr, attr, Pipmaxname);
			memmove(pipstream[slot].ea, pipfrom, 6);
			if((r = pipreply(ps, PipRstream, tag, 8)) != nil)
				pipput(r, 8, period);
		}
		break;

	default:
		piperror(ps, tag, "unknown message");
		break;
	}
	return sz;
}

/*
 * What a stream carries: the same value a PipTread would have answered
 * with, without the request.
 */
static long
pipstreamvalue(Pipstream *st, char *b, long nb, uvlong *version)
{
	Pipsession *ps;
	Pipfid *f;
	void *p;
	char *s;
	long k;
	int i;

	ps = nil;
	for(i = 0; i < Nsession; i++)
		if(pipsession[i].used && pipsession[i].sid == st->sid){
			ps = &pipsession[i];
			break;
		}
	if(ps == nil)
		return -1;
	if((f = pipfid(ps, st->fid)) == nil || f->open == 0)
		return -1;
	if(!pipstill(ps, f))		/* a grant taken back stops the stream */
		return -1;
	if(f->id == 0){
		if(strcmp(st->attr, "*") != 0)
			return -1;
		k = 0;
		for(p = ospreynext(nil); p != nil; p = ospreynext(p))
			k += snprint(b+k, nb-k, k == 0 ? "%llud" : " %llud",
				ospreyid(p));
		*version = 0;
		return k;
	}
	if((p = ospreylookup(f->id)) == nil)
		return -1;
	s = pipdraft(f, st->attr);
	k = s != nil ? snprint(b, nb, "%s", s) : ospreyattr(p, st->attr, b, nb);
	if(k < 0)
		return -1;
	*version = f->dirty ? f->base + 1 : ospreyversion(p);
	return k;
}

/*
 * The rate.  Frames go out when they are due whatever the client is
 * doing; nothing is read to make them happen.
 */
static void
pipstreamer(void*)
{
	uchar *out;
	char *b;
	uvlong now, version;
	long k, n;
	int i;

	out = smalloc(Pipframe);
	b = smalloc(Pipmaxmsg/2);
	pipetherprocs++;
	while(pipserving){
		tsleep(&up->sleep, return0, nil, 5);
		qlock(&piplock);
		if(waserror()){
			qunlock(&piplock);
			continue;
		}
		pipexpire();	/* a stream lasts no longer than its fid */
		pipviafile = 0;	/* and asks as nobody's process, only its ticket */
		now = pipnow();
		for(i = 0; i < Pipmaxstream; i++){
			if(pipstream[i].used == 0 || pipstream[i].due > now)
				continue;
			k = pipstreamvalue(&pipstream[i], b, Pipmaxmsg/2, &version);
			if(k < 0){
				pipstream[i].used = 0;	/* what it named is gone */
				continue;
			}
			if(k > Pipframe - Etherhdr - Pipheader - 10)
				k = Pipframe - Etherhdr - Pipheader - 10;
			memmove(out, pipstream[i].ea, 6);
			memset(out+6, 0, 6);	/* the driver fills this in */
			out[12] = Pipethertype >> 8;
			out[13] = Pipethertype;
			n = Etherhdr;
			pipput(out+n, 4, Pipheader + 8+2+k);
			out[n+4] = PipRread;
			pipput(out+n+5, 2, pipstream[i].tag);
			n += Pipheader;
			pipput(out+n, 8, version);
			pipput(out+n+8, 2, k);
			memmove(out+n+10, b, k);
			n += 10 + k;
			while(n < Minframe)
				out[n++] = 0;
			if(pipetherchan != nil)
				devtab[pipetherchan->type]->write(pipetherchan,
					out, n, 0);
			pipstream[i].due += pipstream[i].period;
			if(pipstream[i].due <= now)
				pipstream[i].due = now + pipstream[i].period;
			if(pipstream[i].left > 0 && --pipstream[i].left == 0)
				pipstream[i].used = 0;
		}
		poperror();
		qunlock(&piplock);
	}
	free(b);
	free(out);
	pipetherprocs--;
	wakeup(&pipetherrend);
	pexit("osprey pip stream", 1);
}

/*
 * A group: as many T messages as were written at once, answered in one
 * reply the client reads next.  The session a group leaves off in is
 * remembered against the connection, so that a client need not name it
 * again in every group.
 */
static int
pipetherdone(void*)
{
	return pipetherchan == nil && pipetherprocs == 0;
}

/*
 * Forget every session and every stream.  What a session holds is a fid
 * on a container, and reset makes those containers into different ones
 * with the same numbers, so a session that outlived the reset would be
 * holding somebody else's.
 */
static void
pipreset(void)
{
	int i;

	qlock(&piplock);
	for(i = 0; i < Nsession; i++)
		pipsession[i].used = 0;
	for(i = 0; i < Pipmaxstream; i++)
		pipstream[i].used = 0;
	qunlock(&piplock);
}

/*
 * Answer pi-p on a wire.  Nothing here is a connection: a frame arrives
 * with a group in it, the group says which session it belongs to, and
 * the replies go back to whoever sent it.  That a session outlives a
 * connection is exactly what lets the protocol be its own transport.
 */
static void
pipetherserve(void *a)
{
	Chan *dc, *cc;
	uchar *in, *out;
	long n, r;
	char *ifc;

	ifc = a;

	in = nil;
	out = nil;
	dc = nil;
	cc = nil;
	if(waserror())
		goto done;
	in = smalloc(Pipframe);
	out = smalloc(Pipframe);
	dc = etherconv(ifc, Pipethertype, &cc);
	pipetherchan = dc;
	pipetherprocs++;
	kproc("ospreypipstream", pipstreamer, nil);
	while(pipserving){
		n = devtab[dc->type]->read(dc, in, Pipframe, 0);
		if(n <= Etherhdr)
			continue;
		qlock(&piplock);
		if(waserror()){
			qunlock(&piplock);
			nexterror();
		}
		pipexpire();
		pipviafile = 0;			/* a frame says nothing about who */
		memmove(pipfrom, in+6, 6);	/* for a stream to be sent to */
		r = pipserve(in+Etherhdr, n-Etherhdr,
			out+Etherhdr, Pipframe-Etherhdr);
		qunlock(&piplock);
		poperror();
		if(r <= 0)
			continue;
		memmove(out, in+6, 6);		/* back to whoever asked */
		memmove(out+6, in, 6);
		out[12] = Pipethertype >> 8;
		out[13] = Pipethertype;
		r += Etherhdr;
		while(r < Minframe)		/* shorter than this is refused */
			out[r++] = 0;
		devtab[dc->type]->write(dc, out, r, 0);
	}
	poperror();
done:
	pipserving = 0;
	/*
	 * the streamer writes on this chan, and only ever with the lock
	 * held, so taking it away under the lock is enough.
	 */
	qlock(&piplock);
	pipetherchan = nil;
	for(n = 0; n < Pipmaxstream; n++)
		pipstream[n].used = 0;
	qunlock(&piplock);
	wakeup(&pipetherrend);
	if(dc != nil)
		cclose(dc);
	if(cc != nil)
		cclose(cc);
	free(in);
	free(out);
	pipetherprocs--;
	wakeup(&pipetherrend);
	pexit("osprey pip", 1);
}

static long
pipwrite(Chan *c, uchar *m, long n)
{
	Pipsession *ps;
	long k, used;
	int i;

	qlock(&piplock);
	if(waserror()){
		qunlock(&piplock);
		nexterror();
	}
	pipviafile = 1;		/* the kernel knows who this process is */
	ps = (Pipsession*)c->aux;
	if(ps != nil && (ps->used == 0 || ps > &pipsession[Nsession-1]))
		ps = nil;
	if(ps != nil){
		ps->nreply = ps->rp = 0;
		ps->overflow = 0;
	}
	for(used = 0, i = 0; i < Pipmaxgroup && used < n; i++){
		k = pipmsg(&ps, m+used, n-used);
		if(k <= 0)
			break;
		used += k;
	}
	if(ps == nil)
		error("no session");
	pipfits(ps, 0);
	c->aux = ps;
	qunlock(&piplock);
	poperror();
	return n;
}

/*
 * A group carried by something that is not a connection: a datagram, say.
 * There is nothing to remember a session against, so the group says which
 * session it is -- which is what a session outliving its connection is
 * for -- and the replies go back the way the group came.
 */
/*
 * A conversation of our own on an interface, carrying one frame type.
 * The control file is held open for as long as the conversation lives.
 */
static Chan*
etherconv(char *ifc, int type, Chan **ccp)
{
	char buf[64], path[64];
	Chan *cc, *dc;
	long n;
	int cno;

	/*
	 * the chan the clone file hands back is the conversation's own ctl
	 * file, and the conversation lives exactly as long as it is held
	 * open.  close it and the connect is undone under you.
	 */
	snprint(path, sizeof path, "#l/%s/clone", ifc);
	cc = namec(path, Aopen, ORDWR, 0);
	if(waserror()){
		cclose(cc);
		nexterror();
	}
	n = devtab[cc->type]->read(cc, buf, sizeof buf - 1, 0);
	if(n <= 0)
		error(Eio);
	buf[n] = '\0';
	cno = atoi(buf);
	snprint(buf, sizeof buf, "connect %d", type);
	devtab[cc->type]->write(cc, buf, strlen(buf), 0);
	snprint(path, sizeof path, "#l/%s/%d/data", ifc, cno);
	dc = namec(path, Aopen, ORDWR, 0);
	poperror();
	*ccp = cc;
	return dc;
}

static long
pipserve(uchar *in, long n, uchar *out, long nout)
{
	Pipsession *ps;
	long used, k, r;
	int i;

	ps = nil;
	for(used = 0, i = 0; i < Pipmaxgroup && used < n; i++){
		k = pipmsg(&ps, in+used, n-used);
		if(k <= 0)
			break;
		used += k;
	}
	if(ps == nil)
		return 0;
	r = pipfits(ps, nout);
	if(r > nout)			/* even the error does not fit */
		return 0;
	memmove(out, ps->reply, r);
	ps->nreply = ps->rp = 0;
	return r;
}

static long
pipread(Chan *c, void *a, long n)
{
	Pipsession *ps;

	qlock(&piplock);
	ps = (Pipsession*)c->aux;
	if(ps == nil || ps->used == 0){
		qunlock(&piplock);
		return 0;
	}
	if(n > ps->nreply - ps->rp)
		n = ps->nreply - ps->rp;
	if(n < 0)
		n = 0;
	memmove(a, ps->reply + ps->rp, n);
	ps->rp += n;
	qunlock(&piplock);
	return n;
}

static long
/*
 * Whether these bytes of the span are the caller's to see.  A slice is
 * a container's and a page is whichever container holds it; a page
 * nobody holds is nobody's memory yet.  Without this the arena file
 * hands every container's memory to whoever can open it, which is the
 * whole of what a segment name being a capability was for.
 */
static int
ospreyspanmine(uvlong off, long n)
{
	Ospreyproc *p;
	uvlong slice, end, base;
	int i;

	slice = ospreyslicesize();
	if(slice == 0)
		return 0;
	for(end = off + n; off < end; off = base + slice){
		i = (int)(off / slice);
		base = (uvlong)i * slice;
		if(i >= ospreynproc()){
			/* the pages, past every slice */
			for(; off < end; off += BY2PG){
				p = nil;
				while((p = ospreynext(p)) != nil)
					if(ospreyholdspage(p, off & ~((uvlong)BY2PG-1))
					&& !ospreymay(p, up != nil ? up->user : nil))
						return 0;
			}
			return 1;
		}
		if((p = ospreyat(i)) != nil
		&& !ospreymay(p, up != nil ? up->user : nil))
			return 0;
	}
	return 1;
}

static long
ospreyarenaio(void *a, long n, vlong offset, int write)
{
	uvlong size;
	void *m;

	size = ospreyarenasize();
	if(offset < 0 || (uvlong)offset >= size)
		return 0;
	if(n > size - offset)
		n = size - offset;
	if(n <= 0)
		return 0;
	if(!ospreyspanmine(offset, n))
		error(Eperm);
	qlock(&ospreylock);
	if(waserror()){
		qunlock(&ospreylock);
		nexterror();
	}
	if((m = ospreyarenaaddr(offset, n)) == nil)
		n = 0;
	else if(write)
		memmove(m, a, n);
	else
		memmove(a, m, n);
	qunlock(&ospreylock);
	poperror();
	return n;
}

static long
ospreyarenaread(void *a, long n, vlong offset)
{
	return ospreyarenaio(a, n, offset, 0);
}

static long
ospreyread(Chan *c, void *a, long n, vlong offset)
{
	char *buf, *s, *e;
	uvlong op, now, arg[Ospreynarg];
	Ospreyproc *p;
	long status;

	switch((ulong)c->qid.path){
	case Qdir:
		return devdirread(c, a, n, ospreydir, nelem(ospreydir), devgen);

	case Qstatus:
		buf = smalloc(Statuslen);
		if(waserror()){
			free(buf);
			nexterror();
		}
		qlock(&ospreylock);
		if(waserror()){
			qunlock(&ospreylock);
			nexterror();
		}
		now = ospreynow();	/* sets ospreyhz; read it after */
		ospreystatus(buf, Statuslen, now, ospreyhz);
		/*
		 * and what key this machine holds -- not the key, what SHA1
		 * makes of it, so that two machines that agreed one may be
		 * seen to have agreed the same one.
		 */
		{
			long k;

			k = strlen(buf);
			seprint(buf+k, buf+Statuslen, "key %s\n",
				ospreykeyset ? ospreyfinger : "none");
		}
		qunlock(&ospreylock);
		poperror();
		n = readstr(offset, a, n, buf);
		poperror();
		free(buf);
		return n;

	case Qreply:
		/*
		 * One line per reply, drained from every container's reply
		 * ring.  Reading is destructive and a ring has no stable
		 * offset, so only a read at the start of the file takes
		 * anything: a reader that asks for more would otherwise
		 * drain replies that arrived meanwhile and discard them.
		 */
		if(offset != 0)
			return 0;
		buf = smalloc(Statuslen);
		if(waserror()){
			free(buf);
			nexterror();
		}
		qlock(&ospreylock);
		if(waserror()){
			qunlock(&ospreylock);
			nexterror();
		}
		s = buf;
		e = buf + Statuslen;
		for(p = ospreynext(nil); p != nil; p = ospreynext(p))
			while(s < e - 1 && ospreycollect(p, &op, &status, arg) == 0)
				s = seprint(s, e, "%llud %s %s %llud %llud %llud\n",
					ospreyid(p), ospreyopname(op),
					ospreystatusname(status),
					arg[0], arg[1], arg[2]);
		*s = '\0';
		qunlock(&ospreylock);
		poperror();
		n = readstr(offset, a, n, buf);
		poperror();
		free(buf);
		return n;

	case Qarena:
		/*
		 * The shared span itself, at its own byte offsets, so the
		 * rings and data areas can be examined without mapping it.
		 */
		n = ospreyarenaread(a, n, offset);
		return n;

	case Qpip:
		return pipread(c, a, n);

	case Qbench:
	case Qticket:
		/*
		 * The ticket the last write on this chan asked for, handed
		 * over once.  There is no offset in it: a write moves the
		 * chan's, and what is wanted is the whole thing.
		 */
		if(c->aux == nil)
			return 0;
		s = (char*)c->aux;
		if((long)strlen(s) > n)
			error(Etoobig);
		n = strlen(s);
		memmove(a, s, n);
		free(c->aux);
		c->aux = nil;
		return n;

	case Qsnap:
		/*
		 * Every container as text, so that a checkpoint can be
		 * written somewhere and read back: into this kernel later,
		 * or into another one.
		 */
		buf = smalloc(Snaplen);
		if(waserror()){
			free(buf);
			nexterror();
		}
		qlock(&ospreylock);
		if(waserror()){
			qunlock(&ospreylock);
			nexterror();
		}
		if(ospreysnapwrite(buf, Snaplen) < 0)
			error("checkpoint does not fit");
		/*
		 * A checkpoint carries who a container is for and who it has
		 * been handed to.  On another machine that is only worth what
		 * the machine that wrote it is worth, so a machine with a key
		 * signs what it wrote, and one with the same key will believe
		 * it and no other.
		 */
		if(ospreykeyset){
			char sig[Sigchars+1];
			long k;

			k = strlen(buf);
			if(ospreysign(buf, sig, sizeof sig) > 0
			&& k + 5 + Sigchars < Snaplen)
				snprint(buf+k, Snaplen-k, "sig %s\n", sig);
		}
		qunlock(&ospreylock);
		poperror();
		n = readstr(offset, a, n, buf);
		poperror();
		free(buf);
		return n;

	default:
		error(Egreg);
	}
}

static long
ospreywrite(Chan *c, void *a, long n, vlong offset)
{
	Cmdbuf *cb;
	Cmdtab *ct;
	Ospreyproc *p;
	Proc *q;
	Uart *ut;
	void *et;
	Selwait sw;
	char *nm;
	uvlong arg[Ospreynarg];
	int i, op, x;

	if((ulong)c->qid.path == Qarena)
		return ospreyarenaio(a, n, offset, 1);
	if((ulong)c->qid.path == Qpip)
		return pipwrite(c, a, n);
	if((ulong)c->qid.path == Qbench){
		/*
		 * What a request costs this kernel.  The talk measures a
		 * send, a receive and a context switch together at 270
		 * nanoseconds; that is a microkernel figure and this is not
		 * one, so the number wanted here is what it really costs to
		 * put a request on a ring, wake the process that serves the
		 * container, and be woken again with the answer.
		 *
		 * The container must have a service process of its own --
		 * ctl serve -- or there would be nothing to switch to.
		 */
		uvlong t0, t1, arg[Ospreynarg], op;
		long i, count, status;
		char *r;

		cb = parsecmd(a, n);
		if(waserror()){
			free(cb);
			nexterror();
		}
		if(cb->nf != 2)
			error(Ebadarg);
		count = (long)strtoul(cb->f[1], nil, 0);
		if(count <= 0 || count > 100000)
			error(Ebadarg);
		qlock(&ospreylock);
		if(waserror()){
			qunlock(&ospreylock);
			nexterror();
		}
		p = ospreyproc(cb->f[0]);
		if(!ospreymay(p, up->user))
			error(Eperm);
		if((x = ospreyindex(p)) < 0)
			error(Enonexist);
		if(ospreyserving[x] == 0)
			error("the container has no service process");
		while(ospreyreplyready(p))	/* start from a quiet ring */
			ospreycollect(p, &op, &status, arg);

		cycles(&t0);
		for(i = 0; i < count; i++){
			memset(arg, 0, sizeof arg);
			if(ospreysubmit(p, ospreyop("poll"), arg) < 0)
				break;
			ospreywakeup();
			ospreywakeservers(-1);
			while(!ospreyreplyready(p)){
				if((x = ospreyindex(p)) < 0)
					error(Enonexist);
				qunlock(&ospreylock);
				if(waserror()){
					qlock(&ospreylock);
					nexterror();
				}
				sleep(&ospreyreplyrend[x], ospreyreply, p);
				poperror();
				qlock(&ospreylock);
				p = ospreyproc(cb->f[0]);
			}
			ospreycollect(p, &op, &status, arg);
		}
		cycles(&t1);

		r = smalloc(256);
		if(waserror()){
			free(r);
			nexterror();
		}
		if(i <= 0)
			error("nothing was measured");
		snprint(r, 256, "%ld round trips, %llud cycles each,"
			" %llud ns each, at %llud hz\n",
			i, (t1 - t0)/i,
			m->cpuhz == 0 ? 0 :
				((t1 - t0)/i)*1000000000ULL/m->cpuhz,
			m->cpuhz);
		poperror();
		if(c->aux != nil)
			free(c->aux);
		c->aux = r;
		qunlock(&ospreylock);
		poperror();
		poperror();
		free(cb);
		return n;
	}
	if((ulong)c->qid.path == Qticket){
		/*
		 * Sign a name for a container until a time.  Only somebody
		 * the container is already for may ask, and only for a name
		 * it is already for: a ticket says a thing that is true
		 * here, so that it can be believed elsewhere.  What comes
		 * back is on this chan alone, so nobody else sees it.
		 */
		char *t;
		uvlong secs;

		if(ospreykeyset == 0)
			error("no key");
		cb = parsecmd(a, n);
		if(waserror()){
			free(cb);
			nexterror();
		}
		if(cb->nf != 3)
			error(Ebadarg);
		qlock(&ospreylock);
		if(waserror()){
			qunlock(&ospreylock);
			nexterror();
		}
		p = ospreyproc(cb->f[0]);
		if(!ospreymay(p, up->user) || !ospreymay(p, cb->f[1]))
			error(Eperm);
		secs = strtoull(cb->f[2], nil, 10);
		t = smalloc(Ticketlen);
		if(waserror()){
			free(t);
			nexterror();
		}
		if(ospreyticket(cb->f[1], ospreyid(p),
			secs == 0 ? 0 : (uvlong)seconds() + secs,
			t, Ticketlen) < 0)
			error(Ebadarg);
		poperror();
		if(c->aux != nil)
			free(c->aux);
		c->aux = t;
		qunlock(&ospreylock);
		poperror();
		poperror();
		free(cb);
		return n;
	}
	if((ulong)c->qid.path == Qsnap){
		/* a checkpoint read back; what it names and is not here is made */
		if(n <= 0 || n >= Snaplen)
			error(Etoobig);
		nm = smalloc(n+1);
		if(waserror()){
			free(nm);
			nexterror();
		}
		memmove(nm, a, n);
		nm[n] = '\0';
		x = n;		/* what the writer wrote, whatever we keep */
		/*
		 * and a machine with a key takes back only what it, or a
		 * machine holding the same key, signed.
		 */
		if(ospreykeyset){
			char *sig;

			if(n > 4 && strncmp(nm, "sig ", 4) == 0)
				sig = nm;
			else if((sig = strstr(nm, "\nsig ")) != nil)
				sig++;
			if(sig == nil)
				error("checkpoint is not signed");
			*sig = '\0';
			sig += 4;
			for(i = 0; sig[i] != '\0'; i++)
				if(sig[i] == '\n'){
					sig[i] = '\0';
					break;
				}
			if(!ospreysigok(nm, sig))
				error("checkpoint is not ours");
			x = strlen(nm);
		}
		qlock(&ospreylock);
		if(waserror()){
			qunlock(&ospreylock);
			nexterror();
		}
		/*
		 * A checkpoint may make a container that is not here.  It
		 * may not write over one that is and is not the writer's:
		 * a checkpoint says who a container is for, so writing one
		 * would otherwise be a way of taking any container going.
		 */
		{
			char *l;
			uvlong id;

			for(l = nm; (l = strstr(l, "container ")) != nil; ){
				if(l != nm && l[-1] != '\n'){
					l += 10;
					continue;
				}
				l += 10;
				id = strtoull(l, nil, 0);
				if(ospreylookup(id) != nil
				&& !ospreymay(ospreylookup(id), up->user))
					error(Eperm);
			}
		}
		ospreysnapread(nm, x+1);
		qunlock(&ospreylock);
		poperror();
		poperror();
		free(nm);
		ospreywakeup();
		return n;
	}
	if((ulong)c->qid.path != Qctl)
		error(Eperm);

	cb = parsecmd(a, n);
	qlock(&ospreylock);
	if(waserror()){
		qunlock(&ospreylock);
		free(cb);
		nexterror();
	}
	ct = lookupcmd(cb, ospreycmd, nelem(ospreycmd));
	switch(ct->index){
	case CMreset:
		/* the chans first: cclose can sleep, and reset takes locks */
		for(p = ospreynext(nil); p != nil; p = ospreynext(p)){
			ospreyclosefds(p);
			ospreyputproc(p);
			ospreyputserver(p);
			ospreyputether(p);
			ospreyputuart(p);
		}
		ospreyreset();
		pipreset();
		ospreywakeup();
		break;

	case CMcreate:
		if((p = ospreycreate(strtoull(cb->f[1], nil, 0),
			strtoull(cb->f[2], nil, 0),
			strtoull(cb->f[3], nil, 0),
			strtoull(cb->f[4], nil, 0))) == nil)
			error(Enodev);
		ospreysetowner(p, up->user);
		break;

	case CMattach:
		p = ospreymine(cb->f[1]);
		if(ospreyattach(p, strtoul(cb->f[2], nil, 0), ospreynow()) < 0)
			error(Ebadarg);
		break;

	case CMdetach:
		if(ospreydetach(ospreyproc(cb->f[1])) < 0)
			error(Ebadarg);
		break;

	case CMexit:
		/* the chans first: cclose can sleep, and exit takes locks */
		p = ospreymine(cb->f[1]);
		ospreyclosefds(p);
		ospreyputproc(p);
		ospreyputserver(p);
		ospreyputether(p);
		ospreyputuart(p);
		if(ospreyexit(p) < 0)
			error(Ebadarg);
		ospreywakeup();
		break;

	case CMbalance:
		ospreybalance(ospreynow());
		break;

	case CMschedule:
		ospreyschedule(strtoul(cb->f[1], nil, 0), ospreynow());
		break;

	case CMcharge:
		if(ospreycharge(strtoul(cb->f[1], nil, 0),
			strtoull(cb->f[2], nil, 0), ospreynow()) < 0)
			error(Ebadarg);
		break;

	case CMlimit:
		p = ospreymine(cb->f[1]);
		if(ospreylimit(p, strtoul(cb->f[2], nil, 0),
			strtoul(cb->f[3], nil, 0),
			strtoul(cb->f[4], nil, 0)) < 0)
			error(Ebadarg);
		break;

	case CMsubmit:
		if(cb->nf < 3 || cb->nf > 3 + Ospreynarg)
			error(Ecmdargs);
		p = ospreymine(cb->f[1]);
		if((op = ospreyop(cb->f[2])) < 0)
			error(Ebadarg);
		for(i = 0; i < Ospreynarg; i++)
			arg[i] = 3 + i < cb->nf ?
				strtoull(cb->f[3+i], nil, 0) : 0;
		if(!ospreyringsane(p))
			error("the container's ring indices are not usable");
		/* the queue-full path: wait for the dispatcher to make room */
		while(ospreyrequestfull(p)){
			if((x = ospreyindex(p)) < 0)
				error(Enonexist);
			qunlock(&ospreylock);
			if(waserror()){
				qlock(&ospreylock);
				nexterror();
			}
			sleep(&ospreyroomrend[x], ospreyroom, p);
			poperror();
			qlock(&ospreylock);
			p = ospreymine(cb->f[1]);
		}
		if(ospreysubmit(p, op, arg) < 0)
			error(Eio);
		if((x = ospreyindex(p)) >= 0 && x < nelem(ospreyservrend)){
			wakeup(&ospreyservrend[x]);
			wakeup(&ospreyselrend[x]);
		}
		ospreywakeup();
		break;

	case CMservice:
		if(cb->nf > 2)
			error(Ecmdargs);
		i = cb->nf == 2 ? atoi(cb->f[1]) : 1;
		while(i-- > 0)
			if(ospreyservice(ospreynow()) <= 0)
				break;
		for(p = ospreynext(nil); p != nil; p = ospreynext(p))
			ospreyroute(p);
		ospreywakeup();
		break;

	case CMpipether:
		/*
		 * Speak pi-p on a wire rather than through this file.  Two
		 * machines that have nothing else in common can then talk
		 * about containers.
		 */
		if(strcmp(cb->f[2], "off") == 0){
			/*
			 * The reader is asleep in a read on its conversation
			 * and will not look at pipserving until something
			 * arrives, so send it something.  A frame of nothing
			 * is a group with no messages in it, which it
			 * answers by going round again -- and then sees that
			 * it has been told to stop.  Waiting for it to
			 * finish is what makes off followed by on work.
			 */
			pipserving = 0;
			qlock(&piplock);
			if(pipetherchan != nil){
				static uchar quiet[Minframe];

				memset(quiet, 0, sizeof quiet);
				quiet[0] = 0xff;
				quiet[12] = Pipethertype >> 8;
				quiet[13] = Pipethertype;
				if(!waserror()){
					devtab[pipetherchan->type]->write(
						pipetherchan, quiet,
						sizeof quiet, 0);
					poperror();
				}
			}
			qunlock(&piplock);
			while(!pipetherdone(nil))
				sleep(&pipetherrend, pipetherdone, nil);
			break;
		}
		if(pipserving)
			break;
		if(etherlookup(cb->f[1]) == nil)
			error(Enonexist);
		nm = smalloc(strlen(cb->f[1])+1);
		strcpy(nm, cb->f[1]);
		pipserving = 1;
		if(waserror()){
			pipserving = 0;
			free(nm);
			nexterror();
		}
		kproc("ospreypip", pipetherserve, nm);
		poperror();
		break;

	case CMoutput:
		/*
		 * Put work on the container's output queue: a place in its
		 * own data area and how much of it.  A process with the
		 * slice mapped puts its own work there without the kernel;
		 * this is for whoever has not mapped it.
		 */
		p = ospreyproc(cb->f[1]);
		if(!ospreymay(p, up->user))
			error(Eperm);
		if(ospreyoutput(p, strtoull(cb->f[2], nil, 0),
			strtoull(cb->f[3], nil, 0)) < 0)
			error(Ebadarg);
		ospreywakeup();
		break;

	case CMkey:
		/*
		 * The key this machine signs with, and believes.  Only the
		 * host owner sets it, and nothing reads it back: what it is
		 * for is that two machines holding the same one will take
		 * each other's word, and nobody else's.
		 */
		if(strcmp(eve, "") != 0 && strcmp(up->user, eve) != 0)
			error(Eperm);
		if(strcmp(cb->f[1], "off") == 0){
			memset(ospreykey, 0, sizeof ospreykey);
			ospreyfinger[0] = '\0';
			ospreykeyset = 0;
			break;
		}
		sha1((uchar*)cb->f[1], strlen(cb->f[1]), ospreykey, nil);
		{
			uchar h[SHA1dlen];

			sha1(ospreykey, Keylen, h, nil);
			ospreyhex(h, 8, ospreyfinger);
		}
		ospreykeyset = 1;
		break;

	case CMpair:
		/*
		 * Agree a key with whoever is on the other end of that
		 * interface rather than have the same one typed into both
		 * machines.  One says listen and the other says offer; both
		 * end up saying the same fingerprint in status, and
		 * comparing those two is the only thing that says who was
		 * on the other end.
		 */
		if(strcmp(eve, "") != 0 && strcmp(up->user, eve) != 0)
			error(Eperm);
		{
			Pairarg *pa;

			pa = smalloc(sizeof(Pairarg));
			if(waserror()){
				free(pa);
				nexterror();
			}
			strncpy(pa->ifc, cb->f[1], sizeof pa->ifc - 1);
			if(strcmp(cb->f[2], "offer") == 0)
				pa->offer = 1;
			else if(strcmp(cb->f[2], "listen") == 0)
				pa->offer = 0;
			else
				error(Ebadarg);
			poperror();
			kproc("ospreypair", pairproc, pa);
		}
		break;

	case CMgrant:
		/*
		 * The owner hands the right to another, by name.  Nothing
		 * here knows anything about that name; it is enough that
		 * whoever comes with it is called that.
		 */
		p = ospreyproc(cb->f[1]);
		if(!ospreymay(p, up->user))
			error(Eperm);
		if(ospreygrant(p, cb->f[2]) < 0)
			error(Ebadarg);
		break;

	case CMrevoke:
		p = ospreyproc(cb->f[1]);
		if(!ospreymay(p, up->user))
			error(Eperm);
		if(ospreyrevoke(p, cb->f[2]) < 0)
			error(Enonexist);
		break;

	case CMpage:
		/*
		 * Take a page for the container, or give one back.  A page
		 * is in the arena, which the container has mapped, so what
		 * it holds is what its map names.
		 */
		p = ospreymine(cb->f[1]);
		if(strcmp(cb->f[2], "alloc") == 0){
			if(ospreypagealloc(p) < 0)
				error(Enomem);
		} else if(ospreypagefree(p, atoi(cb->f[2])) < 0)
			error(Ebadarg);
		break;

	case CMflip:
		/*
		 * Hand a page from one container to another.  What was
		 * written in it is there afterwards, having been neither
		 * copied nor moved.
		 */
		p = ospreymine(cb->f[1]);
		/* the page it is given to need not be mine: this is a gift */
		if(ospreypageflip(p, ospreyproc(cb->f[2]),
			atoi(cb->f[3])) < 0)
			error(Ebadarg);
		break;

	case CMdelegate:
		/*
		 * Have another container answer what the kernel will not.
		 * The server is an ordinary process; nothing about this is
		 * in the kernel but the routing.
		 */
		p = ospreymine(cb->f[1]);
		if(strcmp(cb->f[2], "off") == 0){
			if(ospreydelegate(p, nil) < 0)
				error(Ebadarg);
			break;
		}
		if(ospreydelegate(p, ospreyproc(cb->f[2])) < 0)
			error(Ebadarg);
		break;

	case CMether:
		/*
		 * Give the container an ethernet interface: its packets are
		 * charged to the container's network caps and queued for it,
		 * and each gives the named semaphore.
		 */
		p = ospreymine(cb->f[1]);
		if((x = ospreyindex(p)) < 0 || x >= nelem(ospreyether))
			error(Ebadarg);
		if(strcmp(cb->f[2], "off") == 0){
			if(ospreyether[x] != nil)
				((Ether*)ospreyether[x])->rbpool = nil;
			ospreyether[x] = nil;
			if(ospreyheld[x] != nil){
				freeb(ospreyheld[x]);
				ospreyheld[x] = nil;
			}
			wakeup(&ospreyselrend[x]);
			break;
		}
		i = atoi(cb->f[3]);
		if(i < 0 || (ulong)i >= ospreynsem())
			error(Ebadarg);
		if((et = etherlookup(cb->f[2])) == nil)
			error(Enonexist);
		if(ospreyether[x] != nil && ospreyether[x] != et)
			ospreyputether(p);	/* give the last one back first */
		if(ospreylendbufs(p, x) < 0)
			error(Enomem);
		ospreyether[x] = et;
		ospreyethersem[x] = i;
		((Ether*)et)->rbpool = &ospreyrbpool[x];
		break;

	case CMuart:
		/*
		 * Hand a uart to the container: from here its interrupt does
		 * nothing but give the named semaphore, and a task of the
		 * container's does the work.  The console's uart is refused;
		 * losing it would take the machine with it.
		 */
		p = ospreymine(cb->f[1]);
		if((x = ospreyindex(p)) < 0 || x >= nelem(ospreyuart))
			error(Ebadarg);
		if(strcmp(cb->f[2], "off") == 0){
			if(ospreyuart[x] != nil){
				if(ospreyuart[x]->phys->taskenable != nil)
					(*ospreyuart[x]->phys->taskenable)(ospreyuart[x], 0);
				(*ospreyuart[x]->phys->intrmask)(ospreyuart[x], 1);
			}
			ospreyuart[x] = nil;
			ospreyuarting[x] = 0;
			wakeup(&ospreyselrend[x]);
			break;
		}
		i = atoi(cb->f[3]);
		if(i < 0 || (ulong)i >= ospreynsem())
			error(Ebadarg);
		if((ut = uartlookup(cb->f[2])) == nil)
			error(Enonexist);
		if(ut->console || ut->special)
			error(Eperm);
		/*
		 * All four, not two: without send the task would have
		 * nothing to write with and would drop what it was given
		 * without telling anyone.
		 */
		if(ut->phys->interrupt == nil || ut->phys->intrmask == nil
		|| ut->phys->send == nil || ut->phys->taskenable == nil)
			error(Ebadarg);
		if(ospreyuart[x] != nil && ospreyuart[x] != ut)
			ospreyputuart(p);	/* and the last uart */
		ospreyuart[x] = ut;
		ospreyuartsem[x] = i;
		if(ut->phys->taskenable != nil)
			(*ut->phys->taskenable)(ut, 1);
		if(ospreyuarting[x] == 0){
			ospreyuarting[x] = 1;
			if(waserror()){
				ospreyuarting[x] = 0;
				ospreyuart[x] = nil;
				nexterror();
			}
			kproc("ospreyuart", ospreyuarttask, p);
			poperror();
		}
		break;

	case CMtick:
		/*
		 * Have the clock interrupt give one of the container's
		 * semaphores on every tick of its core.  There is no device
		 * here whose interrupt to take, so the one interrupt this
		 * driver already owns stands in for it.
		 */
		p = ospreymine(cb->f[1]);
		if((x = ospreyindex(p)) < 0 || x >= nelem(ospreyticksem))
			error(Ebadarg);
		if(strcmp(cb->f[2], "off") == 0)
			ospreyticksem[x] = -1;
		else {
			i = atoi(cb->f[2]);
			if(i < 0 || (ulong)i >= ospreynsem())
				error(Ebadarg);
			ospreyticksem[x] = i;
		}
		break;

	case CMsemup:
		/*
		 * Give a semaphore.  This is what an interrupt does for the
		 * task that serves its device, and what one task does for
		 * another that is waiting on it.
		 */
		p = ospreymine(cb->f[1]);
		i = atoi(cb->f[2]);
		if(i < 0 || (ulong)i >= ospreynsem())
			error(Ebadarg);
		ospreysemgive(p, i);
		if((x = ospreyindex(p)) >= 0 && x < nelem(ospreyselrend))
			wakeup(&ospreyselrend[x]);
		ospreywakeup();
		break;

	case CMselect:
		/*
		 * Wait on the arms the container left in the span and
		 * perform the first that is ready.  Which one that was is
		 * left in the container's map, where the caller reads it
		 * without asking.
		 */
		p = ospreymine(cb->f[1]);
		sw.p = p;
		sw.armoff = strtoull(cb->f[2], nil, 0);
		sw.narms = atoi(cb->f[3]);
		/* wait only while the arms are good and none of them is ready */
		while((i = ospreyselectready(p, sw.armoff, sw.narms)) == -1){
			if((x = ospreyindex(p)) < 0)
				error(Enonexist);
			qunlock(&ospreylock);
			if(waserror()){
				qlock(&ospreylock);
				nexterror();
			}
			sleep(&ospreyselrend[x], ospreyselok, &sw);
			poperror();
			qlock(&ospreylock);
			p = ospreymine(cb->f[1]);
			sw.p = p;
		}
		if(i < 0 || ospreyselect(p, sw.armoff, sw.narms) < 0)
			error(Ebadarg);
		break;

	case CMmode:
		p = ospreymine(cb->f[1]);
		if(strcmp(cb->f[2], "strict") == 0)
			ospreysetstrict(p, 1);
		else if(strcmp(cb->f[2], "besteffort") == 0)
			ospreysetstrict(p, 0);
		else
			error(Ebadarg);
		break;

	case CMserve:
		/*
		 * Give the container a service process of its own, in this
		 * process's namespace.  From then on nothing has to write
		 * service for its requests to be answered.
		 */
		p = ospreymine(cb->f[1]);
		if((x = ospreyindex(p)) < 0 || x >= nelem(ospreyserving))
			error(Ebadarg);
		if(ospreyserving[x]){
			if(ospreyservingid[x] == ospreyid(p))
				break;		/* already has one */
			error("the last server for that slot has not finished");
		}
		ospreyserving[x] = 1;
		ospreyservingid[x] = ospreyid(p);
		incref(up->pgrp);
		ospreypgrp[x] = up->pgrp;
		if(waserror()){
			ospreyserving[x] = 0;
			ospreypgrp[x] = nil;
			closepgrp(up->pgrp);
			nexterror();
		}
		kproc("osprey", ospreyserver, p);
		poperror();
		break;

	case CMbindproc:
		/*
		 * Bill a running process to this container.  From here on the
		 * clock charges the container for the cycles the core spends
		 * in that process, and the budget holds it back.
		 */
		p = ospreymine(cb->f[1]);
		if((x = ospreyindex(p)) < 0 || x >= nelem(ospreyprocs))
			error(Ebadarg);
		i = atoi(cb->f[2]);
		q = nil;
		for(op = 0; op < conf.nproc; op++){
			q = proctab(op);
			if(q->pid == i && q->state != Dead)
				break;
		}
		if(op == conf.nproc)
			error(Enonexist);
		/*
		 * One process, one container.  A process already bound
		 * somewhere else is let go there first: otherwise two slots
		 * hold the same process, both stop and start it against
		 * their own budgets, and one of them can leave it stopped
		 * with nothing to start it again.
		 */
		for(op = 0; op < nelem(ospreyprocs); op++)
			if(op != x && ospreyprocs[op] == q){
				ospreyprocs[op] = nil;
				ospreystopped[op] = 0;
			}
		if(ospreyprocs[x] != nil && ospreyprocs[x] != q)
			ospreyprocs[x]->osprey = nil;
		ospreyprocs[x] = q;
		q->osprey = p;
		ospreysetpid(p, i);
		break;

	case CMunbindproc:
		p = ospreymine(cb->f[1]);
		if((x = ospreyindex(p)) < 0 || x >= nelem(ospreyprocs))
			error(Ebadarg);
		if((q = ospreyprocs[x]) != nil){
			if(q->fixedpri)
				procpriority(q, PriNormal, 0);
			ospreyrelease(q, x);
			q->osprey = nil;
			ospreyprocs[x] = nil;
		}
		ospreysetpid(p, 0);
		break;

	case CMmigrate:
		p = ospreymine(cb->f[1]);
		if(ospreymigrate(p, strtoul(cb->f[2], nil, 0), ospreynow()) < 0)
			error(Ebadarg);
		break;

	case CMnetcharge:
		p = ospreymine(cb->f[1]);
		if(ospreynetcharge(p, strtoul(cb->f[2], nil, 0),
			strtoul(cb->f[3], nil, 0)) < 0)
			error(Enomem);
		break;

	case CMnetfree:
		p = ospreymine(cb->f[1]);
		ospreynetrelease(p, strtoul(cb->f[2], nil, 0),
			strtoul(cb->f[3], nil, 0));
		break;

	case CMcheckpoint:
		if(ospreycheckpoint(ospreymine(cb->f[1])) < 0)
			error(Ebadarg);
		break;

	case CMrestore:
		if(ospreyrestore(ospreymine(cb->f[1])) < 0)
			error(Ebadarg);
		ospreywakeup();
		break;

	case CMpoke:
		/*
		 * Put a name in a container's data area without mapping the
		 * arena.  A process that has segattached it writes there
		 * itself; this is for the shell.
		 */
		p = ospreyproc(cb->f[1]);
		i = strlen(cb->f[3]);
		if((nm = ospreydata(p, strtoull(cb->f[2], nil, 0), i+1)) == nil)
			error(Ebadarg);
		memmove(nm, cb->f[3], i+1);
		break;

	case CMwait:
		/* the reply wait path */
		p = ospreymine(cb->f[1]);
		while(!ospreyreplyready(p)){
			if((x = ospreyindex(p)) < 0)
				error(Enonexist);
			qunlock(&ospreylock);
			if(waserror()){
				qlock(&ospreylock);
				nexterror();
			}
			sleep(&ospreyreplyrend[x], ospreyreply, p);
			poperror();
			qlock(&ospreylock);
			p = ospreymine(cb->f[1]);
		}
		break;

	case CMbind:
		p = ospreymine(cb->f[1]);
		if(ospreybind(p, cb->f[2], cb->f[3]) < 0)
			error(Ebadarg);
		break;

	case CMunbind:
		p = ospreymine(cb->f[1]);
		if(ospreyunbind(p, cb->f[2]) < 0)
			error(Enonexist);
		break;
	}
	qunlock(&ospreylock);
	poperror();
	free(cb);
	return n;
}

Dev ospreydevtab = {
	'O',
	"osprey",

	devreset,
	ospreyinit,
	devshutdown,
	ospreyattachdev,
	ospreywalk,
	ospreystat,
	ospreyopen,
	devcreate,
	ospreyclose,
	ospreyread,
	devbread,
	ospreywrite,
	devbwrite,
	devremove,
	devwstat,
};
