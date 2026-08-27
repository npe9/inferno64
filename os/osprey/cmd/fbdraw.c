/* fbdraw - composite with libmemdraw into the exposed frame buffer.
 * Built natively on the disk, so it links the disk's own libmemdraw and
 * libc - the whole point.  It maps the exposed "framebuffer" segment,
 * builds an image with the library, and blits it. */
#include <u.h>
#include <libc.h>
#include <draw.h>
#include <memdraw.h>

enum { W=1280, H=800 };

static Memimage*
colour(ulong c)
{
	Memimage *m = allocmemimage(Rect(0,0,1,1), XRGB32);
	if(m==nil) return nil;
	m->flags |= Frepl;
	m->clipr = Rect(-0x3FFFFFF,-0x3FFFFFF,0x3FFFFFF,0x3FFFFFF);
	memfillcolor(m, c);
	return m;
}

void
main(int, char**)
{
	ulong *fb;
	Memimage *img, *red, *green;

	fb = (ulong*)segattach(0, "framebuffer", 0, (ulong)W*H*4);
	if(fb == (ulong*)-1)
		sysfatal("segattach framebuffer: %r");
	if(memimageinit() < 0)
		sysfatal("memimageinit: %r");
	img = allocmemimage(Rect(0,0,W,H), XRGB32);
	if(img == nil)
		sysfatal("allocmemimage: %r");
	memfillcolor(img, 0x204080FF);
	red = colour(0xE03030FF);
	green = colour(0x30C060FF);
	if(red) memimagedraw(img, Rect(120,120,520,360), red, ZP, nil, ZP, SoverD);
	if(green) memimagedraw(img, Rect(600,300,1120,680), green, ZP, nil, ZP, SoverD);
	memmove(fb, byteaddr(img, img->r.min), (ulong)W*H*4);
	print("fbdraw: composited with libmemdraw into the exposed frame buffer\n");
	exits(nil);
}
