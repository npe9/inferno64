implement Elephantwalk;

# TempleOS Demo/Games/ElephantWalk.HC
#
#   Sprite3ZB(gr.dc,x,y,0,$IB,"<1>",BI=1$,Sin(8*tS)/4);
#
# Sprite3ZB's last argument is a rotation about z in RADIANS
# (Adam/Gr/GrSpritePlot.HC: it builds Mat4x4RotZ and hands it to
# Sprite3Mat4x4B), so the elephant is tilted by sin(8t)/4 - about
# fourteen degrees either way - each time it is drawn.  The original
# loop blocks in GetKey, so that is once per step: the elephant rocks as
# it walks, which is the whole of the joke and the whole of the title.
#
# Two more things the original does that are easy to miss.  The rotation
# is about the sprite's own origin, not the middle of its bitmap - the
# bin's rect is (-124,-100)-(95,136), so the origin sits near the
# elephant's shoulder - and the mirror is set only while walking RIGHT
# (x > x_last), so a vertical step clears it.  Steps are 32 pixels and
# wrap at the screen edge rather than stopping there.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Context, Display, Point, Rect, Image: import draw;

include "math.m";
	math: Math;

include "math/polyfill.m";
include "math/draw3d.m";
	draw3d: Draw3d;

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
xlast: int;
mirror := 0;
t0: int;

STEP: con 32;			# the original's cursor step

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
	math = load Math Math->PATH;
	# The device provider, for sprite2d: it sends the rotation or the
	# scale to the GPU as a textured quad instead of resampling it in
	# interpreted Limbo, and falls back to the same C resampler in
	# devdraw.c when the destination is not one the GPU can draw into.
	# 220x220 at 30 degrees measured 2725us a sprite through the Limbo
	# path and 65us through this one, end to end.  It degrades on its
	# own when there is no device, so the second load is only for the
	# .dis file being absent.
	draw3d = load Draw3d "/dis/math/draw3ddev.dis";
	if(draw3d == nil)
		draw3d = load Draw3d Draw3d->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	if(draw3d == nil){
		sys->fprint(sys->fildes(2), "elephantwalk: cannot load draw3d: %r\n");
		raise "fail:load";
	}
	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	draw3d->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	display = ctxt.display;

	menubut: chan of string;
	(top, menubut) = tkclient->toplevel(ctxt, "", "TempleOS ElephantWalk", 0);
	for(i := 0; i < len cfg; i++)
		cmd(top, cfg[i]);

	elephant = display.open("/icons/temple/elephantwalk_1.bit");
	emask = display.open("/icons/temple/elephantwalk_1.mask");
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
	xlast = x;
	t0 = sys->millisec();
	paint();

	for(;;) alt{
	s := <-top.ctxt.kbd =>
		tk->keyboard(top, s);
		case s {
		16r1b or 'q' or 'Q' =>
			exit;
		'a' or 'A' or Keyboard->Left =>
			x -= STEP;
		'd' or 'D' or Keyboard->Right =>
			x += STEP;
		'w' or 'W' or Keyboard->Up =>
			y -= STEP;
		's' or 'S' or Keyboard->Down =>
			y += STEP;
		}
		wrap();
		paint();
	s := <-top.ctxt.ptr =>
		tk->pointer(top, *s);
	s := <-top.ctxt.ctl or
	s = <-top.wreq or
	s = <-menubut =>
		tkclient->wmctl(top, s);
	}
}

# The original walks off one edge and back on the other:
#	if (x<0) x=Fs->pix_width;  if (x>Fs->pix_width) x=0;
wrap()
{
	if(x < 0)
		x = buffer.r.dx();
	if(x > buffer.r.dx())
		x = 0;
	if(y < 0)
		y = buffer.r.dy();
	if(y > buffer.r.dy())
		y = 0;
}

paint()
{
	# DCSymmetrySet(,x,y,x,y-1) with DCF_SYMMETRY|DCF_JUST_MIRROR is set
	# only while x is increasing, and the assignment x_last=x after it
	# means a vertical step clears it again.
	mirror = x > xlast;
	xlast = x;
	ang := math->sin(8.0 * real (sys->millisec() - t0) / 1000.0) / 4.0;
	buffer.draw(buffer.r, display.color(Draw->White), nil, Point(0, 0));
	# sprite2d places the middle of the bitmap, but the rotation and the
	# mirror are about the sprite's origin, so carry the origin-to-middle
	# offset through both and ask for the middle where it lands.
	ox := real elephant.r.min.x + real elephant.r.dx() / 2.0;
	oy := real elephant.r.min.y + real elephant.r.dy() / 2.0;
	if(mirror)
		ox = -ox;
	cs := math->cos(ang);
	sn := math->sin(ang);
	px := real x + ox*cs - oy*sn;
	py := real y + ox*sn + oy*cs;
	draw3d->sprite2d(buffer, Point(int px, int py), elephant, emask,
		elephant.r.dx(), elephant.r.dy(), ang*180.0/math->Pi, mirror);
	tk->putimage(top, ".f.p", buffer, nil);
	cmd(top, ".f.p dirty; update");
}

cmd(t: ref Toplevel, s: string)
{
	e := tk->cmd(t, s);
	if(e != nil && e[0] == '!')
		sys->fprint(sys->fildes(2), "elephantwalk: tk %s: %s\n", s, e);
}
