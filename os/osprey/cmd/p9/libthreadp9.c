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
 * What it shows is that the scheduler inside a process works here:
 * threads of one proc, an unbuffered channel between them, and the
 * hand-off that an unbuffered send is - the sender blocks until the
 * receiver takes the value, so neither could get through this alone.
 *
 * The numbers are stated here and in the check, both written before the
 * machine was booted: five values, 1 through 5, summing to 15.
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

void
threadmain(int argc, char **argv)
{
	int v, sum, n;

	USED(argv);
	print("libthread: threadmain runs with %d arguments, as thread %d of proc %d\n",
		argc, threadid(), getpid());
	if((c = chancreate(sizeof(int), 0)) == nil)
		sysfatal("chancreate: %r");
	if(threadcreate(sender, nil, Stack) < 0)
		sysfatal("threadcreate: %r");
	sum = n = 0;
	while(recv(c, &v) == 1 && v != 0){
		sum += v;
		n++;
	}
	print("libthread: %d values crossed an unbuffered channel between two threads of one proc, summing to %d\n",
		n, sum);
	if(n != Nsend || sum != Sum)
		print("libthread: that is not the %d values summing to %d this program was written to send\n",
			Nsend, Sum);
	threadexitsall(nil);
}
