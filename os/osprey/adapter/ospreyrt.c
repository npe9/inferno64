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
 * rather than to allocate them, and the kernel side serialises every
 * entry point.
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
};

struct Ospreyproc {
	Process	process;
	int	used;
	uvlong	sequence;	/* request numbering, kept out of Task */
	Message	request[Nqueue];
	Message	reply[Nqueue];
	Name	name[Nname];
	char	local[Nname][KNAMELEN];
	char	global[Nname][KNAMELEN];
};

static Runtime runtime;
static Core cores[Ncore];
static Ospreyproc procs[Nproc];
static Process *plist[Nproc];
static int started;

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

void
ospreyreset(void)
{
	ulong i;

	memset(procs, 0, sizeof procs);
	memset(cores, 0, sizeof cores);
	memset(plist, 0, sizeof plist);
	for(i = 0; i < Ncore; i++)
		coreinit(&cores[i], i);
	runtimeinit(&runtime, cores, Ncore, plist, Nproc);
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
	int i;

	ready();
	if(id == 0 || ospreylookup(id) != nil)
		return nil;
	for(i = 0; i < Nproc; i++)
		if(procs[i].used == 0)
			break;
	if(i == Nproc)
		return nil;

	p = &procs[i];
	memset(p, 0, sizeof *p);
	for(i = 0; i < Nname; i++){
		p->name[i].local = p->local[i];
		p->name[i].global = p->global[i];
		p->local[i][0] = '\0';
		p->global[i][0] = '\0';
	}
	if(processinit(&p->process, id, budget, period, deadline,
		p->request, p->reply, Nqueue, p->name, Nname) < 0)
		return nil;
	p->used = 1;
	for(i = 0; i < Nproc; i++)
		if(plist[i] == nil){
			plist[i] = &p->process;
			break;
		}
	return p;
}

int
ospreyattach(Ospreyproc *p, ulong core, uvlong now)
{
	if(p == nil || p->used == 0)
		return -1;
	runtime.now = now;
	return runtimeattach(&runtime, &p->process, core);
}

int
ospreydetach(Ospreyproc *p)
{
	if(p == nil || p->used == 0)
		return -1;
	return runtimedetach(&runtime, &p->process);
}

int
ospreyexit(Ospreyproc *p)
{
	int i;

	if(p == nil || p->used == 0)
		return -1;
	runtimeexit(&runtime, &p->process);
	for(i = 0; i < Nproc; i++)
		if(plist[i] == &p->process)
			plist[i] = nil;
	p->used = 0;
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
	ready();
	return taskid(runtimenext(&runtime, core, now));
}

int
ospreycharge(ulong core, uvlong amount, uvlong now)
{
	ready();
	if(core >= Ncore)
		return -1;
	return corecharge(&cores[core], amount, now);
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

int
ospreybalance(uvlong now)
{
	ready();
	return runtimebalance(&runtime, now);
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
		rep->message.arg[2] = queuecount(&p->requests);
		rep->message.arg[3] = queuecount(&p->replies);
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
	rep->status = ReplyError;
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
	p = seprint(p, e, "now %llud hz %llud cores %lud procs %lud\n",
		now, hz, (ulong)Ncore, (ulong)Nproc);
	for(i = 0; i < Ncore; i++){
		for(n = 0, t = cores[i].runq; t != nil; t = t->next)
			n++;
		if(n == 0 && cores[i].cycles == 0)
			continue;
		p = seprint(p, e, "core %lud runq %lud cycles %llud switches %llud"
			" current %llud order",
			i, n, cores[i].cycles, cores[i].contextswitches,
			taskid(cores[i].current));
		for(t = cores[i].runq; t != nil; t = t->next)
			p = seprint(p, e, " %llud", taskid(t));
		p = seprint(p, e, "\n");
	}
	for(i = 0; i < Nproc; i++){
		if(procs[i].used == 0)
			continue;
		q = &procs[i].process;
		p = seprint(p, e, "proc %llud core %lud %s"
			" budget %llud used %llud period %llud deadline %llud"
			" mem %lud of %lud net %lud of %lud"
			" requests %llud replies %llud\n",
			q->id, q->core, statename(q->state),
			q->container.budget, q->container.used,
			q->container.period, q->task.deadline,
			q->container.memused, q->container.memory,
			q->container.netbytes, q->container.netmax,
			queuecount(&q->requests), queuecount(&q->replies));
	}
	return p - buf;
}
