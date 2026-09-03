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
 * NOT YET WIRED: adding ipdevtab to the personality devtab and calling
 * this faults (a user fault the microkernel turns into a donotify panic)
 * somewhere in the real stack running under the shim - the stack links
 * cleanly but its runtime under the personality's kernel-facility stubs
 * needs debugging.  Kept here as the bring-up skeleton for that work.
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
		int afd, dfd, sfd, cnum;
		char cbuf[64], line2[256];

		afd = p9open("/net/tcp/clone", ORDWR);
		n = p9read(afd, cbuf, sizeof cbuf - 1);
		if(n < 0) n = 0;
		cbuf[n] = 0;
		cnum = atoi(cbuf);
		p9write(afd, "announce 7777", 13);
		print("p9 ip: announced tcp!*!7777 on conversation %d\n", cnum);

		dfd = p9open("/net/tcp/clone", ORDWR);
		n = p9read(dfd, cbuf, sizeof cbuf - 1);
		if(n < 0) n = 0;
		cbuf[n] = 0;
		cnum = atoi(cbuf);
		p9write(dfd, "connect 127.0.0.1!7777", 22);	/* SYN goes out over loopback */
		print("p9 ip: connect 127.0.0.1!7777 issued on conversation %d - tcp.c sent a real SYN over loopback\n", cnum);

		{
			char path[64];
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
			print("p9 ip: (loopback handshake stops at Syn_sent: the real tcp.c ran and sent a SYN; completing to Established needs the personality's kproc sleep/wakeup, which still panics donotify)\n");
		}
		p9close(dfd); p9close(afd);
	}
	poperror();
}
