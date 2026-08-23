/*
 * pip - talk pi-p to /n/osprey/pip.
 *
 * usage: pip [-e] [-s sid] transaction ...
 *
 * With -e the group goes on the wire in a frame of its own type rather
 * than through /n/osprey/pip, and the reply comes back the same way.
 * Nothing about it is a connection: the group says which session it is,
 * which is what lets the protocol be its own transport.
 *
 * A transaction is
 *	open FID NAME		walk, clone and open in one message
 *	read FID ATTR		read an attribute, * for the list of them
 *	write FID ATTR VALUE	set one
 *	lease FID		renew the fid and its session
 *	close FID		commit what was written, and let it go
 *
 * All of them given at once go in one group: one write and one read, one
 * round trip, however many transactions.  With -s the session is resumed
 * rather than made, which is the point of a session outliving the
 * connection that carried it -- this program opens a new one every time
 * it runs.
 *
 * It formats its own output and supplies its own startup, as ring does,
 * because the library here cannot be linked by this loader.
 */
#include <u.h>
#include <libc.h>
#include "../port/pip.h"

enum {
	Bufsize	= 8192,
	Ethertype = 0x910a,
	Hdrlen	= 14,
	Minframe = 60,
};

static uchar wbuf[Bufsize], rbuf[Bufsize];
static long wn;
static char obuf[4096];
static int on;
static int tag;

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
outb(uchar *p, long n)
{
	while(n-- > 0 && on < sizeof obuf - 1)
		obuf[on++] = *p++;
}

static void
die(char *s)
{
	outs("pip: ");
	outs(s);
	outs("\n");
	flush();
	exits(s);
}

/* the same, with what the kernel said about it */
static void
dieerr(char *s)
{
	static char e[128];

	e[0] = '\0';
	errstr(e, sizeof e);
	outs("pip: ");
	outs(s);
	if(e[0] != '\0'){
		outs(": ");
		outs(e);
	}
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

static uvlong
get(uchar *p, int n)
{
	uvlong v;
	int i;

	v = 0;
	for(i = n; i-- > 0; )
		v = (v<<8) | p[i];
	return v;
}

static void
put(uchar *p, int n, uvlong v)
{
	int i;

	for(i = 0; i < n; i++, v >>= 8)
		p[i] = v;
}

static uchar*
msg(int type, long n)
{
	uchar *m;

	if(wn + Pipheader + n > sizeof wbuf)
		die("group too large");
	m = wbuf + wn;
	put(m, 4, Pipheader + n);
	m[4] = type;
	put(m+5, 2, ++tag);
	wn += Pipheader + n;
	return m + Pipheader;
}

static long
str(uchar *p, char *s)
{
	long n;

	n = strlen(s);
	put(p, 2, n);
	memmove(p+2, s, n);
	return 2 + n;
}

static char*
typename(int t)
{
	switch(t){
	case PipRsession:	return "Rsession";
	case PipRopen:		return "Ropen";
	case PipRread:		return "Rread";
	case PipRwrite:		return "Rwrite";
	case PipRclose:		return "Rclose";
	case PipRlease:		return "Rlease";
	case PipRerror:		return "Rerror";
	case PipRstream:	return "Rstream";
	case PipRauth:		return "Rauth";
	}
	return "R?";
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

static int
hexd(int c)
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

/* a conversation of our own, carrying only our own frame type */
static int
etherfd(void)
{
	char buf[64], path[64], *e;
	int fd, n, cno;

	/* this fd is the conversation's ctl file; it must stay open */
	if((fd = open("#l/ether0/clone", ORDWR)) < 0)
		die("cannot clone #l/ether0");
	n = read(fd, buf, sizeof buf - 1);
	if(n <= 0)
		die("cannot read the conversation number");
	buf[n] = '\0';
	cno = (int)num(buf);

	e = cat(buf, "connect ");
	catn(e, Ethertype);
	if(write(fd, buf, strlen(buf)) < 0)
		die("cannot set the frame type");
	e = cat(path, "#l/ether0/");
	e = catn(e, cno);
	cat(e, "/data");
	return open(path, ORDWR);
}

static int efd = -1;
static uchar ea[6];

/* the wire: our own address, and a conversation carrying our own type */
static void
etheropen(void)
{
	char buf[32];
	int fd, n, i, a, b;

	if(efd >= 0)
		return;
	if((fd = open("#l/ether0/addr", OREAD)) < 0)
		die("no #l/ether0/addr");
	n = read(fd, buf, sizeof buf - 1);
	close(fd);
	if(n < 12)
		die("short address");
	for(i = 0; i < 6; i++){
		a = hexd(buf[2*i]);
		b = hexd(buf[2*i+1]);
		if(a < 0 || b < 0)
			die("bad address");
		ea[i] = (a<<4) | b;
	}

	if((efd = etherfd()) < 0)
		die("cannot open the conversation data");
}

/* the group into a frame */
static void
ethersend(uchar *w, long wn)
{
	static uchar f[2048];
	long n;
	int i;

	etheropen();
	for(i = 0; i < 6; i++)
		f[i] = 0xff;
	memmove(f+6, ea, 6);
	f[12] = Ethertype >> 8;
	f[13] = Ethertype;
	memmove(f+Hdrlen, w, wn);
	/* a frame shorter than the ethernet minimum is refused outright */
	n = Hdrlen + wn;
	while(n < Minframe)
		f[n++] = 0;
	if(write(efd, f, n) != n)
		die("the frame did not go");
}

/* and whatever comes back out of the next frame that is not our own */
static long
etherrecv(uchar *r, long rn)
{
	static uchar f[2048];
	long n;

	etheropen();
	for(;;){
		n = read(efd, f, sizeof f);
		if(n <= Hdrlen)
			die("nothing came back");
		if(memcmp(f+6, ea, 6) != 0)
			break;
	}
	n -= Hdrlen;
	if(n > rn)
		n = rn;
	memmove(r, f+Hdrlen, n);
	return n;
}

static void
show(uchar *rbuf, long n)
{
	uvlong sz;
	uchar *m;
	long k, alen;
	int type;

	for(k = 0; k + Pipheader <= n; ){
		sz = get(rbuf+k, 4);
		if(sz < Pipheader || k + sz > n)
			break;
		type = rbuf[k+4];
		m = rbuf + k + Pipheader;
		outs(typename(type));
		outs(" tag "); outn(get(rbuf+k+5, 2));
		switch(type){
		case PipRsession:
			outs(" sid "); outn(get(m, 8));
			break;
		case PipRopen:
			outs(" qid "); outn(get(m, 8));
			outs(" version "); outn(get(m+8, 8));
			outs(" lease "); outn(get(m+16, 8));
			break;
		case PipRread:
			outs(" version "); outn(get(m, 8));
			alen = get(m+8, 2);
			outs(" '"); outb(m+10, alen); outs("'");
			break;
		case PipRstream:
			outs(" period "); outn(get(m, 8));
			break;
		case PipRauth:
			alen = get(m, 2);
			outs(" '"); outb(m+2, alen); outs("'");
			break;
		case PipRwrite:
		case PipRclose:
		case PipRlease:
			outs(" "); outn(get(m, 8));
			break;
		case PipRerror:
			alen = get(m, 2);
			outs(" '"); outb(m+2, alen); outs("'");
			break;
		}
		outs("\n");
		k += sz;
	}
}

static void
pipmain(int argc, char **argv)
{
	uchar *m;
	uvlong sid;
	long n, k, alen, waiting;
	int i, fd, ether;

	sid = 0;
	waiting = 0;
	ether = 0;
	i = 1;
	if(i < argc && strcmp(argv[i], "-e") == 0){
		ether = 1;
		i++;
	}
	if(i+1 < argc && strcmp(argv[i], "-s") == 0){
		sid = num(argv[i+1]);
		i += 2;
	}

	/* the group opens by saying which session it is, or asking for one */
	m = msg(PipTsession, 8);
	put(m, 8, sid);

	for(; i < argc; ){
		if(strcmp(argv[i], "open") == 0 && i+2 < argc){
			n = strlen(argv[i+2]);
			m = msg(PipTopen, 4+4+1+2+n);
			put(m, 4, 0);			/* from the root */
			put(m+4, 4, num(argv[i+1]));	/* into this fid */
			m[8] = 0;			/* how: read */
			str(m+9, argv[i+2]);
			i += 3;
		} else if(strcmp(argv[i], "read") == 0 && i+2 < argc){
			n = strlen(argv[i+2]);
			m = msg(PipTread, 4+4+2+n);
			put(m, 4, num(argv[i+1]));
			put(m+4, 4, 1024);
			str(m+8, argv[i+2]);
			i += 3;
		} else if(strcmp(argv[i], "write") == 0 && i+3 < argc){
			n = strlen(argv[i+2]);
			k = strlen(argv[i+3]);
			m = msg(PipTwrite, 4+2+n+2+k);
			put(m, 4, num(argv[i+1]));
			str(m+4, argv[i+2]);
			str(m+4+2+n, argv[i+3]);
			i += 4;
		} else if(strcmp(argv[i], "lease") == 0 && i+1 < argc){
			m = msg(PipTlease, 4);
			put(m, 4, num(argv[i+1]));
			i += 2;
		} else if(strcmp(argv[i], "close") == 0 && i+1 < argc){
			m = msg(PipTclose, 4);
			put(m, 4, num(argv[i+1]));
			i += 2;
		} else if(strcmp(argv[i], "auth") == 0 && i+1 < argc){
			alen = strlen(argv[i+1]);
			m = msg(PipTauth, 2+alen);
			put(m, 2, alen);
			memmove(m+2, argv[i+1], alen);
			i += 2;
		} else if(strcmp(argv[i], "stream") == 0 && i+4 < argc){
			alen = strlen(argv[i+4]);
			m = msg(PipTstream, 4+4+4+2+alen);
			put(m, 4, num(argv[i+1]));
			put(m+4, 4, num(argv[i+2]));
			put(m+8, 4, num(argv[i+3]));
			put(m+12, 2, alen);
			memmove(m+14, argv[i+4], alen);
			waiting = (long)num(argv[i+3]);
			i += 5;
		} else
			die("usage: pip [-e] [-s sid] open FID NAME | read FID ATTR | write FID ATTR VAL | lease FID | stream FID PERIOD COUNT ATTR | auth TICKET | close FID");
	}

	if(ether){
		ethersend(wbuf, wn);
		n = etherrecv(rbuf, sizeof rbuf);
	} else {
		if((fd = open("/n/osprey/pip", ORDWR)) < 0)
			dieerr("cannot open /n/osprey/pip");
		if(write(fd, wbuf, wn) != wn)
			dieerr("write failed");
		n = read(fd, rbuf, sizeof rbuf);
		close(fd);
	}
	if(n <= 0)
		die("no reply");

	show(rbuf, n);
	/*
	 * a stream keeps arriving on its own; nothing is sent to make the
	 * rest of it happen.
	 */
	while(ether && waiting > 0){
		n = etherrecv(rbuf, sizeof rbuf);
		show(rbuf, n);
		waiting--;
	}
	flush();
}

void
_main(char *argv0)
{
	char **argv;
	int argc;

	argv = &argv0;
	for(argc = 0; argv[argc] != nil; argc++)
		;
	pipmain(argc, argv);
	exits(nil);
}
