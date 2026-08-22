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
oplookup(char *s)
{
	int i;

	for(i = 0; opname[i] != nil; i++)
		if(strcmp(opname[i], s) == 0)
			return i;
	return -1;
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
