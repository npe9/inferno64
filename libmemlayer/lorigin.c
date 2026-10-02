#include "lib9.h"
#include "draw.h"
#include "memdraw.h"
#include "memlayer.h"


enum {
	Nvac = 32,	/* bands tracked while subtracting layers */
};

/*
 * a minus b, as up to four rectangles.  Returns how many.
 */
static int
subrect(Rectangle a, Rectangle b, Rectangle *out)
{
	Rectangle x;
	int n;

	n = 0;
	if(!rectXrect(a, b)){
		out[0] = a;
		return 1;
	}
	if(b.min.y > a.min.y){		/* above */
		x = a;
		x.max.y = b.min.y;
		out[n++] = x;
	}
	if(b.max.y < a.max.y){		/* below */
		x = a;
		x.min.y = b.max.y;
		out[n++] = x;
	}
	if(b.min.x > a.min.x){		/* left, between the bands */
		x = a;
		x.max.x = b.min.x;
		if(b.min.y > a.min.y)
			x.min.y = b.min.y;
		if(b.max.y < a.max.y)
			x.max.y = b.max.y;
		out[n++] = x;
	}
	if(b.max.x < a.max.x){		/* right, between the bands */
		x = a;
		x.min.x = b.max.x;
		if(b.min.y > a.min.y)
			x.min.y = b.min.y;
		if(b.max.y < a.max.y)
			x.max.y = b.max.y;
		out[n++] = x;
	}
	return n;
}

/*
 * Paint the screen's fill over the parts of r that no layer covers.
 *
 * This is what cleans up after a move.  memldelete() used to paint
 * s->fill over a deleted layer's footprint and deliberately no longer
 * does - ldelete.c explains why, with two independent reproductions: on
 * a screen TEARDOWN the pixels may already belong to a different screen
 * sharing the same softscreen, so painting them is a wipe.
 *
 * A move is not a teardown.  This screen still exists and still owns
 * oldr, and memlorigin's shadow window exists for no other purpose than
 * to make this restore happen - "this will cause no graphics action
 * except to restore the background", says the comment below, which
 * stopped being true when that step went.  So the restore is done here,
 * where the thing ldelete.c cannot know is known.
 *
 * Subtracting the layers rather than painting and re-exposing them is
 * deliberate: memlexpose() on a Refnone layer calls its refresh
 * function, which in devdraw asks the client to repaint, so painting
 * first would turn one window move into a repaint storm for everything
 * underneath - and for a layer whose refresh does nothing it would leave
 * fill where content was, trading this afterimage for another.
 *
 * Running out of bands drops the remainder, which shows as a stale patch
 * rather than as live content painted over.  That is the safe direction.
 */
static void
fillvacated(Memscreen *s, Rectangle r)
{
	Rectangle work[Nvac], next[Nvac], piece[4];
	int nwork, nnext, i, j, n;
	Memimage *t;

	if(s->fill == nil || Dx(r) <= 0 || Dy(r) <= 0)
		return;
	work[0] = r;
	nwork = 1;
	for(t = s->rearmost; t != nil && nwork > 0; t = t->layer->front){
		nnext = 0;
		for(i = 0; i < nwork; i++){
			n = subrect(work[i], t->layer->screenr, piece);
			for(j = 0; j < n; j++){
				if(Dx(piece[j]) <= 0 || Dy(piece[j]) <= 0)
					continue;
				if(nnext >= Nvac)
					continue;
				next[nnext++] = piece[j];
			}
		}
		for(i = 0; i < nnext; i++)
			work[i] = next[i];
		nwork = nnext;
	}
	for(i = 0; i < nwork; i++)
		memdraw(s->image, work[i], s->fill, work[i].min, nil, Pt(0,0), S);
}

/*
 * Place i so i->r.min = log, i->layer->screenr.min == scr.
*/
int
memlorigin(Memimage *i, Point log, Point scr)
{
	Memlayer *l;
	Memscreen *s;
	Memimage *t, *shad, *nsave;
	Rectangle x, newr, oldr;
	Point delta;
	int overlap, eqlog, eqscr, wasclear;

	l = i->layer;
	s = l->screen;
	oldr = l->screenr;
	newr = Rect(scr.x, scr.y, scr.x+Dx(oldr), scr.y+Dy(oldr));
	eqscr = eqpt(scr, oldr.min);
	eqlog = eqpt(log, i->r.min);
	if(eqscr && eqlog)
		return 0;
	nsave = nil;
	if(eqlog==0 && l->save!=nil){
		nsave = allocmemimage(Rect(log.x, log.y, log.x+Dx(oldr), log.y+Dy(oldr)), i->chan);
		if(nsave == nil)
			return -1;
	}

	/*
	 * Bring it to front and move logical coordinate system.
	 */
	memltofront(i);
	wasclear = l->clear;
	if(nsave){
		if(!wasclear)
			memimagedraw(nsave, nsave->r, l->save, l->save->r.min, nil, Pt(0,0), S);
		freememimage(l->save);
		l->save = nsave;
	}
	delta = subpt(log, i->r.min);
	i->r = rectaddpt(i->r, delta);
	i->clipr = rectaddpt(i->clipr, delta);
	l->delta = subpt(l->screenr.min, i->r.min);
	if(eqscr)
		return 0;

	/*
	 * To clean up old position, make a shadow window there, don't paint it,
	 * push it behind this one, and (later) delete it.  Because the refresh function
	 * for this fake window is a no-op, this will cause no graphics action except
	 * to restore the background and expose the windows previously hidden.
	 */
	shad = memlalloc(s, oldr, memlnorefresh, nil, DNofill);
	if(shad == nil)
		return -1;
	s->frontmost = i;
	if(s->rearmost == i)
		s->rearmost = shad;
	else
		l->rear->layer->front = shad;
	shad->layer->front = i;
	shad->layer->rear = l->rear;
	l->rear = shad;
	l->front = nil;
	shad->layer->clear = 0;

	/*
	 * Shadow is now holding down the fort at the old position.
	 * Move the window and hide things obscured by new position.
	 */
	for(t=l->rear->layer->rear; t!=nil; t=t->layer->rear){
		x = newr;
		overlap = rectclip(&x, t->layer->screenr);
		if(overlap){
			memlhide(t, x);
			t->layer->clear = 0;
		}
	}
	l->screenr = newr;
	l->delta = subpt(scr, i->r.min);
	l->clear = rectinrect(newr, l->screen->image->clipr);

	/*
	 * Everything's covered.  Copy to new position and delete shadow window.
	 */
	if(wasclear)
		memdraw(s->image, newr, s->image, oldr.min, nil, Pt(0,0), S);
	else
		memlexpose(i, newr);
	memldelete(shad);

	/*
	 * The window is at its new place and the shadow is gone; nothing
	 * has repainted what the window used to cover that no other layer
	 * covers now.  oldr includes the part newr overlaps, which is fine:
	 * the moved window is itself a layer at newr, so subtracting the
	 * layers takes that out too.
	 */
	fillvacated(s, oldr);

	return 1;
}

void
memlnorefresh(Memimage *l, Rectangle r, void *v)
{
	USED(l);
	USED(r.min.x);
	USED(v);
}
