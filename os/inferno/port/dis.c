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
	/*
	 * runhd/runtl have moved into Pctx (include/interp.h): the run queue
	 * is per context, and they are deleted from here rather than left
	 * unused so that nothing can reach the old global by the old name.
	 * head/tail stay -- that is the list of EVERY Prog, which
	 * execatidle() hands to rungc() as the root list, and splitting it
	 * per context would divide the root set and lose objects.
	 */
	Prog*	head;
	Prog*	tail;
	Rendez	irend;
	int	idle;
	int	nyield;
	int	creating;
	Proc*	vmq;		/* queue of procs wanting vm */
	Proc*	vmqt;
	Proc*	idlevmq;	/* queue of procs wanting work */
	Atidle*	idletasks;
} isched;

int	bflag;
int	cflag;
uvlong	gcbusy;
uvlong	gcidle;
uvlong	gcidlepass;
uvlong	gcpartial;
int keepbroken = 1;
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
extern ulong reschedtaken;	/* port/proc.c */
extern ulong gcticks, gcpasses, gcmax, idlegcticks, idlegcmax;
int	disracepid = -1;
int	disracehits;
int	disracewindows;	/* delprog windows opened, total */
int	disraceoverlaps;	/* windows opened while another was already open */
extern ulong gchalted;

/*
 * Stopping the world for a collection.
 *
 * rootset() reads a program's live registers through progreg(), and
 * Pctx.inxec is exactly "this context's register file is live".  So the
 * collector's precondition is that no OTHER context has a quantum open, and
 * that is all it is: a context outside xec() can still mutate the heap,
 * which the write barrier handles by design, and can still queue a program,
 * which cannot cost a root because roots come from isched.head and never
 * from a run queue.
 *
 * With one executor this is satisfied the moment it is asked, and that is
 * the case the board runs today -- Dis is serialised through isched, so
 * othersrunning() is always 0 and stoptheworld() returns without waiting.
 * It is here so the precondition is enforced by code rather than by the
 * accident of there being one executor, and so the call sites are already
 * in the right shape.
 *
 * Bounded by wall-clock time, and by time rather than by a count of tries
 * because that is the mistake the multicore branch measured: a count
 * measures how fast this loop happens to go round, so the same two thousand
 * tries either spanned long enough for other contexts to finish or elapsed
 * too quickly to ever succeed, depending on whether an unrelated print sat
 * in the loop.  What the waiting is for is wall-clock time for somebody
 * else's quantum to end.
 *
 * Giving up is safe in a way that waiting is not: a collection that does not
 * happen costs memory until the next one, and there is always a next one,
 * while a collection that cannot start costs the boot.  Parking rather than
 * polling is the better answer, as Go does with an M, and is a larger change.
 */
enum { Stwticks = HZ/10 };	/* 100ms for another quantum to end */

/*
 * The process-group lists, and why they get a lock of their own.
 *
 * addgrp() and delgrp() thread Progs onto a doubly-linked group list and
 * maintain g->head and g->tail.  Neither has ever taken a lock and neither
 * needed one: newprog() calls addgrp() after it has released isched.l,
 * delprog() calls delgrp() before it takes it, and both run with the
 * interpreter acquired -- which, while one executor runs Dis at a time,
 * means there is nothing to race with.  That is still true on this board.
 *
 * It stops being true the moment two executors run.  The multicore branch
 * measured what happens: both run addgrp() and delgrp() on the same group,
 * the list tears, g->tail is left naming a Prog that delprog() has since
 * freed, and the next addgrp() to that group does "g->tail->grpnext = n",
 * writing a Prog pointer into freed memory.  From there it is the
 * allocator's problem and which panic you get depends on what the pool had
 * since put there.  Three guests each way, fifteen minutes, eight
 * processors: 18 and 17 detections on two guests of three without the lock,
 * 0 on three of three with it, and the same channel throughput either way --
 * so the fixed kernel was working just as hard and had simply stopped
 * writing into freed Progs.
 *
 * A lock of its own, and NOT isched.l, because delgrp() ends by freeing
 * empty parent groups and free() takes the pool's own lock.  The order is
 * always grplock then pool, never the reverse.
 */
static Lock	grplock;

int	gcstw;			/* a collection wants the others stopped */
ulong	gcstwstops;		/* worlds stopped */
ulong	gcstwwaits;		/* times one had to be waited for */
ulong	gcstwfails;		/* collections abandoned; see above */
ulong	nrunqother;		/* Progs found on another context's run queue */
ulong	nrunqdel;		/* Progs delprog() freed that were still queued */

static int
othersrunning(void)
{
	int i, n;

	n = 0;
	for(i = 0; i < npctx; i++)
		if(pctxs[i] != curP && pctxs[i]->inxec)
			n++;
	return n;
}

int
stoptheworld(void)
{
	ulong start;

	gcstw = 1;
	coherence();
	if(othersrunning() == 0){
		gcstwstops++;
		return 1;
	}
	start = m->ticks;
	while(othersrunning() != 0){
		if(m->ticks - start > Stwticks){
			gcstw = 0;
			coherence();
			gcstwfails++;
			return 0;
		}
		gcstwwaits++;
		sched();
	}
	gcstwstops++;
	return 1;
}

void
starttheworld(void)
{
	gcstw = 0;
	coherence();
}



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
	return curP->runhd != nil || isched.vmq != nil;
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
	ulong t0;

	if(tready(nil))
		return;

	gcidle++;
	up->type = IdleGC;
	up->iprog = nil;
	addrun(up->prog);

	t0 = m->ticks;
	done = gccolor+3;
	while(gccolor < done && gcruns()) {
		if(isched.vmq != nil || curP->runhd != curP->runtl) {
			gcpartial++;
			break;
		}
		if(!stoptheworld())
			break;
		rungc(isched.head);
		starttheworld();
		gcidlepass++;
		if(((ulong)gcidlepass&0xFF) == 0)
			sched();
	}

	up->type = Interp;
	delrunq(up->prog);
	/*
	 * t0 is a local because this loop calls sched(): a static held
	 * the start time of whichever interpreter kproc ran last, so
	 * every other one measured from there and the total came out at
	 * 1.8 million ticks on a board that had been up for 12 thousand.
	 * A counter larger than the uptime is the tell.
	 */
	t0 = m->ticks - t0;
	idlegcticks += t0;
	if(t0 > idlegcmax)
		idlegcmax = t0;
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
	 * delrunq(), not a test against this context's queue head.  The head
	 * test unlinks p only if it happens to be running here: a p anywhere
	 * else in a queue stayed linked and was then freed, and with a second
	 * context "anywhere else" includes another context's queue entirely.
	 * nrunqdel counts the times the search found it somewhere the head
	 * test would have missed.
	 */
	if(p == curP->runhd) {
		curP->runhd = p->link;
		if(p->link == nil)
			curP->runtl = nil;
	}else{
		Prog *q;
		int j;

		for(j = 0; j < npctx; j++)
			for(q = pctxs[j]->runhd; q != nil; q = q->link)
				if(q == p){
					nrunqdel++;
					delrunq(p);
					j = npctx;
					break;
				}
	}
	p->state = 0xdeadbeef;
	/*
	 * Before the Prog's memory goes back.  progreg() answers "which
	 * register file holds this program's live roots" by comparing a
	 * Prog pointer against each context's curprog -- it never follows
	 * the pointer, so a dangling one is not itself a fault.  But the
	 * allocator will hand this address out again, and a new Prog at the
	 * old address would be answered for with some other program's
	 * register file.  So the context stops naming it here.
	 */
	{
		int i;

		for(i = 0; i < npctx; i++)
			if(pctxs[i]->curprog == p){
				/*
				 * inxec too: if the program whose quantum was
				 * open is being freed, that quantum is over.
				 * A program that exits from inside its own
				 * quantum gets here through progexit() and
				 * xec() never reaches the tail that would
				 * clear the flag, which left inxec set for
				 * the rest of the boot -- the collector's
				 * guard reported "a quantum open (prog 0x0)",
				 * a nil program beside a set flag, which is
				 * the signature of clearing one and not the
				 * other.
				 */
				pctxs[i]->curprog = nil;
				pctxs[i]->inxec = 0;
			}
	}
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
	if(g == nil)
		return nil;
	lock(&grplock);
	l = g->head;
	unlock(&grplock);
	if(l != nil && l->pid == g->id)
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
	/*
	 * This walk is NOT under grplock, deliberately.  It calls exprog()
	 * and killprog() on each member, and those can raise and can sleep,
	 * which a spinlock forbids.  The answer is to snapshot the members
	 * under the lock and act on the snapshot outside it -- which is what
	 * the multicore branch does, and which needs somewhere to put the
	 * snapshot on a path that is already handling an exception.  It
	 * cannot race while one executor runs Dis, so it is written down here
	 * rather than half-done.
	 */
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
	pg = delgrp(p);		/* takes grplock itself; do not nest */
	lock(&grplock);
	g->head = g->tail = p;
	p->group = g;
	if(pg != nil){
		g->sib = pg->child;
		pg->child = g;
	}
	g->parent = pg;
	unlock(&grplock);
}

static void
addgrp(Prog *n, Prog *p)
{
	Progs *g;

	n->group = p->group;
	if((g = n->group) != nil){
		lock(&grplock);
		n->grpnext = nil;
		if(g->head != nil){
			n->grpprev = g->tail;
			g->tail->grpnext = n;
		}else{
			n->grpprev = nil;
			g->head = n;
		}
		g->tail = n;
		unlock(&grplock);
	}
}

static Progs*
delgrp(Prog *p)
{
	Progs *g, *pg, *cg, **l;

	g = p->group;
	if(g == nil)
		return nil;
	lock(&grplock);
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
	unlock(&grplock);
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

/*
 * The hang watchdog.
 *
 * This board wedges: the interpreter stops handing over, and a dump
 * taken with ^\ at that moment shows processes Queueing for the VM and
 * others Ready with nobody running them.  Five of those in two days,
 * and every one was diagnosed late or not at all, because ^\ has to be
 * typed by somebody who is watching and who notices in time.  Two were
 * diagnosed from dumps of a board that had already recovered, which is
 * worth nothing -- a healthy machine's processes are all asleep too,
 * and the difference only shows in the counts.
 *
 * So the board watches itself.  disbeat is incremented once per turn of
 * vmachine's loop, which is the one place every running Dis program
 * passes through; if it has not moved for Wedgesecs while there is
 * still work queued for the VM, the machine is not idle, it is stuck,
 * and this prints the same dump ^\ would have.
 *
 * It prints once per wedge, not once per second, because a wedged board
 * with a console full of repeated dumps has lost the evidence of what
 * happened first.  And it only reports: rebooting on its own would
 * destroy the state somebody may be about to look at, and ^R is one
 * keystroke away for whoever does.
 */
enum {
	Wedgesecs = 15,	/* silence this long, with work queued, is a wedge */
};

ulong	disbeat;
extern void kstackdump(void);		/* devcons.c */

void
diswatchproc(void*)
{
	ulong last, lastticks;
	int quiet, reported;

	last = disbeat;
	lastticks = 0;
	quiet = 0;
	reported = 0;
	for(;;){
		tsleep(&up->sleep, return0, nil, 1000);
		if(disbeat != last){
			last = disbeat;
			quiet = 0;
			reported = 0;
			continue;
		}
		/*
		 * The interpreter has not moved.  That is only a wedge if
		 * something was waiting for it: an idle board with nothing
		 * to run sits here legitimately for as long as it likes.
		 */
		if(isched.vmq == nil && curP->runhd == nil){
			quiet = 0;
			continue;
		}
		if(++quiet < Wedgesecs || reported)
			continue;
		reported = 1;
		iprint("\nDIS-WEDGED: no interpreter progress for %d s, "
			"beat %lud, vmq %s, runhd %s, ticks %lud\n",
			quiet, disbeat,
			isched.vmq != nil? "waiting": "empty",
			curP->runhd != nil? "ready": "empty",
			m->ticks);
		USED(lastticks);
		kstackdump();
	}
}

/*
 * ^C on the console: kill whatever is holding it.
 *
 * Same principle as ^\ in devcons.c, and for the same reason.  A
 * program that will not stop cannot be killed through a file, because
 * writing /prog/n/ctl needs a shell and the shell is the thing that is
 * blocked behind it.  The console's receive path still runs -- every
 * character typed is still echoed -- so that is where the question goes
 * in.  It only sets a flag and wakes this kproc: killing a Dis process
 * needs the interpreter acquired, which an interrupt handler cannot do.
 *
 * What it kills, and why that rule.  Everything the console starts ends
 * up in the process group of the first Dis program, so that group is
 * "what the console is running" -- and its leader is the shell itself,
 * which is the one thing that must survive or there is nothing left to
 * type at.  So: every program in that group except the leader.  The
 * cause is "interrupted" rather than "killed" because that is the word
 * the program prints on its way out, and it is what happened.
 *
 * A program not started from the console -- a server in its own group,
 * like dossrv -- is deliberately untouched.  ^C is for the thing in
 * front of you, not for the machine.
 */
static Rendez	intrr;
static int	intrwanted;

static int
intrready(void*)
{
	return intrwanted;
}

void
consinterrupt(void)
{
	intrwanted = 1;
	wakeup(&intrr);
}

void
consintrproc(void*)
{
	Prog *p, *f;
	Progs *g;
	int *pids, npid, i, n;

	for(;;){
		sleep(&intrr, intrready, nil);
		intrwanted = 0;
		acquire();
		if(waserror()){
			release();
			continue;
		}
		p = progpid(1);
		if(p == nil || p->group == nil){
			print("^C: nothing running\n");
			poperror();
			release();
			continue;
		}
		g = p->group;
		/*
		 * Take the pids first and walk them afterwards.  killprog()
		 * can take a program off this very list, so holding a Prog*
		 * across it is how killgrp() below says not to do it.
		 */
		npid = 0;
		for(f = g->head; f != nil; f = f->grpnext)
			npid++;
		pids = malloc(npid*sizeof(int));
		if(pids == nil){
			poperror();
			release();
			continue;
		}
		npid = 0;
		for(f = g->head; f != nil; f = f->grpnext)
			pids[npid++] = f->pid;
		n = 0;
		for(i = 0; i < npid; i++){
			if(pids[i] == p->pid)
				continue;	/* not the shell */
			f = progpid(pids[i]);
			if(f != nil && f != currun()){
				killprog(f, "interrupted");
				n++;
			}
		}
		free(pids);
		print("^C: interrupted %d\n", n);
		poperror();
		release();
	}
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
	if(curP->runhd == nil)
		curP->runhd = p;
	else
		curP->runtl->link = p;

	curP->runtl = p;
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

	return p;
}

void
delrunq(Prog *p)
{
	Prog *prev, *f;
	Pctx *c;
	int i;

	/*
	 * Every context's queue, not just this one.  With one context that is
	 * the same search it always was; with two, a program can be on a
	 * queue that is not the asking context's, and looking only here would
	 * leave it linked -- on a Prog that delprog() is about to free.
	 * nrunqother counts the case, so that "it cannot happen yet" is a
	 * measurement rather than an assumption.
	 */
	for(i = 0; i < npctx; i++){
		c = pctxs[i];
		prev = nil;
		for(f = c->runhd; f; f = f->link) {
			if(f == p)
				break;
			prev = f;
		}
		if(f == nil)
			continue;
		if(c != curP)
			nrunqother++;
		if(prev == nil)
			c->runhd = p->link;
		else
			prev->link = p->link;
		if(p == c->runtl)
			c->runtl = prev;
		return;
	}
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
	int empty;
	Prog *p;

	lock(&isched.l);
	if(isched.idle) {
		isched.idle = 0;
		unlock(&isched.l);
	}
	else {
		up->qnext = nil;
		if(isched.vmq != nil){
			empty = 0;
			isched.vmqt->qnext = up;
		}else{
			isched.vmq = up;
			empty = 1;
		}
		isched.vmqt = up;

		up->state = Queueing;
		up->pc = getcallerpc(&empty);
		unlock(&isched.l);
		if(empty)
			wakeup(&isched.irend);
		sched();
		/*
		 * acquire() treats sched() as a promise it does not make.
		 * sched() returns without switching when the process holds
		 * a spin lock, up to twenty times in a row; if that ever
		 * happened here this process would fall through and run
		 * the interpreter without the token, while still linked on
		 * isched.vmq for release() to hand the token to -- and the
		 * token would be gone, with every other process queued in
		 * acquire() behind a VM nobody is running.  That is the
		 * shape of the wedge, so say so here rather than hang.
		 */
		if(up->state == Queueing)
			panic("acquire: sched returned queueing, nlocks %d delaysched %d",
				up->nlocks, up->delaysched);
	}

	if(up->type == Interp) {
		p = up->iprog;
		up->iprog = nil;
		irestore(p);
	}
	else
		p = up->prog;

	p->state = Pready;
	p->link = curP->runhd;
	curP->runhd = p;
	if(p->link == nil)
		curP->runtl = p;
}

void
release(void)
{
	Proc *p, **pq;
	int f;

	if(up->type == Interp){
		if(up->iprog != nil)
			panic("Double release (Interp)?");
		up->iprog = isave();
	}else{
		if(((Prog *)up->prog)->state != Pready) panic("double release (GC)?");
		delrun(Prelease);
	}

	lock(&isched.l);
	if(*(pq = &isched.vmq) == nil && *(pq = &isched.idlevmq) == nil) {
		isched.idle = 1;
		f = isched.creating;
		isched.creating = 1;
		unlock(&isched.l);
		if(f == 0)
			/*
			 * flags=0 left this kproc's pgrp/fgrp/egrp at
			 * whatever newproc()'s recycled Proc slot last
			 * had -- rptproc(), the same acquire()/release()
			 * pattern this loop uses, passes KPDUP for exactly
			 * this reason.  The per-iteration up->fgrp = o->fgrp
			 * below resyncs before every xec(), but code that
			 * can run before this kproc's first loop iteration
			 * (startup(), the waserror() scaffolding) still sees
			 * whatever newproc() handed it otherwise.
			 */
			kproc("dis", vmachine, nil, KPDUP);
		return;
	}
	p = *pq;
	*pq = p->qnext;
	unlock(&isched.l);

	ready(p);
}

void
iyield(void)
{
	Proc *p;

	lock(&isched.l);
	p = isched.vmq;
	if(p == nil) {
		unlock(&isched.l);
		return;
	}
	isched.nyield++;
	isched.vmq = p->qnext;

	if(up->iprog != nil)
		panic("iyield but iprog, type %d", up->type);
	if(up->type != Interp){
		static int once;
		if(!once++)
			print("tell charles: #%p->type==%d\n", up, up->type);
	}
	up->qnext = isched.idlevmq;
	isched.idlevmq = up;

	up->state = Queueing;
	up->pc = getcallerpc(&p);
	unlock(&isched.l);
	ready(p);
	sched();
}

void
startup(void)
{
	int x;

	up->type = Interp;
	up->iprog = nil;

	lock(&isched.l);
	isched.creating = 0;
	if(isched.idle) {
		isched.idle = 0;
		unlock(&isched.l);
		return;
	}
	up->qnext = isched.idlevmq;
	isched.idlevmq = up;
	up->state = Queueing;
	up->pc = getcallerpc(&x);
	unlock(&isched.l);
	sched();
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
		DBG("vmachine waserror() loop up->env->errstr %s\n",  up->env->errstr);
		if(up->type != Interp)
			panic("vmachine: non-interp kproc");
		/*
		 * The quantum is over, however it ended.
		 *
		 * xec() clears inxec at its tail and isave() clears it when a
		 * program blocks, but an exception leaves by longjmp and
		 * reaches neither: error() inside a quantum unwinds straight
		 * to here.  inxec then stays set for the rest of the boot,
		 * and it is the flag the collector's root walk is guarded by
		 * -- so the guard would read "a quantum is open" for ever and
		 * mean nothing.
		 *
		 * Found by that guard rather than by reasoning: with it
		 * checking on entry to rungc(), a QEMU boot printed "rungc:
		 * context 0 has a quantum open (prog 0x0)".  The nil program
		 * beside a set flag is what named the path -- delprog() had
		 * cleared curprog on the way out while inxec stayed behind,
		 * so the two could only disagree if the quantum had ended
		 * somewhere that clears one and not the other.
		 */
		if(curP != nil){
			curP->inxec = 0;
			curP->curprog = nil;
		}
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
		disbeat++;	/* the hang watchdog's heartbeat; see diswatchproc */
		/*
		 * The safe point.
		 *
		 * Nothing else in this kernel ever takes the processor away
		 * from a running process.  There is no user mode to preempt
		 * from -- every process is a kernel process running C -- so
		 * the processor changes hands only when a process blocks of
		 * its own accord: sleep(), qlock(), or the release() that
		 * brackets a blocking Dis system call.  A CPU-bound Dis
		 * program therefore runs until it makes a system call, and a
		 * process a device interrupt just readied waits that long.
		 * Measured in usbdwc: three or four microseconds from arming
		 * a channel to the interrupt, and then 2.7 to 142
		 * milliseconds before the waiter ran.
		 *
		 * Here is the one place where giving it up is free of
		 * consequence.  Control is between two Dis instructions: the
		 * whole machine is R and the heap, both of which xec() has
		 * just written back into the Prog, no C invariant is half
		 * built, no lock is held, no waserror() label is in flight.
		 * It is what user mode is in Plan 9, and it comes round every
		 * PQUANTA instructions however tight the Limbo loop is.
		 *
		 * So interrupts do not call sched(); they call wantsched(),
		 * which sets this bit and returns (port/proc.c says why at
		 * length), as does hzsched() when the quantum is up.  The
		 * sched() below puts this process on the back of its run
		 * queue, exactly as a quantum expiry does in Plan 9.
		 */
		if(up->resched){
			up->resched = 0;
			reschedtaken++;
			sched();
		}

		/*
		 * Keep the clock moving under CPU-bound Dis (Bounce tk update).
		 * On virt, soft timers used to advance only via idlehands→WFI→
		 * clockpoll; a busy interpreter never idled so sys->sleep stalled.
		 */
		clockcheck();

		if(tready(nil) == 0) {
			execatidle();
			sleep(&isched.irend, tready, 0);
		}

		if(isched.vmq != nil && (curP->runhd == nil || ++cycles > 2)){
			iyield();
			cycles = 0;
		}

		r = curP->runhd;
		if(r != nil) {
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
				ulong t0;

				gcbusy++;
				up->type = BusyGC;
				pushrun(r);
				/*
				 * The third term in the latency bound, and
				 * the only one that had never been timed.
				 * This runs in the interpreter's own kproc,
				 * between two Dis instructions, and the
				 * resched check is at the top of the loop --
				 * so however long a pass takes is added to
				 * every wake that lands behind it.  Ticks,
				 * because what was wanted first was the
				 * order of magnitude: a 50ms sleep on this
				 * board overshot by 670ms exactly once, on
				 * the first pass after a Limbo loop started.
				 */
				t0 = m->ticks;
				if(stoptheworld()){
					rungc(isched.head);
					starttheworld();
				}
				t0 = m->ticks - t0;
				gcticks += t0;
				gcpasses++;
				if(t0 > gcmax)
					gcmax = t0;
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

	isched.idle = 1;

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
}
