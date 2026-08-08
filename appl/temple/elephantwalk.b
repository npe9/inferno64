implement Elephantwalk;

# TempleOS Demo/Games/ElephantWalk.HC
# coffee-style buffer + extracted /icons/temple/elephant.{bit,mask}
#
# GAP: Draw has no horizontal image flip; TempleOS mirrors the sprite when
# walking left. We translate only until geom/draw flip exists.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Context, Display, Point, Rect, Image: import draw;

include "tk.m";
	tk: Tk;
	Toplevel: import tk;

include "tkclient.m";
	tkclient: Tkclient;

include "keyboard.m";

Elephantwalk: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

display: ref Display;
top: ref Toplevel;
elephant, emask: ref Image;
buffer: ref Image;
x, y: int;

cfg := array[] of {
	"frame .f",
	"label .f.help -text {arrows/wasd move · q quit}",
	"panel .f.p -bd 1 -relief sunken",
	"pack .f.help -side top -fill x",
	"pack .f.p -side top -fill both -expand 1",
	"pack .f -fill both -expand 1",
};

init(ctxt: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	display = ctxt.display;

	menubut: chan of string;
	(top, menubut) = tkclient->toplevel(ctxt, "", "TempleOS ElephantWalk", 0);
	for(i := 0; i < len cfg; i++)
		cmd(top, cfg[i]);

	elephant = display.open("/icons/temple/elephant.bit");
	emask = display.open("/icons/temple/elephant.mask");
	if(elephant == nil || emask == nil){
		sys->fprint(sys->fildes(2), "elephantwalk: cannot open sprites: %r\n");
		raise "fail:sprites";
	}

	r := Rect((0, 0), (500, 360));
	buffer = display.newimage(r, display.image.chans, 0, Draw->White);
	if(buffer == nil){
		sys->fprint(sys->fildes(2), "elephantwalk: no buffer\n");
		raise "fail:buffer";
	}
	tk->putimage(top, ".f.p", buffer, nil);
	cmd(top, "update");
	tkclient->startinput(top, "ptr" :: "kbd" :: nil);
	tkclient->onscreen(top, nil);

	x = r.dx() / 2;
	y = r.dy() / 2;
	paint();

	for(;;) alt{
	s := <-top.ctxt.kbd =>
		tk->keyboard(top, s);
		case s {
		16r1b or 'q' or 'Q' =>
			exit;
		'a' or 'A' or Keyboard->Left =>
			x -= 8;
		'd' or 'D' or Keyboard->Right =>
			x += 8;
		'w' or 'W' or Keyboard->Up =>
			y -= 8;
		's' or 'S' or Keyboard->Down =>
			y += 8;
		}
		clamp();
		paint();
	s := <-top.ctxt.ptr =>
		tk->pointer(top, *s);
	s := <-top.ctxt.ctl or
	s = <-top.wreq or
	s = <-menubut =>
		tkclient->wmctl(top, s);
	}
}

clamp()
{
	hw := elephant.r.dx() / 2;
	hh := elephant.r.dy() / 2;
	if(x < hw) x = hw;
	if(y < hh) y = hh;
	if(x > buffer.r.dx() - hw) x = buffer.r.dx() - hw;
	if(y > buffer.r.dy() - hh) y = buffer.r.dy() - hh;
}

paint()
{
	buffer.draw(buffer.r, display.color(Draw->White), nil, Point(0, 0));
	p0 := Point(x - elephant.r.dx()/2, y - elephant.r.dy()/2);
	buffer.draw(elephant.r.addpt(p0), elephant, emask, elephant.r.min);
	tk->putimage(top, ".f.p", buffer, nil);
	cmd(top, ".f.p dirty; update");
}

cmd(t: ref Toplevel, s: string)
{
	e := tk->cmd(t, s);
	if(e != nil && e[0] == '!')
		sys->fprint(sys->fildes(2), "elephantwalk: tk %s: %s\n", s, e);
}
