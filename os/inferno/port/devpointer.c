/*
 * mouse or stylus
 */

#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

#include <draw.h>
#include <memdraw.h>
#include <cursor.h>
#include "screen.h"

enum{
	Qdir,
	Qpointer,
	Qcursor,
};

typedef struct Pointer Pointer;

struct Pointer {
	int	x;
	int	y;
	int	b;
	ulong	msec;
};

static struct
{
	Pointer;
	int	modify;
	int	lastb;
	Rendez	r;
	Ref	ref;
	QLock	q;
} mouse;

static
Dirtab pointertab[]={
	".",			{Qdir, 0, QTDIR},	0,	0555,
	"pointer",		{Qpointer},	0,	0666,
	"cursor",		{Qcursor},		0,	0222,
};

enum {
	Nevent = 16	/* enough for some */
};

static struct {
	int	rd;
	int	wr;
	Pointer	clicks[Nevent];
	Rendez r;
	int	full;
	int	put;
	int	get;
} ptrq;

/*
 * How far a pointer event got, and both halves are needed.  Not static:
 * tools/jtag/splittrace resolves them in the symbol table, and they
 * persist until the board is rebooted -- which is the point, because an
 * instrument that has to be running at the moment of the event is one
 * that can miss it.
 */
uint	pointerevents;		/* written to the queue by a producer */
uint	pointerreads;		/* taken off it by a reader */

/*
 * called by any source of pointer data
 */
void
mousetrack(int b, int x, int y, int isdelta)
{
	int lastb;
	ulong msec;
	Pointer e;

	if(isdelta){
		x += mouse.x;
		y += mouse.y;
	}
	msec = TK2MS(MACHP(0)->ticks);
	if(b && (mouse.b ^ b)&0x1f){
		if(msec - mouse.msec < 300 && mouse.lastb == b
		   && abs(mouse.x - x) < 12 && abs(mouse.y - y) < 12)
			b |= 1<<8;
		mouse.lastb = b & 0x1f;
		mouse.msec = msec;
	}
	if(x == mouse.x && y == mouse.y && mouse.b == b)
		return;
	/*
	 * EVENTS THAT REACHED THIS QUEUE, counted so that the question
	 * "did a pointer event get this far" can be answered WITHOUT
	 * anything reading the queue at the same moment.
	 *
	 * Why it exists: on the Pi 3B the whole chain from a moved mouse
	 * to a moving pointer had to be measured, and the only
	 * instruments were a kernel counter at the USB controller and a
	 * bounded reader of this file -- so the reader had to be running
	 * during the movement, and three capture windows in a row missed
	 * it.  A counter does not have to be there when it happens.
	 *
	 * pointerevents is "usbd decoded a report and wrote it here";
	 * pointerreads below is "something took it off the queue".  The
	 * pair separates a device that said nothing from a consumer that
	 * was not listening, which no single number can.
	 */
	pointerevents++;
	lastb = mouse.b;
	mouse.x = x;
	mouse.y = y;
	mouse.b = b;
	mouse.msec = msec;
	if(!ptrq.full && lastb != b){
		e = mouse.Pointer;
		ptrq.clicks[ptrq.wr] = e;
		if(++ptrq.wr >= Nevent)
			ptrq.wr = 0;
		if(ptrq.wr == ptrq.rd)
			ptrq.full = 1;
	}
	mouse.modify = 1;
	ptrq.put++;
	wakeup(&ptrq.r);
	/*
	 * Soft cursor uses canqlock(drawlock); never block here.
	 * drawactive omitted (emu does too).
	 */
	/* drawactive(1); */
	cursoron();
}

static int
ptrqnotempty(void*)
{
	return ptrq.full || ptrq.put != ptrq.get;
}

static Pointer
mouseconsume(void)
{
	Pointer e;

	sleep(&ptrq.r, ptrqnotempty, 0);
	ptrq.full = 0;
	ptrq.get = ptrq.put;
	if(ptrq.rd != ptrq.wr){
		e = ptrq.clicks[ptrq.rd];
		if(++ptrq.rd >= Nevent)
			ptrq.rd = 0;
	}else
		e = mouse.Pointer;
	return e;
}

Point
mousexy(void)
{
	return Pt(mouse.x, mouse.y);
}


static Chan*
pointerattach(char* spec)
{
	return devattach('m', spec);
}

static Walkqid*
pointerwalk(Chan *c, Chan *nc, char **name, s32 nname)
{
	Walkqid *wq;

	wq = devwalk(c, nc, name, nname, pointertab, nelem(pointertab), devgen);
	/*
	 * NO incref HERE, and the comment that used to sit on it asked
	 * "can this happen?" -- which nobody had answered.
	 *
	 * It can, and when it did the reference leaked, because nothing
	 * could ever balance it: devclone() PANICS on a chan with COPEN
	 * set, so a clone is always of an unopened chan, and
	 * pointerclose() returns early on exactly that -- `if((c->flag &
	 * COPEN) == 0) return'.  So the increment had no matching
	 * decrement by construction.
	 *
	 * And it is not needed.  The single-reader reference belongs to
	 * the OPEN, which is where it is taken and where it is put back.
	 * A walk resolves a name; it grants nothing to release.
	 */
	USED(c);
	return wq;
}

static s32
pointerstat(Chan* c, uchar *db, s32 n)
{
	return devstat(c, db, n, pointertab, nelem(pointertab), devgen);
}

static Chan*
pointeropen(Chan* c, u32 omode)
{
	c = devopen(c, omode, pointertab, nelem(pointertab), devgen);
	/*
	 * One reader at a time; a write-only open only injects events
	 * (usbd's mouse driver does this) and may coexist with it.
	 */
	if((u64)c->qid.path == Qpointer && c->mode != OWRITE){
		if(waserror()){
			c->flag &= ~COPEN;
			nexterror();
		}
		if(!canqlock(&mouse.q))
			error(Einuse);
		if(incref(&mouse.ref) != 1){
			/*
			 * PUT IT BACK.  This path used to increment and then
			 * error without decrementing, so EVERY REFUSED OPEN
			 * RAISED THE COUNT PERMANENTLY and the single reader
			 * slot was poisoned for the life of the boot -- with
			 * each further attempt making it worse, because each
			 * one incremented again on its way to the
			 * same refusal.
			 *
			 * Found on a Pi 3B: /dev/pointer answered `device or
			 * object already in use' with NO process holding it
			 * for reading.  Every fd on it in /prog/<pid>/fd was
			 * `w' -- usbd's injecting writer, which never counted
			 * -- and ps showed nothing that could be the reader.
			 * The reference had outlived every process that could
			 * own it, which is only possible if it was never
			 * owned.
			 *
			 * The trigger was two readers colliding once.  After
			 * that a mouse could enumerate, deliver reports and
			 * have them decoded, and no consumer -- wm included --
			 * could ever open the queue again.
			 */
			decref(&mouse.ref);
			qunlock(&mouse.q);
			error(Einuse);
		}
		cursorenable();
		qunlock(&mouse.q);
		poperror();
	}
	return c;
}

static void
pointerclose(Chan* c)
{
	if((c->flag & COPEN) == 0)
		return;
	switch((ulong)c->qid.path){
	case Qpointer:
		if(c->mode == OWRITE)
			break;	/* an injecting writer never counted */
		qlock(&mouse.q);
		if(decref(&mouse.ref) == 0){
			cursordisable();
		}
		qunlock(&mouse.q);
		break;
	}
}

static s32
pointerread(Chan* c, void* a, s32 n, s64)
{
	Pointer mt;
	char tmp[128];
	int l;

	switch((ulong)c->qid.path){
	case Qdir:
		return devdirread(c, a, n, pointertab, nelem(pointertab), devgen);
	case Qpointer:
		qlock(&mouse.q);
		if(waserror()) {
			qunlock(&mouse.q);
			nexterror();
		}
		mt = mouseconsume();
	pointerreads++;
		poperror();
		qunlock(&mouse.q);
		/*
		 * KenC LP64: one homogeneous arg per sprint/snprint;
		 * multi-int varargs mis-read 2nd+ values as pointers.
		 */
		{
			char *cp;

			cp = tmp;
			*cp++ = 'm';
			cp += sprint(cp, "%11d ", mt.x);
			cp += sprint(cp, "%11d ", mt.y);
			cp += sprint(cp, "%11d ", mt.b);
			cp += sprint(cp, "%11lud ", mt.msec);
			l = cp - tmp;
		}
		if(l < n)
			n = l;
		memmove(a, tmp, n);
		break;
	case Qcursor:
		/* TO DO: interpret data written as Image; give to drawcursor() */
		break;
	default:
		n=0;
		break;
	}
	return n;
}

static s32
pointerwrite(Chan* c, void* va, s32 n, s64)
{
	char *a = va;
	char buf[128];
	int b, x, y;
	Drawcursor cur;

	switch((u32)c->qid.path){
	case Qpointer:
		if(n > sizeof buf-1)
			n = sizeof buf -1;
		memmove(buf, va, n);
		buf[n] = 0;
		x = strtoul(buf+1, &a, 0);
		if(*a == 0)
			error(Eshort);
		y = strtoul(a, &a, 0);
		if(*a != 0)
			b = strtoul(a, 0, 0);
		else
			b = mouse.b;
		mousetrack(b, x, y, 0);
		break;
	case Qcursor:
		/*
		 * hotx[4] hoty[4] dx[4] dy[4] clr[dx/8 * dy/2] set[dx/8 * dy/2]
		 * dx multiple of 8; dy multiple of 2.
		 * The four counts are LITTLE-endian: BG32INT composes two
		 * little-endian halves in little-endian order (draw.h).
		 */
		if(n == 0){
			cur.data = nil;
			drawcursor(&cur);
			break;
		}
		if(n < 8)
			error(Eshort);
		cur.hotx = BG32INT((uchar*)va+0*4);
		cur.hoty = BG32INT((uchar*)va+1*4);
		cur.minx = 0;
		cur.miny = 0;
		cur.maxx = BG32INT((uchar*)va+2*4);
		cur.maxy = BG32INT((uchar*)va+3*4);
		if(cur.maxx%8 != 0 || cur.maxy%2 != 0 || n-4*4 != (cur.maxx/8 * cur.maxy))
			error(Ebadarg);
		cur.data = (uchar*)va + 4*4;
		drawcursor(&cur);
		break;
	default:
		error(Ebadusefd);
	}
	return n;
}

Dev pointerdevtab = {
	'm',
	"pointer",

	devreset,
	devinit,
	devshutdown,
	pointerattach,
	pointerwalk,
	pointerstat,
	pointeropen,
	devcreate,
	pointerclose,
	pointerread,
	devbread,
	pointerwrite,
	devbwrite,
	devremove,
	devwstat,
};
