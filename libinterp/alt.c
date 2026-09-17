#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "raise.h"

#define OP(fn)	void fn(void)
#define W(p)	*((WORD*)(p))

#define CANGET(c)	((c)->size > 0)
#define CANPUT(c)	((c)->buf != H && (c)->size < (c)->buf->len)

/*
 * altcomm() is inside the channel region already, so it calls the
 * region-internal halves of send and receive, not the OP()s that open
 * one; see isendx()/irecvx() in xec.c.
 */
extern	void	isendx(Channel*);
extern	void	irecvx(Channel*);

/*
 * Count the number of ready channels in an array of channels
 * Set each channel's alt pointer to the owning prog
 */
static int
altmark(Channel *c, Prog *p)
{
	int nrdy;
	Array *a;
	Channel **ca, **ec;

	nrdy = 0;
	a = (Array*)c;
	ca = (Channel**)a->data;
	ec = ca + a->len;
	while(ca < ec) {
		c = *ca;
		if(c != H) {
			if(c->send->prog || CANGET(c))
				nrdy++;
			cqadd(&c->recv, p);
		}
		ca++;
	}

	return nrdy;
}

/*
 * Remove alt references to an array of channels
 */
static void
altunmark(Channel *c, WORD *ptr, Prog *p, int sr, Channel **sel, int dn)
{
	int n;
	Array *a;
	Channel **ca, **ec;

	n = 0;
	a = (Array*)c;
	ca = (Channel**)a->data;
	ec = ca + a->len;
	while(ca < ec) {
		c = *ca;
		if(c != H && c->recv->prog)
			cqdelp(&c->recv, p);
		if(sr == 1 && *sel == c) {
			W(p->reg.d) = dn;
			p->ptr = ptr + 1;
			ptr[0] = n;
			*sel = nil;
		}
		ca++;
		n++;
	}
}

/*
 * ALT Pass 1 - Count the number of ready channels and mark
 * each channel as ALT by this prog
 */
/*
 * How many queue cells altrdy() below can spend.  It must walk the same
 * channels in the same shape as altrdy() does -- an array channel on the
 * recv side expands to one cell per element, everything else is one cell
 * -- or cqadd() will panic on an empty pool.  The two are kept adjacent
 * for that reason.
 */
int
altcells(Alt *a)
{
	int n;
	Type *t;
	Channel *c;
	Altc *ac, *eac;

	n = 0;
	ac = a->ac + a->nsend;
	eac = ac + a->nrecv;
	while(ac < eac) {
		c = ac->c;
		ac++;
		if(c == H)
			continue;
		t = D2H(c)->t;
		if(t == &Tarray)
			n += ((Array*)c)->len;
		else
			n++;
	}

	ac = a->ac;
	eac = ac + a->nsend;
	while(ac < eac) {
		if(ac->c != H)
			n++;
		ac++;
	}

	return n;
}

/*
 * ALT Pass 1 - as below, except that the two errors it can find are
 * handed back through ep rather than raised here.  error() is a longjmp
 * and this runs with the channel region held; xecalt() raises it once
 * the region is closed.
 */
static int
altrdy(Alt *a, Prog *p, char **ep)
{
	char *e;
	Type *t;
	int nrdy;
	Channel *c;
	Altc *ac, *eac;

	e = nil;
	nrdy = 0;

	ac = a->ac + a->nsend;
	eac = ac + a->nrecv;
	while(ac < eac) {
		c = ac->c;
		ac++;
		if(c == H) {
			e = exNilref;
			continue;
		}
		t = D2H(c)->t;
		if(t == &Tarray)
			nrdy += altmark(c, p);
		else {
			if(c->send->prog || CANGET(c))
				nrdy++;
			cqadd(&c->recv, p);
		}
	}

	ac = a->ac;
	eac = ac + a->nsend;
	while(ac < eac) {
		c = ac->c;
		ac++;
		if(c == H) {
			e = exNilref;
			continue;
		}
		if(c->recv->prog || CANPUT(c)) {
			if(c->recv->prog == p) {
				e = exAlt;
				continue;
			}
			nrdy++;
		}
		cqadd(&c->send, p);
	}

	*ep = e;
	if(e != nil)
		altdone(a, p, nil, -1);

	return nrdy;
}

/*
 * ALT Pass 3 - Pull out of an ALT cancelling the channel pointers in each item
 */
void
altdone(Alt *a, Prog *p, Channel *sel, int sr)
{
	int n;
	Type *t;
	Channel *c;
	Altc *ac, *eac;

	n = 0;
	ac = a->ac;
	eac = a->ac + a->nsend;
	while(ac < eac) {
		c = ac->c;
		if(c != H) {
			if(c->send->prog)
				cqdelp(&c->send, p);
			if(sr == 0 && c == sel) {
				p->ptr = ac->ptr;
				W(p->reg.d) = n;
				sel = nil;
			}
		}
		ac++;
		n++;
	}

	eac = a->ac + a->nsend + a->nrecv;
	while(ac < eac) {
		c = ac->c;
		if(c != H) {
			t = D2H(c)->t;
			if(t == &Tarray)
				altunmark(c, ac->ptr, p, sr, &sel, n);
			else {
				if(c->recv->prog)
					cqdelp(&c->recv, p);
				if(sr == 1 && c == sel) {
					p->ptr = ac->ptr;
					W(p->reg.d) = n;
					sel = nil;
				}
			}
		}
		ac++;
		n++;
	}
}

/*
 * ALT Pass 2 - Perform the communication on the chosen channel
 */
static void
altcomm(Alt *a, int which)
{
	Type *t;
	Array *r;
	int n, an;
	WORD *ptr;
	Altc *ac, *eac;
	Channel *c, **ca, **ec;

	n = 0;
	ac = a->ac;
	eac = ac + a->nsend;
	while(ac < eac) {
		c = ac->c;
		if((c->recv->prog != nil || CANPUT(c)) && which-- == 0) {
			W(R.d) = n;
			R.s = ac->ptr;
			isendx(c);
			return;
		}
		ac++;
		n++;
	}

	eac = eac + a->nrecv;
	while(ac < eac) {
		c = ac->c;
		t = D2H(c)->t;
		if(t == &Tarray) {
			an = 0;
			r = (Array*)c;
			ca = (Channel**)r->data;
			ec = ca + r->len;
			while(ca < ec) {
				c = *ca;
				if(c != H && (c->send->prog != nil || CANGET(c)) && which-- == 0) {
					W(R.d) = n;
					ptr = ac->ptr;
					R.d = ptr + 1;
					ptr[0] = an;
					irecvx(c);
					return;
				}
				ca++;
				an++;
			}
		}
		else
		if((c->send->prog != nil || CANGET(c)) && which-- == 0) {
			W(R.d) = n;
			R.d = ac->ptr;
			irecvx(c);
			return;
		}
		ac++;
		n++;
	}
	/* Diagnostic: altrdy() (pass 1) counted `nrdy` ready channels and
	 * xecalt() picked `which` in [0,nrdy) to hand to us; if we get here,
	 * `which` never hit 0 against an actually-ready channel in this
	 * pass 2 walk - i.e. a channel that looked ready during pass 1 no
	 * longer is during pass 2. When that happens the caller's dispatch
	 * index slot (R.d before we overwrote it above) is never written,
	 * so a subsequent igoto reads whatever was left there. */
	print("altcomm: no channel matched which=%d nrdy-derived, nsend=%ld nrecv=%ld\n",
		which, (long)a->nsend, (long)a->nrecv);
	return;
}

void
altgone(Prog *p)
{
	Alt *a;

	if (p->state == Palt) {
		a = p->reg.s;
		altdone(a, p, nil, -1);
		p->kill = "alt channel hungup";
		addrun(p);
	}
}

void
xecalt(int block)
{
	Alt *a;
	Prog *p;
	char *e;
	int nrdy;
	static ulong xrand = 0x20342;

	p = currun();

	a = R.s;
	/*
	 * All three passes are one region.  Pass 1 marks this prog on every
	 * channel of the alt and counts how many are ready; pass 2 does the
	 * communication on one of them; pass 3 unmarks.  A second
	 * interpreter arriving between passes sees a prog queued on
	 * channels it is not going to use, or a readiness count that has
	 * stopped being true -- the "altcomm: no channel matched" print
	 * below is what that looks like from inside.
	 *
	 * cqfill() and the error() for a nil or self-referencing channel
	 * are outside the region, at the two ends, because both can
	 * longjmp.
	 */
	cqfill(altcells(a) + 1);	/* +1: altcomm()'s isendx/irecvx */
	chanlock();
	e = nil;
	nrdy = altrdy(a, p, &e);
	if(e == nil) {
		if(nrdy == 0) {
			if(block) {
				delrun(Palt);
				p->reg.s = R.s;
				p->reg.d = R.d;
				R.IC = 1;
				R.t = 1;
			}
			else {
				W(R.d) = a->nsend + a->nrecv;
				altdone(a, p, nil, -1);
			}
		}
		else {
			xrand = xrand*1103515245 + 12345;
			altcomm(a, (xrand>>8)%nrdy);
			altdone(a, p, nil, -1);
		}
	}
	chanunlock();
	cqtrim();
	if(e != nil)
		error(e);
}
