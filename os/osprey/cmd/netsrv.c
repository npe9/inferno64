/*
 * netsrv - the protocol stack, outside the kernel.
 *
 * The Osprey plan asks for protocol stacks and packet processing in
 * user space over shared packet buffers with zero-copy paths.  The
 * buffers are in os/osprey/port/devosprey.c: a container that has been
 * given an interface lends the card receive buffers out of its own
 * slice and fills transmit buffers in the same slice for the card to
 * read.  Nothing between the wire and this program copies a frame.
 *
 * This is the talk's driver task with all three of its arms: it selects
 * on its own request ring, on the semaphore a received packet gives,
 * and on the semaphore a transmit buffer gives when the card has
 * finished with it.  What it does with a frame is answer ARP for one
 * address and answer ICMP echo, which is the whole of it: enough to be
 * pinged, and nothing more.
 *
 * usage: netsrv segment size rxsem txsem a.b.c.d
 *
 * The segment is this container's slice and the size is that slice's,
 * as /n/osprey/status reports.  The two semaphores are the ones named
 * to the ether control message.  The address is the one this program
 * answers for.
 *
 * As with ring(1) and p9srv(1) the program uses only the system calls
 * out of the library and formats its own output: the library here was
 * built by a newer compiler than this loader reads.
 */
#include <u.h>
#include <libc.h>

typedef struct Ospreymap Ospreymap;
typedef struct Queue Queue;
typedef struct Message Message;
typedef struct Arm Arm;

enum {
	Ospreymagic	= 0x4f53505259ULL,
	Nword		= 5,
	Narm		= 8,
	Eaddrlen	= 6,
	Ehdrlen		= 14,
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
	uvlong	txbuf;
	uvlong	ntxbuf;
	uvlong	txbufsize;
	uvlong	txavail;
};

struct Queue {
	vlong	message;
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

struct Arm {
	uvlong	op;
	uvlong	obj;
	uvlong	buf;
};

enum {				/* arm operations */
	OSlast,
	OSnoop,
	OSget,
	OSput,
	OSdown,
};

enum {				/* request operations, as syscall.h orders them */
	Opread, Opwrite, Opopen, Opclose, Opwait, Opsend,
	Oprecv, Opstat, Opbind, Opalloc, Opyield, Oppoll,
};

enum {				/* reply status */
	Stpending, Stdone, Sterror, Stblocked, Stretry,
};

static char obuf[512];
static int on;

static uchar *base;
static Ospreymap *map;
static Queue *rq, *pq;
static Message *rm, *pm;
static int ctlfd = -1;
static uvlong myid;
static uchar myea[Eaddrlen];
static uchar myip[4];


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
outhex(uvlong v, int digits)
{
	char b[20];
	int i;

	for(i = digits; i > 0; i--){
		b[i-1] = "0123456789abcdef"[v & 0xf];
		v >>= 4;
	}
	b[digits] = '\0';
	outs(b);
}

static void
die(char *s)
{
	outs("netsrv: ");
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
catstr(char *d, char *s)
{
	while(*s != '\0')
		*d++ = *s++;
	return d;
}

static char*
catnum(char *d, uvlong v)
{
	char b[24];
	int i;

	i = sizeof b;
	b[--i] = '\0';
	do {
		b[--i] = '0' + (int)(v % 10);
		v /= 10;
	} while(v != 0 && i > 0);
	return catstr(d, b+i);
}

static int
hexval(int c)
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

/*
 * This container's own ethernet address, which the kernel reports on
 * the packets line of status because the card is the kernel's and the
 * address is the card's.  A frame this program builds carries it in the
 * arp body; the kernel writes it into the frame header itself.
 */
static int
findea(void)
{
	static char st[33*1024];
	char *p, *e, *l;
	long n, t;
	int fd, i, hi, lo;

	if((fd = open("/n/osprey/status", OREAD)) < 0)
		return -1;
	for(t = 0; t < sizeof st - 1; t += n)
		if((n = read(fd, st+t, sizeof st - 1 - t)) <= 0)
			break;
	close(fd);
	if(t <= 0)
		return -1;
	st[t] = '\0';
	for(p = st; *p != '\0'; p = e){
		if((e = strchr(p, '\n')) != nil)
			*e++ = '\0';
		else
			e = p + strlen(p);
		if(strncmp(p, "packets ", 8) != 0)
			continue;
		if(num(p+8) != myid)
			continue;
		for(l = p+8; *l != '\0'; l++){
			if(strncmp(l, " ea ", 4) != 0)
				continue;
			l += 4;
			for(i = 0; i < Eaddrlen; i++){
				if((hi = hexval(l[0])) < 0
				|| (lo = hexval(l[1])) < 0)
					return -1;
				myea[i] = (uchar)(hi<<4 | lo);
				l += 2;
			}
			return 0;
		}
		return -1;
	}
	return -1;
}

/* a.b.c.d into four bytes */
static int
parseip4(char *s, uchar *to)
{
	uvlong v;
	int i;

	for(i = 0; i < 4; i++){
		v = num(s);
		if(v > 255)
			return -1;
		to[i] = (uchar)v;
		while(*s >= '0' && *s <= '9')
			s++;
		if(i < 3){
			if(*s != '.')
				return -1;
			s++;
		}
	}
	return 0;
}

/*
 * Wait on the arms just built.  This is the only trap the program
 * takes: taking a packet, building an answer and handing it back are
 * all done in the mapped slice.
 */
static int
selectarms(int narm)
{
	char buf[64], *e;

	e = buf;
	e = catstr(e, "select ");
	e = catnum(e, myid);
	e = catstr(e, " 0 ");
	e = catnum(e, narm);
	e = catstr(e, "\n");
	return write(ctlfd, buf, e-buf) < 0 ? -1 : 0;
}

/* put one request on this container's own ring and wait for its answer */
static int
ask(uvlong op, uvlong a0, uvlong a1, uvlong a2, Message *rep)
{
	Message msg;
	int i;

	if(rq->put - rq->get >= rq->size)
		return -1;
	memset(&msg, 0, sizeof msg);
	msg.op = op;
	msg.sequence = rq->put + 1;
	msg.container = myid;
	msg.arg[2] = a0;
	msg.arg[3] = a1;
	msg.arg[4] = a2;
	rm[rq->put % rq->size] = msg;
	rq->put++;
	for(i = 0; i < 200; i++){
		if(pq->put != pq->get){
			*rep = pm[pq->get % pq->size];
			pq->get++;
			return 0;
		}
		sleep(5);
	}
	return -1;
}

static ushort
nhgets(uchar *p)
{
	return (ushort)(p[0]<<8 | p[1]);
}

static void
hnputs(uchar *p, ushort v)
{
	p[0] = (uchar)(v>>8);
	p[1] = (uchar)v;
}

/* the ones complement sum an ip header and an icmp body want */
static ushort
csum(uchar *a, int n)
{
	ulong s;
	int i;

	s = 0;
	for(i = 0; i+1 < n; i += 2)
		s += (ulong)a[i]<<8 | a[i+1];
	if(i < n)
		s += (ulong)a[i]<<8;
	while(s>>16)
		s = (s & 0xffff) + (s>>16);
	return (ushort)(~s & 0xffff);
}

/*
 * A transmit buffer this program is allowed to fill, or -1.  The kernel
 * keeps the word: a bit is set while the card has finished with that
 * buffer.  Reading it is a load out of this container's own map, so
 * finding a buffer costs nothing.
 */
static int
freebuf(void)
{
	uvlong avail;
	int i;

	avail = map->txavail;
	for(i = 0; i < (int)map->ntxbuf && i < 64; i++)
		if(avail & (1ULL<<i))
			return i;
	return -1;
}

static int
sendbuf(int bi, long len)
{
	Message rep;

	if(ask(Opsend, (uvlong)bi, (uvlong)len, 0, &rep) < 0){
		outs("netsrv: no answer to send\n");
		flush();
		return -1;
	}
	if(rep.arg[0] != Stdone){
		outs("netsrv: send status "); outd(rep.arg[0]);
		outs(" why "); outd(rep.arg[2]); outs("\n");
		flush();
		return -1;
	}
	return 0;
}

/*
 * Somebody asked who has our address.  The answer is the same frame
 * turned round: a reply, from us, to them.
 */
static int
answerarp(uchar *f, long n)
{
	uchar *a, *t;
	int bi;

	if(n < Ehdrlen + 28)
		return 0;
	a = f + Ehdrlen;
	if(nhgets(a) != 1 || nhgets(a+2) != 0x0800)	/* ethernet, ip */
		return 0;
	if(a[4] != Eaddrlen || a[5] != 4)
		return 0;
	if(nhgets(a+6) != 1)				/* a request */
		return 0;
	if(memcmp(a+24, myip, 4) != 0)			/* not for us */
		return 0;
	if((bi = freebuf()) < 0){
		outs("netsrv: no free transmit buffer for arp\n");
		flush();
		return 0;
	}

	t = base + map->txbuf + (uvlong)bi*map->txbufsize;
	memmove(t, a+8, Eaddrlen);			/* to whoever asked */
	memset(t+Eaddrlen, 0, Eaddrlen);		/* the kernel fills this */
	hnputs(t+12, 0x0806);
	hnputs(t+Ehdrlen+0, 1);
	hnputs(t+Ehdrlen+2, 0x0800);
	t[Ehdrlen+4] = Eaddrlen;
	t[Ehdrlen+5] = 4;
	hnputs(t+Ehdrlen+6, 2);				/* a reply */
	memmove(t+Ehdrlen+8, myea, Eaddrlen);
	memmove(t+Ehdrlen+14, myip, 4);
	memmove(t+Ehdrlen+18, a+8, Eaddrlen);
	memmove(t+Ehdrlen+24, a+14, 4);
	return sendbuf(bi, Ehdrlen + 28) == 0;
}

/* and an echo request becomes an echo reply, turned round the same way */
static int
answerping(uchar *f, long n)
{
	uchar *ip, *ic, *t, *tip, *tic;
	long hl, iplen, iclen;
	int bi;

	if(n < Ehdrlen + 20)
		return 0;
	ip = f + Ehdrlen;
	if((ip[0]>>4) != 4)
		return 0;
	hl = (ip[0] & 0xf) * 4;
	if(hl < 20 || n < Ehdrlen + hl + 8)
		return 0;
	if(ip[9] != 1)					/* icmp */
		return 0;
	if(memcmp(ip+16, myip, 4) != 0)			/* not for us */
		return 0;
	iplen = nhgets(ip+2);
	if(iplen < hl + 8 || Ehdrlen + iplen > n)
		return 0;
	ic = ip + hl;
	if(ic[0] != 8)					/* echo request */
		return 0;
	iclen = iplen - hl;
	if((bi = freebuf()) < 0){
		outs("netsrv: no free transmit buffer for echo\n");
		flush();
		return 0;
	}
	if((uvlong)(Ehdrlen + 20 + iclen) > map->txbufsize)
		return 0;

	t = base + map->txbuf + (uvlong)bi*map->txbufsize;
	memmove(t, f+Eaddrlen, Eaddrlen);		/* back where it came from */
	memset(t+Eaddrlen, 0, Eaddrlen);
	hnputs(t+12, 0x0800);

	tip = t + Ehdrlen;
	memset(tip, 0, 20);
	tip[0] = 0x45;
	hnputs(tip+2, (ushort)(20 + iclen));
	tip[8] = 64;					/* ttl */
	tip[9] = 1;					/* icmp */
	memmove(tip+12, myip, 4);
	memmove(tip+16, ip+12, 4);
	hnputs(tip+10, csum(tip, 20));

	tic = tip + 20;
	memmove(tic, ic, iclen);
	tic[0] = 0;					/* echo reply */
	tic[2] = tic[3] = 0;
	hnputs(tic+2, csum(tic, iclen));
	return sendbuf(bi, Ehdrlen + 20 + iclen) == 0;
}

static void
srvmain(int argc, char **argv)
{
	Arm *a;
	Message rep;
	uvlong bufoff, slicesize, off;
	long n, got, arps, pings;
	int rxsem, txsem, i;

	if(argc < 6)
		die("usage: netsrv segment size rxsem txsem a.b.c.d");
	slicesize = num(argv[2]);
	rxsem = (int)num(argv[3]);
	txsem = (int)num(argv[4]);
	if(parseip4(argv[5], myip) < 0)
		die("that is not an address");

	base = (uchar*)segattach(0, argv[1], 0, slicesize);
	if(base == (uchar*)-1)
		die("segattach failed");
	map = (Ospreymap*)base;
	if(map->magic != Ospreymagic)
		die("no container mapped there");
	myid = map->id;
	rq = (Queue*)(base + map->requestqueue);
	pq = (Queue*)(base + map->replyqueue);
	rm = (Message*)(base + map->request);
	pm = (Message*)(base + map->reply);

	if((ctlfd = open("/n/osprey/ctl", OWRITE)) < 0)
		die("cannot open /n/osprey/ctl");
	if(findea() < 0)
		die("this container has no interface");

	a = (Arm*)(base + map->data);
	bufoff = (uvlong)(Narm*sizeof(Arm));

	outs("netsrv container "); outd(myid);
	outs(" ea ");
	for(i = 0; i < Eaddrlen; i++){
		outhex(myea[i], 2);
		if(i < Eaddrlen-1)
			outs(":");
	}
	outs(" ip ");
	for(i = 0; i < 4; i++){
		outd(myip[i]);
		if(i < 3)
			outs(".");
	}
	outs("\n");
	flush();

	got = arps = pings = 0;
	for(;;){
		/*
		 * The talk's driver task waits on three things.  Two of them
		 * are here: a packet arriving and a transmit buffer coming
		 * back.  The third, its own message queue, is what the
		 * requests above go on, and this program is the only one
		 * putting them there.
		 */
		a[0].op = OSdown; a[0].obj = (uvlong)rxsem; a[0].buf = bufoff;
		a[1].op = OSdown; a[1].obj = (uvlong)txsem; a[1].buf = bufoff;
		a[2].op = OSlast; a[2].obj = 0; a[2].buf = 0;
		if(selectarms(3) < 0)
			die("select failed");
		/*
		 * A transmit buffer coming back needs nothing done: the
		 * kernel has already set its bit in the map.  The arm is
		 * here so that a program with every buffer in flight waits
		 * rather than spins.
		 */
		if(map->selected != 0)
			continue;

		/*
		 * Take the packet.  The reply says where in this slice the
		 * card put it; the frame is read where it lies.
		 */
		if(ask(Oprecv, 0, 0, 0, &rep) < 0)
			continue;
		if(rep.arg[0] != Stdone)
			continue;
		off = rep.arg[2];
		n = (long)rep.arg[3];
		if(off >= slicesize || (uvlong)n > slicesize - off)
			continue;
		got++;
		if(n < Ehdrlen)
			continue;
		switch(nhgets(base + off + 12)){
		case 0x0806:
			arps += answerarp(base + off, n);
			break;
		case 0x0800:
			pings += answerping(base + off, n);
			break;
		}
		/*
		 * Not every frame: the console is a uart, and a program
		 * that says something about each of four hundred of them
		 * spends its time in the driver rather than answering.
		 */
		if((got % 16) == 0){
			outs("netsrv "); outd(got);
			outs(" frames, "); outd(arps);
			outs(" arp, "); outd(pings);
			outs(" echo\n");
			flush();
		}
	}
}

void
_main(char *argv0)
{
	char **argv;
	int argc;

	argv = &argv0;
	for(argc = 0; argv[argc] != nil; argc++)
		;
	srvmain(argc, argv);
	exits(nil);
}
