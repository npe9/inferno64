#include "lib9.h"
#include "draw.h"
#include "memdraw.h"
#include "memlayer.h"

void
memldelete(Memimage *i)
{
	Memscreen *s;
	Memlayer *l;

	l = i->layer;
	/* free backing store and disconnect refresh, to make pushback fast */
	freememimage(l->save);
	l->save = nil;
	l->refreshptr = nil;
	memltorear(i);

	/* window is now the rearmost;  clean up screen structures and deallocate */
	s = i->layer->screen;
	/*
	 * memltorear() above already did the real work of revealing what's
	 * now visible: for every layer i passed on its way to the rear, it
	 * called memlexpose() on the overlap, which correctly repaints from
	 * whatever real content lies behind. Painting i's own footprint
	 * with s->fill here on top of that is redundant in every case where
	 * something genuinely was behind - and actively harmful otherwise:
	 * it writes straight into the shared softscreen (all screens on
	 * this branch share the same physical pixel buffer, &screendata)
	 * with zero awareness that a different, unrelated screen may
	 * already have drawn correct content into that exact footprint
	 * before this layer's own teardown got around to running - deleting
	 * i here doesn't mean the pixels are unclaimed, only that this
	 * particular screen no longer has a layer covering them.
	 *
	 * This was first found via wmclient.b's putimage(), which discards
	 * its own nested Screen on every reshape (a narrower guard here,
	 * `s->image->layer == nil`, was tried to distinguish that nested
	 * case from a "genuinely top-level, safe to paint" one) - but a
	 * second, independent reproduction (via drawuninstallscreen()'s
	 * whole-screen 'F' teardown path, LLDB watchpoint-traced) showed
	 * the exact same wipe firing through a screen that *does* satisfy
	 * that guard (s->image->layer legitimately nil, i.e. truly
	 * top-level) - proving nesting depth was never the real invariant;
	 * the race exists regardless of it. s->fill has no other consumer
	 * anywhere in this tree, so removing this step here removes it
	 * everywhere: pinboard icons and the toolbar wiped after a resize.
	 */
	if(l->front){
		l->front->layer->rear = nil;
		s->rearmost = l->front;
	}else{
		s->frontmost = nil;
		s->rearmost = nil;
	}
	free(l);
	freememimage(i);
}

/*
 * Just free the data structures, don't do graphics
 */
void
memlfree(Memimage *i)
{
	Memlayer *l;

	l = i->layer;
	freememimage(l->save);
	free(l);
	freememimage(i);
}

void
_memlsetclear(Memscreen *s)
{
	Memimage *i, *j;
	Memlayer *l;

	for(i=s->rearmost; i; i=i->layer->front){
		l = i->layer;
		l->clear = rectinrect(l->screenr, l->screen->image->clipr);
		if(l->clear)
			for(j=l->front; j; j=j->layer->front)
				if(rectXrect(l->screenr, j->layer->screenr)){
					l->clear = 0;
					break;
				}
	}
}
