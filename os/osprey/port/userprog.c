/*
 * userprog - a library-OS program for the Osprey microkernel.
 *
 * It runs on top of the microkernel and reaches the kernel only through
 * the minimal system-call interface - write, exit, segattach, and a
 * yield-and-service call.  Its file operations are not the kernel's:
 * they are a personality it links as a library.  Here the personality
 * does not hold the files at all - it opens and reads them over the
 * message ring from a file server, another task on the same microkernel.
 * persopen and persread below are that library: they speak the open and
 * read protocol over the ring, and the kernel only carries the messages.
 * This is a library operating system in the paper's shape: the OS
 * personality implemented as a library, run on top of the microkernel,
 * reaching a server by message passing.
 *
 * As with initcode there is no separate loader: the whole image is
 * carried into the program's text, so its strings live in that text and
 * it keeps no data segment.
 */
#include <u.h>
#include <libc.h>

enum {
	Ospreymagic	= 0x4f53505259ULL,
	ReqRead		= 0,
	ReqOpen		= 2,
	ReplyDone	= 1,
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

/* the ring this program's container was given, laid over its slice; kept
 * on the stack, not in statics, because the program has no data segment */
typedef struct Ring Ring;
struct Ring {
	uchar	*base;
	Omap	*map;
	Queue	*rq, *pq;
	Msg	*reqm, *repm;
};

static void
puts(char *s)
{
	write(2, s, strlen(s));
}

/*
 * One request over the ring: put the message in the ring in our own
 * memory, trap once to have the kernel service it (which forwards it to
 * our server), and read the reply back.  Returns the reply's status
 * word, or -1 if none came; fills *rep with the whole reply.
 */
static long
ringcall(Ring *r, uvlong op, uvlong a0, uvlong a1, uvlong a2, Msg *rep)
{
	Msg m;
	uvlong seq;
	int tries;

	memset(&m, 0, sizeof m);
	m.op = op;
	m.container = r->map->id;
	m.arg[2] = a0;
	m.arg[3] = a1;
	m.arg[4] = a2;
	seq = r->rq->put + 1;
	m.sequence = seq;
	r->reqm[r->rq->put % r->rq->size] = m;
	r->rq->put++;				/* submit: memory, no trap */

	for(tries = 0; tries < 400 && r->pq->put == r->pq->get; tries++)
		sleep(1);			/* service and yield until the reply lands */

	if(r->pq->put == r->pq->get)
		return -1;
	*rep = r->repm[r->pq->get % r->pq->size];
	r->pq->get++;				/* collect: memory, no trap */
	if(rep->sequence != seq)
		return -1;
	return (long)rep->arg[0];		/* the status word */
}

/* the personality's open: resolve a name at the server, return a handle */
static int
persopen(Ring *r, char *name)
{
	Msg rep;
	uchar *data;
	long n, status;

	data = r->base + r->map->data;		/* our data area */
	for(n = 0; name[n] != 0; n++)		/* put the name where the server reads it */
		data[n] = name[n];
	status = ringcall(r, ReqOpen, 0, n, 0, &rep);
	if(status != ReplyDone)
		return -1;
	return (int)rep.arg[2];			/* the handle the server returned */
}

/* the personality's read: the server copies the file into our data area */
static long
persread(Ring *r, int fd, char *buf, long max)
{
	Msg rep;
	uchar *data;
	long n, k;
	uvlong dest;

	dest = 128;				/* where in our data area the bytes land */
	n = ringcall(r, ReqRead, (uvlong)fd, dest, (uvlong)max, &rep);
	if(n <= 0)
		return n;
	if(n > max)
		n = max;
	data = r->base + r->map->data;
	for(k = 0; k < n; k++)
		buf[k] = data[dest + k];
	return n;
}

static void
fbrect(ulong *fb, int stride, int x0, int y0, int w, int h, ulong colour)
{
	int x, y;

	for(y = y0; y < y0+h; y++)
		for(x = x0; x < x0+w; x++)
			fb[y*stride + x] = colour;
}

/* a window: black border, blue title bar, white body - what rio draws */
static void
fbwindow(ulong *fb, int stride, int x, int y, int w, int h)
{
	fbrect(fb, stride, x, y, w, h, 0x00000000);		/* border */
	fbrect(fb, stride, x+2, y+2, w-4, 20, 0x00224488);	/* title bar */
	fbrect(fb, stride, x+2, y+22, w-4, h-24, 0x00ffffff);	/* body */
}

void
startboot(char*, char**)
{
	char buf[256];
	int fd;
	long n;
	Ring r;

	puts("osprey user: a program on the microkernel, whose file personality is a library\n");

	r.base = (uchar*)segattach(0, "osprey0", 0, 0);
	if(r.base == (uchar*)-1){
		puts("osprey user: could not map the message ring\n");
		exits(nil);
	}
	r.map = (Omap*)r.base;
	if(r.map->magic != Ospreymagic){
		puts("osprey user: what segattach mapped is not a container ring\n");
		exits(nil);
	}
	puts("osprey user: mapped its container's message ring with segattach\n");
	r.rq = (Queue*)(r.base + r.map->requestqueue);
	r.pq = (Queue*)(r.base + r.map->replyqueue);
	r.reqm = (Msg*)((uchar*)r.rq + r.rq->message);
	r.repm = (Msg*)((uchar*)r.pq + r.pq->message);

	/*
	 * The whole point: the personality library opens a name and reads
	 * the file, both over the ring to the server, both in user space,
	 * the kernel only carrying the messages.
	 */
	fd = persopen(&r, "motd");
	if(fd < 0){
		puts("osprey user: the server did not open the file\n");
		exits(nil);
	}
	puts("osprey user: the personality library opened a file at the server over the ring\n");
	n = persread(&r, fd, buf, sizeof buf - 1);
	if(n <= 0){
		puts("osprey user: the server returned no bytes\n");
		exits(nil);
	}
	puts("osprey user: and read it over the ring from the server, not the kernel:\n");
	write(2, buf, n);

	/*
	 * A user-level graphics driver: map the frame buffer the microkernel
	 * exposed as a physical segment and draw to it.  The kernel
	 * multiplexes the display and knows nothing of what is drawn; this
	 * program, in user space, owns the pixels.  A real driver would read
	 * the geometry from the microkernel; this uses the mode the firmware
	 * set (1280x800, 32-bit) and draws colour bars to show it drew.
	 */
	{
		enum { Fbw = 1280, Fbh = 800 };
		ulong *fb;

		fb = (ulong*)segattach(0, "framebuffer", 0, Fbw*Fbh*4);
		if(fb == (ulong*)-1)
			puts("osprey user: could not map the frame buffer\n");
		else {
			int y, x;

			/* the desktop */
			for(y = 0; y < Fbh; y++)
				for(x = 0; x < Fbw; x++)
					fb[y*Fbw + x] = 0x00777777;
			/* two windows, each a border, a title bar and a body */
			fbwindow(fb, Fbw, 150, 120, 520, 360);
			fbwindow(fb, Fbw, 560, 320, 560, 400);
			/* a mouse arrow */
			for(y = 0; y < 16; y++)
				for(x = 0; x <= y && x < 10; x++)
					fb[(400+y)*Fbw + (640+x)] = 0;
			puts("osprey user: and drew a windowed desktop to the frame buffer the microkernel exposed\n");
		}
	}
	exits(nil);
}
