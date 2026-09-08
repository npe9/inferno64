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
 * procexec.  A library operating system does not have exec: a program
 * is at the address it was linked for and nothing here relocates one,
 * so there is nothing to replace an address space with.  The
 * personality's spawn starts another program at another address, which
 * is a different thing and not what procexec means - procexec's caller
 * expects the proc it is running on to become that program.
 *
 * So this refuses, by name, and says so down the pipe libthread made
 * for exactly this: efork writes the reason there when exec fails and
 * the waiting side reads it.  procexec then reports the failure the way
 * it reports any other.
 */
int
_schedexec(Execargs *e)
{
	char *m = "procexec: the library operating system has no exec; use the personality's spawn";

	write(e->fd[1], m, strlen(m));
	close(e->fd[1]);
	close(e->fd[0]);
	return -1;
}

void
_schedexecwait(void)
{
	/*
	 * Only reached after _schedexec answered with a pid, which it
	 * never does.
	 */
	sysfatal("_schedexecwait: no proc was ever exec'd");
}

/*
 * A new proc: a second flow of control inside this program, sharing its
 * memory.  The personality has exactly that in its cooperative kprocs,
 * and giving one to a program means giving the program per-process
 * storage as well - libthread keeps the running Proc in a privalloc(2)
 * word, and one word cannot answer differently to two flows of control
 * unless something swaps it at the switch.  That is the next piece; it
 * is not here yet, so this refuses by name rather than starting a proc
 * that would find another proc's Proc in its own private.
 */
int
_schedfork(Proc *p)
{
	USED(p);
	werrstr("proccreate: this personality has threads in one proc, not procs");
	return -1;
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
