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
	Fgrp	*fgrp;		/* its own descriptor table */
	int	std[3];		/* its numbers for its standard descriptors */
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
	if(p9load(name, &entry, &base) < 0)	/* it refuses an image already running */
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
