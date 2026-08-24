/*
 * ring - drive an Osprey container's request ring from user space.
 *
 * The kernel publishes the shared span as the "osprey" physical segment,
 * so this maps it with segattach and works the ring directly: no trap is
 * taken to submit a request or to collect its reply.  Only the servicing
 * of a request still goes through the device.
 *
 * usage: ring segment size [op [arg ...]]
 *        ring segment size page PAGESEG [text]
 *        ring segment size twice
 *
 * The segment is the container's own -- osprey0, osprey1 and so on, as
 * status reports -- and the size is that segment's, not the whole span's.
 * Each container's memory is a segment of its own, so attaching one gets
 * that container's and nobody else's.
 *
 * With no op it reports the container's map.  The offsets come from
 * /n/osprey/status; see osprey(3).
 *
 * The program uses only the system calls out of the library and formats
 * its own output.  The library in this tree was built by a newer compiler
 * than the loader here reads, and its printing and startup members cannot
 * be linked; initcode avoids them in the same way.
 */
#include <u.h>
#include <libc.h>

typedef struct Ospreymap Ospreymap;
typedef struct Queue Queue;
typedef struct Message Message;

enum {
	Ospreymagic	= 0x4f53505259ULL,
	Nword		= 5,
	Nwait		= 100,		/* tenths of a second */
	Narm		= 8,
};

struct Ospreymap {
	uvlong	magic;
	uvlong	id;
	uvlong	size;
	uvlong	msgsize;
	uvlong	requestqueue;
	uvlong	replyqueue;
	uvlong	outputqueue;
	uvlong	request;
	uvlong	reply;
	uvlong	output;
	uvlong	data;
	uvlong	datalen;
	uvlong	sem;
	uvlong	nsem;
	uvlong	selected;
	uvlong	pktbuf;
	uvlong	npktbuf;
	uvlong	pktbufsize;
	uvlong	page;
	uvlong	npage;
	uvlong	maxpage;
	uvlong	pagesize;
	uvlong	txbuf;		/* the frames it fills and the card reads */
	uvlong	ntxbuf;
	uvlong	txbufsize;
};

typedef struct Sem Sem;
struct Sem {
	uvlong	count;
	uvlong	given;
	uvlong	taken;
};

typedef struct Arm Arm;
struct Arm {
	uvlong	op;
	uvlong	obj;
	uvlong	buf;
};

enum {
	OSlast,
	OSnoop,
	OSget,
	OSput,
	OSdown,
};

struct Queue {
	vlong	message;	/* bytes from this head to the messages */
	uvlong	size;
	uvlong	put;
	uvlong	get;
};

struct Message {
	uvlong	op;
	uvlong	sequence;
	uvlong	container;
	uvlong	arg[Nword];
};

static char *opname[] = {
	"read", "write", "open", "close", "wait", "send",
	"recv", "stat", "bind", "alloc", "yield", "poll", nil,
};

static char *statusname[] = {
	"pending", "done", "error", "blocked", "retry", nil,
};

static char obuf[512];
static int on;

static void
flush(void)
{
	if(on > 0)
		write(1, obuf, on);
	on = 0;
}

static void
outs(char *s)
{
	while(*s != '\0' && on < sizeof obuf - 1)
		obuf[on++] = *s++;
}

static void
outd(uvlong v)
{
	char b[24];
	int i;

	i = sizeof b;
	b[--i] = '\0';
	do {
		b[--i] = '0' + (int)(v % 10);
		v /= 10;
	} while(v != 0 && i > 0);
	outs(b+i);
}

static void
die(char *s)
{
	outs("ring: ");
	outs(s);
	outs("\n");
	flush();
	exits(s);
}

static uvlong
num(char *s)
{
	uvlong v;

	v = 0;
	while(*s >= '0' && *s <= '9')
		v = v*10 + (*s++ - '0');
	return v;
}

static char*
name(char **t, uvlong i)
{
	uvlong n;

	for(n = 0; t[n] != nil; n++)
		;
	return i < n ? t[i] : "?";
}

static int
prefix(char *s, char *p)
{
	while(*p != 0)
		if(*s++ != *p++)
			return 0;
	return 1;
}

static int
hasget(Arm *a, int n, uvlong ring)
{
	int i;

	for(i = 0; i < n; i++)
		if(a[i].op == OSget && a[i].obj == ring)
			return 1;
	return 0;
}

static char*
ringcat(char *d, char *s)
{
	while(*s != 0)
		*d++ = *s++;
	return d;
}

static char*
ringnum(char *d, uvlong v)
{
	char b[24];
	int i;

	i = sizeof b;
	do {
		b[--i] = '0' + (int)(v % 10);
		v /= 10;
	} while(v != 0 && i > 0);
	while(i < sizeof b)
		*d++ = b[i++];
	return d;
}

static int
oplookup(char *s)
{
	int i;

	for(i = 0; opname[i] != nil; i++)
		if(strcmp(opname[i], s) == 0)
			return i;
	return -1;
}

/*
 * Wait on a reply and on a semaphore at once, as the talk's driver task
 * waits on its message queue, its interrupt semaphore and its output
 * queue.  Readiness is visible in the mapped span, so the loop looks for
 * itself first and only asks the kernel to wait when neither is ready.
 * The arm that fired is left in the map, where it is read without asking
 * again.
 */
static void
waitmain(uchar *base, Ospreymap *m, Queue *rq, Queue *pq, int argc, char **argv)
{
	Arm *a;
	Sem *sem;
	char buf[64], *e;
	int fd, n, sn, na, i;

	sn = argc > 4 ? (int)num(argv[4]) : 0;

	/*
	 * Build the arms from the arguments, in the data area, at its
	 * start.  Each is get:RING, put:RING, down:SEM or noop; with none
	 * given, wait on a reply or on semaphore sn, which is the talk's
	 * driver shape without its output queue.
	 */
	a = (Arm*)(base + m->data);
	na = 0;
	/*
	 * Every arm names the same message buffer.  Only one arm is ever
	 * performed, and a server that takes a request there and then puts
	 * its answer from there keeps the container and sequence the
	 * request carried, which is how the answer finds its way home.
	 */
	for(i = 5; i < argc && na < Narm-1; i++, na++){
		a[na].buf = (uvlong)(Narm*sizeof(Arm));
		if(prefix(argv[i], "get:"))
			a[na].op = OSget, a[na].obj = num(argv[i]+4);
		else if(prefix(argv[i], "put:"))
			a[na].op = OSput, a[na].obj = num(argv[i]+4);
		else if(prefix(argv[i], "down:"))
			a[na].op = OSdown, a[na].obj = num(argv[i]+5);
		else if(strcmp(argv[i], "noop") == 0)
			a[na].op = OSnoop, a[na].obj = 0;
		else
			die("arm is get:N, put:N, down:N or noop");
	}
	if(na == 0){
		a[0].op = OSget;  a[0].obj = 1;
		a[0].buf = (uvlong)(Narm*sizeof(Arm));
		a[1].op = OSdown; a[1].obj = sn;
		a[1].buf = (uvlong)(Narm*sizeof(Arm));
		na = 2;
	}
	a[na].op = OSlast; a[na].obj = 0; a[na].buf = 0;
	na++;

	/*
	 * Answering is putting the message back with a status in it.  The
	 * container and sequence it came with are still there, which is how
	 * the kernel knows where to send it.
	 */
	for(i = 0; i < na; i++)
		if(a[i].op == OSput){
			Message *mp;

			mp = (Message*)(base + m->data + Narm*sizeof(Arm));
			mp->arg[0] = 1;		/* done */
		}

	outs("waiting on "); outd(na-1); outs(" arms\n"); flush();

	/*
	 * A reply is ours to take: this end of that ring is the consumer,
	 * so no one else is moving its get index and no trap is needed.
	 * Only when a reply is among the arms offered, of course.
	 */
	if(hasget(a, na, 1) && pq->put != pq->get){
		pq->get++;
		outs("took a reply without the kernel\n");
		flush();
		return;
	}

	/*
	 * A semaphore is shared with whoever gives it, so taking one is
	 * the kernel's to do.  Its count is visible here either way, which
	 * is how the loop above knew whether to ask at all.
	 */
	if((fd = open("/n/osprey/ctl", OWRITE)) < 0)
		die("cannot open /n/osprey/ctl");
	e = buf;
	e = ringcat(e, "select ");
	e = ringnum(e, m->id);
	e = ringcat(e, " 0 ");
	e = ringnum(e, na);
	e = ringcat(e, "\n");
	n = write(fd, buf, e-buf);
	close(fd);
	if(n < 0)
		die("select failed");

	/* what the message buffer holds, for a server that took a request */
	{
		Message *mp = (Message*)(base + m->data + Narm*sizeof(Arm));

		outs("message op "); outd(mp->op);
		outs(" from "); outd(mp->container);
		outs(" sequence "); outd(mp->sequence);
		outs("\n");
	}
	outs("select returned, arm ");
	if(m->selected == ~0ULL)
		outs("none");
	else
		outd(m->selected);
	outs(", requests put "); outd(rq->put);
	outs(" get "); outd(rq->get);
	outs(", replies put "); outd(pq->put);
	outs(" get "); outd(pq->get);
	/* the semaphore the arm that fired names, not the one asked about */
	if(m->selected != ~0ULL && a[m->selected].op == OSdown){
		sem = (Sem*)(base + m->sem) + a[m->selected].obj;
		outs(", sem "); outd(a[m->selected].obj);
		outs(" count "); outd(sem->count);
		outs(" given "); outd(sem->given);
		outs(" taken "); outd(sem->taken);
	}
	outs("\n");
	flush();
}

static void
ringmain(int argc, char **argv)
{
	uvlong arenasize, slice, seq;
	uchar *va, *base;
	Ospreymap *m;
	Queue *rq, *pq;
	Message *rm, *pm, msg;
	long n;
	int i, op;

	if(argc < 3)
		die("usage: ring segment size [op [arg ...]]");
	arenasize = num(argv[2]);

	va = (uchar*)segattach(0, argv[1], 0, arenasize);
	if(va == (uchar*)-1){
		/* what the kernel said, since "failed" says nothing */
		char e[ERRMAX];

		e[0] = '\0';
		errstr(e, sizeof e);
		outs("ring: segattach ");
		outs(argv[1]);
		outs(": ");
		outs(e);
		outs("\n");
		flush();
		exits("segattach");
	}
	outs("mapped "); outs(argv[1]); outs("\n");

	slice = 0;
	base = va;
	m = (Ospreymap*)base;
	if(m->magic != Ospreymagic)
		die("no container mapped at that offset");

	rq = (Queue*)(base + m->requestqueue);
	pq = (Queue*)(base + m->replyqueue);
	rm = (Message*)(base + m->request);
	pm = (Message*)(base + m->reply);

	outs("id "); outd(m->id);
	outs(" size "); outd(m->size);
	outs(" msgsize "); outd(m->msgsize);
	outs(" data "); outd(m->data);
	outs(" datalen "); outd(m->datalen);
	outs("\nrequests put "); outd(rq->put);
	outs(" get "); outd(rq->get);
	outs(" replies put "); outd(pq->put);
	outs(" get "); outd(pq->get);
	outs("\n");
	if(argc == 3){
		flush();
		return;
	}

	if(strcmp(argv[3], "twice") == 0){
		/*
		 * The talk says segments may be shared at different
		 * addresses, and everything in this span is an offset
		 * rather than a pointer so that they may.  This attaches
		 * the same slice a second time -- the kernel puts it
		 * wherever there is room, which is not where the first one
		 * is -- and then works the ring through the second mapping
		 * alone: the map is read there, the ring heads are found
		 * from it there, and the request is put there.  A pointer
		 * anywhere in the span would make that go wrong, and
		 * nothing else in this check would notice.
		 */
		uchar *vb;
		Ospreymap *mb;
		Queue *rqb, *pqb;
		Message *rmb, *pmb;

		vb = (uchar*)segattach(0, argv[1], 0, arenasize);
		if(vb == (uchar*)-1){
			char e[ERRMAX];

			e[0] = '\0';
			errstr(e, sizeof e);
			outs("ring: second segattach: "); outs(e); outs("\n");
			flush();
			exits("segattach");
		}
		if(vb == va)
			die("the second mapping is the first one");
		outs("mapped twice, "); outd((uvlong)(vb > va ? vb - va : va - vb));
		outs(" bytes apart\n");

		mb = (Ospreymap*)vb;
		if(mb->magic != Ospreymagic || mb->id != m->id)
			die("the second mapping is not the same container");
		/* the same memory: what is written through one is in the other */
		{
			uchar *pa, *pb;

			pa = base + m->data + m->datalen - 1;
			pb = vb + mb->data + mb->datalen - 1;
			*pa = 0x5a;
			if(*pb != 0x5a)
				die("the two mappings are not the same memory");
			*pa = 0;
		}

		rqb = (Queue*)(vb + mb->requestqueue);
		pqb = (Queue*)(vb + mb->replyqueue);
		rmb = (Message*)(vb + mb->request);
		pmb = (Message*)(vb + mb->reply);
		if(rqb->put - rqb->get >= mb->size)
			die("request ring full");
		memset(&msg, 0, sizeof msg);
		msg.op = (uvlong)oplookup("poll");
		msg.sequence = rqb->put + 1;
		msg.container = mb->id;
		rmb[rqb->put % mb->size] = msg;
		rqb->put++;
		for(i = 0; i < Nwait; i++){
			if(pqb->put != pqb->get){
				msg = pmb[pqb->get % mb->size];
				pqb->get++;
				outs("through the second mapping, reply ");
				outs(name(opname, msg.op));
				outs(" "); outs(name(statusname, msg.arg[0]));
				outs("\n");
				flush();
				return;
			}
			sleep(100);
		}
		die("no reply through the second mapping");
	}

	if(strcmp(argv[3], "frame") == 0 && argc > 4){
		/*
		 * Put a frame in the container's first transmit buffer and
		 * hand it to the interface.  Nothing copies it: the buffer
		 * is in this slice, which is where the card reads it from.
		 * The type is pi-p's, so a machine on the other end of the
		 * wire with pipether on says what it saw.
		 */
		uchar *f;
		long len, k;

		len = (long)num(argv[4]);
		if(len < 64)
			len = 64;
		if((uvlong)len > m->txbufsize)
			len = m->txbufsize;
		f = base + m->txbuf;
		for(k = 0; k < 6; k++)
			f[k] = 0xff;			/* to everybody */
		for(k = 6; k < 12; k++)
			f[k] = 0x02;			/* from this container */
		f[12] = 0x91; f[13] = 0x0a;		/* pi-p */
		for(k = 14; k < len; k++)
			f[k] = (uchar)k;
		outs("frame at "); outd(m->txbuf);
		outs(" of "); outd(m->ntxbuf);
		outs(" buffers, "); outd(m->txbufsize);
		outs(" each\n");
		flush();

		memset(&msg, 0, sizeof msg);
		msg.op = (uvlong)oplookup("send");
		msg.sequence = rq->put + 1;
		msg.container = m->id;
		msg.arg[2] = 0;				/* buffer */
		msg.arg[3] = (uvlong)len;
		rm[rq->put % rq->size] = msg;
		rq->put++;
		outs("submitted send of "); outd(len); outs("\n");
		flush();
		for(i = 0; i < Nwait; i++){
			if(pq->put != pq->get){
				msg = pm[pq->get % pq->size];
				pq->get++;
				outs("send "); outs(name(statusname, msg.arg[0]));
				outs(" "); outd(msg.arg[2]); outs("\n");
				flush();
				return;
			}
			sleep(100);
		}
		die("no reply to send");
	}

	if(strcmp(argv[3], "bench") == 0 && argc > 4){
		/*
		 * Submit and collect that many times through the mapped ring
		 * without entering the kernel once, so that what the shell's
		 * time says is the round trip a container pays when it does
		 * not trap.  Nothing is printed in the loop.
		 */
		long k, want;

		want = (long)num(argv[4]);
		for(k = 0; k < want; k++){
			while(rq->put - rq->get >= m->size)
				;
			memset(&msg, 0, sizeof msg);
			msg.op = (uvlong)oplookup("poll");
			msg.sequence = k+1;
			msg.container = m->id;
			rm[rq->put % m->size] = msg;
			rq->put++;
			while(pq->put == pq->get)
				;
			pq->get++;
		}
		outs("did "); outd(want); outs(" round trips\n");
		flush();
		return;
	}

	if(strcmp(argv[3], "page") == 0 && argc > 4){
		/*
		 * A page is a segment of its own, so a container that has
		 * been handed one attaches it and finds what was written
		 * there: the page was mapped, not copied.
		 */
		uchar *pg;

		pg = (uchar*)segattach(0, argv[4], 0, 4096);
		if(pg == (uchar*)-1)
			die("cannot attach that page");
		outs("mapped "); outs(argv[4]); outs("\n");
		if(argc > 5){
			n = strlen(argv[5]);
			memmove(pg, argv[5], n+1);
			outs("wrote '"); outs(argv[5]); outs("'\n");
		} else {
			pg[63] = 0;
			outs("holds '"); outs((char*)pg); outs("'\n");
		}
		flush();
		return;
	}

	if(strcmp(argv[3], "wait") == 0){
		waitmain(base, m, rq, pq, argc, argv);
		return;
	}

	if((op = oplookup(argv[3])) < 0)
		die("unknown operation");
	if(rq->put - rq->get >= rq->size)
		die("request ring full");

	memset(&msg, 0, sizeof msg);
	msg.op = op;
	seq = rq->put + 1;
	msg.sequence = seq;
	msg.container = m->id;
	/* arg[0] and arg[1] carry the status and flag words */
	for(i = 0; i + 4 < argc && i < Nword-2; i++)
		msg.arg[2+i] = num(argv[4+i]);

	rm[rq->put % rq->size] = msg;
	/* amd64 does not reorder stores, so publishing the index suffices */
	rq->put++;
	outs("submitted "); outs(opname[op]);
	outs(" sequence "); outd(seq); outs("\n");
	flush();

	for(i = 0; i < Nwait; i++){
		if(pq->put != pq->get){
			msg = pm[pq->get % pq->size];
			pq->get++;
			outs("reply "); outs(name(opname, msg.op));
			outs(" "); outs(name(statusname, msg.arg[0]));
			outs(" "); outd(msg.arg[2]);
			outs(" "); outd(msg.arg[3]);
			outs(" "); outd(msg.arg[4]);
			outs("\n");
			flush();
			return;
		}
		sleep(100);
	}
	die("no reply");
}

/*
 * The library's own startup member cannot be linked here either, so the
 * program supplies one.  The kernel leaves argv on the stack with a nil
 * terminator, exactly as init9.c assumes.
 */
void
_main(char *argv0)
{
	char **argv;
	int argc;

	argv = &argv0;
	for(argc = 0; argv[argc] != nil; argc++)
		;
	ringmain(argc, argv);
	exits(nil);
}
