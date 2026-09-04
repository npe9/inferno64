/*
 * The server personality's ring loop, compiled against the user headers.  It
 * maps this container's ring and its client's slice with segattach, waits
 * on its request ring with select the way a driver task does, and answers
 * each 9P request by handing the marshalled message to p9srv_serve - the
 * exportfs over this personality's own name space - and routing the reply
 * home.  One library operating system then names the other's files over
 * the ring, the kernel only carrying the messages.
 *
 * The 9P server itself (p9srv.c) is compiled against the kernel headers,
 * since it walks real channels; the two header worlds meet only at the
 * plain-typed p9srv_serve.  The request handler is split into its own
 * function: kencc's 6c miscompiles the whole thing as one large routine.
 */
#include <u.h>
#include <libc.h>

enum {
	Ospreymagic	= 0x4f53505259ULL,
	Req9P		= 14,	/* above every request in policy/syscall.h */
	ReqPip		= 18,	/* a pi-p group, carried the same way */
	Reqframe	= 20,	/* a network frame for the stack at this end, over the ring */
	Maxframe	= 1500,	/* the ring wire's MTU (ring9p.c's Maxframe, ospreymedium.c's Ringmtu) */
	Reqsyscall	= 15,
	ReqGone		= 12,
	ReqReserve	= 14+2,	/* above 9P's 14 and syscall's 15: 16 is the list's ReqReserve, 17 ReqTick */
	ReqTick		= 17,
	Nslot		= 16,
	OSdown		= 4,
	Ticksem		= 2,		/* the block device has 1 */
	Tickarm		= 24,		/* the second arm, after the ring's at Armoff */
	Reservebudget	= 2000,		/* 2 ms of every 10: the storage task's own reservation */
	Reserveperiod	= 10000,
	OSget		= 2,
	Armoff		= 0,
	Reqbuf		= 256,
	Kbdsem		= 3,		/* the block device has 1, the clock 2 */
	Mousesem	= 4,
};

typedef struct Omap Omap;
struct Omap {
	uvlong	magic, id, size, msgsize;
	uvlong	requestqueue, replyqueue, outputqueue;
	uvlong	request, reply, output;
	uvlong	data, datalen, sem, nsem, selected;
	uvlong	pktbuf, npktbuf, pktbufsize;
	uvlong	page, npage, maxpage, pagesize;
	uvlong	txbuf, ntxbuf, txbufsize;
};
typedef struct Queue Queue;
struct Queue { vlong message; uvlong size, put, get; };
typedef struct Msg Msg;
struct Msg { uvlong op, sequence, container, arg[5]; };
typedef struct Arm Arm;
struct Arm { uvlong op, obj, buf; };

extern long p9srv_serve(uchar *msg, long n, uchar *rbuf, long rmax);
extern long p9buddy_serve(uchar *cdata, uvlong container);
extern void p9buddy_gone(uvlong container);
extern void p9blk(uchar *base);		/* blkvirtio.c: the user-level block driver */
extern void p9lfsmount(void);		/* main.c: the log-structured store, mounted at /n */

static void
puts(char *s)
{
	write(2, s, strlen(s));
}

static int
oselect(int armoff, int narms)
{
	return dup(narms, armoff);
}

static uchar*
mapslice(int slot)
{
	char nm[16];
	int i, d, started, div;

	i = 0;
	nm[i++]='o'; nm[i++]='s'; nm[i++]='p'; nm[i++]='r'; nm[i++]='e'; nm[i++]='y';
	if(slot == 0)
		nm[i++]='0';
	else {
		started = 0;
		for(div = 1000000000; div > 0; div /= 10){
			d = (slot/div)%10;
			if(d != 0 || started){ nm[i++]='0'+d; started = 1; }
		}
	}
	nm[i] = 0;
	return (uchar*)segattach(0, nm, 0, 0);
}

/* answer one request: select for it, run the 9P server, route the reply */
/*
 * The slices of the containers this server answers for.  The one it was
 * started with is known by slot; a program the kernel exec'd for that
 * client is a container of its own, delegated to this server, and its
 * slice is found by mapping each slot this server is allowed and reading
 * the identity in its map.  What the kernel has not delegated it refuses
 * to map, so the scan sees only what is this server's to see.
 */
static uchar *slices[Nslot];	/* the slices mapped so far, by slot */

/*
 * The slice of the container a request came from: the kernel says which
 * slot it is in the request's first word, since a forwarded request from
 * a container the kernel exec'd carries no other way to find it.  The
 * slot is mapped once and kept; the identity in its map is checked every
 * time, since a slot is reused by the next container the kernel makes
 * when the last one has gone.
 */
static uchar*
sliceof(int slot, uvlong id)
{
	uchar *b;
	Omap *m;

	if(slot < 0 || slot >= Nslot)
		return nil;
	if(slices[slot] == nil){
		b = mapslice(slot);
		if(b == (uchar*)-1)
			return nil;
		slices[slot] = b;
	}
	m = (Omap*)slices[slot];
	if(m->magic != Ospreymagic || m->id != id)
		return nil;
	return slices[slot] + m->data;
}

extern int lfsreclaim(void);
extern long pipfs_serve(uchar *msg, long n, uchar *rbuf, long rmax);	/* pipfsrv.c */
extern void pipfs_tick(void);
extern void sched_tick(void);		/* p9sched.c: advance the cooperative clock */
extern void runkprocs(void);		/* p9sched.c: run ready kprocs, then return */
extern void ospreymediumpump(void);	/* ospreymedium.c: inject frames arrived over the ring */
extern long ospreymediumreceive(uchar *frame, long n, uvlong fromcontainer);	/* one frame off the ring into the stack */
extern long ospreymediumtake(uchar *buf, long max);	/* one frame the stack sent toward the peer, for the reply */
extern void p9kbdnotify(void);		/* p9kbd.c: hand an IRQ1 notification to the driver kproc */
static int reclaims, ticks;

/*
 * A request of this container's own: the reservation it needs, and the
 * clock.  A server's rings run the other way - its request ring carries
 * its clients' requests, its reply ring its answers - so its own asks
 * are a system call (number 60, xcall.s here and ospreyxcall in the
 * kernel), answered at once.
 */
extern long ospreyxcall(int op, uvlong *args, long n);

static long
srvcall(uchar *base, Omap *map, uvlong op, uvlong a0, uvlong a1)
{
	uvlong args[5];

	USED(base, map);
	args[0] = a0;
	args[1] = a1;
	args[2] = args[3] = args[4] = 0;
	if(ospreyxcall((int)op, args, 2) != 1)	/* 1: ReplyDone */
		return -1;
	return 0;
}

/* returns 1 when a request was served, 2 for an empty frame poll, 0 when the tick was, -1 for neither */
static int
serve1(Queue *pq, Msg *repm, Msg *reqp, Arm *arm, uchar *cdata, uvlong cid)
{
	Msg req, rep;
	long i, rn;
	uvlong toff, tlen, roff;
	int n;

	/*
	 * The clock first: select answers the first ready arm, and under a
	 * stream of requests the ring is always ready, so the tick - at most
	 * one every 10 ms - would never be taken if it came second.
	 */
	arm[0].op = OSdown;		/* the clock: reclamation's turn */
	arm[0].obj = Ticksem;
	arm[0].buf = 0;
	arm[1].op = OSget;		/* a request on the ring */
	arm[1].obj = 0;
	arm[1].buf = Reqbuf;
	arm[2].op = OSdown;		/* the keyboard IRQ1 notification */
	arm[2].obj = Kbdsem;
	arm[2].buf = 0;
	arm[3].op = OSdown;		/* the mouse IRQ12 (aux) notification */
	arm[3].obj = Mousesem;
	arm[3].buf = 0;
	n = oselect(Armoff, 4);
	if(n == 0){
		ticks++;
		sched_tick();		/* advance the cooperative scheduler's clock */
		pipfs_tick();		/* leases are measured in these */
		if(lfsreclaim())
			reclaims++;
		ospreymediumpump();	/* inject any frames that arrived over the osprey medium */
		runkprocs();		/* let timer and medium kprocs run on this tick */
		return 0;
	}
	if(n == 2 || n == 3){		/* the keyboard or mouse interrupt fired */
		p9kbdnotify();		/* ready the driver kproc; it does the inb */
		runkprocs();
		return 0;
	}
	if(n != 1)
		return -1;
	req = *reqp;
	for(i = 0; i < (long)sizeof rep; i++)
		((uchar*)&rep)[i] = 0;
	rep.container = req.container;
	rep.sequence = req.sequence;
	if(req.container != cid){
		/* another container this server answers for: a program exec started */
		cdata = sliceof((int)req.arg[2], req.container);
		if(cdata == nil){
			rep.arg[0] = (uvlong)-1;	/* not a count a layout could have */
			repm[pq->put % pq->size] = rep;
			pq->put++;
			return 1;
		}
	}
	if(req.op == Req9P){
		toff = req.arg[2];
		tlen = req.arg[3];
		roff = req.arg[4];
		rn = p9srv_serve(cdata + toff, (long)tlen, cdata + roff, 8192);
		rep.arg[0] = (uvlong)rn;
	} else if(req.op == ReqPip){
		toff = req.arg[2];
		tlen = req.arg[3];
		roff = req.arg[4];
		rn = pipfs_serve(cdata + toff, (long)tlen, cdata + roff, 4096);
		rep.arg[0] = (uvlong)rn;
	} else if(req.op == Reqframe){
		/*
		 * The device-carried wire.  A frame the peer container's stack
		 * sent is handed to the stack at this end (tlen 0 is a poll,
		 * carrying none); the reply carries back one frame this end's
		 * stack has sent toward the peer, or 0 - its own outbound
		 * traffic, the reverse direction of a wire whose request ring
		 * runs one way.  A poll that carried nothing either way is
		 * not counted as a served request (r 2): the client polls on
		 * every tick, and those must not spend the run's request count.
		 */
		toff = req.arg[2];
		tlen = req.arg[3];
		roff = req.arg[4];
		if(tlen > 0)
			ospreymediumreceive(cdata + toff, (long)tlen, req.container);
		rn = ospreymediumtake(cdata + roff, Maxframe);
		rep.arg[0] = (uvlong)rn;
		if(tlen == 0 && rn == 0){
			repm[pq->put % pq->size] = rep;
			pq->put++;
			return 2;
		}
	} else if(req.op == Reqsyscall){
		rn = p9buddy_serve(cdata, req.container);	/* a forwarded legacy system call, or exec/page */
		rep.arg[0] = (uvlong)rn;
	} else if(req.op == ReqGone){
		p9buddy_gone(req.container);	/* let go of the image held for it */
		return 1;			/* nobody is left to reply to */
	} else
		rep.arg[0] = 2;
	repm[pq->put % pq->size] = rep;
	pq->put++;
	return 1;
}

/* arg is "s <ownslot> <clientslot>"; called after the name space is up */
void
p9serveloop(char *arg)
{
	int own, client, iters;
	uchar *base, *cbase;
	Omap *map, *cmap;
	Queue *pq;

	while(*arg != 0 && (*arg < '0' || *arg > '9')) arg++;
	for(own = 0; *arg >= '0' && *arg <= '9'; arg++) own = own*10 + (*arg - '0');
	while(*arg != 0 && (*arg < '0' || *arg > '9')) arg++;
	for(client = 0; *arg >= '0' && *arg <= '9'; arg++) client = client*10 + (*arg - '0');

	base = mapslice(own);
	if(base == (uchar*)-1){ puts("p9 server: could not map its own ring\n"); return; }
	map = (Omap*)base;
	if(map->magic != Ospreymagic){ puts("p9 server: its slice carries no ring map\n"); return; }
	cbase = mapslice(client);
	if(cbase == (uchar*)-1){ puts("p9 server: could not map the client's slice\n"); return; }
	cmap = (Omap*)cbase;
	if(own >= 0 && own < Nslot)
		slices[own] = base;		/* already mapped: a segment slot is not spent twice */
	if(client >= 0 && client < Nslot)
		slices[client] = cbase;
	pq = (Queue*)(base + map->replyqueue);

	p9blk(base);		/* the disk, if the kernel exposed one: a driver above the kernel */
	p9lfsmount();		/* and the file system on it, mounted at /n for the client */
	/*
	 * The kernel put a line on the uart task's own output queue at
	 * boot; the server does not map the uart's slice, so it spends no
	 * segment on it and keeps them for the containers it must map.
	 */
	/*
	 * This task says what it needs: a reservation for its own work -
	 * the storage service's reclamation, paid for out of it - and the
	 * clock tick to do that work on.  Both are requests on its own
	 * ring, answered by the kernel.
	 */
	if(srvcall(base, map, ReqReserve, Reservebudget, Reserveperiod) < 0)
		puts("p9 server: the reservation was refused\n");
	if(srvcall(base, map, ReqTick, Ticksem, 0) < 0)
		puts("p9 server: the tick was refused\n");
	puts("p9 server: serving this name space over the ring\n");
	for(iters = 0; iters < 400; ){
		int r = serve1(pq, (Msg*)((uchar*)pq + pq->message),
			(Msg*)(base + map->data + Reqbuf),
			(Arm*)(base + map->data + Armoff),
			cbase + cmap->data, cmap->id);
		if(r != 0 && r != 2)
			iters++;	/* ticks and empty frame polls do not count toward the end of a headless run */
	}
	{
		char line[96];
		seprint(line, line + sizeof line, "p9 server: done; %d ticks, reclamation ran %d times on them\n", ticks, reclaims);
		puts(line);
	}
}
