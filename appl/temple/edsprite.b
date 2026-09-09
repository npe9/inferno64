implement Edsprite;

# TempleOS Demo/Graphics/EdSprite.HC — outline a sprite by looking at it.
#
# "Add an outline to Sprites and print them to the cmd line.  They can be
# cut/pasted from there."
#
#	for (n=0;n<NUM;n++) {
#	  SpriteExtents(in_img[n],&minx,&maxx,&miny,&maxy);
#	  w=maxx-minx+1+2;  h=maxy-miny+1+2;
#	  dc=DCNew(w,h);  dc->color=TRANSPARENT;  GrRect(dc,0,0,w,h);
#	  Sprite3(dc,-minx+1,-miny+1,0,in_img[n]);
#	  for (i=0;i<h;i++) for (j=0;j<w;j++)
#	    if (GrPeek(dc,j,i)==TRANSPARENT)
#	      for (k=0;k<8;k++) {
#	        c=GrPeek(dc,j+gr_x_offsets[k],i+gr_y_offsets[k]);
#	        if (c!=-1 && c!=BLACK && c!=TRANSPARENT) {
#	          dc->color=BLACK; GrPlot(dc,j,i); break; }
#	      }
#	  out_img=DC2Sprite(dc);  Sprite(out_img);
#	}
#
# Twelve sprites given a black outline, one pixel wide, by the simplest
# possible method: draw each into a device context one pixel larger all
# round, then walk every transparent pixel and blacken it if any of its
# eight neighbours is neither transparent, nor black, nor off the edge.
# There is no edge detection and no geometry — it reads back the pixels it
# just drew, which is what GrPeek is for, and DC2Sprite turns the result
# into a sprite again.
#
# The outlined sprites are printed to the command line so they can be cut
# and pasted into source; here they are drawn in a row instead, since a
# sprite in this tree is a file rather than a run of characters in a
# document.

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
include "grpalette.m";
	grpal: Grpalette;

Edsprite: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

NUM: con 12;

# gr_x_offsets / gr_y_offsets: the eight neighbours
xoff := array[] of {-1, 0, 1, 1, 1, 0, -1, -1};
yoff := array[] of {-1,-1,-1, 0, 1, 1,  1,  0};

win: ref Window;
font: ref Font;
d: ref Display;
white, black, blue: ref Image;
src, srcmask: array of ref Image;
out, outmask: array of ref Image;
outorg: array of Point;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS EdSprite", Wmclient->Appl);
	d = win.display;
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	if(font == nil)
		font = Font.open(d, "/fonts/temple/temple.font");
	white = d.color(grpal->value(Grpalette->WHITE));
	black = d.color(grpal->value(Grpalette->BLACK));
	blue = d.color(grpal->value(Grpalette->BLUE));

	src = array[NUM] of ref Image;
	srcmask = array[NUM] of ref Image;
	out = array[NUM] of ref Image;
	outmask = array[NUM] of ref Image;
	outorg = array[NUM] of Point;
	for(i := 0; i < NUM; i++){
		src[i] = d.open(sys->sprint("/icons/temple/edsprite_%d.bit", i+1));
		srcmask[i] = d.open(sys->sprint("/icons/temple/edsprite_%d.mask", i+1));
		(out[i], outmask[i]) = outline(src[i], srcmask[i]);
		if(src[i] != nil)
			outorg[i] = Point(src[i].r.min.x - 1, src[i].r.min.y - 1);
	}

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	redraw();
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		redraw();
	pointerev := <-win.ctxt.ptr =>
		# The titlebar is drawn by this window and only sees a click
		# if the program hands it one: without this arm the move,
		# resize and menu buttons on the window do nothing at all.
		win.pointer(*pointerev);
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) != Keyboard->Keyup)
			exit;
	}
}

# OutLine(): one pixel bigger all round, then blacken every transparent
# pixel with a neighbour that is neither transparent nor black.
# The result is a plain (0,0)-(w+2,h+2) image; the sprite's own origin
# moves one pixel up and left, which outorg records.
outline(s, m: ref Image): (ref Image, ref Image)
{
	if(s == nil || m == nil)
		return (nil, nil);
	sw := s.r.dx();
	sh := s.r.dy();
	w := sw + 2;
	h := sh + 2;
	# the mask says which pixels the sprite paints at all; TRANSPARENT is
	# everything it does not
	stride := (sw + 7)/8;
	mb := array[stride*sh] of byte;
	if(m.readpixels(m.r, mb) <= 0)
		return (nil, nil);
	pix := array[sw*sh] of byte;
	if(s.readpixels(s.r, pix) <= 0)
		return (nil, nil);

	on := array[w*h] of { * => 0 };		# 0 transparent, 1 drawn, 2 black
	for(y := 0; y < sh; y++)
		for(x := 0; x < sw; x++)
			if((int mb[y*stride + x/8] & (16r80 >> (x&7))) != 0){
				v := 1;
				if(pix[y*sw + x] == byte 0)
					v = 2;		# already BLACK
				on[(y+1)*w + (x+1)] = v;
			}

	nm := d.newimage(Rect((0,0),(w,h)), Draw->GREY1, 0, 0);
	ni := d.newimage(Rect((0,0),(w,h)), s.chans, 0, Draw->White);
	if(nm == nil || ni == nil)
		return (nil, nil);
	# the sprite itself
	ni.draw(Rect((1,1),(1+sw,1+sh)), s, nil, s.r.min);
	nm.draw(Rect((1,1),(1+sw,1+sh)), d.opaque, m, m.r.min);
	# then the outline
	for(y = 0; y < h; y++)
		for(x = 0; x < w; x++){
			if(on[y*w + x] != 0)
				continue;
			for(k := 0; k < 8; k++){
				nx := x + xoff[k];
				ny := y + yoff[k];
				if(nx < 0 || nx >= w || ny < 0 || ny >= h)
					continue;	# c == -1: off the edge
				if(on[ny*w + nx] == 1){	# not black, not transparent
					ni.draw(Rect((x,y),(x+1,y+1)), black, nil,
						Point(0,0));
					nm.draw(Rect((x,y),(x+1,y+1)), d.opaque, nil,
						Point(0,0));
					break;
				}
			}
		}
	return (ni, nm);
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	img.draw(img.r, white, nil, Point(0, 0));
	if(font != nil){
		img.text(o, blue, Point(0, 0), font,
			"above: as extracted.  below: with the outline added.");
		img.text(Point(o.x, img.r.max.y - font.height), blue, Point(0, 0),
			font, "any key exits");
	}
	x := 8;
	for(i := 0; i < NUM; i++){
		if(src[i] != nil){
			img.draw(src[i].r.addpt(Point(o.x+x-src[i].r.min.x, o.y+40)),
				src[i], srcmask[i], src[i].r.min);
			if(out[i] != nil)
				img.draw(out[i].r.addpt(Point(o.x+x-src[i].r.min.x+outorg[i].x,
					o.y+180)), out[i], outmask[i], out[i].r.min);
			x += src[i].r.dx() + 8;
			if(x > img.r.dx() - 40)
				break;
		}
	}
	img.flush(Draw->Flushnow);
}
