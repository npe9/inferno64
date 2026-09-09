/*
 * Processes for the library operating system.
 *
 * The plan's third arrangement got as far as running one program at a
 * time: the personality loaded a binary beside itself and called it, and
 * the program's open and read were calls, not traps.  A shell wants more
 * than that.  It wants to start a program and go on running, to start a
 * second one with a pipe between them, and to wait for both.
 *
 * fork is not what a library operating system can offer.  rfork(RFPROC)
 * splits a flow of control inside one address space, and a library
 * cannot split its caller's C stack without copying it, pointers into it
 * and all.  So this does not pretend to have fork: the primitive is the
 * one a shell actually wanted fork and exec for, fused.  spawn loads a
 * program, gives it a flow of control of its own - a kproc of the
 * personality's cooperative scheduler - and a descriptor table of its
 * own holding only the descriptors it was handed, and answers with a
 * number.  wait blocks until that number ends and yields its status.
 *
 * What a spawned program gets that the personality's own kprocs do not:
 *
 *   - its own Fgrp.  kproc() shares the creating proc's descriptor
 *     table by pointer, which is right for the stack's read kprocs and
 *     wrong for a program: a program closes descriptors, and a pipeline
 *     only sees end of file because each end is closed by everyone who
 *     is not using it.  So the child's table is built empty (dupfgrp of
 *     nil) and only what spawn was given is put in it.
 *   - its own exit.  A program the personality runs to completion ends
 *     by longjmp back into p9exec; a spawned one ends by ending its
 *     kproc.  p9anyexits decides which from the flow of control it is
 *     called on, so both kinds of program are handed the same table.
 *
 * The name space is shared, as it is between any two processes of one
 * Plan 9 process group, and so is the address space - this is one task
 * to the microkernel, and that is the arrangement, not a shortcoming of
 * it.  Two of the same program cannot run at once: a program is at the
 * address it was linked for and there is no relocation here, so both
 * would be the one image.  spawn refuses that.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"p9lib.h"
#include	"p9file.h"

extern int	p9load(char *name, uvlong *entryp, uvlong *basep);
extern int	p9loadreloc(char *name, uvlong progbase, uvlong *entryp, uvlong *basep);
extern int	p9isreloc(char *name);
extern P9lib*	p9libtable(void);
extern void	p9execexits(char *status);

enum {
	Nproc9	= 16,		/* programs alive at once */
	Nargv	= 16,		/* words in a program's argument vector */
	Nargbuf	= 512,		/* bytes of them */
};

typedef struct Proc9 Proc9;
struct Proc9 {
	int	used;		/* the slot is taken (a live or unwaited program) */
	int	live;		/* it has not ended yet */
	int	done;		/* it has ended; the sleep condition */
	int	pid;
	uvlong	base;		/* the image it is running in */
	uvlong	entry;
	Proc	*p;		/* the kproc it runs on, while it runs */
	Pgrp	*pgrp;		/* a name space of its own, if it asked for one */
	Fgrp	*fgrp;		/* its own descriptor table */
	int	std[3];		/* its numbers for its standard descriptors */
	int	inproc;		/* a second flow of control inside a program already running */
	int	slot;		/* the relocation slot it was laid in, or -1 */
	void	(*fn)(void*);	/* what it runs, when it is one of those */
	void	*arg;
	char	name[64];
	char	status[ERRMAX];
	char	*argv[Nargv];
	char	argbuf[Nargbuf];
	Rendez	r;
};

static Proc9 proc9[Nproc9];
static int p9nextpid = 100;	/* clear of the scheduler's own kproc pids */

/*
 * Is the image at this base already running?  p9exec asks before running
 * a program on its own flow of control, and spawn asks before starting
 * one.
 */
int
p9procbusy(uvlong base)
{
	int i;

	for(i = 0; i < Nproc9; i++)
		if(proc9[i].used && proc9[i].live && proc9[i].base == base)
			return 1;
	return 0;
}

/*
 * Where a relocatable module is laid.
 *
 * A program with a fixed base is its address: p9load refuses a second
 * instance because the two would be one image sharing one data segment.
 * A module has no address, so what it needs is not a name but a free
 * slot, and giving the slot back when the program ends is what lets the
 * next one have it.  That is the whole of the difference, and it is why
 * two of one module can run at once.
 */
static int relocslot[Nrelocslot];

int
p9relocalloc(void)
{
	int i;

	for(i = 0; i < Nrelocslot; i++)
		if(!relocslot[i]){
			relocslot[i] = 1;
			return i;
		}
	return -1;
}

/*
 * Take one slot by number rather than the first free one.  p9execreloc
 * is told which slot to lay a module in - it is the demonstration that
 * one image runs at two addresses - and naming a slot without telling
 * the allocator would leave it free to be handed to something else.
 * Nothing does that today, because those runs are sequential and
 * nothing else is loading; it is closed because the allocator is the
 * mechanism being claimed, and a mechanism with a way round it is not
 * the mechanism.
 */
int
p9relocclaim(int slot)
{
	if(slot < 0 || slot >= Nrelocslot || relocslot[slot])
		return -1;
	relocslot[slot] = 1;
	return slot;
}

void
p9relocfree(int slot)
{
	if(slot >= 0 && slot < Nrelocslot)
		relocslot[slot] = 0;
}

uvlong
p9relocaddr(int slot)
{
	return (uvlong)P9relocbase + (uvlong)slot * P9relocslot;
}

/* the slot an address is, or -1 if it is not one */
int
p9relocslotof(uvlong progbase)
{
	uvlong off;

	if(progbase < (uvlong)P9relocbase)
		return -1;
	off = progbase - (uvlong)P9relocbase;
	if(off % P9relocslot != 0 || off / P9relocslot >= Nrelocslot)
		return -1;
	return (int)(off / P9relocslot);
}

static Proc9*
procof(Proc *p)
{
	int i;

	for(i = 0; i < Nproc9; i++)
		if(proc9[i].used && proc9[i].live && proc9[i].p == p)
			return &proc9[i];
	return nil;
}

/*
 * rfork(2), the name-space half of it.
 *
 * Every flow of control here shares the personality's Pgrp by pointer -
 * kproc hands its child up->pgrp and nothing increments a count - so a
 * program that binds binds the library's own name space.  That is what
 * a library operating system is, and it is what Plan 9 gives a process
 * a way out of: RFNAMEG is a copy of the name space to change on its
 * own, RFCNAMEG an empty one.
 *
 * Only those two bits are answered.  The rest of rfork is about things
 * this arrangement does not have or does not share:
 * .  RFPROC would split a flow of control, which a library cannot do to
 *    its caller's C stack - spawn and proccreate are what there is.
 * .  RFMEM and RFNOMNT ask about an address space that is one address
 *    space.
 * .  RFFDG is what spawn already gives every program it starts.
 * A caller that asks for one of them is told no, by name, rather than
 * being handed a success that did nothing - which is exactly the shape
 * of error that would show up later as a program quietly sharing what
 * it asked not to share.
 */
int
p9forkns(int flags)
{
	Proc9 *t;
	Pgrp *ng, *old;
	int other;

	other = flags & ~(RFNAMEG|RFCNAMEG);
	if(other != 0){
		snprint(up->genbuf, sizeof up->genbuf,
			"rfork %#x: this personality answers RFNAMEG and RFCNAMEG only", flags);
		kstrcpy(up->errstr, up->genbuf, ERRMAX);
		return -1;
	}
	if((flags & (RFNAMEG|RFCNAMEG)) == 0)
		return 0;			/* nothing asked for is nothing to do */
	if((flags & RFNAMEG) != 0 && (flags & RFCNAMEG) != 0){
		kstrcpy(up->errstr, "rfork: RFNAMEG and RFCNAMEG are not both", ERRMAX);
		return -1;
	}
	ng = newpgrp();
	if(ng == nil){
		kstrcpy(up->errstr, "rfork: no name space to give", ERRMAX);
		return -1;
	}
	if((flags & RFNAMEG) != 0)
		pgrpcpy(ng, up->pgrp);
	/*
	 * The old one is not closed.  It is the personality's, held by every
	 * flow of control by pointer with no count between them, so closing
	 * it here would take the library's name space away from the library.
	 * A Pgrp this program made for itself is a different matter, and
	 * procdone closes that one.
	 */
	old = up->pgrp;
	USED(old);
	up->pgrp = ng;
	t = procof(up);
	if(t != nil){
		if(t->pgrp != nil)
			closepgrp(t->pgrp);	/* a second rfork replaces the first */
		t->pgrp = ng;
	}
	return 0;
}


/*
 * Copy the argument vector into the slot's own storage: the caller's is
 * on a stack the program is about to stop using.
 */
static int
copyargv(Proc9 *t, char *name, char **argv)
{
	char *p, *e;
	int n, i;

	p = t->argbuf;
	e = t->argbuf + sizeof t->argbuf;
	n = 0;
	if(argv == nil || argv[0] == nil){
		t->argv[0] = name;	/* the slot's own name, below */
		t->argv[1] = nil;
		return 0;
	}
	for(i = 0; argv[i] != nil; i++){
		if(n >= Nargv-1)
			return -1;
		if(p + strlen(argv[i]) + 1 > e)
			return -1;
		strcpy(p, argv[i]);
		t->argv[n++] = p;
		p += strlen(p) + 1;
	}
	t->argv[n] = nil;
	return 0;
}

/*
 * The child's descriptor table.  It is empty except for what std names,
 * and those are the caller's descriptors, referenced again - so the
 * caller closing its own copy does not take the child's away, and the
 * child holds no copy of the pipe ends it was not given, which is what
 * lets a pipeline reach end of file.
 *
 * newfd and fdtochan work on up->fgrp, so the new table is put there for
 * the length of the call.  Nothing between the two assignments sleeps -
 * on this cooperative scheduler that is the whole of what makes it safe
 * - and the caller's table is back before anything else can run.
 */
static int
givefds(Proc9 *t, int *std)
{
	Fgrp *nf, *mine;
	Chan *c;
	int i;

	mine = up->fgrp;			/* the caller's, to be put back */
	nf = dupfgrp(nil);
	if(waserror()){
		/* newfd can raise with the new table in place: put the
		 * caller's back before closing the one being given up */
		up->fgrp = nf;
		closefgrp(nf);
		up->fgrp = mine;
		return -1;
	}
	for(i = 0; i < 3; i++){
		t->std[i] = -1;
		if(std == nil || std[i] < 0)
			continue;
		c = fdtochan(std[i], -1, 0, 1);		/* referenced */
		up->fgrp = nf;
		t->std[i] = newfd(c, c->mode);
		up->fgrp = mine;
		if(t->std[i] < 0){
			cclose(c);
			error(Enofd);
		}
	}
	poperror();
	t->fgrp = nf;
	return 0;
}

/*
 * A spawned program has ended: its descriptors go, its status is kept
 * for the wait that will ask, and whoever is waiting is woken.
 */
static void
procdone(Proc9 *t, char *status)
{
	Fgrp *f;

	strncpy(t->status, status == nil ? "" : status, sizeof t->status - 1);
	t->status[sizeof t->status - 1] = 0;
	f = t->fgrp;
	t->fgrp = nil;
	if(f != nil){
		up->fgrp = f;
		closefgrp(f);
		up->fgrp = nil;
	}
	t->live = 0;
	t->done = 1;
	if(t->slot >= 0){
		p9relocfree(t->slot);
		t->slot = -1;
	}
	/*
	 * And a name space it made for itself, which nothing else holds: the
	 * one it was given is the personality's and stays.
	 */
	if(t->pgrp != nil){
		closepgrp(t->pgrp);
		t->pgrp = nil;
	}
	wakeup(&t->r);
}

/*
 * A spawned program runs here.  The waserror is not decoration: a fresh
 * kproc has no error label of its own, and the personality's entry
 * points do raise - a write into a pipe whose reader has gone is an
 * error, not a short count, and p9write's own handler ends in
 * nexterror().  Without a label here that raise would unwind off the top
 * of this stack into nothing.  With one, a program whose call into the
 * personality failed ends with the error as its status, which is what a
 * wait is for.
 *
 * There are three ways out of a loaded program, then: a raise, caught
 * here; a call to exits from a spawned one, which ends its kproc; and a
 * call to exits from one the personality is running to completion, which
 * jumps back into p9exec.  p9anyexits tells the last two apart.
 */
static void
procstart(void *a)
{
	Proc9 *t;

	t = a;
	t->p = up;
	up->fgrp = t->fgrp;
	strncpy(up->text, t->name, sizeof up->text - 1);
	if(waserror()){
		print("p9 spawn: %s (%d) failed: %s\n", t->name, t->pid, up->errstr);
		procdone(t, up->errstr);
		return;			/* kproc's launch pexits from here */
	}
	((void(*)(P9lib*, char**, int*))(uintptr)t->entry)(p9libtable(), t->argv, t->std);
	poperror();
	procdone(t, "");
	/* kproc's launch pexits from here */
}

/*
 * exits, for whichever kind of program called it.  A spawned one ends
 * its kproc; one the personality is running to completion jumps back
 * into the frame p9exec left.  The table hands both the same pointer.
 */
void
p9anyexits(char *status)
{
	Proc9 *t;

	t = procof(up);
	if(t == nil){
		p9execexits(status);
		return;			/* not reached */
	}
	procdone(t, status);
	pexit("program exited", 1);
}

/*
 * Start a program.  std[0..2] are the caller's descriptors for the
 * program's standard input, output and error, or -1 for the machine's
 * console.  Answers a number wait takes, or -1.
 */
int
p9spawn(char *name, char **argv, int *std)
{
	Proc9 *t;
	uvlong entry, base;
	int i;

	t = nil;
	for(i = 0; i < Nproc9; i++)
		if(!proc9[i].used){
			t = &proc9[i];
			break;
		}
	if(t == nil){
		print("p9 spawn: %s: no free process slot\n", name);
		return -1;
	}
	memset(t, 0, sizeof *t);
	strncpy(t->name, name, sizeof t->name - 1);
	if(copyargv(t, t->name, argv) < 0){
		print("p9 spawn: %s: argument vector too long\n", name);
		return -1;
	}
	/*
	 * A module is laid in a slot of its own, which is what lets this
	 * be the second copy of a program that is already running.  An
	 * ordinary program is laid at its own address, and p9load refuses
	 * a second instance of it.
	 */
	t->slot = -1;
	if(p9isreloc(name)){
		t->slot = p9relocalloc();
		if(t->slot < 0){
			print("p9 spawn: %s: all %d relocation slots are taken\n", name, Nrelocslot);
			return -1;
		}
		if(p9loadreloc(name, p9relocaddr(t->slot), &entry, &base) < 0){
			p9relocfree(t->slot);
			return -1;
		}
	} else if(p9load(name, &entry, &base) < 0)	/* it refuses an image already running */
		return -1;
	t->entry = entry;
	t->base = base;
	if(givefds(t, std) < 0){
		print("p9 spawn: %s: cannot give it its descriptors\n", name);
		return -1;
	}
	t->pid = ++p9nextpid;
	t->used = 1;
	t->live = 1;
	t->done = 0;
	print("p9 spawn: %s runs as %d at %#llux, with its own descriptor table (%d %d %d)\n",
		name, t->pid, base, t->std[0], t->std[1], t->std[2]);
	kproc(t->name, procstart, t);
	return t->pid;
}

/*
 * A second flow of control inside a program that is already running.
 *
 * This is what a library operating system has instead of
 * rfork(RFPROC|RFMEM): the memory is shared because there is one address
 * space and nothing to share or not share, and what is new is only the
 * flow of control - a kproc of the cooperative scheduler, with a stack
 * of its own and the private words of its own that the scheduler swaps.
 * The descriptor table is the creating proc's, by pointer, which is what
 * rfork without RFFDG means.
 *
 * It differs from spawn in what it does not do: nothing is loaded, no
 * image is claimed, and no descriptor table is built.  The base stays 0
 * so that p9procbusy, which is asking whether an image is in use, does
 * not count these - the image is in use, and the program running in it
 * is the one that asked for this.
 *
 * libthread's proccreate is the caller, through _schedfork.
 */
static void
inprocstart(void *a)
{
	Proc9 *t;

	t = a;
	t->p = up;
	strncpy(up->text, t->name, sizeof up->text - 1);
	if(waserror()){
		print("p9 proccreate: %s (%d) failed: %s\n", t->name, t->pid, up->errstr);
		procdone(t, up->errstr);
		return;			/* kproc's launch pexits from here */
	}
	t->fn(t->arg);
	poperror();
	procdone(t, "");
	/* kproc's launch pexits from here */
}

int
p9proccreate(void (*f)(void*), void *arg)
{
	Proc9 *t;
	int i;

	t = nil;
	for(i = 0; i < Nproc9; i++)
		if(!proc9[i].used){
			t = &proc9[i];
			break;
		}
	if(t == nil){
		print("p9 proccreate: no free process slot\n");
		return -1;
	}
	memset(t, 0, sizeof *t);
	strncpy(t->name, up->text, sizeof t->name - 1);
	t->inproc = 1;
	t->fn = f;
	t->arg = arg;
	t->fgrp = nil;			/* shared with the creator: procdone must not close it */
	t->base = 0;
	t->slot = -1;
	t->pid = ++p9nextpid;
	t->used = 1;
	t->live = 1;
	t->done = 0;
	print("p9 proccreate: %s gets a second flow of control as %d, sharing its memory and its descriptors\n",
		t->name, t->pid);
	kproc(t->name, inprocstart, t);
	return t->pid;
}

/*
 * Wait for the flows of control a program made for itself.  p9exec calls
 * this when the program it entered has returned: the program's own stack
 * is done with, but a proc it made is still running in its image, and
 * the personality must not go on to load something else over it.
 *
 * It waits by tsleep and not by sched, and the difference is the whole
 * of it.  sched only advances the cooperative clock when the run queue
 * is empty, and a loop that calls sched puts itself back on that queue
 * every time round - so a proc still in a tsleep of its own would never
 * see its deadline pass, and the two would wait for each other for good.
 * A tsleep here leaves the queue, which lets the queue empty, which lets
 * the clock move.
 */
void
p9procwaitinproc(void)
{
	int i, n;

	for(;;){
		n = 0;
		for(i = 0; i < Nproc9; i++)
			if(proc9[i].used && proc9[i].live && proc9[i].inproc)
				n++;
		if(n == 0)
			break;
		tsleep(&up->sleep, return0, nil, 10);
	}
	for(i = 0; i < Nproc9; i++)
		if(proc9[i].used && proc9[i].inproc)
			proc9[i].used = 0;	/* nothing waits for these by number */
}

static int
isdone(void *a)
{
	return ((Proc9*)a)->done;
}

/*
 * Wait for a spawned program.  Answers its number, or -1 if there is no
 * such program; the status it exited with is copied out.
 */
int
p9waitpid(int pid, char *status, int nstatus)
{
	Proc9 *t;
	int i;

	t = nil;
	for(i = 0; i < Nproc9; i++)
		if(proc9[i].used && proc9[i].pid == pid){
			t = &proc9[i];
			break;
		}
	if(t == nil)
		return -1;
	ksleep(&t->r, isdone, t);
	if(status != nil && nstatus > 0){
		strncpy(status, t->status, nstatus - 1);
		status[nstatus - 1] = 0;
	}
	t->used = 0;			/* the slot is free again */
	return pid;
}
