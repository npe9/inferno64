implement Scrncapture;

# TempleOS Demo/Graphics/ScrnCapture.HC — the whole program is
#
#	"Capture scrn...\n";  PressAKey;
#	GRScrnCaptureWrite("~/DemoScrnShot");
#	"View captured scrn...\n"; PressAKey;
#	GRScrnCaptureRead("~/DemoScrnShot");
#	PressAKey; DCFill;
#
# Take a picture of the screen, put it in a file, and paint the file back
# over the screen.  The file's own comment points at
# Demo/Games/Stadium/StadiumGen.HC, which is how that game's background
# was made: capture a drawing once, ship the capture.
#
# GAP: an Inferno program can only read the pixels of its own window, so
#      this captures the window rather than the display.  The file is
#      /usr/$user/demoscrnshot in the image(6) format writeimage(2)
#      produces, which is the analogue of ~/DemoScrnShot.

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

include "env.m";
	env: Env;
include "grpalette.m";
	grpal: Grpalette;

Scrncapture: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
font: ref Font;
d: ref Display;
white, black, blue, red, green, yellow: ref Image;
shotfile: string;
stage := 0;		# 0 before capture, 1 captured, 2 painted back
note := "";
shot: ref Image;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	env = load Env Env->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS ScrnCapture", Wmclient->Appl);
	d = win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	white = d.color(grpal->value(Grpalette->WHITE));
	black = d.color(grpal->value(Grpalette->BLACK));
	blue = d.color(grpal->value(Grpalette->BLUE));
	red = d.color(grpal->value(Grpalette->RED));
	green = d.color(grpal->value(Grpalette->GREEN));
	yellow = d.color(grpal->value(Grpalette->YELLOW));

	user := "inferno";
	if(env != nil){
		u := env->getenv("user");
		if(u != nil && u != "")
			user = u;
	}
	shotfile = "/usr/" + user + "/demoscrnshot";

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
		if((k & Keyboard->Keyup) == Keyboard->Keyup)
			continue;
		case stage {
		0 =>	capture();  stage = 1;
		1 =>	readback(); stage = 2;
		* =>	exit;
		}
		redraw();
	}
}

# GRScrnCaptureWrite
capture()
{
	img := win.image;
	if(img == nil)
		return;
	fd := sys->create(shotfile, Sys->OWRITE, 8r666);
	if(fd == nil){
		note = sys->sprint("cannot create %s: %r", shotfile);
		return;
	}
	if(d.writeimage(fd, img) < 0)
		note = sys->sprint("writeimage: %r");
	else
		note = "captured to " + shotfile;
}

# GRScrnCaptureRead
readback()
{
	fd := sys->open(shotfile, Sys->OREAD);
	if(fd == nil){
		note = sys->sprint("cannot open %s: %r", shotfile);
		return;
	}
	shot = d.readimage(fd);
	if(shot == nil)
		note = sys->sprint("readimage: %r");
	else
		note = sys->sprint("read back %dx%d from %s",
			shot.r.dx(), shot.r.dy(), shotfile);
}

redraw()
{
	img := win.image;
	if(img == nil || font == nil)
		return;
	o := img.r.min;
	if(stage == 2 && shot != nil){
		# paint the capture back over the screen
		img.draw(img.r, white, nil, Point(0, 0));
		img.draw(shot.r.addpt(o), shot, nil, shot.r.min);
		img.text(Point(o.x, img.r.max.y - font.height), blue, Point(0, 0),
			font, note + "    any key exits");
		img.flush(Draw->Flushnow);
		return;
	}
	# something worth capturing
	img.draw(img.r, white, nil, Point(0, 0));
	img.draw(Rect((o.x+60, o.y+80), (o.x+240, o.y+200)), red, nil, Point(0,0));
	img.draw(Rect((o.x+160, o.y+140), (o.x+340, o.y+260)), green, nil, Point(0,0));
	img.ellipse(Point(o.x+420, o.y+170), 90, 60, 0, yellow, Point(0, 0));
	msg := "Capture scrn...";
	if(stage == 1)
		msg = "View captured scrn...";
	img.text(Point(o.x, o.y), black, Point(0, 0), font, msg);
	if(note != "")
		img.text(Point(o.x, o.y + font.height), blue, Point(0, 0), font, note);
	img.text(Point(o.x, img.r.max.y - font.height), blue, Point(0, 0), font,
		"any key continues");
	img.flush(Draw->Flushnow);
}
