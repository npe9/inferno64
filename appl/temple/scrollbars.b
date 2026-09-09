implement Scrollbars;

# TempleOS Demo/Graphics/ScrollBars.HC — a window bigger than itself.
#
#	task->horz_scroll.min=0; task->horz_scroll.max=MAP_WIDTH-pix_width;
#	task->vert_scroll.min=0; task->vert_scroll.max=MAP_HEIGHT-pix_height;
#	TaskDerivedValsUpdate(task);
#	h=task->horz_scroll.pos; v=task->vert_scroll.pos;
#	dc->color=BROWN; dc->thick=4;
#	... four GrLine3 for the map border, offset by -h,-v ...
#	for (i=0;i<TREES_NUM;i++)
#	  Sprite3(dc,tree_x[i]-h,tree_y[i]-v,0,$IB,"<Tree>",BI=1$);
#
# A 2048 by 2048 map with 256 trees on it, seen through a window a
# fraction of the size.  The program does not manage the scrolling: it
# declares the range, and the window manager draws the bars, handles the
# dragging and hands back a position, which the drawing subtracts.  The
# original's own aside — "Check bounds if you wish better performance" —
# is that it draws all 256 trees whether or not they are on screen.
#
# GAP: wm(1) has no scroll bars to declare a range to, so the port draws
#      its own along the right and bottom edges and drags them itself.
#      The arrow keys scroll too.  Everything on the other side of the
#      declaration — the map, the trees, the offset drawing, the bounds
#      not being checked — is the original's.

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

include "rand.m";
	rand: Rand;
include "grpalette.m";
	grpal: Grpalette;

Scrollbars: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

MAP_WIDTH: con 2048;
MAP_HEIGHT: con 2048;
TREES_NUM: con 256;
BAR: con 12;			# the scroll bars this port draws

win: ref Window;
font: ref Font;
white, black, brown, ltgray, dkgray: ref Image;
tree, treemask: ref Image;
tx, ty: array of int;
h, v: int;
draghorz := 0;
dragvert := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS ScrollBars", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	if(font == nil)
		font = Font.open(d, "/fonts/temple/temple.font");
	white = d.color(grpal->value(Grpalette->WHITE));
	black = d.color(grpal->value(Grpalette->BLACK));
	brown = d.color(grpal->value(Grpalette->BROWN));
	ltgray = d.color(grpal->value(Grpalette->LTGRAY));
	dkgray = d.color(grpal->value(Grpalette->DKGRAY));
	tree = d.open("/icons/temple/scrollbars_1.bit");
	treemask = d.open("/icons/temple/scrollbars_1.mask");

	tx = array[TREES_NUM] of int;
	ty = array[TREES_NUM] of int;
	for(i := 0; i < TREES_NUM; i++){
		tx[i] = rn(MAP_WIDTH);
		ty[i] = rn(MAP_HEIGHT);
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
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) == Keyboard->Keyup)
			continue;
		case k {
		Keyboard->Left =>	h -= 32;
		Keyboard->Right =>	h += 32;
		Keyboard->Up =>		v -= 32;
		Keyboard->Down =>	v += 32;
		* =>			exit;
		}
		redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		img := win.image;
		if(img == nil)
			continue;
		x := p.xy.x - img.r.min.x;
		y := p.xy.y - img.r.min.y;
		w := img.r.dx();
		ht := img.r.dy();
		if(p.buttons & 1){
			if(!draghorz && !dragvert){
				if(y >= ht - BAR)
					draghorz = 1;
				else if(x >= w - BAR)
					dragvert = 1;
			}
			if(draghorz)
				h = x * hmax(w, ht) / max(1, w - BAR);
			else if(dragvert)
				v = y * vmax(w, ht) / max(1, ht - BAR);
			redraw();
		}else
			draghorz = dragvert = 0;
	}
}

hmax(w, nil: int): int
{
	return max(0, MAP_WIDTH - w);
}

vmax(nil, ht: int): int
{
	return max(0, MAP_HEIGHT - ht);
}

max(a, b: int): int
{
	if(a > b)
		return a;
	return b;
}

clamp(x, lo, hi: int): int
{
	if(x < lo)
		return lo;
	if(x > hi)
		return hi;
	return x;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	ht := img.r.dy();
	h = clamp(h, 0, hmax(w, ht));
	v = clamp(v, 0, vmax(w, ht));
	img.draw(img.r, white, nil, Point(0, 0));

	# the map border, thick 4, offset by the scroll position
	thickline(img, o, 2-h, 2-v, MAP_WIDTH-3-h, 2-v);
	thickline(img, o, 2-h, MAP_HEIGHT-3-v, MAP_WIDTH-3-h, MAP_HEIGHT-3-v);
	thickline(img, o, 2-h, 2-v, 2-h, MAP_HEIGHT-3-v);
	thickline(img, o, MAP_WIDTH-3-h, 2-v, MAP_WIDTH-3-h, MAP_HEIGHT-3-v);

	# every tree, on screen or not, as the original's aside admits
	if(tree != nil)
		for(i := 0; i < TREES_NUM; i++)
			img.draw(tree.r.addpt(Point(o.x+tx[i]-h, o.y+ty[i]-v)),
				tree, treemask, tree.r.min);

	# the bars this port has to draw for itself
	img.draw(Rect((o.x, o.y+ht-BAR), (o.x+w, o.y+ht)), ltgray, nil, Point(0,0));
	img.draw(Rect((o.x+w-BAR, o.y), (o.x+w, o.y+ht)), ltgray, nil, Point(0,0));
	hw := max(8, (w-BAR)*(w-BAR)/MAP_WIDTH);
	hx := 0;
	if(hmax(w, ht) > 0)
		hx = h*(w-BAR-hw)/hmax(w, ht);
	img.draw(Rect((o.x+hx, o.y+ht-BAR), (o.x+hx+hw, o.y+ht)), dkgray,
		nil, Point(0,0));
	vh := max(8, (ht-BAR)*(ht-BAR)/MAP_HEIGHT);
	vy := 0;
	if(vmax(w, ht) > 0)
		vy = v*(ht-BAR-vh)/vmax(w, ht);
	img.draw(Rect((o.x+w-BAR, o.y+vy), (o.x+w, o.y+vy+vh)), dkgray,
		nil, Point(0,0));

	if(font != nil)
		img.text(o, black, Point(0, 0), font,
			sys->sprint("horz %d of %d, vert %d of %d   arrows scroll, a key exits",
				h, hmax(w, ht), v, vmax(w, ht)));
	img.flush(Draw->Flushnow);
}

thickline(img: ref Image, o: Point, x1, y1, x2, y2: int)
{
	img.line(Point(o.x+x1, o.y+y1), Point(o.x+x2, o.y+y2),
		Draw->Endsquare, Draw->Endsquare, 2, brown, Point(0, 0));
}

rn(n: int): int
{
	if(rand == nil)
		return sys->millisec() % n;
	return rand->rand(n);
}
