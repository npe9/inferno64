/*
 * mig - carry a container to another machine.
 *
 * usage: mig send | copy | recv
 *
 * send moves: what it has sent it then destroys here, so the container
 * is in one place afterwards.  copy leaves it where it was.
 *
 * A checkpoint is text, so moving a container is moving that text.  This
 * puts it in an ethernet frame of its own type and sends it, or waits
 * for one and reads it back into the kernel, which makes the container
 * it names and starts it if it was running.
 *
 * The frame is the transport because the two machines have nothing else
 * in common: no addresses, no name service, nothing configured.  A
 * container that has been given the interface would receive the same
 * frame through its own packet queue without a copy; this uses the
 * ethernet device so that the two ends need agree on nothing but a type.
 *
 * It formats its own output and supplies its own startup, as the other
 * commands here do.
 */
#include <u.h>
#include <libc.h>

enum {
	Ethertype	= 0x9109,	/* frames that carry a container */
	Hdrlen		= 14,
	Maxframe	= 1514,
};

static uchar frame[Maxframe];
static char obuf[1024];
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
outn(uvlong v)
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
	outs("mig: ");
	outs(s);
	outs("\n");
	flush();
	exits(s);
}

static char*
cat(char *d, char *s)
{
	while(*s != '\0')
		*d++ = *s++;
	*d = '\0';
	return d;
}

static char*
catn(char *d, uvlong v)
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
	*d = '\0';
	return d;
}

static uvlong
num(char *s)
{
	uvlong v;

	while(*s == ' ' || *s == '\t')
		s++;
	v = 0;
	while(*s >= '0' && *s <= '9')
		v = v*10 + (*s++ - '0');
	return v;
}

static int
hex(int c)
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

/* our own ethernet address, as the device reports it */
static void
myaddr(uchar *ea)
{
	char buf[32];
	int fd, n, i, a, b;

	if((fd = open("#l/ether0/addr", OREAD)) < 0)
		die("no #l/ether0/addr");
	n = read(fd, buf, sizeof buf - 1);
	close(fd);
	if(n < 12)
		die("short address");
	for(i = 0; i < 6; i++){
		a = hex(buf[2*i]);
		b = hex(buf[2*i+1]);
		if(a < 0 || b < 0)
			die("bad address");
		ea[i] = (a<<4) | b;
	}
}

/*
 * A conversation of our own on the interface, carrying only our own
 * frame type, so that nothing else on the wire is in the way.
 */
static int
converse(void)
{
	char buf[64], path[64], *e;
	int fd, n, cno;

	if((fd = open("#l/ether0/clone", ORDWR)) < 0)
		die("cannot clone #l/ether0");
	n = read(fd, buf, sizeof buf - 1);
	if(n <= 0)
		die("cannot read the conversation number");
	buf[n] = '\0';
	cno = (int)num(buf);
	close(fd);

	e = cat(path, "#l/ether0/");
	e = catn(e, cno);
	cat(e, "/ctl");
	if((fd = open(path, ORDWR)) < 0)
		die("cannot open the conversation");
	e = cat(buf, "connect ");
	catn(e, Ethertype);
	if(write(fd, buf, strlen(buf)) < 0)
		die("cannot set the frame type");
	/* the control file stays open for as long as the conversation lives */
	e = cat(path, "#l/ether0/");
	e = catn(e, cno);
	cat(e, "/data");
	return open(path, ORDWR);
}

/*
 * Destroy the containers a checkpoint names, so that what was sent is
 * here no longer.  A migration that left them running in both places
 * would be a copy.
 */
static void
migdrop(char *text, int n)
{
	char cmd[64], *e;
	int fd, i;

	if((fd = open("/n/osprey/ctl", OWRITE)) < 0)
		die("cannot open /n/osprey/ctl");
	for(i = 0; i + 10 < n; i++){
		if(memcmp(text+i, "container ", 10) != 0)
			continue;
		if(i != 0 && text[i-1] != '\n')
			continue;
		e = cat(cmd, "exit ");
		e = catn(e, num(text+i+10));
		cat(e, "\n");
		write(fd, cmd, strlen(cmd));
		outs("dropped "); outs(cmd);
	}
	close(fd);
	flush();
}

/*
 * Whether this is all of a checkpoint: the last line is a container's
 * end, or the signature that follows one.
 */
static int
whole(char *p, int n)
{
	if(n >= 4 && memcmp(p + n - 4, "end\n", 4) == 0)
		return 1;
	while(n > 0 && p[n-1] != '\n')
		n--;
	if(n > 0)
		n--;			/* the newline before the last line */
	while(n > 0 && p[n-1] != '\n')
		n--;
	return n >= 4 && memcmp(p + n - 4, "end\n", 4) == 0;
}

static void
migsend(int move)
{
	uchar ea[6];
	int fd, n, i;

	if((fd = open("/n/osprey/snap", OREAD)) < 0)
		die("cannot read /n/osprey/snap");
	n = read(fd, (char*)frame + Hdrlen, Maxframe - Hdrlen);
	close(fd);
	if(n <= 0)
		die("nothing to send");
	/*
	 * A checkpoint goes in one frame.  One that filled the buffer was
	 * cut, and a cut checkpoint must not be sent -- what is sent is
	 * destroyed here afterwards, so half of it arriving would lose a
	 * container from both machines at once.
	 */
	if(n >= Maxframe - Hdrlen)
		die("the checkpoint does not fit in one frame");
	if(!whole((char*)frame + Hdrlen, n))
		die("the checkpoint does not end where one should");

	myaddr(ea);
	for(i = 0; i < 6; i++)
		frame[i] = 0xff;		/* to everyone */
	memmove(frame+6, ea, 6);
	frame[12] = Ethertype >> 8;
	frame[13] = Ethertype;

	if((fd = converse()) < 0)
		die("cannot open the conversation data");
	if(write(fd, frame, Hdrlen + n) != Hdrlen + n)
		die("the frame did not go");
	outs("sent "); outn(n); outs(" bytes of checkpoint\n");
	flush();

	/*
	 * What is sent is destroyed here, so wait to be told it arrived.
	 * Without this a checkpoint the other end would not take -- signed
	 * with a key it does not hold, say -- left the container gone from
	 * this machine and never there on that one.  The reply is a frame
	 * of the same type beginning "taken", from somebody else.
	 */
	if(move){
		static uchar in[Maxframe];
		int k;

		alarm(10000);	/* rather than wait for ever on a lost frame */
		for(;;){
			k = read(fd, in, sizeof in);
			if(k <= Hdrlen)
				die("the other end said nothing");
			USED(k);
			if(memcmp(in+6, ea, 6) == 0)
				continue;	/* our own frame comes back */
			if(k >= Hdrlen+5 && memcmp(in+Hdrlen, "taken", 5) == 0)
				break;
			if(k >= Hdrlen+7 && memcmp(in+Hdrlen, "refused", 7) == 0)
				die("the other end would not take it");
		}
		alarm(0);
		close(fd);
		migdrop((char*)frame + Hdrlen, n);
		return;
	}
	close(fd);
}

/* tell whoever sent that checkpoint what became of it */
static void
migsay(int fd, uchar *ea, uchar *to, char *what)
{
	static uchar out[Maxframe];
	int i, n;

	memmove(out, to, 6);
	memmove(out+6, ea, 6);
	out[12] = Ethertype >> 8;
	out[13] = Ethertype;
	for(n = 0; what[n] != '\0'; n++)
		out[Hdrlen+n] = what[n];
	n += Hdrlen;
	for(i = n; i < 60; i++)
		out[i] = 0;
	if(n < 60)
		n = 60;
	write(fd, out, n);
}

static void
migrecv(void)
{
	uchar ea[6], from[6];
	int fd, n;

	myaddr(ea);
	if((fd = converse()) < 0)
		die("cannot open the conversation data");
	for(;;){
		n = read(fd, frame, sizeof frame);
		if(n <= Hdrlen)
			die("no frame");
		if(memcmp(frame+6, ea, 6) == 0)
			continue;		/* our own */
		if(n >= Hdrlen+5 && memcmp(frame+Hdrlen, "taken", 5) == 0)
			continue;		/* somebody else's answer */
		break;
	}
	memmove(from, frame+6, 6);
	/*
	 * A frame is padded out to its minimum, so stop at the last thing
	 * the checkpoint said rather than handing the padding to the
	 * kernel.
	 */
	n -= Hdrlen;
	while(n > 4 && memcmp(frame + Hdrlen + n - 4, "end\n", 4) != 0)
		n--;
	if(n <= 4)
		die("the frame does not end in a checkpoint");
	/*
	 * a signed checkpoint carries one more line after the end of it;
	 * that line is the whole point, so keep it.
	 */
	if(memcmp(frame + Hdrlen + n, "sig ", 4) == 0){
		n += 4;
		while(frame[Hdrlen + n] != '\n' && Hdrlen + n < Maxframe)
			n++;
		n++;
	}
	n += Hdrlen;
	outs("received "); outn(n - Hdrlen); outs(" bytes of checkpoint\n");
	flush();

	{
		int sfd;

		if((sfd = open("/n/osprey/snap", OWRITE)) < 0){
			migsay(fd, ea, from, "refused");
			die("cannot write /n/osprey/snap");
		}
		if(write(sfd, frame + Hdrlen, n - Hdrlen) != n - Hdrlen){
			close(sfd);
			migsay(fd, ea, from, "refused");
			die("the kernel would not take it");
		}
		close(sfd);
	}
	/* the sender destroys what it sent, so say that it arrived */
	migsay(fd, ea, from, "taken");
	close(fd);
	outs("restarted\n");
	flush();
}

static void
migmain(int argc, char **argv)
{
	if(argc < 2)
		die("usage: mig send | copy | recv");
	if(strcmp(argv[1], "send") == 0)
		migsend(1);
	else if(strcmp(argv[1], "copy") == 0)
		migsend(0);
	else if(strcmp(argv[1], "recv") == 0)
		migrecv();
	else
		die("usage: mig send | copy | recv");
}

void
_main(char *argv0)
{
	char **argv;
	int argc;

	argv = &argv0;
	for(argc = 0; argv[argc] != nil; argc++)
		;
	migmain(argc, argv);
	exits(nil);
}
