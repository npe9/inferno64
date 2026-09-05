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
	Inpktbuf	= 0xB0F,	/* arg[4] of a Reqframe: the frame is in the client's packet buffer arg[2] */
	Rxslot0		= 16,	/* the client's packet buffers 16-31 carry this end's frames to it */
	Nrxslot		= 16,
	ReqMigrate	= 22,	/* the kernel: carry this container's process over the wire (OpMigrate) */
	Maxframe	= 2048,	/* the ring wire's MTU (ring9p.c's Maxframe, ospreymedium.c's Ringmtu): a packet buffer */
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
	Netsem		= 5,		/* the network device's interrupt */
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
extern void ospreymediumflush(void);	/* frames the stack sent toward the peer that had to wait for room on its queue */
extern void p9kbdnotify(void);		/* p9kbd.c: hand an IRQ1 notification to the driver kproc */
extern void p9vnet(uchar *base);		/* netvirtio.c: the user-level network driver */
extern void p9migrate(uvlong container);	/* p9ip.c: carry a container's process over the wire, in a kproc */
static uchar *srvbase;			/* this server's own slice, for p9srvdata */
static uchar *clientbase;		/* the client's slice: its output queue and packet buffers, filled in memory */
static Omap *clientmap;
static int rxnext;			/* the next of the client's packet buffers to put a frame in */
static long framesout, kicks;
extern void p9vnetup(void);		/* p9ip.c: the interface on it, and the machine's role on the wire */
extern void ospreyvnetpump(void);	/* ospreyvnetmedium.c: what the device received, into the stack */
static int reclaims, ticks;
static int opcount[32];			/* requests served, by op: what the periodic line names */
static int unmapped;			/* requests from a container whose slice could not be mapped */
static uvlong unmappedop, unmappedfrom, unmappedslot;

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
	arm[4].op = OSdown;		/* the network device's interrupt */
	arm[4].obj = Netsem;
	arm[4].buf = 0;
	n = oselect(Armoff, 5);
	if(n == 0){
		ticks++;
		sched_tick();		/* advance the cooperative scheduler's clock */
		pipfs_tick();		/* leases are measured in these */
		if(lfsreclaim())
			reclaims++;
		ospreymediumpump();	/* inject any frames that arrived over the osprey medium */
		ospreymediumflush();	/* and give the peer what waited for room on its queue */
		ospreyvnetpump();	/* and any the network device received */
		runkprocs();		/* let timer and medium kprocs run on this tick */
		return 0;
	}
	if(n == 2 || n == 3){		/* the keyboard or mouse interrupt fired */
		p9kbdnotify();		/* ready the driver kproc; it does the inb */
		runkprocs();
		return 0;
	}
	if(n == 4){			/* the network device's interrupt */
		ospreyvnetpump();
		runkprocs();
		return 0;
	}
	if(n != 1)
		return -1;
	req = *reqp;
	if(req.op < 32)
		opcount[req.op]++;
	for(i = 0; i < (long)sizeof rep; i++)
		((uchar*)&rep)[i] = 0;
	rep.container = req.container;
	rep.sequence = req.sequence;
	/*
	 * What the kernel itself puts on this ring names a container and
	 * nothing else - no slot to map - so it is answered before any
	 * slice is looked for: a container gone, or one to carry over the
	 * wire.  Neither is replied to on the ring.
	 */
	if(req.op == ReqGone){
		p9buddy_gone(req.container);	/* let go of the image held for it */
		return 1;
	}
	if(req.op == ReqMigrate){
		p9migrate(req.container);	/* the kernel asks: a kproc carries it over the wire */
		runkprocs();
		return 1;			/* the kernel is answered by ReqMigdone */
	}
	if(req.container != cid){
		/* another container this server answers for: a program exec started */
		cdata = sliceof((int)req.arg[2], req.container);
		if(cdata == nil){
			unmapped++;
			unmappedop = req.op;
			unmappedfrom = req.container;
			unmappedslot = req.arg[2];
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
		 * The device-carried wire, the direction the request ring
		 * runs: a frame the peer container's stack sent, in one of the
		 * peer's own packet buffers, handed to the stack at this end.
		 * This end's frames to the peer do not ride the reply: they go
		 * into the peer's packet buffers and onto its output queue, in
		 * memory (ringsrv_output), and the kernel is asked to wake it.
		 */
		toff = req.arg[2];
		tlen = req.arg[3];
		roff = req.arg[4];
		rn = 0;
		if(roff == Inpktbuf && clientbase != nil && toff < clientmap->npktbuf && tlen > 0 && tlen <= clientmap->pktbufsize)
			rn = ospreymediumreceive(clientbase + clientmap->pktbuf + toff*clientmap->pktbufsize, (long)tlen, req.container);
		rep.arg[0] = (uvlong)rn;
	} else if(req.op == Reqsyscall){
		rn = p9buddy_serve(cdata, req.container);	/* a forwarded legacy system call, or exec/page */
		rep.arg[0] = (uvlong)rn;
	} else
		rep.arg[0] = 2;
	repm[pq->put % pq->size] = rep;
	pq->put++;
	return 1;
}

/*
 * A frame from this end's stack to the client container: into one of the
 * client's own packet buffers, and a message naming it onto the client's
 * output queue, both in the client's slice which this server maps - no
 * kernel in the data path - then one request (ReqKick) so the kernel
 * wakes the client's select, which takes the message on an arm of its
 * own.  Returns -1 when the queue is full (sixteen frames not yet taken,
 * one per buffer), and the medium keeps the frame until the next tick.
 */
long
ringsrv_output(uchar *frame, long n)
{
	Queue *oq;
	Msg *om, m;
	uchar *b;
	long k;
	int slot;
	uvlong args[5];

	if(clientbase == nil || n <= 0 || n > (long)clientmap->pktbufsize || clientmap->npktbuf < Rxslot0 + Nrxslot)
		return -1;
	oq = (Queue*)(clientbase + clientmap->outputqueue);
	if(oq->put - oq->get >= oq->size)
		return -1;			/* the client has not taken what is there */
	slot = Rxslot0 + rxnext++ % Nrxslot;
	b = clientbase + clientmap->pktbuf + slot*clientmap->pktbufsize;
	for(k = 0; k < n; k++)
		b[k] = frame[k];
	om = (Msg*)((uchar*)oq + oq->message);
	for(k = 0; k < (long)sizeof m; k++)
		((uchar*)&m)[k] = 0;
	m.op = Reqframe;
	m.container = clientmap->id;
	m.arg[0] = slot;
	m.arg[1] = n;
	om[oq->put % oq->size] = m;
	oq->put++;
	framesout++;
	args[0] = clientmap->id;
	args[1] = args[2] = args[3] = args[4] = 0;
	if(ospreyxcall(33, args, 1) == 0)	/* ReqKick */
		kicks++;
	return 0;
}

/* this server's own data area, for the kernel-header side (the migration kprocs stage pages in it) */
uchar*
p9srvdata(void)
{
	Omap *m;

	if(srvbase == nil)
		return nil;
	m = (Omap*)srvbase;
	return srvbase + m->data;
}

/* a packet buffer slot of this server's own slice, len bytes from its start: a page is staged whole across two adjacent slots */
uchar*
p9srvpktbuf(int slot, long len)
{
	Omap *m;

	if(srvbase == nil || slot < 0)
		return nil;
	m = (Omap*)srvbase;
	if(m->pktbufsize == 0 || (uvlong)slot*m->pktbufsize + len > m->npktbuf*m->pktbufsize)
		return nil;
	return srvbase + m->pktbuf + (uvlong)slot*m->pktbufsize;
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
	srvbase = base;
	clientbase = cbase;
	clientmap = cmap;

	p9blk(base);		/* the disk, if the kernel exposed one: a driver above the kernel */
	p9lfsmount();		/* and the file system on it, mounted at /n for the client */
	p9vnet(base);		/* the network device, if the kernel exposed one: the same */
	p9vnetup();		/* and the real stack's interface on it */
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
	/*
	 * Serve until the machine stops: the kernel ends the boot when the
	 * boot program exits, and a server that stopped after a fixed number
	 * of requests (as this once did, at four hundred, a headless-run
	 * guard) left the client's own stack with nobody to answer its ring
	 * once the rest of the run had spent them.  Every thousandth served
	 * request says the server is still here.
	 */
	for(iters = 0;; ){
		int r = serve1(pq, (Msg*)((uchar*)pq + pq->message),
			(Msg*)(base + map->data + Reqbuf),
			(Arm*)(base + map->data + Armoff),
			cbase + cmap->data, cmap->id);
		if(r != 0 && r != 2 && ++iters % 1000 == 0){
			char line[200], *s, *e;
			int k;

			s = line;
			e = line + sizeof line;
			s = seprint(s, e, "p9 server: %d requests served; %d ticks, reclamation ran %d times on them; by op:", iters, ticks, reclaims);
			for(k = 0; k < 32; k++)
				if(opcount[k] > 0)
					s = seprint(s, e, " %d=%d", k, opcount[k]);
			seprint(s, e, "; unmapped %d, last op %llud from container %llud slot %llud\n", unmapped, unmappedop, unmappedfrom, unmappedslot);
			puts(line);
		}
	}
}
