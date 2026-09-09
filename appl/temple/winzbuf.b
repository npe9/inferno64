implement Winzbuf;

# TempleOS Demo/Graphics/WinZBuf.HC — who owns each cell of the screen.
#
#	DrawIt: U16 *ptr=gr.win_z_buf;
#	        dc->color=BLACK;
#	        GrPrint(dc,0,0,"Move the windows around and watch.");
#	        for (i=0;i<TEXT_ROWS;i++)
#	          for (j=0;j<TEXT_COLS;j++) {
#	            dc->color=*ptr++&15;
#	            GrPlot(dc,j,i+FONT_HEIGHT);
#	          }
#
# Twelve lines that print the window manager's mind.  TempleOS keeps one
# U16 for every character cell of the screen saying which window owns it,
# and compositing is a lookup in that array rather than a walk of a window
# list.  The demo plots the array one pixel to the cell, so the picture in
# the corner is a little map of the desktop: move a window and its patch
# moves.
#
# GAP: wm(1) does not expose an equivalent, and cannot — Inferno windows
#      composite through the draw device, and a client can see only its
#      own image.  So this port owns the windows it maps: drag the three
#      panes and the map below them updates the same way.  The idea is the
#      original's; the scope is one window instead of the display.

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

Winzbuf: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

FW: con 8;
FH: con 8;
NWIN: con 3;

win: ref Window;
font: ref Font;
ink: array of ref Image;
wr: array of Rect;		# the panes, in cell coordinates
zbuf: array of int;		# one owner per cell, as gr.win_z_buf is
cols, rows: int;
drag := -1;
dragoff: Point;

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
	win = wmclient->window(ctxt, "TempleOS WinZBuf", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	ink = array[16] of ref Image;
	c := grpal->values();
	for(i := 0; i < 16; i++)
		ink[i] = d.color(c[i]);

	wr = array[NWIN] of Rect;
	wr[0] = Rect(( 4, 6), (28, 22));
	wr[1] = Rect((16,12), (44, 30));
	wr[2] = Rect((30, 4), (52, 20));

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
		if((k & Keyboard->Keyup) != Keyboard->Keyup)
			exit;
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		img := win.image;
		if(img == nil)
			continue;
		cx := (p.xy.x - img.r.min.x) / FW;
		cy := (p.xy.y - img.r.min.y) / FH;
		if(p.buttons & 1){
			if(drag < 0){
				# topmost pane under the pointer, as a click picks
				for(wi := NWIN-1; wi >= 0; wi--)
					if(Point(cx, cy).in(wr[wi])){
						drag = wi;
						dragoff = Point(cx - wr[wi].min.x,
							cy - wr[wi].min.y);
						break;
					}
			}else{
				dx := wr[drag].dx();
				dy := wr[drag].dy();
				nx := cx - dragoff.x;
				ny := cy - dragoff.y;
				wr[drag] = Rect((nx, ny), (nx+dx, ny+dy));
				redraw();
			}
		}else
			drag = -1;
	}
}

# gr.win_z_buf: the owning window of every cell, later windows on top
buildz()
{
	zbuf = array[cols*rows] of { * => 0 };
	for(i := 0; i < NWIN; i++)
		for(y := wr[i].min.y; y < wr[i].max.y; y++)
			for(x := wr[i].min.x; x < wr[i].max.x; x++)
				if(x >= 0 && x < cols && y >= 0 && y < rows)
					zbuf[y*cols + x] = i + 1;
}

redraw()
{
	img := win.image;
	if(img == nil || font == nil)
		return;
	o := img.r.min;
	cols = img.r.dx() / FW;
	rows = (img.r.dy() - 8*FH) / FH;
	if(cols <= 0 || rows <= 0)
		return;
	buildz();
	img.draw(img.r, ink[15], nil, Point(0, 0));

	# the panes themselves, in the colours the map uses
	for(i := 0; i < NWIN; i++){
		r := Rect((o.x + wr[i].min.x*FW, o.y + wr[i].min.y*FH),
			(o.x + wr[i].max.x*FW, o.y + wr[i].max.y*FH));
		img.draw(r, ink[(i+1) & 15], nil, Point(0, 0));
		img.text(r.min.add(Point(3, 3)), ink[0], Point(0, 0), font,
			sys->sprint("window %d", i+1));
	}

	img.text(o, ink[0], Point(0, 0), font,
		"Move the windows around and watch.");

	# the z-buffer, one pixel to the cell, in the corner
	mx := o.x;
	my := img.r.max.y - 7*FH;
	img.draw(Rect((mx-1, my-1), (mx+cols+1, my+rows+1)), ink[8], nil, Point(0,0));
	for(y := 0; y < rows; y++)
		for(x := 0; x < cols; x++)
			img.draw(Rect((mx+x, my+y), (mx+x+1, my+y+1)),
				ink[zbuf[y*cols + x] & 15], nil, Point(0, 0));
	img.text(Point(o.x, img.r.max.y - font.height), ink[1], Point(0, 0), font,
		"one pixel per character cell; drag a window.  Any key exits.");
	img.flush(Draw->Flushnow);
}
