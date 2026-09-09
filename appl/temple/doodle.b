implement Doodle;

# TempleOS Demo/Graphics/Doodle.HC — stock Inferno Wmclient+Draw port
#
# The original is a rubber-band straight-line tool: MSG_MS_L_DOWN anchors,
# an inner GetMsg loop XOR-previews the line anchor->cursor on every
# MS_MOVE, and MS_L_UP commits one straight 7px-thick segment.
# MSG_MS_R_UP opens PopUpColor (16-color chooser; cancel keeps the
# current color).  Any key with a nonzero char exits.
#
# Here the XOR preview is done by redrawing from a white backing canvas
# (which also preserves the drawing across window redraws/resizes, as
# TempleOS screen memory did) and PopUpColor is a 4x4 swatch grid:
# left-click a swatch to pick, click elsewhere or press Esc to cancel.
#
# GAP: original runs fullscreen borderless (WinMax, SELF_BORDER/SELF_FOCUS
# inhibited); this is a normal 640x480 Inferno window.
# GAP: PopUpColor is a titled menu of color names in TempleOS; here it is
# a swatch grid, and the preview line is drawn in the chosen color rather
# than XORed.

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

Doodle: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
canvas: ref Image;	# backing store: committed drawing, white ground
ink: array of ref Image;
color := 0;		# original starts with color=BLACK
rubber := 0;		# button 1 held, previewing anchor->cursor
ax, ay: int;		# anchor (canvas coords)
cx, cy: int;		# current cursor (canvas coords)
picking := 0;		# PopUpColor swatch grid is up
pickr: Rect;		# grid panel rect (canvas coords)
prevbtns := 0;

# PopUpColor swatch grid geometry
SW: con 28;		# swatch size
GAP: con 6;		# padding between swatches and panel edge
PANEL: con 4*SW + 5*GAP;

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

	win = wmclient->window(ctxt, "TempleOS Doodle", Wmclient->Appl);
	d := win.display;
	ink = array[16] of ref Image;
	# the exact TempleOS 16-color palette, index = TempleOS color
	cols := grpal->values();
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	ensurecanvas();
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
		if(k >= 16rE000)
			break;		# key releases / bare shifters: no char
		if(picking){
			# Esc (or any key) cancels PopUpColor, keeps color
			picking = 0;
			refresh();
			break;
		}
		# original exits on ANY key with a nonzero char
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

refresh()
{
	img := win.image;
	if(img == nil || canvas == nil)
		return;
	img.draw(img.r, canvas, nil, Point(0, 0));
	if(rubber)
		img.line(Point(ax, ay).add(img.r.min), Point(cx, cy).add(img.r.min),
			Draw->Enddisc, Draw->Enddisc, 3, ink[color], Point(0, 0));
	if(picking)
		drawpicker(img);
	img.flush(Draw->Flushnow);
}

drawpicker(img: ref Image)
{
	pr := pickr.addpt(img.r.min);
	img.draw(pr, ink[7], nil, Point(0, 0));		# LtGray panel
	img.border(pr, 1, ink[0], Point(0, 0));
	for(i := 0; i < 16; i++){
		sr := swatchrect(i).addpt(img.r.min);
		img.draw(sr, ink[i], nil, Point(0, 0));
		img.border(sr, 1, ink[0], Point(0, 0));
	}
}

swatchrect(i: int): Rect
{
	x := pickr.min.x + GAP + (i % 4) * (SW + GAP);
	y := pickr.min.y + GAP + (i / 4) * (SW + GAP);
	return Rect((x, y), (x + SW, y + SW));
}

openpicker(x, y: int)
{
	img := win.image;
	if(img == nil)
		return;
	# center the grid on the click, clamped to the window
	x -= PANEL / 2;
	y -= PANEL / 2;
	if(x + PANEL > img.r.dx())
		x = img.r.dx() - PANEL;
	if(y + PANEL > img.r.dy())
		y = img.r.dy() - PANEL;
	if(x < 0)
		x = 0;
	if(y < 0)
		y = 0;
	pickr = Rect((x, y), (x + PANEL, y + PANEL));
	picking = 1;
	refresh();
}

ptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	x := p.xy.x - img.r.min.x;
	y := p.xy.y - img.r.min.y;
	b := p.buttons;
	ob := prevbtns;
	prevbtns = b;

	if(picking){
		# PopUpColor is modal: pick on button-1 release
		if((ob & 1) && !(b & 1)){
			picking = 0;
			for(i := 0; i < 16; i++)
				if(swatchrect(i).contains(Point(x, y))){
					color = i;
					break;
				}
			refresh();	# click outside cancels, keeps color
		}
		return;
	}

	if(b & 1){
		if(!rubber){
			# MSG_MS_L_DOWN: anchor the rubber band
			rubber = 1;
			ax = x;
			ay = y;
		}
		# MS_MOVE: re-preview the straight line anchor->cursor
		cx = x;
		cy = y;
		refresh();
	}else if(rubber){
		# MSG_MS_L_UP: commit one straight 7px segment
		rubber = 0;
		canvas.line(Point(ax, ay), Point(x, y),
			Draw->Enddisc, Draw->Enddisc, 3, ink[color], Point(0, 0));
		refresh();
	}else if((ob & 2) && !(b & 2)){
		# MSG_MS_R_UP: PopUpColor
		openpicker(x, y);
	}
}
