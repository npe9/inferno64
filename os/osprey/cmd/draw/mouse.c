/*
 * mouse.c - a user-level mouse driver for the full personality.
 *
 * The microkernel exposes the PS/2 aux (mouse) byte stream as the
 * physical segment "mousering" (see ospreymouseexpose in devosprey.c):
 * an 8-byte write count followed by a ring of raw aux bytes the IRQ12
 * handler fills.  This program segattaches that page, decodes the 3-byte
 * PS/2 movement packets into an absolute cursor position and a button
 * mask, and serves /dev/mouse in the format libdraw expects.  It is the
 * seL4/Osprey shape: the driver is an ordinary program above the kernel,
 * reaching the hardware only through the exposed segment.
 */
#include <u.h>
#include <libc.h>
#include <fcall.h>
/* 9p.h needs Ref, which this environment's libc.h does not define */
typedef struct Ref Ref;
struct Ref {
	long	ref;
};
#include <9p.h>

enum {
	Mousen	= 256,		/* ring capacity, matches the kernel */
	Winw	= 1280,		/* the exposed frame buffer is 1280x800 */
	Winh	= 800,
	/*
	 * We are the one decoder of the ring, so we publish the position we
	 * compute into the same page (past the kernel's count-plus-bytes);
	 * the draw server's cursor reads it there and draws the arrow at
	 * exactly where /dev/mouse says the pointer is - one source, so the
	 * cursor and the click point cannot drift apart.
	 */
	Posoff	= 512,		/* int mx, my */
};

static uchar	*ring;		/* the exposed page: [8]=count, then bytes */
static uvlong	rp;		/* how many bytes we have consumed */
static int	mx = Winw/2, my = Winh/2, mb;
static int	first = 1;

/* pull the next raw aux byte, or -1 if none available yet */
static int
nextbyte(void)
{
	uvlong count;

	count = *(uvlong*)ring;
	if(rp >= count)
		return -1;
	/* if we have fallen more than a ring behind, skip to the newest */
	if(count - rp > Mousen)
		rp = count - Mousen;
	return ring[8 + (rp++ % Mousen)];
}

/*
 * Assemble one 3-byte PS/2 packet and fold it into the cursor state.
 * Returns 1 when a full packet updated the state, 0 when it is still
 * waiting for bytes.
 */
static int
step(void)
{
	static uchar pkt[3];
	static int pn;
	int b, dx, dy;

	for(;;){
		b = nextbyte();
		if(b < 0)
			return 0;
		if(pn == 0 && !(b & 0x08))	/* resync: byte 0 has bit 3 set */
			continue;
		pkt[pn++] = (uchar)b;
		if(pn < 3)
			continue;
		pn = 0;
		dx = pkt[1];
		if(pkt[0] & 0x10)
			dx -= 256;
		dy = pkt[2];
		if(pkt[0] & 0x20)
			dy -= 256;
		mx += dx;
		my -= dy;			/* screen y grows downward */
		if(mx < 0) mx = 0; else if(mx >= Winw) mx = Winw-1;
		if(my < 0) my = 0; else if(my >= Winh) my = Winh-1;
		mb = (pkt[0] & 1) ? 1 : 0;	/* left  -> 1 */
		if(pkt[0] & 2) mb |= 4;		/* right -> 4 */
		if(pkt[0] & 4) mb |= 2;		/* middle-> 2 */
		return 1;
	}
}

static void
fsread(Req *r)
{
	char buf[64];
	int n;

	if(r->fid->file == nil || strcmp(r->fid->file->name, "mouse") != 0){
		respond(r, "not the mouse file");
		return;
	}
	/* the first read reports the initial position without waiting */
	if(!first){
		while(step() == 0)
			sleep(5);
	}
	first = 0;
	((int*)(ring + Posoff))[0] = mx;	/* publish for the cursor */
	((int*)(ring + Posoff))[1] = my;
	n = snprint(buf, sizeof buf, "m%11d %11d %11d %11d ",
		mx, my, mb, (int)(nsec()/1000000));
	/* a mouse is a stream: return the whole record, ignore the offset */
	if(n > r->ifcall.count)
		n = r->ifcall.count;
	memmove(r->ofcall.data, buf, n);
	r->ofcall.count = n;
	respond(r, nil);
}

static Srv mousesrv = {
	.read = fsread,
};

void
usage(void)
{
	fprint(2, "usage: mouse [-m mtpt]\n");
	exits("usage");
}

void
main(int argc, char **argv)
{
	char *mtpt;
	void *v;

	mtpt = "/dev";
	ARGBEGIN{
	case 'm':
		mtpt = EARGF(usage());
	}ARGEND;
	USED(argc, argv);

	v = segattach(0, "mousering", 0, 4096);	/* whole page: we use Posoff */
	if(v == (void*)-1)
		sysfatal("segattach mousering: %r");
	ring = v;
	rp = *(uvlong*)ring;		/* start from the current tail */
	((int*)(ring + Posoff))[0] = mx;	/* seed the published position */
	((int*)(ring + Posoff))[1] = my;

	mousesrv.tree = alloctree("glenda", "glenda", DMDIR|0555, nil);
	if(mousesrv.tree == nil)
		sysfatal("alloctree: %r");
	if(createfile(mousesrv.tree->root, "mouse", "glenda", 0666, nil) == nil)
		sysfatal("createfile: %r");
	postmountsrv(&mousesrv, nil, mtpt, MBEFORE);
	exits(nil);
}
