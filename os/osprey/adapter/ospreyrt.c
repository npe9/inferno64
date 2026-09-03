/*
 * Osprey runtime adapter.
 *
 * This file is the only place where the kernel and the portable policy
 * layer meet.  It includes the policy headers and none of the port
 * headers, so the policy layer's Queue and Block names stay clear of the
 * qio types of the same name.  It sits in its own directory because the
 * compiler looks for a quoted include beside the file being compiled
 * first, and the port directory has its own edf.h, lib.h and queue.h.
 *
 * Storage is static: the policy layer is written to be given its arrays
 * rather than to allocate them.
 *
 * Locking.  The device supplies one lock per core.  A function that ticks,
 * schedules or bills one core takes that core's lock; a function that
 * moves a task between cores, or that creates or destroys a container,
 * takes every core's lock in index order.  Everything else -- the rings,
 * the namespace, the resource caps, the snapshot -- is left to the caller,
 * which serialises the device's own file operations.  No locking function
 * here calls another, and ready() runs before any lock is taken, so the
 * first-use reset cannot deadlock against a lock it would take itself.
 */
/* the policy headers guard their own <u.h> with this */
#define OSPREY_U_INCLUDED
#include <u.h>

/*
 * By path, not by name: the policy directory is on the include path and
 * has a lib.h of its own, but the library routines used here must be
 * declared exactly as the port declares them.  The loader compares type
 * signatures, and the two trees disagree about the width of usize.
 */
#include "../port/lib.h"
#include "../port/osprey.h"

#include "runtime.h"
#include "snap.h"
#include "select.h"
#include "net.h"

enum {
	Nproc		= 16,	/* resource containers this adapter can hold */
	Ncore		= 8,	/* independent per-core run queues */
	Nqueue		= 16,	/* messages per request and reply ring */
	Nname		= 8,	/* private namespace entries per container */
	Ndata		= 4096,	/* names and i/o buffers per container */
	Nsem		= 8,	/* semaphores per container */
	/*
	 * and the most it may be set to.  status and the checkpoint copy
	 * the counts out under the semaphore lock and print them after
	 * letting it go, which wants somewhere fixed to copy them to.
	 */
	Nsemmax		= 64,
	Npkt		= 32,	/* packets a container may hold */
	Npktbuf		= 16,	/* receive buffers it lends an interface */
	Ntxbuf		= 8,	/* and transmit buffers it fills itself */
	Npage		= 32,	/* pages that may be handed about */
	Pagesize	= 4096,
	Maxpage		= 8,	/* pages one container may hold */
	Pktbufsize	= 2112,	/* one of them, room for 2048 and a trailer */
	Txbufsize	= 2112,
	Segnamelen	= 16,
	Ngrant		= 4,	/* others the owner may hand it to */
	Userlen		= 28,
	Narm		= 16,	/* arms one select may offer */
	Align		= 64,
};

struct Ospreyproc {
	Process	process;
	int	used;
	int	saved;		/* snap holds a checkpoint */
	Snap	snap;
	uvlong	sequence;	/* request numbering, kept out of Task */
	int	pid;		/* the process billed to this container, or 0 */
	uvlong	version;	/* writes to its attributes */
	uvlong	slice;		/* byte offset of this container in the arena */
	uvlong	npage;		/* pages held; the map's copy is only published */
	Ospreymap *map;		/* the slice itself */
	char	segname[Segnamelen];	/* the segment that is this slice */
	char	owner[Userlen];		/* whoever made it */
	char	grant[Ngrant][Userlen];	/* and whoever they handed it to */
	Ospreyproc *server;	/* answers what the kernel will not */
	int	serving;	/* is that server for someone */
	Pktq	pktq;		/* packets given to this container */
	Pkt	pkt[Npkt];
	Pkt	*pktp[Npkt];
	Name	name[Nname];
};

static Runtime runtime;
static Core cores[Ncore];
static Ospreyproc procs[Nproc];
static Process *plist[Nproc];
static int started;

enum {
	Fwdnone	= -1,	/* no server: the kernel's own personality answers */
	Fwdfull	= -2,	/* a server, but its ring has no room right now */
};

static int forward(Ospreyproc*, Request*);
static char *statename(int);

/*
 * The five limits that do nothing but lay out a slice.  They are
 * variables rather than constants because a slice is memory and how much
 * of it a container gets is a configuration, not a design: everything
 * they size lives in the container's own slice and is reached through
 * the map, so nothing in this file or the device indexes an array with
 * them.  The other limits in the enum above are not here for exactly the
 * opposite reason -- Nproc, Ncore, Npkt, Nname and Maxpage size arrays
 * that are compiled in.
 */
#define ROUNDUP(n, a)	(((n)+(a)-1) & ~((uvlong)(a)-1))

enum {
	/*
	 * The most the whole arena may come to.  It is a ceiling on a
	 * configuration, not a design limit: sixteen slices of four
	 * megabytes each is already far past anything the checks ask for,
	 * and what it is really for is that the number below it is refused
	 * out loud rather than panicking the machine.
	 */
	Maxarena	= 64*1024*1024,
};

static ulong nqueue = Nqueue;
static ulong ndata = Ndata;
static ulong nsem = Nsem;
static ulong npktbuf = Npktbuf;
static ulong ntxbuf = Ntxbuf;

static uchar *arena;		/* the shared span, or nil until given one */
static ulong arenasize;
static ulong slicesize;

/*
 * What a slice would come to with the limits as they stand, and what the
 * whole arena would come to with it.  In uvlongs, because the point of
 * working it out is to refuse a number too big for the ulong the slice
 * size is kept in.
 */
static uvlong
trialslice(void)
{
	uvlong n;

	n = ROUNDUP(sizeof(Ospreymap), Align)
		+ ROUNDUP(3*sizeof(Queue), Align)
		+ ROUNDUP((uvlong)nsem*sizeof(Sem), Align)
		+ ROUNDUP(3*(uvlong)nqueue*sizeof(Message), Align)
		+ ROUNDUP((uvlong)ndata, Align)
		+ (uvlong)npktbuf*Pktbufsize
		+ (uvlong)ntxbuf*Txbufsize;
	return ROUNDUP(n, Pagesize);
}

static uvlong
trialarena(void)
{
	return ROUNDUP(trialslice() * Nproc, Pagesize)
		+ (uvlong)Npage*Pagesize;
}

/*
 * Set one of them, by the name the kernel reads out of its configuration
 * and passes straight through.  Only before there is an arena: the whole
 * span is one allocation whose size these decide, and every container in
 * it is laid out the same way.  A limit smaller than the compiled-in one
 * is refused rather than obeyed, since what is in the tree is already a
 * demonstration's size and taking memory away from it breaks a check
 * rather than a container.
 */
int
ospreysetsize(char *what, ulong n, ulong max)
{
	ulong *v, floor, old;

	if(arena != nil || slicesize != 0 || what == nil)
		return -1;
	if(strcmp(what, "queue") == 0)
		v = &nqueue, floor = Nqueue;
	else if(strcmp(what, "data") == 0)
		v = &ndata, floor = Ndata;
	else if(strcmp(what, "sem") == 0)
		v = &nsem, floor = Nsem;
	else if(strcmp(what, "pktbuf") == 0)
		v = &npktbuf, floor = Npktbuf;
	else if(strcmp(what, "txbuf") == 0)
		v = &ntxbuf, floor = Ntxbuf;
	else
		return -1;
	if(n < floor || (max != 0 && n > max))
		return -1;
	old = *v;
	*v = n;
	/*
	 * The arena is one allocation, and xspanalloc panics rather than
	 * returning nothing when it cannot make it: a number here that
	 * asks for more memory than a machine has would stop the kernel at
	 * devinit, before there is a console worth reading, and read as a
	 * broken kernel rather than as a refused line of plan9.ini.  So
	 * the ceiling is what the whole arena would come to, worked out
	 * here in uvlongs, before anything asks for it.
	 */
	if(trialarena() > Maxarena){
		*v = old;
		return -1;
	}
	return 0;
}

static uvlong pagebase;		/* the pages, after every slice */
static uchar pagetaken[Npage];


static struct {
	char	*name;
	int	op;
} opnames[] = {
	{"read",	ReqRead},
	{"write",	ReqWrite},
	{"open",	ReqOpen},
	{"close",	ReqClose},
	{"wait",	ReqWait},
	{"gone",	ReqGone},
	{"send",	ReqSend},
	{"recv",	ReqRecv},
	{"stat",	ReqStat},
	{"bind",	ReqBind},
	{"alloc",	ReqAlloc},
	{"yield",	ReqYield},
	{"poll",	ReqPoll},
	{"exec",	ReqExec},
	{"reserve",	ReqReserve},
	{"tick",	ReqTick},
};

static char *attrnames[] = {
	"core", "state", "budget", "used", "period", "deadline",
	"besteffort", "periods", "mode", "memory", "memused",
	"netbytes", "netmax", "packetmax", "packets",
	"requests", "replies", "output",
	"slice", "data", "pid", "version", nil,
};

void
ospreysetowner(Ospreyproc *p, char *user)
{
	if(p == nil || p->used == 0 || user == nil)
		return;
	strncpy(p->owner, user, Userlen-1);
	p->owner[Userlen-1] = '\0';
}

char*
ospreyowner(Ospreyproc *p)
{
	return p == nil || p->used == 0 ? nil : p->owner;
}

char*
ospreygranted(Ospreyproc *p, int i)
{
	if(p == nil || p->used == 0 || i < 0 || i >= Ngrant)
		return nil;
	return p->grant[i][0] == '\0' ? nil : p->grant[i];
}

int
ospreygrant(Ospreyproc *p, char *user)
{
	int i;

	if(p == nil || p->used == 0 || user == nil || *user == '\0')
		return -1;
	if(strlen(user) >= Userlen)
		return -1;
	for(i = 0; i < Ngrant; i++)
		if(strcmp(p->grant[i], user) == 0)
			return 0;
	for(i = 0; i < Ngrant; i++)
		if(p->grant[i][0] == '\0'){
			strcpy(p->grant[i], user);
			return 0;
		}
	return -1;
}

int
ospreyrevoke(Ospreyproc *p, char *user)
{
	int i;

	if(p == nil || p->used == 0 || user == nil)
		return -1;
	for(i = 0; i < Ngrant; i++)
		if(strcmp(p->grant[i], user) == 0){
			p->grant[i][0] = '\0';
			return 0;
		}
	return -1;
}

/*
 * Whether a container is that user's to have.  A container with no owner
 * is anyone's: nothing has claimed it.
 */
int
ospreymay(Ospreyproc *p, char *user)
{
	int i;

	if(p == nil || p->used == 0)
		return 0;
	if(p->owner[0] == '\0')
		return 1;
	if(user == nil)
		return 0;
	if(strcmp(p->owner, user) == 0)
		return 1;
	for(i = 0; i < Ngrant; i++)
		if(p->grant[i][0] != '\0' && strcmp(p->grant[i], user) == 0)
			return 1;
	return 0;
}

uvlong
ospreyversion(Ospreyproc *p)
{
	return p == nil ? 0 : p->version;
}

/*
 * Read one attribute of a container into buf, or the list of them all
 * when the name is *.  Returns what was written, or -1 for a name the
 * container does not have.
 */
long
ospreyattr(Ospreyproc *p, char *name, char *buf, long nbuf)
{
	Container *c;
	Process *q;
	char *e, *s;
	int i;

	if(p == nil || p->used == 0 || name == nil || nbuf <= 0)
		return -1;
	q = &p->process;
	c = &q->container;
	s = buf;
	e = buf + nbuf;

	if(strcmp(name, "*") == 0){
		for(i = 0; attrnames[i] != nil; i++)
			s = seprint(s, e, i == 0 ? "%s" : " %s", attrnames[i]);
		return s - buf;
	}
	if(strcmp(name, "core") == 0)
		s = seprint(s, e, "%lud", q->core);
	else if(strcmp(name, "state") == 0)
		s = seprint(s, e, "%s", statename(q->state));
	else if(strcmp(name, "budget") == 0)
		s = seprint(s, e, "%llud", c->budget);
	else if(strcmp(name, "used") == 0)
		s = seprint(s, e, "%llud", c->used);
	else if(strcmp(name, "period") == 0)
		s = seprint(s, e, "%llud", c->period);
	else if(strcmp(name, "deadline") == 0)
		s = seprint(s, e, "%llud", q->task.deadline);
	else if(strcmp(name, "besteffort") == 0)
		s = seprint(s, e, "%llud", c->besteffort);
	else if(strcmp(name, "periods") == 0)
		s = seprint(s, e, "%llud", c->periods);
	else if(strcmp(name, "mode") == 0)
		s = seprint(s, e, "%s", c->strict ? "strict" : "besteffort");
	else if(strcmp(name, "memory") == 0)
		s = seprint(s, e, "%lud", c->memory);
	else if(strcmp(name, "memused") == 0)
		s = seprint(s, e, "%lud", c->memused);
	else if(strcmp(name, "netbytes") == 0)
		s = seprint(s, e, "%lud", c->netbytes);
	else if(strcmp(name, "netmax") == 0)
		s = seprint(s, e, "%lud", c->netmax);
	else if(strcmp(name, "packetmax") == 0)
		s = seprint(s, e, "%lud", c->packetmax);
	else if(strcmp(name, "packets") == 0)
		s = seprint(s, e, "%lud", (ulong)pktqcount(&p->pktq));
	else if(strcmp(name, "requests") == 0)
		s = seprint(s, e, "%llud", queuecount(q->requests));
	else if(strcmp(name, "replies") == 0)
		s = seprint(s, e, "%llud", queuecount(q->replies));
	else if(strcmp(name, "output") == 0)
		s = seprint(s, e, "%llud", queuecount(q->output));
	else if(strcmp(name, "slice") == 0)
		s = seprint(s, e, "%llud", p->slice);
	else if(strcmp(name, "data") == 0)
		s = seprint(s, e, "%llud", ospreydataoffset(p));
	else if(strcmp(name, "pid") == 0)
		s = seprint(s, e, "%d", p->pid);
	else if(strcmp(name, "version") == 0)
		s = seprint(s, e, "%llud", p->version);
	else
		return -1;
	return s - buf;
}

/* the attributes that may be written: a container's own policy */
static char *writable[] = {
	"budget", "period", "deadline", "memory", "netmax", "packetmax",
	"mode", nil,
};

int
ospreyattrwritable(char *name)
{
	int i;

	for(i = 0; writable[i] != nil; i++)
		if(strcmp(writable[i], name) == 0)
			return 1;
	return 0;
}

/*
 * Write one.  Only the attributes that are a container's own policy may
 * be set; what it has done is read only.
 */
int
ospreysetattr(Ospreyproc *p, char *name, char *val)
{
	Container *c;

	if(p == nil || p->used == 0 || name == nil || val == nil)
		return -1;
	c = &p->process.container;
	if(strcmp(name, "budget") == 0)
		c->budget = strtoull(val, nil, 0);
	else if(strcmp(name, "period") == 0)
		c->period = strtoull(val, nil, 0);
	else if(strcmp(name, "deadline") == 0)
		c->deadline = strtoull(val, nil, 0);
	else if(strcmp(name, "memory") == 0)
		c->memory = strtoul(val, nil, 0);
	else if(strcmp(name, "netmax") == 0)
		c->netmax = strtoul(val, nil, 0);
	else if(strcmp(name, "packetmax") == 0)
		c->packetmax = strtoul(val, nil, 0);
	else if(strcmp(name, "mode") == 0){
		if(strcmp(val, "strict") == 0)
			containerstrict(c, 1);
		else if(strcmp(val, "besteffort") == 0)
			containerstrict(c, 0);
		else
			return -1;
	} else
		return -1;
	p->version++;
	return 0;
}

int
ospreyop(char *name)
{
	int i;

	for(i = 0; i < nelem(opnames); i++)
		if(strcmp(opnames[i].name, name) == 0)
			return opnames[i].op;
	return -1;
}

char*
ospreyopname(uvlong op)
{
	int i;

	for(i = 0; i < nelem(opnames); i++)
		if(opnames[i].op == op)
			return opnames[i].name;
	return "?";
}

/*
 * The adapter does not allocate: the device hands it one contiguous span
 * and it carves a fixed slice out of it for each container.
 */
static void
lockall(void)
{
	ulong i;

	for(i = 0; i < Ncore; i++)
		ospreylockcore(i);
}

static void
unlockall(void)
{
	ulong i;

	for(i = Ncore; i-- > 0; )
		ospreyunlockcore(i);
}

int
ospreyncore(void)
{
	return Ncore;
}

ulong
ospreynsem(void)
{
	return nsem;
}

static void
sizes(void)
{
	if(slicesize != 0)
		return;
	/*
	 * A whole number of pages: a slice is a segment of its own, and a
	 * segment is attached in pages.
	 */
	slicesize = (ulong)trialslice();
}

int
ospreyarena(void *base, ulong size)
{
	ulong need;

	need = ospreyarenasize();
	if(base == nil || size < need)
		return -1;
	arena = base;
	arenasize = size;
	memset(arena, 0, need);
	memset(pagetaken, 0, sizeof pagetaken);
	return 0;
}

uvlong
ospreyarenasize(void)
{
	sizes();
	pagebase = ROUNDUP((uvlong)slicesize * Nproc, Pagesize);
	return pagebase + (uvlong)Npage*Pagesize;
}

/*
 * A ring head is in memory the container maps and may write.  What the
 * kernel must not do is believe what it finds there: where the messages
 * are and how many there is room for are the kernel's own, and a
 * container that puts a wild offset in message would otherwise have the
 * kernel write a message wherever it said.  Only put and get are the
 * container's to move, and they are taken modulo a size it does not
 * choose.  This puts the geometry back before every use of a ring.
 */
static void mapfix(Ospreyproc*);

static void
mapfix(Ospreyproc *p)
{
	Ospreymap *m;
	Process *r;

	if(p == nil || p->used == 0 || p->map == nil)
		return;
	/*
	 * Everything the kernel goes on to believe is put back from what
	 * it knows, not read from what is there.  A container may write
	 * every byte of this; what it writes is its own view.
	 */
	m = p->map;
	m->magic = Ospreymagic;
	m->id = p->process.id;
	m->size = nqueue;
	m->msgsize = sizeof(Message);
	m->requestqueue = ROUNDUP(sizeof(Ospreymap), Align);
	m->replyqueue = m->requestqueue + sizeof(Queue);
	m->outputqueue = m->replyqueue + sizeof(Queue);
	m->sem = ROUNDUP(m->outputqueue + sizeof(Queue), Align);
	m->nsem = nsem;
	m->request = ROUNDUP(m->sem + nsem*sizeof(Sem), Align);
	m->reply = m->request + nqueue*sizeof(Message);
	m->output = m->reply + nqueue*sizeof(Message);
	m->data = ROUNDUP(m->output + nqueue*sizeof(Message), Align);
	m->pktbuf = ROUNDUP(m->data + ndata, Align);
	m->npktbuf = npktbuf;
	m->pktbufsize = Pktbufsize;
	m->txbuf = ROUNDUP(m->pktbuf + npktbuf*Pktbufsize, Align);
	m->ntxbuf = ntxbuf;
	m->txbufsize = Txbufsize;
	m->page = m->data + ndata - Maxpage*sizeof(uvlong);
	m->maxpage = Maxpage;
	m->pagesize = Pagesize;
	m->datalen = ndata - Maxpage*sizeof(uvlong);
	m->npage = p->npage;
	r = &p->process;
	if(r->requests != nil){
		r->requests->message = (uchar*)r->requeststorage
			- (uchar*)r->requests;
		r->requests->size = nqueue;
	}
	if(r->replies != nil){
		r->replies->message = (uchar*)r->repliestorage
			- (uchar*)r->replies;
		r->replies->size = nqueue;
	}
	if(r->output != nil){
		r->output->message = (uchar*)r->outputstorage
			- (uchar*)r->output;
		r->output->size = nqueue;
	}
}

uvlong
ospreyslice(Ospreyproc *p)
{
	return p == nil ? 0 : p->slice;
}

uvlong
ospreyslicesize(void)
{
	sizes();
	return slicesize;
}

/*
 * A container's slice is a segment of its own, so that attaching one
 * gets that container's memory and nobody else's.
 */
/*
 * The name of a slice and the name of a page.  A name here is a
 * capability and not merely a name, so the rule that forms one is
 * written once: the device publishes these segments before any
 * container exists and cannot ask a container for its own name, and it
 * used to form them from a copy of this rule with a comment saying so.
 * Two copies of a rule that decides which container's memory a name
 * reaches is not a thing to keep by hand.
 */
char*
ospreyslicename(int slot)
{
	static char buf[Segnamelen];

	if(slot < 0 || slot >= Nproc)
		return nil;
	seprint(buf, buf + sizeof buf, "osprey%d", slot);
	return buf;
}

char*
ospreypagename(uvlong i)
{
	static char buf[Segnamelen];

	if(i >= Npage)
		return nil;
	seprint(buf, buf + sizeof buf, "ospreypage%llud", i);
	return buf;
}

char*
ospreysegname(Ospreyproc *p)
{
	if(p == nil || p->used == 0)
		return nil;
	return p->segname;
}

/* and a page is a segment of its own, so that handing one over maps it */
char*
ospreypagesegname(uvlong off)
{
	static char buf[Segnamelen];
	char *s;
	uvlong i;

	if(off < pagebase || off >= pagebase + (uvlong)Npage*Pagesize)
		return nil;
	i = (off - pagebase)/Pagesize;
	if((s = ospreypagename(i)) == nil)
		return nil;
	s = seprint(buf, buf+sizeof buf, "%s", s);
	USED(s);
	return buf;
}

ulong
ospreycoreof(Ospreyproc *p)
{
	return p == nil || p->used == 0 ? ~0UL : p->process.core;
}

int
ospreyindex(Ospreyproc *p)
{
	if(p == nil || p->used == 0)
		return -1;
	return p - procs;
}

int
ospreynproc(void)
{
	return Nproc;
}

/* byte offset of a container's data area within the whole arena */
uvlong
ospreydataoffset(Ospreyproc *p)
{
	/*
	 * mapfix first, like every other reader of this map.  These two
	 * were the last that did not, and were safe only because their
	 * callers happened to call ospreydata, which does, before them --
	 * an accident, and the same one that let ospreymapsizes work for
	 * as long as it did.  status prints what this returns, and a
	 * server asks status precisely so as not to believe a container's
	 * own map: without the fix a container could scribble a false
	 * data offset into its map and have the kernel repeat it.
	 */
	mapfix(p);
	if(p == nil || p->used == 0 || p->map == nil)
		return 0;
	return p->slice + p->map->data;
}

uvlong
ospreydatalen(Ospreyproc *p)
{
	mapfix(p);
	if(p == nil || p->used == 0 || p->map == nil)
		return 0;
	return p->map->datalen;
}

static uvlong*
pagelist(Ospreyproc *p)
{
	mapfix(p);
	if(p == nil || p->used == 0 || p->map == nil)
		return nil;
	return (uvlong*)((uchar*)p->map + p->map->page);
}

/*
 * Take a page for this container.  Nothing is mapped or unmapped: the
 * arena is one span and both ends have all of it, so what a page belongs
 * to is what a map names, and that is what moves.
 */
int
ospreypagealloc(Ospreyproc *p)
{
	uvlong *l;
	int i;

	if((l = pagelist(p)) == nil || p->npage >= Maxpage)
		return -1;
	for(i = 0; i < Npage; i++)
		if(pagetaken[i] == 0){
			pagetaken[i] = 1;
			l[p->npage] = pagebase + (uvlong)i*Pagesize;
			p->map->npage = ++p->npage;
			return (int)p->npage - 1;
		}
	return -1;
}

static int
pagedrop(Ospreyproc *p, int i, uvlong *off)
{
	uvlong *l;
	uvlong n;

	if((l = pagelist(p)) == nil)
		return -1;
	n = p->npage;
	if(i < 0 || (uvlong)i >= n)
		return -1;
	*off = l[i];
	for(; (uvlong)i < n-1; i++)
		l[i] = l[i+1];
	p->npage = n-1;
	p->map->npage = p->npage;
	return 0;
}

int
ospreypagefree(Ospreyproc *p, int i)
{
	uvlong off;

	if(pagedrop(p, i, &off) < 0)
		return -1;
	if(off >= pagebase && off < pagebase + (uvlong)Npage*Pagesize)
		pagetaken[(off - pagebase)/Pagesize] = 0;
	return 0;
}

/*
 * Hand a page from one container to another.  What was written in it is
 * there afterwards, having been neither copied nor moved.
 */
int
ospreypageflip(Ospreyproc *from, Ospreyproc *to, int i)
{
	uvlong *l, off;

	if(from == nil || to == nil || from == to)
		return -1;
	if((l = pagelist(to)) == nil || to->npage >= Maxpage)
		return -1;
	if(pagedrop(from, i, &off) < 0)
		return -1;
	l[to->npage++] = off;
	to->map->npage = to->npage;
	return 0;
}

/* whether this container holds the page at that offset in the span */
int
ospreyholdspage(Ospreyproc *p, uvlong off)
{
	uvlong *l, j;

	if((l = pagelist(p)) == nil)
		return 0;
	for(j = 0; j < p->npage; j++)
		if(l[j] == off)
			return 1;
	return 0;
}

uvlong
ospreypageoff(uvlong i)
{
	sizes();
	if(pagebase == 0)
		ospreyarenasize();
	return i >= Npage ? ~0ULL : pagebase + i*Pagesize;
}

/* where this container's receive buffers are, and how many */
int
ospreymapsizes(Ospreyproc *p, uvlong *off, uvlong *n, uvlong *size)
{
	mapfix(p);
	if(p == nil || p->used == 0 || p->map == nil)
		return -1;
	*off = p->map->pktbuf;
	*n = p->map->npktbuf;
	*size = p->map->pktbufsize;
	return 0;
}

/* the same for the buffers it fills and the card reads */
int
ospreytxsizes(Ospreyproc *p, uvlong *off, uvlong *n, uvlong *size)
{
	mapfix(p);
	if(p == nil || p->used == 0 || p->map == nil)
		return -1;
	*off = p->map->txbuf;
	*n = p->map->ntxbuf;
	*size = p->map->txbufsize;
	return 0;
}

/* the address of a place in this container's slice, and the reverse */
void*
ospreyat_off(Ospreyproc *p, uvlong off, ulong len)
{
	if(p == nil || p->used == 0 || p->map == nil)
		return nil;
	if(off >= slicesize || len > slicesize - off)
		return nil;
	return (uchar*)p->map + off;
}

uvlong
ospreyoff_at(Ospreyproc *p, void *addr)
{
	uchar *a = addr;

	if(p == nil || p->used == 0 || p->map == nil)
		return ~0ULL;
	if(a < (uchar*)p->map || a >= (uchar*)p->map + slicesize)
		return ~0ULL;
	return a - (uchar*)p->map;
}

void*
ospreyarenaaddr(uvlong off, ulong len)
{
	if(arena == nil || off >= arenasize || len > arenasize - off)
		return nil;
	return arena + off;
}

void*
ospreydata(Ospreyproc *p, uvlong off, ulong len)
{
	mapfix(p);
	if(p == nil || p->used == 0 || p->map == nil)
		return nil;
	if(off >= p->map->datalen || len > p->map->datalen - off)
		return nil;
	return (uchar*)p->map + p->map->data + off;
}

void
ospreyreset(void)
{
	ulong i;

	if(started)
		lockall();
	memset(procs, 0, sizeof procs);
	memset(cores, 0, sizeof cores);
	memset(plist, 0, sizeof plist);
	for(i = 0; i < Ncore; i++)
		coreinit(&cores[i], i);
	runtimeinit(&runtime, cores, Ncore, plist, Nproc);
	if(arena != nil)
		memset(arena, 0, slicesize * Nproc);
	if(started)
		unlockall();
	started = 1;
}

static void
ready(void)
{
	if(started == 0)
		ospreyreset();
}

Ospreyproc*
ospreylookup(uvlong id)
{
	int i;

	ready();
	for(i = 0; i < Nproc; i++)
		if(procs[i].used && procs[i].process.id == id)
			return &procs[i];
	return nil;
}

/* walk the live containers; nil starts the walk and ends it */
Ospreyproc*
ospreynext(Ospreyproc *p)
{
	int i;

	ready();
	i = p == nil ? 0 : (p - procs) + 1;
	for(; i < Nproc; i++)
		if(procs[i].used)
			return &procs[i];
	return nil;
}

/* the container in a given slot, or nil */
Ospreyproc*
ospreyat(int i)
{
	if(i < 0 || i >= Nproc || procs[i].used == 0)
		return nil;
	return &procs[i];
}

uvlong
ospreyid(Ospreyproc *p)
{
	return p == nil ? 0 : p->process.id;
}

Ospreyproc*
ospreycreate(uvlong id, uvlong budget, uvlong period, uvlong deadline)
{
	Ospreyproc *p;
	Ospreymap *m;
	Queue *rq, *pq, *oq;
	Message *rm, *pm, *om;
	uchar *base;
	int i, slot;

	ready();
	if(id == 0 || arena == nil || ospreylookup(id) != nil)
		return nil;
	for(slot = 0; slot < Nproc; slot++)
		if(procs[slot].used == 0)
			break;
	if(slot == Nproc)
		return nil;

	p = &procs[slot];
	memset(p, 0, sizeof *p);

	p->slice = (uvlong)slot * slicesize;
	seprint(p->segname, p->segname + Segnamelen, "%s",
		ospreyslicename(slot));
	base = arena + p->slice;
	memset(base, 0, slicesize);
	m = (Ospreymap*)base;
	m->magic = Ospreymagic;
	m->id = id;
	m->size = nqueue;
	m->msgsize = sizeof(Message);
	m->requestqueue = ROUNDUP(sizeof(Ospreymap), Align);
	m->replyqueue = m->requestqueue + sizeof(Queue);
	m->outputqueue = m->replyqueue + sizeof(Queue);
	m->sem = ROUNDUP(m->outputqueue + sizeof(Queue), Align);
	m->nsem = nsem;
	m->request = ROUNDUP(m->sem + nsem*sizeof(Sem), Align);
	m->reply = m->request + nqueue*sizeof(Message);
	m->output = m->reply + nqueue*sizeof(Message);
	m->data = ROUNDUP(m->output + nqueue*sizeof(Message), Align);
	m->pktbuf = ROUNDUP(m->data + ndata, Align);
	m->npktbuf = npktbuf;
	m->pktbufsize = Pktbufsize;
	/*
	 * The pages a container holds are named at the end of its data
	 * area, as offsets into the whole arena rather than into the
	 * slice: a page is not part of any slice, and moves between them.
	 */
	m->page = m->data + ndata - Maxpage*sizeof(uvlong);
	m->npage = 0;
	m->maxpage = Maxpage;
	m->pagesize = Pagesize;
	m->datalen = ndata - Maxpage*sizeof(uvlong);
	m->selected = ~0ULL;
	p->map = m;
	for(i = 0; i < nsem; i++)
		seminit((Sem*)(base + m->sem) + i, 0);

	rq = (Queue*)(base + m->requestqueue);
	pq = (Queue*)(base + m->replyqueue);
	oq = (Queue*)(base + m->outputqueue);
	rm = (Message*)(base + m->request);
	pm = (Message*)(base + m->reply);
	om = (Message*)(base + m->output);
	lockall();
	pktqinit(&p->pktq, p->pktp, Npkt);
	if(processinit(&p->process, id, budget, period, deadline,
		rq, pq, oq, rm, pm, om, nqueue, p->name, Nname) < 0){
		unlockall();
		return nil;
	}
	p->used = 1;
	for(i = 0; i < Nproc; i++)
		if(plist[i] == nil){
			plist[i] = &p->process;
			break;
		}
	unlockall();
	return p;
}

/*
 * Whether a container's rings can be worked at all.  The two indices
 * are the container's to move and it may move them to nonsense; a ring
 * saying it holds more than it can hold will never come right, so
 * waiting for room in it is waiting for ever.
 */
int
ospreyringsane(Ospreyproc *p)
{
	Process *r;

	mapfix(p);
	if(p == nil || p->used == 0)
		return 0;
	r = &p->process;
	if(r->requests->put - r->requests->get > r->requests->size)
		return 0;
	if(r->replies->put - r->replies->get > r->replies->size)
		return 0;
	if(r->output->put - r->output->get > r->output->size)
		return 0;
	return 1;
}

int
ospreyrequestfull(Ospreyproc *p)
{
	mapfix(p);
	if(p == nil || p->used == 0)
		return 1;
	return queuefull(p->process.requests);
}

int
ospreyreplyready(Ospreyproc *p)
{
	mapfix(p);
	if(p == nil || p->used == 0)
		return 0;
	return !queueempty(p->process.replies);
}

int
ospreyattach(Ospreyproc *p, ulong core, uvlong now)
{
	int r;

	if(p == nil || p->used == 0)
		return -1;
	lockall();
	runtime.now = now;
	r = runtimeattach(&runtime, &p->process, core);
	unlockall();
	return r;
}

/*
 * Controlled migration: the same operation as attach, named separately
 * because moving a running container between cores is a policy decision
 * and balance() makes it on its own.
 */
int
ospreymigrate(Ospreyproc *p, ulong core, uvlong now)
{
	return ospreyattach(p, core, now);
}

int
ospreydetach(Ospreyproc *p)
{
	int r;

	if(p == nil || p->used == 0)
		return -1;
	lockall();
	r = runtimedetach(&runtime, &p->process);
	unlockall();
	return r;
}

int
ospreyexit(Ospreyproc *p)
{
	int i;

	if(p == nil || p->used == 0)
		return -1;
	lockall();
	runtimeexit(&runtime, &p->process);
	if(p->server != nil){
		p->server->serving--;
		p->server = nil;
	}
	for(i = 0; i < Nproc; i++)
		if(procs[i].used && procs[i].server == p){
			procs[i].server = nil;
			p->serving--;
		}
	for(i = 0; i < Nproc; i++)
		if(plist[i] == &p->process)
			plist[i] = nil;
	/*
	 * The pages it was holding go back to the span.  The list of them
	 * is in the map, which is about to be wiped, and nothing else
	 * remembers which they were: without this every page a container
	 * ever took was gone until the machine was reset.
	 */
	if(p->map != nil){
		uvlong *l, off, j;

		if((l = pagelist(p)) != nil)
			for(j = 0; j < p->npage; j++){
				off = l[j];
				if(off >= pagebase
				&& off < pagebase + (uvlong)Npage*Pagesize)
					pagetaken[(off - pagebase)/Pagesize] = 0;
			}
		memset(p->map, 0, slicesize);
	}
	p->used = 0;
	p->map = nil;
	unlockall();
	return 0;
}

/* the container a policy task belongs to, or 0 */
static uvlong
taskid(Task *t)
{
	int i;

	if(t == nil)
		return 0;
	for(i = 0; i < Nproc; i++)
		if(procs[i].used && &procs[i].process.task == t)
			return procs[i].process.id;
	return 0;
}

/*
 * Pick the earliest-deadline runnable task on a core and make it the
 * core's current task.  The container it belongs to is then the one
 * ospreycharge() bills.
 */
uvlong
ospreyschedule(ulong core, uvlong now)
{
	uvlong id;

	ready();
	if(core >= Ncore)
		return 0;
	ospreylockcore(core);
	id = taskid(runtimenext(&runtime, core, now));
	ospreyunlockcore(core);
	return id;
}

int
ospreycharge(ulong core, uvlong amount, uvlong now)
{
	int r;

	ready();
	if(core >= Ncore)
		return -1;
	ospreylockcore(core);
	r = corecharge(&cores[core], amount, now);
	ospreyunlockcore(core);
	return r;
}

/*
 * One tick of a core's clock.  Bill the running container; if that
 * exhausts its budget before its period is out, take it off the run queue
 * so the cores below it get their turn, and put back anything whose
 * period has since refilled.  Then choose again.  Returns the number of
 * containers this tick threw off the queue.
 */
void
ospreysetpid(Ospreyproc *p, int pid)
{
	if(p != nil && p->used)
		p->pid = pid;
}

/*
 * A container is throttled when it has been attached to a core but is
 * not on its run queue, which is where the tick puts it once its budget
 * for the period is gone.
 */
int
ospreythrottled(Ospreyproc *p)
{
	if(p == nil || p->used == 0)
		return 0;
	return p->process.state == ProcessRunnable && p->process.task.runnable == 0;
}

/* the container has spent its reservation for this period */
int
ospreyover(Ospreyproc *p)
{
	if(p == nil || p->used == 0)
		return 0;
	return containerover(&p->process.container);
}

int
ospreystrict(Ospreyproc *p)
{
	return p != nil && p->used && p->process.container.strict;
}

void
ospreysetstrict(Ospreyproc *p, int strict)
{
	if(p != nil && p->used)
		containerstrict(&p->process.container, strict);
}

int
ospreytick(ulong core, Ospreyproc *running, uvlong amount, uvlong now)
{
	Core *c;
	Process *q;
	Task *t;
	ulong i;
	int throttled;

	ready();
	if(core >= Ncore)
		return -1;
	c = &cores[core];
	throttled = 0;

	ospreylockcore(core);
	runtime.now = now;
	c->cycles += amount;
	/*
	 * Bill the container of the process this core is running, wherever
	 * that container's task is queued.  Only one process is bound to a
	 * container and it runs on one core at a time, so a container has
	 * one biller at a time even though any core may be the one.
	 */
	t = running != nil && running->used ? &running->process.task : c->current;
	if(t != nil && t->container != nil)
		containercharge(t->container, amount, now);

	/*
	 * Queueing decisions belong to the core the container is attached
	 * to, which is the only one holding the lock that protects this run
	 * queue.  A container that has run out of budget leaves it; one
	 * whose period has refilled comes back.
	 */
	for(i = 0; i < Nproc; i++){
		q = plist[i];
		if(q == nil || q->core != core)
			continue;
		if(q->state != ProcessRunnable && q->state != ProcessBlocked)
			continue;
		/*
		 * A period refills whether the container is waiting or not:
		 * a reservation is time it is owed, and it is owed it while
		 * it waits.  What a waiting container does not get is a
		 * place on the run queue, since there is nothing to run.
		 */
		containerrefill(&q->container, now);
		if(q->state != ProcessRunnable)
			continue;
		if(q->container.strict == 0 || budgetok(&q->task, amount)){
			if(q->task.runnable == 0)
				coreenqueue(c, &q->task, now);
		} else if(q->task.runnable){
			coredequeue(c, &q->task);
			throttled++;
		}
	}
	corenext(c);
	ospreyunlockcore(core);
	return throttled;
}

/*
 * The bounded resource caps.  containerinit() only sets the CPU budget,
 * so a container refuses every allocation until its limits are named.
 */
int
ospreylimit(Ospreyproc *p, ulong memory, ulong netbytes, ulong netpackets)
{
	if(p == nil || p->used == 0)
		return -1;
	p->process.container.memory = memory;
	p->process.container.netmax = netbytes;
	p->process.container.packetmax = netpackets;
	return 0;
}

/*
 * Bounded network accounting.  A packet that arrives for a container's
 * interface is charged against these as it is queued and given back when
 * it is taken; netcharge and netfree are for whatever else a container
 * is told to account for.
 */
/*
 * The other half of alloc.  It charges a container's memory and returns
 * what it now holds; until this was written nothing gave any back, so
 * memused only ever grew and memrelease in the policy layer was called
 * from nowhere at all.  The network side had both halves from the start;
 * this is memory's netfree.
 */
void
ospreymemrelease(Ospreyproc *p, ulong bytes)
{
	if(p == nil || p->used == 0)
		return;
	memrelease(&p->process.container, bytes);
}

int
ospreynetcharge(Ospreyproc *p, ulong bytes, ulong packets)
{
	if(p == nil || p->used == 0)
		return -1;
	return netcharge(&p->process.container, bytes, packets);
}

void
ospreynetrelease(Ospreyproc *p, ulong bytes, ulong packets)
{
	if(p == nil || p->used == 0)
		return;
	netrelease(&p->process.container, bytes, packets);
}

/*
 * A container that is waiting, and one that has been given something to
 * wait for.  The policy layer has had both of these from the start and
 * nothing called either, so a container blocked in a select stayed on
 * its core's run queue and said "runnable" in status however long it
 * waited: the scheduler chose between containers that could run and
 * containers that could not, and a checkpoint carried a state that was
 * never anything else.
 */
int
ospreyblock(Ospreyproc *p)
{
	int r;

	if(p == nil || p->used == 0)
		return -1;
	ready();
	lockall();
	r = runtimeblock(&runtime, &p->process);
	unlockall();
	return r;
}

int
ospreyunblock(Ospreyproc *p, uvlong now)
{
	int r;

	if(p == nil || p->used == 0)
		return -1;
	ready();
	lockall();
	r = runtimewake(&runtime, &p->process, now);
	unlockall();
	return r;
}

int
ospreybalance(uvlong now)
{
	int r;

	ready();
	lockall();
	r = runtimebalance(&runtime, now);
	unlockall();
	return r;
}

int
ospreysubmit(Ospreyproc *p, uvlong op, uvlong *arg)
{
	Request r;
	int i;

	mapfix(p);
	if(p == nil || p->used == 0)
		return -1;
	memset(&r, 0, sizeof r);
	r.message.op = op;
	r.sequence = ++p->sequence;
	r.flags = ReqAsync;
	/*
	 * processsubmit() and processreply() reserve arg[0] and arg[1] for
	 * the status and flag words, so caller data starts at arg[2].
	 */
	for(i = 0; i < Ospreynarg; i++)
		r.message.arg[2+i] = arg[i];
	return processsubmit(&p->process, &r);
}

int
ospreycollect(Ospreyproc *p, uvlong *op, long *status, uvlong *arg)
{
	Reply r;
	int i;

	mapfix(p);
	if(p == nil || p->used == 0)
		return -1;
	memset(&r, 0, sizeof r);
	if(processnextreply(&p->process, &r) < 0)
		return -1;
	*op = r.message.op;
	*status = r.status;
	for(i = 0; i < Ospreynarg; i++)
		arg[i] = r.message.arg[2+i];
	return 0;
}

/*
 * The portable dispatcher.  Only the operations the policy layer can
 * answer by itself are implemented here: yielding, polling a ring and
 * charging a container's memory budget.  File, IPC and network requests
 * belong to the user-level services described in doc/osprey-plan.ms and
 * are refused until those exist.
 */
static int
dispatch(Process *p, Request *req, Reply *rep, void *arg)
{
	USED(arg);
	switch(req->message.op){
	case ReqYield:
		rep->status = ReplyDone;
		return 0;

	case ReqPoll:
		rep->message.arg[2] = queuecount(p->requests);
		rep->message.arg[3] = queuecount(p->replies);
		rep->status = ReplyDone;
		return 0;

	case ReqAlloc:
		if(memcharge(&p->container, (ulong)req->message.arg[2]) < 0){
			rep->status = ReplyError;
			return 0;
		}
		rep->message.arg[2] = p->container.memused;
		rep->status = ReplyDone;
		return 0;

	case ReqBind:
		/*
		 * A name space is not a personality.  What a container calls
		 * a thing is its own, is in its own table, and is written
		 * into its checkpoint, so it crosses to another machine with
		 * it; what that name stands for on this machine is what a
		 * personality knows.  So this is answered here and not
		 * forwarded, and it needs no Pgrp: a Pgrp is a Plan 9 object
		 * that no checkpoint could carry.
		 *
		 * arg[2] is the local name and arg[3] the global one, in the
		 * order the bind control message takes them and the order
		 * the table itself is written in.
		 */
		{
			Ospreyproc *q;
			char *l, *g;

			q = (Ospreyproc*)p;
			if((l = ospreyname(q, req->message.arg[2])) == nil
			|| (g = ospreyname(q, req->message.arg[3])) == nil){
				rep->status = ReplyError;
				return 0;
			}
			if(ospreybind(q, l, g) < 0){
				rep->status = ReplyError;
				return 0;
			}
			if(ospreynamed != nil)
				ospreynamed(q, ReqBind);
			rep->status = ReplyDone;
			return 0;
		}

	case ReqExec:
		/*
		 * A program in a container of its own, laid out and paged by
		 * the caller's server.  The kernel makes the container; the
		 * device, which knows what a process is, does the rest.
		 */
		{
			long id;

			if(ospreyexec == nil
			|| (id = ospreyexec((Ospreyproc*)p, req->message.arg[2])) < 0){
				rep->status = ReplyError;
				return 0;
			}
			rep->message.arg[2] = id;
			rep->status = ReplyDone;
			return 0;
		}

	case ReqReserve:
		if(ospreyreserve == nil
		|| ospreyreserve((Ospreyproc*)p, req->message.arg[2], req->message.arg[3]) < 0){
			rep->status = ReplyError;
			return 0;
		}
		rep->status = ReplyDone;
		return 0;

	case ReqTick:
		if(ospreytickreq == nil
		|| ospreytickreq((Ospreyproc*)p, (int)(long)req->message.arg[2]) < 0){
			rep->status = ReplyError;
			return 0;
		}
		rep->status = ReplyDone;
		return 0;

	case ReqWait:
		/*
		 * Answered now if a child has already exited, later when one
		 * does (1: the device replies through ospreyreplylater), or
		 * refused when there is nobody to wait for.
		 */
		{
			long st;
			uvlong v;
			int r;

			if(ospreywait == nil
			|| (r = ospreywait((Ospreyproc*)p, req->sequence, &st, &v)) < 0){
				rep->status = ReplyError;
				return 0;
			}
			if(r > 0)
				return 1;	/* replied when the child exits */
			rep->message.arg[2] = v;
			rep->status = st;
			return 0;
		}
	}

	/*
	 * Everything above is mechanism and is answered here.  Everything
	 * below it -- opening a name, reading it, the shape of a file --
	 * is a personality, and a personality is a program.  A container
	 * that has named a server has all of it answered there, in that
	 * server's own name space, with the kernel doing nothing but
	 * carrying the message.
	 *
	 * A container that has named none falls back to the kernel's own
	 * Plan 9 personality in ospreykernop(), which is where all of this
	 * used to live and is what a library operating system is meant to
	 * replace.
	 */
	switch(forward((Ospreyproc*)p, req)){
	case 0:
		return 1;	/* answered outside the kernel */
	case Fwdfull:
		/*
		 * Delegated, but the server cannot take it just now.  Saying
		 * so is the answer.  Falling through to the kernel here --
		 * which the first version did, because forward returned the
		 * same -1 for a full ring as for no server at all -- had the
		 * personality this container had replaced answering for it
		 * whenever its server was busy.
		 */
		rep->status = ReplyRetry;
		return 0;
	}
	rep->status = ospreykernop((Ospreyproc*)p, req->message.op,
		&req->message.arg[2], &rep->message.arg[2]);
	return 0;
}

/*
 * Have another container answer the requests this one makes that the
 * kernel does not implement.  The server is an ordinary process with the
 * span mapped: the request appears on its own request ring, carrying the
 * container and sequence it came from, and the answer it leaves on its
 * reply ring is routed back to them.
 */
int
ospreydelegate(Ospreyproc *p, Ospreyproc *server)
{
	if(p == nil || p->used == 0)
		return -1;
	if(server == p)
		return -1;
	if(p->server != nil)
		p->server->serving--;
	p->server = server;
	if(server != nil)
		server->serving++;
	return 0;
}

/*
 * Move a request to the server's ring, keeping where it came from.  The
 * two ways of failing are not the same and must not be reported the same:
 * Fwdnone means this container has no personality of its own and the
 * kernel's is what it gets, Fwdfull means it has one that cannot take the
 * request at this moment and should be asked again.
 */
static int
forward(Ospreyproc *p, Request *req)
{
	Ospreyproc *s;
	Message m;

	if(p == nil || (s = p->server) == nil || s->used == 0)
		return Fwdnone;
	m = req->message;
	m.container = p->process.id;
	m.sequence = req->sequence;
	if(queuefull(s->process.requests))
		return Fwdfull;
	if(queueput(s->process.requests, &m) < 0)
		return Fwdfull;
	return 0;
}

/* whether this container answers for others: its rings run inbound then */
int
ospreyisserver(Ospreyproc *p)
{
	return p != nil && p->used && p->serving > 0;
}

/*
 * A request of a container's own, answered at once and not through its
 * rings: a server's request ring carries its clients' requests and its
 * reply ring its answers to them, so a server that needs something of
 * the kernel - its reservation, the clock - asks this way.  Only what
 * the dispatcher answers itself; a request it would forward or hold is
 * refused.  The reply's value comes back in arg[0].
 */
int
ospreycall(Ospreyproc *p, uvlong op, uvlong *arg, long *status)
{
	Request req;
	Reply rep;
	int i, n;

	if(p == nil || p->used == 0)
		return -1;
	memset(&req, 0, sizeof req);
	memset(&rep, 0, sizeof rep);
	req.message.op = op;
	req.message.container = p->process.id;
	req.sequence = ++p->sequence;
	for(i = 0; i < Ospreynarg; i++)
		req.message.arg[2+i] = arg[i];
	switch(op){
	case ReqYield: case ReqPoll: case ReqAlloc: case ReqBind:
	case ReqExec: case ReqReserve: case ReqTick:
		break;
	default:
		return -1;
	}
	n = dispatch(&p->process, &req, &rep, nil);
	if(n != 0)
		return -1;
	*status = rep.status;
	arg[0] = rep.message.arg[2];
	return 0;
}

/* who answers for this container, if anyone does */
Ospreyproc*
ospreyserverof(Ospreyproc *p)
{
	if(p == nil || p->used == 0)
		return nil;
	return p->server;
}

/*
 * Take what a server has answered and give it to whoever asked.  A
 * container that serves others should not also be asking, since its
 * reply ring is where its answers go.
 */
/*
 * Tell a container's server something about that container, on the same
 * ring its requests go on and with its identity on the message, since
 * that is how a server knows whose anything is.  There is no reply: what
 * the message says is that there is nothing left to reply to.
 */
int
ospreytellserver(Ospreyproc *p, int op)
{
	Ospreyproc *s;
	Message m;

	if(p == nil || p->used == 0 || (s = p->server) == nil || s->used == 0)
		return -1;
	memset(&m, 0, sizeof m);
	m.op = op;
	m.container = p->process.id;
	m.sequence = 0;
	if(queuefull(s->process.requests) || queueput(s->process.requests, &m) < 0)
		return -1;
	return 0;
}

int
ospreyroute(Ospreyproc *s)
{
	Ospreyproc *p;
	Message m;
	int n;

	mapfix(s);
	/*
	 * Only a container that answers for others has anything here to
	 * route.  Draining anyone else's reply ring would take the answers
	 * meant for the container itself, which is what the first version
	 * did.
	 */
	if(s == nil || s->used == 0 || s->serving == 0)
		return 0;
	for(n = 0; queueget(s->process.replies, &m) == 0; n++){
		if((p = ospreylookup(m.container)) == nil || p == s)
			continue;
		if(queuefull(p->process.replies))
			continue;
		queueput(p->process.replies, &m);
	}
	return n;
}

int
ospreyservicep(Ospreyproc *p, uvlong now)
{
	mapfix(p);
	if(p == nil || p->used == 0 || p->serving)
		return -1;
	ready();
	runtime.now = now;
	return runtimeserve(&runtime, &p->process, dispatch, nil);
}

static Sem*
semof(Ospreyproc *p, ulong i)
{
	mapfix(p);
	if(p == nil || p->used == 0 || p->map == nil || i >= p->map->nsem)
		return nil;
	return (Sem*)((uchar*)p->map + p->map->sem) + i;
}

/*
 * A packet for this container: charge it, and keep the block whole.  A
 * container over its network caps, or with no room, refuses it, and the
 * caller frees the block as it would have anyway.
 *
 * The charging is pktqput's, and only pktqput's.  Charging here as well
 * cost every packet twice and gave only one of them back when it was
 * taken, so a container with a cap stopped hearing anything after about
 * half of it and never recovered.
 */
int
ospreypktput(Ospreyproc *p, void *block, ulong len)
{
	Pkt *k;

	if(p == nil || p->used == 0 || block == nil)
		return -1;
	if(pktqfull(&p->pktq))
		return -1;
	k = &p->pkt[p->pktq.put % Npkt];
	k->block = block;
	k->len = len;
	k->container = &p->process.container;
	return pktqput(&p->pktq, k);
}

/*
 * Take the next packet.  The block is handed back rather than read: what
 * is in it is the driver's business and this layer has no way to look
 * inside one.  The caller copies what it wants and frees it.
 */
int
ospreypktget(Ospreyproc *p, void **block, ulong *len)
{
	Pkt k;

	if(p == nil || p->used == 0)
		return -1;
	if(pktqget(&p->pktq, &k) < 0)
		return -1;
	netrelease(&p->process.container, k.len, 1);
	*block = k.block;
	*len = k.len;
	return 0;
}

/* how a container's packets have been arriving; the device keeps count */
ulong	(*ospreypktdirect)(Ospreyproc*);
ulong	(*ospreypktcopied)(Ospreyproc*);
int	(*ospreyetherea)(Ospreyproc*, uchar*);
/*
 * How the kernel says something to a container's server.  The device
 * owns it, since waking a server is a device matter; this layer uses it
 * to say that a container's names have changed, which a server cannot
 * see for itself because bind is answered here and never forwarded.
 */
void	(*ospreynamed)(Ospreyproc*, int op);

/*
 * Starting a program and waiting for it are the kernel's: a program is
 * a process, which this layer has no notion of.  exec is given the
 * caller and the offset of the name in its data area and answers the
 * new container's identity or -1; wait is given the caller and the
 * request's sequence and answers 0 with a status and value to reply
 * now, 1 to reply later through ospreyreplylater when a child exits,
 * or -1 when there is no child to wait for.
 */
long	(*ospreyexec)(Ospreyproc*, uvlong nameoff);
int	(*ospreywait)(Ospreyproc*, uvlong seq, long *status, uvlong *value);
/*
 * And a task's reservation and its clock: the device converts the
 * microseconds a task speaks in to the counter this layer keeps time
 * in, and owns the clock interrupt that gives a semaphore.
 */
int	(*ospreyreserve)(Ospreyproc*, uvlong usbudget, uvlong usperiod);
int	(*ospreytickreq)(Ospreyproc*, int sem);

/*
 * Set a container's reservation: what it is owed every period, and by
 * when.  The current period's use is forgotten; the totals stand.
 */
int
ospreysetreservation(Ospreyproc *p, uvlong budget, uvlong period, uvlong deadline)
{
	Container *c;

	if(p == nil || p->used == 0 || period == 0)
		return -1;
	lockall();
	c = &p->process.container;
	c->budget = budget;
	c->period = period;
	c->deadline = deadline;
	/*
	 * The period accounting starts afresh: what was used of the old
	 * reservation is not owed against the new one, and the epoch is
	 * in units of the old period.  The best-effort total and the
	 * periods seen so far stand.
	 */
	c->used = 0;
	c->epoch = 0;
	unlockall();
	return 0;
}

/*
 * A reply the kernel owes for a request it held on to - a wait, answered
 * when the child exits.  The sequence is the request's own, so the caller
 * matches it as it would any reply.
 */
int
ospreyreplylater(Ospreyproc *p, uvlong seq, uvlong op, long status, uvlong value)
{
	Reply r;

	if(p == nil || p->used == 0)
		return -1;
	memset(&r, 0, sizeof r);
	r.message.op = op;
	r.message.container = p->process.id;
	r.message.arg[2] = value;
	r.sequence = seq;
	r.status = status;
	return processreply(&p->process, &r);
}

/*
 * The device says which of a container's transmit buffers are free; this
 * puts it where the container can read it without asking.  mapfix does
 * not touch it: it is not geometry, it is what the card is doing.
 */
void
ospreysettxavail(Ospreyproc *p, uvlong m)
{
	if(p == nil || p->used == 0 || p->map == nil)
		return;
	p->map->txavail = m;
}

ulong
ospreypktcount(Ospreyproc *p)
{
	if(p == nil || p->used == 0)
		return 0;
	return pktqcount(&p->pktq);
}

void
ospreysemgive(Ospreyproc *p, ulong i)
{
	Sem *s;

	if((s = semof(p, i)) == nil)
		return;
	ospreylocksem();
	semgive(s);
	ospreyunlocksem();
}

uvlong
ospreysemcount(Ospreyproc *p, ulong i)
{
	uvlong n;

	ospreylocksem();
	n = semcount(semof(p, i));
	ospreyunlocksem();
	return n;
}

/*
 * Resolve the arms a caller left in the shared span into the objects
 * they name, so the portable scan never sees an offset.  An arm past the
 * end of the array, or naming something the container does not have, is
 * refused rather than quietly turned off: a caller that miscounts should
 * hear about it.
 */
static int
arms(Ospreyproc *p, uvlong armoff, int narms, Arm *a)
{
	Ospreyarm *o;
	int i;

	mapfix(p);
	if(p == nil || p->used == 0 || p->map == nil)
		return -1;
	if(narms <= 0 || narms > Narm)
		return -1;
	if((o = ospreydata(p, armoff, narms*sizeof(Ospreyarm))) == nil)
		return -1;
	for(i = 0; i < narms; i++){
		a[i].op = (int)o[i].op;
		a[i].q = nil;
		a[i].s = nil;
		a[i].m = nil;
		switch(a[i].op){
		case MSlast:
		case MSnoop:
			continue;
		case MSget:
		case MSput:
			switch(o[i].obj){
			case 0:
				a[i].q = p->process.requests;
				break;
			case 1:
				a[i].q = p->process.replies;
				break;
			case 2:
				a[i].q = p->process.output;
				break;
			default:
				return -1;
			}
			a[i].m = ospreydata(p, o[i].buf, sizeof(Message));
			if(a[i].m == nil)
				return -1;
			continue;
		case MSdown:
			if((a[i].s = semof(p, (ulong)o[i].obj)) == nil)
				return -1;
			continue;
		}
		return -1;
	}
	return 0;
}

/*
 * -2 when the arms themselves are wrong, -1 when they are good and none
 * is ready.  A caller that cannot tell those apart waits for something
 * that will never happen.
 */
int
ospreyselectready(Ospreyproc *p, uvlong armoff, int narms)
{
	Arm a[Narm];

	int i;

	if(arms(p, armoff, narms, a) < 0)
		return -2;
	ospreylocksem();
	i = selectready(a, narms);
	ospreyunlocksem();
	return i;
}

/*
 * Perform one ready arm and record which it was where the caller can
 * read it without asking again.
 */
int
ospreyselect(Ospreyproc *p, uvlong armoff, int narms)
{
	Arm a[Narm];
	int i;

	if(arms(p, armoff, narms, a) < 0)
		return -2;
	ospreylocksem();
	i = selectscan(a, narms);
	ospreyunlocksem();
	if(p->map != nil)
		p->map->selected = i < 0 ? ~0ULL : (uvlong)i;
	return i;
}

uvlong
ospreymsgsize(void)
{
	return sizeof(Message);
}

/* what the message at that offset says: its operation and the caller's words */
int
ospreymessage(Ospreyproc *p, uvlong off, uvlong *op, uvlong *arg)
{
	Message *m;
	int i;

	mapfix(p);
	if((m = ospreydata(p, off, sizeof(Message))) == nil)
		return -1;
	*op = m->op;
	for(i = 0; i < Ospreynarg; i++)
		arg[i] = m->arg[2+i];
	return 0;
}

/* and the answer to it, on the container's reply ring */
int
ospreyanswer(Ospreyproc *p, uvlong off, long status)
{
	Message *m;
	Reply r;

	mapfix(p);
	if(p == nil || p->used == 0)
		return -1;
	if((m = ospreydata(p, off, sizeof(Message))) == nil)
		return -1;
	memset(&r, 0, sizeof r);
	r.message = *m;
	r.sequence = m->sequence;
	r.status = status;
	return processreply(&p->process, &r);
}

/*
 * Work for a driver task: a place in the container's data area and how
 * much of it.  This is the queue the presentation's driver takes from
 * on its third arm, and it is the container's own memory, so whoever
 * has the slice mapped may fill it without the kernel.
 */
int
ospreyoutput(Ospreyproc *p, uvlong off, uvlong len)
{
	Message m;

	mapfix(p);
	if(p == nil || p->used == 0)
		return -1;
	if(ospreydata(p, off, (ulong)len) == nil)
		return -1;
	memset(&m, 0, sizeof m);
	m.op = ReqWrite;
	m.container = p->process.id;
	m.arg[2] = off;
	m.arg[3] = len;
	return queueput(p->process.output, &m);
}

/* room on the output queue for one more piece of work */
int
ospreyoutputroom(Ospreyproc *p)
{
	mapfix(p);
	if(p == nil || p->used == 0)
		return 0;
	return !queuefull(p->process.output);
}

int
ospreyoutputready(Ospreyproc *p)
{
	mapfix(p);
	if(p == nil || p->used == 0)
		return 0;
	return !queueempty(p->process.output);
}

int
ospreyrequestready(Ospreyproc *p)
{
	mapfix(p);
	if(p == nil || p->used == 0)
		return 0;
	return !queueempty(p->process.requests);
}

/*
 * The whole of what a container is, as text, so that it can be written
 * somewhere and read back -- into this kernel later, or into another
 * one.  Ring storage, the data area, the packets and the channels the
 * kernel holds for it are not part of it: what is here is what a
 * container is, not what it happens to be holding.
 */
/*
 * One line per message a ring is holding.  A queue is single producer,
 * single consumer and its storage is a plain array, so what is in it is
 * the slots between get and put.
 */
static char*
snapqueue(char *p, char *e, char *name, Queue *q)
{
	Message *m;
	uvlong i;
	int j;

	if(q == nil || q->message == 0 || q->size == 0)
		return p;
	for(i = q->get; i != q->put; i++){
		m = &QMESSAGE(q)[i % q->size];
		p = seprint(p, e, "queued %s %llud %llud %llud",
			name, m->op, m->sequence, m->container);
		for(j = 0; j < MessageWords-3; j++)
			p = seprint(p, e, " %llud", m->arg[j]);
		p = seprint(p, e, "\n");
	}
	return p;
}

/*
 * The buffers the messages in a ring name.  A message says where in the
 * container's data area its buffer is, so a checkpoint that carried the
 * messages and not the area would answer them against whatever happened
 * to be at that offset.  Written in chunks and only the chunks that
 * hold something, so a container with an empty area writes nothing.
 */
enum {
	Snapchunk = 32,		/* bytes of data area to a line */
};

/*
 * The counts, what has ever been given and what has ever been taken.
 * The last two are accounting and go with it so that a container's
 * account of itself does not restart at zero on another machine.
 */
static char*
snapsem(char *p, char *e, Ospreyproc *q)
{
	Sem *sm;
	uvlong c[Nsemmax], g[Nsemmax], t[Nsemmax];
	ulong n;

	if(q->map == nil)
		return p;
	/*
	 * Taken under the lock, printed outside it.  An interrupt giving a
	 * semaphore takes this lock -- every packet that arrives does --
	 * and seprint is not the sort of work to hold it across, the less
	 * so now that how many semaphores there are is a configuration.
	 *
	 * semof and not the offset out of the map: a container may write
	 * every byte of its own map, and mapfix is what puts the geometry
	 * back.  Reading the field raw is the bug this file has already
	 * had twice.
	 */
	ospreylocksem();
	for(n = 0; n < nsem && n < nelem(c); n++){
		if((sm = semof(q, n)) == nil){
			c[n] = g[n] = t[n] = 0;
			continue;
		}
		c[n] = sm->count;
		g[n] = sm->given;
		t[n] = sm->taken;
	}
	ospreyunlocksem();
	for(n = 0; n < nsem && n < nelem(c); n++){
		if(c[n] == 0 && g[n] == 0 && t[n] == 0)
			continue;
		p = seprint(p, e, "sem %lud %llud %llud %llud\n",
			n, c[n], g[n], t[n]);
	}
	return p;
}

static char*
snapdata(char *p, char *e, Ospreyproc *q)
{
	static char hex[] = "0123456789abcdef";
	uchar *d;
	ulong off, len, i;

	len = (ulong)ospreydatalen(q);
	if((d = ospreydata(q, 0, len)) == nil)
		return p;
	for(off = 0; off < len; off += Snapchunk){
		ulong n;

		n = len - off < Snapchunk ? len - off : Snapchunk;
		for(i = 0; i < n; i++)
			if(d[off+i] != 0)
				break;
		if(i == n)
			continue;	/* nothing in this one */
		p = seprint(p, e, "data %lud ", off);
		for(i = 0; i < n && p < e - 2; i++){
			*p++ = hex[d[off+i] >> 4];
			*p++ = hex[d[off+i] & 0xF];
		}
		p = seprint(p, e, "\n");
	}
	return p;
}

static int
snaphex(int c)
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

long
ospreysnapwrite(char *buf, long nbuf)
{
	Ospreyproc *q;
	Process *r;
	Container *c;
	char *p, *e;
	ulong i, j;

	ready();
	p = buf;
	e = buf + nbuf;
	for(i = 0; i < Nproc; i++){
		if(procs[i].used == 0)
			continue;
		q = &procs[i];
		r = &q->process;
		c = &r->container;
		p = seprint(p, e, "container %llud\n", r->id);
		p = seprint(p, e, "core %lud\n", r->core);
		p = seprint(p, e, "state %s\n", statename(r->state));
		p = seprint(p, e, "budget %llud\n", c->budget);
		p = seprint(p, e, "period %llud\n", c->period);
		p = seprint(p, e, "deadline %llud\n", c->deadline);
		p = seprint(p, e, "used %llud\n", c->used);
		p = seprint(p, e, "besteffort %llud\n", c->besteffort);
		p = seprint(p, e, "periods %llud\n", c->periods);
		p = seprint(p, e, "mode %s\n", c->strict ? "strict" : "besteffort");
		p = seprint(p, e, "memory %lud\n", c->memory);
		p = seprint(p, e, "memused %lud\n", c->memused);
		p = seprint(p, e, "netmax %lud\n", c->netmax);
		p = seprint(p, e, "packetmax %lud\n", c->packetmax);
		p = seprint(p, e, "netbytes %lud\n", c->netbytes);
		p = seprint(p, e, "netpackets %lud\n", c->netpackets);
		p = seprint(p, e, "version %llud\n", q->version);
		if(q->owner[0] != '\0')
			p = seprint(p, e, "owner %s\n", q->owner);
		for(j = 0; j < Ngrant; j++)
			if(q->grant[j][0] != '\0')
				p = seprint(p, e, "grant %s\n", q->grant[j]);
		/*
		 * What is in the rings, message by message, rather than the
		 * indices alone: the indices without the messages they point
		 * at named storage that was not going anywhere.  A ring that
		 * is empty writes nothing, which is the usual case.
		 */
		p = snapqueue(p, e, "requests", r->requests);
		p = snapqueue(p, e, "replies", r->replies);
		p = snapqueue(p, e, "output", r->output);
		/*
		 * The data area whatever the rings hold.  It used to be
		 * written only when a message was in flight, on the argument
		 * that the data was there for the message to name; but the
		 * area is the container's memory, and a container that had
		 * built its select arms and was waiting on them lost them
		 * for no saving at all -- snapdata skips a chunk that is
		 * still zero, so an area nothing has written costs nothing.
		 */
		p = snapdata(p, e, q);
		/*
		 * And its semaphores, which are the one thing the microkernel
		 * itself keeps for a container that a checkpoint did not
		 * carry.  A task waiting on one, or one given and not yet
		 * taken, is state; dropping it makes a container that
		 * migrates lose a wakeup it was owed.
		 */
		p = snapsem(p, e, q);
		for(j = 0; j < r->ns.n; j++)
			p = seprint(p, e, "name %s %s\n",
				r->ns.name[j].local, r->ns.name[j].global);
		p = seprint(p, e, "end\n");
	}
	/*
	 * seprint stops at the end and says nothing, and a checkpoint cut
	 * in half is worse than no checkpoint: it would be signed as if it
	 * were whole and read back as partial state.  A ring with a great
	 * many messages in it is what makes this reachable.
	 */
	if(p >= buf + nbuf - 1)
		return -1;
	return p - buf;
}

static char*
snapword(char **pp)
{
	char *s, *w;

	s = *pp;
	while(*s == ' ' || *s == '\t')
		s++;
	w = s;
	while(*s != '\0' && *s != ' ' && *s != '\t')
		s++;
	if(*s != '\0')
		*s++ = '\0';
	*pp = s;
	return w;
}

/*
 * Read a checkpoint back.  A container it names that is not here is
 * made; one that is here is set to what the checkpoint says.  The text
 * is written over as it is parsed, so the caller must own it.
 */
int
ospreysnapread(char *text, long n)
{
	Ospreyproc *p;
	Process *r;
	Container *c;
	char *s, *line, *key, *a, *b;
	uvlong id, v, now;
	int made, runnable;

	ready();
	if(text == nil || n <= 0)
		return -1;
	text[n-1] = '\0';
	p = nil;
	made = 0;
	runnable = 0;
	now = runtime.now;
	for(s = text; *s != '\0'; ){
		line = s;
		while(*s != '\0' && *s != '\n')
			s++;
		if(*s == '\n')
			*s++ = '\0';
		key = snapword(&line);
		if(*key == '\0' || *key == '#')
			continue;
		if(strcmp(key, "container") == 0){
			id = strtoull(snapword(&line), nil, 0);
			if((p = ospreylookup(id)) == nil){
				p = ospreycreate(id, 0, 1, 0);
				made++;
			}
			runnable = 0;
			continue;
		}
		if(p == nil || p->used == 0)
			continue;
		r = &p->process;
		c = &r->container;
		a = snapword(&line);
		v = strtoull(a, nil, 0);
		if(strcmp(key, "end") == 0){
			/*
			 * A container that was running when it was written
			 * out is running again: a checkpoint that came back
			 * only as settings would not be a restart.
			 */
			if(runnable)
				ospreyattach(p, p->process.core, now);
			p = nil;
		} else if(strcmp(key, "state") == 0)
			runnable = strcmp(a, "runnable") == 0;
		else if(strcmp(key, "core") == 0)
			r->core = v;
		else if(strcmp(key, "budget") == 0)
			c->budget = v;
		else if(strcmp(key, "period") == 0)
			c->period = v == 0 ? 1 : v;
		else if(strcmp(key, "deadline") == 0)
			c->deadline = v;
		else if(strcmp(key, "used") == 0)
			c->used = v;
		else if(strcmp(key, "besteffort") == 0)
			c->besteffort = v;
		else if(strcmp(key, "periods") == 0)
			c->periods = v;
		else if(strcmp(key, "mode") == 0)
			containerstrict(c, strcmp(a, "strict") == 0);
		else if(strcmp(key, "memory") == 0)
			c->memory = v;
		else if(strcmp(key, "memused") == 0)
			c->memused = v;
		else if(strcmp(key, "netmax") == 0)
			c->netmax = v;
		else if(strcmp(key, "packetmax") == 0)
			c->packetmax = v;
		else if(strcmp(key, "netbytes") == 0)
			c->netbytes = v;
		else if(strcmp(key, "netpackets") == 0)
			c->netpackets = v;
		else if(strcmp(key, "version") == 0)
			p->version = v;
		else if(strcmp(key, "requests") == 0)
			USED(v);	/* an older checkpoint's indices */
 else if(strcmp(key, "queued") == 0){
			Message m;
			Queue *q;
			int j;

			/* a is the ring's name; the rest is the message */
			if(strcmp(a, "requests") == 0)
				q = r->requests;
			else if(strcmp(a, "replies") == 0)
				q = r->replies;
			else if(strcmp(a, "output") == 0)
				q = r->output;
			else
				continue;
			memset(&m, 0, sizeof m);
			m.op = strtoull(snapword(&line), nil, 0);
			m.sequence = strtoull(snapword(&line), nil, 0);
			m.container = strtoull(snapword(&line), nil, 0);
			for(j = 0; j < MessageWords-3; j++)
				m.arg[j] = strtoull(snapword(&line), nil, 0);
			queueput(q, &m);
		} else if(strcmp(key, "data") == 0){
			uchar *d;
			ulong off, len;
			int hi, lo;

			off = (ulong)strtoull(a, nil, 0);
			b = snapword(&line);
			len = strlen(b) / 2;
			if(len == 0 || (d = ospreydata(p, off, len)) == nil)
				continue;
			for(len = 0; b[2*len] != '\0' && b[2*len+1] != '\0'; len++){
				hi = snaphex(b[2*len]);
				lo = snaphex(b[2*len+1]);
				if(hi < 0 || lo < 0)
					break;
				d[len] = (hi<<4) | lo;
			}
		} else if(strcmp(key, "sem") == 0){
			Sem *sm;
			uvlong sc, sg, st;
			ulong sn;

			sn = (ulong)strtoull(a, nil, 0);
			/*
			 * A checkpoint written where a container had more
			 * semaphores than this kernel gives one is refused
			 * rather than read in part: the limits are settable
			 * now, so two machines may disagree about how many
			 * there are, and a container that arrives holding
			 * some of what it held is worse than one that does
			 * not arrive.
			 */
			if(r == nil || p == nil || (sm = semof(p, sn)) == nil)
				return -1;
			/*
			 * Parsed first and stored after: an interrupt giving
			 * a semaphore wants this lock, and taking a line of
			 * text apart is not the sort of work to hold it
			 * across.
			 */
			sc = strtoull(snapword(&line), nil, 0);
			sg = strtoull(snapword(&line), nil, 0);
			st = strtoull(snapword(&line), nil, 0);
			ospreylocksem();
			sm->count = sc;
			sm->given = sg;
			sm->taken = st;
			ospreyunlocksem();
		} else if(strcmp(key, "name") == 0){
			b = snapword(&line);
			nsbind(&r->ns, a, b);
		} else if(strcmp(key, "owner") == 0)
			ospreysetowner(p, a);
		else if(strcmp(key, "grant") == 0)
			ospreygrant(p, a);
	}
	return made;
}

/*
 * The serialisable part of a container: identity, core, state, budget
 * accounting, ring indices and namespace size.  Ring storage, the data
 * area and any chan the kernel holds for it are the adapter's, and are
 * not part of the snapshot.
 */
int
ospreycheckpoint(Ospreyproc *p)
{
	if(p == nil || p->used == 0)
		return -1;
	if(snapsave(&p->process, &p->snap) < 0)
		return -1;
	p->saved = 1;
	return 0;
}

int
ospreyrestore(Ospreyproc *p)
{
	if(p == nil || p->used == 0 || p->saved == 0)
		return -1;
	return snapload(&p->process, &p->snap);
}

int
ospreybind(Ospreyproc *p, char *local, char *global)
{
	if(p == nil || p->used == 0)
		return -1;
	return nsbind(&p->process.ns, local, global);
}

/*
 * A name a request points at: NUL terminated, inside the container's own
 * data area, and no longer than a name may be.  The bounds are the
 * kernel's, since a container may write every byte of its own map.
 */
char*
ospreyname(Ospreyproc *p, uvlong off)
{
	char *a, *e;
	uvlong n;

	if((a = ospreydata(p, off, 1)) == nil)
		return nil;
	n = ospreydatalen(p) - off;
	if(n > Nnamelen)
		n = Nnamelen;
	if((e = memchr(a, 0, n)) == nil || e == a)
		return nil;
	return a;
}

/*
 * What a name means to this container.  The table is the policy layer's
 * Ns: it is the container's own, it is written into a checkpoint and
 * read back out of one, so it goes where the container goes.  A name
 * with no entry is not refused; it is left as it stands, and whoever
 * answers for the container makes what it can of it.  That is the buddy
 * operating system underneath doing what a buddy is for.
 */
char*
ospreyresolve(Ospreyproc *p, char *local)
{
	char *g;

	if(p == nil || p->used == 0 || local == nil)
		return local;
	if((g = nslookup(&p->process.ns, local)) != nil)
		return g;
	return local;
}

int
ospreyunbind(Ospreyproc *p, char *local)
{
	if(p == nil || p->used == 0)
		return -1;
	return nsunbind(&p->process.ns, local);
}

char*
ospreystatusname(long status)
{
	switch(status){
	case ReplyPending:	return "pending";
	case ReplyDone:		return "done";
	case ReplyError:	return "error";
	case ReplyBlocked:	return "blocked";
	case ReplyRetry:	return "retry";
	}
	return "?";
}

/* the reverse, for a caller that has no business knowing the numbers */
long
ospreystatusof(char *name)
{
	if(strcmp(name, "pending") == 0)	return ReplyPending;
	if(strcmp(name, "done") == 0)		return ReplyDone;
	if(strcmp(name, "error") == 0)		return ReplyError;
	if(strcmp(name, "blocked") == 0)	return ReplyBlocked;
	if(strcmp(name, "retry") == 0)		return ReplyRetry;
	return ReplyError;
}

static char*
statename(int state)
{
	switch(state){
	case ProcessNew:	return "new";
	case ProcessRunnable:	return "runnable";
	case ProcessBlocked:	return "blocked";
	case ProcessExited:	return "exited";
	}
	return "?";
}

long
ospreystatus(char *buf, long nbuf, uvlong now, uvlong hz)
{
	char *p, *e;
	Process *q;
	Task *t;
	uvlong semc[Nsemmax], semg[Nsemmax], semt[Nsemmax];
	ulong i, n;

	ready();
	p = buf;
	/*
	 * Room is kept at the end to say so if the rest did not fit.  A
	 * status that stops in the middle of a container looks exactly
	 * like a machine with fewer containers on it.
	 */
	e = buf + nbuf - 16;
	p = seprint(p, e, "now %llud hz %llud cores %lud procs %lud"
		" arena %llud slice %lud data %lud pagesize %lud\n",
		now, hz, (ulong)Ncore, (ulong)Nproc,
		ospreyarenasize(), slicesize, ndata,
		(ulong)Pagesize);
	for(i = 0; i < Ncore; i++){
		/*
		 * The run queue is a list the clock is free to change on
		 * another core, so walk it under that core's lock.
		 */
		ospreylockcore(i);
		for(n = 0, t = cores[i].runq; t != nil; t = t->next)
			n++;
		if(n == 0 && cores[i].cycles == 0){
			ospreyunlockcore(i);
			continue;
		}
		p = seprint(p, e, "core %lud runq %lud cycles %llud switches %llud"
			" current %llud order",
			i, n, cores[i].cycles, cores[i].contextswitches,
			taskid(cores[i].current));
		for(t = cores[i].runq; t != nil; t = t->next)
			p = seprint(p, e, " %llud", taskid(t));
		ospreyunlockcore(i);
		p = seprint(p, e, "\n");
	}
	for(i = 0; i < Nproc; i++){
		if(procs[i].used == 0)
			continue;
		q = &procs[i].process;
		p = seprint(p, e, "proc %llud core %lud %s"
			" budget %llud used %llud period %llud deadline %llud"
			" besteffort %llud periods %llud %s"
			" mem %lud of %lud net %lud of %lud"
			" requests %llud replies %llud output %llud"
			" slice %llud data %llud pid %d\n",
			q->id, q->core, statename(q->state),
			q->container.budget, q->container.used,
			q->container.period, q->task.deadline,
			q->container.besteffort, q->container.periods,
			q->container.strict ? "strict" : "besteffort",
			q->container.memused, q->container.memory,
			q->container.netbytes, q->container.netmax,
			queuecount(q->requests), queuecount(q->replies),
			queuecount(q->output),
			procs[i].slice, ospreydataoffset(&procs[i]),
			procs[i].pid);
		/* the semaphores, and the container's private names */
		{
			uvlong *l;
			uvlong j;

			l = pagelist(&procs[i]);
				p = seprint(p, e, "owner %llud %s", q->id,
				procs[i].owner[0] ? procs[i].owner : "-");
			for(j = 0; j < Ngrant; j++)
				if(procs[i].grant[j][0] != '\0')
					p = seprint(p, e, " %s", procs[i].grant[j]);
			p = seprint(p, e, "\n");
			p = seprint(p, e, "segment %llud %s %lud\n",
				q->id, procs[i].segname, slicesize);
			p = seprint(p, e, "pages %llud", q->id);
			for(j = 0; l != nil && j < procs[i].npage; j++)
				p = seprint(p, e, " %llud", l[j]);
			p = seprint(p, e, "\n");
		}
		p = seprint(p, e, "packets %llud direct %lud copied %lud held %lud",
			q->id, ospreypktdirect(&procs[i]),
			ospreypktcopied(&procs[i]), pktqcount(&procs[i].pktq));
		if(ospreyetherea != nil){
			uchar ea[6];

			if(ospreyetherea(&procs[i], ea) > 0)
				p = seprint(p, e, " ea %.2ux%.2ux%.2ux%.2ux%.2ux%.2ux",
					ea[0], ea[1], ea[2], ea[3], ea[4], ea[5]);
		}
		p = seprint(p, e, "\n");
		p = seprint(p, e, "sem %llud", q->id);
		/* under the lock, printed outside it; snapsem says why */
		ospreylocksem();
		for(n = 0; n < nsem && n < nelem(semc); n++){
			Sem *sm = semof(&procs[i], n);

			if(sm == nil){
				semc[n] = semg[n] = semt[n] = 0;
				continue;
			}
			semc[n] = sm->count;
			semg[n] = sm->given;
			semt[n] = sm->taken;
		}
		ospreyunlocksem();
		for(n = 0; n < nsem && n < nelem(semc); n++)
			p = seprint(p, e, " %llud/%llud/%llud",
				semc[n], semg[n], semt[n]);
		p = seprint(p, e, "\n");
		for(n = 0; n < q->ns.n; n++)
			p = seprint(p, e, "name %llud %s %s\n", q->id,
				q->ns.name[n].local, q->ns.name[n].global);
	}
	if(p >= e - 1)
		p = seprint(p, buf + nbuf, "truncated\n");
	return p - buf;
}
