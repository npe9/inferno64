implement Balloon;

# TempleOS Demo/Graphics/Balloon.HC — "Classic Commodore 64 Sprite".
#
#	U8 a[60]={0,127,0, 1,255,192, 3,255,224, ... 0,28,0};
#	CLI
#	OutU8(VGAP_IDX,VGAR_MAP_MASK); OutU8(VGAP_DATA,0xF);
#	MemSetI64(text.vga_alias,0,640*480/64);
#	OutU8(VGAP_IDX,VGAR_MAP_MASK); OutU8(VGAP_DATA,RED+GREEN+8);
#	for (k=100;k<150;k++) {
#	  for (i=0;i<20;i++) for (j=0;j<3;j++)
#	    *(text.vga_alias+0x1000+(i+k)*640/8+j)(U8*)=a[i*3+j];
#	  Busy(40000);
#	  ... and write zeroes back over it
#	}
#	STI  VGAFlush;
#
# Twenty rows of three bytes: the balloon sprite from a Commodore 64, at
# its original 24 by 21, one bit to the pixel.  Everything else in the
# program is the VGA: interrupts off, the plane mask set so writes land in
# the red, green and intensity planes at once — which is yellow — the
# screen cleared, and then the sprite poked straight into the framebuffer
# a byte at a time, erased, and poked one row lower.
#
# GAP: there is no framebuffer to poke and no plane mask to set, so the
#      port draws the same bits as pixels.  The sprite data, its 24x21
#      shape, the yellow, and the fifty rows it falls through are the
#      original's; the mechanism the demo is really showing off is not
#      reproducible outside a VGA.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";

Balloon: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# the sixty bytes, verbatim
a := array[] of {
	0,127,0,   1,255,192, 3,255,224, 3,231,224,
	7,217,240, 7,223,240, 7,217,240, 3,231,224,
	3,255,224, 3,255,224, 2,255,160, 1,127,64,
	1,62,64,   0,156,128, 0,156,128, 0,73,0, 0,73,0,
	0,62,0,    0,62,0,    0,28,0
};

win: ref Window;
font: ref Font;
black, yellow, blue: ref Image;
k := 100;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS Balloon", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	black = d.color(int 16r000000FF);
	blue = d.color(int 16r0000AAFF);
	yellow = d.color(int 16rFFFF55FF);	# RED+GREEN+8 in the plane mask

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 40);		# Busy(40000), near enough
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	kk := <-win.ctxt.kbd =>
		if((kk & Keyboard->Keyup) != Keyboard->Keyup)
			exit;
	<-ticks =>
		if(++k >= 150)
			k = 100;
		redraw();
	}
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	img.draw(img.r, black, nil, Point(0, 0));	# the cleared screen
	# the sprite: twenty rows of three bytes, most significant bit left
	for(i := 0; i < 20; i++)
		for(j := 0; j < 3; j++){
			b := a[i*3 + j];
			for(bit := 0; bit < 8; bit++)
				if((b & (16r80 >> bit)) != 0){
					x := o.x + j*8 + bit;
					y := o.y + i + k;
					img.draw(Rect((x, y), (x+1, y+1)), yellow,
						nil, Point(0, 0));
				}
		}
	if(font != nil)
		img.text(Point(o.x, o.y), blue, Point(0, 0), font,
			sys->sprint("row %d of 100..149    any key exits", k));
	img.flush(Draw->Flushnow);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
