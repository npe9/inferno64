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

enum {
	Ospreymagic	= 0x4f53505259ULL,
	ReqRead		= 0,
	ReqOpen		= 2,
	Req9P		= 14,	/* above every request in policy/syscall.h */
	ReqWait		= 4,
	ReqExec		= 13,
	Execnameoff	= 3072,	/* where exec's name goes in the data area, clear of 9P */
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
long
ring9p_xfer(uchar *tmsg, long tn, uchar *rbuf, long rmax)
{
	Ring *r = &ring;
	Msg rep;
	uchar *data;
	long rn, k;
	enum { T9off = 256, R9off = 1024 };

	if(tn < 0 || tn > R9off - T9off)	/* keep T clear of R in the small data area */
		return -1;
	data = r->base + r->map->data;
	for(k = 0; k < tn; k++)
		data[T9off + k] = tmsg[k];
	rn = ringcall(Req9P, (uvlong)T9off, (uvlong)tn, (uvlong)R9off, &rep);
	if(rn <= 0)
		return rn;
	if(rn > rmax)
		rn = rmax;
	for(k = 0; k < rn; k++)
		rbuf[k] = data[R9off + k];
	return rn;
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
 * back in *status.  The kernel answers when the child exits, which may
 * be a while, so this waits longer than a file request does.
 */
long
ring_wait(long *status)
{
	Msg rep;

	if(ringcalln(ReqWait, 0, 0, 0, &rep, 5000) < 0 || rep.arg[0] != 1)
		return -1;
	*status = (long)rep.arg[2];
	return 0;
}
