/* dtest - a libdraw client, to drive the user-level /dev/draw server:
 * initdraw through it, then draw rectangles on the screen. */
#include <u.h>
#include <libc.h>
#include <draw.h>

void
main(void)
{
	Image *red, *green;
	Rectangle r;

	if(initdraw(nil, nil, "dtest") < 0)
		sysfatal("initdraw: %r");
	draw(screen, screen->r, display->white, nil, ZP);
	red = allocimage(display, Rect(0,0,1,1), screen->chan, 1, 0xDD3333FF);
	green = allocimage(display, Rect(0,0,1,1), screen->chan, 1, 0x33CC66FF);
	if(red==nil || green==nil)
		sysfatal("allocimage: %r");
	r = rectaddpt(Rect(0,0,400,240), addpt(screen->r.min, Pt(120,120)));
	draw(screen, r, red, nil, ZP);
	r = rectaddpt(Rect(0,0,520,360), addpt(screen->r.min, Pt(600,300)));
	draw(screen, r, green, nil, ZP);
	if(flushimage(display, 1) < 0)
		sysfatal("flushimage: %r");
	print("dtest: drew through the user-level /dev/draw server\n");
	sleep(4000);
	exits(nil);
}
