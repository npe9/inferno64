/*
 * The Osprey request ABI, as a library.  See osprey9.h for what this is
 * and, as much to the point, what it is not.
 */
#include <u.h>
#include <libc.h>
#include <osprey9.h>

static char obuf[1024];
static int on;

void
o9flush(void)
{
	if(on > 0)
		write(1, obuf, on);
	on = 0;
}

void
o9outs(char *s)
{
	while(*s != '\0'){
		if(on >= sizeof obuf)
			o9flush();
		obuf[on++] = *s++;
	}
}

char*
o9catnum(char *to, uvlong v)
{
	char b[24];
	int i;

	i = sizeof b;
	b[--i] = '\0';
	do {
		b[--i] = '0' + (int)(v % 10);
		v /= 10;
	} while(v != 0 && i > 0);
	return o9catstr(to, b+i);
}

char*
o9catstr(char *to, char *s)
{
	while(*s != '\0')
		*to++ = *s++;
	return to;
}

void
o9outd(uvlong v)
{
	char b[24], *e;

	e = o9catnum(b, v);
	*e = '\0';
	o9outs(b);
}

void
o9outhex(uvlong v, int digits)
{
	char b[20];
	int i;

	if(digits > sizeof b - 1)
		digits = sizeof b - 1;
	for(i = digits; i > 0; i--){
		b[i-1] = "0123456789abcdef"[v & 0xf];
		v >>= 4;
	}
	b[digits] = '\0';
	o9outs(b);
}

void
o9die(char *s)
{
	o9outs("osprey: ");
	o9outs(s);
	o9outs("\n");
	o9flush();
	exits(s);
}

uvlong
o9num(char *s)
{
	uvlong v;

	v = 0;
	while(*s >= '0' && *s <= '9')
		v = v*10 + (*s++ - '0');
	return v;
}

/*
 * Everything below reads the map rather than working anything out.  The
 * kernel puts the geometry back before every use of a ring -- a
 * container may write every byte of its own map -- so what is here is
 * what the kernel last said, not what this process last wrote.
 */
static void
layout(Osprey *o)
{
	Ospreymap *m;

	m = o->map;
	o->requests = (Queue*)(o->base + m->requestqueue);
	o->replies = (Queue*)(o->base + m->replyqueue);
	o->output = (Queue*)(o->base + m->outputqueue);
	o->reqmsg = (Message*)(o->base + m->request);
	o->repmsg = (Message*)(o->base + m->reply);
	o->outmsg = (Message*)(o->base + m->output);
	o->sem = (Sem*)(o->base + m->sem);
	o->arm = (Ospreyarm*)(o->base + m->data);
	o->armbuf = m->data + (uvlong)(O9narm*sizeof(Ospreyarm));
}

int
o9attach(Osprey *o, char *segment, uvlong size)
{
	memset(o, 0, sizeof *o);
	o->ctlfd = -1;
	o->size = size;
	o->base = (uchar*)segattach(0, segment, 0, size);
	if(o->base == (uchar*)-1){
		o->base = nil;
		o->err = "segattach failed";
		return -1;
	}
	o->map = (Ospreymap*)o->base;
	if(o->map->magic != Ospreymagic){
		o->err = "no container mapped there";
		return -1;
	}
	o->id = o->map->id;
	layout(o);
	return 0;
}

int
o9attachid(Osprey *o, uvlong id, uvlong size)
{
	char name[32], *e;

	e = o9catstr(name, "osprey");
	e = o9catnum(e, id);
	*e = '\0';
	return o9attach(o, name, size);
}

void
o9detach(Osprey *o)
{
	if(o->ctlfd >= 0)
		close(o->ctlfd);
	o->ctlfd = -1;
	if(o->base != nil)
		segdetach(o->base);
	o->base = nil;
	o->map = nil;
}

uvlong
o9datalen(Osprey *o)
{
	return o->map->datalen;
}

void*
o9data(Osprey *o, uvlong off, uvlong len)
{
	uvlong n;

	n = o->map->datalen;
	if(off >= n || len > n - off){
		o->err = "outside the data area";
		return nil;
	}
	return o->base + o->map->data + off;
}

int
o9ctl(Osprey *o, char *line, int n)
{
	if(o->ctlfd < 0 && (o->ctlfd = open("/n/osprey/ctl", OWRITE)) < 0){
		o->err = "cannot open /n/osprey/ctl";
		return -1;
	}
	if(write(o->ctlfd, line, n) < 0){
		o->err = "the kernel refused that control message";
		return -1;
	}
	return 0;
}

int
o9submit(Osprey *o, int op, uvlong a0, uvlong a1, uvlong a2)
{
	Queue *q;
	Message m;

	q = o->requests;
	if(q->put - q->get >= q->size){
		o->err = "the request ring is full";
		return -1;
	}
	memset(&m, 0, sizeof m);
	m.op = op;
	m.sequence = q->put + 1;
	m.container = o->id;
	/* arg[0] and arg[1] carry the status and flag words back */
	m.arg[2] = a0;
	m.arg[3] = a1;
	m.arg[4] = a2;
	o->reqmsg[q->put % q->size] = m;
	/*
	 * The message must be stored before the index that publishes it.
	 * amd64 does not reorder stores, so publishing the index is
	 * enough; a machine that does needs a barrier here.
	 */
	q->put++;
	return 0;
}

int
o9collect(Osprey *o, Message *rep, int tries)
{
	Queue *q;
	int i;

	q = o->replies;
	for(i = 0; i < tries; i++){
		if(q->put != q->get){
			*rep = o->repmsg[q->get % q->size];
			q->get++;
			return 0;
		}
		sleep(5);
	}
	o->err = "no reply came";
	return -1;
}

int
o9call(Osprey *o, int op, uvlong a0, uvlong a1, uvlong a2, Message *rep)
{
	if(o9submit(o, op, a0, a1, a2) < 0)
		return -1;
	if(o9collect(o, rep, 400) < 0)
		return -1;
	if(rep->arg[0] != ReplyDone){
		o->err = "the request was refused";
		return -1;
	}
	return 0;
}

/* a name goes into the data area, which is where the answerer looks */
static int
putname(Osprey *o, uvlong off, char *s)
{
	char *a;
	long n;

	n = strlen(s) + 1;
	if((a = o9data(o, off, (uvlong)n)) == nil)
		return -1;
	memmove(a, s, n);
	return 0;
}

int
o9open(Osprey *o, char *name, int mode)
{
	Message rep;

	if(putname(o, O9name, name) < 0)
		return -1;
	if(o9call(o, ReqOpen, O9name, (uvlong)mode, 0, &rep) < 0)
		return -1;
	return (int)rep.arg[2];
}

static long
rw(Osprey *o, int op, int fd, void *buf, long n)
{
	Message rep;
	void *a;

	/*
	 * The buffer is in the data area and the request says where: what
	 * answers the request is in another address space, or in the
	 * kernel, and a pointer would mean nothing there.
	 */
	if((a = o9data(o, O9iobuf, (uvlong)n)) == nil)
		return -1;
	if(op == ReqWrite)
		memmove(a, buf, n);
	if(o9call(o, op, (uvlong)fd, O9iobuf, (uvlong)n, &rep) < 0)
		return -1;
	n = (long)rep.arg[2];
	if(op != ReqWrite && n > 0)
		memmove(buf, a, n);
	return n;
}

long
o9read(Osprey *o, int fd, void *buf, long n)
{
	return rw(o, ReqRead, fd, buf, n);
}

long
o9write(Osprey *o, int fd, void *buf, long n)
{
	return rw(o, ReqWrite, fd, buf, n);
}

long
o9stat(Osprey *o, int fd, void *buf, long n)
{
	return rw(o, ReqStat, fd, buf, n);
}

int
o9bind(Osprey *o, char *name, char *over, int flag)
{
	Message rep;

	if(putname(o, O9name, name) < 0 || putname(o, O9name2, over) < 0)
		return -1;
	return o9call(o, ReqBind, O9name, O9name2, (uvlong)flag, &rep);
}

int
o9close(Osprey *o, int fd)
{
	Message rep;

	return o9call(o, ReqClose, (uvlong)fd, 0, 0, &rep);
}

uvlong
o9alloc(Osprey *o, uvlong n)
{
	Message rep;

	if(o9call(o, ReqAlloc, n, 0, 0, &rep) < 0)
		return 0;
	return rep.arg[2];
}

void
o9arm(Osprey *o, int i, int op, uvlong obj)
{
	if(i < 0 || i >= O9narm)
		return;
	o->arm[i].op = op;
	o->arm[i].obj = obj;
	o->arm[i].buf = o->armbuf - o->map->data;
}

Message*
o9armmsg(Osprey *o)
{
	return (Message*)(o->base + o->armbuf);
}

/*
 * Wait on the arms already built.  This is the one trap: the arms, the
 * message and everything the message names are in memory this process
 * has mapped, and only the waiting is the kernel's.
 */
int
o9select(Osprey *o, int narm)
{
	char buf[64], *e;

	if(narm < 0 || narm >= O9narm)
		return -1;
	o->arm[narm].op = OSlast;
	o->arm[narm].obj = 0;
	o->arm[narm].buf = 0;
	e = buf;
	e = o9catstr(e, "select ");
	e = o9catnum(e, o->id);
	e = o9catstr(e, " ");
	e = o9catnum(e, (uvlong)0);	/* the arms are at the head of it */
	e = o9catstr(e, " ");
	e = o9catnum(e, (uvlong)(narm+1));
	e = o9catstr(e, "\n");
	/*
	 * A refusal here is not "wait again": the commonest reason for one
	 * is that this container no longer exists, and a caller that
	 * looped on it would spin.  It is told apart from an empty wait.
	 */
	if(o9ctl(o, buf, (int)(e-buf)) < 0)
		return -1;
	if(o->map->selected == ~0ULL)
		return O9nothing;
	return (int)o->map->selected;
}

uvlong
o9semcount(Osprey *o, int n)
{
	if(n < 0 || (uvlong)n >= o->map->nsem)
		return 0;
	return o->sem[n].count;
}
