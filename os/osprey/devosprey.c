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

#include	"osprey.h"

enum {
	Qdir,
	Qctl,
	Qstatus,
	Qreply,
	Qarena,

	Statuslen	= 8*1024,	/* every core and container line */
	Nfd		= 16,		/* chans a container may hold open */
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
};

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
static uchar *ospreybase;		/* the shared arena */
/* SG_PHYSICAL is a value of the SG_TYPE field, not a flag beside it */
static Physseg ospreyseg = { SG_PHYSICAL, "osprey", 0, 0 };
static Chan *ospreyfd[16][Nfd];		/* per container, indexed as procs are */
static Proc *ospreyprocs[16];		/* the process bound to each container */
static Rendez ospreyservrend[16];	/* wakes a container's service process */
static int ospreyserving[16];		/* a service process is running for it */
static Pgrp *ospreypgrp[16];		/* the namespace it is to run in */

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

static int
ospreyhaswork(void *a)
{
	Ospreyproc *p = a;

	return ospreyindex(p) < 0 || ospreyrequestready(p);
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
	int x;

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
		poperror();
		qunlock(&ospreylock);
		ospreywakeup();
		if(ospreyindex(p) < 0)
			break;
		sleep(&ospreyservrend[x], ospreyhaswork, p);
	}
	poperror();
done:
	if((x = ospreyindex(p)) >= 0)
		ospreyserving[x] = 0;
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
	 * Wake the service process of any container that has a request
	 * waiting.  A process that submitted through the mapped ring never
	 * entered the kernel, so the clock is what notices.
	 */
	for(i = 0; i < nelem(ospreyservrend); i++)
		if(ospreyserving[i])
			wakeup(&ospreyservrend[i]);

	/*
	 * Hold a throttled container's process back until its period
	 * refills.  A budget is a reservation rather than a hard stop: the
	 * process drops to the lowest fixed priority, so it runs only when
	 * nothing within its budget wants the core.
	 */
	for(i = 0; i < nelem(ospreyprocs); i++){
		if((q = ospreyprocs[i]) == nil || (p = q->osprey) == nil)
			continue;
		if(ospreythrottled(p)){
			if(q->fixedpri == 0){
				procpriority(q, 0, 1);
				if(q == m->proc)
					q->delaysched++;
			}
		} else if(q->fixedpri)
			procpriority(q, PriNormal, 0);
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
	}
}

static void
ospreyinit(void)
{
	uvlong size;

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
	ospreyseg.pa = PADDR(ospreybase);
	ospreyseg.size = size;
	/* published once; a second driver reset keeps the same span */
	addphysseg(&ospreyseg);

	if(ospreyncore() > nelem(ospreycorelock)){
		print("osprey: %d cores but %d locks\n",
			ospreyncore(), (int)nelem(ospreycorelock));
		return;
	}
	fastticks(&ospreyhz);
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
/* let go of a container's service process */
static void
ospreyputserver(Ospreyproc *p)
{
	int x;

	if((x = ospreyindex(p)) < 0 || x >= nelem(ospreyservrend))
		return;
	wakeup(&ospreyservrend[x]);
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
ospreyclose(Chan*)
{
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
	char *nm;
	uvlong arg[Ospreynarg];
	int i, op, x;

	if((ulong)c->qid.path == Qarena)
		return ospreyarenaio(a, n, offset, 1);
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
		}
		ospreyreset();
		ospreywakeup();
		break;

	case CMcreate:
		if(ospreycreate(strtoull(cb->f[1], nil, 0),
			strtoull(cb->f[2], nil, 0),
			strtoull(cb->f[3], nil, 0),
			strtoull(cb->f[4], nil, 0)) == nil)
			error(Enodev);
		break;

	case CMattach:
		p = ospreyproc(cb->f[1]);
		if(ospreyattach(p, strtoul(cb->f[2], nil, 0), ospreynow()) < 0)
			error(Ebadarg);
		break;

	case CMdetach:
		if(ospreydetach(ospreyproc(cb->f[1])) < 0)
			error(Ebadarg);
		break;

	case CMexit:
		/* the chans first: cclose can sleep, and exit takes locks */
		p = ospreyproc(cb->f[1]);
		ospreyclosefds(p);
		ospreyputproc(p);
		ospreyputserver(p);
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
		p = ospreyproc(cb->f[1]);
		if(ospreylimit(p, strtoul(cb->f[2], nil, 0),
			strtoul(cb->f[3], nil, 0),
			strtoul(cb->f[4], nil, 0)) < 0)
			error(Ebadarg);
		break;

	case CMsubmit:
		if(cb->nf < 3 || cb->nf > 3 + Ospreynarg)
			error(Ecmdargs);
		p = ospreyproc(cb->f[1]);
		if((op = ospreyop(cb->f[2])) < 0)
			error(Ebadarg);
		for(i = 0; i < Ospreynarg; i++)
			arg[i] = 3 + i < cb->nf ?
				strtoull(cb->f[3+i], nil, 0) : 0;
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
			p = ospreyproc(cb->f[1]);
		}
		if(ospreysubmit(p, op, arg) < 0)
			error(Eio);
		if((x = ospreyindex(p)) >= 0 && x < nelem(ospreyservrend))
			wakeup(&ospreyservrend[x]);
		ospreywakeup();
		break;

	case CMservice:
		if(cb->nf > 2)
			error(Ecmdargs);
		i = cb->nf == 2 ? atoi(cb->f[1]) : 1;
		while(i-- > 0)
			if(ospreyservice(ospreynow()) <= 0)
				break;
		ospreywakeup();
		break;

	case CMserve:
		/*
		 * Give the container a service process of its own, in this
		 * process's namespace.  From then on nothing has to write
		 * service for its requests to be answered.
		 */
		p = ospreyproc(cb->f[1]);
		if((x = ospreyindex(p)) < 0 || x >= nelem(ospreyserving))
			error(Ebadarg);
		if(ospreyserving[x])
			break;
		ospreyserving[x] = 1;
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
		p = ospreyproc(cb->f[1]);
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
		if(ospreyprocs[x] != nil && ospreyprocs[x] != q)
			ospreyprocs[x]->osprey = nil;
		ospreyprocs[x] = q;
		q->osprey = p;
		ospreysetpid(p, i);
		break;

	case CMunbindproc:
		p = ospreyproc(cb->f[1]);
		if((x = ospreyindex(p)) < 0 || x >= nelem(ospreyprocs))
			error(Ebadarg);
		if((q = ospreyprocs[x]) != nil){
			if(q->fixedpri)
				procpriority(q, PriNormal, 0);
			q->osprey = nil;
			ospreyprocs[x] = nil;
		}
		ospreysetpid(p, 0);
		break;

	case CMmigrate:
		p = ospreyproc(cb->f[1]);
		if(ospreymigrate(p, strtoul(cb->f[2], nil, 0), ospreynow()) < 0)
			error(Ebadarg);
		break;

	case CMnetcharge:
		p = ospreyproc(cb->f[1]);
		if(ospreynetcharge(p, strtoul(cb->f[2], nil, 0),
			strtoul(cb->f[3], nil, 0)) < 0)
			error(Enomem);
		break;

	case CMnetfree:
		p = ospreyproc(cb->f[1]);
		ospreynetrelease(p, strtoul(cb->f[2], nil, 0),
			strtoul(cb->f[3], nil, 0));
		break;

	case CMcheckpoint:
		if(ospreycheckpoint(ospreyproc(cb->f[1])) < 0)
			error(Ebadarg);
		break;

	case CMrestore:
		if(ospreyrestore(ospreyproc(cb->f[1])) < 0)
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
		p = ospreyproc(cb->f[1]);
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
			p = ospreyproc(cb->f[1]);
		}
		break;

	case CMbind:
		p = ospreyproc(cb->f[1]);
		if(ospreybind(p, cb->f[2], cb->f[3]) < 0)
			error(Ebadarg);
		break;

	case CMunbind:
		p = ospreyproc(cb->f[1]);
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
