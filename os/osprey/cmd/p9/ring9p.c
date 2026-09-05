/*
 * The ring transport, compiled against the user headers: it reaches the
 * microkernel only through libc's system calls (segattach to map the
 * ring, and the SLEEP syscall - which services the ring - to yield until
 * a reply lands).  It includes none of the kernel's headers, so its
 * sleep is libc's one-argument sleep and not the name space's; the two
 * header worlds meet only at the plain-typed ring9p.h interface, which
 * dev9ploop.c (kernel headers) uses.
 *
 * The ring layout is the container ring the microkernel lays over this
 * program's slice - the same one the stub client in userprog.c maps.
 * For now the requests are the stub server's own ReqOpen/ReqRead, which
 * proves the round trip from this binary before 9P rides the same ring.
 */
#include <u.h>
#include <libc.h>
#include "ospreydata.h"

enum {
	Ospreymagic	= 0x4f53505259ULL,
	ReqRead		= 0,
	ReqOpen		= 2,
	Req9P		= 14,	/* above every request in policy/syscall.h */
	ReqPip		= 18,	/* a pi-p group to the server personality, the same way */
	Reqframe	= 20,	/* a network frame to the peer container's stack, over the ring */
	Maxframe	= 2048,	/* the ring medium's MTU: a frame fits one of the slice's packet buffers */
	Inpktbuf	= 0xB0F,	/* arg[4] of a Reqframe: the frame is in the sender's packet buffer arg[2], not the data area */
	Ntxslot		= 16,	/* our packet buffers 0-15 carry frames to the server; 16-31 carry the server's to us */
	Takenoff	= Odtaken,	/* where select puts a message it takes off our output queue */
	OSget		= 2,	/* a select arm: take a message off a queue */
	ReqWait		= 4,
	ReqExec		= 13,
	ReqTick		= 17,	/* a request of our own (ospreyxcall): the clock tick on a semaphore */
	OSdown		= 4,	/* a select arm: down a semaphore */
	Armoff		= Odarm,	/* the client's one select arm, at the start of the data area */
	Execnameoff	= Odexecname,	/* where exec's name goes in the data area, clear of 9P */
	ReplyDone	= 1,
};

typedef struct Omap Omap;
struct Omap {
	uvlong	magic, id, size, msgsize;
	uvlong	requestqueue, replyqueue, outputqueue;
	uvlong	request, reply, output;
	uvlong	data, datalen, sem, nsem, selected;
	uvlong	pktbuf, npktbuf, pktbufsize;
	uvlong	page, npage, maxpage, pagesize;
	uvlong	txbuf, ntxbuf, txbufsize;
};
typedef struct Queue Queue;
struct Queue { vlong message; uvlong size, put, get; };
typedef struct Msg Msg;
struct Msg { uvlong op, sequence, container, arg[5]; };

typedef struct Arm Arm;
struct Arm { uvlong op, obj, buf; };

typedef struct Ring Ring;
struct Ring {
	uchar	*base;
	Omap	*map;
	Queue	*rq, *pq;
	Msg	*reqm, *repm;
};

static Ring ring;
static int mapped;

int
ring9p_init(void)
{
	Ring *r = &ring;

	if(mapped)
		return 0;
	r->base = (uchar*)segattach(0, "osprey0", 0, 0);
	if(r->base == (uchar*)-1)
		return -1;
	r->map = (Omap*)r->base;
	if(r->map->magic != Ospreymagic)
		return -1;
	r->rq = (Queue*)(r->base + r->map->requestqueue);
	r->pq = (Queue*)(r->base + r->map->replyqueue);
	r->reqm = (Msg*)((uchar*)r->rq + r->rq->message);
	r->repm = (Msg*)((uchar*)r->pq + r->pq->message);
	mapped = 1;
	return 0;
}

static long ringcalln(uvlong, uvlong, uvlong, uvlong, Msg*, int);

static long
ringcall(uvlong op, uvlong a0, uvlong a1, uvlong a2, Msg *rep)
{
	return ringcalln(op, a0, a1, a2, rep, 400);
}

/* as ringcall, waiting up to tries services for the reply */
static long
ringcalln(uvlong op, uvlong a0, uvlong a1, uvlong a2, Msg *rep, int tries)
{
	Ring *r = &ring;
	Msg m;
	uvlong seq;

	memset(&m, 0, sizeof m);
	m.op = op;
	m.container = r->map->id;
	m.arg[2] = a0;
	m.arg[3] = a1;
	m.arg[4] = a2;
	seq = r->rq->put + 1;
	m.sequence = seq;
	r->reqm[r->rq->put % r->rq->size] = m;
	r->rq->put++;				/* submit: memory, no trap */

	for(; tries > 0 && r->pq->put == r->pq->get; tries--)
		sleep(1);			/* service the ring and yield */

	if(r->pq->put == r->pq->get)
		return -1;
	*rep = r->repm[r->pq->get % r->pq->size];
	r->pq->get++;				/* collect: memory, no trap */
	if(rep->sequence != seq)
		return -1;
	return (long)rep->arg[0];
}



/*
 * One 9P exchange over the ring: leave the marshalled T-message in our
 * data area, ask the server (Req9P) to run 9P on it and leave the
 * R-message back, and copy that out.  The data area is small (about nine
 * kilobytes), but 9P messages to this server are tens of bytes; T sits
 * at one offset and R at another, clear of each other.
 */
static long
ringxfer(uvlong op, uchar *tmsg, long tn, uchar *rbuf, long rmax)
{
	Ring *r = &ring;
	Msg rep;
	uchar *data;
	long rn, k;
	enum { T9off = Odt9, R9off = Odr9 };

	if(tn < 0 || tn > R9off - T9off)	/* keep T clear of R in the small data area */
		return -1;
	data = r->base + r->map->data;
	for(k = 0; k < tn; k++)
		data[T9off + k] = tmsg[k];
	rn = ringcall(op, (uvlong)T9off, (uvlong)tn, (uvlong)R9off, &rep);
	if(rn <= 0)
		return rn;
	if(rn > rmax)
		rn = rmax;
	for(k = 0; k < rn; k++)
		rbuf[k] = data[R9off + k];
	return rn;
}

long
ring9p_xfer(uchar *tmsg, long tn, uchar *rbuf, long rmax)
{
	return ringxfer(Req9P, tmsg, tn, rbuf, rmax);
}

/* a pi-p group, the same way: the group at T, its replies at R */
long
ringpip_xfer(uchar *tmsg, long tn, uchar *rbuf, long rmax)
{
	if(rmax > 4096)
		rmax = 4096;		/* R sits at 1024 in a data area of two pages */
	return ringxfer(ReqPip, tmsg, tn, rbuf, rmax);
}

/*
 * A network frame to the peer container over the ring: staged in one of
 * this container's own packet buffers - the server maps the slice and
 * reads it there - and sent as a Reqframe naming the buffer; the reply
 * is the count taken.  Nothing comes back on the reply any more: the
 * far stack's frames arrive on this container's output queue, which
 * select takes them from (ring9p_wait, ring9p_taken).  The one-way
 * request ring is used one way.  Returns 0 when the server took it, -1
 * if the ring failed.
 */
long
ring9p_frame(uchar *frame, long n, uchar*, long)
{
	Ring *r = &ring;
	Msg rep;
	uchar *b;
	long k, rn;
	static int txnext;
	int slot;

	if(n <= 0 || n > Maxframe || !mapped || r->map->npktbuf < 2*Ntxslot || r->map->pktbufsize < Maxframe)
		return -1;
	slot = txnext++ % Ntxslot;
	b = r->base + r->map->pktbuf + slot*r->map->pktbufsize;
	for(k = 0; k < n; k++)
		b[k] = frame[k];
	rn = ringcall(Reqframe, (uvlong)slot, (uvlong)n, (uvlong)Inpktbuf, &rep);
	return rn < 0 ? -1 : 0;
}

/*
 * A frame the server put in one of our packet buffers, announced by
 * the message select just took off our output queue: where it is and
 * how long, or 0 for none.
 */
uchar*
ring9p_taken(long *len)
{
	Ring *r = &ring;
	Msg *m;

	if(!mapped)
		return nil;
	m = (Msg*)(r->base + r->map->data + Takenoff);
	if(m->op != Reqframe || m->arg[1] == 0 || m->arg[0] >= r->map->npktbuf){
		*len = 0;
		return nil;
	}
	*len = (long)m->arg[1];
	if(*len > (long)r->map->pktbufsize)
		*len = r->map->pktbufsize;
	m->op = 0;				/* taken: not twice */
	return r->base + r->map->pktbuf + m->arg[0]*r->map->pktbufsize;
}

/*
 * The clock for the client end of the ring wire.  A client's ring runs
 * requests to its server, so the clock is asked for the way a server
 * asks for its own things: a request of its own by system call
 * (ospreyxcall, xcall.s), answered at once by the kernel, which then
 * gives the named semaphore on every tick.  0 for taken, -1 refused.
 */
extern long ospreyxcall(int op, uvlong *args, long n);

int
ring9p_taketick(int sem)
{
	uvlong args[5];

	args[0] = sem;
	args[1] = args[2] = args[3] = args[4] = 0;
	if(ospreyxcall(ReqTick, args, 1) != 1)	/* 1: ReplyDone */
		return -1;
	return 0;
}

/*
 * Wait for the tick, or for a frame from the server: two arms in our
 * data area, a down on the tick's semaphore and a get on our output
 * queue (the server fills it in memory and the kernel wakes us), taken
 * by select the way a driver task waits.  Returns 0 for the tick, 1 for
 * a frame (ring9p_taken says where), -1 otherwise.
 */
int
ring9p_wait(int sem)
{
	Ring *r = &ring;
	Arm *arm;
	int n;

	if(!mapped)
		return -1;
	arm = (Arm*)(r->base + r->map->data + Armoff);
	arm[0].op = OSdown;
	arm[0].obj = sem;
	arm[0].buf = 0;
	arm[1].op = OSget;
	arm[1].obj = 2;			/* our output queue */
	arm[1].buf = Takenoff;
	n = dup(2, Armoff);		/* DUP's number is select over arms */
	if(n == 0 || n == 1)
		return n;
	return n == -2 ? -2 : -1;	/* -1: nothing within the kernel's wait (200 ms of quiet), ask again; -2: the arms were refused */
}

/* this container's data area, for a caller that is a client rather than a server (a server has p9srvdata) */
uchar*
ring9p_data(void)
{
	Ring *r = &ring;

	if(!mapped)
		return nil;
	return r->base + r->map->data;
}

/*
 * Start a program in a container of its own: the name goes in our data
 * area and the kernel is asked to exec it, which it does through our
 * server, the one that answers everything else we ask.  Returns the new
 * container's identity, or -1.
 */
long
ring_exec(char *name)
{
	Ring *r = &ring;
	Msg rep;
	uchar *d;
	long i;

	d = r->base + r->map->data + Execnameoff;
	for(i = 0; i < 120 && name[i] != 0; i++)
		d[i] = name[i];
	d[i] = 0;
	if(ringcall(ReqExec, Execnameoff, 0, 0, &rep) < 0 || rep.arg[0] != 1)
		return -1;
	return (long)rep.arg[2];
}

/*
 * Wait for a program this container started to exit; its status comes
 * back in *status.  The kernel answers when the child exits - or when it
 * has gone to another machine - which may be a while: a wait is a wait,
 * and it does not give up on its own.  (It once gave up after ten
 * seconds, which a child migrating over a slow wire outlasted, and the
 * program went on with the child still here.)
 */
long
ring_wait(long *status)
{
	Msg rep;

	if(ringcalln(ReqWait, 0, 0, 0, &rep, 1<<30) < 0 || rep.arg[0] != 1)
		return -1;
	*status = (long)rep.arg[2];
	return 0;
}
