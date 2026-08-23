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
#include "../lib.h"
#include "osprey.h"

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
	Npkt		= 32,	/* packets a container may hold */
	Npktbuf		= 16,	/* receive buffers it lends an interface */
	Pktbufsize	= 2112,	/* one of them, room for 2048 and a trailer */
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
	Ospreymap *map;		/* the slice itself */
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

static int forward(Ospreyproc*, Request*);
static char *statename(int);

static uchar *arena;		/* the shared span, or nil until given one */
static ulong arenasize;
static ulong slicesize;

#define ROUNDUP(n, a)	(((n)+(a)-1) & ~((uvlong)(a)-1))

static struct {
	char	*name;
	int	op;
} opnames[] = {
	{"read",	ReqRead},
	{"write",	ReqWrite},
	{"open",	ReqOpen},
	{"close",	ReqClose},
	{"wait",	ReqWait},
	{"send",	ReqSend},
	{"recv",	ReqRecv},
	{"stat",	ReqStat},
	{"bind",	ReqBind},
	{"alloc",	ReqAlloc},
	{"yield",	ReqYield},
	{"poll",	ReqPoll},
};

static char *attrnames[] = {
	"core", "state", "budget", "used", "period", "deadline",
	"besteffort", "periods", "mode", "memory", "memused",
	"netbytes", "netmax", "packets", "requests", "replies",
	"slice", "data", "pid", "version", nil,
};

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
	else if(strcmp(name, "packets") == 0)
		s = seprint(s, e, "%lud", (ulong)pktqcount(&p->pktq));
	else if(strcmp(name, "requests") == 0)
		s = seprint(s, e, "%llud", queuecount(q->requests));
	else if(strcmp(name, "replies") == 0)
		s = seprint(s, e, "%llud", queuecount(q->replies));
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
	"budget", "period", "deadline", "memory", "netmax", "mode", nil,
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
	return Nsem;
}

static void
sizes(void)
{
	if(slicesize != 0)
		return;
	slicesize = ROUNDUP(sizeof(Ospreymap), Align)
		+ ROUNDUP(2*sizeof(Queue), Align)
		+ ROUNDUP(Nsem*sizeof(Sem), Align)
		+ ROUNDUP(2*Nqueue*sizeof(Message), Align)
		+ ROUNDUP(Ndata, Align)
		+ Npktbuf*Pktbufsize;
	slicesize = ROUNDUP(slicesize, Align);
}

int
ospreyarena(void *base, ulong size)
{
	ulong need;

	sizes();
	need = slicesize * Nproc;
	if(base == nil || size < need)
		return -1;
	arena = base;
	arenasize = size;
	memset(arena, 0, need);
	return 0;
}

uvlong
ospreyarenasize(void)
{
	sizes();
	return slicesize * Nproc;
}

uvlong
ospreyslice(Ospreyproc *p)
{
	return p == nil ? 0 : p->slice;
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
	if(p == nil || p->used == 0 || p->map == nil)
		return 0;
	return p->slice + p->map->data;
}

uvlong
ospreydatalen(Ospreyproc *p)
{
	if(p == nil || p->used == 0 || p->map == nil)
		return 0;
	return p->map->datalen;
}

/* where this container's receive buffers are, and how many */
int
ospreymapsizes(Ospreyproc *p, uvlong *off, uvlong *n, uvlong *size)
{
	if(p == nil || p->used == 0 || p->map == nil)
		return -1;
	*off = p->map->pktbuf;
	*n = p->map->npktbuf;
	*size = p->map->pktbufsize;
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
	Queue *rq, *pq;
	Message *rm, *pm;
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
	base = arena + p->slice;
	memset(base, 0, slicesize);
	m = (Ospreymap*)base;
	m->magic = Ospreymagic;
	m->id = id;
	m->size = Nqueue;
	m->msgsize = sizeof(Message);
	m->requestqueue = ROUNDUP(sizeof(Ospreymap), Align);
	m->replyqueue = m->requestqueue + sizeof(Queue);
	m->sem = ROUNDUP(m->replyqueue + sizeof(Queue), Align);
	m->nsem = Nsem;
	m->request = ROUNDUP(m->sem + Nsem*sizeof(Sem), Align);
	m->reply = m->request + Nqueue*sizeof(Message);
	m->data = ROUNDUP(m->reply + Nqueue*sizeof(Message), Align);
	m->datalen = Ndata;
	m->pktbuf = ROUNDUP(m->data + Ndata, Align);
	m->npktbuf = Npktbuf;
	m->pktbufsize = Pktbufsize;
	m->selected = ~0ULL;
	p->map = m;
	for(i = 0; i < Nsem; i++)
		seminit((Sem*)(base + m->sem) + i, 0);

	rq = (Queue*)(base + m->requestqueue);
	pq = (Queue*)(base + m->replyqueue);
	rm = (Message*)(base + m->request);
	pm = (Message*)(base + m->reply);
	lockall();
	pktqinit(&p->pktq, p->pktp, Npkt);
	if(processinit(&p->process, id, budget, period, deadline,
		rq, pq, rm, pm, Nqueue, p->name, Nname) < 0){
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

int
ospreyrequestfull(Ospreyproc *p)
{
	if(p == nil || p->used == 0)
		return 1;
	return queuefull(p->process.requests);
}

int
ospreyreplyready(Ospreyproc *p)
{
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
	if(p->map != nil)
		memset(p->map, 0, slicesize);
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
		if(q == nil || q->core != core || q->state != ProcessRunnable)
			continue;
		containerrefill(&q->container, now);
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
 * Bounded network accounting.  Nothing charges these yet from a packet
 * path; the caps and the counters are here so that the path added later
 * has something to charge.
 */
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
	}

	/*
	 * Everything else needs the kernel: file, process, IPC and network
	 * requests are served by ospreykernop() in the device, which is the
	 * only side of the adapter that may touch a Chan.  What it will not
	 * answer goes to the container's server, if it has one, and is
	 * answered from outside the kernel altogether.
	 */
	rep->status = ospreykernop((Ospreyproc*)p, req->message.op,
		&req->message.arg[2], &rep->message.arg[2]);
	if(rep->status == ReplyError && forward((Ospreyproc*)p, req) == 0)
		return 1;	/* answered elsewhere */
	return 0;
}

/*
 * Serve one request from whichever container has one.  A container that
 * answers for others is passed over: what is on its ring is there for the
 * process serving it, and the kernel answering it first would take the
 * work away from exactly the service this exists to allow.
 */
int
ospreyservice(uvlong now)
{
	int i;

	ready();
	runtime.now = now;
	for(i = 0; i < Nproc; i++){
		if(procs[i].used == 0 || procs[i].serving)
			continue;
		if(runtimeserve(&runtime, &procs[i].process, dispatch, nil) > 0)
			return 1;
	}
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

/* move a request to the server's ring, keeping where it came from */
static int
forward(Ospreyproc *p, Request *req)
{
	Ospreyproc *s;
	Message m;

	if(p == nil || (s = p->server) == nil || s->used == 0)
		return -1;
	m = req->message;
	m.container = p->process.id;
	m.sequence = req->sequence;
	if(queuefull(s->process.requests))
		return -1;
	return queueput(s->process.requests, &m);
}

/*
 * Take what a server has answered and give it to whoever asked.  A
 * container that serves others should not also be asking, since its
 * reply ring is where its answers go.
 */
int
ospreyroute(Ospreyproc *s)
{
	Ospreyproc *p;
	Message m;
	int n;

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
	if(p == nil || p->used == 0 || p->serving)
		return -1;
	ready();
	runtime.now = now;
	return runtimeserve(&runtime, &p->process, dispatch, nil);
}

static Sem*
semof(Ospreyproc *p, ulong i)
{
	if(p == nil || p->used == 0 || p->map == nil || i >= p->map->nsem)
		return nil;
	return (Sem*)((uchar*)p->map + p->map->sem) + i;
}

/*
 * A packet for this container: charge it, and keep the block whole.  A
 * container over its network caps, or with no room, refuses it, and the
 * caller frees the block as it would have anyway.
 */
int
ospreypktput(Ospreyproc *p, void *block, ulong len)
{
	Pkt *k;

	if(p == nil || p->used == 0 || block == nil)
		return -1;
	if(pktqfull(&p->pktq))
		return -1;
	if(netcharge(&p->process.container, len, 1) < 0)
		return -1;
	k = &p->pkt[p->pktq.put % Npkt];
	k->block = block;
	k->len = len;
	k->container = &p->process.container;
	if(pktqput(&p->pktq, k) < 0){
		netrelease(&p->process.container, len, 1);
		return -1;
	}
	return 0;
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
			if(o[i].obj > 1)
				return -1;
			a[i].q = o[i].obj == 0 ? p->process.requests
					: p->process.replies;
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

int
ospreyrequestready(Ospreyproc *p)
{
	if(p == nil || p->used == 0)
		return 0;
	return !queueempty(p->process.requests);
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
	ulong i, n;

	ready();
	p = buf;
	e = buf + nbuf;
	p = seprint(p, e, "now %llud hz %llud cores %lud procs %lud"
		" arena %lud slice %lud data %lud\n",
		now, hz, (ulong)Ncore, (ulong)Nproc,
		slicesize*Nproc, slicesize, (ulong)Ndata);
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
			" requests %llud replies %llud"
			" slice %llud data %llud pid %d\n",
			q->id, q->core, statename(q->state),
			q->container.budget, q->container.used,
			q->container.period, q->task.deadline,
			q->container.besteffort, q->container.periods,
			q->container.strict ? "strict" : "besteffort",
			q->container.memused, q->container.memory,
			q->container.netbytes, q->container.netmax,
			queuecount(q->requests), queuecount(q->replies),
			procs[i].slice, ospreydataoffset(&procs[i]),
			procs[i].pid);
		/* the semaphores, and the container's private names */
		p = seprint(p, e, "packets %llud direct %lud copied %lud held %lud\n",
			q->id, ospreypktdirect(&procs[i]),
			ospreypktcopied(&procs[i]), pktqcount(&procs[i].pktq));
		p = seprint(p, e, "sem %llud", q->id);
		ospreylocksem();
		for(n = 0; n < Nsem; n++){
			Sem *sm = (Sem*)((uchar*)procs[i].map
				+ procs[i].map->sem) + n;
			p = seprint(p, e, " %llud/%llud/%llud",
				sm->count, sm->given, sm->taken);
		}
		ospreyunlocksem();
		p = seprint(p, e, "\n");
		for(n = 0; n < q->ns.n; n++)
			p = seprint(p, e, "name %llud %s %s\n", q->id,
				q->ns.name[n].local, q->ns.name[n].global);
	}
	return p - buf;
}
