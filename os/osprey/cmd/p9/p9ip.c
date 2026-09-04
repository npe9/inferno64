#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"ip.h"

/*
 * The Plan 9 IP stack, run in the personality as a user-space service.
 * ipprotoinit is the list of protocols the stack brings up - the same
 * list a kernel config generates, tcp and udp among them - so that the
 * real tcp.c and udp.c register with the Fs.  The bring-up that mounts
 * #I at /net, binds the loopback medium and configures 127.0.0.1, and a
 * loopback TCP round-trip that the real tcp.c handles, go here as they
 * are written.
 */
extern void tcpinit(Fs*), udpinit(Fs*), rudpinit(Fs*), ipifcinit(Fs*);
extern void icmpinit(Fs*), icmp6init(Fs*), igmpinit(Fs*), greinit(Fs*);
extern void ipmuxinit(Fs*), ilinit(Fs*);

void (*ipprotoinit[])(Fs*) = {
	tcpinit,
	udpinit,
	rudpinit,
	ipifcinit,
	icmpinit,
	icmp6init,
	igmpinit,
	greinit,
	ipmuxinit,
	ilinit,
	nil,
};

extern void loopbackmediumlink(void);
extern void ospreymediumlink(void);
extern void ospreyvnetmediumlink(void);	/* ospreyvnetmedium.c: the real wire, the exposed virtio network device */
extern void p9kbdstart(void);		/* p9kbd.c: the user-space i8042 keyboard driver */
extern int p9open(char*, int);
extern long p9read(int, void*, long);
extern long p9write(int, void*, long);
extern void p9close(int);

/*
 * A tiny proof that timed sleep works off the osprey clock: a kproc that
 * sleeps 100ms and prints, five times.  It parks in tsleep during p9ipup
 * (no ticks yet) and wakes once the server loop starts delivering ticks,
 * showing the deadline path and the tick-driven scheduler run.
 */
static void
ticktest(void *)
{
	int i;

	for(i = 0; i < 5; i++){
		tsleep(&up->sleep, return0, nil, 100);
		print("p9 sched: timed kproc woke after ~100ms, tick %d\n", i + 1);
	}
}

/*
 * The osprey-medium proof, run as a kproc so it lives during the server
 * loop where the medium's inbound is pumped.  It announces a port, then
 * connects to 10.0.0.1 - the osprey interface's own address, so the route
 * sends the SYN out that interface, through ospreybwrite, back in through
 * the loop's ospreymediumpump, and into the stack.  If the handshake
 * reaches Established and the osprey interface's own packet counters have
 * moved, the loop-driven medium carried a real tcp.c conversation.
 */
static void
ostcp(void *)
{
	int afd, dfd, dfd2, sfd, anum, cnum, lnum;
	long n;
	char cbuf[64], line[256], path[64], *e;

	tsleep(&up->sleep, return0, nil, 200);	/* let the server loop start ticking */
	if(waserror()){
		print("p9 ip: osprey-medium tcp failed: %s\n", up->errstr);
		pexit("ostcp", 0);
	}
	/* two independent stacks over the osprey wire: stack B (#I1, 10.0.0.2)
	 * announces; stack A (/net, 10.0.0.1) connects to it, the SYN crosses
	 * the medium and the two stacks' tcp.c handshakes; then a byte stream
	 * crosses between them */
	afd = p9open("#I1/tcp/clone", ORDWR);
	n = p9read(afd, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; anum=atoi(cbuf);
	p9write(afd, "announce 8888", 13);
	dfd = p9open("/net/tcp/clone", ORDWR);
	n = p9read(dfd, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; cnum=atoi(cbuf);
	print("p9 ip: osprey wire: stack A (10.0.0.1) connecting to stack B (10.0.0.2)!8888\n");
	p9write(dfd, "connect 10.0.0.2!8888", 21);

	snprint(path, sizeof path, "/net/tcp/%d/status", cnum);
	sfd = p9open(path, OREAD); n = p9read(sfd, line, sizeof line - 1); p9close(sfd);
	if(n<0)n=0; line[n]=0;
	for(e=line; *e && *e!='\n'; e++) ; *e=0;
	if(strncmp(line, "Established", 11) == 0)
		print("p9 ip: osprey wire: the two stacks' tcp.c completed a handshake over the medium - %s\n", line);
	else
		print("p9 ip: osprey wire: handshake did not reach Established - %s\n", line);

	tsleep(&up->sleep, return0, nil, 100);		/* let the final ACK reach stack B */
	snprint(path, sizeof path, "#I1/tcp/%d/listen", anum);
	dfd2 = p9open(path, ORDWR);			/* the listen fd IS the accepted conv's ctl - keep it open to hold it */
	n = p9read(dfd2, cbuf, sizeof cbuf - 1);
	if(n<0)n=0; cbuf[n]=0; lnum = atoi(cbuf);
	print("p9 ip: osprey wire: stack B accepted the flow as conversation %d\n", lnum);

	/* a byte stream across the two stacks: stack A writes, stack B reads */
	{
		int wfd, rfd, tries; char rx[128];
		static char wire[] = "a byte stream across two stacks over the osprey medium";
		snprint(path, sizeof path, "#I1/tcp/%d/data", lnum);
		rfd = p9open(path, ORDWR);
		snprint(path, sizeof path, "/net/tcp/%d/data", cnum);
		wfd = p9open(path, ORDWR);
		p9write(wfd, wire, sizeof wire - 1);
		for(tries = 0, n = 0; tries < 20 && n <= 0; tries++){
			tsleep(&up->sleep, return0, nil, 50);	/* let the pump carry the segment */
			n = p9read(rfd, rx, sizeof rx - 1);
		}
		if(n<0)n=0; rx[n]=0;
		if(n == (long)(sizeof wire - 1) && memcmp(rx, wire, n) == 0){
			static char back[] = "and a reply back from stack B to stack A";
			print("p9 ip: osprey wire: stack B read the %ld bytes stack A sent: \"%s\" - byte stream across two independent stacks verified\n", n, rx);
			/* the other way: stack B writes, stack A reads - full duplex */
			p9write(rfd, back, sizeof back - 1);
			for(tries = 0, n = 0; tries < 20 && n <= 0; tries++){
				tsleep(&up->sleep, return0, nil, 50);
				n = p9read(wfd, rx, sizeof rx - 1);
			}
			if(n<0)n=0; rx[n]=0;
			if(n == (long)(sizeof back - 1) && memcmp(rx, back, n) == 0)
				print("p9 ip: osprey wire: stack A read the %ld bytes stack B sent back: \"%s\" - full-duplex byte stream across two stacks verified\n", n, rx);
			else
				print("p9 ip: osprey wire: reply stream short (%ld bytes)\n", n);
		} else
			print("p9 ip: osprey wire: data stream short (%ld bytes)\n", n);
		p9close(rfd); p9close(wfd);
	}

	USED(anum);
	p9close(dfd2); p9close(dfd); p9close(afd);
	poperror();
	pexit("ostcp done", 0);
}

/*
 * The server end of the device-carried wire, as a service: announce a
 * port on stack B - the stack whose osprey interface 10.0.1.2 is the
 * ring to the client container - accept the connection the client
 * container's own tcp.c makes across the ring, read what it sends, and
 * answer.  Both the listen and the read block cooperatively; the frames
 * that carry the conversation cross the ring on the client's requests
 * and this loop's replies.
 */
static void
ringsrv(void *)
{
	int afd, lfd, dfd, anum, lnum;
	long n;
	char cbuf[64], path[64], rx[256];
	static char reply[] = "answered by the server container's own tcp.c, across the ring";

	if(waserror()){
		print("p9 ip: ring server failed: %s\n", up->errstr);
		pexit("ringsrv", 0);
	}
	afd = p9open("#I1/tcp/clone", ORDWR);
	n = p9read(afd, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; anum=atoi(cbuf);
	p9write(afd, "announce 9999", 13);
	print("p9 ip: ring server: tcp!*!9999 announced on stack B for the client container\n");
	snprint(path, sizeof path, "#I1/tcp/%d/listen", anum);
	lfd = p9open(path, ORDWR);		/* blocks until the client container connects */
	n = p9read(lfd, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; lnum=atoi(cbuf);
	print("p9 ip: ring server: accepted a connection from the client container's tcp.c across the ring as conversation %d\n", lnum);
	snprint(path, sizeof path, "#I1/tcp/%d/data", lnum);
	dfd = p9open(path, ORDWR);
	n = p9read(dfd, rx, sizeof rx - 1); if(n<0)n=0; rx[n]=0;
	print("p9 ip: ring server: read %ld bytes the client container's stack sent across the ring: \"%s\"\n", n, rx);
	p9write(dfd, reply, sizeof reply - 1);
	print("p9 ip: ring server: answered with %d bytes\n", (int)(sizeof reply - 1));
	tsleep(&up->sleep, return0, nil, 1000);	/* let the answer and its ack cross before the close does */
	p9close(dfd); p9close(lfd); p9close(afd);
	poperror();
	pexit("ringsrv done", 0);
}

/*
 * The service behind the gateway: the same shape as ringsrv, but on stack
 * A (/net, 10.0.0.1), which has no wire to the client container at all -
 * a connection from the client reaches it only if stack B forwards.
 * Afterwards it reads stack B's ip statistics and reports how many
 * datagrams B forwarded, the count the real ip.c keeps.
 */
static void
gwsrv(void *)
{
	int afd, lfd, dfd, anum, lnum, sfd;
	long n;
	char cbuf[64], path[64], rx[256], stats[1024], *p, *e;
	static char reply[] = "answered by stack A, behind the gateway";

	if(waserror()){
		print("p9 ip: gateway server failed: %s\n", up->errstr);
		pexit("gwsrv", 0);
	}
	afd = p9open("/net/tcp/clone", ORDWR);
	n = p9read(afd, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; anum=atoi(cbuf);
	p9write(afd, "announce 8890", 13);
	print("p9 ip: gateway server: tcp!*!8890 announced on stack A, which the client container can reach only through stack B\n");
	snprint(path, sizeof path, "/net/tcp/%d/listen", anum);
	lfd = p9open(path, ORDWR);
	n = p9read(lfd, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; lnum=atoi(cbuf);
	snprint(path, sizeof path, "/net/tcp/%d/remote", lnum);
	sfd = p9open(path, OREAD); n = p9read(sfd, rx, sizeof rx - 1); p9close(sfd);
	if(n<0)n=0; rx[n]=0;
	for(e=rx; *e && *e!='\n'; e++) ; *e=0;
	print("p9 ip: gateway server: stack A accepted a connection from %s, forwarded by stack B, as conversation %d\n", rx, lnum);
	snprint(path, sizeof path, "/net/tcp/%d/data", lnum);
	dfd = p9open(path, ORDWR);
	n = p9read(dfd, rx, sizeof rx - 1); if(n<0)n=0; rx[n]=0;
	print("p9 ip: gateway server: stack A read %ld bytes from the client container through the gateway: \"%s\"\n", n, rx);
	p9write(dfd, reply, sizeof reply - 1);
	/* the count now, not after a sleep: the client exits soon after it reads the answer, and the machine idles with it */
	sfd = p9open("#I1/ipifc/stats", OREAD);
	n = p9read(sfd, stats, sizeof stats - 1); p9close(sfd);
	if(n<0)n=0; stats[n]=0;
	p = strstr(stats, "ForwDatagrams:");
	if(p != nil){
		for(e=p; *e && *e!='\n'; e++) ; *e=0;
		print("p9 ip: gateway: stack B's ip.c forwarded the conversation - %s\n", p);
	}
	tsleep(&up->sleep, return0, nil, 1000);
	p9close(dfd); p9close(lfd); p9close(afd);
	poperror();
	pexit("gwsrv done", 0);
}

/*
 * Pi-p on a wire of its own.  The personality's pi-p (pipfsrv.c) has
 * been spoken over the ring, a group on a request and its replies on
 * the answer; here it is spoken on the wire between the two containers'
 * stacks: a tcp.c connection across the ring, carrying groups as
 * length-prefixed records each way (a 4-byte little-endian count, then
 * the messages).  A session is settled by number, so it outlives the
 * connection: a second connection resumes it and finds its fids still
 * open.  And on a wire a Tstream can be answered - the attribute keeps
 * arriving at its rate with nothing sent to make it happen - which over
 * the ring it could not be.  pipwire takes connections one after
 * another and serves the groups on each; pipstreamer, on every tick,
 * puts whatever the streams owe on the connection that is up.
 */
static int pipwirefd = -1;		/* the connection up now, for the streamer */

static long
readn(int fd, uchar *buf, long n)
{
	long k, got;

	for(got = 0; got < n; got += k){
		k = p9read(fd, buf + got, n - got);
		if(k <= 0)
			return got;
	}
	return got;
}

void
pipwire_put(int fd, uchar *rec, long n)
{
	uchar len[4];

	len[0] = n; len[1] = n>>8; len[2] = n>>16; len[3] = n>>24;
	p9write(fd, len, 4);
	if(n > 0)
		p9write(fd, rec, n);
}

long
pipwire_get(int fd, uchar *rec, long max)
{
	uchar len[4];
	long n;

	if(readn(fd, len, 4) != 4)
		return -1;
	n = len[0] | (len[1]<<8) | (len[2]<<16) | (len[3]<<24);
	if(n < 0 || n > max)
		return -1;
	if(readn(fd, rec, n) != n)
		return -1;
	return n;
}

static void
pipstreamer(void *)
{
	extern long pipfs_stream(uchar*, long);
	uchar out[2048];
	long n;

	for(;;){
		tsleep(&up->sleep, return0, nil, 10);
		if(pipwirefd < 0)
			continue;
		n = pipfs_stream(out, sizeof out);
		if(n > 0)
			pipwire_put(pipwirefd, out, n);
	}
}

static void
pipwire(void *)
{
	extern long pipfs_servewire(uchar*, long, uchar*, long);
	int afd, lfd, dfd, anum, lnum, conns;
	long n, rn;
	char cbuf[64], path[64];
	uchar tg[2048], rg[4096];

	if(waserror()){
		print("p9 ip: pi-p wire failed: %s\n", up->errstr);
		pipwirefd = -1;
		pexit("pipwire", 0);
	}
	afd = p9open("#I1/tcp/clone", ORDWR);
	n = p9read(afd, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; anum=atoi(cbuf);
	p9write(afd, "announce 9001", 13);
	print("p9 ip: pi-p wire: tcp!*!9001 announced on stack B - the personality's pi-p on a wire of its own\n");
	kproc("pipstreamer", pipstreamer, nil);
	for(conns = 1;; conns++){
		snprint(path, sizeof path, "#I1/tcp/%d/listen", anum);
		lfd = p9open(path, ORDWR);
		n = p9read(lfd, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; lnum=atoi(cbuf);
		snprint(path, sizeof path, "#I1/tcp/%d/data", lnum);
		dfd = p9open(path, ORDWR);
		print("p9 ip: pi-p wire: connection %d from the client container, conversation %d\n", conns, lnum);
		pipwirefd = dfd;
		while((n = pipwire_get(dfd, tg, sizeof tg)) >= 0){
			rn = pipfs_servewire(tg, n, rg, sizeof rg);
			print("p9 ip: pi-p wire: a %ld-byte group came over the wire on connection %d, answered with %ld bytes of replies\n", n, conns, rn);
			pipwire_put(dfd, rg, rn);
		}
		pipwirefd = -1;
		print("p9 ip: pi-p wire: connection %d closed; the sessions it carried live on\n", conns);
		p9close(dfd);
		p9close(lfd);
	}
}

/*
 * The real wire.  When the kernel has exposed a network device to this
 * container and netvirtio.c has brought it up, stack A binds the vnet
 * medium on it and takes an address from the device's MAC - 10.1.0.n
 * for a MAC ending in n - so two machines booted from the same image on
 * one wire know which they are: 1 answers, 2 asks.  Machine 1 announces
 * a port on the wire and answers a line; machine 2 connects to it
 * across the cable, its tcp.c to the other's, ARP and all, and reads
 * the answer.  Nothing but the two personalities' own stacks and the
 * drivers they run in user space is in the path; the kernels carry
 * interrupts and nothing else.
 */
extern int vnet_ready(void);
extern void vnet_mac(uchar*);
extern void vnet_stats(long*, long*, long*);

static void
wiresrv(void *)
{
	int afd, lfd, dfd, anum, lnum, sfd;
	long n, rx, tx, drops;
	char cbuf[64], path[64], rx1[256], *e;
	static char reply[] = "answered across the cable by machine 1's tcp.c in user space";

	if(waserror()){
		print("p9 wire: machine 1 failed: %s\n", up->errstr);
		pexit("wiresrv", 0);
	}
	afd = p9open("/net/tcp/clone", ORDWR);
	n = p9read(afd, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; anum=atoi(cbuf);
	p9write(afd, "announce 9005", 13);
	print("p9 wire: machine 1 announced tcp!*!9005 on the wire, 10.1.0.1\n");
	snprint(path, sizeof path, "/net/tcp/%d/listen", anum);
	lfd = p9open(path, ORDWR);
	n = p9read(lfd, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; lnum=atoi(cbuf);
	snprint(path, sizeof path, "/net/tcp/%d/remote", lnum);
	sfd = p9open(path, OREAD); n = p9read(sfd, rx1, sizeof rx1 - 1); p9close(sfd);
	if(n<0)n=0; rx1[n]=0;
	for(e=rx1; *e && *e!='\n'; e++) ; *e=0;
	print("p9 wire: machine 1 accepted a connection over the cable from %s as conversation %d\n", rx1, lnum);
	snprint(path, sizeof path, "/net/tcp/%d/data", lnum);
	dfd = p9open(path, ORDWR);
	n = p9read(dfd, rx1, sizeof rx1 - 1); if(n<0)n=0; rx1[n]=0;
	print("p9 wire: machine 1 read %ld bytes from the other machine: \"%s\"\n", n, rx1);
	p9write(dfd, reply, sizeof reply - 1);
	tsleep(&up->sleep, return0, nil, 1000);
	vnet_stats(&rx, &tx, &drops);
	print("p9 wire: machine 1 answered the other machine; its user-space driver took %ld frames in and put %ld out, %ld dropped\n", rx, tx, drops);
	p9close(dfd); p9close(lfd); p9close(afd);
	poperror();
	pexit("wiresrv done", 0);
}

static void
wirecli(void *)
{
	int dfd, sfd, wfd, cnum;
	long n, rx, tx, drops;
	char cbuf[64], path[64], line[256], rx1[256], *e;
	static char msg[] = "sent across the cable by machine 2's tcp.c in user space";

	tsleep(&up->sleep, return0, nil, 2000);		/* let the other machine come up */
	if(waserror()){
		print("p9 wire: machine 2 failed: %s\n", up->errstr);
		pexit("wirecli", 0);
	}
	dfd = p9open("/net/tcp/clone", ORDWR);
	n = p9read(dfd, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; cnum=atoi(cbuf);
	print("p9 wire: machine 2 connecting to 10.1.0.1!9005 across the cable\n");
	p9write(dfd, "connect 10.1.0.1!9005", 21);
	snprint(path, sizeof path, "/net/tcp/%d/status", cnum);
	sfd = p9open(path, OREAD); n = p9read(sfd, line, sizeof line - 1); p9close(sfd);
	if(n<0)n=0; line[n]=0;
	for(e=line; *e && *e!='\n'; e++) ; *e=0;
	print("p9 wire: machine 2's handshake with machine 1 across the cable - %s\n", line);
	snprint(path, sizeof path, "/net/tcp/%d/data", cnum);
	wfd = p9open(path, ORDWR);
	p9write(wfd, msg, sizeof msg - 1);
	n = p9read(wfd, rx1, sizeof rx1 - 1); if(n<0)n=0; rx1[n]=0;
	vnet_stats(&rx, &tx, &drops);
	print("p9 wire: machine 2 read the answer across the cable: \"%s\"; its user-space driver took %ld frames in and put %ld out, %ld dropped\n", rx1, rx, tx, drops);
	tsleep(&up->sleep, return0, nil, 500);
	p9close(wfd); p9close(dfd);
	poperror();
	pexit("wirecli done", 0);
}

/* called by the server loop once the driver is up: the interface, and the machine's role */
void
p9vnetup(void)
{
	uchar mac[6];
	char buf[128], addr[64];
	int fd;
	long n;

	if(!vnet_ready())
		return;
	if(waserror()){
		print("p9 wire: the vnet interface failed: %s\n", up->errstr);
		return;
	}
	vnet_mac(mac);
	fd = p9open("/net/ipifc/clone", ORDWR);
	n = p9read(fd, buf, sizeof buf - 1); if(n < 0) n = 0; buf[n] = 0;
	p9write(fd, "bind vnet", 9);
	n = snprint(addr, sizeof addr, "add 10.1.0.%d 255.255.255.0", mac[5]);
	p9write(fd, addr, n);
	p9close(fd);
	print("p9 wire: stack A bound the vnet medium on the user-space driver and is 10.1.0.%d on the wire (from the MAC); machine %d\n", mac[5], mac[5]);
	if(mac[5] == 1)
		kproc("wiresrv", wiresrv, nil);
	else
		kproc("wirecli", wirecli, nil);
	poperror();
}

/*
 * The firewall, item 7's last word, with the real stack's own rule
 * engine: ipmux.  Once an ipmux conversation exists, every packet for
 * the stack passes its rules first (devip's Fsrcvpcolx), and one that
 * matches is diverted to that conversation instead of reaching its
 * protocol.  Here stack B announces a port, and when the client asks
 * (a datagram to 9003) puts up a rule diverting TCP from 10.0.1.1 to
 * that port - source, protocol and destination port, the fields a
 * firewall's rule has; the client's SYNs then arrive on the ipmux
 * conversation, read and counted here, and tcp.c never sees them.
 * After two the rule is lifted (the conversation closed), the next
 * retransmitted SYN reaches tcp.c, and the connection is accepted and
 * answered.  What the client sees is a connect held for as long as the
 * rule stood.
 */
static void
fwsrv(void *)
{
	int ua, ul, afd, mfd, dfd, lfd, cfd, anum, mnum, lnum, i;
	long n;
	char cbuf[64], path[64], rx[256];
	uchar pkt[2048];
	static char rule[] = "connect src=10.0.1.1;proto=06;data[2:3]=232c";	/* tcp from the client to port 9004 */
	static char reply[] = "answered once the firewall's rule was lifted";

	if(waserror()){
		print("p9 ip: firewall failed: %s\n", up->errstr);
		pexit("fwsrv", 0);
	}
	afd = p9open("#I1/tcp/clone", ORDWR);
	n = p9read(afd, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; anum=atoi(cbuf);
	p9write(afd, "announce 9004", 13);
	ua = p9open("#I1/udp/clone", ORDWR);
	n = p9read(ua, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0;
	p9write(ua, "announce 9003", 13);
	snprint(path, sizeof path, "#I1/udp/%s/listen", cbuf);
	ul = p9open(path, ORDWR);			/* the client's ask, when it comes */
	n = p9read(ul, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0;
	p9close(ul); p9close(ua);
	mfd = p9open("#I1/ipmux/clone", ORDWR);
	n = p9read(mfd, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; mnum=atoi(cbuf);
	p9write(mfd, rule, sizeof rule - 1);
	print("p9 ip: firewall: the client asked for the rule; stack B's ipmux now diverts TCP from 10.0.1.1 to port 9004 before tcp.c sees it\n");
	snprint(path, sizeof path, "#I1/ipmux/%d/data", mnum);
	dfd = p9open(path, OREAD);
	for(i = 0; i < 2; i++){
		n = p9read(dfd, pkt, sizeof pkt);
		print("p9 ip: firewall: diverted a %ld-byte TCP packet from 10.0.1.1 to port 9004 - the rule holds, tcp.c never saw it\n", n);
	}
	p9close(dfd); p9close(mfd);
	print("p9 ip: firewall: the rule is lifted after 2 diverted packets\n");
	snprint(path, sizeof path, "#I1/tcp/%d/listen", anum);
	lfd = p9open(path, ORDWR);
	n = p9read(lfd, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; lnum=atoi(cbuf);
	print("p9 ip: firewall: the next SYN reached tcp.c and the connection was accepted as conversation %d\n", lnum);
	snprint(path, sizeof path, "#I1/tcp/%d/data", lnum);
	cfd = p9open(path, ORDWR);
	n = p9read(cfd, rx, sizeof rx - 1); if(n<0)n=0; rx[n]=0;
	p9write(cfd, reply, sizeof reply - 1);
	tsleep(&up->sleep, return0, nil, 1000);
	p9close(cfd); p9close(lfd); p9close(afd);
	poperror();
	pexit("fwsrv done", 0);
}

/*
 * The client end.  The client container brings up the real Plan 9 IP
 * stack of its own - devip, ip.c, tcp.c - and binds an osprey interface
 * whose wire is the ring to the server container.  A kproc connects to
 * the service above with the client's own tcp.c, so two whole stacks in
 * two containers run one tcp.c conversation over a wire the kernel only
 * routes.  The client has no server loop; this is its loop, driven by
 * the clock tick it asks for: each tick it polls the ring for frames the
 * far stack sent (ospreymediumpoll), advances the cooperative clock, and
 * runs the kprocs that are ready.
 */
static int clientnetdone;

/*
 * Pi-p over the wire, from the client container: three groups on two
 * connections to the server container's pi-p at 10.0.1.2!9001, over the
 * two stacks' tcp.c across the ring.  The first connection opens a
 * session and a fid on /n/hello and reads it; the connection is closed
 * and a second one resumes the session by number and reads through the
 * same fid, still open - the session outlived the connection.  Then a
 * Tstream on that fid, and the attribute arrives three times at the
 * asked rate with nothing sent to make it happen.
 */
int
pipwire_connect(int *dfdp)
{
	char cbuf[64], path[64];
	long n;
	int dfd, cnum;

	dfd = p9open("/net/tcp/clone", ORDWR);
	n = p9read(dfd, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; cnum=atoi(cbuf);
	p9write(dfd, "connect 10.0.1.2!9001", 21);
	*dfdp = dfd;
	snprint(path, sizeof path, "/net/tcp/%d/data", cnum);
	return p9open(path, ORDWR);
}

static void
pipclient(void)
{
	extern long pip_tsession(uchar*, int, uvlong);
	extern long pip_topen(uchar*, int, ulong, ulong, int, char*);
	extern long pip_tread(uchar*, int, ulong, long, char*);
	extern long pip_tstream(uchar*, int, ulong, ulong, ulong, char*);
	extern long pip_tclose(uchar*, int, ulong);
	extern int pip_next(uchar*, long, long*, int*, int*, uchar**, long*);
	extern uvlong pip_num(uchar*, int);
	extern uvlong kfastticks(uvlong*);
	uchar tg[512], rg[2048], *body;
	long tn, rn, off, blen;
	int type, tag, dfd, wfd, nrep, i;
	uvlong sid, v, t0, t;
	char show[160];

	/* connection 1: a session, a fid on /n/hello, its data and version */
	wfd = pipwire_connect(&dfd);
	tn = 0;
	tn += pip_tsession(tg+tn, 1, 0);
	tn += pip_topen(tg+tn, 2, 0, 1, 0, "/n/hello");
	tn += pip_tread(tg+tn, 3, 1, 256, "data");
	tn += pip_tread(tg+tn, 4, 1, 32, "version");
	pipwire_put(wfd, tg, tn);
	rn = pipwire_get(wfd, rg, sizeof rg);
	sid = 0; v = 0; nrep = 0;
	for(off = 0; rn > 0 && pip_next(rg, rn, &off, &type, &tag, &body, &blen); nrep++){
		if(type == 101)
			sid = pip_num(body, 8);
		else if(type == 105 && tag == 3){
			snprint(show, sizeof show, "%.*s", (int)pip_num(body+8, 2), (char*)body+10);
			v = pip_num(body, 8);
			print("p9 ip: pi-p over the wire: opened /n/hello in session %llux, read data (version %llud): \"%s\"\n", sid, v, show);
		} else if(type == 112){
			snprint(show, sizeof show, "%.*s", (int)pip_num(body, 2), (char*)body+2);
			print("p9 ip: pi-p over the wire: error on tag %d: %s\n", tag, show);
		}
	}
	print("p9 ip: pi-p over the wire: a group of 4 crossed the two stacks' tcp.c across the ring and came back with %d replies\n", nrep);
	p9close(wfd); p9close(dfd);		/* the connection goes; the session and its fid do not */
	tsleep(&up->sleep, return0, nil, 200);

	/* connection 2: the same session by number, the same fid, still open */
	wfd = pipwire_connect(&dfd);
	tn = 0;
	tn += pip_tsession(tg+tn, 5, sid);
	tn += pip_tread(tg+tn, 6, 1, 256, "data");
	pipwire_put(wfd, tg, tn);
	rn = pipwire_get(wfd, rg, sizeof rg);
	for(off = 0; rn > 0 && pip_next(rg, rn, &off, &type, &tag, &body, &blen); ){
		if(type == 105 && tag == 6){
			snprint(show, sizeof show, "%.*s", (int)pip_num(body+8, 2), (char*)body+10);
			print("p9 ip: pi-p over the wire: a new connection resumed session %llux and read fid 1, still open, data (version %llud): \"%s\" - the session outlived the connection\n", sid, pip_num(body, 8), show);
		} else if(type == 112){
			snprint(show, sizeof show, "%.*s", (int)pip_num(body, 2), (char*)body+2);
			print("p9 ip: pi-p over the wire: error on tag %d: %s\n", tag, show);
		}
	}

	/* a stream: the version, every 100 ms, three times, unasked; a group
	 * settles its session first, as every group does */
	tn = 0;
	tn += pip_tsession(tg+tn, 9, sid);
	tn += pip_tstream(tg+tn, 7, 1, 100, 3, "version");
	pipwire_put(wfd, tg, tn);
	rn = pipwire_get(wfd, rg, sizeof rg);
	nrep = 0;
	for(off = 0; rn > 0 && pip_next(rg, rn, &off, &type, &tag, &body, &blen); ){
		if(type == 114){		/* Rstream */
			print("p9 ip: pi-p over the wire: Tstream answered, period %llud ms\n", pip_num(body, 8));
			nrep = 1;
		} else if(type == 112){
			snprint(show, sizeof show, "%.*s", (int)pip_num(body, 2), (char*)body+2);
			print("p9 ip: pi-p over the wire: tag %d refused: %s\n", tag, show);
		}
	}
	t0 = kfastticks(nil);
	for(i = 0; nrep && i < 3; i++){
		rn = pipwire_get(wfd, rg, sizeof rg);
		if(rn <= 0)
			break;
		t = kfastticks(nil);
		off = 0;
		if(pip_next(rg, rn, &off, &type, &tag, &body, &blen) && type == 105 && tag == 7){
			snprint(show, sizeof show, "%.*s", (int)pip_num(body+8, 2), (char*)body+10);
			print("p9 ip: pi-p over the wire: stream frame %d arrived unasked, tag 7, version \"%s\", %llud ms after the last\n", i+1, show, (t - t0) * 10);
		} else
			print("p9 ip: pi-p over the wire: unexpected frame type %d tag %d\n", type, tag);
		t0 = t;
	}
	if(i == 3)
		print("p9 ip: pi-p over the wire: three frames of the stream came at the asked rate with nothing sent to make them happen - isochronous data over the wire\n");
	tn = 0;
	tn += pip_tsession(tg+tn, 10, sid);
	tn += pip_tclose(tg+tn, 8, 1);
	pipwire_put(wfd, tg, tn);
	pipwire_get(wfd, rg, sizeof rg);
	tsleep(&up->sleep, return0, nil, 200);
	p9close(wfd); p9close(dfd);
}

/*
 * Dynamic replicated data, the talk's end for the wire above: the
 * client container keeps a replica of the server's /n/hello and follows
 * a stream of the file's committed version ("latest") over the wire.
 * While each frame says the version it holds, reads are answered from
 * the replica with nothing asked of the server; when a frame says
 * another version, the replica opens a new fid and refetches - a fid's
 * data is a snapshot, so the new version needs a new fid - and is
 * current again within a period.  The change is made by another path
 * while the replica watches: 9P over the ring, this container's own
 * mount of the server, writing the file.  Stream frames and the replies
 * to the groups the replica sends arrive on one connection, told apart
 * by tag.
 */
static void
replica(void)
{
	extern long pip_tsession(uchar*, int, uvlong);
	extern long pip_topen(uchar*, int, ulong, ulong, int, char*);
	extern long pip_tread(uchar*, int, ulong, long, char*);
	extern long pip_tstream(uchar*, int, ulong, ulong, ulong, char*);
	extern long pip_tclose(uchar*, int, ulong);
	extern int pip_next(uchar*, long, long*, int*, int*, uchar**, long*);
	extern uvlong pip_num(uchar*, int);
	uchar tg[512], rg[2048], *body;
	char data[512], show[160];
	long tn, rn, off, blen, dlen, served, frames;
	int type, tag, dfd, wfd, fid, wrote, refetched, unchanged, want;
	uvlong sid, vers, v;

	wfd = pipwire_connect(&dfd);
	fid = 1;
	tn = 0;
	tn += pip_tsession(tg+tn, 1, 0);
	tn += pip_topen(tg+tn, 2, 0, fid, 0, "/n/hello");
	tn += pip_tread(tg+tn, 3, fid, sizeof data - 1, "data");
	tn += pip_tread(tg+tn, 4, fid, 32, "latest");
	pipwire_put(wfd, tg, tn);
	rn = pipwire_get(wfd, rg, sizeof rg);
	sid = 0; vers = 0; dlen = 0;
	for(off = 0; rn > 0 && pip_next(rg, rn, &off, &type, &tag, &body, &blen); ){
		if(type == 101)
			sid = pip_num(body, 8);
		else if(type == 105 && tag == 3){
			dlen = pip_num(body+8, 2);
			if(dlen > (long)sizeof data - 1)
				dlen = sizeof data - 1;
			memmove(data, body+10, dlen);
			data[dlen] = 0;
		} else if(type == 105 && tag == 4){
			snprint(show, sizeof show, "%.*s", (int)pip_num(body+8, 2), (char*)body+10);
			vers = strtoull(show, nil, 10);
		}
	}
	print("p9 ip: replica: holding /n/hello at version %llud (%ld bytes) from the wire; watching its committed version on a stream\n", vers, dlen);
	tn = 0;
	tn += pip_tsession(tg+tn, 5, sid);
	tn += pip_tstream(tg+tn, 7, fid, 100, 0, "latest");	/* every 100 ms, no end */
	pipwire_put(wfd, tg, tn);
	pipwire_get(wfd, rg, sizeof rg);				/* Rsession, Rstream */

	served = frames = 0; wrote = refetched = unchanged = 0; want = 0;
	while(frames < 40 && !(refetched && unchanged >= 2 && !want)){
		rn = pipwire_get(wfd, rg, sizeof rg);
		if(rn <= 0)
			break;
		for(off = 0; pip_next(rg, rn, &off, &type, &tag, &body, &blen); ){
			if(type == 105 && tag == 7){		/* a stream frame: the committed version now */
				frames++;
				snprint(show, sizeof show, "%.*s", (int)pip_num(body+8, 2), (char*)body+10);
				v = strtoull(show, nil, 10);
				if(v == vers){
					served++;		/* a read, answered from the copy */
					unchanged++;
					if(unchanged == 3 && !wrote)
						print("p9 ip: replica: the stream says version %llud still, %ld reads answered from the replica without asking the server\n", vers, served);
				} else if(!want){
					/* changed: a new fid on the file, its data, the old fid closed */
					tn = 0;
					tn += pip_tsession(tg+tn, 8, sid);
					tn += pip_topen(tg+tn, 9, 0, fid+1, 0, "/n/hello");
					tn += pip_tread(tg+tn, 10, fid+1, sizeof data - 1, "data");
					tn += pip_tclose(tg+tn, 11, fid);
					pipwire_put(wfd, tg, tn);
					want = 10;
					unchanged = 0;
				}
			} else if(type == 105 && tag == want){	/* the refetch */
				dlen = pip_num(body+8, 2);
				if(dlen > (long)sizeof data - 1)
					dlen = sizeof data - 1;
				memmove(data, body+10, dlen);
				data[dlen] = 0;
				print("p9 ip: replica: the stream says version %llud now, not %llud: refetched over the wire, \"%s\" - the replica is current again\n", v, vers, data);
				vers = v;
				fid++;
				want = 0;
				refetched = 1;
				/* the stream was on the old fid, closed with it: watch the new one */
				tn = 0;
				tn += pip_tsession(tg+tn, 12, sid);
				tn += pip_tstream(tg+tn, 7, fid, 100, 0, "latest");
				pipwire_put(wfd, tg, tn);
			} else if(type == 112){
				snprint(show, sizeof show, "%.*s", (int)pip_num(body, 2), (char*)body+2);
				print("p9 ip: replica: error on tag %d: %s\n", tag, show);
			}
		}
		if(unchanged >= 3 && !wrote){
			/* another path changes the file: 9P over the ring, this container's mount of the server */
			Chan *tc, *rc, *hc;
			char *names[2];
			static char text[] = "a new version the replica must notice";

			wrote = 1;
			if(!waserror()){
				tc = namec("#L", Aopen, ORDWR, 0);
				rc = mntattach(tc, nil, "", 0);
				cclose(tc);
				names[0] = "n"; names[1] = "hello";
				hc = cclone(rc);
				cclose(rc);
				if(walk(&hc, names, 2, 1, nil) < 0)
					error("no /n/hello over 9P");
				hc = devtab[hc->type]->open(hc, OWRITE|OTRUNC);
				devtab[hc->type]->write(hc, text, sizeof text - 1, 0);
				cclose(hc);			/* the clunk commits the new version */
				poperror();
				print("p9 ip: replica: another path, 9P over the ring, wrote a new version while the replica watched\n");
			} else
				print("p9 ip: replica: the 9P write failed: %s\n", up->errstr);
		}
	}
	print("p9 ip: replica: done - %ld stream frames, %ld reads answered from the replica, %d refetch\n", frames, served, refetched);
	tn = 0;
	tn += pip_tsession(tg+tn, 13, sid);
	tn += pip_tstream(tg+tn, 14, fid, 0, 0, "latest");	/* period 0: the stream stops */
	tn += pip_tclose(tg+tn, 15, fid);
	pipwire_put(wfd, tg, tn);
	pipwire_get(wfd, rg, sizeof rg);
	tsleep(&up->sleep, return0, nil, 200);
	p9close(wfd); p9close(dfd);
}

/* a new version of the server's /n/hello by another path: 9P over the ring, this container's mount */
static void
write9p(char *text)
{
	Chan *tc, *rc, *hc;
	char *names[2];

	tc = namec("#L", Aopen, ORDWR, 0);
	rc = mntattach(tc, nil, "", 0);
	cclose(tc);
	names[0] = "n"; names[1] = "hello";
	hc = cclone(rc);
	cclose(rc);
	if(walk(&hc, names, 2, 1, nil) < 0)
		error("no /n/hello over 9P");
	hc = devtab[hc->type]->open(hc, OWRITE|OTRUNC);
	devtab[hc->type]->write(hc, text, strlen(text), 0);
	cclose(hc);			/* the clunk commits the new version */
}

/*
 * The caching file system (devcache.c) through the name space: #K bound
 * over /n, so /n/hello here is the server's file, held in this
 * container and kept current by the wire.  Two opens - a miss and a
 * hit; a listing; a new version written by another path; and an open
 * after the stream has said so, which refetches.
 */
static void
cachetest(void)
{
	extern void cachestats(int*, int*, int*, long*);
	extern int p9bind(char*, char*, int);
	char buf[256];
	uchar dbuf[1024];
	int fd, hits, misses, refetches, i;
	long n, nf;
	Dir d;
	char names[128];

	p9bind("#K", "/n", MREPL);
	for(i = 0; i < 2; i++){
		fd = p9open("/n/hello", OREAD);
		n = p9read(fd, buf, sizeof buf - 1); if(n < 0) n = 0; buf[n] = 0;
		p9close(fd);
		print("p9 ip: cache: read /n/hello through this container's name space (%s): \"%s\"\n", i == 0 ? "a miss, fetched" : "a hit, from the copy", buf);
	}
	fd = p9open("/n", OREAD);
	n = p9read(fd, dbuf, sizeof dbuf);
	p9close(fd);
	if(n > 0 && convM2D(dbuf, (uint)n, &d, names) > 0)
		print("p9 ip: cache: ls /n lists %s, version %lud, %lld bytes - the cache is a directory in the name space\n", d.name, d.qid.vers, (vlong)d.length);
	write9p("a version written after the cache held the file");
	print("p9 ip: cache: another path, 9P over the ring, wrote a new version\n");
	tsleep(&up->sleep, return0, nil, 250);		/* two periods of the stream */
	fd = p9open("/n/hello", OREAD);
	n = p9read(fd, buf, sizeof buf - 1); if(n < 0) n = 0; buf[n] = 0;
	p9close(fd);
	print("p9 ip: cache: read /n/hello again after the stream said the version changed: \"%s\"\n", buf);
	cachestats(&hits, &misses, &refetches, &nf);
	print("p9 ip: cache: done - %d miss, %d hit, %d refetch, %ld stream frames taken off the wire\n", misses, hits, refetches, nf);
}

/* the firewall from the client's side: ask for the rule, then a connect held until it is lifted */
static void
fwtest(void)
{
	extern uvlong kfastticks(uvlong*);
	int ufd, dfd, wfd, cnum;
	long n;
	uvlong t0, t1;
	char cbuf[64], path[64], rx[256];
	static char msg[] = "sent once the firewall let the connection through";

	ufd = p9open("/net/udp/clone", ORDWR);
	n = p9read(ufd, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0;
	p9write(ufd, "connect 10.0.1.2!9003", 21);
	snprint(path, sizeof path, "/net/udp/%s/data", cbuf);
	wfd = p9open(path, ORDWR);
	p9write(wfd, "put the rule up", 15);		/* the ask, a datagram across the ring */
	p9close(wfd); p9close(ufd);
	tsleep(&up->sleep, return0, nil, 200);		/* let the rule go up */
	t0 = kfastticks(nil);
	dfd = p9open("/net/tcp/clone", ORDWR);
	n = p9read(dfd, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; cnum=atoi(cbuf);
	print("p9 ip: firewall: connecting to 10.0.1.2!9004 while the rule stands\n");
	p9write(dfd, "connect 10.0.1.2!9004", 21);	/* held: the SYNs are diverted until the rule is lifted */
	t1 = kfastticks(nil);
	print("p9 ip: firewall: the connect took %llud ms - held while the rule diverted its SYNs, done once it was lifted\n", (t1 - t0) * 10);
	snprint(path, sizeof path, "/net/tcp/%d/data", cnum);
	wfd = p9open(path, ORDWR);
	p9write(wfd, msg, sizeof msg - 1);
	n = p9read(wfd, rx, sizeof rx - 1); if(n<0)n=0; rx[n]=0;
	print("p9 ip: firewall: read %ld bytes back through the connection the rule had held: \"%s\"\n", n, rx);
	tsleep(&up->sleep, return0, nil, 300);
	p9close(wfd); p9close(dfd);
}

static void
ostcpclient(void *)
{
	int dfd, sfd, wfd, cnum, tries;
	long n;
	char cbuf[64], line[256], path[64], rx[256], *e;
	static char msg[] = "sent by the client container's own tcp.c, across the ring";

	tsleep(&up->sleep, return0, nil, 100);	/* let the loop start ticking */
	if(waserror()){
		print("p9 ip: client container: tcp across the ring failed: %s\n", up->errstr);
		clientnetdone = 1;
		pexit("ostcpclient", 0);
	}
	dfd = p9open("/net/tcp/clone", ORDWR);
	n = p9read(dfd, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; cnum=atoi(cbuf);
	print("p9 ip: client container: its own tcp.c connecting to 10.0.1.2!9999, the server container, across the ring wire\n");
	p9write(dfd, "connect 10.0.1.2!9999", 21);	/* returns once the handshake is done */
	snprint(path, sizeof path, "/net/tcp/%d/status", cnum);
	sfd = p9open(path, OREAD); n = p9read(sfd, line, sizeof line - 1); p9close(sfd);
	if(n<0)n=0; line[n]=0;
	for(e=line; *e && *e!='\n'; e++) ; *e=0;
	if(strncmp(line, "Established", 11) == 0)
		print("p9 ip: client container: the two containers' tcp.c completed a handshake across the ring - %s\n", line);
	else
		print("p9 ip: client container: handshake did not reach Established - %s\n", line);
	snprint(path, sizeof path, "/net/tcp/%d/data", cnum);
	wfd = p9open(path, ORDWR);
	p9write(wfd, msg, sizeof msg - 1);
	for(tries = 0, n = 0; tries < 100 && n <= 0; tries++){
		tsleep(&up->sleep, return0, nil, 50);	/* the answer crosses on ticks */
		n = p9read(wfd, rx, sizeof rx - 1);
	}
	if(n<0)n=0; rx[n]=0;
	print("p9 ip: client container: read %ld bytes back from the server container's tcp.c across the ring: \"%s\"\n", n, rx);
	tsleep(&up->sleep, return0, nil, 300);	/* let the acks cross before the close does */
	p9close(wfd); p9close(dfd);
	/*
	 * Through the gateway: stack A (10.0.0.1) has no wire to this
	 * container; the route added below sends 10.0.0.0/24 to 10.0.1.2,
	 * stack B, which forwards.  The same tcp.c conversation, one hop
	 * further, the forwarding done by the real ip.c in the server
	 * container.
	 */
	{
		static char msg2[] = "sent through stack B as a gateway to stack A";
		dfd = p9open("/net/tcp/clone", ORDWR);
		n = p9read(dfd, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; cnum=atoi(cbuf);
		print("p9 ip: client container: connecting to 10.0.0.1!8890, stack A, through stack B as a gateway\n");
		p9write(dfd, "connect 10.0.0.1!8890", 21);
		snprint(path, sizeof path, "/net/tcp/%d/status", cnum);
		sfd = p9open(path, OREAD); n = p9read(sfd, line, sizeof line - 1); p9close(sfd);
		if(n<0)n=0; line[n]=0;
		for(e=line; *e && *e!='\n'; e++) ; *e=0;
		if(strncmp(line, "Established", 11) == 0)
			print("p9 ip: client container: handshake with stack A through the gateway - %s\n", line);
		else
			print("p9 ip: client container: gateway handshake did not reach Established - %s\n", line);
		snprint(path, sizeof path, "/net/tcp/%d/data", cnum);
		wfd = p9open(path, ORDWR);
		p9write(wfd, msg2, sizeof msg2 - 1);
		for(tries = 0, n = 0; tries < 100 && n <= 0; tries++){
			tsleep(&up->sleep, return0, nil, 50);
			n = p9read(wfd, rx, sizeof rx - 1);
		}
		if(n<0)n=0; rx[n]=0;
		print("p9 ip: client container: read %ld bytes back from stack A through the gateway: \"%s\"\n", n, rx);
		tsleep(&up->sleep, return0, nil, 300);
		p9close(wfd); p9close(dfd);
	}
	pipclient();
	replica();
	cachetest();
	fwtest();
	poperror();
	clientnetdone = 1;
	pexit("ostcpclient done", 0);
}

void
p9clientnet(void)
{
	extern int ring9p_taketick(int), ring9p_waittick(int);
	extern void ospreymediumpoll(void), ospreymediumstats(long*, long*);
	extern void sched_tick(void), runkprocs(void);
	enum { Ticksem = 3 };		/* the kernel gave the client's keyboard 1 and mouse 2 */
	Chan *ic, *nc;
	char buf[128];
	int fd, ticks;
	long n, tx, rx;

	if(waserror()){
		print("p9 ip: client container: stack bring-up failed: %s\n", up->errstr);
		return;
	}
	ospreymediumlink();
	ic = namec("#I", Atodir, 0, 0);
	nc = namec("/net", Atodir, 0, 0);
	cmount(ic, nc, MAFTER, "");
	cclose(ic);
	cclose(nc);
	fd = p9open("/net/ipifc/clone", ORDWR);
	n = p9read(fd, buf, sizeof buf - 1); if(n < 0) n = 0; buf[n] = 0;
	p9write(fd, "bind osprey ring client", 23);
	p9write(fd, "add 10.0.1.1 255.255.255.0", 26);
	p9close(fd);
	{
		static char via[] = "add 10.0.0.0 255.255.255.0 10.0.1.2";	/* stack A's network, through stack B */
		fd = p9open("/net/iproute", ORDWR);
		p9write(fd, via, sizeof via - 1);
		p9close(fd);
	}
	print("p9 ip: client container: the real Plan 9 IP stack is up in this container too; its osprey interface 10.0.1.1 is the ring wire to the server container\n");
	if(ring9p_taketick(Ticksem) < 0)
		error("the clock tick was refused");
	kproc("ostcpclient", ostcpclient, nil);
	for(ticks = 0; ticks < 4000 && !clientnetdone; ){
		if(ring9p_waittick(Ticksem) < 0)
			error("select on the tick failed");
		ticks++;
		ospreymediumpoll();	/* frames the far stack sent since, injected */
		sched_tick();		/* the cooperative clock: timers, tsleep */
		runkprocs();		/* the connecting kproc and the protocol kprocs */
	}
	ospreymediumstats(&tx, &rx);
	print("p9 ip: client container: %s after %d ticks; %ld frames of its stack's crossed the ring to the server container and %ld of the server's stack's came back\n",
		clientnetdone ? "done" : "gave up", ticks, tx, rx);
	poperror();
}

/*
 * Bring the real Plan 9 IP stack up in this personality and prove it
 * runs.  ipdevtab is in the personality devtab and this is called from
 * the server once its name space is up.  The stack is the actual
 * devip/ip.c/tcp.c/udp.c/ipifc.c, running in a user-space process on the
 * microkernel, not a hand-written responder.
 *
 * Bring the stack up in this personality: register the loopback medium,
 * mount the ip device (#I) at /net, bind loopback to an interface and
 * give it 127.0.0.1, then read the interface's status back - which the
 * real ipifc.c produced, proving the stack initialised and configured
 * itself.  Called from the server personality once its name space is up.
 */
void
p9ipup(void)
{
	Chan *ic, *nc;
	char buf[512], *p, *e;
	int fd;
	long n;

	{
		extern int ospreyinb(int);
		extern long ospreyxcall(int op, uvlong *args, long n);
		uvlong grant[2];
		int st;
		/* Ask the kernel to delegate the i8042 ports (0x60 data, 0x64
		 * status/command) to this process.  The kernel clears their bits
		 * in this process's own I/O-permission bitmap, which the scheduler
		 * loads into the CPU's TSS - a per-process grant, not machine-wide.
		 * Then a user-mode INB runs at CPL3 with no trap and no syscall in
		 * the data path; a printed status byte, not a fault, is the proof. */
		grant[0] = 0x60; grant[1] = 0x64;
		ospreyxcall(20, grant, 2);		/* ReqIoport */
		st = ospreyinb(0x64);
		print("p9 io: user-mode inb(0x64) i8042 status = %#ux - port I/O delegated to this process, no trap\n", st & 0xff);
	}

	{
		/*
		 * The real-time clock read in user space, the exokernel way the
		 * console and uart are tasks: the CMOS clock is at ports 0x70
		 * (index) and 0x71 (data), granted to this process, and read with
		 * its own outb/inb - no kernel rtc device in the data path.  The
		 * bytes are BCD.  Reading is a handful of port ops, a short CPL3
		 * burst; the update-in-progress spin the kernel's driver does
		 * would be a long one, so instead the six registers are read
		 * twice and taken when the seconds match, which is the same
		 * guard against catching the clock mid-update without the spin.
		 */
		extern int ospreyinb(int);
		extern void ospreyoutb(int, int);
		extern long ospreyxcall(int op, uvlong *args, long n);
		uvlong grant[2];
		static int reg[6] = { 0x00, 0x02, 0x04, 0x07, 0x08, 0x09 };	/* sec min hour mday mon year */
		int a[6], b[6], i, tries;

		grant[0] = 0x70; grant[1] = 0x71;
		ospreyxcall(20, grant, 2);		/* ReqIoport: the CMOS index/data ports */
		for(tries = 0; tries < 16; tries++){
			for(i = 0; i < 6; i++){ ospreyoutb(0x70, reg[i]); a[i] = ospreyinb(0x71) & 0xff; }
			for(i = 0; i < 6; i++){ ospreyoutb(0x70, reg[i]); b[i] = ospreyinb(0x71) & 0xff; }
			if(a[0] == b[0])		/* seconds stable: not read mid-update */
				break;
		}
		for(i = 0; i < 6; i++)
			a[i] = (a[i] & 0xf) + 10*(a[i] >> 4);	/* BCD to decimal */
		print("p9 rtc: read the CMOS clock in user space by its own outb/inb (ports 0x70/0x71): "
			"%d-%02d-%02d %02d:%02d:%02d - no kernel rtc device\n",
			2000 + a[5], a[4], a[3], a[2], a[1], a[0]);
		/*
		 * And hand the kernel the time: it read no clock at boot and
		 * its time of day starts at zero, which is what tickets expire
		 * against.  Seconds since 1970, the CMOS clock taken as UTC
		 * (which is how the test bench keeps it), by the usual
		 * days-from-civil count.
		 */
		{
			extern long ospreyxcall(int op, uvlong *args, long n);
			uvlong secs, args[5];
			long y, m, d, days;

			y = 2000 + a[5]; m = a[4]; d = a[3];
			if(m <= 2){ y--; m += 12; }
			days = 365*y + y/4 - y/100 + y/400 + (153*(m - 3) + 2)/5 + d - 1 - 719468;	/* days since 1970-01-01 */
			secs = (uvlong)days*86400 + a[2]*3600 + a[1]*60 + a[0];
			args[0] = secs;
			args[1] = args[2] = args[3] = args[4] = 0;
			if(ospreyxcall(23, args, 1) == 0)		/* ReqSettime */
				print("p9 rtc: set the kernel's time of day to %llud seconds since the epoch, by request, from the clock read in user space\n", secs);
			else
				print("p9 rtc: the kernel refused the time of day\n");
		}
	}
	if(waserror()){
		print("p9 ip: bring-up failed: %s\n", up->errstr);
		return;
	}
	loopbackmediumlink();
	ospreymediumlink();
	ospreyvnetmediumlink();
	ic = namec("#I", Atodir, 0, 0);
	nc = namec("/net", Atodir, 0, 0);
	cmount(ic, nc, MAFTER, "");
	cclose(ic);
	cclose(nc);
	print("p9 ip: the Plan 9 IP stack mounted at /net (devip, tcp, udp, ipifc)\n");
	kproc("ticktest", ticktest, nil);	/* proof the tick-driven timed sleep works */
	poperror();

	if(waserror()){
		print("p9 ip: configure failed: %s\n", up->errstr);
		return;
	}
	fd = p9open("/net/ipifc/clone", ORDWR);
	n = p9read(fd, buf, sizeof buf - 1);		/* the conversation number */
	if(n < 0) n = 0;
	buf[n] = 0;
	p9write(fd, "bind loopback", 13);
	p9write(fd, "add 127.0.0.1 255.0.0.0", 23);
	print("p9 ip: bound the loopback medium and gave it 127.0.0.1\n");
	p9close(fd);
	/* a second interface on the osprey medium, its inbound pumped by the server loop */
	fd = p9open("/net/ipifc/clone", ORDWR);
	n = p9read(fd, buf, sizeof buf - 1);
	if(n < 0) n = 0;
	buf[n] = 0;
	p9write(fd, "bind osprey", 11);
	p9write(fd, "add 10.0.0.1 255.255.255.0", 26);
	print("p9 ip: bound the osprey medium on stack A and gave it 10.0.0.1\n");
	p9close(fd);
	/*
	 * A second, independent IP stack (devip's ipfs[1], reached as #I1) with
	 * its own osprey interface at 10.0.0.2.  Binding it pairs the two osprey
	 * interfaces into one wire, so this is two whole stacks joined by the
	 * medium, not a loopback within one.
	 */
	fd = p9open("#I1/ipifc/clone", ORDWR);
	n = p9read(fd, buf, sizeof buf - 1); if(n < 0) n = 0; buf[n] = 0;
	p9write(fd, "bind osprey", 11);
	p9write(fd, "add 10.0.0.2 255.255.255.0", 26);
	print("p9 ip: second stack #I1 with an osprey interface at 10.0.0.2\n");
	p9close(fd);
	/*
	 * And on stack B a third osprey interface whose wire is the ring to
	 * the client container: frames it sends wait for the client's next
	 * request and ride the reply; frames the client's stack sends
	 * arrive by Reqframe and are injected here.  10.0.1.2, on a subnet
	 * of its own, so the route to the client's 10.0.1.1 goes out it.
	 */
	fd = p9open("#I1/ipifc/clone", ORDWR);
	n = p9read(fd, buf, sizeof buf - 1); if(n < 0) n = 0; buf[n] = 0;
	p9write(fd, "bind osprey ring", 16);
	p9write(fd, "add 10.0.1.2 255.255.255.0", 26);
	print("p9 ip: stack B's osprey interface 10.0.1.2 is the ring wire to the client container\n");
	/*
	 * Stack B now has a wire on each side - 10.0.0.2 to stack A, 10.0.1.2
	 * to the client container - so make it a gateway: the real stack's
	 * own forwarding (ip.c's iprouting), a packet from the client for
	 * stack A comes in the ring wire, is not for stack B, and goes out
	 * the paired one with its ttl decremented, and the reply comes back
	 * the same way because stack A routes 10.0.1.0/24 through 10.0.0.2.
	 * The talk's router and gateway, run by the Plan 9 stack in user
	 * space; the kernel routes nothing here but the ring messages.
	 */
	p9write(fd, "iprouting 1", 11);
	p9close(fd);
	{
		static char via[] = "add 10.0.1.0 255.255.255.0 10.0.0.2";
		fd = p9open("/net/iproute", ORDWR);
		p9write(fd, via, sizeof via - 1);
		p9close(fd);
	}
	print("p9 ip: stack B forwards between its two wires - a gateway; stack A routes 10.0.1.0/24 through it at 10.0.0.2\n");
	kproc("ostcp", ostcp, nil);	/* two-stack tcp.c handshake + byte stream over the osprey wire */
	kproc("ringsrv", ringsrv, nil);	/* a tcp.c service for the client container, across the ring wire */
	kproc("gwsrv", gwsrv, nil);	/* the same on stack A, reached through stack B as a gateway */
	kproc("pipwire", pipwire, nil);	/* pi-p about this personality's files, on the wire */
	kproc("fwsrv", fwsrv, nil);	/* the firewall: the stack's own ipmux, a rule on the client's ask */
	p9kbdstart();			/* the i8042 keyboard driver, in user space above the kernel */
	poperror();

	if(waserror()){
		print("p9 ip: status read failed: %s\n", up->errstr);
		return;
	}
	fd = p9open("/net/ipifc/0/status", OREAD);
	n = p9read(fd, buf, sizeof buf - 1);
	if(n < 0) n = 0;
	buf[n] = 0;
	p9close(fd);
	/* first line of the interface status, from the real ipifc.c */
	for(p = buf, e = buf; *e != 0 && *e != '\n'; e++)
		;
	*e = 0;
	print("p9 ip: interface status from the real stack: %s\n", p);
	poperror();

	/*
	 * The proof: drive the real tcp.c over loopback.
	 * Announce a port, then connect to it - the connect completes only
	 * once the three-way handshake is done, so it succeeding, and the
	 * connection reading Established, is tcp.c's state machine running
	 * in user space.
	 */
	if(waserror()){
		print("p9 ip: tcp loopback failed: %s\n", up->errstr);
		return;
	}
	{
		static char msg[] = "hello from osprey over the real plan 9 tcp";
		int afd, dfd, sfd, lfd, wfd, rfd, anum, cnum, lnum, ok;
		char cbuf[64], line2[256], path[64], rx[128];

		afd = p9open("/net/tcp/clone", ORDWR);
		n = p9read(afd, cbuf, sizeof cbuf - 1);
		if(n < 0) n = 0;
		cbuf[n] = 0;
		anum = atoi(cbuf);
		p9write(afd, "announce 7777", 13);
		print("p9 ip: announced tcp!*!7777 on conversation %d\n", anum);

		dfd = p9open("/net/tcp/clone", ORDWR);
		n = p9read(dfd, cbuf, sizeof cbuf - 1);
		if(n < 0) n = 0;
		cbuf[n] = 0;
		cnum = atoi(cbuf);
		p9write(dfd, "connect 127.0.0.1!7777", 22);	/* SYN goes out over loopback */
		print("p9 ip: connect 127.0.0.1!7777 issued on conversation %d - tcp.c sent a real SYN over loopback\n", cnum);

		snprint(path, sizeof path, "/net/tcp/%d/status", cnum);
		sfd = p9open(path, OREAD);
		n = p9read(sfd, line2, sizeof line2 - 1);
		p9close(sfd);
		if(n < 0) n = 0;
		line2[n] = 0;
		for(p = line2, e = line2; *e != 0 && *e != '\n'; e++)
			;
		*e = 0;
		print("p9 ip: connection status from the real tcp.c: %s\n", line2);
		if(strncmp(line2, "Established", 11) == 0)
			print("p9 ip: the real Plan 9 tcp.c completed a 3-way handshake over loopback in user space\n");
		else
			print("p9 ip: handshake did not reach Established\n");

		/*
		 * A data round-trip: the connecting side writes, the accepted
		 * side reads.  listen dequeues the connection the incoming SYN
		 * created; the write segments the payload through the real
		 * tcp.c, the synchronous loopback delivers it, and the read
		 * pulls it out of the accepted conversation's queue.
		 */
		snprint(path, sizeof path, "/net/tcp/%d/listen", anum);
		lfd = p9open(path, ORDWR);
		n = p9read(lfd, cbuf, sizeof cbuf - 1);
		if(n < 0) n = 0;
		cbuf[n] = 0;
		lnum = atoi(cbuf);
		print("p9 ip: accepted the connection as conversation %d\n", lnum);

		snprint(path, sizeof path, "/net/tcp/%d/data", cnum);
		wfd = p9open(path, ORDWR);
		p9write(wfd, msg, sizeof msg - 1);

		snprint(path, sizeof path, "/net/tcp/%d/data", lnum);
		rfd = p9open(path, ORDWR);
		n = p9read(rfd, rx, sizeof rx - 1);
		if(n < 0) n = 0;
		rx[n] = 0;
		ok = (n == (long)(sizeof msg - 1)) && memcmp(rx, msg, n) == 0;
		print("p9 ip: read %ld bytes on conversation %d: \"%s\"\n", n, lnum, rx);
		if(ok)
			print("p9 ip: TCP DATA round-trip verified - the real tcp.c carried the payload over loopback\n");
		else
			print("p9 ip: data round-trip mismatch\n");

		p9close(rfd); p9close(wfd); p9close(lfd);
		p9close(dfd); p9close(afd);
	}
	/*
	 * The same over UDP.  An announced udp conversation in the default
	 * (no-headers) mode spawns a new conversation per peer via Fsnewcall
	 * and queues it on its listen file, exactly as tcp does; so the
	 * receiver announces, accepts through listen, and reads the datagram
	 * from the accepted conversation - the cooperative scheduler carries
	 * the blocking listen and read.
	 */
	{
		static char dg[] = "a udp datagram through the real plan 9 udp.c";
		int ua, ub, uwr, ulis, urd, uan, ubn, unew;
		char cbuf[64], path[64], rx[128];

		ua = p9open("/net/udp/clone", ORDWR);
		n = p9read(ua, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; uan=atoi(cbuf);
		p9write(ua, "announce 7778", 13);

		ub = p9open("/net/udp/clone", ORDWR);
		n = p9read(ub, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; ubn=atoi(cbuf);
		p9write(ub, "connect 127.0.0.1!7778", 22);
		print("p9 ip: udp announce %d, connect %d - sending a datagram over loopback\n", uan, ubn);

		snprint(path, sizeof path, "/net/udp/%d/data", ubn);
		uwr = p9open(path, ORDWR);
		p9write(uwr, dg, sizeof dg - 1);

		snprint(path, sizeof path, "/net/udp/%d/listen", uan);
		ulis = p9open(path, ORDWR);
		n = p9read(ulis, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; unew=atoi(cbuf);
		print("p9 ip: udp accepted the datagram's flow as conversation %d\n", unew);

		snprint(path, sizeof path, "/net/udp/%d/data", unew);
		urd = p9open(path, ORDWR);
		n = p9read(urd, rx, sizeof rx - 1); if(n<0)n=0; rx[n]=0;
		print("p9 ip: udp read %ld bytes: \"%s\"\n", n, rx);
		if(n == (long)(sizeof dg - 1) && memcmp(rx, dg, n) == 0)
			print("p9 ip: UDP datagram round-trip verified - udp.c carried the payload over loopback\n");
		else
			print("p9 ip: udp round-trip mismatch\n");

		p9close(urd); p9close(ulis); p9close(uwr); p9close(ub); p9close(ua);
	}
	poperror();
}
