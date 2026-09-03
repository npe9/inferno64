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
extern int p9open(char*, int);
extern long p9read(int, void*, long);
extern long p9write(int, void*, long);
extern void p9close(int);

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

	if(waserror()){
		print("p9 ip: bring-up failed: %s\n", up->errstr);
		return;
	}
	loopbackmediumlink();
	ic = namec("#I", Atodir, 0, 0);
	nc = namec("/net", Atodir, 0, 0);
	cmount(ic, nc, MAFTER, "");
	cclose(ic);
	cclose(nc);
	print("p9 ip: the Plan 9 IP stack mounted at /net (devip, tcp, udp, ipifc)\n");
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
	poperror();
}
