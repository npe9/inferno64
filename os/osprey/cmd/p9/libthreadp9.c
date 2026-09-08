/*
 * libthreadp9.c - a threaded program, its operating system a library in
 * its own address space.
 *
 * It is an ordinary Plan 9 libthread program: threadmain, threadcreate,
 * chancreate, send and recv.  The libthread it runs on is the real one,
 * built from the source in 9front/src with no line changed; what is
 * this personality's own is threadmain9.c, the four functions libthread
 * keeps separate for exactly this reason.
 *
 * What it shows is both halves of libthread.  First the scheduler
 * inside a process: threads of one proc, an unbuffered channel between
 * them, and the hand-off that an unbuffered send is - the sender blocks
 * until the receiver takes the value, so neither could get through this
 * alone.  Then a proc of its own: proccreate is a second flow of control
 * inside this program, sharing its memory, and the same channel carries
 * values across it.  A cross-proc send is not the same mechanism - the
 * sender's proc has no ready thread and goes to sleep, and the receiving
 * proc wakes it - so it exercises the personality's rendezvous and the
 * per-process word that tells each flow which Proc it is running.
 *
 * The numbers are stated here and in the check, both written before the
 * machine was booted: five values, 1 through 5, summing to 15, sent
 * twice - once between threads of one proc and once between two procs.
 */
#include <u.h>
#include <libc.h>
#include <thread.h>

enum {
	Stack	= 8192,
	Nsend	= 5,		/* how many values cross the channel */
	Sum	= 15,		/* and what they come to: 1+2+3+4+5 */
};

static Channel *c;

static void
sender(void *a)
{
	int i;

	USED(a);
	for(i = 1; i <= Nsend; i++)
		send(c, &i);
	i = 0;			/* the end of the sequence */
	send(c, &i);
	threadexits(nil);
}

/*
 * The same sender, as the thread a new proc starts with.  It says which
 * proc it is on, because that number is getpid(2) and getpid on this
 * personality is the flow of control's own - two procs of one program
 * reading the same number would mean the per-process word was not.
 */
static void
procsender(void *a)
{
	print("libthread: the second proc runs as %d, and the first was %d\n",
		getpid(), (int)(uintptr)a);
	sender(nil);
}

/* count what comes off the channel until the zero that ends it */
static int
drain(int *sump)
{
	int v, n;

	n = *sump = 0;
	while(recv(c, &v) == 1 && v != 0){
		*sump += v;
		n++;
	}
	return n;
}

void
threadmain(int argc, char **argv)
{
	int sum, n, pid;

	USED(argv);
	print("libthread: threadmain runs with %d arguments, as thread %d of proc %d\n",
		argc, threadid(), getpid());
	if((c = chancreate(sizeof(int), 0)) == nil)
		sysfatal("chancreate: %r");
	if(threadcreate(sender, nil, Stack) < 0)
		sysfatal("threadcreate: %r");
	n = drain(&sum);
	print("libthread: %d values crossed an unbuffered channel between two threads of one proc, summing to %d\n",
		n, sum);
	if(n != Nsend || sum != Sum)
		print("libthread: that is not the %d values summing to %d this program was written to send\n",
			Nsend, Sum);

	/*
	 * And again, with the sender on a proc of its own.  Now the two
	 * ends are two flows of control of the personality's, and the
	 * hand-off goes through its rendezvous: the receiving proc has
	 * nothing to run while it waits and sleeps, and the sending proc
	 * wakes it.
	 */
	if((pid = proccreate(procsender, (void*)(uintptr)getpid(), Stack)) < 0)
		sysfatal("proccreate: %r");
	n = drain(&sum);
	print("libthread: %d values crossed the same channel from a proc of its own, summing to %d\n",
		n, sum);
	if(n != Nsend || sum != Sum)
		print("libthread: that is not the %d values summing to %d this program was written to send\n",
			Nsend, Sum);
	USED(pid);
	threadexitsall(nil);
}
