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
/*
 * THE ROW OFFSET MUST BE COMPUTED ENTIRELY IN 32 BITS, with no narrowing cast
 * for the compiler to drop.  It was
 *
 *	a = i->data->bdata+i->zero+(s32)(sizeof(u32)*p.y*i->width);
 *
 * and 7c DROPS that (s32) -- the same class as the (u32) and (ulong) cases this
 * tree already records.  sizeof is 64-bit, so the emitted code is
 *
 *	LSLW $2,R2	   p.y<<2 in 32 bits: -8 becomes 0xFFFFFFF8
 *	MOVWU 12(R0),R3    i->width
 *	UMULL R3,R2	   32x32 -> 64, UNSIGNED, never truncated back
 *	ADD R2,R3,R2	   added to the pointer at full 64-bit width
 *
 * with no SXTW and no MOVW back through 32 bits.  So for a NEGATIVE p.y the
 * 32-bit wrap survives into the high word:
 *
 *	term = (2^32 + 4*p.y) * width = width*2^32 + 4*p.y*width
 *
 * and since zero cancels the second part for an allocated image at r.min,
 *
 *	byteaddr(i, i->r.min) = bdata + width * 2^32
 *
 * EXACTLY.  So the high word of the bad address IS i->width and the low word is
 * bdata, unchanged -- which is why the raspi3b fault address was 0x3008c6c40,
 * with a clean small constant above a plausible pool pointer, IDENTICAL across
 * two kernels and two boots.  A corrupted pointer does not do that twice.
 *
 * It needs p.y < 0, so only an image with a negative r.min.y reaches it, and
 * libdraw/bytesperline.c already notes such a rectangle is rare.  Found by a
 * peer, who compiled the real file and read the instructions rather than
 * reducing the case; the board fault and the address arithmetic are this
 * session's.
 *
 * Keeping every operand 32 bits makes the truncation the arithmetic rather than
 * a cast, so there is nothing left to drop and 7c emits MULW with a
 * sign-extending widen.
 *
 * THE DEFECT IS NOW FIXED AND THIS SHAPE IS NO LONGER NECESSARY, which is
 * recorded here because the paragraphs above read as though it were.  7c's
 * gmove was dropping the widening move and no longer does; the natural form
 * compiles correctly on every 64-bit target this tree builds for.  Verified by
 * compiling both forms and reading the instructions, not by argument:
 *
 *	7c   aarch64   MOVW Rx,Rx before the ADD   sign-extends (MOVWU is the
 *	                                           zero-extending one, and 7c
 *	                                           uses it only for unsigned)
 *	6c   amd64     MOVLQSX                     sign-extends; was always
 *	                                           correct here
 *	jc   riscv64   MULW alone                  correct BY ISA: RISC-V's
 *	                                           W-form ops sign-extend their
 *	                                           32-bit result into the full
 *	                                           register, where AArch64's
 *	                                           W-register writes ZERO-extend
 *	5c 8c kc qc    32-bit targets              no widening exists to get
 *	vc 0c tc zc                                wrong
 *
 * The shape is KEPT anyway, deliberately: it costs two redundant moves and
 * eight bytes of frame in a function called per span rather than per pixel,
 * and tests/kencc-widencast.sh is what would catch a 7c regression -- but a
 * regression caught by a test still has to not corrupt memory in the meantime.
 * Belt and braces, with the braces now documented as braces.
 *
 * ONE TRAP WORTH THE LINE, because it cost a false alarm while checking this:
 * the first version of that comparison used `long' for the 64-bit type, and
 * kencc's long is THIRTY-TWO BITS.  Every "widening" in it was an int-to-int
 * move, 6c's bare MOVL was correct, and it looked exactly like 6c dropping the
 * sign extension on four paths out of five.  Use vlong.
 */
byteaddr(Memimage *i, Point p)
{
	uchar *a;
	s32 off;

	off = 4 * p.y * (s32)i->width;
	a = i->data->bdata + i->zero + off;

	/*
	 * AND THE X OFFSET HAS THE SAME PROBLEM WITH NO CAST ANYWHERE IN SIGHT.
	 *
	 * It was three returns of the form `a + <32-bit int expression>', and 7c
	 * emitted
	 *
	 *	SDIVW	R3,R5		32-bit result; an AArch64 W write
	 *	ADD	R10,R5,R0	ZEROES the top half of R5
	 *
	 * so a negative offset widens by ZERO EXTENSION.  For the one-byte-back
	 * case the offset is -1, which becomes 0x00000000FFFFFFFF, and the
	 * pointer lands at a - 1 + 2^32.
	 *
	 * MEASURED ON THE BOARD, after the row-offset fix above was already in:
	 *
	 *	memfillcolor: HIGH dst 0x1008c6c40 bdata 0x8c6c40 base 0x8c6c30
	 *	  allocd 1 zero 17 width 2 r -2 -2 3 3 chan 0x31
	 *
	 * bdata CLEAN, base = bdata-16, zero and width exactly right -- a
	 * correctly allocated image -- and the destination exactly 2^32 above
	 * it.  That is this branch, not the row offset, and it is why fixing the
	 * row offset moved the fault instead of removing it.
	 *
	 * There is no cast to drop here: C requires the int to widen with its
	 * sign when added to a pointer, and that widening is simply absent.  So
	 * the fix is the shape that survives -- assign to an s32 local and add
	 * that -- which forces the value through a 32-bit slot and makes 7c
	 * reload it sign-extended.  Same remedy as the row offset above, and the
	 * same reason: give the compiler nothing it can treat as a no-op.
	 */
	if(i->depth < 8){
		/*
		 * We need to always round down,
		 * but C rounds toward zero.
		 */
		s32 np, xoff;
		np = 8/i->depth;
		if(p.x < 0)
			xoff = (p.x-np+1)/np;
		else
			xoff = p.x/np;
		return a + xoff;
	}
	else {
		s32 xoff;

		xoff = p.x*(i->depth/8);
		return a + xoff;
	}
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
