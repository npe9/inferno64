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
#include <osprey9.h>

enum {
	Nfd		= 16,
	Nclient		= 16,
	Nslice		= 16,	/* slices to look through by default */
	Namelen		= 256,
};

typedef struct Client Client;
/*
 * A container this server answers for.  Each has a process of its own,
 * forked with a name space of its own, and the pipe by which the process
 * that owns the ring hands it a request and takes the answer back.  What
 * the request names is in the shared span, not in the pipe.
 */
struct Client {
	uvlong	id;
	uchar	*base;
	int	fd[Nfd];
	int	pipe;		/* -1 in the parent until the child exists */
	int	mine;		/* set in the process that answers for it */
};

enum {
	Qrequests,
	Qreplies,
};

static Osprey o;

static int verbose;
static Client client[Nclient];
static int nclient;

static void childloop(Client*, int);

static uvlong slicesize;
static int nslice = Nslice;
/*
 * From this server's own map, never a client's: a container may write
 * every byte of its map, and a server that believed one would be told
 * to read and write wherever that container liked.
 */
static uvlong dataoff;
static uvlong datalen;

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
		if(o9num(p+5) != id)
			continue;
		for(l = p+5; *l != '\0'; l++)
			if(strncmp(l, " slice ", 7) == 0){
				off = o9num(l+7);
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
	int i, slot, pfd[2];

	for(i = 0; i < Nclient; i++)
		if(client[i].id == id && client[i].pipe >= 0)
			return &client[i];
	for(nclient = 0; nclient < Nclient; nclient++)
		if(client[nclient].id == 0)
			break;
	if(nclient >= Nclient)
		return nil;
	if((slot = slotof(id)) < 0 || slot >= nslice)
		return nil;
	e = o9catstr(name, "osprey");
	e = o9catnum(e, (uvlong)slot);
	*e = '\0';
	/*
	 * The slice is attached before the fork and not after: a segment
	 * attached in one process afterwards is not in the other, whatever
	 * its type.  This one is SG_PHYSICAL, which fork shares rather
	 * than copies, so the child writes where the client will read.
	 */
	va = (uchar*)segattach(0, name, 0, slicesize);
	if(va == (uchar*)-1)
		return nil;
	c = &client[nclient];
	c->id = id;
	c->base = va;
	c->pipe = -1;
	c->mine = 0;
	for(i = 0; i < Nfd; i++)
		c->fd[i] = -1;
	if(pipe(pfd) < 0)
		return nil;
	/*
	 * A name space of its own, and a file descriptor group of its own
	 * so that what it opens for its container is not in anybody
	 * else's.  Its memory is a copy, which is why the record above is
	 * filled in first: the child reads its own copy of it and the two
	 * never write to each other's.
	 */
	switch(rfork(RFPROC|RFNAMEG|RFFDG|RFREND)){
	case -1:
		c->id = 0;
		close(pfd[0]);
		close(pfd[1]);
		return nil;
	case 0:
		c->mine = 1;
		close(pfd[0]);
		if(o.ctlfd >= 0)
			close(o.ctlfd);
		/* the pipes of every other container this server answers for */
		for(i = 0; i < Nclient; i++)
			if(&client[i] != c && client[i].pipe >= 0)
				close(client[i].pipe);
		childloop(c, pfd[1]);
		exits(nil);
	}
	close(pfd[1]);
	c->pipe = pfd[0];
	if(verbose){
		o9outs("serving container "); o9outd(id);
		o9outs(" in "); o9outs(name); o9outs("\n"); o9flush();
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
 * Answer one request in the name space of the container it came from.
 * This runs in that container's own process; nothing here enters the
 * kernel except the ordinary system call the operation is, which is the
 * whole of the point.
 */
static int
answer(Client *c, Message *mp)
{
	char *a, *e;
	uvlong off, cnt;
	long n;
	int i, fd;

	switch(mp->op){
	case ReqOpen:
		if((a = clientname(c, mp->arg[2])) == nil)
			return ReplyError;
		for(i = 0; i < Nfd; i++)
			if(c->fd[i] < 0)
				break;
		if(i == Nfd)
			return ReplyError;
		if((fd = open(a, (int)mp->arg[3])) < 0)
			return ReplyError;
		c->fd[i] = fd;
		mp->arg[2] = i;
		if(verbose){
			o9outs("open '"); o9outs(a); o9outs("' -> "); o9outd(i);
			o9outs("\n"); o9flush();
		}
		return ReplyDone;

	case ReqRead:
	case ReqWrite:
		i = (int)mp->arg[2];
		if(i < 0 || i >= Nfd || c->fd[i] < 0)
			return ReplyError;
		off = mp->arg[3];
		cnt = mp->arg[4];
		if((a = clientdata(c, off, cnt)) == nil)
			return ReplyError;
		if(mp->op == ReqRead)
			n = read(c->fd[i], a, (long)cnt);
		else
			n = write(c->fd[i], a, (long)cnt);
		if(n < 0)
			return ReplyError;
		mp->arg[2] = (uvlong)n;
		return ReplyDone;

	case ReqStat:
		i = (int)mp->arg[2];
		if(i < 0 || i >= Nfd || c->fd[i] < 0)
			return ReplyError;
		off = mp->arg[3];
		cnt = mp->arg[4];
		if((a = clientdata(c, off, cnt)) == nil)
			return ReplyError;
		if((n = fstat(c->fd[i], (uchar*)a, (long)cnt)) < 0)
			return ReplyError;
		mp->arg[2] = (uvlong)n;
		return ReplyDone;

	case ReqBind:
		/*
		 * The kernel refuses this: a container has no name space of
		 * its own there, only the name table the policy layer keeps.
		 * Here it is the ordinary bind, in the name space of the
		 * process this server forked for this container and nobody
		 * else -- so what one container binds, another container of
		 * the same server does not see, and neither does the server.
		 * That is the whole difference between a personality and a
		 * device.
		 */
		if((a = clientname(c, mp->arg[2])) == nil)
			return ReplyError;
		if((e = clientname(c, mp->arg[3])) == nil)
			return ReplyError;
		if(bind(a, e, (int)mp->arg[4]) < 0)
			return ReplyError;
		if(verbose){
			o9outs("bind '"); o9outs(a); o9outs("' '"); o9outs(e);
			o9outs("'\n"); o9flush();
		}
		return ReplyDone;

	case ReqClose:
		i = (int)mp->arg[2];
		if(i < 0 || i >= Nfd || c->fd[i] < 0)
			return ReplyError;
		close(c->fd[i]);
		c->fd[i] = -1;
		return ReplyDone;
	}
	/*
	 * A personality answers what it implements and says so about the
	 * rest.  It does not fall back into the kernel: a container that
	 * named this server named it for everything the kernel does not
	 * keep for itself.
	 */
	return ReplyError;
}

/*
 * A container's own process.  It reads a request, performs it in its own
 * name space and writes the answer back.  Only the message travels the
 * pipe; what the message points at is in the span both processes have
 * mapped, so nothing is copied through it.
 */
static void
childloop(Client *c, int fd)
{
	Message m;

	for(;;){
		if(readn(fd, &m, sizeof m) != sizeof m)
			exits(nil);
		m.arg[0] = (uvlong)answer(c, &m);
		if(write(fd, &m, sizeof m) != sizeof m)
			exits(nil);
	}
}

/*
 * Hand the request to the process that holds that container's name space
 * and wait for it.  One request at a time: this end of the ring has one
 * consumer, and making it more than one would need a second.
 */
/*
 * A container this server answered for has gone.  Closing the pipe ends
 * the process that held its name space -- its read returns nothing --
 * and with the process goes everything it had open there.  What is left
 * is this end of the pipe and the mapping of a slice that is about to be
 * somebody else's, and both are let go here.
 */
static void
gone(uvlong id)
{
	Client *c;
	int i;

	for(i = 0; i < Nclient; i++){
		c = &client[i];
		if(c->id != id || c->pipe < 0)
			continue;
		close(c->pipe);
		c->pipe = -1;
		if(c->base != nil)
			segdetach(c->base);
		c->base = nil;
		c->id = 0;
		if(verbose){
			o9outs("container "); o9outd(id);
			o9outs(" gone\n"); o9flush();
		}
		return;
	}
}

static int
serve(Message *mp)
{
	Client *c;

	if(mp->op == ReqGone){
		gone(mp->container);
		return -1;
	}
	if((c = clientof(mp->container)) == nil)
		return ReplyError;
	if(write(c->pipe, mp, sizeof *mp) != sizeof *mp)
		return ReplyError;
	if(readn(c->pipe, mp, sizeof *mp) != sizeof *mp)
		return ReplyError;
	return (int)mp->arg[0];
}

static void
srvmain(int argc, char **argv)
{
	Message *mp;
	int st;

	if(argc < 3)
		o9die("usage: p9srv segment size [nslice]");
	slicesize = o9num(argv[2]);
	if(argc > 3)
		nslice = (int)o9num(argv[3]);
	if(argc > 4 && strcmp(argv[4], "-v") == 0)
		verbose = 1;

	if(o9attach(&o, argv[1], slicesize) < 0)
		o9die(o.err);
	dataoff = o.map->data;
	datalen = o.map->datalen;
	mp = o9armmsg(&o);

	o9outs("p9srv container "); o9outd(o.id);
	o9outs(" serving\n"); o9flush();

	for(;;){
		/*
		 * One arm: whatever the kernel forwarded onto this
		 * container's request ring.  The talk's driver shape is a
		 * select over several; a personality has only the one
		 * source, so this is that shape with one arm in it.
		 */
		o9arm(&o, 0, OSget, Qrequests);
		if((st = o9select(&o, 1)) == -1)
			o9die("the kernel will not wait for this container");
		if(st < 0)
			continue;

		if((st = serve(mp)) < 0)
			continue;	/* nothing to answer, and nobody to */

		/*
		 * The answer goes back in the same message, which still
		 * carries the container and the sequence the request came
		 * with; that is how the kernel knows whose it is.
		 */
		mp->arg[0] = (uvlong)st;
		o9arm(&o, 0, OSput, Qreplies);
		if(o9select(&o, 1) < 0)
			o9die("the answer could not be put back");
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
