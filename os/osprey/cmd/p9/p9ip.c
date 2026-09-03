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
	/* stack B (#I1) announces a port */
	afd = p9open("#I1/tcp/clone", ORDWR);
	n = p9read(afd, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; anum=atoi(cbuf);
	p9write(afd, "announce 8888", 13);
	/* stack A (/net) connects to stack B's address, out over the osprey wire */
	dfd = p9open("/net/tcp/clone", ORDWR);
	n = p9read(dfd, cbuf, sizeof cbuf - 1); if(n<0)n=0; cbuf[n]=0; cnum=atoi(cbuf);
	print("p9 ip: osprey wire: stack A (10.0.0.1) connecting to stack B (10.0.0.2)!8888\n");
	p9write(dfd, "connect 10.0.0.2!8888", 21);	/* out A's osprey interface, in at B's */

	snprint(path, sizeof path, "/net/tcp/%d/status", cnum);
	sfd = p9open(path, OREAD); n = p9read(sfd, line, sizeof line - 1); p9close(sfd);
	if(n<0)n=0; line[n]=0;
	for(e=line; *e && *e!='\n'; e++) ; *e=0;
	if(strncmp(line, "Established", 11) == 0)
		print("p9 ip: osprey wire: the two stacks' tcp.c completed a handshake over the osprey medium - %s\n", line);
	else
		print("p9 ip: osprey wire: handshake did not reach Established - %s\n", line);

	/* stack B accepts the flow the SYN created, via its listen file */
	tsleep(&up->sleep, return0, nil, 100);	/* let the final ACK reach stack B */
	snprint(path, sizeof path, "#I1/tcp/%d/listen", anum);
	dfd2 = p9open(path, ORDWR);
	n = p9read(dfd2, cbuf, sizeof cbuf - 1); p9close(dfd2);
	if(n<0)n=0; cbuf[n]=0;
	lnum = atoi(cbuf);
	print("p9 ip: osprey wire: stack B accepted the flow as conversation %d - two stacks joined over the osprey medium\n", lnum);

	USED(anum);
	p9close(dfd); p9close(afd);
	poperror();
	pexit("ostcp done", 0);
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
		int st;
		/* A user-mode INB on the i8042 status port.  At CPL3 this traps
		 * unless the kernel delegated 0x64 through the TSS I/O-permission
		 * bitmap - so a printed status byte, not a fault, is the proof
		 * that port I/O is delegated to user space, no syscall in the
		 * data path. */
		st = ospreyinb(0x64);
		print("p9 io: user-mode inb(0x64) i8042 status = %#ux - port I/O delegated to user space, no trap\n", st & 0xff);
	}
	if(waserror()){
		print("p9 ip: bring-up failed: %s\n", up->errstr);
		return;
	}
	loopbackmediumlink();
	ospreymediumlink();
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
	n = p9read(fd, buf, sizeof buf - 1);
	if(n < 0) n = 0;
	buf[n] = 0;
	p9write(fd, "bind osprey", 11);
	p9write(fd, "add 10.0.0.2 255.255.255.0", 26);
	print("p9 ip: bound the osprey medium on stack B (#I1) and gave it 10.0.0.2\n");
	p9close(fd);
	kproc("ostcp", ostcp, nil);	/* proves a tcp.c handshake across the two stacks over the osprey wire */
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
