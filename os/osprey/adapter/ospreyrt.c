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

enum {
	Nproc		= 16,	/* resource containers this adapter can hold */
	Ncore		= 8,	/* independent per-core run queues */
	Nqueue		= 16,	/* messages per request and reply ring */
	Nname		= 8,	/* private namespace entries per container */
	Ndata		= 4096,	/* names and i/o buffers per container */
	Align		= 64,
};

struct Ospreyproc {
	Process	process;
	int	used;
	int	saved;		/* snap holds a checkpoint */
	Snap	snap;
	uvlong	sequence;	/* request numbering, kept out of Task */
	int	pid;		/* the process billed to this container, or 0 */
	uvlong	slice;		/* byte offset of this container in the arena */
	Ospreymap *map;		/* the slice itself */
	Name	name[Nname];
};

static Runtime runtime;
static Core cores[Ncore];
static Ospreyproc procs[Nproc];
static Process *plist[Nproc];
static int started;

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

static void
sizes(void)
{
	if(slicesize != 0)
		return;
	slicesize = ROUNDUP(sizeof(Ospreymap), Align)
		+ ROUNDUP(2*sizeof(Queue), Align)
		+ ROUNDUP(2*Nqueue*sizeof(Message), Align)
		+ Ndata;
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
	m->request = ROUNDUP(m->replyqueue + sizeof(Queue), Align);
	m->reply = m->request + Nqueue*sizeof(Message);
	m->data = ROUNDUP(m->reply + Nqueue*sizeof(Message), Align);
	m->datalen = slicesize - m->data;
	p->map = m;

	rq = (Queue*)(base + m->requestqueue);
	pq = (Queue*)(base + m->replyqueue);
	rm = (Message*)(base + m->request);
	pm = (Message*)(base + m->reply);
	lockall();
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
	 * Bill the container of the process the core is actually running,
	 * when one is bound to it.  Without a process behind it a container
	 * can only be billed for the core's own idea of what it is running.
	 */
	t = running != nil && running->used ? &running->process.task : c->current;
	if(t != nil && t->container != nil
	&& containercharge(t->container, amount, now) < 0){
		coredequeue(c, t);
		throttled++;
	}
	for(i = 0; i < Nproc; i++){
		q = plist[i];
		if(q == nil || q->core != core || q->state != ProcessRunnable)
			continue;
		if(q->task.runnable)
			continue;
		containerrefill(&q->container, now);
		if(budgetok(&q->task, amount))
			coreenqueue(c, &q->task, now);
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
	 * only side of the adapter that may touch a Chan.
	 */
	rep->status = ospreykernop((Ospreyproc*)p, req->message.op,
		&req->message.arg[2], &rep->message.arg[2]);
	return 0;
}

int
ospreyservice(uvlong now)
{
	ready();
	runtime.now = now;
	return runtimeservice(&runtime, dispatch, nil);
}

int
ospreyservicep(Ospreyproc *p, uvlong now)
{
	if(p == nil || p->used == 0)
		return -1;
	ready();
	runtime.now = now;
	return runtimeserve(&runtime, &p->process, dispatch, nil);
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
			" mem %lud of %lud net %lud of %lud"
			" requests %llud replies %llud"
			" slice %llud data %llud pid %d\n",
			q->id, q->core, statename(q->state),
			q->container.budget, q->container.used,
			q->container.period, q->task.deadline,
			q->container.memused, q->container.memory,
			q->container.netbytes, q->container.netmax,
			queuecount(q->requests), queuecount(q->replies),
			procs[i].slice, ospreydataoffset(&procs[i]),
			procs[i].pid);
		/* the container's private names, if it has bound any */
		for(n = 0; n < q->ns.n; n++)
			p = seprint(p, e, "name %llud %s %s\n", q->id,
				q->ns.name[n].local, q->ns.name[n].global);
	}
	return p - buf;
}
