/*
 * The Osprey request ABI, as a library.
 *
 * A container's own program works its slice directly: it puts a request
 * on a ring and takes the answer off another, and enters the kernel only
 * for the things that must block.  Everything about how that is laid out
 * is in the map at the head of the slice, and every program that did it
 * used to carry its own copy of the map, the ring heads, the message and
 * the arm, and its own code for filling them in.  Three copies of a
 * structure the kernel writes is three chances to be out of date with
 * it; this is the one place, and it includes the kernel's own
 * declarations rather than repeating them.
 *
 * What this is not is a library operating system in the sense the Osprey
 * plan means.  There is still a Plan 9 kernel underneath, answering what
 * the policy layer does not; this is that kernel's request ABI made into
 * a library, so that a program does not have to work out the span's
 * shape for itself.
 *
 * A program that links it supplies its own _main, as the programs in
 * os/osprey/cmd do: the library's own startup member cannot be linked
 * with these.
 */
#ifndef OSPREY9_H
#define OSPREY9_H

/*
 * Include <u.h> before this.  The policy headers below include it
 * themselves when nothing else has, which they say by this name; u.h has
 * no guard of its own, so including it twice is an error rather than
 * nothing.
 */
#ifndef OSPREY_U_INCLUDED
#define OSPREY_U_INCLUDED
#endif

#include <osprey/queue.h>	/* Message, Queue: os/osprey/policy/queue.h */
#include <osprey/syscall.h>	/* Req..., Reply...: policy/syscall.h */
#include <osprey/sem.h>		/* Sem: policy/sem.h */
#include <osprey/ospreyabi.h>	/* Ospreymap, Ospreyarm: port/ospreyabi.h */

typedef struct Osprey Osprey;

enum {
	O9narm	= 8,	/* arms this library will build at once */
	/*
	 * Where in the data area the library puts things.  A request says
	 * where its arguments are as offsets into that area, since what
	 * answers it is in another address space or in the kernel and a
	 * pointer would mean nothing there.  The arms come first, then the
	 * message an arm took or put, and the names and the i/o buffer
	 * after those: a program that opened a file and then waited would
	 * otherwise have written the name over its own arms.  Every one of
	 * these is worked out from the two before it, so that changing the
	 * number of arms moves the rest rather than overlapping them.
	 */
	O9armend = O9narm*sizeof(Ospreyarm),
	O9msgend = O9armend + sizeof(Message),
	O9name	= O9msgend,		/* a name a request points at */
	O9name2	= O9name + 256,		/* and the second one bind wants */
	O9iobuf	= O9name2 + 256,	/* what read and write move */

	O9nothing = -2,	/* o9select: the wait ended and no arm was ready */
};

/*
 * One container's slice, mapped.  base is the slice; everything else is
 * a pointer into it worked out from the map, so a program reads the
 * rings and the semaphores without arithmetic of its own.
 */
struct Osprey {
	uchar	*base;
	Ospreymap *map;
	Queue	*requests;
	Queue	*replies;
	Queue	*output;
	Message	*reqmsg;
	Message	*repmsg;
	Message	*outmsg;
	Sem	*sem;
	Ospreyarm *arm;		/* the arms, at the head of the data area */
	uvlong	armbuf;		/* and the message buffer after them */
	uvlong	id;
	uvlong	size;		/* bytes in the slice */
	int	ctlfd;
	char	*err;		/* what the last call that failed said */
};

/*
 * Attach the segment named -- osprey0, osprey1 -- and check that a
 * container really is mapped there.  size is the slice size, which
 * /n/osprey/status reports.  o9attachid is the same thing for a program
 * that knows the container's number rather than the segment's name.
 */
int	o9attach(Osprey*, char *segment, uvlong size);
int	o9attachid(Osprey*, uvlong id, uvlong size);
void	o9detach(Osprey*);

/* the data area: where a request's arguments and its answers live */
void*	o9data(Osprey*, uvlong off, uvlong len);
uvlong	o9datalen(Osprey*);

/*
 * Put a request on this container's own ring and wait for its answer,
 * with no trap taken either way.  op is one of the Req... values.  The
 * three argument words are the request's own; the reply's are read out
 * of rep.  o9submit and o9collect are the two halves, for a program that
 * wants several in flight.
 */
int	o9submit(Osprey*, int op, uvlong a0, uvlong a1, uvlong a2);
int	o9collect(Osprey*, Message *rep, int tries);
int	o9call(Osprey*, int op, uvlong a0, uvlong a1, uvlong a2, Message *rep);

/*
 * The file operations, as a program would rather write them.  A name is
 * copied into the data area first, which is where the kernel or the
 * container's server will look for it.  Each returns -1 and sets err.
 */
int	o9open(Osprey*, char *name, int mode);
long	o9read(Osprey*, int fd, void *buf, long n);
long	o9write(Osprey*, int fd, void *buf, long n);
long	o9stat(Osprey*, int fd, void *buf, long n);
int	o9bind(Osprey*, char *name, char *over, int flag);
int	o9close(Osprey*, int fd);
uvlong	o9alloc(Osprey*, uvlong n);

/*
 * select.  The arms are built in the data area, where the kernel reads
 * them; o9arm fills one in and o9select waits.  What it returns is the
 * arm that fired, O9nothing when the wait ended with none of them
 * ready, or -1 when the kernel would not take the wait at all -- which
 * is what a container whose own slot has gone is told, and is a reason
 * to stop rather than to ask again.  The message an arm took or put is
 * at o->base + o->armbuf, which o9armmsg gives.
 */
void	o9arm(Osprey*, int i, int op, uvlong obj);
int	o9select(Osprey*, int narm);
Message*	o9armmsg(Osprey*);

/* what a semaphore's count is, without asking anybody */
uvlong	o9semcount(Osprey*, int n);

/*
 * Write a ready-made line to /n/osprey/ctl, which is how a container
 * asks for the things that must block.  The fd is opened once and kept.
 */
int	o9ctl(Osprey*, char *line, int n);

/*
 * Output and numbers, which every one of these programs wrote for
 * itself.  The library's own print cannot be linked with them -- it was
 * built by a newer compiler than this loader reads -- so this is what
 * there is.  o9out* buffer; o9flush writes.
 */
void	o9outs(char*);
void	o9outd(uvlong);
void	o9outhex(uvlong, int digits);
void	o9flush(void);
void	o9die(char*);
uvlong	o9num(char*);
char*	o9catstr(char *to, char *s);
char*	o9catnum(char *to, uvlong v);
#endif
