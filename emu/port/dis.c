#include	"dat.h"
#include	"fns.h"
#include	<isa.h>
#include	<interp.h>
#include	<kernel.h>
#include	"error.h"
#include	"raise.h"

#define DP if(1){}else print

/* Names for the Dis instruction set (include/isa.h), used only to make a
 * fault report show what actually faulted instead of a bare opcode number.
 * Designated initializers, keyed by the enum constants themselves, so this
 * can't silently drift out of alignment with isa.h the way a plain
 * positional table could if an entry there were added, removed, or
 * reordered.
 */
static char *opnames[MAXDIS] = {
	[INOP] = "nop",
	[IALT] = "alt",
	[INBALT] = "nbalt",
	[IGOTO] = "goto",
	[ICALL] = "call",
	[IFRAME] = "frame",
	[ISPAWN] = "spawn",
	[IRUNT] = "runt",
	[ILOAD] = "load",
	[IMCALL] = "mcall",
	[IMSPAWN] = "mspawn",
	[IMFRAME] = "mframe",
	[IRET] = "ret",
	[IJMP] = "jmp",
	[ICASE] = "case",
	[IEXIT] = "exit",
	[INEW] = "new",
	[INEWA] = "newa",
	[INEWCB] = "newcb",
	[INEWCW] = "newcw",
	[INEWCF] = "newcf",
	[INEWCP] = "newcp",
	[INEWCM] = "newcm",
	[INEWCMP] = "newcmp",
	[ISEND] = "send",
	[IRECV] = "recv",
	[ICONSB] = "consb",
	[ICONSW] = "consw",
	[ICONSP] = "consp",
	[ICONSF] = "consf",
	[ICONSM] = "consm",
	[ICONSMP] = "consmp",
	[IHEADB] = "headb",
	[IHEADW] = "headw",
	[IHEADP] = "headp",
	[IHEADF] = "headf",
	[IHEADM] = "headm",
	[IHEADMP] = "headmp",
	[ITAIL] = "tail",
	[ILEA] = "lea",
	[IINDX] = "indx",
	[IMOVP] = "movp",
	[IMOVM] = "movm",
	[IMOVMP] = "movmp",
	[IMOVB] = "movb",
	[IMOVW] = "movw",
	[IMOVF] = "movf",
	[ICVTBW] = "cvtbw",
	[ICVTWB] = "cvtwb",
	[ICVTFW] = "cvtfw",
	[ICVTWF] = "cvtwf",
	[ICVTCA] = "cvtca",
	[ICVTAC] = "cvtac",
	[ICVTWC] = "cvtwc",
	[ICVTCW] = "cvtcw",
	[ICVTFC] = "cvtfc",
	[ICVTCF] = "cvtcf",
	[IADDB] = "addb",
	[IADDW] = "addw",
	[IADDF] = "addf",
	[ISUBB] = "subb",
	[ISUBW] = "subw",
	[ISUBF] = "subf",
	[IMULB] = "mulb",
	[IMULW] = "mulw",
	[IMULF] = "mulf",
	[IDIVB] = "divb",
	[IDIVW] = "divw",
	[IDIVF] = "divf",
	[IMODW] = "modw",
	[IMODB] = "modb",
	[IANDB] = "andb",
	[IANDW] = "andw",
	[IORB] = "orb",
	[IORW] = "orw",
	[IXORB] = "xorb",
	[IXORW] = "xorw",
	[ISHLB] = "shlb",
	[ISHLW] = "shlw",
	[ISHRB] = "shrb",
	[ISHRW] = "shrw",
	[IINSC] = "insc",
	[IINDC] = "indc",
	[IADDC] = "addc",
	[ILENC] = "lenc",
	[ILENA] = "lena",
	[ILENL] = "lenl",
	[IBEQB] = "beqb",
	[IBNEB] = "bneb",
	[IBLTB] = "bltb",
	[IBLEB] = "bleb",
	[IBGTB] = "bgtb",
	[IBGEB] = "bgeb",
	[IBEQW] = "beqw",
	[IBNEW] = "bnew",
	[IBLTW] = "bltw",
	[IBLEW] = "blew",
	[IBGTW] = "bgtw",
	[IBGEW] = "bgew",
	[IBEQF] = "beqf",
	[IBNEF] = "bnef",
	[IBLTF] = "bltf",
	[IBLEF] = "blef",
	[IBGTF] = "bgtf",
	[IBGEF] = "bgef",
	[IBEQC] = "beqc",
	[IBNEC] = "bnec",
	[IBLTC] = "bltc",
	[IBLEC] = "blec",
	[IBGTC] = "bgtc",
	[IBGEC] = "bgec",
	[ISLICEA] = "slicea",
	[ISLICELA] = "slicela",
	[ISLICEC] = "slicec",
	[IINDW] = "indw",
	[IINDF] = "indf",
	[IINDB] = "indb",
	[INEGF] = "negf",
	[IMOVL] = "movl",
	[IADDL] = "addl",
	[ISUBL] = "subl",
	[IDIVL] = "divl",
	[IMODL] = "modl",
	[IMULL] = "mull",
	[IANDL] = "andl",
	[IORL] = "orl",
	[IXORL] = "xorl",
	[ISHLL] = "shll",
	[ISHRL] = "shrl",
	[IBNEL] = "bnel",
	[IBLTL] = "bltl",
	[IBLEL] = "blel",
	[IBGTL] = "bgtl",
	[IBGEL] = "bgel",
	[IBEQL] = "beql",
	[ICVTLF] = "cvtlf",
	[ICVTFL] = "cvtfl",
	[ICVTLW] = "cvtlw",
	[ICVTWL] = "cvtwl",
	[ICVTLC] = "cvtlc",
	[ICVTCL] = "cvtcl",
	[IHEADL] = "headl",
	[ICONSL] = "consl",
	[INEWCL] = "newcl",
	[ICASEC] = "casec",
	[IINDL] = "indl",
	[IMOVPC] = "movpc",
	[ITCMP] = "tcmp",
	[IMNEWZ] = "mnewz",
	[ICVTRF] = "cvtrf",
	[ICVTFR] = "cvtfr",
	[ICVTWS] = "cvtws",
	[ICVTSW] = "cvtsw",
	[ILSRW] = "lsrw",
	[ILSRL] = "lsrl",
	[IECLR] = "eclr",
	[INEWZ] = "newz",
	[INEWAZ] = "newaz",
	[IRAISE] = "raise",
	[ICASEL] = "casel",
	[IMULX] = "mulx",
	[IDIVX] = "divx",
	[ICVTXX] = "cvtxx",
	[IMULX0] = "mulx0",
	[IDIVX0] = "divx0",
	[ICVTXX0] = "cvtxx0",
	[IMULX1] = "mulx1",
	[IDIVX1] = "divx1",
	[ICVTXX1] = "cvtxx1",
	[ICVTFX] = "cvtfx",
	[ICVTXF] = "cvtxf",
	[IEXPW] = "expw",
	[IEXPL] = "expl",
	[IEXPF] = "expf",
	[ISELF] = "self",
};

struct
{
	Lock	l;
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
	int	handoffs;	/* times the vm has been taken; vmwatch reads it */
	Proc*	holder;		/* who has the vm now, for vmwatch to name */
} isched;

/*
 * Rpcs retired rather than recycled by mntfree(); see devmnt.c.
 * vmwatch prints it so that a run can say whether that path was taken
 * at all -- a fix whose code never ran explains nothing.
 */
extern	int	mntretired;

/* Three places look at isched.vmq without holding isched.l, and all
 * three are deliberate: tready(), which Sleep() calls as its wakeup
 * condition while holding up->rlock and irend.l; the "someone wants the
 * VM, stop collecting" test in execatidle(); and the iyield() test in
 * vmachine().  None of the reads is load-bearing.  tready() is safe
 * because
 * every writer of vmq calls Wakeup(&isched.irend) *after* dropping
 * isched.l, and Wakeup and Sleep serialise on irend.l -- so Sleep
 * either sees the condition true or has registered itself before
 * releasing that lock, and the wakeup cannot be lost.  vmachine()'s
 * test is a heuristic whose only action is iyield(), which retakes
 * isched.l and rechecks.
 *
 * They are still racing reads of a word another thread writes, which is
 * undefined behaviour whatever the hardware does, and they were three
 * of the eleven signatures ThreadSanitizer reports (doc/dis-parallel-plan.ms
 * section 4).  Say so to the compiler rather than taking the lock:
 * taking isched.l inside a condition function already called under two
 * other locks would add a lock-order edge on the path every idle
 * transition runs through, to protect a value that is rechecked under
 * the lock a moment later anyway.
 */
#define	ISCHEDPEEK(f)	__atomic_load_n(&isched.f, __ATOMIC_RELAXED)
/* and the matching writes.  A relaxed load paired with a plain store is
 * still a data race -- the model needs both sides to be atomic, not one
 * -- so vmq's three writers say so too.  They all still hold isched.l,
 * which is what actually orders the handoff; this only tells the
 * compiler the word may be read concurrently, and costs nothing on any
 * machine emu runs on.  vmq is the whole of it: it is the only isched
 * field the tool ever caught being written under the lock and read
 * without it.
 */
#define	ISCHEDPOKE(p, v)	__atomic_store_n((p), (v), __ATOMIC_RELAXED)
/* and the same for the run queue, which moved to the execution context
 * in Phase 2 but is read by tready() from a thread that does not hold
 * the VM, exactly as before.
 */
#define	PCTXPEEK(f)	__atomic_load_n(&curP->f, __ATOMIC_RELAXED)

extern	int	bflag;
int	cflag = 1;	/* JIT on by default; -c0 selects interpreter */
uvlong	gcbusy;
uvlong	gcidle;
uvlong	gcidlepass;
uvlong	gcpartial;
int keepbroken = 1;
extern int	vflag;
static Prog*	proghash[64];

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
	return PCTXPEEK(runhd) != nil || ISCHEDPEEK(vmq) != nil;
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
		if(ISCHEDPEEK(vmq) != nil || curP->runhd != curP->runtl) {
			gcpartial++;
			break;
		}
		rungc(isched.head);
		gcidlepass++;
		if(((ulong)gcidlepass&0xFF) == 0)
			osyield();
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
	AINC(&h->ref);
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
	incref(&on->pgrp->r);
	incref(&on->fgrp->r);
	incref(&on->egrp->r);
	if(on->sigs != nil)
		incref(&on->sigs->r);
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
		DP("delprog p->pid %d msg %s p->exstr %s\n", p->pid, msg, p->exstr);
	else
		DP("delprog p->pid %d msg --%s--\n", p->pid, msg);
	tellsomeone(p, msg);	/* call before being removed from prog list */

	o = p->osenv;
	release();
	closepgrp(o->pgrp);
	closefgrp(o->fgrp);
	closeegrp(o->egrp);
	closesigs(o->sigs);
	acquire();

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

	if(p == curP->runhd) {
		curP->runhd = p->link;
		if(p->link == nil)
			curP->runtl = nil;
	}
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

	DP("tellsomeone pid %d buf %s\n", p->pid, buf);
	if(waserror())
		return;
	DP("tellsomeone after waserror() pid %d buf %s\n", p->pid, buf);
	o = p->osenv;
	if(o->childq != nil)
		qproduce(o->childq, buf, strlen(buf));
	if(o->waitq != nil) 
		qproduce(o->waitq, buf, strlen(buf)); 
	poperror();
}

static void
swiprog(Prog *p)
{
	Proc *q;

	lock(&procs.l);
	for(q = procs.head; q; q = q->next) {
		if(q->iprog == p) {
			unlock(&procs.l);
			swiproc(q, 1);
			return;
		}
	}
	unlock(&procs.l);
	/*print("didn't find\n");*/
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
	/* similar code to killprog but not quite */
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

	snprint(msg, sizeof(msg), "%d \"%s\":%s", p->pid, p->reg.M->m->name, cause);

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
	if(p->group != nil)
		g->flags |= p->group->flags&Pprivatemem;
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

	n = malloc(sizeof(Prog));
	if(n == nil)
		panic("no memory");
	p->prog = n;
	n->osenv = p->env;
}

static void
cwakeme(Prog *p)
{
	Osenv *o;

	p->addrun = nil;
	o = p->osenv;
	Wakeup(o->rend);
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
	Sleep(o->rend, cdone, p);
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

	prev = nil;
	for(f = curP->runhd; f; f = f->link) {
		if(f == p)
			break;
		prev = f;
	}
	if(f == nil)
		return;
	if(prev == nil)
		curP->runhd = p->link;
	else
		prev->link = p->link;
	if(p == curP->runtl)
		curP->runtl = prev;
}

Prog*
delruntail(int state)
{
	Prog *p;

	p = curP->runtl;
	delrunq(p);
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
		AINC(&t->ref);
		ml->MP = H2D(uchar*, h);
		newmp(ml->MP, m->origmp, t);
	}

	p = newprog(nil, ml);
	h = D2H(ml);
	ADEC(&h->ref);
	p->reg.PC = m->entry;
	/* newstack() below does memmove(p->reg.FP, f, f->t->size) - f->t is
	 * m->entryt here, the *complete* entry-frame type covering every
	 * local the module's init() declares, which is routinely far
	 * bigger than sizeof(Frame). A bare on-stack `Frame f` (as this
	 * used to be) is only ever big enough for the Frame header, so
	 * that copy read straight past it into whatever the caller's
	 * stack happened to hold - garbage into every local of every
	 * program's very first frame, on every single emu startup.
	 * initmem() right below only clears the pointer-typed slots (per
	 * the type's GC map); every plain int/byte/real local is left
	 * exactly as newstack's memmove set it. Allocate the real
	 * entry-frame size instead. */
	f = mallocz(m->entryt->size, 1);
	fp = f;
	R.s = &fp;
	f->t = m->entryt;
	newstack(p);
	free(f);
	initmem(m->entryt, p->reg.FP);

	return p;
}

/*
static char*
m(Prog *p)
{
	if(p)
		if(p->reg.M)
			if(p->reg.M->m)
				return p->reg.M->m->name;
	return "nil";
}
*/

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
			ISCHEDPOKE(&isched.vmq, up);
			empty = 1;
		}
		isched.vmqt = up;

		unlock(&isched.l);
		strcpy(up->text, "acquire");
		/* unconditional: iyield() takes a waiter off vmq without the
		 * VM thread returning to irend, so "somebody else is queued"
		 * does not mean "the VM thread has been told".  The comment
		 * above this function already asserts that EVERY writer of vmq
		 * wakes irend; this makes the code do it. */
		USED(empty);
		Wakeup(&isched.irend);
		osblock();
	}

	/*
	 * Getting here IS the handoff, by either path.
	 *
	 * AINC rather than ++: on a parallel VM two threads can leave
	 * acquire() at once, and a lost increment is exactly the input
	 * that makes vmwatch below cry stall when the VM was busy.  An
	 * instrument that cannot tell work from a stall is worse than
	 * none -- that mistake has already been made once here.
	 */
	AINC(&isched.handoffs);
	isched.holder = up;

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

	strcpy(up->text, "dis");
}

/*
 * Say so when the VM has stopped handing itself on.
 *
 * The styx server stops answering after a while: connections are
 * accepted, their first message is never read, and the process is at
 * 0% CPU with every exportfs slave asleep, one waiting to re-enter the
 * VM after a socket write, and one in acquire() -- with nobody running
 * to hold the lock they are waiting for.  Both this emu and the
 * raspi3b-port one do it, identically, so it is neither the per-request
 * worker rewrite nor parallelvm.
 *
 * It is invisible from outside and intermittent, which is the worst
 * combination to debug by hand: by the time anyone looks, the state
 * that would explain it has usually been restarted away.  This watches
 * for exactly the signature -- processes queued for the VM, the VM not
 * idle, and no handoff at all between two samples -- and prints the
 * scheduler's state once when it sees it.
 *
 * Cheap: one wakeup every five seconds and three loads under the lock,
 * and it says nothing at all while the VM is being handed on.
 *
 * KNOWN LIMITATION: holder is a hint, not evidence.  It is written
 * without the lock on the acquire() path and cleared in release() only
 * if it still names the caller, so under a parallel VM it can name a
 * thread that has already let go.  Read it as "this is who took it
 * last", and believe the queue and the counter, which are the
 * predicate.
 */
static void
vmwatch(void *a)
{
	int last, now;
	int stalled, said, lastretired, first;

	Proc *q, *h;

	USED(a);
	last = 0;
	said = 0;
	first = 1;
	lastretired = 0;
	for(;;){
		osmillisleep(5000);
		/*
		 * One line on the first sample, so that a silent run is
		 * evidence rather than an open question: it says the watcher
		 * is running and that its prints reach wherever the log goes.
		 * Without it, "mntretired never printed" could equally have
		 * meant the printing was broken -- and that ambiguity would
		 * have been read as a result.
		 */
		if(first){
			first = 0;
			print("dis: vmwatch running; handoffs %d mntretired %d\n",
				isched.handoffs, mntretired);
		}
		/*
		 * Say when mntfree() has retired a tag, whether or not
		 * anything is wrong.  Hanging that number off the stall
		 * report alone made it unreadable: the report only fires on a
		 * predicate this failure does not meet, so a run could not
		 * tell "the fix worked" from "the fix never ran".
		 */
		if(mntretired != lastretired){
			print("dis: mntretired %d\n", mntretired);
			lastretired = mntretired;
		}

		lock(&isched.l);
		now = isched.handoffs;
		q = isched.vmq;
		h = isched.holder;
		stalled = q != nil && isched.idle == 0 && now == last;
		last = now;
		unlock(&isched.l);
		if(!stalled){
			said = 0;
			continue;
		}
		if(said)
			continue;
		said = 1;
		/*
		 * Name the HOLDER, which is the whole question.
		 *
		 * The first firing of this printed only the waiters, and the
		 * holder had to be guessed at from a sampling profile -- which
		 * produced a confident wrong answer, because the stack that
		 * looked like the culprit occupied a tenth of the sample
		 * window and was merely passing through.  Whoever took the VM
		 * is recorded now, so the report says it instead of inviting
		 * an inference.
		 */
		print("dis: SCHEDULER STALLED: idle %d creating %d handoffs %d "
			"mntretired %d\n",
			isched.idle, isched.creating, now, mntretired);
		if(h != nil)
			print("dis:    the vm was last taken by %s pid %d\n",
				h->text, h->pid);
		else
			print("dis:    NOBODY holds the vm\n");
		for(; q != nil; q = q->qnext)
			print("dis:    waiting: %s pid %d\n", q->text, q->pid);
	}
}

void
release(void)
{
	Proc *p, **pq;
	int f;

	if(up->type == Interp)
		up->iprog = isave();
	else
		delrun(Prelease);

	lock(&isched.l);
	if(isched.holder == up)
		isched.holder = nil;
	if(*(pq = &isched.vmq) == nil && *(pq = &isched.idlevmq) == nil) {
		isched.idle = 1;
		f = isched.creating;
		isched.creating = 1;
		unlock(&isched.l);
		if(f == 0)
			kproc("dis", vmachine, nil, 0);
		return;
	}
	p = *pq;
	ISCHEDPOKE(pq, p->qnext);
	unlock(&isched.l);

	osready(p);		/* wake up thread to run VM */
	strcpy(up->text, "released");
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
	ISCHEDPOKE(&isched.vmq, p->qnext);

	if(up->iprog != nil)
		panic("iyield but iprog, type %d", up->type);
	if(up->type != Interp){
		static int once;
		if(!once++)
			print("tell charles: #%p->type==%d\n", up, up->type);
	}
	up->qnext = isched.idlevmq;
	isched.idlevmq = up;

	unlock(&isched.l);
	osready(p);		/* wake up acquiring kproc */
	strcpy(up->text, "yield");
	osblock();		/* sleep */
	strcpy(up->text, "dis");
	/*
	 * Resuming here IS a handoff.
	 *
	 * The counter used to be bumped only in acquire(), and this path
	 * never goes through it -- a thread parked on idlevmq is woken
	 * straight back into the VM loop.  So a perfectly busy server
	 * could show the counter frozen, and the stall detector above
	 * fired on it: a false alarm that was then read off a sampling
	 * profile as a root cause.  An instrument that cannot tell work
	 * from a stall produces exactly that.
	 */
	lock(&isched.l);
	isched.handoffs++;
	isched.holder = up;
	unlock(&isched.l);
}

void
startup(void)
{

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
	unlock(&isched.l);

	osblock();
	lock(&isched.l);		/* resuming is a handoff; see iyield */
	isched.handoffs++;
	isched.holder = up;
	unlock(&isched.l);
}

void
progexit(void)
{
	Prog *r;
	Module *m;
	int broken;
	char *estr, msg[ERRMAX+2*KNAMELEN];

	estr = up->env->errstr;
	broken = 0;
	DP("progexit estr %s\n", estr);
	if(estr[0] != '\0' && strcmp(estr, Eintr) != 0 && strncmp(estr, "fail:", 5) != 0)
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
		if(cflag){	/* only works on Plan9 for now */
			DP("progexit cflag set\n");
			char *pc = strstr(estr, "pc=");

			if(pc != nil)
				R.PC = r->reg.PC = (Inst*)strtol(pc+3, nil, 0);	/* for debugging */
		}
		print("[%s] Broken: pid %d \"%s\"\n", m->name, getpid(), estr);
	}

	if(r->exstr != nil)
		DP("progexit pid %d name %s estr %s exval %p exstr %s\n",
			r->pid, m->name, estr, r->exval, r->exstr);
	else
		DP("progexit pid %d name %s estr %s exval %p\n",
			r->pid, m->name, estr, r->exval);
	// sh.b is matching on fail: not on "<pid> fail: "
	snprint(msg, sizeof(msg), "%d \"%s\":%s", r->pid, m->name, estr);
	// snprint(msg, sizeof(msg), "%s", estr);
	DP("progexit msg %s\n", msg);

	if(up->env->debug != nil) {
		DP("progexit debug set\n");
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

	if(isched.head == nil)
		cleanexit(0);
}

void
disfault(void *reg, char *msg)
{
	Prog *p;

	USED(reg);

	if(strncmp(msg, Eintr, 6) == 0)
		exits(0);

	if(up == nil) {
		print("EMU: faults: %s\n", msg);
		cleanexit(0);
	}
	if(up->type != Interp) {
		print("SYS: process %s faults: %s\n", up->text, msg);
		cleanexit(0);
	}

	if(up->iprog != nil)
		acquire();

	p = currun();
	if(p == nil)
		panic("Interp faults with no dis prog");

	/* Which Dis instruction was executing, and where (interpreted mode
	 * only - in compiled/JIT mode R.PC is a native code address, not an
	 * Inst*, so printing op/operands off it would just be another wild
	 * read). This is what actually distinguishes "a send instruction's
	 * channel operand is nil" from "an alt statement's channel operand
	 * is nil" from every other op that checks for a nil ref - the
	 * one-line message and even the call stack below don't, since
	 * several different ops share the same source line/PC bucketing.
	 *
	 * Deliberately the GLOBAL R here, not p->reg: xec() only writes
	 * p->reg = R back on a *normal* quantum exit (falls off the bottom
	 * of the do-while, or blocks cleanly). A mid-instruction native
	 * fault skips that entirely, so p->reg is stale - frozen at wherever
	 * this proc's *previous* quantum happened to end, which is
	 * whatever instruction the scheduler last preempted it at, not
	 * where it just crashed. The live global R (xec.c) is what the
	 * interpreter was actually touching when the signal hit, on this
	 * same thread, synchronously - that's the real fault site. */
	if(!R.M->compiled && R.PC != nil){
		int op;
		char *opn;

		op = R.PC->op;
		opn = (op >= 0 && op < MAXDIS && opnames[op] != nil)? opnames[op]: "?";
		print("disfault: %s at %s+%ld (s=%ld d=%ld)\n",
			opn, R.M->m->path,
			(long)(R.PC - R.M->prog),
			(long)R.PC->s.ind, (long)R.PC->d.ind);
	}

	/* Print the Dis-level call stack at fault time: which module/pc was
	 * running and what called it. Without this, a native fault (segv,
	 * bad address) or an "array bounds"/"dereference of nil" trap only
	 * ever reports a one-line message with no indication of where in
	 * the Limbo source it happened - previously the only way to find
	 * that out was reading /prog/pid/stack before the broken prog got
	 * cleaned up (if it did at all), or attaching a native debugger.
	 * Also the live global R, for the same staleness reason as above. */
	{
		char stackbuf[4096];
		int n;

		n = progstack(&R, p->state, stackbuf, sizeof(stackbuf)-1, 0);
		if(n > 0){
			stackbuf[n] = '\0';
			print("disfault: %s\nstack:\n%s", msg, stackbuf);
		}
	}

	/* cause an exception in the dis prog.  As for error(), but Plan 9 needs reg*/
	kstrcpy(up->env->errstr, msg, ERRMAX);
	print("disfault: %s\n", msg);
	oslongjmp(reg, up->estack[--up->nerr], 1);
}

void
vmachine(void *a)
{
	Prog *r;
	Osenv *o;
	int cycles;
	static int gccounter;

	USED(a);

	startup();

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
		if(up->iprog != nil)
			acquire();
		if(handler(up->env->errstr) == 0) {
			propex(currun(), up->env->errstr);
			progexit();
		}
		up->env = &up->defenv;
	}

	/* GC-LOCK HISTORY: r->xec(r) below runs with no lock held, and
	 * multiple vmachine kprocs (spun up by release() whenever a proc
	 * blocks on native I/O) each independently pull procs off
	 * curP->runhd and call xec() in parallel - genuine concurrent
	 * execution, not hypothetical. libinterp/heap.c's destroy() used to
	 * decrement refcounts with a plain, non-atomic `--h->ref`, so two
	 * threads decrementing the same object's refcount at once was a
	 * lost-update race -> could hit 0 twice -> double free. Root-caused
	 * via a resize-triggered wm.dis crash that persisted even after
	 * fixing the specific Limbo-level race it looked like (see
	 * appl/wm/wm.b's pendingsnapslock and git log for that
	 * investigation).
	 *
	 * First attempt was a single global lock (dislock) around Dis
	 * execution - taken at the end of acquire(), dropped at the start
	 * of release(), plus wrapped directly around this r->xec(r) call.
	 * REVERTED: it deadlocked basic multi-command shell usage
	 * (`sh -c 'echo a; echo b'` - only "a" ever printed). Cause: proc
	 * termination/error handling in this VM unwinds via longjmp
	 * (waserror()/nexterror()), which jumps straight back to
	 * vmachine()'s own `while(waserror())` recovery block at the top of
	 * this function, skipping right over the paired unlock() - leaving
	 * the lock held by nobody forever.
	 *
	 * Fixed instead with atomics: every genuinely-shared ->ref++/--
	 * site across heap.c, xec.c, draw.c, tk.c, loader.c, keyring.c,
	 * link.c, load.c, string.c, runt.c, crypt.c, and the emu/port
	 * files that touch Limbo heap objects (devdraw.c, exception.c,
	 * dis.c, devprog.c, devsrv.c, srv.c) now goes through AINC()/ADEC()
	 * (see include/interp.h / emu/port/dat.h - __atomic_fetch_add /
	 * __atomic_sub_fetch). No held state, so no longjmp-skips-the-
	 * unlock failure mode - each op is a single indivisible instruction.
	 * emu/port/{chan,devpipe,devssl,devsrv,exportfs,pgrp}.c's own
	 * device-level refcounts were already protected by an existing
	 * lock (verified per-site) and were left alone.
	 *
	 * REMAINING GAP: this only covers the interpreted (-c0) path.
	 * libinterp/comp-arm64.c - the JIT backend, which is what actually
	 * runs by default (cflag=1, i.e. -c1) - emits plain, non-atomic
	 * load/modify/store machine code for the same h->ref field (see
	 * its OHeap,ref) mem() calls). That's a separate, harder,
	 * architecture-specific fix (would need LSE atomic instructions or
	 * a CAS-retry sequence in the generated code) and is NOT done.
	 * Everything in this investigation was validated with -c0. See
	 * memory inferno-rio-gc-lock-todo for the full writeup. */
	cycles = 0;
	for(;;) {
		if(tready(nil) == 0) {
			execatidle();
			strcpy(up->text, "idle");
			Sleep(&isched.irend, tready, 0);
			strcpy(up->text, "dis");
		}

		if(ISCHEDPEEK(vmq) != nil && (curP->runhd == nil || ++cycles > 2)){
			iyield();
			cycles = 0;
		}

		r = curP->runhd;
		if(r != nil) {
			o = r->osenv;
			up->env = o;

			FPrestore(&o->fpu);
			r->xec(r);
			FPsave(&o->fpu);

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
		if(curP->runhd != nil)
		if((++gccounter&0xFF) == 0 || memlow()) {
			gcbusy++;
			up->type = BusyGC;
			pushrun(up->prog);
			rungc(isched.head);
			up->type = Interp;
			delrunq(up->prog);
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

	if(waserror())
		panic("disinit error: %r");

	if(vflag)
		print("Initial Dis: \"%s\"\n", initmod);

	kproc("vmwatch", vmwatch, nil, 0);

	fmtinstall('D', Dconv);

	FPinit();
	FPsave(&up->env->fpu);

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
	incref(&o->pgrp->r);
	incref(&o->fgrp->r);
	incref(&o->egrp->r);
	if(o->sigs != nil)
		incref(&o->sigs->r);
	o->user = nil;
	kstrdup(&o->user, up->env->user);
	o->errstr = o->errbuf0;
	o->syserrstr = o->errbuf1;

	isched.idle = 1;
	poperror();
	vmachine(nil);
}

void
pushrun(Prog *p)
{
	if(p->addrun != nil)
		panic("pushrun addrun");
	p->state = Pready;
	p->link = curP->runhd;
	curP->runhd = p;
	if(p->link == nil)
		curP->runtl = p;
}

/*
 * The kernel's channel region; see chanlock() in os/inferno/port/dis.c.
 * emu runs one Dis interpreter at a time behind its own VM lock, so a
 * channel operation is already atomic here and these are the identity.
 * chandefer stays nil, so destroy() frees channels exactly as it did.
 */
void
chanlock(void)
{
}

void
chanunlock(void)
{
}
