/*
 * The buddy server's ring loop, compiled against the user headers.  It
 * maps this container's ring and its client's slice with segattach, waits
 * on its request ring with select the way a driver task does, and answers
 * each 9P request by handing the marshalled message to p9srv_serve - the
 * exportfs over this personality's own name space - and routing the reply
 * home.  Two library operating systems then name each other's files over
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
	Req9P		= 4,
	OSget		= 2,
	Armoff		= 0,
	Reqbuf		= 256,
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
static void
serve1(Queue *pq, Msg *repm, Msg *reqp, Arm *arm, uchar *cdata)
{
	Msg req, rep;
	long i, rn;
	uvlong toff, tlen, roff;

	arm->op = OSget;
	arm->obj = 0;
	arm->buf = Reqbuf;
	if(oselect(Armoff, 1) != 0)
		return;
	req = *reqp;
	for(i = 0; i < (long)sizeof rep; i++)
		((uchar*)&rep)[i] = 0;
	rep.container = req.container;
	rep.sequence = req.sequence;
	if(req.op == Req9P){
		toff = req.arg[2];
		tlen = req.arg[3];
		roff = req.arg[4];
		rn = p9srv_serve(cdata + toff, (long)tlen, cdata + roff, 8192);
		rep.arg[0] = (uvlong)rn;
	} else
		rep.arg[0] = 2;
	repm[pq->put % pq->size] = rep;
	pq->put++;
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
	if(base == (uchar*)-1){ puts("p9 buddy: could not map its own ring\n"); return; }
	map = (Omap*)base;
	if(map->magic != Ospreymagic){ puts("p9 buddy: its slice carries no ring map\n"); return; }
	cbase = mapslice(client);
	if(cbase == (uchar*)-1){ puts("p9 buddy: could not map the client's slice\n"); return; }
	cmap = (Omap*)cbase;
	pq = (Queue*)(base + map->replyqueue);

	puts("p9 buddy: serving this name space over the ring\n");
	for(iters = 0; iters < 400; iters++)
		serve1(pq, (Msg*)((uchar*)pq + pq->message),
			(Msg*)(base + map->data + Reqbuf),
			(Arm*)(base + map->data + Armoff),
			cbase + cmap->data);
	puts("p9 buddy: done\n");
}
