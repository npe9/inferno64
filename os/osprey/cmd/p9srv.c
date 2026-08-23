/*
 * p9srv - the Plan 9 personality, outside the kernel.
 *
 * Osprey's talk says the kernel keeps message passing, address spaces,
 * interrupts and scheduling, and that everything else is a library
 * operating system: a program, in its own name space, answering for
 * whoever asked.  The kernel in this tree still holds a whole 9front --
 * chan.c, dev.c, pgrp.c, sysfile.c, every device, the ip stack and every
 * driver -- and answers a container's open, read, write and close from
 * inside it, in ospreykernop().  That is the thing a library operating
 * system replaces.
 *
 * This is that replacement for one container.  It is an ordinary user
 * process.  It maps its own container's slice, waits on its request
 * ring, and for each request that arrives performs the operation with
 * the ordinary system calls, in its own name space, and puts the answer
 * back.  The kernel does no more than carry the message: dispatch() in
 * ospreyrt.c offers a delegated request to the server before it offers
 * it to ospreykernop(), so nothing of the kernel's own personality is
 * consulted for a container that has named one of these.
 *
 * usage: p9srv segment size [nslice]
 *
 * The segment is this server's own container slice -- osprey0, osprey1
 * and so on, as /n/osprey/status reports -- and the size is that
 * slice's.  nslice is how many slices to look through for the containers
 * it serves; the default covers every one this kernel publishes.
 *
 * A request names its arguments as offsets into the *asking* container's
 * data area, so the server maps those slices too.  It may: a container
 * that delegates to a server has thereby given that server the right to
 * its memory, which is what ospreyentitled() in devosprey.c now says.
 * Which slice belongs to which container is asked of /n/osprey/status
 * rather than read out of the maps, since a container may write its own
 * map and could otherwise claim to be one of the others.
 *
 * The offsets within a slice are not read from the slice.  Every slice
 * is laid out identically by mapfix(), from kernel constants, and a
 * container may write every byte of its own map -- so this takes the
 * data area's offset and length from its own map, which nobody else can
 * write, and applies them to the client.  Reading them from the client's
 * map would let a container that lied about datalen have its server
 * write a read() past the end of the slice and into the next one.
 *
 * As with ring(1), the program uses only the system calls out of the
 * library and formats its own output: the library here was built by a
 * newer compiler than this loader reads, and its printing and startup
 * members cannot be linked.
 */
#include <u.h>
#include <libc.h>

typedef struct Ospreymap Ospreymap;
typedef struct Queue Queue;
typedef struct Message Message;
typedef struct Arm Arm;
typedef struct Client Client;

enum {
	Ospreymagic	= 0x4f53505259ULL,
	Nword		= 5,
	Narm		= 8,
	Nfd		= 16,
	Nclient		= 16,
	Nslice		= 16,	/* slices to look through by default */
	Namelen		= 256,
};

/*
 * The head of every slice.  Only the fields up to selected are read
 * here, and they must stay in the order osprey.h gives them; adding a
 * field there before one of these moves it silently.
 */
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

/* a container this server answers for, and what it has open here */
struct Client {
	uvlong	id;
	uchar	*base;
	int	fd[Nfd];
};

enum {				/* arm operations, as ospreyselect reads them */
	OSlast,
	OSnoop,
	OSget,
	OSput,
	OSdown,
};

enum {				/* request operations, as syscall.h orders them */
	Opread,
	Opwrite,
	Opopen,
	Opclose,
	Opwait,
	Opsend,
	Oprecv,
	Opstat,
	Opbind,
	Opalloc,
	Opyield,
	Oppoll,
};

enum {				/* reply status, as syscall.h orders it */
	Stpending,
	Stdone,
	Sterror,
};

enum {
	Qrequests,
	Qreplies,
};

static char obuf[512];
static int on;
static int verbose;

static Client client[Nclient];
static int nclient;

static uvlong dataoff;		/* from this server's own map, never a client's */
static uvlong datalen;
static uvlong slicesize;
static int nslice = Nslice;
static int ctlfd = -1;
static uvlong myid;

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
die(char *s)
{
	outs("p9srv: ");
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

/*
 * Wait on the arms just built, or hand back what they hold.  A select is
 * the only trap this program takes: everything it does with the message
 * is done in the mapped slice.
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

/*
 * Which slice a container's memory is, asked of the kernel.  The id a
 * request carries is the container's, and the map at the head of each
 * slice has an id in it -- but a container may write its own map, so
 * looking for a matching id there would let one container claim to be
 * another and have this server answer somebody else's request against
 * its memory.  status is the kernel's own account and is asked instead.
 */
static int
slotof(uvlong id)
{
	static char st[33*1024];	/* status is at most Statuslen */
	char *p, *e, *l;
	uvlong off;
	long n, t;
	int fd;

	if((fd = open("/n/osprey/status", OREAD)) < 0)
		return -1;
	/* a read gives what it gives; the whole of it is wanted */
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
			e = p + strlen(p);	/* the last line ends the walk */
		if(strncmp(p, "proc ", 5) != 0)
			continue;
		if(num(p+5) != id)
			continue;
		for(l = p+5; *l != '\0'; l++)
			if(strncmp(l, " slice ", 7) == 0){
				off = num(l+7);
				if(slicesize == 0)
					return -1;
				return (int)(off / slicesize);
			}
		return -1;
	}
	return -1;
}

/*
 * The container an arrived request came from.  A slice is attached once
 * and kept; a miss is looked for again, since a container may have been
 * made after this server started.
 */
static Client*
clientof(uvlong id)
{
	Client *c;
	char name[32], *e;
	uchar *va;
	int i, slot;

	for(i = 0; i < nclient; i++)
		if(client[i].id == id)
			return &client[i];
	if(nclient >= Nclient)
		return nil;
	if((slot = slotof(id)) < 0 || slot >= nslice)
		return nil;
	e = catstr(name, "osprey");
	e = catnum(e, (uvlong)slot);
	*e = '\0';
	va = (uchar*)segattach(0, name, 0, slicesize);
	if(va == (uchar*)-1)
		return nil;
	c = &client[nclient++];
	c->id = id;
	c->base = va;
	for(i = 0; i < Nfd; i++)
		c->fd[i] = -1;
	if(verbose){
		outs("serving container "); outd(id);
		outs(" in "); outs(name); outs("\n"); flush();
	}
	return c;
}

/* a client's data area, with the bounds this server was given, not theirs */
static char*
clientdata(Client *c, uvlong off, uvlong len)
{
	if(c == nil || off >= datalen || len > datalen - off)
		return nil;
	return (char*)c->base + dataoff + off;
}

/*
 * A name a request points at: NUL terminated, inside the data area, and
 * no longer than a name may be.  The bounds are this server's, not the
 * client's, for the reason clientdata gives.
 */
static char*
clientname(Client *c, uvlong off)
{
	char *a, *e;
	long n;

	if((a = clientdata(c, off, 1)) == nil)
		return nil;
	n = datalen - off;
	if(n > Namelen)
		n = Namelen;
	if((e = memchr(a, 0, n)) == nil || e == a)
		return nil;
	return a;
}

/*
 * Answer one request in this server's own name space.  Nothing here
 * enters the kernel except the ordinary system call the operation is:
 * that is the whole of the point.
 */
static int
serve(Message *mp)
{
	Client *c;
	char *a, *e;
	uvlong off, cnt;
	long n;
	int i, fd;

	if((c = clientof(mp->container)) == nil)
		return Sterror;

	switch(mp->op){
	case Opopen:
		if((a = clientname(c, mp->arg[2])) == nil)
			return Sterror;
		for(i = 0; i < Nfd; i++)
			if(c->fd[i] < 0)
				break;
		if(i == Nfd)
			return Sterror;
		if((fd = open(a, (int)mp->arg[3])) < 0)
			return Sterror;
		c->fd[i] = fd;
		mp->arg[2] = i;
		if(verbose){
			outs("open '"); outs(a); outs("' -> "); outd(i);
			outs("\n"); flush();
		}
		return Stdone;

	case Opread:
	case Opwrite:
		i = (int)mp->arg[2];
		if(i < 0 || i >= Nfd || c->fd[i] < 0)
			return Sterror;
		off = mp->arg[3];
		cnt = mp->arg[4];
		if((a = clientdata(c, off, cnt)) == nil)
			return Sterror;
		if(mp->op == Opread)
			n = read(c->fd[i], a, (long)cnt);
		else
			n = write(c->fd[i], a, (long)cnt);
		if(n < 0)
			return Sterror;
		mp->arg[2] = (uvlong)n;
		return Stdone;

	case Opstat:
		i = (int)mp->arg[2];
		if(i < 0 || i >= Nfd || c->fd[i] < 0)
			return Sterror;
		off = mp->arg[3];
		cnt = mp->arg[4];
		if((a = clientdata(c, off, cnt)) == nil)
			return Sterror;
		if((n = fstat(c->fd[i], (uchar*)a, (long)cnt)) < 0)
			return Sterror;
		mp->arg[2] = (uvlong)n;
		return Stdone;

	case Opbind:
		/*
		 * The kernel refuses this: a container has no name space of
		 * its own there, only the name table the policy layer keeps.
		 * Here it is the ordinary bind, in the server's name space,
		 * which is the container's name space for as long as this
		 * server answers for it.  That is the whole difference
		 * between a personality and a device.
		 */
		if((a = clientname(c, mp->arg[2])) == nil)
			return Sterror;
		if((e = clientname(c, mp->arg[3])) == nil)
			return Sterror;
		if(bind(a, e, (int)mp->arg[4]) < 0)
			return Sterror;
		if(verbose){
			outs("bind '"); outs(a); outs("' '"); outs(e);
			outs("'\n"); flush();
		}
		return Stdone;

	case Opclose:
		i = (int)mp->arg[2];
		if(i < 0 || i >= Nfd || c->fd[i] < 0)
			return Sterror;
		close(c->fd[i]);
		c->fd[i] = -1;
		return Stdone;
	}
	/*
	 * A personality answers what it implements and says so about the
	 * rest.  It does not fall back into the kernel: a container that
	 * named this server named it for everything the kernel does not
	 * keep for itself.
	 */
	return Sterror;
}

static void
srvmain(int argc, char **argv)
{
	uchar *base;
	Ospreymap *m;
	Arm *a;
	Message *mp;
	uvlong bufoff;
	int st;

	if(argc < 3)
		die("usage: p9srv segment size [nslice]");
	slicesize = num(argv[2]);
	if(argc > 3)
		nslice = (int)num(argv[3]);
	if(argc > 4 && strcmp(argv[4], "-v") == 0)
		verbose = 1;

	base = (uchar*)segattach(0, argv[1], 0, slicesize);
	if(base == (uchar*)-1)
		die("segattach failed");
	m = (Ospreymap*)base;
	if(m->magic != Ospreymagic)
		die("no container mapped there");
	myid = m->id;
	dataoff = m->data;
	datalen = m->datalen;

	if((ctlfd = open("/n/osprey/ctl", OWRITE)) < 0)
		die("cannot open /n/osprey/ctl");

	a = (Arm*)(base + dataoff);
	bufoff = (uvlong)(Narm*sizeof(Arm));
	mp = (Message*)(base + dataoff + bufoff);

	outs("p9srv container "); outd(myid);
	outs(" serving\n"); flush();

	for(;;){
		/*
		 * One arm: whatever the kernel forwarded onto this
		 * container's request ring.  The talk's driver shape is a
		 * select over several; a personality has only the one
		 * source, so this is that shape with one arm in it.
		 */
		a[0].op = OSget; a[0].obj = Qrequests; a[0].buf = bufoff;
		a[1].op = OSlast; a[1].obj = 0; a[1].buf = 0;
		if(selectarms(2) < 0)
			die("select for a request failed");
		if(m->selected == ~0ULL)
			continue;

		st = serve(mp);

		/*
		 * The answer goes back in the same message, which still
		 * carries the container and the sequence the request came
		 * with; that is how the kernel knows whose it is.
		 */
		mp->arg[0] = (uvlong)st;
		a[0].op = OSput; a[0].obj = Qreplies; a[0].buf = bufoff;
		a[1].op = OSlast; a[1].obj = 0; a[1].buf = 0;
		if(selectarms(2) < 0)
			die("select to answer failed");
	}
}

/*
 * The library's own startup member cannot be linked here, so the program
 * supplies one, as ring(1) and initcode do.
 */
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
