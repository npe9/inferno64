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
typedef struct Arm Arm;
struct Arm { uvlong op, obj, buf; };	/* a select arm: op, ring/sem, message offset */
enum { OSget = 2, OSdown = 4 };		/* the talk's MSget / MSdown */

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
 * select over arms.  The kernel maps the DUP syscall number to select
 * for this minimal interface, so dup carries the two words: the arms'
 * offset in our data area and how many.  Returns which arm was ready.
 */
static int
oselect(int armoff, int narms)
{
	return dup(narms, armoff);
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

enum { Cw = 12, Ch = 18 };	/* the cursor sprite */

/* save the pixels a cursor is about to cover, so it can be lifted cleanly */
static void
savebox(ulong *fb, int stride, int x, int y, ulong *buf)
{
	int i, j;

	for(j = 0; j < Ch; j++)
		for(i = 0; i < Cw; i++)
			buf[j*Cw + i] = fb[(y+j)*stride + (x+i)];
}

static void
restorebox(ulong *fb, int stride, int x, int y, ulong *buf)
{
	int i, j;

	for(j = 0; j < Ch; j++)
		for(i = 0; i < Cw; i++)
			fb[(y+j)*stride + (x+i)] = buf[j*Cw + i];
}

/* a black arrow with a white edge, so it shows on any background */
static void
drawcursor(ulong *fb, int stride, int x, int y)
{
	int i, j;

	for(j = 0; j < 16; j++)
		for(i = 0; i <= j && i < 8; i++){
			fb[(y+j)*stride + (x+i)] = 0;			/* body */
			if(i == 0 || i == j || i == 7)
				fb[(y+j)*stride + (x+i)] = 0x00ffffff;	/* edge */
		}
}

/* a small unsigned decimal, for the console report */
static void
putint(int v)
{
	char m[12];
	int k = 0, j;

	if(v == 0)
		m[k++] = '0';
	for(j = k; v > 0; v /= 10)
		m[k++] = '0' + v%10;
	/* reverse the digits we pushed */
	for(j = 0; j < (k - 0)/2; j++){
		char t = m[j]; m[j] = m[k-1-j]; m[k-1-j] = t;
	}
	write(2, m, k);
}

/* build "osprey<n>", a container's slice name, into buf */
static void
slicename(char *buf, int n)
{
	int i, d, started, div;

	i = 0;
	buf[i++]='o'; buf[i++]='s'; buf[i++]='p'; buf[i++]='r'; buf[i++]='e'; buf[i++]='y';
	if(n == 0)
		buf[i++]='0';
	else {
		started = 0;
		for(div = 1000000000; div > 0; div /= 10){
			d = (n/div)%10;
			if(d != 0 || started){
				buf[i++]='0'+d;
				started = 1;
			}
		}
	}
	buf[i] = 0;
}

/* parse "s <a> <b>" into a and b */
static void
parse2(char *s, int *a, int *b)
{
	while(*s != 0 && (*s < '0' || *s > '9')) s++;
	for(*a = 0; *s >= '0' && *s <= '9'; s++) *a = *a*10 + (*s - '0');
	while(*s != 0 && (*s < '0' || *s > '9')) s++;
	for(*b = 0; *s >= '0' && *s <= '9'; s++) *b = *b*10 + (*s - '0');
}

static int
streq(char *a, char *b)
{
	while(*a != 0 && *a == *b){ a++; b++; }
	return *a == 0 && *b == 0;
}

/*
 * The file server, as its own user program rather than a kernel task.
 * It maps two slices with the address-space service: its own ring, where
 * the microkernel routes the client's forwarded requests, and the
 * client's slice, which delegation entitles it to reach so it can read
 * the name to open and write the bytes to read.  It works both rings in
 * user memory - no trap to read a request or write a reply - and sleeps
 * only to have the kernel route what it has answered back to the client.
 * Two user tasks then exchange the open and read messages, the kernel
 * carrying them and nothing more.
 */
static void
ospreyserver(char *arg0)
{
	int ownslot, clientslot, iters;
	char oname[16], cname[16], nbuf[64];
	uchar *base, *cbase, *cdata;
	Omap *map, *cmap;
	Queue *rq, *pq;
	Msg *reqm, *repm;

	parse2(arg0, &ownslot, &clientslot);
	slicename(oname, ownslot);
	slicename(cname, clientslot);

	base = (uchar*)segattach(0, oname, 0, 0);
	if(base == (uchar*)-1){
		puts("osprey server: could not map its own ring\n");
		return;
	}
	map = (Omap*)base;
	if(map->magic != Ospreymagic){
		puts("osprey server: its own slice carries no ring map\n");
		return;
	}
	rq = (Queue*)(base + map->requestqueue);
	pq = (Queue*)(base + map->replyqueue);
	reqm = (Msg*)((uchar*)rq + rq->message);
	repm = (Msg*)((uchar*)pq + pq->message);

	cbase = (uchar*)segattach(0, cname, 0, 0);
	if(cbase == (uchar*)-1){
		puts("osprey server: could not map the client's slice\n");
		return;
	}
	cmap = (Omap*)cbase;
	cdata = cbase + cmap->data;

	puts("osprey server: a user-mode file server; its own ring and its client's slice are mapped\n");
	puts("osprey server: waiting for requests with select over its ring's arm\n");

	{
		enum { Armoff = 0, Reqbuf = 256 };	/* arm at data[0]; a request lands at data[256] */
		Arm *arm = (Arm*)(base + map->data + Armoff);
		Msg *reqp = (Msg*)(base + map->data + Reqbuf);

		USED(rq); USED(reqm);
		for(iters = 0; iters < 150; iters++){	/* up to ~30s of waiting, then finish */
			Msg req, rep;
			uvlong off, len, fd, dest, most;
			char *content;
			long i, nb;
			int fi, a;

			/* wait for a request with select: a get on the request ring */
			arm->op = OSget;
			arm->obj = 0;			/* the request ring */
			arm->buf = Reqbuf;		/* where the message is taken to */
			a = oselect(Armoff, 1);
			if(a != 0)			/* nothing ready this time; look again */
				continue;
			req = *reqp;			/* the request select took into our data area */

			for(i = 0; i < (long)sizeof rep; i++)
				((uchar*)&rep)[i] = 0;
			rep.container = req.container;	/* whose it is - how the kernel routes it home */
			rep.sequence = req.sequence;

			if(req.op == ReqOpen){
				off = req.arg[2];
				len = req.arg[3];
				if(len > sizeof nbuf - 1)
					len = sizeof nbuf - 1;
				for(i = 0; i < (long)len; i++)
					nbuf[i] = (char)cdata[off + i];
				nbuf[len] = 0;
				fi = -1;
				if(streq(nbuf, "greeting"))
					fi = 0;
				else if(streq(nbuf, "motd"))
					fi = 1;
				rep.arg[2] = (uvlong)fi;		/* the handle */
				rep.arg[0] = fi >= 0 ? ReplyDone : 2;	/* status */
			} else if(req.op == ReqRead){
				fd = req.arg[2];
				dest = req.arg[3];
				most = req.arg[4];
				content = nil;
				if(fd == 0)
					content = "hello from the file server, reached over the ring, not held in the client\n";
				else if(fd == 1)
					content = "the osprey microkernel serves this file from a task by message passing; the personality that opened it is a library, above the kernel, not in it\n";
				nb = 0;
				if(content != nil){
					while(content[nb] != 0)
						nb++;
					if(nb > (long)most)
						nb = most;
					for(i = 0; i < nb; i++)
						cdata[dest + i] = (uchar)content[i];
				}
				rep.arg[0] = (uvlong)nb;		/* byte count */
			} else
				rep.arg[0] = 2;				/* an op we do not answer */

			repm[pq->put % pq->size] = rep;
			pq->put++;
			/* the reply is routed home by select's own service on the next wait */
		}
	}
	puts("osprey server: done\n");
}

void
startboot(char *arg0, char**)
{
	char buf[256];
	int fd;
	long n;
	Ring r;

	if(arg0 != nil && arg0[0] == 's'){	/* the server role */
		ospreyserver(arg0);
		exits(nil);
	}

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
			puts("osprey user: and drew a windowed desktop to the frame buffer the microkernel exposed\n");

			/*
			 * User-level keyboard and mouse drivers, the exokernel way.
			 * The microkernel exposes two interrupts, each filling a ring
			 * in this program's own data area and raising a semaphore;
			 * these drivers, above the kernel, read the rings.  The
			 * keyboard draws a square per key; the mouse assembles the
			 * three-byte PS/2 packets, moves a cursor sprite over the
			 * desktop and marks a left click.  The kernel knows nothing of
			 * squares, cursors or clicks.
			 */
			{
				enum { Kbdoff = 1024, Kbdn = 256, Mouseoff = 2048, Mousen = 256 };
				uchar *kring = r.base + r.map->data + Kbdoff;
				uvlong *kwp = (uvlong*)kring;
				uchar *kbytes = kring + 8;
				uchar *mring = r.base + r.map->data + Mouseoff;
				uvlong *mwp = (uvlong*)mring;
				uchar *mbytes = mring + 8;
				uvlong krp, mrp;
				ulong save[Cw*Ch];
				int i, keys, clicks, moved, cx, cy, pkt[3], pi;

				puts("osprey user: keyboard and mouse drivers reading exposed rings\n");
				krp = *kwp;		/* ignore anything before we start */
				mrp = *mwp;
				keys = 0; clicks = 0; moved = 0; pi = 0;
				cx = 640; cy = 400;
				savebox(fb, Fbw, cx, cy, save);
				drawcursor(fb, Fbw, cx, cy);
				for(i = 0; i < 6000 && keys < 40 && clicks < 20; i++){
					/* keyboard: a square per key press, marching across */
					while(krp != *kwp && keys < 40){
						uchar sc = kbytes[krp % Kbdn];
						int y0, x0, yy, xx;
						ulong col;

						krp++;
						if(sc & 0x80)	/* key release */
							continue;
						y0 = 40 + (keys/16)*40; x0 = 40 + (keys%16)*40;
						col = 0x00ff00 + (sc<<8);
						for(yy = 0; yy < 32; yy++)
							for(xx = 0; xx < 32; xx++)
								fb[(y0+yy)*Fbw + (x0+xx)] = col;
						puts("kb="); putint(sc); puts("\n");
						keys++;
					}
					/* mouse: assemble packets, move the cursor, read buttons */
					while(mrp != *mwp){
						uchar b = mbytes[mrp % Mousen];
						int dx, dy, ncx, ncy;

						mrp++;
						if(pi == 0 && !(b & 0x08))	/* resync: byte 0 has bit 3 set */
							continue;
						pkt[pi++] = b;
						if(pi < 3)
							continue;
						pi = 0;
						dx = pkt[1]; dy = pkt[2];
						if(pkt[0] & 0x10) dx -= 256;	/* X sign */
						if(pkt[0] & 0x20) dy -= 256;	/* Y sign */
						ncx = cx + dx;
						ncy = cy - dy;			/* screen Y grows downward */
						if(ncx < 0) ncx = 0;
						if(ncx > Fbw-Cw) ncx = Fbw-Cw;
						if(ncy < 0) ncy = 0;
						if(ncy > Fbh-Ch) ncy = Fbh-Ch;
						if(ncx != cx || ncy != cy){
							restorebox(fb, Fbw, cx, cy, save);
							cx = ncx; cy = ncy;
							savebox(fb, Fbw, cx, cy, save);
							drawcursor(fb, Fbw, cx, cy);
							moved++;
						}
						if(pkt[0] & 0x01){	/* left click: a red mark beside the cursor */
							int mx = cx + Cw, my = cy, yy, xx;
							if(mx > Fbw-6) mx = Fbw-6;
							for(yy = 0; yy < 6; yy++)
								for(xx = 0; xx < 6; xx++)
									fb[(my+yy)*Fbw + (mx+xx)] = 0x00ff0000;
							puts("click@"); putint(cx); puts(","); putint(cy); puts("\n");
							clicks++;
						}
					}
					sleep(5);
				}
				puts("osprey user: mouse moved "); putint(moved);
				puts(" steps; drivers done\n");
			}
		}
	}
	exits(nil);
}
