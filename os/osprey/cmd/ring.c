/*
 * ring - drive an Osprey container's request ring from user space.
 *
 * The kernel publishes the shared span as the "osprey" physical segment,
 * so this maps it with segattach and works the ring directly: no trap is
 * taken to submit a request or to collect its reply.  Only the servicing
 * of a request still goes through the device.
 *
 * usage: ring arenasize slice [op [arg ...]]
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
	uvlong	request;
	uvlong	reply;
	uvlong	data;
	uvlong	datalen;
	uvlong	sem;
	uvlong	nsem;
	uvlong	selected;
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
	void	*message;	/* a kernel address; not usable here */
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
	uvlong msgroom;

	msgroom = sizeof(Message);

	sn = argc > 4 ? (int)num(argv[4]) : 0;

	/*
	 * Build the arms from the arguments, in the data area, at its
	 * start.  Each is get:RING, put:RING, down:SEM or noop; with none
	 * given, wait on a reply or on semaphore sn, which is the talk's
	 * driver shape without its output queue.
	 */
	a = (Arm*)(base + m->data);
	na = 0;
	for(i = 5; i < argc && na < Narm-1; i++, na++){
		a[na].buf = (uvlong)(Narm*sizeof(Arm)) + na*msgroom;
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
		a[1].op = OSdown; a[1].obj = sn; a[1].buf = 0;
		na = 2;
	}
	a[na].op = OSlast; a[na].obj = 0; a[na].buf = 0;
	na++;

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
	int i, op;

	if(argc < 3)
		die("usage: ring arenasize slice [op [arg ...]]");
	arenasize = num(argv[1]);
	slice = num(argv[2]);

	va = (uchar*)segattach(0, "osprey", 0, arenasize);
	if(va == (uchar*)-1)
		die("segattach failed");
	outs("mapped osprey segment\n");

	base = va + slice;
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
