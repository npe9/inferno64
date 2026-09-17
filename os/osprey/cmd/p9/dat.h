#include "nsdat.h"
enum { NERR = 32 };
enum { Dead = 0, Ready, Running, Wakeme };	/* p->state for the cooperative scheduler (p9sched.c) */
/*
 * Per-process private words.  privalloc(2) hands a program one word that
 * has to answer differently to each of its flows of control, and
 * libthread's _threadgetproc is a dereference of one fixed pointer
 * captured once in main - so the word cannot be found from the running
 * proc at the time of the call.  It is a fixed address whose contents
 * the scheduler swaps at the switch, the way a kernel swaps a
 * per-process register, and this is where the outgoing proc's copy
 * lives.  Eight is what libthread wants one of.
 */
enum { Nprivwords = 8 };
struct Proc {
	Pgrp *pgrp; Egrp *egrp; Fgrp *fgrp; Chan *dot; Chan *slash; Fgrp *closingfgrp;
	char *user; int procctl; char genbuf[128];
	char *errstr; char *syserrstr;
	int nerrlab; jmp_buf errlab[NERR];
	int nnote; int pid; char text[32]; Rendez sleep; int priority;
	/* cooperative scheduler (p9sched.c) */
	Label sched;			/* where to resume this proc */
	int state;			/* Dead/Ready/Running/Wakeme */
	Proc *rnext;			/* run-queue link */
	Rendez *rendez;			/* the Rendez this proc is asleep on */
	ulong twhen;			/* tsleep deadline in ticks, 0 if untimed */
	void (*kpfun)(void*);		/* kproc entry */
	void *kparg;
	void *kstack;			/* base of this proc's stack */
	void *priv[Nprivwords];		/* this proc's copy of the private words */
};
typedef struct Ospreybuddyseg	Ospreybuddyseg;	/* the kernel-side layout record portfns.h names; unused here */
typedef struct Conf Conf;
struct Conf { ulong pipeqsize; ulong npage; };
extern Conf conf;
extern Proc *up;
