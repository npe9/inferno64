implement Massspring;

# TempleOS Demo/Games/MassSpring.HC — a mass-and-spring toy over the ODE
# solver.
#
# It opens with a PopUpOk, reproduced here verbatim, typo included:
#
#	"Left-Click to place mas\n"
#	"Right-Click and drag to\n"
#	"connect with spring.\n\n"
#	"Springs are 100 pixs long."
#
# The point of the demo is that everything after that is the solver's:
# masses and springs go into an ODE and it integrates them, so the drags
# and the acceleration limit are the only tuning there is.  Uses
# /dis/lib/ode.dis.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "math.m";
	math: Math;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";

include "rand.m";
	rand: Rand;

include "ode.m";
	ode: Ode;
	ODE, Mass, Spring: import ode;
include "grpalette.m";
	grpal: Grpalette;

Massspring: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
font: ref Font;
sim: ref ODE;
red, black, white, blue: ref Image;
help := 1;			# the opening PopUpOk
drag1: ref Mass;
lastl := 0;
lastr := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	ode = load Ode Ode->PATH;
	if(ode == nil){
		sys->fprint(sys->fildes(2), "massspring: cannot load %s: %r\n", Ode->PATH);
		raise "fail:load";
	}
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	ode->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS MassSpring", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	red = d.color(Draw->Red);
	black = d.color(Draw->Black);
	white = d.color(Draw->White);
	blue = d.color(grpal->value(Grpalette->BLUE));

	reset();
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 16);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		ptr(p);
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) == Keyboard->Keyup)
			continue;
		if(help){		# PopUpOk: any key dismisses it
			help = 0;
			redraw();
			continue;
		}
		case k {
		16r1b or 'q' or 'Q' =>
			exit;
		'\n' =>
			reset();
		}
	<-ticks =>
		if(help)
			continue;	# the PopUpOk holds the simulation
		step();
		redraw();
	}
}

reset()
{
	sim = ode->new();
	sim.drag_v2 = 0.002;
	sim.drag_v3 = 0.00001;
	sim.accel_limit = 5000.0;
	sim.h = 0.01;
	drag1 = nil;
	lastl = 0;
	lastr = 0;
}

ptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil || help)
		return;
	x := real(p.xy.x - img.r.min.x);
	y := real(p.xy.y - img.r.min.y);
	left := (p.buttons & 1) != 0;
	right := (p.buttons & 2) != 0;

	if(left && !lastl)
		place_mass(x, y);
	if(right && !lastr)
		drag1 = ode->massfind(sim, x, y, 0.0);
	if(!right && lastr){
		if(drag1 != nil){
			m2 := ode->massfind(sim, x, y, 0.0);
			if(m2 != nil && m2 != drag1)
				place_spring(drag1, m2);
		}
		drag1 = nil;
	}
	lastl = left;
	lastr = right;
}

place_mass(x, y: real)
{
	m := ref Mass(
		x, y, 0.0,
		0.0, 0.0, 0.0,
		0.0, 0.0, 0.0,
		1.0,
		100.0,
		0,
		0,
		10.0 * (rnreal() + 0.25),
		0
	);
	ode->addmass(sim, m);
}

place_spring(a, b: ref Mass)
{
	s := ref Spring(a, b, 10000.0, 100.0, 0.0, 0.0, 0, 0, 0);
	ode->addspring(sim, s);
}

step()
{
	ode->clearforces(sim);
	for(l1 := sim.masses; l1 != nil; l1 = tl l1){
		m1 := hd l1;
		for(l2 := tl l1; l2 != nil; l2 = tl l2){
			m2 := hd l2;
			dx := m2.x - m1.x;
			dy := m2.y - m1.y;
			dz := m2.z - m1.z;
			dd := dx*dx + dy*dy + dz*dz;
			rr := m1.radius + m2.radius;
			if(dd <= rr*rr){
				d := math->sqrt(dd) + 0.0001;
				gap := rr*rr - dd;
				g2 := gap*gap;
				g4 := g2*g2;
				g8 := g4*g4;
				force := 10.0 * g8;
				scale := force / d;
				fx := dx * scale;
				fy := dy * scale;
				fz := dz * scale;
				m2.fx += fx; m2.fy += fy; m2.fz += fz;
				m1.fx -= fx; m1.fy -= fy; m1.fz -= fz;
			}
		}
	}
	ode->update(sim, 0.016);
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, white, nil, Point(0, 0));
	o := img.r.min;
	for(ls := sim.springs; ls != nil; ls = tl ls){
		s := hd ls;
		if(s.end1 == nil || s.end2 == nil)
			continue;
		img.line(
			Point(int s.end1.x, int s.end1.y).add(o),
			Point(int s.end2.x, int s.end2.y).add(o),
			Draw->Endsquare, Draw->Endsquare, 0, red, Point(0, 0));
	}
	for(lm := sim.masses; lm != nil; lm = tl lm){
		m := hd lm;
		r := int m.radius;
		if(r < 2)
			r = 2;
		img.ellipse(Point(int m.x, int m.y).add(o), r, r, 0, black, Point(0, 0));
	}
	if(help)
		popup(img, o, img.r.dx(), img.r.dy());
	img.flush(Draw->Flushnow);
}

rnreal(): real
{
	if(rand == nil)
		return real(sys->millisec() & 255) / 255.0;
	return real(rand->rand(1000)) / 1000.0;
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}

# The original's opening PopUpOk, verbatim — "mas" is Terry's.
popup(img: ref Image, o: Point, w, h: int)
{
	lines := array[] of {
		"Left-Click to place mas",
		"Right-Click and drag to",
		"connect with spring.",
		"",
		"Springs are 100 pixs long.",
	};
	if(font == nil)
		return;
	pad := 12;
	tw := 0;
	for(i := 0; i < len lines; i++){
		lw := font.width(lines[i]);
		if(lw > tw)
			tw = lw;
	}
	bw := tw + 2*pad;
	bh := (len lines + 2)*(font.height+2) + 2*pad;
	bx := o.x + (w - bw)/2;
	by := o.y + (h - bh)/2;
	img.draw(Rect((bx-2, by-2), (bx+bw+2, by+bh+2)), black, nil, Point(0, 0));
	img.draw(Rect((bx, by), (bx+bw, by+bh)), white, nil, Point(0, 0));
	y := by + pad;
	for(i = 0; i < len lines; i++){
		img.text(Point(bx+pad, y), black, Point(0, 0), font, lines[i]);
		y += font.height + 2;
	}
	ok := "any key";
	img.text(Point(bx + (bw - font.width(ok))/2, y + font.height/2),
		blue, Point(0, 0), font, ok);
}
