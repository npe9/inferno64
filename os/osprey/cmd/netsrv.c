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
 * address, answer ICMP echo, and, when it is given a rule, drop echo
 * from a blocked source and count it - the talk's packet filter, run in
 * user space over the frames the card put in the container's own slice.
 * The rest is enough to be
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

static ulong
nhgetl(uchar *p)
{
	return (ulong)p[0]<<24 | (ulong)p[1]<<16 | (ulong)p[2]<<8 | p[3];
}

static void
hnputl(uchar *p, ulong v)
{
	p[0] = (uchar)(v>>24);
	p[1] = (uchar)(v>>16);
	p[2] = (uchar)(v>>8);
	p[3] = (uchar)v;
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

/*
 * UDP echo: a datagram to our port 7 is answered with its own payload,
 * from us back to whoever sent it, addresses and ports swapped.  This is
 * the next reach of the user-space stack past ICMP - a real transport
 * datagram built and sent on the same zero-copy path - the start of the
 * "UDP and TCP" the plan names.
 */
static int
answerudp(uchar *f, long n)
{
	uchar *ip, *ud, *t, *tip, *tud;
	long hl, iplen, udlen, dlen;

	if(n < Ehdrlen + 20)
		return 0;
	ip = f + Ehdrlen;
	if((ip[0]>>4) != 4)
		return 0;
	hl = (ip[0] & 0xf) * 4;
	if(hl < 20 || n < Ehdrlen + hl + 8)
		return 0;
	if(ip[9] != 17)					/* udp */
		return 0;
	if(memcmp(ip+16, myip, 4) != 0)			/* not for us */
		return 0;
	iplen = nhgets(ip+2);
	if(iplen < hl + 8 || Ehdrlen + iplen > n)
		return 0;
	ud = ip + hl;
	if(nhgets(ud+2) != 7)				/* our echo port */
		return 0;
	udlen = nhgets(ud+4);				/* udp length: header + data */
	if(udlen < 8 || hl + udlen > iplen)
		return 0;
	dlen = udlen - 8;
	if((uvlong)(Ehdrlen + 20 + udlen) > o.map->txbufsize)
		return 0;
	{
		int bi = freebuf();
		if(bi < 0){
			o9outs("netsrv: no free transmit buffer for udp\n");
			o9flush();
			return 0;
		}
		t = o.base + o.map->txbuf + (uvlong)bi*o.map->txbufsize;
		memmove(t, f+Eaddrlen, Eaddrlen);	/* back where it came from */
		memset(t+Eaddrlen, 0, Eaddrlen);
		hnputs(t+12, 0x0800);
		tip = t + Ehdrlen;
		memset(tip, 0, 20);
		tip[0] = 0x45;
		hnputs(tip+2, (ushort)(20 + udlen));
		tip[8] = 64;				/* ttl */
		tip[9] = 17;				/* udp */
		memmove(tip+12, myip, 4);
		memmove(tip+16, ip+12, 4);		/* to the sender */
		hnputs(tip+10, csum(tip, 20));
		tud = tip + 20;
		hnputs(tud+0, 7);			/* from our port */
		hnputs(tud+2, nhgets(ud+0));		/* to the sender's port */
		hnputs(tud+4, (ushort)udlen);
		hnputs(tud+6, 0);			/* checksum optional in ipv4 udp */
		memmove(tud+8, ud+8, dlen);		/* the payload, back */
		return sendbuf(bi, Ehdrlen + 20 + udlen) == 0;
	}
}

/*
 * A minimal TCP echo, item 7's transport past a datagram: one connection
 * at a time to the stack's echo port, the three-way handshake answered,
 * data acknowledged and sent back, the close answered.  There is no
 * retransmit and no window past a fixed one - a real TCP is a larger
 * machine - but the handshake, the sequence and acknowledgement numbers
 * and the checksum over the pseudo-header are the real ones, so a real
 * TCP on the other end (9front's) talks to it.
 */
enum {
	TCPfin = 1, TCPsyn = 2, TCPrst = 4, TCPpsh = 8, TCPack = 16,
};
static int tcpup;			/* a connection is in progress */
static uchar tcppeerip[4];
static ushort tcppeerport;
static ulong tcprcvnxt;			/* the next of theirs we expect */
static ulong tcpsndnxt;			/* the next of ours to send */

/* the ones-complement sum tcp wants: the pseudo-header, then the segment */
static ushort
tcpcsum(uchar *srcip, uchar *dstip, uchar *seg, int seglen)
{
	ulong s;
	int i;

	s = 0;
	s += (ulong)srcip[0]<<8 | srcip[1];
	s += (ulong)srcip[2]<<8 | srcip[3];
	s += (ulong)dstip[0]<<8 | dstip[1];
	s += (ulong)dstip[2]<<8 | dstip[3];
	s += 6;				/* protocol */
	s += seglen;
	for(i = 0; i+1 < seglen; i += 2)
		s += (ulong)seg[i]<<8 | seg[i+1];
	if(i < seglen)
		s += (ulong)seg[i]<<8;
	while(s>>16)
		s = (s & 0xffff) + (s>>16);
	return (ushort)(~s & 0xffff);
}

/* build and send one tcp segment: flags, our seq/ack, and dlen bytes of payload from data */
static int
tcpsend(uchar *toea, uchar *toip, ushort toport, int flags, ulong seq, ulong ack, uchar *data, int dlen)
{
	uchar *t, *tip, *tcp;
	int bi, seglen;

	seglen = 20 + dlen;
	if((uvlong)(Ehdrlen + 20 + seglen) > o.map->txbufsize)
		return 0;
	if((bi = freebuf()) < 0)
		return 0;
	t = o.base + o.map->txbuf + (uvlong)bi*o.map->txbufsize;
	memmove(t, toea, Eaddrlen);
	memset(t+Eaddrlen, 0, Eaddrlen);
	hnputs(t+12, 0x0800);
	tip = t + Ehdrlen;
	memset(tip, 0, 20);
	tip[0] = 0x45;
	hnputs(tip+2, (ushort)(20 + seglen));
	tip[8] = 64;
	tip[9] = 6;				/* tcp */
	memmove(tip+12, myip, 4);
	memmove(tip+16, toip, 4);
	hnputs(tip+10, csum(tip, 20));
	tcp = tip + 20;
	memset(tcp, 0, 20);
	hnputs(tcp+0, 7);			/* our port */
	hnputs(tcp+2, toport);
	hnputl(tcp+4, seq);
	hnputl(tcp+8, ack);
	tcp[12] = 5<<4;				/* data offset: 5 words, no options */
	tcp[13] = (uchar)flags;
	hnputs(tcp+14, 4096);			/* a fixed window */
	if(dlen > 0)
		memmove(tcp+20, data, dlen);
	hnputs(tcp+16, tcpcsum(myip, toip, tcp, seglen));
	return sendbuf(bi, Ehdrlen + 20 + seglen) == 0;
}

static int
answertcp(uchar *f, long n)
{
	uchar *ip, *tcp;
	long hl, iplen, thl, dlen;
	ulong seq;
	ushort sport;
	int flags;

	if(n < Ehdrlen + 20)
		return 0;
	ip = f + Ehdrlen;
	if((ip[0]>>4) != 4)
		return 0;
	hl = (ip[0] & 0xf) * 4;
	if(hl < 20 || n < Ehdrlen + hl + 20)
		return 0;
	if(ip[9] != 6)					/* tcp */
		return 0;
	if(memcmp(ip+16, myip, 4) != 0)			/* not for us */
		return 0;
	iplen = nhgets(ip+2);
	if(iplen < hl + 20 || Ehdrlen + iplen > n)
		return 0;
	tcp = ip + hl;
	if(nhgets(tcp+2) != 7)				/* our echo port */
		return 0;
	thl = (tcp[12]>>4) * 4;
	if(thl < 20 || hl + thl > iplen)
		return 0;
	sport = nhgets(tcp+0);
	seq = nhgetl(tcp+4);
	flags = tcp[13];
	dlen = iplen - hl - thl;

	if(flags & TCPsyn){
		/* open: remember the peer, ack its SYN, offer ours */
		memmove(tcppeerip, ip+12, 4);
		tcppeerport = sport;
		tcprcvnxt = seq + 1;			/* SYN takes one sequence */
		tcpsndnxt = 1000;			/* our initial sequence */
		tcpup = 1;
		tcpsend(f+Eaddrlen, tcppeerip, sport, TCPsyn|TCPack, tcpsndnxt, tcprcvnxt, nil, 0);
		tcpsndnxt += 1;				/* our SYN takes one */
		return 1;
	}
	if(!tcpup || sport != tcppeerport || memcmp(ip+12, tcppeerip, 4) != 0)
		return 0;				/* not this connection */
	if(dlen > 0){
		/* data: acknowledge it and echo it back in one segment */
		tcprcvnxt = seq + dlen;
		tcpsend(f+Eaddrlen, tcppeerip, sport, TCPpsh|TCPack, tcpsndnxt, tcprcvnxt, tcp+thl, (int)dlen);
		tcpsndnxt += dlen;
		return 1;
	}
	if(flags & TCPfin){
		/* close: acknowledge their FIN and send ours */
		tcprcvnxt = seq + 1;
		tcpsend(f+Eaddrlen, tcppeerip, sport, TCPfin|TCPack, tcpsndnxt, tcprcvnxt, nil, 0);
		tcpsndnxt += 1;
		tcpup = 0;
		return 1;
	}
	return 0;				/* a bare ack: nothing to send */
}

static uchar blockip[4];		/* an echo source to drop, or zero for none */
static int blocking;
static long dropped;

/* the filter: whether this frame is to be dropped rather than answered */
static int
blocked(uchar *ip)
{
	return blocking && memcmp(ip+12, blockip, 4) == 0;
}

static void
srvmain(int argc, char **argv)
{
	Message rep;
	uvlong slicesize, off;
	long n, got, arps, pings, udps, tcps;
	int rxsem, txsem, i;

	if(argc < 6)
		o9die("usage: netsrv segment size rxsem txsem a.b.c.d");
	slicesize = o9num(argv[2]);
	rxsem = (int)o9num(argv[3]);
	txsem = (int)o9num(argv[4]);
	if(parseip4(argv[5], myip) < 0)
		o9die("that is not an address");
	if(argc > 6 && parseip4(argv[6], blockip) == 0)
		blocking = 1;
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
	if(blocking){
		o9outs("netsrv filter: echo from ");
		for(i = 0; i < 4; i++){ o9outd(blockip[i]); if(i < 3) o9outs("."); }
		o9outs(" is dropped\n");
	}
	o9flush();

	got = arps = pings = udps = tcps = 0;
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
			if(n >= Ehdrlen + 20 && o.base[off+Ehdrlen+9] == 1
			&& blocked(o.base + off + Ehdrlen)){
				dropped++;	/* the filter: an echo from the blocked source */
				o9outs("netsrv filter: dropped an echo, "); o9outd(dropped);
				o9outs(" so far\n"); o9flush();
				break;
			}
			pings += answerping(o.base + off, n);
			if(answerudp(o.base + off, n)){
				udps++;
				o9outs("netsrv udp: echoed a datagram, "); o9outd(udps);
				o9outs(" so far\n"); o9flush();
			}
			if(answertcp(o.base + off, n)){
				tcps++;
				o9outs("netsrv tcp: a segment answered, "); o9outd(tcps);
				o9outs(" so far\n"); o9flush();
			}
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
