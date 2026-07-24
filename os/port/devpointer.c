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
	if(wq != nil && wq->clone != c && wq->clone != nil && (u64)c->qid.path == Qpointer)
		incref(&mouse.ref);	/* can this happen? */
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
	if((u64)c->qid.path == Qpointer){
		if(waserror()){
			c->flag &= ~COPEN;
			nexterror();
		}
		if(!canqlock(&mouse.q))
			error(Einuse);
		if(incref(&mouse.ref) != 1){
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
	switch((u64)c->qid.path){
	case Qpointer:
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

	switch((u64)c->qid.path){
	case Qdir:
		return devdirread(c, a, n, pointertab, nelem(pointertab), devgen);
	case Qpointer:
		qlock(&mouse.q);
		if(waserror()) {
			qunlock(&mouse.q);
			nexterror();
		}
		mt = mouseconsume();
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
