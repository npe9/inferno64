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
 * Everything about the shape of the span, and the code that works it,
 * is in os/osprey/libosprey9: the structures here are the kernel's own
 * declarations rather than a copy of them.  The program still formats
 * its own output, through the library's o9out..., because the C
 * library's print cannot be linked with these.
 */
#include <u.h>
#include <libc.h>
#include <osprey9.h>

enum {
	Eaddrlen	= 6,
	Ehdrlen		= 14,
};

static Osprey o;
static uchar myea[Eaddrlen];
static uchar myip[4];

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
		if(o9num(p+8) != o.id)
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
		v = o9num(s);
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

	avail = o.map->txavail;
	for(i = 0; i < (int)o.map->ntxbuf && i < 64; i++)
		if(avail & (1ULL<<i))
			return i;
	return -1;
}

static int
sendbuf(int bi, long len)
{
	Message rep;

	if(o9call(&o, ReqSend, (uvlong)bi, (uvlong)len, 0, &rep) < 0){
		o9outs("netsrv: send refused, status "); o9outd(rep.arg[0]);
		o9outs(" why "); o9outd(rep.arg[2]); o9outs("\n");
		o9flush();
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
		o9outs("netsrv: no free transmit buffer for arp\n");
		o9flush();
		return 0;
	}

	t = o.base + o.map->txbuf + (uvlong)bi*o.map->txbufsize;
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
		o9outs("netsrv: no free transmit buffer for echo\n");
		o9flush();
		return 0;
	}
	if((uvlong)(Ehdrlen + 20 + iclen) > o.map->txbufsize)
		return 0;

	t = o.base + o.map->txbuf + (uvlong)bi*o.map->txbufsize;
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
	Message rep;
	uvlong slicesize, off;
	long n, got, arps, pings;
	int rxsem, txsem, i;

	if(argc < 6)
		o9die("usage: netsrv segment size rxsem txsem a.b.c.d");
	slicesize = o9num(argv[2]);
	rxsem = (int)o9num(argv[3]);
	txsem = (int)o9num(argv[4]);
	if(parseip4(argv[5], myip) < 0)
		o9die("that is not an address");
	if(o9attach(&o, argv[1], slicesize) < 0)
		o9die(o.err);
	if(findea() < 0)
		o9die("this container has no interface");

	o9outs("netsrv container "); o9outd(o.id);
	o9outs(" ea ");
	for(i = 0; i < Eaddrlen; i++){
		o9outhex(myea[i], 2);
		if(i < Eaddrlen-1)
			o9outs(":");
	}
	o9outs(" ip ");
	for(i = 0; i < 4; i++){
		o9outd(myip[i]);
		if(i < 3)
			o9outs(".");
	}
	o9outs("\n");
	o9flush();

	got = arps = pings = 0;
	for(;;){
		/*
		 * The talk's driver task waits on three things.  Two of them
		 * are here: a packet arriving and a transmit buffer coming
		 * back.  The third, its own message queue, is what the
		 * requests above go on, and this program is the only one
		 * putting them there.
		 */
		o9arm(&o, 0, OSdown, (uvlong)rxsem);
		o9arm(&o, 1, OSdown, (uvlong)txsem);
		/*
		 * A transmit buffer coming back needs nothing done: the
		 * kernel has already set its bit in the map.  The arm is
		 * here so that a program with every buffer in flight waits
		 * rather than spins.
		 */
		if((i = o9select(&o, 2)) == -1)
			o9die("the kernel will not wait for this container");
		if(i != 0)
			continue;

		/*
		 * Take the packet.  The reply says where in this slice the
		 * card put it; the frame is read where it lies.
		 */
		if(o9call(&o, ReqRecv, 0, 0, 0, &rep) < 0)
			continue;
		off = rep.arg[2];
		n = (long)rep.arg[3];
		if(off >= slicesize || (uvlong)n > slicesize - off)
			continue;
		got++;
		if(n < Ehdrlen)
			continue;
		switch(nhgets(o.base + off + 12)){
		case 0x0806:
			arps += answerarp(o.base + off, n);
			break;
		case 0x0800:
			pings += answerping(o.base + off, n);
			break;
		}
		/*
		 * Not every frame: the console is a uart, and a program
		 * that says something about each of four hundred of them
		 * spends its time in the driver rather than answering.
		 */
		if((got % 16) == 0){
			o9outs("netsrv "); o9outd(got);
			o9outs(" frames, "); o9outd(arps);
			o9outs(" arp, "); o9outd(pings);
			o9outs(" echo\n");
			o9flush();
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
