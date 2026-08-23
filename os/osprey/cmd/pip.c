/*
 * pip - talk pi-p to /n/osprey/pip.
 *
 * usage: pip [-s sid] transaction ...
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
#include "../pip.h"

enum {
	Bufsize	= 8192,
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
	}
	return "R?";
}

static void
pipmain(int argc, char **argv)
{
	uchar *m;
	uvlong sid, sz;
	long n, k, alen;
	int i, fd, type;

	sid = 0;
	i = 1;
	if(argc > 2 && strcmp(argv[1], "-s") == 0){
		sid = num(argv[2]);
		i = 3;
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
		} else
			die("usage: pip [-s sid] open FID NAME | read FID ATTR | write FID ATTR VAL | lease FID | close FID");
	}

	if((fd = open("/n/osprey/pip", ORDWR)) < 0)
		die("cannot open /n/osprey/pip");
	if(write(fd, wbuf, wn) != wn)
		die("write failed");
	n = read(fd, rbuf, sizeof rbuf);
	close(fd);
	if(n <= 0)
		die("no reply");

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
