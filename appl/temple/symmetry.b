implement Symmetry;

# TempleOS Demo/Graphics/Symmetry.HC — stock Inferno Wmclient+Draw port
#
# The original is a rubber-band straight-line tool with a mirror:
# MSG_MS_L_DOWN anchors, an inner GetMsg loop XOR-previews the line
# anchor->cursor on every MS_MOVE (mirrored live, since DCF_SYMMETRY
# stays on), and MS_L_UP commits one straight segment.  MSG_MS_R_DOWN
# clears DCF_SYMMETRY and rubber-bands the prospective mirror line in
# XOR red; MS_R_UP commits it via DCSymmetry3Set — a degenerate (point)
# line leaves symmetry off.  The default mirror at pix_width/2 is
# configured but never drawn.  Only Esc/Shift-Esc exits.
#
# Here the XOR draw/undraw preview is done by redrawing from a white
# backing canvas (which also preserves the drawing across window
# redraws/resizes, as TempleOS screen memory did).
#
# GAP: draw(2) has no XOR raster op: previews and committed strokes
# paint opaquely (black strokes, red mirror line) instead of
# XOR-inverting the pixels beneath, so overlapping ink does not invert.
# GAP: original runs fullscreen borderless (WinBorder/WinMax,
# SELF_BORDER/SELF_FOCUS inhibited); this is a normal 640x480 window.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "grpalette.m";
	grpal: Grpalette;

Symmetry: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
canvas: ref Image;	# backing store: committed drawing, white ground
black, red: ref Image;
sym_on := 1;
sx1, sy1, sx2, sy2: int;	# mirror line (canvas coords)
rubber := 0;		# 0 idle, 1 LMB stroke, 2 RMB mirror line
ax, ay: int;		# rubber-band anchor (canvas coords)
cx, cy: int;		# current cursor (canvas coords)

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
	win = wmclient->window(ctxt, "TempleOS Symmetry", Wmclient->Appl);
	d := win.display;
	# exact TempleOS palette entries: BLACK, RED
	black = d.color(grpal->value(Grpalette->BLACK));
	red = d.color(grpal->value(Grpalette->RED));
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	ensurecanvas();
	if(win.image != nil){
		# default mirror: vertical at width/2, active but NOT drawn
		# (DCSymmetrySet only configures the transform)
		sx1 = win.image.r.dx()/2; sy1 = 0;
		sx2 = sx1; sy2 = 1;
	}
	refresh();

	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!'){
			ensurecanvas();
			refresh();
		}
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		ptr(p);
	k := <-win.ctxt.kbd =>
		# original exits ONLY on Esc/Shift-Esc; other keys ignored
		if(k == 16r1b)
			exit;
	}
}

# keep the backing canvas at least as big as the window, preserving content
ensurecanvas()
{
	img := win.image;
	if(img == nil)
		return;
	w := img.r.dx();
	h := img.r.dy();
	if(canvas != nil && canvas.r.dx() >= w && canvas.r.dy() >= h)
		return;
	if(canvas != nil){
		if(canvas.r.dx() > w)
			w = canvas.r.dx();
		if(canvas.r.dy() > h)
			h = canvas.r.dy();
	}
	nc := win.display.newimage(Rect((0, 0), (w, h)), img.chans, 0, Draw->White);
	if(nc == nil)
		return;
	if(canvas != nil)
		nc.draw(canvas.r, canvas, nil, canvas.r.min);
	canvas = nc;
}

# reflect point across line (sx1,sy1)-(sx2,sy2)
reflect(x, y: int): (int, int)
{
	dx := real(sx2 - sx1);
	dy := real(sy2 - sy1);
	if(dx == 0.0 && dy == 0.0)
		return (x, y);
	px := real(x - sx1);
	py := real(y - sy1);
	t := (px*dx + py*dy) / (dx*dx + dy*dy);
	qx := real sx1 + t*dx;
	qy := real sy1 + t*dy;
	return (int(2.0*qx - real x), int(2.0*qy - real y));
}

# draw a 1px line (and its mirror image if symmetry is on), as
# DCF_SYMMETRY mirrored every plotted pixel in the original
line2(img: ref Image, x1, y1, x2, y2: int, col: ref Image, off: Point)
{
	img.line(Point(x1, y1).add(off), Point(x2, y2).add(off), 0, 0, 0, col, Point(0, 0));
	if(sym_on){
		(a, b) := reflect(x1, y1);
		(c, d) := reflect(x2, y2);
		img.line(Point(a, b).add(off), Point(c, d).add(off), 0, 0, 0, col, Point(0, 0));
	}
}

# blit the committed canvas, then the live rubber-band preview on top
refresh()
{
	img := win.image;
	if(img == nil || canvas == nil)
		return;
	img.draw(img.r, canvas, nil, Point(0, 0));
	case rubber {
	1 =>	# stroke preview: mirrored live, like the original's XOR pass
		line2(img, ax, ay, cx, cy, black, img.r.min);
	2 =>	# mirror-line preview: red, unmirrored (DCF_SYMMETRY cleared)
		img.line(Point(ax, ay).add(img.r.min), Point(cx, cy).add(img.r.min),
			0, 0, 0, red, Point(0, 0));
	}
	img.flush(Draw->Flushnow);
}

ptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil || canvas == nil)
		return;
	x := p.xy.x - img.r.min.x;
	y := p.xy.y - img.r.min.y;
	b := p.buttons;

	case rubber {
	0 =>
		if(b & 2){
			# MSG_MS_R_DOWN: symmetry off, anchor the mirror line
			rubber = 2;
			sym_on = 0;
			ax = x; ay = y;
			cx = x; cy = y;
			refresh();
		}else if(b & 1){
			# MSG_MS_L_DOWN: anchor the stroke
			rubber = 1;
			ax = x; ay = y;
			cx = x; cy = y;
			refresh();
		}
	1 =>
		if(b & 1){
			# MS_MOVE: re-preview the straight line anchor->cursor
			cx = x; cy = y;
			refresh();
		}else{
			# MSG_MS_L_UP: commit one straight segment (+ mirror)
			rubber = 0;
			line2(canvas, ax, ay, x, y, black, Point(0, 0));
			refresh();
		}
	2 =>
		if(b & 2){
			cx = x; cy = y;
			refresh();
		}else{
			# MSG_MS_R_UP: the red line stays as ink (the original's
			# final XOR pass leaves it on screen); a point turns
			# symmetry off, anything else sets the new mirror
			rubber = 0;
			canvas.line(Point(ax, ay), Point(x, y), 0, 0, 0, red, Point(0, 0));
			sx1 = ax; sy1 = ay;
			sx2 = x; sy2 = y;
			if(sx1 != sx2 || sy1 != sy2)
				sym_on = 1;
			refresh();
		}
	}
}
