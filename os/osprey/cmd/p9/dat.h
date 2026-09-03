#include "nsdat.h"
enum { NERR = 32 };
enum { Dead = 0, Ready, Running, Wakeme };	/* p->state for the cooperative scheduler (p9sched.c) */
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
	void (*kpfun)(void*);		/* kproc entry */
	void *kparg;
	void *kstack;			/* base of this proc's stack */
};
typedef struct Ospreybuddyseg	Ospreybuddyseg;	/* the kernel-side layout record portfns.h names; unused here */
typedef struct Conf Conf;
struct Conf { ulong pipeqsize; ulong npage; };
extern Conf conf;
extern Proc *up;
