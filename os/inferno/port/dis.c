#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"
#include <isa.h>
#include <interp.h>
#include <kernel.h>
#include "raise.h"

static int debug = 0;

void	vmachine(void*);

struct
{
	Lock	l;
	Prog*	head;
	Prog*	tail;
	Rendez	irend;
	int	nidle;		/* interpreters parked on idlevmq */
	int	nyield;
	int	creating;
	Proc*	idlevmq;	/* interpreters with no program to run */
	Atidle*	idletasks;
	Prog*	ghead;		/* global run queue; see gput() */
	Prog*	gtail;
	int	ngq;
} isched;

/*
 * The global run queue, on Go's shape.
 *
 * A per-P local run queue cannot simply replace the shared one: a Prog
 * that one context queues would be invisible to another, and if that
 * context then blocks, the program never runs.  Go does not split it
 * either -- runqput overflows a bounded local queue into a global one
 * and runqget falls back to the global queue before stealing.  The
 * global queue is not a remnant there; it is what makes the local ones
 * correct.
 *
 * So it is built first, while there is still one P, because it is the
 * only piece of that design that can be exercised before the last one
 * lands.  Runqmax is the local bound.  At its default nothing overflows
 * -- the deepest local queue this workload produces is 2, measured --
 * so this path is inert unless the bound is lowered, and it is lowered
 * on purpose to test it.  That is the point of having it: a mechanism
 * whose default is "never runs" is untested, and the bound is the
 * constant to falsify.
 */
int Runqmax = 256;	/* MULTICORE - local run queue bound, Go's is 256 */
enum { Gqevery = 61 };	/* Go's schedule() uses 61 for the same reason */
int gqtick;
int gqput, gqget;	/* MULTICORE INSTRUMENTATION - temporary */

static void
gput(Prog *p)
{
	lock(&isched.l);
	p->link = nil;
	if(isched.gtail != nil)
		isched.gtail->link = p;
	else
		isched.ghead = p;
	isched.gtail = p;
	isched.ngq++;
	gqput++;
	unlock(&isched.l);
}

static Prog*
gget(void)
{
	Prog *p;

	lock(&isched.l);
	p = isched.ghead;
	if(p != nil){
		isched.ghead = p->link;
		if(isched.ghead == nil)
			isched.gtail = nil;
		isched.ngq--;
		gqget++;
		p->link = nil;
	}
	unlock(&isched.l);
	return p;
}

/* is p on the global queue?  used only by delrunq() */
static int
gdel(Prog *p)
{
	Prog *f, *prev;

	lock(&isched.l);
	prev = nil;
	for(f = isched.ghead; f != nil; f = f->link){
		if(f == p)
			break;
		prev = f;
	}
	if(f == nil){
		unlock(&isched.l);
		return 0;
	}
	if(prev == nil)
		isched.ghead = p->link;
	else
		prev->link = p->link;
	if(p == isched.gtail)
		isched.gtail = prev;
	isched.ngq--;
	unlock(&isched.l);
	return 1;
}

int	bflag;
int	cflag;
uvlong	gcbusy;
uvlong	gcidle;
uvlong	gcidlepass;
uvlong	gcpartial;
int keepbroken = 1;
int nvm;	/* MULTICORE INSTRUMENTATION - temporary: VM holders */
int maxnvm;
/*
 * MULTICORE INSTRUMENTATION - temporary.  nvm above answers "how many
 * processes hold the VM lock", and with one global vmlock that is 1 by
 * construction, which says nothing about whether there is parallelism
 * to win.  maxnrunq answers the question that actually decides whether
 * Phase 1b and Phase 5 are worth their risk: how many Dis programs are
 * READY at the same moment.  A high-water mark of 1 on this workload
 * would mean a per-executor register file buys nothing here, and the
 * measurement is much cheaper than the work.
 *
 * Measured by walking curP->runhd at the scheduler's own pick rather
 * than by a counter incremented in addrun().  The queue is inserted
 * into and removed from in five places, not just addrun()/delrun()/
 * delrunq() -- delprog() unlinks a head directly, and the Prog that
 * takes the VM lock is pushed on the front -- so a maintained counter
 * would drift.  The walk is once per quantum, not once per queue
 * operation, and is capped so its cost is bounded whatever the queue
 * does.  It runs under the VM lock, which is what serialises the queue.
 */
enum { Runqcap = 64 };
int maxnrunq;
int nrunqmismatch;	/* MULTICORE INSTRUMENTATION - temporary */
int maxvmq;
int vmqbad;
uvlong vmpasses;	/* MULTICORE INSTRUMENTATION - temporary */
uvlong vmblocked;

/*
 * Dis executes one program at a time, system-wide.
 *
 * This is not a scaling choice, it is what the interpreter is.  The
 * virtual machine's register set is the single global REG R
 * (libinterp/xec.c:11); irestore() loads it from a Prog and isave()
 * stores it back (libinterp/xec.c:2280); and every JIT backend
 * compiles the absolute address of that one object into the code it
 * emits -- comp-amd64.c alone has eight con((uintptr)&R, RTMP).  Two
 * processors interpreting at once share one register file.
 *
 * The isched.idle/vmq/idlevmq handshake this replaces was meant to be
 * that exclusion and was not.  Instrumenting vmachine()'s xec() call
 * with a counter showed ten kernel processes inside xec() at once on a
 * four processor boot; "movp: bad sv", "movp: bad dv-freed" and the
 * decref underflows all came from there.
 *
 * A QLock, not a Lock: the holder blocks in Dis system calls, and
 * qunlock() hands the lock to the head of its own FIFO queue rather
 * than dropping it, which is what makes iyield() a real yield.
 *
 * vmheld is per-process and makes both operations idempotent.  That is
 * what lets this survive the error path: propex()/nexterror() longjmps
 * out of xec() straight back to vmachine()'s waserror() block, over
 * any unlock in between.  An earlier attempt at a single Dis lock was
 * reverted for exactly that reason -- the history is in the long
 * comment in emu/port/dis.c's vmachine() -- and the flag is the answer
 * to it: the recovery path calls vmrelease() and it does the right
 * thing whether or not the lock survived the jump.
 */
static QLock vmlock;

static void
vmacquire(void)
{
	if(up->vmheld == 0){
		qlock(&vmlock);
		up->vmheld = 1;
		{	/* MULTICORE INSTRUMENTATION - temporary */
			int n = ainc(&nvm);
			if(n > maxnvm){
				maxnvm = n;
				print("nvm: %d hold the vm, cpu%d %s\n",
					n, m->machno, up->text);
			}
		}
	}
}

/*
 * An interpreter with nothing to run parks itself on isched.idlevmq and
 * gives up the processor; this is what restarts one.  It is not the VM
 * lock -- a woken interpreter still has to take that -- it only says
 * "there is work now".
 *
 * A Rendez holds exactly one sleeper, so the idle interpreters cannot
 * simply sleep() on a shared one; doing that produced "double sleep
 * called from vmachine+0x22b" the moment a second interpreter went
 * idle.  Parking with state Queueing and restarting with ready() is
 * what the code this replaced already did, and it takes any number.
 */
static void
wakeidle(void)
{
	Proc *p;

	lock(&isched.l);
	p = isched.idlevmq;
	if(p != nil){
		isched.idlevmq = p->vmnext;
		p->vmnext = nil;
		isched.nidle--;
	}
	unlock(&isched.l);
	if(p != nil)
		ready(p);
}

static void
vmrelease(void)
{
	if(up->vmheld){
		adec(&nvm);	/* MULTICORE INSTRUMENTATION - temporary */
		up->vmheld = 0;
		qunlock(&vmlock);
	}
}
static Prog*	proghash[64];

/*
 * delprog() release()s the interpreter token while it closes p's
 * pgrp/fgrp/egrp/sigs, but does not unlink p from proghash[]/isched
 * until it reacquires -- so p is still reachable by pid through
 * progpid() during that window, while o->pgrp etc may already be
 * freed.  disracepid names the pid currently inside that window (-1
 * when none is); devprog.c's progpid()-based read paths report a hit
 * if they find it, and delprog itself reports whether the GC was
 * blocked from running (via gchalt/gchalted, see include/interp.h and
 * libinterp/gc.c) during the same window.  Diagnostic only, capped;
 * see doc/inferno-ports.ms.
 */
int	disracepid = -1;
int	disracehits;
int	disracewindows;	/* delprog windows opened, total */
int	disraceoverlaps;	/* windows opened while another was already open */
extern ulong gchalted;


static Progs*	delgrp(Prog*);
static void	addgrp(Prog*, Prog*);
void	printgrp(Prog*, char*);

static Prog**
pidlook(int pid)
{
	ulong h;
	Prog **l;

	h = (ulong)pid % nelem(proghash);
	for(l = &proghash[h]; *l != nil && (*l)->pid != pid; l = &(*l)->pidlink)
		;
	return l;
}

int
tready(void *a)
{
	USED(a);
	return curP->runhd != nil || isched.ghead != nil;
}

Prog*
progpid(int pid)
{
	return *pidlook(pid);
}

Prog*
progn(int n)
{
	Prog *p;

	for(p = isched.head; p && n--; p = p->next)
		;
	return p;
}

int
nprog(void)
{
	int n;
	Prog *p;

	n = 0;
	for(p = isched.head; p; p = p->next)
		n++;
	return n;
}

static void
accountant(void)
{
	Prog *p;

	p = curP->runhd;
	if(p != nil)
		p->ticks++;
}

static void
execatidle(void)
{
	int done;

	if(tready(nil))
		return;

	gcidle++;
	up->type = IdleGC;
	up->iprog = nil;
	addrun(up->prog);

	done = gccolor+3;
	while(gccolor < done && gcruns()) {
		if(curP->runhd != curP->runtl) {
			gcpartial++;
			break;
		}
		rungc(isched.head);
		gcidlepass++;
		if(((ulong)gcidlepass&0xFF) == 0)
			sched();
	}

	up->type = Interp;
	delrunq(up->prog);
}

Prog*
newprog(Prog *p, Modlink *m)
{
	Heap *h;
	Prog *n, **ph;
	Osenv *on, *op;
	static int pidnum;

	if(p != nil){
		if(p->group != nil)
			p->flags |= p->group->flags & Pkilled;
		if(p->kill != nil)
			error(p->kill);
		if(p->flags & Pkilled)
			error("");
	}
	n = malloc(sizeof(Prog)+sizeof(Osenv));
	if(n == 0){
		if(p == nil)
			panic("no memory");
		else
			error(exNomem);
	}

	n->pid = ++pidnum;
	if(n->pid <= 0)
		panic("no pids");
	n->group = nil;

	if(isched.tail != nil) {
		n->prev = isched.tail;
		isched.tail->next = n;
	}
	else {
		isched.head = n;
		n->prev = nil;
	}
	isched.tail = n;

	ph = pidlook(n->pid);
	if(*ph != nil)
		panic("dup pid");
	n->pidlink = nil;
	*ph = n;

	n->osenv = (Osenv*)((uchar*)n + sizeof(Prog));
	n->xec = xec;
	n->quanta = PQUANTA;
	n->flags = 0;
	n->exval = H;

	h = D2H(m);
	h->ref++;
	Setmark(h);
	n->reg.M = m;
	n->reg.MP = m->MP;
	if(m->MP != H)
		Setmark(D2H(m->MP));
	addrun(n);

	if(p == nil){
		newgrp(n);
		return n;
	}

	addgrp(n, p);
	n->flags = p->flags;
	if(p->flags & Prestrict)
		n->flags |= Prestricted;
	memmove(n->osenv, p->osenv, sizeof(Osenv));
	op = p->osenv;
	on = n->osenv;
	on->waitq = op->childq;
	on->childq = nil;
	on->debug = nil;
	incref(on->pgrp);
	incref(on->fgrp);
	if(on->egrp != nil)
		incref(on->egrp);
	if(on->sigs != nil)
		incref(on->sigs);
	on->user = nil;
	kstrdup(&on->user, op->user);
	on->errstr = on->errbuf0;
	on->syserrstr = on->errbuf1;

	return n;
}

void
delprog(Prog *p, char *msg)
{
	Osenv *o;
	Prog **ph;

	if(p->exstr != nil)
		DBG("delprog p->pid %d msg %s p->exstr %s\n", p->pid, msg, p->exstr);
	else
		DBG("delprog p->pid %d msg --%s--\n", p->pid, msg);
	tellsomeone(p, msg);	/* call before being removed from prog list */

	o = p->osenv;
	{
		ulong gcbefore;

		gcbefore = gchalted;
		disracewindows++;
		if(disracepid != -1) {
			disraceoverlaps++;
			if(disraceoverlaps <= 8)
				print("delprog: pid %d opening window while pid %d's was still open (overlap %d)\n",
					p->pid, disracepid, disraceoverlaps);
		}
		disracepid = p->pid;
		release();
		closepgrp(o->pgrp);
		closefgrp(o->fgrp);
		closeegrp(o->egrp);
		closesigs(o->sigs);
		acquire();
		disracepid = -1;
		if(disracehits < 8 && gchalted != gcbefore) {
			disracehits++;
			print("delprog: pid %d gchalted %lud->%lud during close window\n",
				p->pid, gcbefore, gchalted);
		}
	}

	delgrp(p);

	if(p->prev)
		p->prev->next = p->next;
	else
		isched.head = p->next;

	if(p->next)
		p->next->prev = p->prev;
	else
		isched.tail = p->prev;

	ph = pidlook(p->pid);
	if(*ph == nil)
		panic("lost pid");
	*ph = p->pidlink;

	/*
	 * This removed p only when it was the head of the run queue, so a
	 * Prog deleted from anywhere else stayed linked into a list whose
	 * every other reader -- vmachine()'s own pick, and disdump()'s
	 * walk -- then dereferences it after free().  delrunq() already
	 * removes from anywhere in the list and returns harmlessly when p
	 * is not on it, which is exactly this job.
	 *
	 * Found while looking for unguarded dereferences in disdump()
	 * rather than from a capture: the faults this hunt has in hand
	 * come through the isched.head walk, and that list is unlinked
	 * correctly here.  So this is a real use-after-free with no
	 * observed instance, fixed on inspection.
	 */
	delrunq(p);
	/*
	 * vmachine()'s waserror() loop clears curprog because a Dis
	 * exception leaves xec() by longjmp and "a later Prog allocated at
	 * the same address would be handed the wrong register file" -- its
	 * own words.  That covers non-local exits from the interpreter and
	 * not this: a Prog can reach delprog() while curprog still names
	 * it, and then the name outlives the object with nothing to clear
	 * it.  Observed, not deduced: an assertion in rungc() that
	 * dereferenced curprog printed state 0xdeadbeef, which is the
	 * value written two lines below.
	 *
	 * progreg() compares curprog by pointer, so the damage is exactly
	 * what that comment describes -- once the allocator hands this
	 * address to a new Prog, progreg() gives out curR for a program
	 * whose live registers are somewhere else.
	 */
	if(p == curP->curprog)
		curP->curprog = nil;
	p->state = 0xdeadbeef;
	free(o->user);
	free(p->killstr);
	free(p->exstr);
	free(p);
}

void
renameproguser(char *old, char *new)
{
	Prog *p;
	Osenv *o;

	acquire();
	for(p = isched.head; p; p = p->next){
		o = p->osenv;
		if(o->user != nil && strcmp(o->user, old) == 0)
			kstrdup(&o->user, new);
	}
	release();
}

void
tellsomeone(Prog *p, char *buf)
{
	Osenv *o;
	int ret, woke;

	if(waserror())
		return;
	o = p->osenv;
	woke = 0;
	if(o->childq != nil){
		ret = qproduce(o->childq, buf, strlen(buf));
		if(ret == strlen(buf))
			woke = 1;
		else if(ret != strlen(buf))
			print("tellsomeone childq %d/%lud\n", ret, (ulong)strlen(buf));
	}
	if(o->waitq != nil){
		ret = qproduce(o->waitq, buf, strlen(buf));
		if(ret == strlen(buf))
			woke = 1;
		else
			print("tellsomeone waitq %d/%lud\n", ret, (ulong)strlen(buf));
	}
	poperror();
	/*
	 * On a uniprocessor, qproduce's wakeup only readies the waiter.
	 * Yield so the parent can finish Sys_read/acquire before we
	 * release() in delprog and risk a VM handoff deadlock.
	 */
	if(woke && anyready())
		sched();
}

static void
swiprog(Prog *p)
{
	Proc *q, *eq;
	char c[ERRMAX];

	snprint(c, ERRMAX, "interrupted by swiprog 0x%p\n", getcallerpc(&p));
	/* print("swiprog: %s\n", c); */
	q = proctab(0);
	for(eq = q+conf.nproc; q < eq; q++) {
		if(q->iprog == p) {
			/*	postnote(q, 1, "interrupted by swiprog", NUser); */
			postnote(q, 1, c, NUser);
			/* dumpstack(); */
			return;
		}
	}
	print("swigrog: didn't find proc\n");
}

static Prog*
grpleader(Prog *p)
{
	Progs *g;
	Prog *l;

	g = p->group;
	if(g != nil && (l = g->head) != nil && l->pid == g->id)
		return l;
	return nil;
}

int
exprog(Prog *p, char *exc)
{
	switch(p->state) {
	case Palt:
		altdone(p->reg.s, p, nil, -1);
		break;
	case Psend:
		cqdelp(&p->chan->send, p);
		break;
	case Precv:
		cqdelp(&p->chan->recv, p);
		break;
	case Pready:
		break;
	case Prelease:
		swiprog(p);
		break;
	case Pexiting:
	case Pbroken:
	case Pdebug:
		return 0;
	default:
		panic("exprog - bad state 0x%x\n", p->state);
	}
	if(p->state != Pready && p->state != Prelease)
		addrun(p);
	if(p->kill == nil){
		if(p->killstr == nil){
			p->killstr = malloc(ERRMAX);
			if(p->killstr == nil){
				p->kill = Enomem;
				return 1;
			}
		}
		kstrcpy(p->killstr, exc, ERRMAX);
		p->kill = p->killstr;
	}
	return 1;
}

static void
propex(Prog *p, char *estr)
{
	Prog *f, *nf, *pgl;

	if(!(p->flags & (Ppropagate|Pnotifyleader)) || p->group == nil)
		return;
	if(*estr == 0){
		if((p->flags & Pkilled) == 0)
			return;
		estr = "killed";
	}
	pgl = grpleader(p);
	if(pgl == nil)
		pgl = p;
	if(!(pgl->flags & (Ppropagate|Pnotifyleader)))
		return;	/* exceptions are local; don't propagate */
	for(f = p->group->head; f != nil; f = nf){
		nf = f->grpnext;
		if(f != p && f != pgl){
			if(pgl->flags & Ppropagate)
				exprog(f, estr);
			else{
				f->flags &= ~(Ppropagate|Pnotifyleader);	/* prevent recursion */
				killprog(f, "killed");
			}
		}
	}
	if(p != pgl)
		exprog(pgl, estr);
}

int
killprog(Prog *p, char *cause)
{
	Osenv *env;
	char msg[ERRMAX+2*KNAMELEN];

	if(p == curP->runhd) {
		p->kill = "";
		p->flags |= Pkilled;
		p->state = Pexiting;
		return 0;
	}

	switch(p->state) {
	case Palt:
		altdone(p->reg.s, p, nil, -1);
		break;
	case Psend:
		cqdelp(&p->chan->send, p);
		break;
	case Precv:
		cqdelp(&p->chan->recv, p);
		break;
	case Pready:
		delrunq(p);
		break;
	case Prelease:
		p->kill = "";
		p->flags |= Pkilled;
		p->state = Pexiting;
		swiprog(p);
		/* No break */
	case Pexiting:
		return 0;
	case Pbroken:
	case Pdebug:
		break;
	default:
		panic("killprog - bad state 0x%x\n", p->state);
	}

	if(p->addrun != nil) {
		p->kill = "";
		p->flags |= Pkilled;
		p->addrun(p);
		p->addrun = nil;
		return 0;
	}

	env = p->osenv;
	if(env->debug != nil) {
		p->state = Pbroken;
		dbgexit(p, 0, cause);
		return 0;
	}

	propex(p, "killed");

	/* KenC LP64: one homogeneous arg per snprint */
	{
		int i;

		i = snprint(msg, sizeof(msg), "%d \"", p->pid);
		i += snprint(msg+i, sizeof(msg)-i, "%s", p->reg.M->m->name);
		i += snprint(msg+i, sizeof(msg)-i, "\":");
		snprint(msg+i, sizeof(msg)-i, "%s", cause);
	}

	p->state = Pexiting;
	gclock();
	destroystack(&p->reg);
	delprog(p, msg);
	gcunlock();

	return 1;
}

void
newgrp(Prog *p)
{
	Progs *pg, *g;

	if(p->group != nil && p->group->id == p->pid)
		return;
	g = malloc(sizeof(*g));
	if(g == nil)
		error(Enomem);
	p->flags &= ~(Ppropagate|Pnotifyleader);
	g->id = p->pid;
	g->flags = 0;
	g->child = nil;
	pg = delgrp(p);
	g->head = g->tail = p;
	p->group = g;
	if(pg != nil){
		g->sib = pg->child;
		pg->child = g;
	}
	g->parent = pg;
}

static void
addgrp(Prog *n, Prog *p)
{
	Progs *g;

	n->group = p->group;
	if((g = n->group) != nil){
		n->grpnext = nil;
		if(g->head != nil){
			n->grpprev = g->tail;
			g->tail->grpnext = n;
		}else{
			n->grpprev = nil;
			g->head = n;
		}
		g->tail = n;
	}
}

static Progs*
delgrp(Prog *p)
{
	Progs *g, *pg, *cg, **l;

	g = p->group;
	if(g == nil)
		return nil;
	if(p->grpprev)
		p->grpprev->grpnext = p->grpnext;
	else
		g->head = p->grpnext;
	if(p->grpnext)
		p->grpnext->grpprev = p->grpprev;
	else
		g->tail = p->grpprev;
	p->grpprev = p->grpnext = nil;
	p->group = nil;

	if(g->head == nil){
		/* move up, giving subgroups of groups with no Progs to their parents */
		do{
			if((pg = g->parent) != nil){
				pg = g->parent;
				for(l = &pg->child; *l != nil && *l != g; l = &(*l)->sib)
					;
				*l = g->sib;
			}
			/* put subgroups in new parent group */
			while((cg = g->child) != nil){
				g->child = cg->sib;
				cg->parent = pg;
				if(pg != nil){
					cg->sib = pg->child;
					pg->child = cg;
				}
			}
			free(g);
		}while((g = pg) != nil && g->head == nil);
	}
	return g;
}

void
printgrp(Prog *p, char *v)
{
	Progs *g;
	Prog *q;

	g = p->group;
	print("%s pid %d grp %d pgrp %d: [pid", v, p->pid, g->id, g->parent!=nil?g->parent->id:0);
	for(q = g->head; q != nil; q = q->grpnext)
		print(" %d", q->pid);
	print(" subgrp");
	for(g = g->child; g != nil; g = g->sib)
		print(" %d", g->id);
	print("]\n");
}

int
killgrp(Prog *p, char *msg)
{
	int i, npid, *pids;
	Prog *f;
	Progs *g;

	/* interpreter has been acquired */
	g = p->group;
	if(g == nil || g->head == nil)
		return 0;
	while(g->flags & Pkilled){
		release();
		acquire();
	}
	npid = 0;
	for(f = g->head; f != nil; f = f->grpnext)
		if(f->group != g)
			panic("killgrp");
		else
			npid++;
	/* use pids not Prog* because state can change during killprog (eg, in delprog) */
	pids = malloc(npid*sizeof(int));
	if(pids == nil)
		error(Enomem);
	npid = 0;
	for(f = g->head; f != nil; f = f->grpnext)
		pids[npid++] = f->pid;
	g->flags |= Pkilled;
	if(waserror()) {
		g->flags &= ~Pkilled;
		free(pids);
		nexterror();
	}
	for(i = 0; i < npid; i++) {
		f = progpid(pids[i]);
		if(f != nil && f != currun())
			killprog(f, msg);
	}
	poperror();
	g->flags &= ~Pkilled;
	free(pids);
	return 1;
}

char	changup[] = "channel hangup";

void
killcomm(Progq **q)
{
	Prog *p;
	Progq *f;

	for (f = *q; f != nil; f = *q) {
		*q = f->next;
		p = f->prog;
		free(f);
		if(p == nil)
			return;
		p->ptr = nil;
		switch(p->state) {
		case Prelease:
			swiprog(p);
			break;
		case Psend:
		case Precv:
			p->kill = changup;
			addrun(p);
			break;
		case Palt:
			altgone(p);
			break;
		}
	}
}

void
addprog(Proc *p)
{
	Prog *n;

	if((n = p->prog) == nil) {
		n = malloc(sizeof(Prog));
		if(n == nil)
			panic("no memory");
		p->prog = n;
	} else
		memset(n, 0, sizeof(Prog));
	n->osenv = p->env;
}

static void
cwakeme(Prog *p)
{
	Osenv *o;

	p->addrun = nil;
	o = p->osenv;
	wakeup(o->rend);
}

static int
cdone(void *vp)
{
	Prog *p = vp;

	return p->addrun == nil || p->kill != nil;
}

void
cblock(Prog *p)
{
	Osenv *o;

	p->addrun = cwakeme;
	o = p->osenv;
	o->rend = &up->sleep;
	release();

	/*
	 * To allow cdone(p) safely after release,
	 * p must be currun before the release.
	 * Exits in the error case with the vm acquired.
	 */
	if(waserror()) {
		acquire();
		p->addrun = nil;
		nexterror();
	}
	sleep(o->rend, cdone, p);
	if (p->kill != nil)
		error(Eintr);
	poperror();
	acquire();
}

void
addrun(Prog *p)
{
	if(p->addrun != 0) {
		p->addrun(p);
		return;
	}
	if(p->state == Pready && p != (Prog *)up->prog)
		panic("addrun of ready prog %8.8p by %8.8zux\n", p, getcallerpc(&p));
	p->state = Pready;
	p->link = nil;
	if(curP->nlocal >= Runqmax){
		gput(p);		/* local queue full; see gput() */
		return;
	}
	if(curP->runhd == nil)
		curP->runhd = p;
	else
		curP->runtl->link = p;

	curP->runtl = p;
	curP->nlocal++;
}

Prog*
delrun(int state)
{
	Prog *p;

	p = curP->runhd;
	p->state = state;
	curP->runhd = p->link;
	if(p->link == nil)
		curP->runtl = nil;
	curP->nlocal--;

	return p;
}

void
delrunq(Prog *p)
{
	Prog *prev, *f;

	prev = nil;
	for(f = curP->runhd; f; f = f->link) {
		if(f == p)
			break;
		prev = f;
	}
	if(f == nil){
		gdel(p);	/* it may be on the global queue instead */
		return;
	}
	if(prev == nil)
		curP->runhd = p->link;
	else
		prev->link = p->link;
	if(p == curP->runtl)
		curP->runtl = prev;
	curP->nlocal--;
}

Prog*
delruntail(int state)
{
	Prog *p;

	p = curP->runtl;
	delrunq(curP->runtl);
	p->state = state;
	return p;
}

Prog*
currun(void)
{
	return curP->runhd;
}

Prog*
schedmod(Module *m)
{
	Heap *h;
	Type *t;
	Prog *p;
	Modlink *ml;
	Frame *f, *fp;

	ml = mklinkmod(m, 0);

	if(m->origmp != H && m->ntype > 0) {
		t = m->type[0];
		h = nheap(t->size);
		h->t = t;
		t->ref++;
		ml->MP = H2D(uchar*, h);
		if(ml->MP != H && (uintptr)ml->MP < 0x1000)
			print("schedmod: bad ml->MP %#p right after H2D, h %#p ml %#p\n",
				ml->MP, h, ml);
		newmp(ml->MP, m->origmp, t);
	}

	p = newprog(nil, ml);
	h = D2H(ml);
	h->ref--;
	p->reg.PC = m->entry;
	/*
	 * newstack() (libinterp/stack.c) does memmove(p->reg.FP, f, f->t->size)
	 * -- f->t is m->entryt here, the *complete* entry-frame type covering
	 * every local the root module's init() declares, routinely far
	 * bigger than sizeof(Frame).  This used to pass a bare on-stack
	 * `Frame f`, only ever big enough for the Frame header, so the copy
	 * read straight past it into whatever this C function's own stack
	 * frame happened to hold next -- garbage into every local of the
	 * very first Dis Prog run at boot, on every single native startup.
	 * emu/port/dis.c's own schedmod() already carries this exact fix
	 * (and the comment explaining it) from an earlier hunt; this native
	 * copy never got the same fix.  Allocate the real entry-frame size
	 * instead, same as emu.  See doc/inferno-ports.ms.
	 */
	f = mallocz(m->entryt->size, 1);
	fp = f;
	R.s = &fp;
	f->t = m->entryt;
	newstack(p);
	free(f);
	initmem(m->entryt, p->reg.FP);

	return p;
}

void
acquire(void)
{
	Prog *p;

	vmacquire();

	if(up->type == Interp) {
		p = up->iprog;
		up->iprog = nil;
		irestore(p);
	}
	else
		p = up->prog;

	/*
	 * Unlocked on purpose: the VM lock is held from here until the
	 * matching release(), and nothing touches the run queue without
	 * it.
	 */
	p->state = Pready;
	p->link = curP->runhd;
	curP->runhd = p;
	if(p->link == nil)
		curP->runtl = p;
	curP->nlocal++;
}

void
release(void)
{
	int spawn;

	if(up->type == Interp){
		if(up->iprog != nil)
			panic("Double release (Interp)?");
		up->iprog = isave();
	}else{
		if(((Prog *)up->prog)->state != Pready) panic("double release (GC)?");
		delrun(Prelease);
	}

	/*
	 * This process is about to block.  If programs are left on the run
	 * queue and no interpreter is sitting idle to pick them up, make
	 * one: otherwise a single blocking Dis system call stops every
	 * Limbo program in the system, which is the whole reason this
	 * kernel spawns "dis" processes at all.  isched.creating keeps two
	 * releases in a row from making two.
	 */
	lock(&isched.l);
	spawn = 0;
	/*
	 * The global queue counts as work here.  Testing curP->runhd alone
	 * asks "is there work on THIS context's local queue", which stopped
	 * being the same question as "is there work" the moment a bounded
	 * local queue could overflow.  With Runqmax forced to 1 the boot
	 * stalled: programs sat on the global queue, this test saw an empty
	 * local one, no further interpreter was spawned, and the only one
	 * running parked.  88 scheduler passes in a whole boot, against
	 * 8318 for the same boot at the default bound.
	 */
	if((curP->runhd != nil || isched.ghead != nil)
	&& isched.nidle == 0 && isched.creating == 0){
		isched.creating = 1;
		spawn = 1;
	}
	unlock(&isched.l);

	vmrelease();
	wakeidle();

	if(spawn)
		kproc("dis", vmachine, nil, KPDUP);
}

void
iyield(void)
{
	if(up->vmheld == 0)
		return;
	if(up->iprog != nil)
		panic("iyield but iprog, type %d", up->type);
	isched.nyield++;
	vmrelease();
	vmacquire();
}

void
startup(void)
{
	up->type = Interp;
	up->iprog = nil;

	lock(&isched.l);
	isched.creating = 0;
	unlock(&isched.l);

	vmacquire();
}

void
progexit(void)
{
	Prog *r;
	Module *m;
	int broken;
	char *estr, msg[ERRMAX+2*KNAMELEN] = {'\0'};

	estr = up->env->errstr;
	broken = 0;
	DBG("progexit estr %s\n", estr);
	if(emptystr(up->env->errstr) == 0 && strcmp(estr, Eintr) != 0 && strncmp(estr, "fail:", 5) != 0)
		broken = 1;

	r = up->iprog;
	if(r != nil)
		acquire();
	else
		r = currun();

	if(*estr == '\0' && r->flags & Pkilled)
		estr = "killed";

	m = R.M->m;
	if(broken){
		print("[%s] Broken: \"%s\" at 0x%p pid %d\n", m->name, estr, up->env->errpc, up->pid);
		if(1) dumpstack();
	}
	if(r->exval != H)
		DBG("progexit pid %d name %s estr %s exval %p exstr %s\n",
			r->pid, m->name, estr, r->exval, r->exstr);

	// sh.b is matching on fail: not on "<pid> fail: "
	/* KenC LP64: one homogeneous arg per snprint */
	{
		int i;

		i = snprint(msg, sizeof(msg), "%d \"", r->pid);
		i += snprint(msg+i, sizeof(msg)-i, "%s", m->name);
		i += snprint(msg+i, sizeof(msg)-i, "\":");
		snprint(msg+i, sizeof(msg)-i, "%s", estr);
	}
	// snprint(msg, sizeof(msg), "%s", estr);
	DBG("progexit msg %s\n", msg);

	if(up->env->debug != nil) {
		DBG("progexit debug set\n");
		dbgexit(r, broken, estr);
		broken = 1;
		/* must force it to break if in debug */
	}else if(broken && (!keepbroken || strncmp(estr, "out of memory", 13)==0 || memusehigh()))
		broken = 0;	/* don't want them or short of memory */

	if(broken){
		tellsomeone(r, msg);
		r = isave();
		r->state = Pbroken;
		return;
	}
	gclock();
	destroystack(&R);
	delprog(r, msg);
	gcunlock();
}

void
disfault(void *reg, char *msg)
{
	Prog *p;

	USED(reg);

	if(strncmp(msg, Eintr, 6) == 0 || up == nil) {
		print("EMU: faults: %s\n", msg);
		panic("disfault");
	}
	if(up->type != Interp) {
		print("SYS: process %s faults: %s\n", up->text, msg);
		panic("disfault");
	}

	if(up->iprog != nil)
		acquire();

	p = currun();
	if(p == nil)
		panic("Interp faults with no dis prog");

	/* cause an exception in the dis prog. */
print("disfault caller 0x%p\n", getcallerpc(&reg));
	error(msg);
}

void
vmachine(void*)
{
	Prog *r;
	Osenv *o;
	int cycles;
	static int gccounter;

	startup();

	/* cleans out the exception stack (error labels) */
	while(waserror()) {
		/*
		 * A Dis exception leaves xec() by longjmp, so the
		 * curP->curprog = nil at the bottom of the handler never
		 * runs and the name would dangle -- past the Prog's own
		 * destruction, in the exit case.  progreg() only compares
		 * the pointer, never follows it, but a later Prog allocated
		 * at the same address would be handed the wrong register
		 * file.  Clear it here, where every non-local exit from the
		 * interpreter lands.  The answer this restores is the right
		 * one: exception.c has already synced p->reg from R on the
		 * path that carries on executing.
		 */
		curP->curprog = nil;
		inxec = 0;	/* the quantum did not finish; see xec.c */
		DBG("vmachine waserror() loop up->env->errstr %s\n",  up->env->errstr);
		if(up->type != Interp)
			panic("vmachine: non-interp kproc");
		/*
		 * swiprog() posts a note to the kproc a killed Prog was last
		 * running on, to break it out of a blocking system call.  If
		 * that Prog has since left this kproc and the note lands on
		 * the idle sleep below instead, the Eintr it raises has no
		 * Prog to be delivered to: propex(nil) faulted at +0xb4 here
		 * on riscv64 under smoke.sh, right after a shell script
		 * finished.  It is nobody's exception; go back to the loop.
		 */
		if(up->iprog == nil && currun() == nil && strcmp(up->env->errstr, Eintr) == 0){
			up->env = &up->defenv;
			continue;
		}
		if(up->iprog != nil){
			DBG("vmachine waserror() before acquire up->env->errstr %s\n",  up->env->errstr);
			acquire();
		}
		DBG("vmachine waserror() after acquire up->env->errstr %s\n",  up->env->errstr);
		if(handler(up->env->errstr) == 0) {
			if(currun() == nil)
				panic("vmachine: error \"%s\" with no current prog", up->env->errstr);
			propex(currun(), up->env->errstr);
			DBG("vmachine waserror() after propex up->env->errstr %s\n",  up->env->errstr);
			progexit();
			DBG("vmachine waserror() after progexit\n");
		}
		up->env = &up->defenv;
	}

	cycles = 0;
	for(;;) {
		/*
		 * Keep the clock moving under CPU-bound Dis (Bounce tk update).
		 * On virt, soft timers used to advance only via idlehands→WFI→
		 * clockpoll; a busy interpreter never idled so sys->sleep stalled.
		 */
		clockcheck();

		if(tready(nil) == 0) {
			/*
			 * execatidle() collects and calls addrun/delrunq, so
			 * it wants the VM held.  Parking must not hold it, or
			 * every Limbo program in the system stops here.
			 */
			execatidle();
			vmrelease();
			lock(&isched.l);
			if(tready(nil) == 0){
				/*
				 * Re-checked under isched.l: the VM was given
				 * up above, so another process may have made a
				 * program ready and called wakeidle() before
				 * this one was on the list to be found.
				 */
				up->vmnext = isched.idlevmq;
				isched.idlevmq = up;
				isched.nidle++;
				up->state = Queueing;
				up->pc = getcallerpc(&r);
				unlock(&isched.l);
				sched();
			} else
				unlock(&isched.l);
			vmacquire();
		}

		/*
		 * MULTICORE INSTRUMENTATION - temporary.  maxnrunq says how
		 * many Dis programs are ready at once; this says how much
		 * that costs.  vmlock.head is the queue of kernel processes
		 * blocked in vmacquire(), so a pass that sees it non-nil is
		 * a pass where a runnable interpreter was waiting on the one
		 * global VM lock.  The ratio is the answer to "what would a
		 * per-executor register file buy on this workload", in the
		 * only units that matter: passes spent with someone blocked
		 * over passes total.
		 */
		vmpasses++;
		if(vmlock.head != nil) {
			Proc *w;
			int d = 0;

			vmblocked++;
			/*
			 * The control this counter lacked.  vmblocked rests on
			 * vmlock.head meaning "processes blocked in
			 * qlock(&vmlock)", and would report a plausible
			 * fraction whether or not that is what the field
			 * holds.  qlock() appends up to the head/tail chain
			 * through up->qnext and sleeps it, so every process on
			 * that chain must be in Queueing; one that is not
			 * would mean the field is stale or means something
			 * else, and the fraction above would be measuring
			 * nothing.
			 *
			 * The depth is worth having for its own sake too: the
			 * boolean says a runnable interpreter was waiting, the
			 * depth says how many, which is what a per-executor
			 * register file would actually release.
			 */
			for(w = vmlock.head; w != nil && d < 64; w = w->qnext) {
				d++;
				if(w->state != Queueing && vmqbad++ == 0)
					print("vmq: waiter %d %s state %d, not Queueing"
						" -- vmlock.head is not the wait queue\n",
						w->pid, w->text, w->state);
			}
			if(d > maxvmq) {
				maxvmq = d;
				print("vmq: %d interpreters blocked on the vm lock at once\n", d);
			}
		}

		if(vmlock.head != nil && (curP->runhd == nil || ++cycles > 2)){
			iyield();
			cycles = 0;
		}

		/*
		 * Take from the global queue when the local one is empty,
		 * and every Gqevery picks even when it is not.
		 *
		 * The second half is not optional, and a forced-bound test
		 * proved it: with Runqmax 1 the boot stalled after the shell
		 * spawned.  The round-robin at the foot of this loop only
		 * rotates when runhd != runtl, so a local queue of one never
		 * rotates, the same Prog is picked forever, and everything
		 * that overflowed to the global queue starves.  Go has the
		 * same hazard and the same answer -- schedule() takes from
		 * the global queue every 61st tick regardless of the local
		 * one, precisely so a busy local queue cannot starve it.
		 *
		 * Linked directly rather than through addrun(), which panics
		 * on a Prog already in Pready, and one that reached the
		 * global queue is.
		 */
		if(curP->runhd == nil || (++gqtick % Gqevery) == 0){
			Prog *g;

			if((g = gget()) != nil){
				g->link = curP->runhd;
				curP->runhd = g;
				if(g->link == nil)
					curP->runtl = g;
				curP->nlocal++;
			}
		}

		r = curP->runhd;
		if(r != nil) {
			{	/* MULTICORE INSTRUMENTATION - temporary */
				Prog *q;
				int n = 0, ready = 0;

				for(q = r; q != nil && n < Runqcap; q = q->link)
					n++;
				/*
				 * The same quantity by an independent path, as
				 * a control on the walk above.  maxnrunq counts
				 * the run-queue links; this counts Progs in
				 * state Pready over isched.head, which is the
				 * list of every Prog and is maintained by
				 * different code.  Two counts that agree are a
				 * measurement; one count is an assertion about
				 * a data structure.
				 *
				 * They should agree, because addrun() sets
				 * Pready exactly when it links, and delrun()
				 * and delrunq() unlink.  A persistent
				 * disagreement would mean one of those paths
				 * leaves a Prog on the queue in another state
				 * or in a state without being queued -- which
				 * is the shape of the delprog() bug fixed
				 * above, where a freed Prog stayed linked.
				 */
				for(q = isched.head; q != nil; q = q->next)
					if(q->state == Pready)
						ready++;
				if(n > maxnrunq){
					maxnrunq = n;
					print("runq: %d dis programs ready at once "
						"(%d by state), cpu%d\n",
						n, ready, m->machno);
				}
				/*
				 * Pready counts Progs on the global queue too,
				 * so the local walk is short by exactly ngq.
				 * Comparing without that term made this fire
				 * the moment the global queue was first used,
				 * which is the control working -- it noticed a
				 * real change in what the structures mean.
				 */
				if(ready != n + isched.ngq && nrunqmismatch++ == 0)
					print("runq: %d linked + %d global but %d in "
						"Pready -- the counts disagree\n",
						n, isched.ngq, ready);
			}
			o = r->osenv;
			up->env = o;
			/* Keep Proc.*grp in sync for #e/#p and namec (pctl updates Osenv). */
			up->pgrp = o->pgrp;
			up->fgrp = o->fgrp;
			up->egrp = o->egrp;

			fpurestore(up->env->fpuostate);
			r->xec(r);
			up->env->fpuostate = fpusave();

			if(curP->runhd != nil)
			if(r == curP->runhd)
			if(curP->runhd != curP->runtl) {
				curP->runhd = r->link;
				r->link = nil;
				curP->runtl->link = r;
				curP->runtl = r;
			}
			up->env = &up->defenv;
		}
		/*
		 * BusyGC like emu (throttled).  Never pushrun when addrun is
		 * set — that panics "pushrun addrun" (seen on virt at
		 * interactive sh with wm/toolbar load).
		 */
		if(curP->runhd != nil)
		if(up->iprog == nil)
		if((++gccounter & 0xFF) == 0){
			r = (Prog*)up->prog;
			if(r != nil && r->addrun == nil){
				gcbusy++;
				up->type = BusyGC;
				pushrun(r);
				rungc(isched.head);
				up->type = Interp;
				delrunq(r);
			}
		}
	}
}

void
disinit(void *a)
{
	Prog *p;
	Osenv *o;
	Module *root;
	char *initmod = a;

	if(waserror()){
		/*
		 * Every "disinit error:" capture this hunt has ever seen
		 * printed no text after the colon -- %r does nothing in
		 * kernel context on this port (libkern/print.c's own
		 * errfmt() unconditionally returns -1; the comment there
		 * says as much: it "works from limbo" via lib9's own
		 * errfmt(), never here).  This swallowed the actual error
		 * on every single capture.  Use the same kgerrstr()+%s
		 * idiom the "loading %s: %s" panic two dozen lines below
		 * already uses instead.  pc64-only, temporary.  See
		 * doc/inferno-ports.ms.
		 */
		kgerrstr(up->genbuf, sizeof up->genbuf);
		panic("disinit error: %s", up->genbuf);
	}

	print("Initial Dis: \"%s\"\n", initmod);

	fmtinstall('D', Dconv);

	addclock0link(accountant, MS2HZ);

	// TODO obsolete? cpuidentify calls fpuinit() fpinit();
	// TODO obsolete? fpsave(&up->env->fpu);

	opinit();
	modinit();
	excinit();

	root = load(initmod);
	if(root == 0) {
		kgerrstr(up->genbuf, sizeof up->genbuf);
		panic("loading \"%s\": %s", initmod, up->genbuf);
	}

	p = schedmod(root);

	memmove(p->osenv, up->env, sizeof(Osenv));
	o = p->osenv;
	incref(o->pgrp);
	incref(o->fgrp);
	if(o->egrp != nil)
		incref(o->egrp);
	if(o->sigs != nil)
		incref(o->sigs);
	o->user = nil;
	kstrdup(&o->user, up->env->user);
	o->errstr = o->errbuf0;
	o->syserrstr = o->errbuf1;

	if(kopen("#c/cons", OREAD) != 0)
		panic("failed to make fd0 from #c/cons");
	kopen("#c/cons", OWRITE);
	kopen("#c/cons", OWRITE);

	poperror();
	vmachine(nil);
}

void
pushrun(Prog *p)
{
	if(p->addrun != nil){
		/* Was panic; under virt+wm this raced BusyGC.  Skip. */
		print("pushrun: prog %#p has addrun (skipped)\n", p);
		return;
	}
	p->state = Pready;
	p->link = curP->runhd;
	curP->runhd = p;
	if(p->link == nil)
		curP->runtl = p;
	curP->nlocal++;
}

/*
 * One dump of the Dis scheduler's state: who holds the interpreter, who
 * is parked waiting for work, every live Prog, and every live kernel
 * process with the Rendez it is asleep on.  Meant to be called once,
 * from a clock handler, after a stall has set in.
 *
 * NOTE: this is a reimplementation.  An earlier disdump() existed in
 * this tree as uncommitted work and was destroyed by a bad edit while
 * the multicore work was going on; it could not be recovered from any
 * commit or worktree.  os/inferno/raspi3b/clock.c calls this and needs
 * it to link.  What it prints is what its caller's comment said it
 * printed, written fresh against the structures here -- it is not the
 * original text.
 */
void
disdump(void)
{
	static char *pstate[] = {
		"alt", "send", "recv", "debug",
		"ready", "release", "exiting", "broken",
	};
	extern char *statename[];
	char mbuf[64];
	Prog *p;
	Proc *q;
	int i;

	print("\ndis: vmlocked %d nidle %d creating %d runhd %#p runtl %#p\n",
		vmlock.locked, isched.nidle, isched.creating,
		curP->runhd, curP->runtl);
	/* MULTICORE INSTRUMENTATION - temporary */
	print("dis: maxrunq %d, %llud of %llud scheduler passes had an "
		"interpreter blocked on the vm lock\n",
		maxnrunq, vmblocked, vmpasses);
	/* MULTICORE INSTRUMENTATION - temporary */
	print("dis: global runq: %d put, %d got, %d now, bound %d\n",
		gqput, gqget, isched.ngq, Runqmax);

	for(p = curP->runhd; p != nil; p = p->link)
		print("dis: runq prog %d %s\n", p->pid,
			(uint)p->state < nelem(pstate)? pstate[p->state]: "?");

	for(p = isched.head; p != nil; p = p->next){
		modstatus(&p->reg, mbuf, sizeof mbuf);
		print("dis: prog %d %s %s\n", p->pid,
			(uint)p->state < nelem(pstate)? pstate[p->state]: "?", mbuf);
	}

	for(q = vmlock.head; q != nil; q = q->qnext)
		print("dis: waiting for the vm: proc %d %s\n", q->pid, q->text);

	for(q = isched.idlevmq; q != nil; q = q->vmnext)
		print("dis: parked for work: proc %d %s\n", q->pid, q->text);

	for(i = 0; i < conf.nproc; i++){
		q = proctab(i);
		if(q->state == Dead)
			continue;
		print("dis: proc %d %s %s type %d vmheld %d iprog %#p r %#p sleeppc %#p qpc %#p\n",
			q->pid, q->text, statename[q->state], q->type,
			q->vmheld, q->iprog, q->r, q->sleeppc, q->qpc);
	}
}
