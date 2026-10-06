#include "lib9.h"
#include "draw.h"
#include "memdraw.h"
#include "pool.h"

extern	Pool*	imagmem;

void
memimagemove(void *from, void *to)
{
	Memdata *md;

	md = *(Memdata**)to;
	if(md->base != from){
		print("compacted data not right: #%p\n", md->base);
		abort();
	}
	md->base = to;

	/* if allocmemimage changes this must change too */
	md->bdata = (uchar*)&md->base[2];
}

Memimage*
allocmemimaged(Rectangle r, u32 chan, Memdata *md)
{
	s32 d;
	u32 l;
	Memimage *i;

	if((d = chantodepth(chan)) == 0) {
		werrstr("bad channel descriptor %.8ux", chan);
		return nil;
	}

	l = wordsperline(r, d);

	i = mallocz(sizeof(Memimage), 1);
	if(i == nil)
		return nil;

	i->data = md;
	i->zero = sizeof(u32)*l*r.min.y;
	
	if(r.min.x >= 0)
		i->zero += (r.min.x*d)/8;
	else
		i->zero -= (-r.min.x*d+7)/8;
	i->zero = -i->zero;
	i->width = l;
	i->r = r;
	i->clipr = r;
	i->flags = 0;
	i->layer = nil;
	i->cmap = memdefcmap;
	if(memsetchan(i, chan) < 0){
		free(i);
		return nil;
	}
	return i;
}

Memimage*
allocmemimage(Rectangle r, u32 chan)
{
	s32 d;
	u32 l, nw;
	Memdata *md;
	Memimage *i;

	if((d = chantodepth(chan)) == 0) {
		werrstr("bad channel descriptor %.8ux", chan);
		return nil;
	}

	l = wordsperline(r, d);
	nw = l*Dy(r);
	md = malloc(sizeof(Memdata));
	if(md == nil)
		return nil;

	md->ref = 1;
	md->base = poolalloc(imagmem, 2*sizeof(intptr)+nw*sizeof(u32));
	if(md->base == nil){
		free(md);
		return nil;
	}

	md->base[0] = (uintptr)md;
	md->base[1] = getcallerpc(&r);

	/* if this changes, memimagemove must change too */
	md->bdata = (uchar*)&md->base[2];

	md->allocd = 1;

	i = allocmemimaged(r, chan, md);
	if(i == nil){
		poolfree(imagmem, md->base);
		free(md);
		return nil;
	}
	md->imref = i;
	return i;
}

void
freememimage(Memimage *i)
{
	if(i == nil)
		return;
	if(i->data->ref-- == 1 && i->data->allocd){
		if(i->data->base)
			poolfree(imagmem, i->data->base);
		free(i->data);
	}
	free(i);
}

/*
 * Wordaddr is deprecated.
 *
 * THE MASK IS sizeof(u32), NOT sizeof(uintptr), and it was the latter.  9front's
 * wordaddr -- 9front/src/libmemdraw/alloc.c:133 -- masks with sizeof(ulong)-1
 * where ulong is 4 bytes, so it rounds a byte address DOWN TO THE 32-BIT WORD
 * that contains it.  Renaming it u32addr for a 64-bit port and writing
 * sizeof(uintptr) changed the rounding to 8 bytes, which can return a pointer
 * FOUR BYTES BEFORE the word asked for.
 *
 * This is latent rather than a bug with symptoms, and saying which it is matters
 * more than the one-line fix: the only caller is memfillcolor(), which passes
 * i->r.min of an image from allocmemimage(), where byteaddr() returns bdata
 * exactly, and imagmem hands out 8-aligned blocks -- so the mask has been a
 * no-op everywhere it runs today.  It would stop being one the moment a caller
 * passes a point whose byte address is 4 mod 8, and memset32() would then write
 * four bytes before the destination and one word past its end.
 */
u32*
u32addr(Memimage *i, Point p)
{
	return (u32*) ((uintptr)byteaddr(i, p) & ~(uintptr)(sizeof(u32)-1));
}

uchar*
byteaddr(Memimage *i, Point p)
{
	uchar *a;

	a = i->data->bdata+i->zero+(s32)(sizeof(u32)*p.y*i->width);

	if(i->depth < 8){
		/*
		 * We need to always round down,
		 * but C rounds toward zero.
		 */
		s32 np;
		np = 8/i->depth;
		if(p.x < 0)
			return a+(p.x-np+1)/np;
		else
			return a+p.x/np;
	}
	else
		return a+p.x*(i->depth/8);
}

int
memsetchan(Memimage *i, u32 chan)
{
	s32 d;
	s32 t, j, k;
	u32 cc;
	s32 bytes;

	if((d = chantodepth(chan)) == 0) {
		werrstr("bad channel descriptor");
		return -1;
	}

	i->depth = d;
	i->chan = chan;
	i->flags &= ~(Fgrey|Falpha|Fcmap|Fbytes);
	bytes = 1;
	for(cc=chan, j=0, k=0; cc; j+=NBITS(cc), cc>>=8, k++){
		t=TYPE(cc);
		if(t < 0 || t >= NChan){
			werrstr("bad channel string");
			return -1;
		}
		if(t == CGrey)
			i->flags |= Fgrey;
		if(t == CAlpha)
			i->flags |= Falpha;
		if(t == CMap && i->cmap == nil){
			i->cmap = memdefcmap;
			i->flags |= Fcmap;
		}

		i->shift[t] = j;
		i->mask[t] = (1<<NBITS(cc))-1;
		i->nbits[t] = NBITS(cc);
		if(NBITS(cc) != 8)
			bytes = 0;
	}
	i->nchan = k;
	if(bytes)
		i->flags |= Fbytes;
	return 0;
}
