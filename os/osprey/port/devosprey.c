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
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

#include	"../port/netif.h"
#include	"../port/etherif.h"

#include	"../port/osprey.h"
#include	<libsec.h>
#include	<mp.h>
#include	"../port/pip.h"

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
	/*
	 * Every container as a checkpoint.  A container that has written
	 * its whole data area is about nine and a third kilobytes of it,
	 * measured, since the data goes whatever the rings hold; sixteen
	 * of those is about a hundred and fifty, and at sixty-four
	 * kilobytes the eighth container was refused.  What it is for is
	 * a checkpoint of the whole machine, so it is sized for the whole
	 * machine.  A checkpoint carried by mig is a different limit and
	 * a much smaller one: that is one ethernet frame.
	 */
	Snaplen		= 192*1024,
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
	OpGone,			/* the kernel to a server, about a container that has gone */
	OpMigrate = 22,		/* the kernel to a server: carry this container's process over the wire */
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
	int	uart;		/* or a uart a container holds: its slot plus one */
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
	CMmemfree,
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
	CMether,	"ether",	0,
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
	CMmemfree,	"memfree",	3,
};

static QLock ospreylock;
/*
 * One pair of rendezvous points per container: sleep() allows a single
 * sleeper on a Rendez, and a room-waiter and a reply-waiter must not
 * share one.  A ring still has one producer and one consumer.
 */
static Rendez ospreyroomrend[16];
static void ospreyconsdrained(Ospreyproc*);	/* the console FIFO, fed when its task frees a slot */
static void ospreyconscheck(Ospreyproc*, uvlong, uvlong);
static void ospreyconspushed(Ospreyproc*, uvlong, uvlong);
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
static long ospreyuartlen0[nelem(ospreyuartlen)];	/* the message's whole length, for the check at the end of its push */
static void *ospreyether[16];		/* an interface this container has */
static int ospreyethersem[16];		/* the semaphore its packets give */
static int ospreytxsem[16];		/* and the one a freed transmit buffer gives */
static void ospreytxdone(Bpool*, Block*);
static uvlong ospreytxavail(int);
static void ospreytellandwake(Ospreyproc*, int);
static void ospreyawake(int, uvlong);
static uvlong ospreynow(void);
static Bpool ospreyrbpool[16];		/* its receive buffers, in the span */
/*
 * And its transmit buffers, also in the span.  The Blocks are kept so
 * that a container naming buffer i can be given the Block that stands
 * for it; a Block that is not on the pool's free list is one the card
 * still has, and the container is told to try again rather than being
 * allowed to write over a frame in flight.
 */
enum {
	Maxtxbuf	= 64,	/* bits in txavail; see below */
};

static Bpool ospreytxpool[16];
/*
 * The one limit the device does index an array with, and the reason
 * txbuf has a ceiling where the other four have none: txavail in the map
 * is one word of bits, so a container can be lent no more transmit
 * buffers than there are bits in it.
 */
static Block *ospreytxblk[16][Maxtxbuf];
static int ospreyntxblk[16];
/*
 * What each transmit buffer was charged for and which of them are
 * charged.  A frame in flight is network the container is using, and
 * its caps bound that the same way they bound a packet waiting to be
 * taken; the charge is given back when the card has finished.
 */
static ulong ospreytxlen[16][Maxtxbuf];
static uvlong ospreytxheld[16];
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

/* the address of the card this container was given, for what it builds */
static int
ospreycardea(Ospreyproc *p, uchar *ea)
{
	Ether *e;
	int x;

	if((x = ospreyindex(p)) < 0 || x >= nelem(ospreyether))
		return 0;
	if((e = (Ether*)ospreyether[x]) == nil)
		return 0;
	memmove(ea, e->ea, 6);
	return 6;
}

static ulong
ospreycountcopied(Ospreyproc *p)
{
	int x;

	x = ospreyindex(p);
	return x < 0 || x >= nelem(ospreycopied) ? 0 : ospreycopied[x];
}

/* lend the container's transmit buffers to nobody yet: they are its own */
static int
ospreylendtx(Ospreyproc *p, int x)
{
	Bpool *pool;
	Block *b;
	uchar *a;
	uvlong off, size, n, i;

	if(ospreytxsizes(p, &off, &n, &size) < 0 || n == 0)
		return -1;
	if(n > nelem(ospreytxblk[0]))
		n = nelem(ospreytxblk[0]);
	pool = &ospreytxpool[x];
	memset(pool, 0, sizeof *pool);
	pool->size = size - Rbtlr;
	pool->align = 8;
	pool->done = ospreytxdone;
	ospreyntxblk[x] = 0;
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
		ospreytxblk[x][i] = b;
		ospreyntxblk[x] = i+1;
	}
	ospreytxavail(x);
	return 0;
}

/*
 * A transmit buffer has come back from the card.  This runs from freeb,
 * which runs at interrupt level, so it does what an interrupt does here:
 * gives the container's semaphore.  A task waiting in select on that arm
 * is told its buffer is its own again.
 */
static void
ospreytxdone(Bpool *pool, Block *b)
{
	Ospreyproc *p;
	int i, j;

	for(i = 0; i < nelem(ospreytxpool); i++){
		if(pool != &ospreytxpool[i])
			continue;
		/*
		 * Which buffer came back is what freeb says now, so this
		 * runs at interrupt level without a lock and without walking
		 * anything: the frame's charge is given back and its bit
		 * cleared, and the word the container reads follows from the
		 * bits alone.
		 */
		for(j = 0; j < ospreyntxblk[i]; j++)
			if(ospreytxblk[i][j] == b)
				break;
		if(j == ospreyntxblk[i])
			return;		/* not one of this container's */
		if((p = ospreyat(i)) == nil)
			return;
		if((ospreytxheld[i] & (1ULL<<j)) != 0){
			ospreynetrelease(p, ospreytxlen[i][j], 1);
			ospreytxheld[i] &= ~(1ULL<<j);
		}
		ospreytxavail(i);
		if(ospreytxsem[i] < 0)
			return;
		ospreysemgive(p, ospreytxsem[i]);
		return;
	}
}

/*
 * Say in the container's map which transmit buffers it may write.  A
 * buffer is either in flight or free and ospreytxheld says which, so
 * this is one word of arithmetic: it used to be a walk of the pool's
 * free list under the pool's lock, which is a walk at interrupt level
 * over a list this code does not own, and a list that ever came to hold
 * a cycle stopped the machine there.  It did: a flood of eight hundred
 * frames ended in "ilock ... held by pc" with the holder and the waiter
 * in the same function.
 */
static uvlong
ospreytxavail(int x)
{
	Ospreyproc *p;
	uvlong all;

	if(x < 0 || x >= nelem(ospreytxpool))
		return 0;
	if((p = ospreyat(x)) == nil)
		return 0;
	if(ospreyntxblk[x] <= 0)
		return 0;
	all = ospreyntxblk[x] >= 64 ? ~0ULL : (1ULL<<ospreyntxblk[x]) - 1;
	all &= ~ospreytxheld[x];
	ospreysettxavail(p, all);
	return all;
}

/* take it off that list; the card will put it back when it is done */
static int
ospreytxtake(Bpool *pool, Block *b, int nblk)
{
	Block **l;
	int got, n;

	got = 0;
	ilock(pool);
	/*
	 * Bounded by the number of blocks there are: the list cannot
	 * honestly be longer, and an unbounded walk of a list under a lock
	 * is a machine that stops rather than a fault that is reported.
	 */
	for(l = &pool->head, n = 0; *l != nil && n <= nblk; l = &(*l)->list, n++)
		if(*l == b){
			*l = b->list;
			b->list = nil;
			got = 1;
			break;
		}
	iunlock(pool);
	return got;
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
		if(ospreyuartlen[x] == 0)
			ospreyconspushed(p, ospreyuartoff[x] - ospreyuartlen0[x], ospreyuartlen0[x]);	/* pushed whole: still what was put there? */
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
				ospreyuartlen0[x] = (long)arg[1];
				ospreyconscheck(p, arg[0], arg[1]);	/* the console's slot as filled, still? */
			}
			qunlock(&ospreylock);
			ospreyconsdrained(p);	/* a slot freed: the console FIFO, if this is the console, feeds it */
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

/*
 * Say something to a container's server on the ring its requests go on,
 * and wake it.  A server waiting in select is asleep on its own
 * rendezvous, not on the one the service kproc uses, so wake both:
 * which of the two is answering for this container is not this code's
 * business.  Nothing replies to these; they are the kernel telling a
 * server something about a container it answers for.
 */
/*
 * A container's own process is about to wait, and has stopped waiting.
 * The policy layer has had runtimeblock and runtimewake from the start
 * and nothing called either, so a container asleep in a select stayed on
 * its core's run queue and called itself runnable however long it
 * waited.  The wake is guarded by the container's identity as well as
 * its slot: the sleep drops the lock, and the slot may hold somebody
 * else by the time it returns.
 */
static void
ospreyawake(int x, uvlong id)
{
	Ospreyproc *q;

	if((q = ospreyat(x)) != nil && ospreyid(q) == id)
		ospreyunblock(q, ospreynow());
}

static void
ospreytellandwake(Ospreyproc *p, int op)
{
	int x;

	if(ospreytellserver(p, op) < 0)
		return;
	x = ospreyindex(ospreyserverof(p));
	if(x >= 0 && x < nelem(ospreyselrend)){
		wakeup(&ospreyselrend[x]);
		wakeup(&ospreyservrend[x]);
	}
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
	 * A watch for a container's process spinning in user mode: once a
	 * second, one that is not in a system call and sits at the user pc
	 * it sat at a second ago is named, with that pc, so a loop nobody
	 * can otherwise see is at least placed.
	 */
	if(core == 0){
		static int watchticks;
		static uintptr lastpc[16];
		static int same[16];
		extern uintptr uregpc(void*);
		int x;

		if(++watchticks % 100 == 0){
			for(x = 0; x < nelem(ospreyprocs); x++){
				Proc *w = ospreyprocs[x];
				uintptr pc;

				if(w == nil || w->osprey == nil || w->insyscall || (w->state != Running && w->state != Ready)){
					same[x] = 0;
					continue;
				}
				pc = uregpc(w->dbgreg);
				if(pc != 0 && pc == lastpc[x]){
					if(++same[x] >= 2 && same[x] <= 6)
						print("osprey watch: container %llud pid %lud %s has sat in user mode at pc %#p for %d s\n",
							ospreyid(w->osprey), w->pid, w->text, pc, same[x]);
				} else
					same[x] = 0;
				lastpc[x] = pc;
			}
		}
	}

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
 * Route a server's replies home and wake, of all the containers, only
 * those that received one: their reply rendezvous, where a caller's
 * yield after a request waits.  Waking every rendezvous of every
 * container (ospreywakeup) was the first form, and woke the server's
 * own select loop some hundred times a second for nothing.
 */
static uvlong ospreyroutewakes;		/* containers woken for a reply, in all */

static void
ospreyroutewake(Ospreyproc *s)
{
	Ospreyproc *got[16];
	int n, i, x;

	n = ospreyroutewoke(s, got, nelem(got));
	for(i = 0; i < n; i++){
		if((x = ospreyindex(got[i])) < 0 || x >= nelem(ospreyreplyrend))
			continue;
		wakeup(&ospreyreplyrend[x]);
		ospreyroutewakes++;
	}
}

/*
 * A caller's yield after a request: sleep until a reply is on its ring,
 * or ms have passed, whichever first.  The yield used to be a fixed
 * two milliseconds, so every request from a personality cost at least
 * that however fast it was answered; the reply routed home by the
 * server's select wakes this at once (ospreywakeup, above).
 */
void
ospreyawaitreply(int ms)
{
	Ospreyproc *p;
	int x;

	p = up->osprey;
	if(p == nil || (x = ospreyindex(p)) < 0 || x >= nelem(ospreyreplyrend)){
		tsleep(&up->sleep, return0, nil, ms);
		return;
	}
	tsleep(&ospreyreplyrend[x], ospreyreply, p, ms);
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
ospreyentitledself(int slot)
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

/*
 * And whoever answers for it.  A container that has delegated its
 * personality to a server has given that server the right to reach the
 * memory its requests point into: the name to open and the buffer to
 * read into are offsets in the asking container's own slice, so a server
 * that cannot map that slice cannot answer anything at all.
 *
 * One step, not a chain.  A server's own server is not thereby given
 * everything its clients have; that would be a policy nobody asked for.
 */
static int
ospreyentitled(int slot)
{
	Ospreyproc *s;

	if(ospreyentitledself(slot))
		return 1;
	if((s = ospreyserverof(ospreyat(slot))) == nil)
		return 0;
	return ospreyentitledself(ospreyindex(s));
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
	 * The containers do not exist yet, so the names come from the
	 * adapter, which is where the rule that forms one lives.
	 */
	for(i = 0; i < ospreynproc() && ospreynseg < nelem(ospreyseg); i++){
		ps = &ospreyseg[ospreynseg];
		ps->attr = SG_PHYSICAL;
		ps->name = smalloc(16);
		snprint(ps->name, 16, "%s", ospreyslicename(i));
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
		snprint(ps->name, 16, "%s", ospreypagename(n));
		ps->pa = PADDR(ospreybase) + off + n*BY2PG;
		ps->size = BY2PG;
		if(addphysseg(ps) != nil)
			ospreynseg++;
	}
}

/*
 * The limits a plan9.ini may set, and the ceiling on each.  Zero is no
 * ceiling: what stops the other four is the memory the arena wants,
 * which is one allocation of a slice times Nproc and fails visibly.
 */
static struct {
	char	*conf;
	char	*name;
	ulong	max;
} ospreysizeconf[] = {
	{ "*ospreyqueue",	"queue",	0 },
	{ "*ospreydata",	"data",		0 },
	{ "*ospreysem",		"sem",		64 },
	{ "*ospreypktbuf",	"pktbuf",	0 },
	{ "*ospreytxbuf",	"txbuf",	Maxtxbuf },
};

/*
 * The microkernel's first task, when a configuration asks for it with
 * ospreymicro.  It boots into an Osprey task rather than into the Plan 9
 * shell: no Pgrp, no name space, no initcode.  It drives the policy
 * layer directly -- create a container, submit requests to its ring,
 * let the dispatcher answer them, collect the replies -- which is the
 * paper's message passing with nothing of Plan 9 above it, and then it
 * idles.  What it proves is that the four services the paper keeps
 * (message passing, address spaces through the segment the arena is,
 * interrupts and the scheduler that runs this task) stand with the Plan
 * 9 boot cut away.  os/osprey/port/userinit.c calls it from proc0.
 */
static void ospreyinit(void);

static int ospreymicroexited;

/*
 * A kernel task that returns walks pexit past the group closes the
 * microkernel stubbed: closepgrp, now in proc.c, runs for real, and
 * closefgrp, closergrp, closeegrp and cclose are all guarded by nil,
 * which a kernel task's fd group, rendezvous group, environment and dot
 * all are.  If any of those stubs were wrong this panics; the boot
 * reaching idle afterwards is the proof it did not.
 */
static void
ospreymicroexit(void *)
{
	ospreymicroexited = 1;
}

/*
 * Prepare a container for a user program and bind this process to it, so
 * the program may map the container's slice - its message ring - with
 * segattach.  Returns the slice index, whose name is ospreyN; the
 * program attaches that.  The exokernel gives the program its ring; the
 * program works it in user space.
 */
/*
 * Service the request ring of the container the calling process is bound
 * to.  This is the one trap a program takes to work its ring: it puts a
 * request in the ring in its own memory, calls this to have the kernel
 * carry it, and reads the reply back from the ring, again in memory.
 */
static int svcdiag;
void
ospreyservicecaller(void)
{
	Ospreyproc *p;
	int i, r, before, after;

	qlock(&ospreylock);
	for(i = 0; i < nelem(ospreyprocs); i++)
		if(ospreyprocs[i] == up){
			if((p = ospreyat(i)) != nil){
				before = ospreyrequestready(p);
				/*
				 * A container that answers for others has its
				 * request ring full of their requests, which are
				 * its program's to take, not the kernel's; its own
				 * asks go through ospreyxcall.
				 */
				r = ospreyisserver(p) ? 0 : ospreyservicep(p, fastticks(nil));
				/*
				 * If this container answers for others, send what
				 * it has answered home.  ospreyroute is a no-op for
				 * a container that serves no one, so this is safe for
				 * the ordinary caller and is what lets a user-space
				 * server's replies reach its client on its own sleep.
				 */
				ospreyroute(p);
				/*
				 * Servicing forwarded this container's requests to its
				 * server's ring; wake that server if it is blocked in a
				 * select, so a user-space server waiting on its message
				 * queue answers at once rather than on a timeout.
				 */
				{
					Ospreyproc *sv;
					int sx;

					if((sv = ospreyserverof(p)) != nil
					&& (sx = ospreyindex(sv)) >= 0 && sx < nelem(ospreyselrend))
						wakeup(&ospreyselrend[sx]);
				}
				after = ospreyreplyready(p);
				if(svcdiag < 4){
					svcdiag++;
					print("svc[%d]: reqready=%d serviced=%d replyready=%d\n",
						i, before, r, after);
				}
			}
			break;
		}
	qunlock(&ospreylock);
}

/*
 * The select call, for a user task.  It names arms in its own data area -
 * a get on one of its rings, a down on an interrupt's semaphore - and
 * this blocks until one is ready, performs that one, and returns which
 * arm it was, the way the talk's select does.  The block is a yield-and-
 * retry, like the service call: the minimal interface has no rendezvous
 * wakeup, so this polls readiness and yields the processor between looks,
 * which lets the peer that will make an arm ready - a client forwarding a
 * request, an interrupt giving a semaphore - run.  Anything the task has
 * answered is routed home first, so a server both answers and waits for
 * the next request on the one call.
 */
int
ospreyselectcaller(uvlong armoff, int narms)
{
	Ospreyproc *p;
	int i, slot;

	p = nil;
	slot = -1;
	qlock(&ospreylock);
	for(i = 0; i < nelem(ospreyprocs); i++)
		if(ospreyprocs[i] == up){
			p = ospreyat(i);
			slot = i;
			break;
		}
	qunlock(&ospreylock);
	if(p == nil)
		return -1;
	{
		Selwait sw;

		sw.p = p;
		sw.armoff = armoff;
		sw.narms = narms;
		qlock(&ospreylock);
		ospreyroutewake(p);		/* send home anything answered, and wake those it is for */
		i = ospreyselectready(p, armoff, narms);
		if(i == -1){
			/*
			 * Nothing ready: block on this container's select
			 * rendezvous, which an interrupt (through ospreysemgive) or
			 * a request forwarded to it wakes.  A short timeout so an
			 * idle driver still returns and can give up, and so the
			 * headless boot ends; a real event wakes it at once, which
			 * is the point of blocking rather than the yield-and-retry
			 * this replaces.  ospreyselok re-checks readiness, so a
			 * wakeup between the check and the sleep is not lost.  Sleep
			 * with the lock dropped, as the device's own select does.
			 */
			qunlock(&ospreylock);
			tsleep(&ospreyselrend[slot], ospreyselok, &sw, 200);
			qlock(&ospreylock);
			if((p = ospreyat(slot)) != nil){
				sw.p = p;
				ospreyroutewake(p);
				i = ospreyselectready(p, armoff, narms);
			}
		}
		if(i >= 0 && p != nil)
			i = ospreyselect(p, armoff, narms);
		qunlock(&ospreylock);
	}
	return i;
}

/*
 * Expose the frame buffer the firmware set up as a physical segment, so a
 * user-level graphics driver can map it and draw.  The microkernel
 * multiplexes the display and knows nothing of windows; the draw stack is
 * above it.  The dimensions the driver needs are put in the first pixels'
 * worth of a tiny second segment, so the driver reads them without a
 * name space to ask.
 */
static Physseg ospreyfbseg;
static Physseg ospreymouseseg;
static Physseg ospreykbdseg;
int ospreyfbw, ospreyfbh, ospreyfbd;
extern int ospreyuser;		/* 0 = full personality (pc64), 1 = xup64 user path */

/*
 * A user-level keyboard driver, the seL4/Osprey way: the interrupt is
 * exposed to user space, not handled by a kernel driver.  The short
 * handler here does only what the talk allows an interrupt to do - reads
 * the one scancode byte and hands it on - writing it into a ring in the
 * container's own data area, which the container has mapped, and raising
 * the semaphore the driver task waits on.  The driver, in user space,
 * reads the scancodes out of the segment it already holds and does the
 * rest.  No kernel keyboard device; the hardware is exposed, the driver
 * is above.
 */
enum {
	Kbdoff	= 1024,		/* the scancode ring, past the request message */
	Kbdn	= 256,
	Kbddata	= 0x60,
	Kbdstat	= 0x64,
	Kbdready = 0x01,
	Auxdata	= 0x20,		/* status bit: the output byte is from the aux (mouse) port */
	Kbdirq	= 1,		/* IrqKBD */
};
static uchar *ospreykbdring;	/* cached kernel pointer into the container slice */
static Ospreyproc *ospreykbdproc;
static int ospreykbdsem;

static void
ospreykbdintr(Ureg*, void*)
{
	int st, c;
	uvlong wp;

	st = inb(Kbdstat);
	if(!(st & Kbdready) || (st & Auxdata))	/* not ready, or a mouse byte */
		return;
	c = inb(Kbddata);
	if(ospreykbdring != nil){
		wp = *(uvlong*)ospreykbdring;
		(ospreykbdring + 8)[wp % Kbdn] = (uchar)c;
		*(uvlong*)ospreykbdring = wp + 1;
		if(ospreykbdproc != nil){
			int sx;
			ospreysemgive(ospreykbdproc, ospreykbdsem);
			if((sx = ospreyindex(ospreykbdproc)) >= 0 && sx < nelem(ospreyselrend))
				wakeup(&ospreyselrend[sx]);	/* wake a driver blocked in select */
		}
	}
}

/*
 * The exokernel form: the kernel does not read the scancode at all.  It
 * routes IRQ1 to the container as a bare notification - give the
 * semaphore, wake the driver's select - and leaves the byte in the i8042
 * output buffer for the user-space driver to read with its own inb, using
 * the per-process port grant.  IRQ1 is edge-triggered (i8259elcr does not
 * mark it level), so signalling without draining does not storm: the next
 * edge comes only once the driver has drained the byte and the controller
 * loads the next.  Registered by the ReqKbdnotify xcall; no ring, no
 * kernel device read - the whole i8042 driver lives above the kernel.
 */
static void
ospreykbdnotify(Ureg*, void*)
{
	int sx;

	if(ospreykbdproc != nil){
		ospreysemgive(ospreykbdproc, ospreykbdsem);
		if((sx = ospreyindex(ospreykbdproc)) >= 0 && sx < nelem(ospreyselrend))
			wakeup(&ospreyselrend[sx]);
	}
}

void
ospreykbdenable(Ospreyproc *p, int sem)
{
	uchar *r;
	int c;

	if((r = ospreydata(p, Kbdoff, 8 + Kbdn)) == nil)
		return;
	memset(r, 0, 8 + Kbdn);
	ospreykbdring = r;
	ospreykbdproc = p;
	ospreykbdsem = sem;
	/*
	 * Make sure the controller will interrupt: set command-byte bit 0
	 * (keyboard interrupt enable).  Firmware usually leaves it on, but
	 * the microkernel runs no keyboard init, so do not assume it.
	 */
	while(inb(Kbdstat) & 0x02)
		;
	outb(Kbdstat, 0x20);		/* read command byte */
	while(!(inb(Kbdstat) & Kbdready))
		;
	c = inb(Kbddata);
	while(inb(Kbdstat) & 0x02)
		;
	outb(Kbdstat, 0x60);		/* write command byte */
	while(inb(Kbdstat) & 0x02)
		;
	outb(Kbddata, c | 0x01);	/* enable keyboard interrupt */
	/*
	 * The interrupt itself is registered only once both devices have
	 * finished programming the shared controller - see ospreyinputarm.
	 * Registering IRQ1 here would let a keypress fire ospreykbdintr and
	 * drain the command byte off port 0x60 in the middle of the mouse's
	 * read-modify-write of that same byte, silently disabling one device.
	 */
}

/*
 * A user-level mouse driver, the exokernel way, exactly as the keyboard.
 * The microkernel's short IRQ12 handler reads one byte from the i8042
 * aux (mouse) port and hands it on - into a second ring in this
 * container's exposed data area - and raises a second semaphore.  The
 * driver, in user space above the kernel, assembles the three-byte PS/2
 * packets, moves a cursor and reads the buttons.  No kernel mouse
 * device; the hardware is exposed, the driver is above.
 */
enum {
	Mouseoff = 2048,	/* the aux-byte ring, past the keyboard ring */
	Mousen	= 256,
	Mouseirq = 12,		/* IrqMOUSE - the i8042 aux device */
};
static uchar *ospreymousering;
static Ospreyproc *ospreymouseproc;
static int ospreymousesem;

static void
ospreymouseintr(Ureg*, void*)
{
	int st, c;
	uvlong wp;

	st = inb(Kbdstat);
	if(!(st & Kbdready) || !(st & Auxdata))
		return;
	c = inb(Kbddata);
	if(ospreymousering != nil){
		wp = *(uvlong*)ospreymousering;
		(ospreymousering + 8)[wp % Mousen] = (uchar)c;
		*(uvlong*)ospreymousering = wp + 1;
		if(ospreymouseproc != nil){
			int sx;
			ospreysemgive(ospreymouseproc, ospreymousesem);
			if((sx = ospreyindex(ospreymouseproc)) >= 0 && sx < nelem(ospreyselrend))
				wakeup(&ospreyselrend[sx]);	/* wake a driver blocked in select */
		}
	}
}

/* the aux twin of ospreykbdnotify: signal, do not read the byte */
static void
ospreymousenotify(Ureg*, void*)
{
	int sx;

	if(ospreymouseproc != nil){
		ospreysemgive(ospreymouseproc, ospreymousesem);
		if((sx = ospreyindex(ospreymouseproc)) >= 0 && sx < nelem(ospreyselrend))
			wakeup(&ospreyselrend[sx]);
	}
}

/* wait for the input buffer to drain, then write a controller command */
static void
i8042cmd(int cmd)
{
	int i;

	for(i = 0; i < 100000 && (inb(Kbdstat) & 0x02); i++)
		;
	outb(Kbdstat, cmd);
}

/* wait for the input buffer to drain, then write a data byte */
static void
i8042wdata(int b)
{
	int i;

	for(i = 0; i < 100000 && (inb(Kbdstat) & 0x02); i++)
		;
	outb(Kbddata, b);
}

/* read one byte the controller has put in its output buffer, or -1 */
static int
i8042rdata(void)
{
	int i;

	for(i = 0; i < 100000; i++)
		if(inb(Kbdstat) & Kbdready)
			return inb(Kbddata);
	return -1;
}

void
ospreymouseenable(Ospreyproc *p, int sem)
{
	uchar *r;
	int c;

	if((r = ospreydata(p, Mouseoff, 8 + Mousen)) == nil)
		return;
	memset(r, 0, 8 + Mousen);
	ospreymousering = r;
	ospreymouseproc = p;
	ospreymousesem = sem;

	i8042cmd(0xA8);			/* enable the aux (mouse) port */
	i8042cmd(0x20);			/* read the command byte */
	c = i8042rdata();
	if(c < 0)
		c = 0;
	c |= 0x02;			/* aux interrupt enable (IRQ12) */
	c &= ~0x20;			/* aux clock enable (0 = enabled) */
	i8042cmd(0x60);			/* write the command byte */
	i8042wdata(c);
	i8042cmd(0xD4);			/* route the next data byte to the aux port */
	i8042wdata(0xF4);		/* tell the mouse to report movement */
	i8042rdata();			/* eat its ACK (0xFA) */
	/* the interrupt is registered by ospreyinputarm, after all programming */
}

/*
 * Register both input interrupts, once ospreykbdenable and
 * ospreymouseenable have finished programming the shared i8042.  Kept
 * apart from the programming so no handler can run while the command
 * byte is being read and rewritten.
 */
void
ospreyinputarm(void)
{
	if(ospreykbdring != nil)
		intrenable(Kbdirq, ospreykbdintr, nil, -1, "osprey-kbd");
	if(ospreymousering != nil)
		intrenable(Mouseirq, ospreymouseintr, nil, -1, "osprey-mouse");
}

/*
 * Expose the PS/2 aux (mouse) byte stream to the full personality the
 * same way the frame buffer is exposed: a dedicated page holds the ring
 * (an 8-byte write count, then Mousen raw aux bytes), the aux interrupt
 * fills it, and the page is published as the physical segment
 * "mousering" for a user-level mouse driver to segattach and poll.  No
 * container and no semaphore are involved - the driver polls the write
 * count - so this is independent of the xup64 container path, which arms
 * the same interrupt into a container slice instead; only one of the two
 * runs on a given kernel (this on pc64, that on xup64).
 */
static int
ospreymouseexpose(void)
{
	static int done;
	uchar *km, *mm;
	int c;

	if(done)
		return 0;
	km = xspanalloc(BY2PG, BY2PG, 0);	/* keyboard scancode ring */
	mm = xspanalloc(BY2PG, BY2PG, 0);	/* mouse aux-byte ring */
	if(km == nil || mm == nil)
		return -1;
	memset(km, 0, 8 + Kbdn);
	memset(mm, 0, 8 + Mousen);
	ospreykbdring = km;
	ospreykbdproc = nil;		/* polled: no semaphore, no wakeup */
	ospreykbdsem = 0;
	ospreymousering = mm;
	ospreymouseproc = nil;
	ospreymousesem = 0;

	/*
	 * Program both devices into the shared i8042 command byte in one
	 * read-modify-write, then arm the interrupts - never arm one while
	 * the other's command byte is still being written, or a keypress
	 * can drain port 0x60 mid-sequence and silently disable a device.
	 */
	i8042cmd(0xA8);			/* enable the aux (mouse) port */
	i8042cmd(0x20);			/* read the command byte */
	c = i8042rdata();
	if(c < 0)
		c = 0;
	c |= 0x01;			/* keyboard interrupt enable (IRQ1) */
	c |= 0x02;			/* aux interrupt enable (IRQ12) */
	c &= ~0x20;			/* aux clock enable (0 = enabled) */
	i8042cmd(0x60);			/* write the command byte */
	i8042wdata(c);
	i8042cmd(0xD4);			/* route the next data byte to the aux port */
	i8042wdata(0xF4);		/* tell the mouse to report movement */
	i8042rdata();			/* eat its ACK */

	memset(&ospreykbdseg, 0, sizeof ospreykbdseg);
	ospreykbdseg.attr = SG_PHYSICAL;
	ospreykbdseg.name = "kbdring";
	ospreykbdseg.pa = PADDR(km);
	ospreykbdseg.size = BY2PG;
	memset(&ospreymouseseg, 0, sizeof ospreymouseseg);
	ospreymouseseg.attr = SG_PHYSICAL;
	ospreymouseseg.name = "mousering";
	ospreymouseseg.pa = PADDR(mm);
	ospreymouseseg.size = BY2PG;
	if(addphysseg(&ospreykbdseg) == nil || addphysseg(&ospreymouseseg) == nil)
		return -1;
	intrenable(Kbdirq, ospreykbdintr, nil, -1, "osprey-kbd");
	intrenable(Mouseirq, ospreymouseintr, nil, -1, "osprey-mouse");
	done = 1;
	print("osprey input: exposed kbd ring pa %#llux as \"kbdring\", "
		"mouse ring pa %#llux as \"mousering\"\n",
		(uvlong)PADDR(km), (uvlong)PADDR(mm));
	return 0;
}

int
ospreyframebuffer(void)
{
	static int done;
	char *s;
	int x, y, z;
	uvlong pa;
	ulong sz;

	if(done)			/* register the segment once, however many callers */
		return 0;
	if((s = getconf("*bootscreen")) == nil)
		return -1;
	/* WIDTHxHEIGHTxDEPTH CHAN PA [SZ] */
	x = strtoul(s, &s, 0);
	if(x == 0 || *s++ != 'x')
		return -1;
	y = strtoul(s, &s, 0);
	if(y == 0 || *s++ != 'x')
		return -1;
	z = strtoul(s, &s, 0);
	if(*s != ' ')
		return -1;
	if((s = strchr(s+1, ' ')) == nil)		/* past CHAN */
		return -1;
	pa = strtoull(s+1, &s, 0);
	if(pa == 0)
		return -1;
	sz = 0;
	if(*s == ' ')
		sz = strtoul(s+1, nil, 0);
	if(sz < (ulong)x*y*(z+7)/8)
		sz = x*y*(z+7)/8;

	ospreyfbw = x;
	ospreyfbh = y;
	ospreyfbd = z;
	memset(&ospreyfbseg, 0, sizeof ospreyfbseg);
	ospreyfbseg.attr = SG_PHYSICAL;
	ospreyfbseg.name = "framebuffer";
	ospreyfbseg.pa = pa;
	ospreyfbseg.size = sz;
	if(addphysseg(&ospreyfbseg) == nil)
		return -1;
	done = 1;
	print("osprey fb: exposed %dx%dx%d at pa %#llux size %lud as \"framebuffer\"\n",
		x, y, z, pa, sz);
	return 0;
}

/*
 * A block device to a user task, the exokernel way.  The kernel's part
 * is what a kernel must do and no more: find the device, turn its
 * registers into a segment a container may map, tell the container
 * where things are in it (Ospreyblk in ospreyabi.h), and turn its
 * interrupt into a semaphore.  The driver - reset, features, the queue,
 * the requests - is a program above the kernel, in the container: the
 * paper's driver as a task, selecting on the device's semaphore.  The
 * device is a virtio 1.0 block device with the legacy interface off,
 * so every register is memory the container can be given; the four
 * virtio-pci capabilities are read here because they are PCI
 * configuration space, which a container is not given.
 */
#include "../port/pci.h"

/* one exposed virtio device: its segment, the task it was given to, the interrupt's semaphore */
typedef struct Vioexp Vioexp;
struct Vioexp {
	Physseg	seg;
	Ospreyproc *proc;
	int	sem;
	uchar	*isr;		/* the interrupt status byte, mapped for the handler */
};
static Vioexp vioblk, vionet;

static int
ospreyviocapmatch(Pcidev *p, int cap, int off, int typ)
{
	int bar;

	if(cap != 9 || pcicfgr8(p, off+3) != typ)
		return 1;
	bar = pcicfgr8(p, off+4);
	if(bar >= nelem(p->mem) || p->mem[bar].size == 0)
		return 1;
	return 0;
}

static void
ospreyviointr(Ureg*, void *a)
{
	Vioexp *v = a;
	int sx;

	/* reading the status deasserts the line; the completion itself is the task's to see */
	if(v->isr == nil || (*v->isr & 1) == 0)
		return;
	if(v->proc != nil){
		ospreysemgive(v->proc, v->sem);
		if((sx = ospreyindex(v->proc)) >= 0 && sx < nelem(ospreyselrend))
			wakeup(&ospreyselrend[sx]);
	}
}

/*
 * Expose one virtio 1.0 PCI device (device id did) to a container: its
 * register BAR as a physical segment of the given name, the descriptor
 * at descoff of the container's data area, and its interrupt as a
 * semaphore.  The block device and the network device are the same
 * shape to the kernel; what differs is the driver above it.
 */
static int
ospreyvioexpose(Vioexp *v, Ospreyproc *p, int sem, int did, char *segname, uvlong descoff, uvlong magic, char *what, char *devname)
{
	Pcidev *pci;
	Ospreyblk *b;
	int cap, bar, i, typ;
	uvlong pa, off[5], mult;

	if(v->proc != nil)
		return -1;			/* one device, one task */
	pci = pcimatch(nil, 0x1AF4, did);	/* virtio 1.0, legacy interface off */
	if(pci == nil)
		return -1;
	bar = -1;
	mult = 0;
	for(typ = 1; typ <= 4; typ++){
		if((cap = pcienumcaps(pci, ospreyviocapmatch, typ)) < 0)
			return -1;
		i = pcicfgr8(pci, cap+4);
		if(bar < 0)
			bar = i;
		else if(i != bar)
			return -1;		/* all four in one BAR, or the segment would be two */
		off[typ] = pcicfgr32(pci, cap+8);
		if(typ == 2)
			mult = pcicfgr32(pci, cap+16);
	}
	if(pci->mem[bar].bar & 1)
		return -1;			/* ports: not memory a container can be given */
	pa = pci->mem[bar].bar & ~0xFULL;
	if((b = (Ospreyblk*)ospreydata(p, descoff, sizeof(Ospreyblk))) == nil)
		return -1;
	memset(&v->seg, 0, sizeof v->seg);
	v->seg.attr = SG_PHYSICAL | SG_DEVICE;
	v->seg.name = segname;
	v->seg.pa = pa;
	v->seg.size = pci->mem[bar].size;
	if(addphysseg(&v->seg) == nil)
		return -1;
	v->isr = vmap(pa + off[3], BY2PG);
	if(v->isr == nil)
		return -1;
	b->magic = magic;
	b->slicepa = PADDR(ospreybase) + (uvlong)ospreyindex(p) * ospreyslicesize();
	b->barsize = pci->mem[bar].size;
	b->cfg = off[1];
	b->notify = off[2];
	b->notifymult = mult;
	b->isr = off[3];
	b->devcfg = off[4];
	b->sem = sem;
	v->proc = p;
	v->sem = sem;
	pcienable(pci);
	intrenable(pci->intl, ospreyviointr, v, pci->tbdf, what);
	print("osprey %s: exposed virtio %s device %d.%d.%d, BAR %d at %#llux size %lud as \"%s\", interrupt %d as semaphore %d of container %llud\n",
		what, devname, BUSBNO(pci->tbdf), BUSDNO(pci->tbdf), BUSFNO(pci->tbdf), bar, pa, (ulong)pci->mem[bar].size,
		segname, pci->intl, sem, ospreyid(p));
	return 0;
}

static int
ospreyblkexpose(Ospreyproc *p, int sem)
{
	return ospreyvioexpose(&vioblk, p, sem, 0x1042, "virtioblk", Ospreyblkoff, Ospreyblkmagic, "blk", "block");
}

static int
ospreynetexpose(Ospreyproc *p, int sem)
{
	return ospreyvioexpose(&vionet, p, sem, 0x1041, "virtionet", Ospreynetoff, Ospreynetmagic, "net", "network");
}

extern void ospreyloadprog(void);
extern void ospreyloadp9(void);
extern void ospreyenteruser(char*);
extern int ospreyp9pair;
extern int ospreyp9buddy;
extern int ospreyp9linux;
extern int ospreyp9;
extern long (*ospreyexec)(Ospreyproc*, uvlong);
extern int (*ospreywait)(Ospreyproc*, uvlong, long*, uvlong*);
extern int ospreyreplylater(Ospreyproc*, uvlong, uvlong, long, uvlong);
static long ospreyexeckern(Ospreyproc*, uvlong);
static void ospreyuartbind(Ospreyproc*, char*, int, int);
static int ospreyreservekern(Ospreyproc*, uvlong, uvlong);
static int ospreytickkern(Ospreyproc*, int);
static int ospreyblkexpose(Ospreyproc*, int);
static int ospreywaitkern(Ospreyproc*, uvlong, long*, uvlong*);
static void ospreyputproc(Ospreyproc*);
static void ospreyputserver(Ospreyproc*);
static void ospreyputether(Ospreyproc*);
static void ospreyputuart(Ospreyproc*);
static void ospreyclosefds(Ospreyproc*);

static int ospreyuserclientslot = -1;

/*
 * The file server as its own user task, not a kernel task.  It is
 * spawned as a kproc that then enters user mode: a kproc reaches user
 * mode the same way proc0 does, by loading the program into its own
 * address space and calling touser - the kernel-process flag is only
 * about scheduling, and ospreyenteruser clears it.  Bound to its own
 * container the way attach binds - the slot and the process's back-
 * pointer both, or the clock's reaper clears it - it is a peer of the
 * first task, in user space, with its own ring.  arg0 tells the shared
 * image which role to run and which slices to map: its own ring, and the
 * client's slice, which delegation entitles a server to reach.
 */
static void
ospreyuserserver(void *a)
{
	Ospreyproc *sv = a;
	char arg[24];
	int x;

	x = ospreyindex(sv);
	qlock(&ospreylock);
	if(x >= 0 && x < nelem(ospreyprocs)){
		ospreyprocs[x] = up;
		up->osprey = sv;
		ospreysetpid(sv, up->pid);
	}
	qunlock(&ospreylock);
	snprint(arg, sizeof arg, "s %d %d", x, ospreyuserclientslot);
	ospreyloadprog();
	ospreyenteruser(arg);		/* never returns */
}

/*
 * The buddy: a second Plan 9 personality, run as a server.  Same shape as
 * ospreyuserserver, but it loads the personality library (ospreyloadp9,
 * which lays out text, data and bss) rather than the flat stub, and its
 * arg0 puts it in the server role.  It answers 9P about its own name
 * space for the first personality, which delegates to it.
 */
static void
ospreyp9server(void *a)
{
	Ospreyproc *sv = a;
	char arg[24];
	int x;

	x = ospreyindex(sv);
	qlock(&ospreylock);
	if(x >= 0 && x < nelem(ospreyprocs)){
		ospreyprocs[x] = up;
		up->osprey = sv;
		ospreysetpid(sv, up->pid);
	}
	qunlock(&ospreylock);
	snprint(arg, sizeof arg, "s %d %d", x, ospreyuserclientslot);
	ospreyloadp9();
	ospreyenteruser(arg);		/* never returns */
}

/*
 * The buddy operating system's kernel side: forward one unimplemented
 * Plan 9 system call from a legacy container to the peer that serves it.
 * Running as the legacy process, this copies the call's pointer arguments
 * (a name, a read buffer) through the legacy container's own data area,
 * submits the call on its ring so the delegation carries it to the buddy,
 * services and waits for the buddy's kproc to answer, and hands the result
 * back.  arg[0] of the reply is the value the call yields (the descriptor
 * or the byte count), the same slot the ring's own status word occupies.
 */
enum {
	Bopen = 14, Bclose = 4, Bread = 15, Bpread = 50,
	Bwrite = 20, Bpwrite = 51, Bseek = 39, Boseek = 16,
	Bcreate = 22, Bremove = 25, Bfstat = 43, Bstat = 42, Berrstr = 41, Bpipe = 21,
	Brfork = 19, Bbind = 2, Bmount = 46, Bawait = 47,
	/*
	 * Not system calls: what the kernel asks the buddy on a legacy
	 * process's behalf beyond its traps.  exec has the buddy lay a
	 * binary out from its own file system - the entry and the loadable
	 * segments come back in the data area - and page has it supply one
	 * page of that image, which is how a page fault is answered by the
	 * buddy and not the kernel.  Numbered above any Plan 9 system call.
	 */
	Bexec = 100, Bpage = 101, Bmappage = 102, Bforkfds = 103,
	Bargoff = 64, Bnameoff = 256, Bdataoff = 1024,
	Reqsyscall = 15,	/* above every request in policy/syscall.h; the same number in cmd/p9 */
};

/*
 * Put one request to the buddy and wait for its answer: submit on the
 * legacy container's ring so the delegation carries it to the buddy,
 * service and sleep until the buddy's task has replied, and hand back
 * the reply's value.  tries bounds the wait, in 2 ms sleeps.
 */
static long
ospreybuddycall(Ospreyproc *p, int tries)
{
	uvlong sarg[Ospreynarg], rop, rarg[Ospreynarg];
	long status;
	int i;

	memset(sarg, 0, sizeof sarg);
	sarg[0] = ospreyindex(p);	/* which slot this container's slice is: the server maps that one */
	if(ospreysubmit(p, Reqsyscall, sarg) < 0)
		return -1;
	status = -1;
	for(i = 0; i < tries; i++){
		ospreyservicecaller();
		if(ospreycollect(p, &rop, &status, rarg) == 0)
			return status;
		tsleep(&up->sleep, return0, nil, 2);
	}
	return -1;
}

/*
 * A task's own request, made as a system call: number 60, above the
 * Plan 9 table, which an unmodified Plan 9 binary uses whole (its read
 * is pread).  It carries (op, args, nargs); the request is put to the
 * dispatcher directly and
 * its reply value comes back in args[0]; the return is the reply's
 * status.  This is how a server, whose rings run the other way, sets
 * its reservation and takes the clock.
 */
static long ospreymovekern(Ospreyproc*, uvlong*, int);
static long ospreymigcall(int op, uvlong *arg, uvlong *ubuf);
uintptr
#define ReqIoport 20	/* xcall op: grant I/O ports (above ReqPip 18) */
#define ReqKbdnotify 21	/* xcall op: route IRQ1 to the caller as a notification */
#define ReqMousenotify 22	/* xcall op: route IRQ12 (aux) to the caller as a notification */
#define ReqSettime 23	/* xcall op: set the kernel's time of day, seconds since the epoch, from a task's own clock read */
#define ReqMove 24	/* xcall op: carry the calling process, running, into a container of its own - resume, not restart */
#define ReqNote 25	/* xcall op: post the caller a note that is not a fault, so noted(NCONT) has something to resume from */
#define ReqMigsnap 26	/* xcall ops 26-31: a server carrying a process over the wire, and one taking it in (ospreymig* below) */
#define ReqMigpage 27
#define ReqMigmake 28
#define ReqMigput 29
#define ReqMigstart 30
#define ReqMigdone 31
#define ReqAccount 32	/* xcall op: the caller's reservation, what it has used of it this period, and the period, in cycles */
#define ReqKick 33	/* xcall op: a server has put work on a container's output queue in memory; wake that container's select */
ospreyxcall(va_list list)
{
	uvlong op, *ubuf, arg[Ospreynarg];
	long n, status;
	int i;

	op = va_arg(list, int);
	ubuf = va_arg(list, uvlong*);
	n = va_arg(list, long);
	if(n < 0 || n > Ospreynarg)
		return (uintptr)-1;
	validaddr((uintptr)ubuf, Ospreynarg*sizeof(uvlong), 1);
	memset(arg, 0, sizeof arg);
	for(i = 0; i < n; i++)
		arg[i] = ubuf[i];
	if(op == ReqIoport){		/* delegate I/O ports arg[0]..arg[1] to the calling process */
		iogrant(up, (int)arg[0], (int)arg[1]);
		ubuf[0] = 0;
		return 0;
	}
	if(op == ReqKbdnotify){		/* route IRQ1 to this container as a bare notification */
		int c, i;

		ospreykbdproc = up->osprey;	/* whose semaphore the interrupt gives */
		ospreykbdsem = (int)arg[0];
		ospreykbdring = nil;		/* notification-only: the driver reads 0x60 itself */
		/*
		 * The one-time controller setup is done here, in the kernel, not
		 * in the driver's CPL3 kproc: the i8042 command-byte handshake
		 * spins on the status port, and a spin that long at CPL3 in a
		 * personality kproc is a window for a clock or device interrupt
		 * to land while that kproc is the running context, which this
		 * microkernel's interrupt path corrupts (the standing pc64
		 * heisenbug - a user driver taking a legacy IRQ from CPL3
		 * reproduces it reliably).  It runs in kernel context instead,
		 * so an interrupt landing during it is handled normally.
		 *
		 * A config that exposes the framebuffer also armed the kernel's
		 * own ospreykbdintr on IRQ1 (it drains 0x60 into a ring).  Take
		 * it off the line first: intrdisable masks IRQ1 (irqdisable),
		 * so the command-byte read below cannot raise an unhandled
		 * interrupt, and no splhi is needed - the handshake does not
		 * block the block device or the clock while it spins.  The
		 * spins are bounded so a wedged controller cannot hang the
		 * kernel.  intrenable last re-arms IRQ1, buffer already drained,
		 * onto the notification handler alone.  The scancodes themselves
		 * - the data path - the driver still reads with its own inb.
		 */
		intrdisable(Kbdirq, ospreykbdintr, nil, -1, "osprey-kbd");
		for(i = 0; i < 100000 && (inb(Kbdstat) & Kbdready); i++)
			inb(Kbddata);			/* drain stale bytes */
		for(i = 0; i < 100000 && (inb(Kbdstat) & 0x02); i++)
			;				/* input buffer clear */
		outb(Kbdstat, 0x20);			/* read command byte */
		for(i = 0; i < 100000 && !(inb(Kbdstat) & Kbdready); i++)
			;
		c = inb(Kbddata);
		for(i = 0; i < 100000 && (inb(Kbdstat) & 0x02); i++)
			;
		outb(Kbdstat, 0x60);			/* write command byte */
		for(i = 0; i < 100000 && (inb(Kbdstat) & 0x02); i++)
			;
		outb(Kbddata, c | 0x01);		/* enable the keyboard interrupt */
		for(i = 0; i < 100000 && (inb(Kbdstat) & Kbdready); i++)
			inb(Kbddata);			/* drain the echo, if any */
		intrenable(Kbdirq, ospreykbdnotify, nil, -1, "osprey-kbd-notify");
		ubuf[0] = 0;
		return 0;
	}
	if(op >= ReqMigsnap && op <= ReqMigdone)
		return ospreymigcall((int)op, arg, ubuf);
	if(op == ReqKick){
		/*
		 * The work itself went into the container's own memory - its
		 * output queue and packet buffers, which its server maps - so
		 * the kernel carries nothing here but the wakeup, and only for
		 * a container the caller serves.
		 */
		Ospreyproc *c;
		int x;

		if((c = ospreylookup(arg[0])) == nil || ospreyserverof(c) != up->osprey)
			return -1;
		if((x = ospreyindex(c)) >= 0 && x < nelem(ospreyselrend))
			wakeup(&ospreyselrend[x]);
		ubuf[0] = 0;
		return 0;
	}
	if(op == ReqAccount){
		/*
		 * A task asks what its reservation is and what it has used of
		 * it this period, so that work it does on its tick - the
		 * storage task's reclamation - can be paid for by the
		 * reservation rather than by a number compiled in.
		 */
		if(ospreyaccount(up->osprey, &ubuf[0], &ubuf[1], &ubuf[2], &ubuf[4]) < 0)
			return -1;
		ubuf[3] = ospreyhz;
		return 0;
	}
	if(op == ReqNote){
		/*
		 * A note by request: delivered on the way back to user mode
		 * (trap.c's donotify), to the handler the caller registered
		 * with notify(2).  A fault's note cannot be continued from -
		 * the address stays bad - so this is what lets noted(NCONT)
		 * be seen to resume the interrupted program.
		 */
		postnote(up, 1, "osprey: a note by request", NUser);
		ubuf[0] = 0;
		return 0;
	}
	if(op == ReqMove)
		return ospreymovekern(up->osprey, ubuf, (int)arg[0]);	/* the caller does not return; its copy does */
	if(op == ReqSettime){
		/*
		 * The time of day is a task's to set: the kernel reads no clock
		 * at boot (its rtc driver is linked only for the warm-reset
		 * vector the AP start writes through it) and starts at zero,
		 * and the container that read the CMOS clock in user space
		 * hands the kernel the time.  Ticket expiry (ospreycheckticket)
		 * is measured against this, so until a task has set it a ticket
		 * with a real expiry is early by the epoch.  Any container may
		 * set it; who may is one of the checks the demonstration scale
		 * leaves out (item 12 of osprey-progress).
		 */
		todset((vlong)arg[0] * 1000000000LL, 0, 0);
		print("osprey: container %llud set the kernel's time of day by request: %llud seconds since the epoch; the kernel read no clock\n",
			ospreyid(up->osprey), (uvlong)seconds());
		ubuf[0] = 0;
		return 0;
	}
	if(op == ReqMousenotify){
		int c, i;

		ospreymouseproc = up->osprey;	/* whose semaphore the aux interrupt gives */
		ospreymousesem = (int)arg[0];	/* its OWN semaphore, distinct from the keyboard's */
		ospreymousering = nil;		/* notification-only: the driver reads 0x60 itself */
		/*
		 * Same shape as ReqKbdnotify (kernel-side setup, bounded spins,
		 * intrdisable masks IRQ12 so no splhi), but the aux device is
		 * more of a handshake: enable the port, set the aux interrupt and
		 * clock bits in the command byte, and tell the mouse to report.
		 */
		intrdisable(Mouseirq, ospreymouseintr, nil, -1, "osprey-mouse");
		i8042cmd(0xA8);			/* enable the aux (mouse) port */
		i8042cmd(0x20);			/* read the command byte */
		c = i8042rdata();
		if(c < 0)
			c = 0;
		c |= 0x02;			/* aux interrupt enable (IRQ12) */
		c &= ~0x20;			/* aux clock enable (0 = enabled) */
		i8042cmd(0x60);			/* write the command byte */
		i8042wdata(c);
		i8042cmd(0xD4);			/* route the next data byte to the aux port */
		i8042wdata(0xF4);		/* tell the mouse to report movement */
		i8042rdata();			/* eat its ACK (0xFA) */
		for(i = 0; i < 100000 && (inb(Kbdstat) & Kbdready); i++)
			inb(Kbddata);		/* drain */
		intrenable(Mouseirq, ospreymousenotify, nil, -1, "osprey-mouse-notify");
		ubuf[0] = 0;
		return 0;
	}
	if(up->osprey == nil || ospreycall(up->osprey, op, arg, &status) < 0){
		print("osprey: xcall op %llud from container %llud refused\n", op, up->osprey == nil ? 0ULL : ospreyid(up->osprey));
		return (uintptr)-1;
	}
	ubuf[0] = arg[0];
	return (uintptr)status;
}

/*
 * Whether this process has a buddy: a container with a server, which is
 * what answers the system calls the kernel does not.  Configurations
 * forward through ospreybuddyforward when this says so.
 */
int
ospreybuddyhas(void)
{
	return up->osprey != nil && ospreyserverof(up->osprey) != nil;
}

static long ospreyforkkern(Ospreyproc*, ulong);
static long ospreylegacyawait(Ospreyproc*, uintptr, int);

long
ospreybuddyforward(ulong scallnr, uintptr *a)
{
	Ospreyproc *p;
	uvlong *ab;
	uchar *nd, *dd;
	long status;
	int i;

	p = up->osprey;
	if(p == nil || ospreyserverof(p) == nil)
		return -1;			/* no buddy to forward to */

	/*
	 * rfork(RFPROC) makes a process, which is the kernel's to do, not the
	 * buddy's; the namespace-only forms (RFNAMEG and friends) still go to
	 * the buddy below.
	 */
	if(!up->oslinux && scallnr == Brfork && (a[0] & RFPROC))
		return ospreyforkkern(p, a[0]);

	/*
	 * await(buf, n): the fork's other end - the parent reaps a forked or
	 * exec'd child and reads its exit status.  The kernel answers it, since
	 * it is the kernel that made the child and knows when it exits.
	 */
	if(!up->oslinux && scallnr == Bawait)
		return ospreylegacyawait(p, a[0], (int)a[1]);

	if(up->oslinux){
		/* Linux system-call numbers to their Plan 9 equivalents; the
		 * argument positions (descriptor, buffer, count) already line up. */
		switch(scallnr){
		case 0:  scallnr = Bread;  break;	/* read */
		case 2:  scallnr = Bopen;  break;	/* open */
		case 3:  scallnr = Bclose; break;	/* close */
		case 8:  scallnr = Bseek;  break;	/* lseek */
		case 1:  scallnr = Bwrite; break;	/* write */
		default: return -1;
		}
	}

	ab = (uvlong*)ospreydata(p, Bargoff, 4*sizeof(uvlong));
	if(ab == nil)
		return -1;
	ab[0] = scallnr;

	switch(scallnr){
	case Bopen:				/* open(name, mode) */
		nd = ospreydata(p, Bnameoff, 256);
		if(nd == nil)
			return -1;
		{
			char *name = (char*)a[0];
			for(i = 0; i < 255 && name[i] != 0; i++)
				nd[i] = name[i];
			nd[i] = 0;
		}
		ab[1] = 0; ab[2] = a[1]; ab[3] = 0;
		break;
	case Bclose:
		ab[1] = a[0]; ab[2] = 0; ab[3] = 0;
		break;
	case Bread: case Bpread:		/* read(fd,buf,n) / pread(fd,buf,n,off) */
		ab[1] = a[0];
		ab[2] = a[2];
		ab[3] = scallnr == Bpread ? a[3] : (uvlong)-1;
		break;
	case Bwrite: case Bpwrite:		/* the data must already be at Bdataoff */
		dd = ospreydata(p, Bdataoff, a[2]);
		if(dd != nil)
			for(i = 0; i < (long)a[2]; i++)
				dd[i] = ((uchar*)a[1])[i];
		ab[1] = a[0]; ab[2] = a[2];
		ab[3] = scallnr == Bpwrite ? a[3] : (uvlong)-1;
		break;
	case Bseek: case Boseek:
		ab[1] = a[0]; ab[2] = a[1]; ab[3] = a[2];
		break;
	case Bcreate:				/* create(name, mode, perm) */
		nd = ospreydata(p, Bnameoff, 256);
		if(nd == nil)
			return -1;
		{
			char *name = (char*)a[0];
			for(i = 0; i < 255 && name[i] != 0; i++)
				nd[i] = name[i];
			nd[i] = 0;
		}
		ab[1] = 0; ab[2] = a[1]; ab[3] = a[2];	/* mode, perm */
		break;
	case Bremove:				/* remove(name) */
		nd = ospreydata(p, Bnameoff, 256);
		if(nd == nil)
			return -1;
		{
			char *name = (char*)a[0];
			for(i = 0; i < 255 && name[i] != 0; i++)
				nd[i] = name[i];
			nd[i] = 0;
		}
		ab[1] = 0; ab[2] = 0; ab[3] = 0;
		break;
	case Bfstat:				/* fstat(fd, edir, nedir): message back at Bdataoff */
		ab[1] = a[0]; ab[2] = a[2]; ab[3] = 0;
		break;
	case Bstat:				/* stat(name, edir, nedir): name at Bnameoff, message back at Bdataoff */
		nd = ospreydata(p, Bnameoff, 256);
		if(nd == nil)
			return -1;
		{
			char *name = (char*)a[0];
			for(i = 0; i < 255 && name[i] != 0; i++)
				nd[i] = name[i];
			nd[i] = 0;
		}
		ab[1] = 0; ab[2] = a[2]; ab[3] = 0;
		break;
	case Berrstr:				/* errstr(buf, nbuf): text back at Bdataoff */
		ab[1] = 0; ab[2] = a[1]; ab[3] = 0;
		break;
	case Bpipe:				/* pipe(fd[2]): two ints back at Bdataoff */
		ab[1] = 0; ab[2] = 0; ab[3] = 0;
		break;
	case Brfork:				/* rfork(flags) */
		ab[1] = a[0]; ab[2] = 0; ab[3] = 0;
		break;
	case Bbind:				/* bind(name, old, flag): name at Bnameoff, old just past it */
		nd = ospreydata(p, Bnameoff, 512);
		if(nd == nil)
			return -1;
		{
			char *name = (char*)a[0], *old = (char*)a[1];
			for(i = 0; i < 127 && name[i] != 0; i++)
				nd[i] = name[i];
			nd[i] = 0;
			for(i = 0; i < 127 && old[i] != 0; i++)
				nd[128+i] = old[i];
			nd[128+i] = 0;
		}
		ab[1] = a[2]; ab[2] = 0; ab[3] = 0;	/* the flag */
		break;
	case Bmount:				/* mount(fd, afd, old, flag, spec): old at Bnameoff, spec just past it */
		nd = ospreydata(p, Bnameoff, 512);
		if(nd == nil)
			return -1;
		{
			char *old = (char*)a[2], *spec = (char*)a[4];
			for(i = 0; i < 127 && old[i] != 0; i++)
				nd[i] = old[i];
			nd[i] = 0;
			for(i = 0; i < 127 && spec[i] != 0; i++)
				nd[128+i] = spec[i];
			nd[128+i] = 0;
		}
		ab[1] = a[0]; ab[2] = a[3]; ab[3] = 0;	/* fd, flag */
		break;
	default:
		return -1;			/* a trap the buddy does not emulate */
	}

	status = ospreybuddycall(p, 400);
	if(status < 0)
		return -1;

	if((scallnr == Bread || scallnr == Bpread || scallnr == Bfstat || scallnr == Bstat || scallnr == Berrstr) && status > 0){
		/* read/fstat/stat return their bytes in a[1]; errstr in a[0] */
		uchar *dst = (uchar*)(scallnr == Berrstr ? a[0] : a[1]);
		dd = ospreydata(p, Bdataoff, status);
		if(dd != nil)
			for(i = 0; i < status; i++)
				dst[i] = dd[i];
	}
	if(scallnr == Bpipe && status == 0){
		/* the two descriptors, two ints, back into the process's fd[2] */
		dd = ospreydata(p, Bdataoff, 2*sizeof(int));
		if(dd != nil)
			for(i = 0; i < (long)(2*sizeof(int)); i++)
				((uchar*)a[0])[i] = dd[i];
	}
	return status;
}


/*
 * The buddy as the legacy process's loader.  The kernel carries no copy
 * of the Linux binary: it is a file in the buddy's file system, and exec
 * asks the buddy to lay it out.  The buddy reads the ELF headers and
 * answers with the entry and each loadable segment's address, size and
 * flags, from which the kernel makes empty segments; what fills them is
 * the buddy too, a page at a time, as the process faults on them
 * (ospreybuddyfault below).  Returns the number of segments, or -1.
 */
int
ospreybuddyexec(char *name, uvlong *entry, Ospreybuddyseg *segs, int max, int *kind)
{
	Ospreyproc *p;
	uvlong *ab, *d;
	uchar *nd;
	long n;
	int i;

	p = up->osprey;
	if(p == nil || ospreyserverof(p) == nil)
		return -1;
	ab = (uvlong*)ospreydata(p, Bargoff, 4*sizeof(uvlong));
	nd = ospreydata(p, Bnameoff, 256);
	if(ab == nil || nd == nil)
		return -1;
	for(i = 0; i < 255 && name[i] != 0; i++)
		nd[i] = name[i];
	nd[i] = 0;
	ab[0] = Bexec; ab[1] = 0; ab[2] = 0; ab[3] = 0;
	/* at boot the buddy may still be bringing its name space up */
	n = ospreybuddycall(p, 5000);
	if(n <= 0 || n > max)
		return -1;
	d = (uvlong*)ospreydata(p, Bdataoff, (2 + 3*n)*sizeof(uvlong));
	if(d == nil)
		return -1;
	*entry = d[0];
	*kind = (int)d[1];		/* 0: an ELF, a Linux process; 1: a Plan 9 a.out */
	for(i = 0; i < n; i++){
		segs[i].va = d[2+3*i];
		segs[i].memsz = d[3+3*i];
		segs[i].flags = d[4+3*i];
	}
	return n;
}

/*
 * One page of the legacy image, from the buddy: it fills the data area
 * with the page at va - the file's bytes where the image has them, zero
 * where it has none - and the kernel copies it into the frame.  The data
 * area is sized for this in ospreyinit.
 */
static int
ospreybuddypage(uintptr va, uchar *dst)
{
	Ospreyproc *p;
	uvlong *ab;
	uchar *dd;

	p = up->osprey;
	if(p == nil || ospreyserverof(p) == nil)
		return -1;
	ab = (uvlong*)ospreydata(p, Bargoff, 4*sizeof(uvlong));
	if(ab == nil)
		return -1;
	ab[0] = Bpage; ab[1] = va; ab[2] = BY2PG; ab[3] = 0;
	if(ospreybuddycall(p, 400) < 0)
		return -1;
	dd = ospreydata(p, Bdataoff, BY2PG);
	if(dd == nil)
		return -1;
	memmove(dst, dd, BY2PG);
	return 0;
}

/*
 * One page of a file the process mapped, from the buddy: the file's
 * bytes at the offset, zero past its end.  The descriptor is the
 * process's own, which the buddy's table stands for.
 */
static int
ospreybuddymappage(int fd, vlong off, uchar *dst)
{
	Ospreyproc *p;
	uvlong *ab;
	uchar *dd;

	p = up->osprey;
	if(p == nil || ospreyserverof(p) == nil)
		return -1;
	ab = (uvlong*)ospreydata(p, Bargoff, 4*sizeof(uvlong));
	if(ab == nil)
		return -1;
	ab[0] = Bmappage; ab[1] = fd; ab[2] = off; ab[3] = BY2PG;
	if(ospreybuddycall(p, 400) < 0)
		return -1;
	dd = ospreydata(p, Bdataoff, BY2PG);
	if(dd == nil)
		return -1;
	memmove(dst, dd, BY2PG);
	return 0;
}

/*
 * A page fault in a legacy process, taken to the buddy.  exec made the
 * process's text and data segments empty; the first touch of each page
 * lands here, and the page's contents are the buddy's to supply, from
 * the file the image is in its file system.  Returns 0 with the page
 * mapped; 1 when the fault is not the buddy's - the stack, or a page
 * already present, which fault() handles as for any process; and -1
 * when the buddy has no such page, which is the legacy process's own bad
 * address.  This is the other half of the paper's buddy: its page faults
 * interposed as well as its system calls.
 */
int
ospreybuddyfault(uintptr addr, uintptr pc, int read)
{
	Segment *s;
	Pte *etp;
	Page *pg;
	KMap *k;
	uintptr va, soff;
	int type, present, m, r;

	va = addr & ~(uintptr)(BY2PG-1);
	s = seg(up, addr, 1);
	if(s == nil)
		return 1;
	type = s->type & SG_TYPE;
	if(type != SG_TEXT && type != SG_DATA){
		qunlock(s);
		return 1;
	}
	soff = va - s->base;
	etp = s->map[soff/PTEMAPMEM];
	present = etp != nil && etp->pages[(soff&(PTEMAPMEM-1))/BY2PG] != nil;
	qunlock(s);
	if(present)
		return 1;
	pg = newpage(va, nil);
	if(pg == nil)
		return -1;
	k = kmap(pg);
	for(m = 0; m < nelem(up->linuxmap); m++)
		if(up->linuxmap[m].len != 0 && va >= up->linuxmap[m].va && va < up->linuxmap[m].va + up->linuxmap[m].len)
			break;
	if(m < nelem(up->linuxmap))
		r = ospreybuddymappage(up->linuxmap[m].fd, up->linuxmap[m].off + (va - up->linuxmap[m].va), (uchar*)VA(k));
	else
		r = ospreybuddypage(va, (uchar*)VA(k));
	if(r < 0){
		kunmap(k);
		putpage(pg);
		return -1;
	}
	kunmap(k);
	print("osprey buddy: page %#llux %s supplied by the buddy\n", (uvlong)va,
		m < nelem(up->linuxmap) ? "of a mapped file" : "of the legacy image");
	segpage(s, pg);
	return fault(addr, pc, read) < 0 ? -1 : 0;
}

/*
 * The console as a task, the second cut's second piece.  A container
 * of its own holds the console uart, and its uart task is the console
 * driver; every print, the kernel's and the tasks', is staged in that
 * container's data area and put on its output queue, in order, and the
 * task sends it.  The kernel writes the port itself only where the task
 * cannot serve: a panic, before the task exists, or with the queue full.
 * The staging ring has one slot more than the queue holds, and the task
 * takes one piece of work at a time, so a slot is never rewritten while
 * its bytes are still going out.
 */
enum {
	Consid		= 6,
	Consoff		= 1024,
	Consslot	= 256,
	Nconsslot	= 17,		/* Nqueue and one in flight */
};
static Ospreyproc *ospreyconsproc;
static Lock ospreyconslock;
static int ospreyconsnext;
static uvlong ospreyconsbytes, ospreyconsdirect;
uvlong kdebugputsbytes;		/* main.c counts what went out through the bare console */

/*
 * Every print goes to the console task, in order, and none blocks or
 * bypasses it: a print appends to a FIFO the kernel keeps, and the FIFO
 * is fed to the task's output queue, a slot at a time, whenever there is
 * room - by the printer itself, and by the task when its take of a
 * message frees a slot (ospreyconsdrained).  A print cannot wait for
 * room, since it may hold the lock the task needs to make it, and it
 * must not write the port itself, since that put its text out ahead of
 * what was queued and cut lines in two; so the FIFO holds what the
 * queue cannot yet.  Only the FIFO itself overflowing - the task sixteen
 * kilobytes behind - or a panic goes to the port.
 */
enum { Consfifo = 16*1024 };
static char consfifo[Consfifo];
static ulong consin, consout;		/* under ospreyconslock; consin - consout is what waits */
static ulong consslotsum[Nconsslot];	/* a checksum of each slot as filled, checked when the task starts to push it */
static ulong consslotlen[Nconsslot];
static int consslotbad;
static int consinflight = -1;		/* the slot the console task is pushing now, or -1 */
static int consreuse;			/* fills that landed on it */

static ulong
conssum(uchar *d, ulong n)
{
	ulong s = 0;

	while(n-- > 0)
		s = s*31 + *d++;
	return s;
}

static void
ospreyconsflush(Ospreyproc *p)
{
	uchar *d;
	ulong m, off;
	int slot;

	while(consout != consin && ospreyoutputroom(p)){
		off = consout % Consfifo;
		m = consin - consout;
		if(m > Consslot)
			m = Consslot;
		if(m > Consfifo - off)
			m = Consfifo - off;	/* to the end of the FIFO; the rest next slot */
		slot = ospreyconsnext++ % Nconsslot;
		if(slot == consinflight){
			char dbg[80];
			int k = snprint(dbg, sizeof dbg, "[console: slot %d refilled while in flight, next %d]\n", slot, ospreyconsnext);
			consreuse++;
			kdebugputs(dbg, k);
		}
		if((d = ospreydata(p, Consoff + slot*Consslot, Consslot)) == nil)
			return;
		memmove(d, consfifo + off, m);
		consslotsum[slot] = conssum(d, m);
		consslotlen[slot] = m;
		if(ospreyoutput(p, Consoff + slot*Consslot, m) < 0)
			return;
		ospreyconsbytes += m;
		consout += m;
	}
}

static int
ospreyconsput(char *s, int n)
{
	Ospreyproc *p;
	ulong off, m;
	int x;

	if((p = ospreyconsproc) == nil || n <= 0)
		return -1;
	ilock(&ospreyconslock);
	if(Consfifo - (consin - consout) < (ulong)n){
		iunlock(&ospreyconslock);
		ospreyconsdirect += n;
		return -1;		/* the task is a whole FIFO behind: the caller writes the port itself */
	}
	while(n > 0){
		off = consin % Consfifo;
		m = n;
		if(m > Consfifo - off)
			m = Consfifo - off;
		memmove(consfifo + off, s, m);
		consin += m;
		s += m;
		n -= m;
	}
	ospreyconsflush(p);
	iunlock(&ospreyconslock);
	if((x = ospreyindex(p)) >= 0 && x < nelem(ospreyselrend))
		wakeup(&ospreyselrend[x]);
	return 0;
}

/* a slot the console task is about to push: is it still what was put there? */
static void
ospreyconscheck(Ospreyproc *p, uvlong off, uvlong len)
{
	int slot;
	uchar *b;

	if(p != ospreyconsproc || off < Consoff || off >= Consoff + Nconsslot*Consslot)
		return;
	slot = (off - Consoff) / Consslot;
	consinflight = slot;
	b = ospreydata(p, off, len);
	if(b != nil && (consslotlen[slot] != len || consslotsum[slot] != conssum(b, len))){
		consslotbad++;
		print("osprey console: slot %d changed between being filled and being pushed (len %lud vs %llud)\n", slot, consslotlen[slot], len);
	}
}

/* a slot the console task has pushed whole: checked, and no longer in flight */
static void
ospreyconspushed(Ospreyproc *p, uvlong off, uvlong len)
{
	ospreyconscheck(p, off, len);
	if(p == ospreyconsproc)
		consinflight = -1;
}

/* the console task took a message off its output queue: feed it what waits in the FIFO */
static void
ospreyconsdrained(Ospreyproc *p)
{
	int x;

	if(p != ospreyconsproc)
		return;
	ilock(&ospreyconslock);
	ospreyconsflush(p);
	iunlock(&ospreyconslock);
	if(consout != consin && (x = ospreyindex(p)) >= 0 && x < nelem(ospreyselrend))
		wakeup(&ospreyselrend[x]);
}

/* a task's write to the console: through the console task, or the port when there is none */
void
ospreyconsolewrite(char *s, int n)
{
	if(consoletask == nil || (*consoletask)(s, n) < 0)
		kdebugputs(s, n);
}

static void
ospreyconsolestart(void)
{
	Ospreyproc *c;

	c = ospreycreate(Consid, 40000000ULL, 800000000ULL, 200000000ULL);
	if(c == nil)
		return;
	if(waserror()){
		print("osprey console: no console task: %s\n", up->errstr);
		return;
	}
	ospreyuartbind(c, "eia0", 1, 1);
	poperror();
	ospreyconsproc = c;
	consoletask = ospreyconsput;
	print("osprey console: eia0 handed to container %llud; from here the console is its task\n", ospreyid(c));
}

/*
 * Address-space groups (the survey's item 6, its scheduling half).  A
 * container holds not one process but a group of them that share its
 * address space - its arena slice - and run under its one reservation.
 * The scheduler already bills whichever of them runs to the container,
 * through the osprey back-pointer each carries, and the group is a group
 * because they share the slice: what one writes there another reads.
 * The kernel makes the group here, since there is no rfork on the
 * microkernel; the members are kernel processes bound to the container,
 * and only one of a container's processes may work its ring or select
 * (there is one arm area), so a group's extra members do neither - they
 * share the address space and the budget, which is what slide 15 groups.
 *
 * Migration of a running group is not this: migration here is
 * checkpoint-and-restart, and a checkpoint carries the container's
 * state, not a running process's registers, so there is a group to
 * schedule but not yet a running group to resume on another machine.
 */
enum {
	Groupid		= 7,
	Groupmark	= 2048,		/* two bytes in the shared slice, one per member */
	Groupspin	= 40,
};
static Ospreyproc *ospreygroupc;

static void
ospreygroupwork(int member)
{
	uchar *m;
	int i;
	uvlong j;

	/* accrue some of the container's reservation, so status shows the group billed */
	for(i = 0; i < Groupspin; i++){
		for(j = 0; j < 2000000; j++)
			;
		tsleep(&up->sleep, return0, nil, 1);
	}
	if((m = ospreydata(ospreygroupc, Groupmark, 2)) != nil)
		m[member] = member == 0 ? 'A' : 'B';
}

static void
ospreygroupproc(void *a)
{
	int member = (int)(uintptr)a;
	uchar *m;
	int tries;

	/* bind to the shared container: the billing follows this back-pointer */
	up->osprey = ospreygroupc;
	qlock(&ospreylock);
	if(member == 0){
		int x = ospreyindex(ospreygroupc);
		if(x >= 0 && x < nelem(ospreyprocs)){
			ospreyprocs[x] = up;		/* the group's first is its nominal process */
			ospreysetpid(ospreygroupc, up->pid);
		}
	} else
		ospreygroupjoin(ospreygroupc, up->pid);	/* the rest are named beside it */
	qunlock(&ospreylock);

	ospreygroupwork(member);

	if(member == 1){
		/* read what the first wrote: the two share one address space */
		if((m = ospreydata(ospreygroupc, Groupmark, 2)) != nil){
			for(tries = 0; tries < 200 && m[0] != 'A'; tries++)
				tsleep(&up->sleep, return0, nil, 2);
			print("osprey group: container %llud runs two processes sharing its address space under one reservation; process two read '%c' that process one wrote to the shared slice\n",
				ospreyid(ospreygroupc), m[0] == 'A' ? m[0] : '?');
		}
	}
	/* idle, so both are alive when the boot program's status is printed */
	for(;;)
		tsleep(&up->sleep, return0, nil, 1000);
}

/*
 * Make the group: a container of its own, a reservation, and two kernel
 * processes bound to it that share its slice.
 */
static void
ospreygroupdemo(void)
{
	Ospreyproc *c;

	c = ospreycreate(Groupid, 40000000ULL, 800000000ULL, 200000000ULL);
	if(c == nil)
		return;
	ospreygroupc = c;
	kproc("osprey-group-a", ospreygroupproc, (void*)0);
	kproc("osprey-group-b", ospreygroupproc, (void*)(uintptr)1);
	print("osprey group: container %llud made, two processes to share its address space and its one reservation\n", ospreyid(c));
}

/*
 * Starting a program: the exec request.  A container asks for a program
 * by a name in its server's name space; the kernel makes a container of
 * its own for it, delegates that container to the same server, and gives
 * it a process that has the server lay the program out (ospreybuddyexec)
 * and page it in as it runs (ospreybuddyfault).  The program's own system
 * calls are the server's to answer as any legacy process's are.  What
 * the kernel keeps is who started whom, so that wait can be answered:
 * now if the child has exited, when it exits otherwise.  This is the
 * piece the plan calls exec, and it is what wait, the paper's remote
 * invocation, and a personality hosting a program all stand on.
 */
typedef struct Ospreychild Ospreychild;
struct Ospreychild {
	int	used;
	Ospreyproc *child;
	Ospreyproc *parent;
	char	name[128];
	int	done;		/* exited; status is valid */
	long	status;
	int	waiting;	/* the parent has asked and is owed a reply */
	uvlong	waitseq;	/* the sequence of that wait request */
};
static Ospreychild ospreychildren[8];
enum {
	Xreqwait = 4,		/* ReqWait and ReplyDone in policy/syscall.h, which the */
	Xreplydone = 1,		/* device does not include; the adapter checks the same values */
};
static uvlong ospreynextid = 100;	/* container identities for programs exec starts */

static void
ospreyexecproc(void *a)
{
	Ospreychild *e = a;
	Ospreyproc *c = e->child;
	int x;

	x = ospreyindex(c);
	qlock(&ospreylock);
	if(x >= 0 && x < nelem(ospreyprocs)){
		ospreyprocs[x] = up;
		up->osprey = c;
		ospreysetpid(c, up->pid);
	}
	qunlock(&ospreylock);
	switch(ospreyexecbuddy(e->name)){
	case 0:
		ospreyenteruserat();	/* an ELF: at its entry, the Linux way */
	case 1:
		ospreyenteruser(e->name);	/* an a.out: the Plan 9 way, argv0 the name */
	}
	print("osprey exec: %s: the server did not lay it out\n", e->name);
	ospreyexits(-1);
}

/*
 * Ask the buddy to clone the descriptor table of the parent container
 * into the child's, staged the same way ospreybuddypage stages a page
 * request.  Best effort; returns the buddy's status.
 */
static int
ospreyforkfds(Ospreyproc *parent, uvlong childid)
{
	uvlong *ab;

	if(parent == nil || ospreyserverof(parent) == nil)
		return -1;
	ab = (uvlong*)ospreydata(parent, Bargoff, 4*sizeof(uvlong));
	if(ab == nil)
		return -1;
	ab[0] = Bforkfds; ab[1] = childid; ab[2] = 0; ab[3] = 0;
	return ospreybuddycall(parent, 400);
}

/*
 * rfork(RFPROC): fork a legacy container.  This is item 6 of the plan -
 * the process-making half of rfork, which the buddy cannot do because a
 * container is the kernel's to make, not the file server's.  Both forms
 * are built: the plain fork gives the child a private address space (text
 * shared read-only, data and bss copied copy-on-write, its own stack),
 * and RFMEM gives it a shared one (text, data and bss shared, only the
 * stack its own) - a thread.  forkchild crafts a return frame so the child
 * pops out of the scheduler in user mode at the parent's fork point with
 * the return register zero: the child sees 0, the parent sees the child's
 * container id.  The child runs in a container of its own for identity and
 * billing, and is recorded beside exec's children so wait answers it the
 * same way.
 *
 * The catch is the buddy's per-container image: a page of the child that
 * is not resident would fault to the buddy, which laid out no image for
 * the child's new container and would refuse it.  So the whole text and
 * data image is faulted in on the parent first, through ospreybuddyfault
 * (the buddy pager); after that the child needs no buddy for it - only its
 * stack and bss grow, which are the kernel's demand-zero service.
 *
 * What the child does not inherit is the buddy-side descriptor table (it
 * starts with the buddy's default console fds), which is the file server's
 * to clone; that is named in the man page as the next step.
 */
static long
ospreyforkkern(Ospreyproc *parent, ulong flag)
{
	Ospreychild *e;
	Ospreyproc *sv, *c;
	Proc *p;
	Segment *s;
	uintptr va;
	int i, x, share;

	if(parent == nil || (sv = ospreyserverof(parent)) == nil)
		return -1;			/* nobody to serve the child's image */
	if((flag & RFPROC) == 0)
		return -1;			/* the namespace-only forms go to the buddy */
	if(up->dbgreg == nil)
		return -1;			/* no user register frame to copy */

	/*
	 * Bring the whole image resident on the parent, so the child - whose
	 * container the buddy does not know - never has to page from it.  This
	 * is ospreybuddyfault, the buddy pager, not the bare kernel fault: the
	 * kernel fault has no image behind these segments (the buddy supplies
	 * the pages out of band), so it must be the buddy asked, page by page,
	 * over the small image; the pages it cannot cover are holes the
	 * program never touches, and are left alone.
	 */
	for(i = 0; i < NSEG; i++){
		if((s = up->seg[i]) == nil)
			continue;
		if((s->type & SG_TYPE) != SG_TEXT && (s->type & SG_TYPE) != SG_DATA)
			continue;
		for(va = s->base; va < s->top; va += BY2PG){
			if(waserror())
				continue;	/* a hole, or the buddy could not cover it */
			ospreybuddyfault(va, va, 1);
			poperror();
		}
	}

	for(e = ospreychildren; e < &ospreychildren[nelem(ospreychildren)]; e++)
		if(!e->used)
			break;
	if(e == &ospreychildren[nelem(ospreychildren)])
		return -1;			/* the child table is full */

	c = ospreycreate(ospreynextid++, 40000000ULL, 800000000ULL, 200000000ULL);
	if(c == nil)
		return -1;
	ospreydelegate(c, sv);

	if((p = newproc()) == nil){
		ospreyexit(c);
		return -1;
	}

	/*
	 * Ask the buddy to clone the parent's descriptor table into the child's
	 * container, so the child inherits its open files (best effort: if the
	 * buddy refuses, the child keeps the default console descriptors).
	 */
	ospreyforkfds(parent, ospreyid(c));

	qlock(&up->debug);
	qlock(&p->debug);
	p->s = up->s;
	p->slash = up->slash;
	p->dot = up->dot;
	if(p->dot != nil)
		incref(p->dot);
	p->nnote = 0;
	p->notify = up->notify;
	p->notified = 0;
	p->notepending = 0;
	p->lastnote = nil;
	p->noteid = up->noteid;
	p->procmode = up->procmode;
	p->privatemem = up->privatemem;
	p->noswap = up->noswap;
	p->hang = up->hang;
	p->kp = 0;
	p->pgrp = up->pgrp;		/* share the namespace, like a thread fork */
	if(p->pgrp != nil)
		incref(p->pgrp);
	/*
	 * Craft the child's return frame: it pops out of the scheduler in
	 * user mode at the parent's fork point, with the return register 0.
	 */
	forkchild(p, up->dbgreg);
	kstrdup(&p->text, up->text);
	kstrdup(&p->user, up->user);
	kstrdup(&p->args, "");
	p->nargs = 0;
	p->setargs = 0;
	p->insyscall = 0;
	memset(p->time, 0, sizeof(p->time));
	p->time[TReal] = MACHP(0)->ticks;
	p->kentry = up->kentry;
	p->pcycles = -p->kentry;
	pidalloc(p);
	qunlock(&p->debug);
	qunlock(&up->debug);

	/*
	 * The child's address space.  RFMEM shares text/data/bss (dupseg's
	 * sameseg) and copies only the stack; the plain fork copies data and
	 * bss too.  A data segment the buddy pages has no Image, and dupseg's
	 * copy path would incref that nil Image, so for the copy such a
	 * segment is dupped as anonymous memory (SG_BSS): its pages are all
	 * resident from the prefault above, so the copy-on-write is exact, and
	 * with no buddy behind it the child's own faults on it are demand-zero.
	 *
	 * The retype flips the parent's own segment type across the dup, which
	 * is safe only while the parent alone holds the segment: if some other
	 * process shares it (ref > 1, e.g. after a prior RFMEM fork), that
	 * process could fault on it mid-flip and ospreybuddyfault would see the
	 * wrong type.  So the retype is gated on ref == 1 - the parent is
	 * blocked here, so with no sharer there is no concurrent fault - and an
	 * already-shared image-less data segment is kept shared instead.
	 */
	share = flag & RFMEM;
	qlock(&p->seglock);
	for(i = 0; i < NSEG; i++){
		if((s = up->seg[i]) == nil)
			continue;
		if(!share && (s->type&SG_TYPE) == SG_DATA && s->image == nil){
			if(s->ref == 1){
				int savedtype = s->type;
				s->type = (s->type & ~SG_TYPE) | SG_BSS;
				p->seg[i] = dupseg(up->seg, i, 0);
				s->type = savedtype;	/* the parent stays SG_DATA */
			} else
				p->seg[i] = dupseg(up->seg, i, RFMEM);	/* shared: keep sharing */
		} else
			p->seg[i] = dupseg(up->seg, i, share);
	}
	qunlock(&p->seglock);
	/* the parent's data and bss are now shared copy-on-write: drop its
	 * stale mappings so the next write faults and copies. */
	flushmmu();

	/* the child runs the buddy's image the same way the parent does */
	p->osprey = c;
	p->buddyimage = up->buddyimage;
	p->oslinux = up->oslinux;
	p->linuxheap = up->linuxheap;
	p->linuxbrk = up->linuxbrk;
	p->linuxmmapnext = up->linuxmmapnext;

	qlock(&ospreylock);
	x = ospreyindex(c);
	if(x >= 0 && x < nelem(ospreyprocs)){
		ospreyprocs[x] = p;
		ospreysetpid(c, p->pid);
	}
	memset(e, 0, sizeof *e);		/* a reused slot carries no stale wait or status */
	e->used = 1;
	e->child = c;
	e->parent = parent;
	strncpy(e->name, up->text, sizeof e->name - 1);
	e->name[sizeof e->name - 1] = 0;
	qunlock(&ospreylock);

	print("osprey fork: container %llud forked container %llud (%s), sharing container %llud's server; readying child\n",
		ospreyid(parent), ospreyid(c), e->name, ospreyid(sv));
	ready(p);
	return (long)ospreyid(c);
}

/*
 * Resume rather than restart: carry the calling process, as it is - its
 * registers, its stack, its data, its open files and its name space -
 * into a container of its own, and take the container it came from
 * apart.  This is migration on one machine, the form slide 15's group
 * migration would take here: the state that crosses is the process's
 * own, not a checkpoint of its container that it restarts from.  The
 * mechanism is the fork's - a new container delegated to the same
 * server, a new Proc whose return frame is the caller's (forkchild), the
 * caller's segments dupped copy-on-write - with the return register set
 * to the new container's identity instead of 0, and then, instead of two
 * processes, one: the caller's container is destroyed the way an exit
 * destroys it, except that its entry in the child table, and any wait
 * pending on it, are carried to the new container so that its parent
 * reaps the moved process and not a phantom.  The buddy is asked to clone
 * the descriptor table to the new container first, and is told the old
 * one is gone after, so the files stay open across the move.
 *
 * What does not cross: a wire.  The segments are copied within one
 * kernel; carrying them to another machine is what a checkpoint of a
 * container's state already does for the small things and cannot yet do
 * for a process's pages.  And only the calling process moves: a member
 * of an address-space group that is running elsewhere would have to be
 * stopped first, which this does not do.
 */
/*
 * Migration over a wire: a process carried to another machine and
 * resumed there.  The kernel keeps nothing of the wire; the server
 * personality has it (the real stack on the exposed network device),
 * so the kernel hands the process's state to the server by request
 * and the server carries it across in its own TCP connection.  The
 * leaving process asks (ReqMove with the wire flag) and is parked in
 * the kernel while its server pulls its state - the segments and the
 * register frame (ReqMigsnap), then each resident page by halves
 * (ReqMigpage; a half is what the server's data area has room for) -
 * and sends it; the server at the other end pushes the same into a
 * process it has the kernel make (ReqMigmake), fill (ReqMigput) and
 * start (ReqMigstart), and the first server tells the kernel it is
 * done (ReqMigdone), whereupon the parked process's container is
 * taken apart and its parent's wait answered as an exit.  Text pages
 * are carried like the rest - the far machine has no buddy image for
 * them - so the whole image is made resident first, as the fork does.
 */
enum {
	Migoff		= 1024,		/* the sender's staging area in its data area: a header, or half a page */
	Migrxoff	= 5120,		/* the receiver's, clear of the sender's and the block device's ring */
	Mighalf		= 2048,
	Nmigin		= 4,
};
typedef struct Migseg Migseg;
struct Migseg { uvlong idx, type, base, top; };

enum { Nmigmember = 4, Migshared = 1<<8 };	/* a segment type in a header carrying Migshared: shared with the group's first member */
static int migdepartures, migarrivedexited;	/* for the line the two-machine check waits on: both have happened here */

static void
ospreymigexchanged(void)
{
	if(migdepartures > 0 && migarrivedexited > 0)
		print("osprey migrate: the exchange is complete on this machine - %d carried away, %d taken in and done\n",
			migdepartures, migarrivedexited);
}

static struct {
	Ospreyproc *c;		/* the container leaving */
	Proc	*p;		/* its process, parked */
	Proc	*mem[Nmigmember];	/* the members of its group going with it, stopped */
	int	nmem;
	int	pending;
	int	result;		/* 0 not yet, 1 carried, -1 refused */
} migout;
static struct {
	Ospreyproc *c;		/* a container arriving, being filled */
	Proc	*p;
	Ospreyproc *first;	/* the group's first member here, whose segments a later member shares; nil for the first */
	int	npages;
	uchar	ureg[512];	/* its register frame, kept from the header: the pages come through the same staging area */
} migin[Nmigin];

/* the process the sender is asking about: the leaving process, or member k of its group */
static Proc*
ospreymigmember(int k)
{
	if(k == 0)
		return migout.p;
	if(k < 1 || k > migout.nmem)
		return nil;
	return migout.mem[k-1];
}

static Page*
ospreymigpageof(Proc *p, uintptr va, Segment **sp)
{
	Segment *s;
	Pte *pte;
	int i;

	for(i = 0; i < NSEG; i++){
		if((s = p->seg[i]) == nil || va < s->base || va >= s->top)
			continue;
		if(sp != nil)
			*sp = s;
		if(s->map == nil || (pte = s->map[(va - s->base)/PTEMAPMEM]) == nil)
			return nil;
		return pte->pages[((va - s->base) & (PTEMAPMEM-1))/BY2PG];
	}
	return nil;
}

static long
ospreymigcall(int op, uvlong *arg, uvlong *ubuf)
{
	extern int uregsize(void);
	extern void uregsanitize(void*);
	extern void forkchildret(Proc*, uintptr);
	uchar *d;
	Ospreyproc *c;
	Proc *p;
	Segment *s;
	Page *pg;
	KMap *k;
	Migseg *ms;
	uvlong *hdr, n, va, half;
	int i, x, nseg;

	switch(op){
	case ReqMigsnap:
		/*
		 * The leaving process's segments and register frame, into the
		 * server's data area - or those of member arg[1] of its group,
		 * whose segments shared with the leaving process are marked so,
		 * to be shared again at the far end and carried once.  ubuf[1]
		 * says how many there are to ask about in all.
		 */
		if(!migout.pending || migout.c == nil || arg[0] != ospreyid(migout.c) || (p = ospreymigmember((int)arg[1])) == nil)
			return -1;
		if((d = ospreydata(up->osprey, Migoff, Mighalf)) == nil)
			return -1;
		hdr = (uvlong*)d;
		ms = (Migseg*)(hdr + 1);
		nseg = 0;
		for(i = 0; i < NSEG; i++){
			if((s = p->seg[i]) == nil)
				continue;
			ms[nseg].idx = i;
			ms[nseg].type = s->type & SG_TYPE;
			if(arg[1] != 0 && migout.p->seg[i] == s)
				ms[nseg].type |= Migshared;
			ms[nseg].base = s->base;
			ms[nseg].top = s->top;
			nseg++;
		}
		hdr[0] = nseg;
		n = sizeof(uvlong) + nseg*sizeof(Migseg);
		*(uvlong*)(d + n) = uregsize();
		n += sizeof(uvlong);
		memmove(d + n, p->dbgreg, uregsize());
		n += uregsize();
		ubuf[0] = n;
		ubuf[1] = 1 + migout.nmem;
		return 0;
	case ReqMigpage:
		/*
		 * Half of one resident page of the leaving process into the
		 * server's data area, or 0 for one that is not resident; and
		 * in ubuf[1] the next address worth asking about - the page
		 * after this one, or past a whole unmapped chunk of the
		 * segment - so a walk over a large, mostly empty segment costs
		 * a request per resident page, not per page.
		 */
		if(!migout.pending || arg[0] != ospreyid(migout.c) || (p = ospreymigmember((int)(arg[2] >> 8))) == nil)
			return -1;			/* arg[2]: the half in its low bit, the member above it - a request carries three words */
		va = arg[1] & ~(uvlong)(BY2PG-1);
		half = arg[2] & 1;
		if((d = ospreydata(up->osprey, Migoff, Mighalf)) == nil)
			return -1;
		s = nil;
		pg = ospreymigpageof(p, va, &s);
		if(s == nil){
			ubuf[0] = 0;
			ubuf[1] = ~0ULL;
			return 0;
		}
		if(pg != nil && !pagedout(pg)){
			k = kmap(pg);
			memmove(d, (uchar*)VA(k) + half*Mighalf, Mighalf);
			kunmap(k);
			ubuf[0] = Mighalf;
			ubuf[1] = va + BY2PG;
			return 0;
		}
		ubuf[0] = 0;
		for(va += BY2PG; va < s->top; ){
			Pte *pte;

			if(s->map == nil || (pte = s->map[(va - s->base)/PTEMAPMEM]) == nil){
				va = s->base + ((va - s->base)/PTEMAPMEM + 1)*PTEMAPMEM;
				continue;
			}
			pg = pte->pages[((va - s->base) & (PTEMAPMEM-1))/BY2PG];
			if(pg != nil && !pagedout(pg))
				break;
			va += BY2PG;
		}
		ubuf[1] = va < s->top ? va : s->top;
		return 0;
	case ReqMigmake:
		/* a container and a process for what is arriving, its segments as the header says */
		if((d = ospreydata(up->osprey, Migrxoff, Mighalf)) == nil)
			return -1;
		for(x = 0; x < Nmigin && migin[x].c != nil; x++)
			;
		if(x == Nmigin)
			return -1;
		hdr = (uvlong*)d;
		nseg = hdr[0];
		if(nseg < 0 || nseg > NSEG)
			return -1;
		ms = (Migseg*)(hdr + 1);
		n = sizeof(uvlong) + nseg*sizeof(Migseg);
		if(*(uvlong*)(d + n) != uregsize() || n + sizeof(uvlong) + uregsize() > Mighalf || uregsize() > sizeof migin[x].ureg)
			return -1;		/* a frame of another shape: another kernel, or another machine */
		memmove(migin[x].ureg, d + n + sizeof(uvlong), uregsize());
		c = ospreycreate(ospreynextid++, 40000000ULL, 800000000ULL, 200000000ULL);
		if(c == nil)
			return -1;
		ospreydelegate(c, up->osprey);		/* the taker serves it, as an exec's child is served */
		if((p = newproc()) == nil){
			ospreyexit(c);
			return -1;
		}
		{
			Proc *fp = nil;
			int y;

			/* a later member of a group: the group's first member here, whose segments it shares */
			if(arg[0] != 0){
				for(y = 0; y < nelem(ospreyprocs); y++)
					if(ospreyprocs[y] != nil && ospreyprocs[y]->osprey != nil && ospreyid(ospreyprocs[y]->osprey) == arg[0]){
						fp = ospreyprocs[y];
						break;
					}
				if(fp == nil){
					ospreyexit(c);
					return -1;
				}
				migin[x].first = fp->osprey;
			}
			qlock(&p->seglock);
			for(i = 0; i < nseg; i++){
				int type;

				if(ms[i].idx >= NSEG || ms[i].top <= ms[i].base)
					continue;
				if((ms[i].type & Migshared) && fp != nil && fp->seg[ms[i].idx] != nil){
					p->seg[ms[i].idx] = fp->seg[ms[i].idx];	/* shared with the first member, here as there */
					incref(p->seg[ms[i].idx]);
					continue;
				}
				type = (ms[i].type & ~Migshared);
				type = type == SG_TEXT ? SG_TEXT : type == SG_STACK ? SG_STACK : SG_BSS;
				p->seg[ms[i].idx] = newseg(type, ms[i].base, (ms[i].top - ms[i].base)/BY2PG);
				if(p->seg[ms[i].idx] != nil && type == SG_TEXT)
					p->seg[ms[i].idx]->flushme = 1;	/* code is fetched from it: what exec marks a text segment with, and fault() insists on */
			}
			qunlock(&p->seglock);
		}
		kstrdup(&p->text, "arrived");
		kstrdup(&p->user, eve);
		kstrdup(&p->args, "");
		/*
		 * newproc leaves what its last occupant had in the fields the
		 * kernel proper does not know - the Linux ABI switch, the
		 * buddy's image, the note handler - and a fork copies its
		 * parent's; this process has no parent here, so each is set.
		 * A Plan 9 process, of no buddy's image, with no handler yet.
		 */
		p->kp = 0;
		p->oslinux = 0;
		p->buddyimage = 0;
		p->linuxheap = -1;
		p->linuxbrk = 0;
		p->linuxmmapnext = 0;
		p->linuxsighandler = 0;
		p->linuxsigrestorer = 0;
		p->notify = nil;
		p->notified = 0;
		p->nnote = 0;
		p->notepending = 0;
		p->lastnote = nil;
		p->privatemem = 0;
		p->noswap = 0;
		p->hang = 0;
		p->pgrp = nil;
		p->slash = nil;
		p->dot = nil;
		p->osprey = c;
		migin[x].c = c;
		migin[x].p = p;
		migin[x].npages = 0;
		if(arg[0] == 0)
			migin[x].first = nil;
		ubuf[0] = ospreyid(c);
		return 0;
	case ReqMigput:
		/* half a page into the arriving process, the page made if it is its first half */
		for(x = 0; x < Nmigin; x++)
			if(migin[x].c != nil && arg[0] == ospreyid(migin[x].c))
				break;
		if(x == Nmigin || (d = ospreydata(up->osprey, Migrxoff, Mighalf)) == nil)
			return -1;
		p = migin[x].p;
		va = arg[1] & ~(uvlong)(BY2PG-1);
		half = arg[2] & 1;
		s = nil;
		pg = ospreymigpageof(p, va, &s);
		if(s == nil)
			return -1;
		if(pg == nil){
			pg = newpage(va, nil);
			pg->va = va;
			segpage(s, pg);
			migin[x].npages++;
		}
		k = kmap(pg);
		memmove((uchar*)VA(k) + half*Mighalf, d, Mighalf);
		kunmap(k);
		ubuf[0] = Mighalf;
		return 0;
	case ReqMigstart:
		/* the register frame, and the process runs: it resumes at its request's return, told where it is */
		for(x = 0; x < Nmigin; x++)
			if(migin[x].c != nil && arg[0] == ospreyid(migin[x].c))
				break;
		if(x == Nmigin || (d = ospreydata(up->osprey, Migrxoff, Mighalf)) == nil)
			return -1;
		p = migin[x].p;
		c = migin[x].c;
		uregsanitize(migin[x].ureg);
		forkchild(p, (Ureg*)migin[x].ureg);
		forkchildret(p, (uintptr)ospreyid(c));
		p->insyscall = 0;
		memset(p->time, 0, sizeof(p->time));
		p->time[TReal] = MACHP(0)->ticks;
		pidalloc(p);
		qlock(&ospreylock);
		i = ospreyindex(c);
		if(i >= 0 && i < nelem(ospreyprocs)){
			ospreyprocs[i] = p;
			ospreysetpid(c, p->pid);
		}
		{
			Ospreychild *e;

			for(e = ospreychildren; e < &ospreychildren[nelem(ospreychildren)]; e++)
				if(!e->used)
					break;
			if(e < &ospreychildren[nelem(ospreychildren)]){
				memset(e, 0, sizeof *e);
				e->used = 1;
				e->child = c;
				/* the taker's, so its exit is reported like an exec'd child's; a group's later member is the first's, so that reaps it */
				e->parent = migin[x].first != nil ? migin[x].first : up->osprey;
				strncpy(e->name, migin[x].first != nil ? "arrived over the wire, a group member" : "arrived over the wire", sizeof e->name - 1);
			}
		}
		qunlock(&ospreylock);
		print("osprey migrate: a process arrived over the wire and is container %llud here, %d pages, its registers and stack as they were; resumed\n",
			ospreyid(c), migin[x].npages);
		migin[x].c = nil;
		migin[x].p = nil;
		ready(p);
		ubuf[0] = 0;
		return 0;
	case ReqMigdone:
		if(!migout.pending || migout.c == nil || arg[0] != ospreyid(migout.c))
			return -1;
		migout.result = arg[1] != 0 ? 1 : -1;
		ubuf[0] = 0;
		return 0;
	}
	return -1;
}

/*
 * The members of the caller's address-space group: the processes of
 * other containers that share a data or bss segment with it - what an
 * rfork(RFPROC|RFMEM) made.  At most Nmember, for the demonstration.
 */
enum { Nmember = 4 };

static int
ospreymembers(Proc **mem, int max)
{
	Proc *q;
	int x, i, n;

	n = 0;
	for(x = 0; x < nelem(ospreyprocs) && n < max; x++){
		if((q = ospreyprocs[x]) == nil || q == up || q->osprey == nil)
			continue;
		for(i = 0; i < NSEG; i++){
			if(up->seg[i] == nil || q->seg[i] != up->seg[i])
				continue;
			if((up->seg[i]->type & SG_TYPE) == SG_DATA || (up->seg[i]->type & SG_TYPE) == SG_BSS){
				mem[n++] = q;
				break;
			}
		}
	}
	return n;
}

/* take a container apart the way an exit does, with nothing to tell a parent */
static void
ospreyunmake(Ospreyproc *c)
{
	qlock(&ospreylock);
	ospreytellandwake(c, OpGone);
	ospreyclosefds(c);
	ospreyputproc(c);
	ospreyputserver(c);
	ospreyputether(c);
	ospreyputuart(c);
	ospreyexit(c);
	qunlock(&ospreylock);
}

/*
 * The new process of a moved one: a Proc whose return frame is the
 * moved process's own (its registers as they were when it entered the
 * kernel), given the container c and the segments seg[] - the mover's
 * new ones where the old ones were shared, its own stack copied.
 */
static Proc*
ospreymoveproc(Proc *q, Ospreyproc *c, Segment **shared, Proc *sharer)
{
	Proc *p;
	int i;

	if((p = newproc()) == nil)
		return nil;
	qlock(&q->debug);
	qlock(&p->debug);
	p->s = q->s;
	p->slash = q->slash;
	p->dot = q->dot;
	if(p->dot != nil)
		incref(p->dot);
	p->nnote = 0;
	p->notify = q->notify;
	p->notified = 0;
	p->notepending = 0;
	p->lastnote = nil;
	p->noteid = q->noteid;
	p->procmode = q->procmode;
	p->privatemem = q->privatemem;
	p->noswap = q->noswap;
	p->hang = q->hang;
	p->kp = 0;
	p->pgrp = q->pgrp;
	if(p->pgrp != nil)
		incref(p->pgrp);
	forkchild(p, q->dbgreg);		/* its registers: it resumes where it entered the kernel */
	kstrdup(&p->text, q->text);
	kstrdup(&p->user, q->user);
	kstrdup(&p->args, "");
	p->nargs = 0;
	p->setargs = 0;
	p->insyscall = 0;
	memset(p->time, 0, sizeof(p->time));
	p->time[TReal] = MACHP(0)->ticks;
	p->kentry = q->kentry;
	p->pcycles = -p->kentry;
	pidalloc(p);
	qunlock(&p->debug);
	qunlock(&q->debug);

	qlock(&p->seglock);
	for(i = 0; i < NSEG; i++){
		if(q->seg[i] == nil)
			continue;
		if(shared != nil && sharer != nil && q->seg[i] == sharer->seg[i] && shared[i] != nil){
			p->seg[i] = shared[i];	/* what it shared with the mover, it shares with the mover's new process */
			incref(shared[i]);
		} else
			p->seg[i] = dupseg(q->seg, i, 0);	/* its own, the stack above all: copied */
	}
	qunlock(&p->seglock);

	p->osprey = c;
	p->buddyimage = q->buddyimage;
	p->oslinux = q->oslinux;
	p->linuxheap = q->linuxheap;
	p->linuxbrk = q->linuxbrk;
	p->linuxmmapnext = q->linuxmmapnext;
	return p;
}

static long
ospreymovekern(Ospreyproc *old, uvlong *ubuf, int group)
{
	Ospreychild *e, *ne, *me;
	Ospreyproc *sv, *c, *mc;
	Proc *p, *mem[Nmember], *mp;
	Segment *s;
	uintptr va;
	int i, x, nmem, k, tries;
	extern void forkchildret(Proc*, uintptr);

	if(old == nil || (sv = ospreyserverof(old)) == nil || up->dbgreg == nil)
		return -1;
	for(e = ospreychildren; e < &ospreychildren[nelem(ospreychildren)]; e++)
		if(e->used && e->child == old)
			break;
	if(e == &ospreychildren[nelem(ospreychildren)])
		return -1;			/* the boot program stays where it is */
	for(ne = ospreychildren; ne < &ospreychildren[nelem(ospreychildren)]; ne++)
		if(!ne->used)
			break;
	if(ne == &ospreychildren[nelem(ospreychildren)])
		return -1;
	/*
	 * The group, once every reason to refuse has been checked, since a
	 * stopped member is only let go here: its members must be stopped
	 * before their registers can be taken.  Each is asked to stop on
	 * its next way back to user mode (the config's donotify runs
	 * procctl); a member that never comes back - blocked for good -
	 * cannot be moved, and the move is refused rather than left half
	 * done, the members that had stopped readied again.
	 */
	nmem = 0;
	if(group & 1){
		nmem = ospreymembers(mem, Nmember);
		for(k = 0; k < nmem; k++)
			mem[k]->procctl = Proc_stopme;
		for(k = 0; k < nmem; k++){
			for(tries = 0; tries < 200 && mem[k]->state != Stopped; tries++)
				tsleep(&up->sleep, return0, nil, 10);
			if(mem[k]->state != Stopped){
				int j;

				print("osprey move: a member of container %llud's group (pid %d) did not stop; the group is not moved\n",
					ospreyid(old), mem[k]->pid);
				for(j = 0; j < nmem; j++){
					if(mem[j]->state == Stopped)
						ready(mem[j]);		/* parked in procctl: goes on */
					else
						mem[j]->procctl = 0;
				}
				return -1;
			}
		}
	}

	/* the whole image resident, as for a fork: the new container is one the buddy has laid nothing out for */
	for(i = 0; i < NSEG; i++){
		if((s = up->seg[i]) == nil)
			continue;
		if((s->type & SG_TYPE) != SG_TEXT && (s->type & SG_TYPE) != SG_DATA)
			continue;
		for(va = s->base; va < s->top; va += BY2PG){
			if(waserror())
				continue;
			ospreybuddyfault(va, va, 1);
			poperror();
		}
	}

	if(group & 2){
		/*
		 * To the wire: ask the server to carry this process, and wait
		 * here, parked, while it pulls the state out; then either go
		 * (the container taken apart, the parent's wait answered as an
		 * exit) or, if nobody took it, return refused to the caller.
		 */
		Ospreychild *me;

		if(migout.pending)
			return -1;
		for(i = 0; i < NSEG; i++){
			if((s = up->seg[i]) == nil)
				continue;
			if((s->type & SG_TYPE) != SG_TEXT && (s->type & SG_TYPE) != SG_DATA)
				continue;
			for(va = s->base; va < s->top; va += BY2PG){
				if(waserror())
					continue;
				ospreybuddyfault(va, va, 1);
				poperror();
			}
		}
		migout.c = old;
		migout.p = up;
		migout.nmem = nmem;
		for(k = 0; k < nmem; k++)
			migout.mem[k] = mem[k];
		migout.result = 0;
		migout.pending = 1;
		ospreytellandwake(old, OpMigrate);
		for(tries = 0; tries < 3000 && migout.result == 0; tries++)
			tsleep(&up->sleep, return0, nil, 20);
		migout.pending = 0;
		if(migout.result <= 0){
			print("osprey migrate: container %llud's process was not taken by the other machine; it stays\n", ospreyid(old));
			for(k = 0; k < nmem; k++)
				if(mem[k]->state == Stopped)
					ready(mem[k]);		/* the group goes on here */
			migout.nmem = 0;
			return -1;
		}
		/* the members went with it: their containers go, their parked processes end */
		for(k = 0; k < nmem; k++){
			Ospreyproc *oc = mem[k]->osprey;

			print("osprey migrate: group member container %llud (pid %d) has gone over the wire with it; container %llud destroyed\n",
				ospreyid(oc), mem[k]->pid, ospreyid(oc));
			/* its entry in the child table goes too, or a container made later in the same slot would exit against it */
			qlock(&ospreylock);
			for(me = ospreychildren; me < &ospreychildren[nelem(ospreychildren)]; me++)
				if(me->used && me->child == oc)
					me->used = 0;
			qunlock(&ospreylock);
			mem[k]->procctl = Proc_exitme;
			ospreyunmake(oc);
			if(mem[k]->state == Stopped)
				ready(mem[k]);
		}
		migout.nmem = 0;
		print("osprey migrate: container %llud's process (%s) has gone over the wire; container %llud destroyed, its parent told\n",
			ospreyid(old), e->name, ospreyid(old));
		migdepartures++;
		ospreymigexchanged();
		qlock(&ospreylock);
		for(me = ospreychildren; me < &ospreychildren[nelem(ospreychildren)]; me++)
			if(me->used && me->child == old)
				break;
		if(me < &ospreychildren[nelem(ospreychildren)]){
			if(me->waiting){
				ospreyreplylater(me->parent, me->waitseq, Xreqwait, Xreplydone, 0);
				me->used = 0;
			} else {
				me->done = 1;
				me->status = 0;
			}
		}
		qunlock(&ospreylock);
		ospreyunmake(old);
		ospreywakeup();
		pexit("migrated", 0);
	}
	c = ospreycreate(ospreynextid++, 40000000ULL, 800000000ULL, 200000000ULL);
	if(c == nil)
		return -1;
	ospreydelegate(c, sv);
	if((p = newproc()) == nil){
		ospreyexit(c);
		return -1;
	}
	ospreyforkfds(old, ospreyid(c));	/* the open files, cloned to the new container by the buddy */
	ubuf[0] = ospreyid(c);			/* before the copy, so the moved process's copy of its args carries it */

	qlock(&up->debug);
	qlock(&p->debug);
	p->s = up->s;
	p->slash = up->slash;
	p->dot = up->dot;
	if(p->dot != nil)
		incref(p->dot);
	p->nnote = 0;
	p->notify = up->notify;
	p->notified = 0;
	p->notepending = 0;
	p->lastnote = nil;
	p->noteid = up->noteid;
	p->procmode = up->procmode;
	p->privatemem = up->privatemem;
	p->noswap = up->noswap;
	p->hang = up->hang;
	p->kp = 0;
	p->pgrp = up->pgrp;
	if(p->pgrp != nil)
		incref(p->pgrp);
	forkchild(p, up->dbgreg);		/* the caller's registers: it resumes at this call's return */
	forkchildret(p, (uintptr)ospreyid(c));	/* ... told where it now is */
	kstrdup(&p->text, up->text);
	kstrdup(&p->user, up->user);
	kstrdup(&p->args, "");
	p->nargs = 0;
	p->setargs = 0;
	p->insyscall = 0;
	memset(p->time, 0, sizeof(p->time));
	p->time[TReal] = MACHP(0)->ticks;
	p->kentry = up->kentry;
	p->pcycles = -p->kentry;
	pidalloc(p);
	qunlock(&p->debug);
	qunlock(&up->debug);

	/* the address space, copied: as the plain fork does it, image-less data as anonymous memory */
	qlock(&p->seglock);
	for(i = 0; i < NSEG; i++){
		if((s = up->seg[i]) == nil)
			continue;
		if((s->type&SG_TYPE) == SG_DATA && s->image == nil){
			if(s->ref == 1){
				int savedtype = s->type;
				s->type = (s->type & ~SG_TYPE) | SG_BSS;
				p->seg[i] = dupseg(up->seg, i, 0);
				s->type = savedtype;
			} else
				p->seg[i] = dupseg(up->seg, i, RFMEM);
		} else
			p->seg[i] = dupseg(up->seg, i, 0);
	}
	qunlock(&p->seglock);
	flushmmu();

	p->osprey = c;
	p->buddyimage = up->buddyimage;
	p->oslinux = up->oslinux;
	p->linuxheap = up->linuxheap;
	p->linuxbrk = up->linuxbrk;
	p->linuxmmapnext = up->linuxmmapnext;

	qlock(&ospreylock);
	x = ospreyindex(c);
	if(x >= 0 && x < nelem(ospreyprocs)){
		ospreyprocs[x] = p;
		ospreysetpid(c, p->pid);
	}
	*ne = *e;				/* the child-table entry moves with it: parent, name, and a wait pending */
	ne->child = c;
	e->used = 0;
	/* what was a child of the old container is a child of the new */
	for(me = ospreychildren; me < &ospreychildren[nelem(ospreychildren)]; me++)
		if(me->used && me->parent == old)
			me->parent = c;
	qunlock(&ospreylock);

	print("osprey move: container %llud's process (%s) resumed as container %llud, registers and stack as they were; container %llud destroyed\n",
		ospreyid(old), ne->name, ospreyid(c), ospreyid(old));

	/*
	 * The group: each stopped member gets a container of its own and a
	 * process with its registers and its own stack, sharing the mover's
	 * new segments where it shared the old; its old container goes the
	 * way the mover's does, and its old process is readied to exit.
	 */
	for(k = 0; k < nmem; k++){
		Ospreyproc *oc = mem[k]->osprey;

		mc = ospreycreate(ospreynextid++, 40000000ULL, 800000000ULL, 200000000ULL);
		if(mc == nil)
			break;
		ospreydelegate(mc, sv);
		ospreyforkfds(oc, ospreyid(mc));
		mp = ospreymoveproc(mem[k], mc, p->seg, up);
		if(mp == nil){
			ospreyexit(mc);
			break;
		}
		qlock(&ospreylock);
		x = ospreyindex(mc);
		if(x >= 0 && x < nelem(ospreyprocs)){
			ospreyprocs[x] = mp;
			ospreysetpid(mc, mp->pid);
		}
		for(me = ospreychildren; me < &ospreychildren[nelem(ospreychildren)]; me++)
			if(me->used && me->child == oc)
				break;
		if(me < &ospreychildren[nelem(ospreychildren)]){
			for(ne = ospreychildren; ne < &ospreychildren[nelem(ospreychildren)]; ne++)
				if(!ne->used)
					break;
			if(ne < &ospreychildren[nelem(ospreychildren)]){
				*ne = *me;
				ne->child = mc;
				if(ne->parent == old)
					ne->parent = c;
				me->used = 0;
			}
		}
		qunlock(&ospreylock);
		print("osprey move: group member container %llud (pid %d, sharing the address space) resumed as container %llud with container %llud's; container %llud destroyed\n",
			ospreyid(oc), mem[k]->pid, ospreyid(mc), ospreyid(c), ospreyid(oc));
		ready(mp);
		mem[k]->procctl = Proc_exitme;	/* the old process, parked in donotify, ends when it runs */
		ospreyunmake(oc);		/* ... which ospreyputproc's release may already have readied */
		if(mem[k]->state == Stopped)
			ready(mem[k]);
	}
	ready(p);

	/* and the old container goes, as on exit, but with nothing to tell a parent */
	ospreyunmake(old);
	ospreywakeup();
	pexit("moved", 0);
	return -1;				/* not reached */
}

static long
ospreyexeckern(Ospreyproc *parent, uvlong nameoff)
{
	Ospreychild *e;
	Ospreyproc *sv, *c;
	uchar *nd;
	int i;

	if(parent == nil || (sv = ospreyserverof(parent)) == nil)
		return -1;		/* nobody to lay the program out */
	if((nd = ospreydata(parent, nameoff, 1)) == nil)
		return -1;
	for(e = ospreychildren; e < &ospreychildren[nelem(ospreychildren)]; e++)
		if(!e->used)
			break;
	if(e == &ospreychildren[nelem(ospreychildren)])
		return -1;
	memset(e, 0, sizeof *e);
	for(i = 0; i < (int)sizeof e->name - 1; i++){
		if(ospreydata(parent, nameoff + i, 1) == nil || nd[i] == 0)
			break;
		e->name[i] = nd[i];
	}
	e->name[i] = 0;
	/* ospreylock is held: dispatch runs under it, as ospreyuserprep did */
	c = ospreycreate(ospreynextid++, 40000000ULL, 800000000ULL, 200000000ULL);
	if(c == nil)
		return -1;
	ospreydelegate(c, sv);
	e->used = 1;				/* the slot was cleared above, before the name */
	e->child = c;
	e->parent = parent;
	print("osprey exec: container %llud starts %s for container %llud, served by container %llud\n",
		ospreyid(c), e->name, ospreyid(parent), ospreyid(sv));
	kproc("osprey-exec", ospreyexecproc, e);
	return (long)ospreyid(c);
}

/*
 * A task sets its own reservation, in microseconds; the scheduler keeps
 * time in the cycle counter, so the conversion is here, where hz is
 * known.  The deadline is the period.
 */
static int
ospreyreservekern(Ospreyproc *p, uvlong usbudget, uvlong usperiod)
{
	uvlong budget, period;

	if(usperiod == 0 || usbudget > usperiod)
		return -1;
	ospreynow();				/* sets ospreyhz */
	budget = usbudget * ospreyhz / 1000000;
	period = usperiod * ospreyhz / 1000000;
	if(ospreysetreservation(p, budget, period, period) < 0)
		return -1;
	print("osprey: container %llud reserves %llud us of every %llud us, by request (%llud of %llud at %llud hz)\n",
		ospreyid(p), usbudget, usperiod, budget, period, ospreyhz);
	return 0;
}

/* a task asks for the clock: its semaphore given on every tick, or off */
static int
ospreytickkern(Ospreyproc *p, int sem)
{
	int x;

	if((x = ospreyindex(p)) < 0 || x >= nelem(ospreyticksem))
		return -1;
	if(sem < 0)
		ospreyticksem[x] = -1;
	else {
		if((ulong)sem >= ospreynsem())
			return -1;
		ospreyticksem[x] = sem;
	}
	print("osprey: container %llud takes the clock tick on semaphore %d, by request\n", ospreyid(p), sem);
	return 0;
}

/*
 * What the talk's dumptask prints at the end of a run: every
 * container's reservation, what it used of it, and the best-effort time
 * beyond it.  Printed when the boot program exits, a line at a time.
 */
static void
ospreydumptasks(void)
{
	char *buf, *s, *e;

	buf = smalloc(Statuslen);
	qlock(&ospreylock);
	ospreystatus(buf, Statuslen, ospreynow(), ospreyhz);
	qunlock(&ospreylock);
	for(s = buf; *s != 0; s = e){
		e = strchr(s, '\n');
		if(e == nil)
			e = s + strlen(s);
		else
			e++;
		if(strncmp(s, "proc ", 5) == 0 || strncmp(s, "core ", 5) == 0)
			print("osprey status: %.*s", (int)(e - s), s);
	}
	free(buf);
	{
		/* each container's process: where the scheduler has it, what it waits in, its last user pc */
		extern char *statename[];
		extern uintptr uregpc(void*);
		Proc *q;
		int x;

		for(x = 0; x < nelem(ospreyprocs); x++){
			if((q = ospreyprocs[x]) == nil || q->osprey == nil)
				continue;
			print("osprey proc: container %llud pid %lud %s: %s%s%s, in a syscall %d, user pc %#p\n",
				ospreyid(q->osprey), q->pid, q->text, statename[q->state],
				q->psstate != nil ? " in " : "", q->psstate != nil ? q->psstate : "",
				q->insyscall, uregpc(q->dbgreg));
		}
	}
	if(ospreyconsproc != nil)
		print("osprey console: %llud bytes of this went out through the console task, %llud straight to the port\n",
			ospreyconsbytes, ospreyconsdirect);
	print("osprey replies: %llud containers woken for a reply of their own, nobody else\n", ospreyroutewakes);
	{
		extern uvlong uartputsbytes, uartputslate, kdebugputsbytes;
		extern char uartputssample[];

		print("osprey console: %d slots found changed between fill and push, %d refilled while in flight\n", consslotbad, consreuse);
		print("osprey console: %llud bytes went to the port through uartputs, %llud of them after the task took over (the first: \"%s\"), and %llud through kdebugputs\n",
			uartputsbytes, uartputslate, uartputssample, kdebugputsbytes);
	}
}

static int
ospreywaitkern(Ospreyproc *parent, uvlong seq, long *status, uvlong *value)
{
	Ospreychild *e, *live;

	live = nil;
	for(e = ospreychildren; e < &ospreychildren[nelem(ospreychildren)]; e++){
		if(!e->used || e->parent != parent)
			continue;
		if(e->done){
			*status = Xreplydone;
			*value = (uvlong)e->status;
			e->used = 0;
			return 0;
		}
		live = e;
	}
	if(live == nil)
		return -1;		/* nothing to wait for */
	live->waiting = 1;
	live->waitseq = seq;
	return 1;
}

/*
 * await(buf, n) for a legacy program: block until a child of this
 * container has exited, then write its wait message - pid, three times,
 * and the quoted exit status - into the program's buffer, the way the
 * Plan 9 await(2) does, so the ordinary library wait() parses it.  The
 * exit status is always empty here because the personality's exits drops
 * its string (it exits 0), so a reaped child reads as a clean exit.  The
 * wait is a bounded kernel sleep between scans, never a CPL3 spin.
 */
static long
ospreylegacyawait(Ospreyproc *parent, uintptr ubuf, int nbuf)
{
	Ospreychild *e;
	char msg[128];
	int n, haslive;

	if(nbuf <= 0)
		return -1;
	for(;;){
		haslive = 0;
		qlock(&ospreylock);
		for(e = ospreychildren; e < &ospreychildren[nelem(ospreychildren)]; e++){
			if(!e->used || e->parent != parent)
				continue;
			if(e->done){
				n = snprint(msg, sizeof msg, "%llud 0 0 0 ''", ospreyid(e->child));
				e->used = 0;
				qunlock(&ospreylock);
				if(n > nbuf)
					n = nbuf;
				if(waserror())
					return -1;
				validaddr(ubuf, n, 1);
				memmove((void*)ubuf, msg, n);
				poperror();
				return n;
			}
			haslive = 1;
		}
		qunlock(&ospreylock);
		if(!haslive)
			return -1;		/* no children to wait for */
		tsleep(&up->sleep, return0, nil, 50);
	}
}

/*
 * A user program's exit.  The boot program's exit idles the machine, as
 * it always has: tearing the boot process down would panic.  A program
 * exec started is a process like any other: its parent is told, if it is
 * waiting, or the status is kept until it asks; the container is taken
 * apart the way the exit control message takes one apart; and the
 * process ends.
 */
void
ospreyexits(long status)
{
	Ospreychild *e;
	Ospreyproc *p;

	p = up->osprey;
	for(e = ospreychildren; e < &ospreychildren[nelem(ospreychildren)]; e++)
		if(e->used && e->child == p)
			break;
	if(p == nil || e == &ospreychildren[nelem(ospreychildren)]){
		ospreydumptasks();
		print("osprey user: the program exited; the microkernel idles\n");
		for(;;)
			tsleep(&up->sleep, return0, nil, 1000);
	}
	print("osprey exec: container %llud (%s) exited with status %ld\n",
		ospreyid(p), e->name, status);
	if(strcmp(e->name, "arrived over the wire") == 0){
		migarrivedexited++;
		ospreymigexchanged();
	}
	qlock(&ospreylock);
	if(e->waiting){
		ospreyreplylater(e->parent, e->waitseq, Xreqwait, Xreplydone, (uvlong)status);
		e->used = 0;
	} else {
		e->done = 1;
		e->status = status;
	}
	ospreytellandwake(p, OpGone);
	ospreyclosefds(p);
	ospreyputproc(p);
	ospreyputserver(p);
	ospreyputether(p);
	ospreyputuart(p);
	ospreyexit(p);
	qunlock(&ospreylock);
	ospreywakeup();
	pexit("exited", 0);
}

int
ospreyuserprep(void)
{
	Ospreyproc *p;
	int x;

	ospreyinit();
	x = -1;
	qlock(&ospreylock);
	if(!waserror()){
		p = ospreycreate(1, 40000000ULL, 800000000ULL, 200000000ULL);
		if(p != nil){
			Ospreyproc *sv;

			x = ospreyindex(p);
			ospreyuserclientslot = x;
			if(x >= 0 && x < nelem(ospreyprocs)){
				ospreyprocs[x] = up;
				/*
				 * Bind the process to the container the way attach
				 * does: setting the process's own back-pointer, not
				 * just the slot.  Without it the clock's reaper sees
				 * a slot whose process claims no container and clears
				 * the binding on the next tick - the race that made
				 * the ring round trip fail about half the time.
				 */
				up->osprey = p;
				ospreysetpid(p, up->pid);
				/* expose the keyboard and mouse interrupts:
				 * program both devices, then arm the interrupts */
				ospreykbdenable(p, 1);
				ospreymouseenable(p, 2);
				ospreyinputarm();
			}
			/*
			 * A file server for the program to reach over the ring:
			 * a second container the client delegates to, with a task
			 * of its own that answers the client's read requests.
			 */
			/*
			 * The file server the client reaches over the ring is
			 * now its own user program, not a kernel task: a second
			 * container the client delegates to, run in user mode by
			 * ospreyuserserver.  Two user tasks then exchange the
			 * open and read messages, the kernel only routing them.
			 */
			sv = ospreycreate(3, 40000000ULL, 800000000ULL, 200000000ULL);
			if(sv != nil){
				ospreydelegate(p, sv);
				/*
				 * The block device, if the machine has one, goes to
				 * the server: the personality that will be the file
				 * system is the one that drives the disk.
				 */
				/* the console, a task from here: every print below goes through it */
				ospreyconsolestart();
				/* a group of processes sharing one container's address space */
				if(ospreyp9pair)
					ospreygroupdemo();
				if(ospreyp9){
					Ospreyproc *ut;

					ospreyblkexpose(sv, 1);
					ospreynetexpose(sv, 5);	/* and the network device, the same way, on the fifth semaphore */
					/*
					 * And the second serial port, served by a task
					 * in a container of its own - Cut B's uart,
					 * which the first attempt could not get bytes
					 * out of.  Its own container, since a container
					 * has one select and one arm area, and the
					 * server's are the server program's; delegated
					 * to the server, so the server may map its slice
					 * and put work on its output queue, which is
					 * how a driver task is given work.
					 */
					ut = ospreycreate(5, 40000000ULL, 800000000ULL, 200000000ULL);
					if(ut != nil && !waserror()){
						uchar *d;
						char *line = "osprey uart task on the microkernel: served by a task, out of the second serial port\n";
						int i;
						enum { Uartoff = 3072 };

						ospreyuartbind(ut, "eia1", 1, 0);
						print("osprey uart: eia1 handed to container %llud, served by its task\n", ospreyid(ut));
						/*
						 * One line for the task to send, put on its
						 * output queue from here: a place in its own
						 * data area and how much of it, the way the
						 * output control message gives a task work.
						 * No container maps its slice for this.
						 */
						d = ospreydata(ut, Uartoff, strlen(line));
						if(d != nil){
							for(i = 0; line[i] != 0; i++)
								d[i] = line[i];
							ospreyoutput(ut, Uartoff, i);
							ospreywakeup();
						}
						poperror();
					}
				}
				if(ospreyp9pair || ospreyp9buddy || ospreyp9linux)
					kproc("p9-buddy", ospreyp9server, sv);
				else
					kproc("osprey-fs", ospreyuserserver, sv);
			}
		}
		poperror();
	}
	qunlock(&ospreylock);
	return x;
}

void
ospreymicroboot(void)
{
	Ospreyproc *p;
	uvlong arg[Ospreynarg], op;
	long status;
	int i, n;

	print("osprey micro: a task, no plan 9 boot\n");
	/*
	 * Prove the last-resort console before relying on the device stack:
	 * this line is written straight to COM1 by kdebugputc, owing nothing
	 * to consuart or devcons, which is the output a panic will need once
	 * the console is a userspace driver task.
	 */
	{
		static char m[] = "osprey micro: bare console (kdebugputc) works\n";
		kdebugputs(m, sizeof m - 1);
	}
	/*
	 * The arena is set up in the device init hook, which the Plan 9
	 * boot runs in init0 and this boot skips.  It is idempotent, so
	 * ensure it here before the first container.
	 */
	ospreyinit();
	status = -1;
	n = 0;
	qlock(&ospreylock);
	if(waserror()){
		qunlock(&ospreylock);
		print("osprey micro: error: %s\n", up->errstr);
		for(;;)
			tsleep(&up->sleep, return0, nil, 1000);
	}
	p = ospreycreate(1, 40000000ULL, 800000000ULL, 200000000ULL);
	if(p == nil)
		print("osprey micro: no container, arena not ready\n");
	else {
		for(i = 0; i < 4; i++){
			memset(arg, 0, sizeof arg);
			if(ospreysubmit(p, ospreyop("poll"), arg) < 0)
				break;
			while(ospreyservicep(p, fastticks(nil)) > 0)
				;
			if(ospreycollect(p, &op, &status, arg) == 0)
				n++;
		}

		/*
		 * The paper's central primitive: a select over arms woken by
		 * an interrupt.  Ask the clock to give the container a
		 * semaphore on every tick, wait on it with an OSdown arm, and
		 * a few ticks later the arm is ready - a driver task's select
		 * driven by a real interrupt, with no name space in reach.
		 */
		{
			Ospreyarm *arm;
			int x, woke;

			woke = 0;
			x = ospreyindex(p);
			arm = ospreydata(p, 0, sizeof(Ospreyarm));
			if(x >= 0 && ospreynsem() > 0 && arm != nil){
				arm->op = OSdown;
				arm->obj = 0;
				arm->buf = 0;
				ospreyticksem[x] = 0;
				for(i = 0; i < 200 && ospreyselectready(p, 0, 1) < 0; i++)
					tsleep(&up->sleep, return0, nil, 5);
				ospreyticksem[x] = -1;
				woke = ospreyselectready(p, 0, 1) >= 0;
			}
			if(woke)
				print("osprey micro: a select woke on the clock interrupt's semaphore\n");
			else
				print("osprey micro: the clock tick never reached the select\n");
		}


		/*
		 * A file operation answered by another container, not by the
		 * kernel: the delegation the paper calls a personality.  A
		 * second container is made the client's server; the client
		 * submits an open; servicing the client forwards it to the
		 * server's request ring rather than to ospreykernop, whose
		 * open reaches namec, a panic in this kernel.  Playing the
		 * server in the same loop rather than as a task - so no lock
		 * is released and no second process contends for it - the
		 * boot reads the forwarded request off the server's ring with
		 * an OSget arm, answers it done, routes the answer to the
		 * client, and the client collects it.  The open completing at
		 * all is the proof the server answered: the kernel's own
		 * personality could not, it would have panicked in namec.
		 *
		 * This is not p9srv and not "the 9front personality"; the boot
		 * stands in for the server a program would be.  When this was
		 * written the note here said a real program server could not
		 * run on this kernel, since loading a program is sysproc.c and
		 * the cut removed it.  That is no longer true: ospreyloadp9
		 * loads and enters the personality library without sysproc.c,
		 * and the p964 and p9pair configurations run it as ordinary
		 * user programs - one of them a second personality answering
		 * 9P for the first over this same delegation path.  What runs
		 * here is still just the path itself, in the microkernel boot.
		 */
		{
			Ospreyproc *sv;
			Ospreyarm *arm;
			uvlong sarg[Ospreynarg], sop, roff;
			long sstatus;
			int answered;

			answered = 0;
			roff = 256;
			sv = ospreycreate(3, 40000000ULL, 800000000ULL, 200000000ULL);
			if(sv != nil && ospreydelegate(p, sv) == 0){
				memset(sarg, 0, sizeof sarg);
				if(ospreysubmit(p, ospreyop("open"), sarg) == 0){
					ospreyservicep(p, fastticks(nil));
					if(ospreyrequestready(sv)
					&& (arm = ospreydata(sv, 0, sizeof(Ospreyarm))) != nil){
						arm->op = OSget;
						arm->obj = 0;		/* the request ring */
						arm->buf = roff;	/* where the request lands */
						if(ospreyselect(sv, 0, 1) == 0){
							ospreyanswer(sv, roff, StatusDone);
							ospreyroute(sv);
							if(ospreycollect(p, &sop, &sstatus, sarg) == 0
							&& sstatus == StatusDone)
								answered = 1;
						}
					}
				}
			}
			if(answered)
				print("osprey micro: a delegated open was answered by a server container, not the kernel\n");
			else
				print("osprey micro: the delegated open was not answered\n");
			if(sv != nil){
				ospreydelegate(p, nil);
				ospreyexit(sv);
			}
		}

		ospreyexit(p);
	}
	poperror();
	qunlock(&ospreylock);
	print("osprey micro: %d of 4 requests answered, last status %ld\n",
		n, status);

	/*
	 * Exercise process teardown before idling: spawn a kernel task and
	 * let it exit through pexit and the stubbed group closes.
	 */
	ospreymicroexited = 0;
	kproc("micro-exit", ospreymicroexit, nil);
	for(i = 0; i < 200 && ospreymicroexited == 0; i++)
		tsleep(&up->sleep, return0, nil, 10);
	if(ospreymicroexited)
		print("osprey micro: a kernel task exited, teardown clean\n");
	else
		print("osprey micro: kernel task never ran\n");

	print("osprey micro: idle\n");
	for(;;)
		tsleep(&up->sleep, return0, nil, 1000);
}

static void
ospreyinit(void)
{
	uvlong size;
	char *cf;
	int i;

	if(ospreybase != nil)
		return;
	/*
	 * How big a slice is, before there is one.  Each of these is a
	 * count the container reads out of its own map and nothing here
	 * indexes an array with, except txbuf, which has a ceiling for the
	 * reason its declaration gives.  A value below what the tree was
	 * built with is refused by the adapter rather than obeyed.
	 */
	/*
	 * A buddy carries a page of a legacy image through the data area
	 * on every fault, and the built-in data area is smaller than a
	 * page plus the offset the data starts at.  Every personality
	 * configuration can be asked to exec one, so all of them get it.
	 */
	if(ospreyp9)
		ospreysetsize("data", 2*BY2PG, 0);
		ospreysetsize("pktbuf", 32, 0);	/* the user-space network driver's receive ring of 16, and room for more */
		ospreysetsize("txbuf", 16, 0);	/* and its transmit ring */
	for(i = 0; i < nelem(ospreysizeconf); i++){
		if((cf = getconf(ospreysizeconf[i].conf)) == nil)
			continue;
		if(ospreysetsize(ospreysizeconf[i].name,
			strtoul(cf, nil, 0), ospreysizeconf[i].max) < 0)
			print("osprey: %s=%s refused\n",
				ospreysizeconf[i].conf, cf);
	}
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
	ospreyetherea = ospreycardea;
	ospreynamed = ospreytellandwake;
	ospreyexec = ospreyexeckern;
	ospreywait = ospreywaitkern;
	ospreyreserve = ospreyreservekern;
	ospreytickreq = ospreytickkern;
	ospreyreset();		/* so no tick can find it uninitialised */
	ospreytimer = ospreyclock;
	/*
	 * Expose the firmware frame buffer as a physical segment here too,
	 * not only on the microkernel path, so a process of the full 9front
	 * personality can map it with segattach - the exposed-address-space
	 * way in for a user-level draw stack.  Idempotent, so the xup64 boot
	 * calling it as well is harmless.
	 */
	/*
	 * Where a frame buffer is exposed and this is the full personality,
	 * also expose the PS/2 mouse as a physical segment for a user-level
	 * mouse driver (rio needs /dev/mouse).  Not on xup64, whose proc0
	 * arms the same interrupt into a container instead.
	 */
	if(ospreyframebuffer() == 0 && !ospreyuser)
		ospreymouseexpose();
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
		/*
		 * The container's own name space first.  What a container
		 * calls a thing is in its own table, which travels in its
		 * checkpoint; what the name stands for here is this
		 * personality's business.  A name the table does not hold is
		 * left as it stands and resolved by the kernel around it,
		 * which is what a buddy operating system is for.
		 */
		a = ospreyresolve(p, a);
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

	case OpSend:
		/*
		 * Put a frame the container wrote in one of its own transmit
		 * buffers on the wire.  arg[0] names the buffer and arg[1]
		 * how much of it to send.  Nothing is copied: the Block that
		 * stands for that buffer is queued to the interface and the
		 * card reads the frame out of the container's slice.  The
		 * Block comes back to the container's pool when the card has
		 * finished with it, which is what makes the buffer safe to
		 * write again; a container that asks before then is told to
		 * retry rather than allowed to change a frame in flight.
		 */
		{
			Ether *e;
			Block *b;
			uvlong txoff, txn, txsize;
			ulong len;
			int bi;

			if((e = (Ether*)ospreyether[x]) == nil){
				result[0] = 1;
				return StatusError;
			}
			bi = (int)arg[0];
			if(bi < 0 || bi >= ospreyntxblk[x]){
				result[0] = 2;
				result[1] = ospreyntxblk[x];
				return StatusError;
			}
			if(ospreytxsizes(p, &txoff, &txn, &txsize) < 0){
				result[0] = 3;
				return StatusError;
			}
			len = (ulong)arg[1];
			if(len < 14 || len > txsize - Rbtlr){
				result[0] = 4;
				result[1] = txsize;
				return StatusError;
			}
			/*
			 * A frame going out is network the container is
			 * using, and its caps are what bound that.  Charged
			 * while it is in flight and given back when the card
			 * has finished with it, which is the same rule a
			 * packet coming in is held to.
			 */
			if(ospreynetcharge(p, len, 1) < 0){
				result[0] = 5;
				return StatusError;
			}
			b = ospreytxblk[x][bi];
			if(!ospreytxtake(&ospreytxpool[x], b, ospreyntxblk[x])){
				ospreynetrelease(p, len, 1);
				return StatusRetry;
			}
			ospreytxlen[x][bi] = len;
			ospreytxheld[x] |= 1ULL<<bi;
			ospreytxavail(x);
			b->rp = b->base;
			b->wp = b->base + len;
			b->flag = BINTR;
			/*
			 * The source address is the kernel's to write, as it
			 * is in etheroq: a container may say what it likes
			 * about where a frame is going and nothing about
			 * where it came from.
			 */
			memmove(((Etherpkt*)b->rp)->s, e->ea, Eaddrlen);
			e->outpackets++;
			qbwrite(e->oq, b);
			if(e->transmit != nil)
				e->transmit(e);
			result[0] = len;
			return StatusDone;
		}

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
 * The other kind of thing a name can walk to: a uart a container has
 * been given, by the uart's own name.  The talk's slide 20 opens
 * /dev/uart/eia0 over pi-p and reads and writes its attributes, answered
 * by the driver task; here the name is the uart's, and the thing is
 * there while a container holds it.  Returns the container's slot, or
 * -1.
 */
enum { Pipuartoff = 2048 };	/* where a write to d is staged in the container's data area */

static int
pipwalkuart(char *name, long n)
{
	char buf[32];
	Uart *u;
	int i;

	while(n > 0 && *name == '/')
		name++, n--;
	if(n <= 0 || n >= sizeof buf)
		return -1;
	memmove(buf, name, n);
	buf[n] = 0;
	u = uartlookup(buf);		/* by the device's name, eia1, as the uart control message names it */
	if(u == nil)
		return -1;
	for(i = 0; i < nelem(ospreyuart); i++)
		if(ospreyuart[i] == u && ospreyat(i) != nil)
			return i;
	return -1;
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
		if(id == ~0ULL && (i = pipwalkuart((char*)m+k, alen)) >= 0){
			/* a uart, opened by whoever the container holding it is for */
			if(!ospreymay(ospreyat(i), pipwho(ps))){
				piperror(ps, tag, "not yours");
				break;
			}
			if((nf = pipnewfid(ps, nfid)) == nil){
				piperror(ps, tag, "fid in use or no free fids");
				break;
			}
			nf->id = 0;
			nf->uart = i + 1;
			nf->open = 1;
			nf->base = 0;
			if((r = pipreply(ps, PipRopen, tag, 24)) != nil){
				pipput(r, 8, 0x10000 + i);
				pipput(r+8, 8, 0);
				pipput(r+16, 8, nf->lease - pipnow());
			}
			break;
		}
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
		if(f->uart){
			/*
			 * The uart's attributes: the talk's *, b and d.  b is
			 * the line speed; d is what the uart has received, as
			 * much as is there, without waiting.
			 */
			Uart *u;
			int slot = f->uart - 1;

			if(slot < 0 || slot >= nelem(ospreyuart) || (u = ospreyuart[slot]) == nil){
				piperror(ps, tag, "the uart has been given back");
				break;
			}
			if(strcmp(attr, "*") == 0)
				k = snprint(val, sizeof val, "* b d name");
			else if(strcmp(attr, "b") == 0)
				k = snprint(val, sizeof val, "%d", u->baud);
			else if(strcmp(attr, "name") == 0)
				k = snprint(val, sizeof val, "%s", u->name);
			else if(strcmp(attr, "d") == 0){
				k = u->iq != nil ? qconsume(u->iq, val, sizeof val - 1) : 0;
				if(k < 0)
					k = 0;
			} else {
				piperror(ps, tag, "no such attribute");
				break;
			}
			if(cnt >= 0 && k > cnt)
				k = cnt;
			if((r = pipreply(ps, PipRread, tag, 8+2+k)) != nil){
				pipput(r, 8, 0);
				pipput(r+8, 2, k);
				memmove(r+10, val, k);
			}
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
		if((f = pipfid(ps, fid)) != nil && f->open && f->uart){
			/*
			 * Set attr d: the bytes go out through the driver task,
			 * as work on the container's output queue - staged in
			 * the container's data area, the queue told where -
			 * exactly as the output control message does.  Set attr
			 * b: the speed, as a control message the task answers.
			 * Neither is a version: a uart is not a file.
			 */
			Ospreyproc *q;
			uchar *d;
			uvlong sarg[Ospreynarg];
			int slot = f->uart - 1;

			if(slot < 0 || slot >= nelem(ospreyuart) || ospreyuart[slot] == nil || (q = ospreyat(slot)) == nil){
				piperror(ps, tag, "the uart has been given back");
				break;
			}
			if(!pipstill(ps, f)){
				piperror(ps, tag, "not yours");
				break;
			}
			if(strcmp(attr, "d") == 0){
				if((d = ospreydata(q, Pipuartoff, vlen)) == nil){
					piperror(ps, tag, "no room in the container's data area");
					break;
				}
				memmove(d, val, vlen);
				if(ospreyoutput(q, Pipuartoff, vlen) < 0){
					piperror(ps, tag, "the output queue is full");
					break;
				}
				ospreywakeup();
			} else if(strcmp(attr, "b") == 0){
				memset(sarg, 0, sizeof sarg);
				sarg[0] = strtoul(val, nil, 0);
				if(ospreysubmit(q, 2 /* ReqOpen, which the task answers as its speed */, sarg) < 0){
					piperror(ps, tag, "the request ring is full");
					break;
				}
				ospreywakeup();
			} else {
				piperror(ps, tag, "attribute is not writable");
				break;
			}
			if((r = pipreply(ps, PipRwrite, tag, 8)) != nil)
				pipput(r, 8, 0);
			break;
		}
		if(f == nil || f->open == 0 || f->id == 0){
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
		if(f->uart){
			f->used = 0;		/* nothing to commit: a uart has no versions */
			if((r = pipreply(ps, PipRclose, tag, 8)) != nil)
				pipput(r, 8, 0);
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
			/* reading is taking, so only from what is ours */
			while(ospreymay(p, up->user) && s < e - 1
			&& ospreycollect(p, &op, &status, arg) == 0)
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

/*
 * The bigger control messages are functions of their own.  What
 * forced it was the compiler: 6c segfaults on ospreywrite once it is
 * given one more live pointer local, and that function was nine
 * hundred lines and thirty-nine cases.  Each of these runs under the
 * lock the caller holds and errors the same way it did.
 */
static void
ospreyctlether(Cmdbuf *cb)
{
	Ospreyproc *p;
	void *et;
	int i, x;

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
		ospreytxsem[x] = -1;
		ospreytxpool[x].done = nil;
		/* give back what the card was still holding for it */
		for(i = 0; i < ospreyntxblk[x]; i++)
			if((ospreytxheld[x] & (1ULL<<i)) != 0)
				ospreynetrelease(p, ospreytxlen[x][i], 1);
		ospreytxheld[x] = 0;
		ospreysettxavail(p, 0);
		ospreyether[x] = nil;
		if(ospreyheld[x] != nil){
			freeb(ospreyheld[x]);
			ospreyheld[x] = nil;
		}
		wakeup(&ospreyselrend[x]);
		return;
	}
	if(cb->nf != 4 && cb->nf != 5)
		error(Ecmdargs);
	i = atoi(cb->f[3]);
	if(i < 0 || (ulong)i >= ospreynsem())
		error(Ebadarg);
	/*
	 * A fifth field names the semaphore a transmit buffer gives
	 * when the card has finished with it.  Without one a
	 * container has to offer a buffer and be refused, which is
	 * what it had to do before there was anywhere to say this.
	 */
	if(cb->nf == 5){
		ospreytxsem[x] = atoi(cb->f[4]);
		if(ospreytxsem[x] < 0
		|| (ulong)ospreytxsem[x] >= ospreynsem())
			error(Ebadarg);
	} else
		ospreytxsem[x] = -1;
	if(ospreyetherlookup == nil
	|| (et = ospreyetherlookup(cb->f[2])) == nil)
		error(Enonexist);
	if(ospreyether[x] != nil && ospreyether[x] != et)
		ospreyputether(p);	/* give the last one back first */
	if(ospreylendbufs(p, x) < 0)
		error(Enomem);
	if(ospreylendtx(p, x) < 0)
		error(Enomem);
	ospreyether[x] = et;
	ospreyethersem[x] = i;
	((Ether*)et)->rbpool = &ospreyrbpool[x];
}

static void
ospreyctluart(Cmdbuf *cb)
{
	Ospreyproc *p;
	Uart *ut;
	int i, x;

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
		return;
	}
	i = atoi(cb->f[3]);
	if(i < 0 || (ulong)i >= ospreynsem())
		error(Ebadarg);
	ospreyuartbind(p, cb->f[2], i, 0);
}

/*
 * The hand-over itself, for the control message above and for a boot
 * that gives a task a uart before there is a name space to say so in.
 * The uart is enabled the device's way first - line format, speed, the
 * queues - since a port nobody has opened has none of that set, which
 * is what left the microkernel's first uart task driving a port whose
 * bytes never reached the line.
 */
static void
ospreyuartbind(Ospreyproc *p, char *name, int sem, int takeconsole)
{
	Uart *ut;
	int x;

	if((x = ospreyindex(p)) < 0 || x >= nelem(ospreyuart))
		error(Ebadarg);
	if((ut = uartlookup(name)) == nil)
		error(Enonexist);
	if(ut->special || (ut->console && !takeconsole))
		error(Eperm);
	if(ut->console){
		/*
		 * The console leaves the kernel: from here its prints go
		 * through the task (consoletask, set by the caller), and
		 * the polled putchar is what is left for a panic.
		 */
		serialoq = nil;
		ut->console = 0;
	}
	/*
	 * All four, not two: without send the task would have
	 * nothing to write with and would drop what it was given
	 * without telling anyone.
	 */
	if(ut->phys->interrupt == nil || ut->phys->intrmask == nil
	|| ut->phys->send == nil || ut->phys->taskenable == nil)
		error(Ebadarg);
	if(uartenable(ut) == nil)
		error(Enomem);
	if(ospreyuart[x] != nil && ospreyuart[x] != ut)
		ospreyputuart(p);	/* and the last uart */
	ospreyuart[x] = ut;
	ospreyuartsem[x] = sem;
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
}

static long
ospreywrite(Chan *c, void *a, long n, vlong offset)
{
	Cmdbuf *cb;
	Cmdtab *ct;
	Ospreyproc *p;
	Ospreyproc *q2;
	Proc *q;
	Selwait sw;
	char *nm;
	uvlong arg[Ospreynarg];
	uvlong waitid;		/* whose wait it is, across a sleep */
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
				waitid = ospreyid(p);
				ospreyblock(p);
				qunlock(&ospreylock);
				if(waserror()){
					qlock(&ospreylock);
					ospreyawake(x, waitid);
					nexterror();
				}
				sleep(&ospreyreplyrend[x], ospreyreply, p);
				poperror();
				qlock(&ospreylock);
				ospreyawake(x, waitid);
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
		/*
		 * ospreymine and not ospreyproc: taking a container off the
		 * core it was attached to is a thing only whoever the
		 * container is for may do, as attaching it was.  This looked
		 * the container up without asking who was writing, which
		 * meant anybody could stop anybody's.
		 */
		if(ospreydetach(ospreymine(cb->f[1])) < 0)
			error(Ebadarg);
		break;

	case CMexit:
		/* the chans first: cclose can sleep, and exit takes locks */
		p = ospreymine(cb->f[1]);
		/*
		 * Tell its server first: after this the container is gone
		 * and there is nothing left to say whose the server's fds,
		 * mapping and process were.
		 */
		ospreytellandwake(p, OpGone);
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
			waitid = ospreyid(p);
			ospreyblock(p);
			qunlock(&ospreylock);
			if(waserror()){
				qlock(&ospreylock);
				ospreyawake(x, waitid);
				nexterror();
			}
			sleep(&ospreyroomrend[x], ospreyroom, p);
			poperror();
			qlock(&ospreylock);
			ospreyawake(x, waitid);
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
		/*
		 * Only the caller's containers.  A request is answered in
		 * the namespace of whoever asked for it to be, so servicing
		 * somebody else's container would resolve their names here
		 * and leave the channel in their hands.
		 */
		while(i-- > 0){
			int did;

			did = 0;
			for(p = ospreynext(nil); p != nil; p = ospreynext(p))
				if(ospreymay(p, up->user)
				&& ospreyservicep(p, ospreynow()) > 0)
					did++;
			if(did == 0)
				break;
		}
		for(p = ospreynext(nil); p != nil; p = ospreynext(p))
			if(ospreymay(p, up->user))
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
		if(ospreyetherlookup == nil || ospreyetherlookup(cb->f[1]) == nil)
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
		/*
		 * Naming a container as your server puts your requests on
		 * its ring and gives it the right to reach your slice, so it
		 * has to be a container you may have: its own, or one whose
		 * owner has granted you.  Anyone could name anyone before,
		 * which made a container's ring a place a stranger could put
		 * work.
		 */
		q2 = ospreyproc(cb->f[2]);
		if(!ospreymay(q2, up != nil ? up->user : nil))
			error(Eperm);
		if(ospreydelegate(p, q2) < 0)
			error(Ebadarg);
		break;

	case CMether:
		ospreyctlether(cb);
		break;
	case CMuart:
		ospreyctluart(cb);
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
			waitid = ospreyid(p);
			ospreyblock(p);
			qunlock(&ospreylock);
			if(waserror()){
				qlock(&ospreylock);
				ospreyawake(x, waitid);
				nexterror();
			}
			sleep(&ospreyselrend[x], ospreyselok, &sw);
			poperror();
			qlock(&ospreylock);
			ospreyawake(x, waitid);
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

	case CMmemfree:
		/*
		 * What alloc charges, given back.  Without it memused only
		 * ever grew: a container could ask for memory up to its
		 * limit and then never ask again, however little of it it
		 * was still using.
		 */
		p = ospreymine(cb->f[1]);
		ospreymemrelease(p, strtoul(cb->f[2], nil, 0));
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
		/*
		 * ospreymine and not ospreyproc: this writes into a
		 * container's own data area, which is its memory.  It is
		 * here for the shell, and being here for the shell is not a
		 * reason for it to be here for everybody.
		 */
		p = ospreymine(cb->f[1]);
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
			waitid = ospreyid(p);
			ospreyblock(p);
			qunlock(&ospreylock);
			if(waserror()){
				qlock(&ospreylock);
				ospreyawake(x, waitid);
				nexterror();
			}
			sleep(&ospreyreplyrend[x], ospreyreply, p);
			poperror();
			qlock(&ospreylock);
			ospreyawake(x, waitid);
			p = ospreymine(cb->f[1]);
		}
		break;

	case CMbind:
		p = ospreymine(cb->f[1]);
		/*
		 * A server keeps a copy of a container's names, so it has to
		 * be told when they change; it cannot see this happen, since
		 * the request that changes them is answered before anything
		 * is forwarded.
		 */
		if(ospreybind(p, cb->f[2], cb->f[3]) < 0)
			error(Ebadarg);
		ospreytellandwake(p, OpBind);
		break;

	case CMunbind:
		p = ospreymine(cb->f[1]);
		if(ospreyunbind(p, cb->f[2]) < 0)
			error(Enonexist);
		/* a server keeps a copy of these; taking one away changes it */
		ospreytellandwake(p, OpBind);
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
