/*
 * libthread's porting layer, for a program the library operating system
 * loaded.
 *
 * libthread is written to be ported.  Everything about threads,
 * channels and the scheduler inside a process is machine- and
 * system-independent; what it needs from the system underneath is four
 * functions and an entry point, and 9front keeps them by themselves in
 * libthread/main.c.  This is that file for this personality, and the
 * rest of libthread is linked from source with no line changed.
 *
 * What is different here, and why:
 *
 *	- No rfork(RFREND).  A rendezvous group is a kernel thing, and
 *	  libthread's own rendezvous - the one _qlockinit installs - is
 *	  entirely in user space (rendez.c): it never makes the system
 *	  call.  So there is no group to leave.
 *
 *	- No notify(_threadnote).  The personality raises no notes on a
 *	  program it loaded, so a handler would be one that could never
 *	  be called.  Leaving the call out is also what keeps note.c off
 *	  the link and notify(2) - which would be a trap - unreferenced.
 *
 *	- No setjmp(mainjmp).  On Plan 9 a new proc is made by
 *	  rfork(RFPROC|RFMEM), whose child gets a copy of the stack at
 *	  the same addresses, so the child can longjmp to a buffer the
 *	  parent saved and land on its own stack.  Two stacks cannot be
 *	  at one address here, so a new proc is started at a function
 *	  instead, and nothing longjmps between procs.
 */
#include <u.h>
#include <libc.h>
#include <thread.h>
#include "threadimpl.h"

extern void (*_sysfatal)(char*, va_list);
extern void (*__assert)(char*);

int	mainstacksize;
static int mainargc;

static void
mainlauncher(void *arg)
{
	threadmain(mainargc, arg);
	threadexits("threadmain");
}

void
main(int argc, char **argv)
{
	_threadprocp = privalloc();
	_qlockinit(_threadrendezvous);
	_sysfatal = _threadsysfatal;
	__assert = _threadassert;
	if(mainstacksize == 0)
		mainstacksize = 8*1024;
	mainargc = argc;
	_threadsetproc(_newproc(mainlauncher, argv, mainstacksize, "threadmain", 0, 0));
	_schedinit();
	abort();	/* not reached: _schedinit ends in _schedexit */
}

/*
 * The loader enters a program at startboot with its argument vector
 * (p9crt.c); libthread's world begins at main.
 */
void
startboot(char *argv0, char **argv)
{
	int argc;

	USED(argv0);
	for(argc = 0; argv[argc] != nil; argc++)
		;
	main(argc, argv);
}

/*
 * procexec, which is fork and exec, and here is spawn.
 *
 * A library operating system has no exec of its own: a program is at
 * the address the loader put it at, and there is nothing to replace an
 * address space with when the library lives in the same one.  But
 * libthread does not ask for exec on its own account.  It asks in
 * _schedexec, which on Plan 9 rforks and execs in the child and answers
 * the parent with the child's pid - fork and exec, fused, which is
 * exactly what the personality's spawn is.
 *
 * So this is not a stub standing in for exec.  It is the same operation
 * libthread was asking for, done by the primitive this system has, and
 * the difference is invisible to the caller: procexec gets a pid back,
 * the program runs, and procexec's own wait finds it.
 *
 * The descriptors are 0, 1 and 2 of the proc that called, which is what
 * exec would have carried across.  A program started in a rio window
 * reads and writes and complains to that window.
 *
 * The pipe is libthread's own way of telling an exec that failed from
 * one that worked: procexec holds the read end and the write end is
 * close-on-exec, so a successful exec closes it and the read gets end
 * of file.  Nothing execs here, and the spawned program is given only
 * the three descriptors above, so it does not hold the write end either
 * - which comes to the same thing.  procexec closes its own copy after
 * this returns and reads end of file, exactly as it would have.
 */
int
_schedexec(Execargs *e)
{
	extern int spawn3(char*, char**, int, int, int);
	char err[ERRMAX], msg[ERRMAX+64];
	int pid, k;

	pid = spawn3(e->prog, e->args, 0, 1, 2);
	if(pid < 0){
		err[0] = 0;
		errstr(err, sizeof err);
		if(err[0] == 0)
			strcpy(err, "cannot start it");
		k = snprint(msg, sizeof msg, "%s: %s", e->prog, err);
		write(e->fd[1], msg, k);
		return -1;
	}
	return pid;
}

/*
 * And the wait that follows it.  libthread's own reads Waitmsgs until
 * the pid matches; this reads await(2) lines directly and parses them
 * with tokenize, which is what libc's wait does to the same line, so
 * that nothing here needs an allocator.
 *
 * It does not send to _threadwaitchan.  Nothing that reaches this uses
 * one - procexec is called with a pid channel instead - and inventing a
 * Waitmsg to send would mean allocating one to describe a program this
 * already knows the fate of.
 */
void
_schedexecwait(void)
{
	Proc *p;
	Thread *t;
	char buf[256], *fld[5];
	int pid, n;

	p = _threadgetproc();
	t = p->thread;
	pid = t->ret;
	for(;;){
		n = await(buf, sizeof buf - 1);
		if(n < 0)
			break;
		buf[n] = 0;
		if(tokenize(buf, fld, 5) != 5)
			break;
		if(atoi(fld[0]) == pid)
			break;
	}
	threadexits("procexec");
}

/*
 * A new proc: a second flow of control inside this program, sharing its
 * memory.  On Plan 9 that is rfork(RFPROC|RFMEM), and the child, which
 * has a copy of the stack at the same addresses, longjmps to a buffer
 * the parent saved and lands in _schedinit on its own stack.  Two stacks
 * cannot be at one address here, so the personality starts the new flow
 * at a function instead - which is simpler, because nothing about
 * _schedinit needs the caller's stack: it never returns.
 *
 * What makes this work at all is that the personality gives each flow
 * its own privalloc(2) word.  _threadgetproc is a dereference of one
 * fixed pointer captured in main, so the word behind it has to answer
 * differently to each flow; the personality's scheduler swaps its
 * contents at the switch.
 */
extern int p9proccreate(void (*f)(void*), void *arg);

static void
procstart(void *a)
{
	_threadsetproc((Proc*)a);
	_schedinit();
}

int
_schedfork(Proc *p)
{
	return p9proccreate(procstart, p);
}

/*
 * A proc that has run out of threads.  On Plan 9 this is _exits,
 * skipping the atexit handlers because the other procs of the program
 * are still running and one of them will do them.  Here exits is the
 * loader's - a program that ends returns to the personality that called
 * it - and that is what a proc ending has to reach.
 */
void
_schedexit(Proc *p)
{
	char ex[ERRMAX];

	utfecpy(ex, ex+sizeof ex, p->exitstr);
	free(p);
	exits(ex);
}
