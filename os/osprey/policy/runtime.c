#include "runtime.h"

int
runtimeinit(Runtime *r, Core *core, ulong ncore,
	Process **process, ulong nprocess)
{
	if(r == nil || core == nil || ncore == 0)
		return -1;
	r->core = core;
	r->ncore = ncore;
	r->process = process;
	r->nprocess = nprocess;
	r->now = 0;
	return 0;
}

int
runtimeattach(Runtime *r, Process *p, ulong core)
{
	ulong i;
	if(r == nil || p == nil || core >= r->ncore)
		return -1;
	for(i = 0; i < r->ncore; i++)
		coredequeue(&r->core[i], &p->task);
	p->core = core;
	coreenqueue(&r->core[core], &p->task, r->now);
	p->state = ProcessRunnable;
	return 0;
}

int
runtimedetach(Runtime *r, Process *p)
{
	ulong i;
	if(r == nil || p == nil)
		return -1;
	for(i = 0; i < r->ncore; i++)
		coredequeue(&r->core[i], &p->task);
	p->state = ProcessNew;
	return 0;
}

int
runtimeblock(Runtime *r, Process *p)
{
	if(r == nil || p == nil || p->core >= r->ncore)
		return -1;
	coredequeue(&r->core[p->core], &p->task);
	p->state = ProcessBlocked;
	return 0;
}

int
runtimewake(Runtime *r, Process *p, uvlong now)
{
	if(r == nil || p == nil || p->core >= r->ncore ||
		p->state == ProcessExited)
		return -1;
	r->now = now;
	coreenqueue(&r->core[p->core], &p->task, now);
	p->state = ProcessRunnable;
	return 0;
}

int
runtimeexit(Runtime *r, Process *p)
{
	if(r == nil || p == nil || p->core >= r->ncore)
		return -1;
	coredequeue(&r->core[p->core], &p->task);
	p->state = ProcessExited;
	return 0;
}

static ulong
load(Core *c)
{
	ulong n;
	Task *t;
	for(n = 0, t = c->runq; t != nil; n++, t = t->next)
		;
	return n;
}

int
runtimebalance(Runtime *r, uvlong now)
{
	ulong i, from, to, high, low;
	Task *t;
	if(r == nil || r->ncore < 2)
		return 0;
	from = to = 0;
	high = load(&r->core[0]);
	low = high;
	for(i = 1; i < r->ncore; i++){
		if(load(&r->core[i]) > high){
			high = load(&r->core[i]);
			from = i;
		}
		if(load(&r->core[i]) < low){
			low = load(&r->core[i]);
			to = i;
		}
	}
	if(high <= low + 1)
		return 0;
	t = r->core[from].runq;
	if(t == nil)
		return 0;
	coredequeue(&r->core[from], t);
	coreenqueue(&r->core[to], t, now);
	for(i = 0; i < r->nprocess; i++)
		if(r->process != nil && r->process[i] != nil &&
			&r->process[i]->task == t)
			r->process[i]->core = to;
	return 1;
}

Task*
runtimenext(Runtime *r, ulong core, uvlong now)
{
	if(r == nil || core >= r->ncore)
		return nil;
	r->now = now;
	return corenext(&r->core[core]);
}

/* take one request off a process's ring and answer it */
int
runtimeserve(Runtime *r, Process *p, Handler handler, void *arg)
{
	Request req;
	Reply rep;
	int n;

	if(r == nil || p == nil || handler == nil)
		return -1;
	if(processnext(p, &req) < 0)
		return 0;
	rep.message = req.message;
	rep.sequence = req.sequence;
	rep.status = ReplyPending;
	rep.flags = 0;
	n = handler(p, &req, &rep, arg);
	if(n > 0)
		return 1;	/* the handler will answer it elsewhere */
	if(n < 0)
		rep.status = ReplyError;
	else if(rep.status == ReplyPending)
		rep.status = ReplyDone;
	processreply(p, &rep);
	return 1;
}

int
runtimeservice(Runtime *r, Handler handler, void *arg)
{
	ulong i;

	if(r == nil || handler == nil || r->process == nil)
		return -1;
	for(i = 0; i < r->nprocess; i++){
		if(r->process[i] == nil)
			continue;
		if(runtimeserve(r, r->process[i], handler, arg) > 0)
			return 1;
	}
	return 0;
}
