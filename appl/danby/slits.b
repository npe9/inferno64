implement Slits;

# danby/slits - the double slit, actually solved
#
# danby-twoslit(1) draws the interference pattern from a formula: it
# assumes the answer's shape and fills in the numbers.  This solves the
# time-dependent Schrodinger equation on a grid and lets the pattern
# happen - one packet goes in, meets a wall with two gaps in it, and
# what comes out the far side is worked out and not assumed.
#
# It is worth having both.  The formula is exact and instant and tells
# you nothing about how the pattern arrives; this is approximate and
# slow and shows the wave going through BOTH slits, which is the part
# that has no classical account and the part a formula cannot draw.
#
# The right-hand strip is the screen, and it ACCUMULATES.  Each step
# adds however much probability is passing the screen column at that
# moment, so the fringes build up over the run the way a real pattern
# builds up from arrivals rather than appearing all at once.
#
# The equation is /lib/danby/slits.pde and not code in here, so it can
# be changed without a compiler.  See danby-slits(1) for what the
# controls do and pde(2) for the spec language.

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Font, Point, Rect: import draw;
include "tk.m";
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "math.m";
	math: Math;
include "pde.m";
	pde: Pde;
include "env.m";
	env: Env;

Slits: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

SPECFILE: con "/lib/danby/slits.pde";

win: ref Window;
font: ref Font;
bg, fg, grid, inkcol, wallcol, screencol: ref Image;
fieldim: ref Image;
pix: array of byte;
ramp: array of int;			# the colour ramp, as packed rgb
RAMPN: con 48;

prob: ref Pde->Problem;
screen: array of real;			# what has passed the screen column
t := 0.0;
paused := 0;
peak := 1.0;

# the packet, and the things the keys move
k0 := 6.0;
sep := 3.6;
slitw := 0.5;
vwall := 90.0;
oneslit := 0;			# block one of them, and watch the fringes go

nx, ny: int;
dx, dy: real;
xw := 9.0;

readspec(): string
{
	iob := bufio->open(SPECFILE, Bufio->OREAD);
	if(iob == nil){
		sys->fprint(sys->fildes(2), "danby/slits: %s: %r\n", SPECFILE);
		raise "fail:spec";
	}
	s := "";
	while((l := iob.gets('\n')) != nil)
		s += l;
	return s;
}

reset()
{
	(p, err) := pde->newproblem(readspec());
	if(err != nil){
		sys->fprint(sys->fildes(2), "danby/slits: %s\n", err);
		raise "fail:spec";
	}
	prob = p;
	nx = p.field.nx;
	ny = p.field.ny;
	dx = p.field.dx;
	dy = p.field.dy;
	xw = p.hocmod->symbol("xw").val;
	yc := real ny*dy/2.0;
	# the controls, into the problem's own variables
	p.hocmod->setvar("v0", vwall);
	# With one slit blocked the other is moved right out of the domain
	# rather than closed, because closing it means making its step()
	# zero, and the two step()s are ADDED: setting both to the same
	# place would give 2 inside it, and 1-2 is a well rather than a
	# hole.  A slit nobody can reach is the honest way to have one.
	p.hocmod->setvar("ya", yc + sep/2.0);
	if(oneslit)
		p.hocmod->setvar("yb", yc + 1000.0);
	else
		p.hocmod->setvar("yb", yc - sep/2.0);
	p.hocmod->setvar("sw", slitw);
	# a packet wide in y - it has to cover both slits at once, which is
	# the whole point - and narrow in x so it arrives as one pulse
	(x0, sgx, sgy) := (4.0, 1.0, 3.0);
	peak = 0.0;
	for(i := 0; i < nx; i++){
		x := real i*dx;
		for(j := 0; j < ny; j++){
			y := real j*dy;
			g := math->exp(-(x-x0)*(x-x0)/(4.0*sgx*sgx) -
				(y-yc)*(y-yc)/(4.0*sgy*sgy));
			pde->set(prob.field, i, j, g*math->cos(k0*x));
			pde->set(prob.fieldb, i, j, g*math->sin(k0*x));
			if(g*g > peak)
				peak = g*g;
		}
	}
	if(peak <= 0.0)
		peak = 1.0;
	screen = array[ny] of real;
	for(j := 0; j < ny; j++)
		screen[j] = 0.0;
	t = 0.0;
}

# the column the screen sits in, just inside the far boundary
scol(): int
{
	c := nx - 8;
	if(c < 1)
		c = 1;
	return c;
}

step()
{
	pde->step(prob, 0.01);
	t += 0.01;
	c := scol();
	for(j := 0; j < ny; j++){
		u := pde->get(prob.field, c, j);
		v := pde->get(prob.fieldb, c, j);
		screen[j] += u*u + v*v;
	}
}

census()
{
	reset();
	for(s := 0; s < 240; s++)
		step();
	tot := 0.0;
	for(j := 0; j < ny; j++)
		tot += screen[j];
	how := "two slits";
	if(oneslit)
		how = "ONE slit";
	sys->print("mesh %dx%d  %s, separation %.2f, width %.2f, wall %.4g\n",
		nx, ny, how, sep, slitw, vwall);
	if(tot <= 0.0){
		sys->print("nothing reached the screen\n");
		return;
	}
	n := 0;
	for(j = 2; j < ny-2; j++)
		if(screen[j] > screen[j-1] && screen[j] > screen[j+1] &&
		   screen[j] > 0.02*tot/real ny*real ny/8.0)
			n++;
	sys->print("maxima on the screen: %d\n", n);
	for(j = 0; j < ny; j += 4){
		b := int(screen[j]/tot*real ny*18.0);
		bar := "";
		for(q := 0; q < b && q < 56; q++)
			bar[len bar] = '#';
		sys->print("  y %5.2f %s\n", real j*dy, bar);
	}
}

init(ctxt: ref Draw->Context, argv: list of string)
{
	# maths before graphics: emu-g has no Draw, and a program that
	# loads it first cannot be checked where there is no display
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	math = load Math Math->PATH;
	pde = load Pde Pde->PATH;
	if(sys == nil || bufio == nil || math == nil || pde == nil)
		raise "fail:slits: missing module";
	pde->init();
	args := array[len argv] of string;
	na := 0;
	for(a := tl argv; a != nil; a = tl a)
		args[na++] = hd a;
	cflag := 0;
	for(i := 0; i < na; i++){
		case args[i] {
		"-c" => cflag = 1;
		"-s" => if(i+1 < na) sep = real args[++i];
		"-w" => if(i+1 < na) slitw = real args[++i];
		"-v" => if(i+1 < na) vwall = real args[++i];
		"-one" => oneslit = 1;
		}
	}
	if(cflag){
		census();
		return;
	}
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	env = load Env Env->PATH;
	if(draw == nil || wmclient == nil)
		raise "fail:slits: no display";
	if(env != nil){
		env->clone();
		env->setenv("wmman", "danby-slits");
	}
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "The double slit, solved", Wmclient->Appl);
	font = Font.open(win.display, "/fonts/lucida/unicode.8.font");
	bg = win.display.color(int 16rf4f0e7ff);
	fg = win.display.color(int 16r20272cff);
	grid = win.display.color(int 16rd6d0c4ff);
	inkcol = win.display.color(int 16r178f86ff);
	wallcol = win.display.color(int 16rb85c38ff);
	screencol = win.display.color(int 16r7b5aa6ff);
	reset();
	buildramp();
	fieldim = win.display.newimage(Rect((0,0),(nx,ny)), Draw->RGB24, 0, 0);
	pix = array[nx*ny*3] of byte;
	win.reshape(Rect((0,0),(nx+210, ny+70)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	ticks := chan of int;
	spawn timer(ticks);
	redraw();
	for(;;) alt {
	c := <-win.ctl or c = <-win.ctxt.ctl =>
		win.wmctl(c);
		redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		key(k);
	<-ticks =>
		if(!paused)
			step();
		redraw();
	}
}

key(k: int)
{
	case k {
	16r1b or 'q' or 'Q' =>
		win.wmctl("exit");
		exit;
	' ' =>
		paused = !paused;
	'r' or 'R' =>
		reset();
	's' =>
		if(sep < real ny*dy*0.6){ sep += 0.4; reset(); }
	'S' =>
		if(sep > 0.8){ sep -= 0.4; reset(); }
	'w' =>
		if(slitw < 2.0){ slitw += 0.1; reset(); }
	'W' =>
		if(slitw > 0.2){ slitw -= 0.1; reset(); }
	'o' or 'O' =>
		oneslit = !oneslit;
		reset();
	'v' =>
		if(vwall < 90.0){ vwall += 10.0; reset(); }
	'V' =>
		if(vwall > 10.0){ vwall -= 10.0; reset(); }
	}
	redraw();
}

timer(c: chan of int)
{
	for(;;){
		sys->sleep(20);
		c <-= 1;
	}
}

# paper to ink, precomputed, because the alternative is a colour
# allocation per cell per frame
buildramp()
{
	ramp = array[RAMPN] of int;
	(br, bgc, bb) := (16rf4, 16rf0, 16re7);
	(ir, ig, ib) := (16r0e, 16r3b, 16r38);
	for(i := 0; i < RAMPN; i++){
		f := real i/real(RAMPN-1);
		f = math->sqrt(f);		# so the faint parts are visible
		r := int(real br + (real ir - real br)*f);
		g := int(real bgc + (real ig - real bgc)*f);
		b := int(real bb + (real ib - real bb)*f);
		ramp[i] = (r<<16)|(g<<8)|b;
	}
}

redraw()
{
	im := win.image;
	if(im == nil)
		return;
	im.draw(im.r, bg, nil, Point(0,0));
	r := im.r;
	fr := Rect(r.min.add((8,26)), r.min.add((8+nx, 26+ny)));

	# the field, built as one byte array and blitted in one call: a
	# draw per cell would be forty thousand of them a frame.  RGB24 is
	# stored blue first - checked, not assumed.
	mx := 0.0;
	i, j: int;
	for(i = 0; i < nx; i++)
		for(j = 0; j < ny; j++){
			u := pde->get(prob.field, i, j);
			v := pde->get(prob.fieldb, i, j);
			d := u*u+v*v;
			if(d > mx)
				mx = d;
		}
	if(mx <= 0.0)
		mx = 1.0;
	for(j = 0; j < ny; j++){
		# row 0 is y = 0, which belongs at the BOTTOM of the picture
		row := (ny-1-j)*nx*3;
		for(i = 0; i < nx; i++){
			u := pde->get(prob.field, i, j);
			v := pde->get(prob.fieldb, i, j);
			q := int((u*u+v*v)/mx*real(RAMPN-1));
			if(q < 0)
				q = 0;
			if(q >= RAMPN)
				q = RAMPN-1;
			c := ramp[q];
			o := row + i*3;
			pix[o] = byte (c & 16rff);
			pix[o+1] = byte ((c>>8) & 16rff);
			pix[o+2] = byte ((c>>16) & 16rff);
		}
	}
	fieldim.writepixels(fieldim.r, pix);
	im.draw(fr, fieldim, nil, fieldim.r.min);

	# the wall, drawn over the field so its gaps are visible
	wx := fr.min.x + int(xw/(real nx*dx)*real nx);
	yc := real ny*dy/2.0;
	drawwall(im, fr, wx, yc);

	# the screen, accumulating
	sr := Rect((fr.max.x+16, fr.min.y), (r.max.x-8, fr.max.y));
	drawscreen(im, sr);

	st := "running";
	if(paused)
		st = "paused";
	im.text(r.min.add((8,12)), fg, Point(0,0), font,
		sys->sprint("%s   t %.2f   %s   separation %.2g   width %.2g   wall %.4g   (o one slit, s/S w/W v/V, r restarts)",
			st, t, slitword(), sep, slitw, vwall));
	im.text((fr.max.x+16, fr.max.y+14), fg, Point(0,0), font, "the screen, accumulating");
	im.flush(Draw->Flushnow);
}

slitword(): string
{
	if(oneslit)
		return "ONE slit";
	return "two slits";
}

drawwall(im: ref Image, fr: Rect, wx: int, yc: real)
{
	ytop := yc + sep/2.0;
	ybot := yc - sep/2.0;
	if(oneslit)
		ybot = yc + 1000.0;
	for(j := 0; j < ny; j++){
		y := real j*dy;
		da := y-ytop;
		if(da < 0.0)
			da = -da;
		db := y-ybot;
		if(db < 0.0)
			db = -db;
		if(da < slitw || db < slitw)
			continue;		# a gap: leave the field showing
		py := fr.max.y - 1 - j;
		im.draw(Rect((wx-2,py),(wx+3,py+1)), wallcol, nil, Point(0,0));
	}
}

drawscreen(im: ref Image, sr: Rect)
{
	im.draw(Rect((sr.min.x,sr.min.y),(sr.min.x+1,sr.max.y)), grid, nil, Point(0,0));
	mx := 0.0;
	j: int;
	for(j = 0; j < ny; j++)
		if(screen[j] > mx)
			mx = screen[j];
	if(mx <= 0.0)
		return;
	w := sr.dx()-4;
	for(j = 0; j < ny; j++){
		py := sr.max.y - 1 - j;
		if(py < sr.min.y)
			continue;
		b := int(screen[j]/mx*real w);
		if(b < 1)
			continue;
		im.draw(Rect((sr.min.x+1,py),(sr.min.x+1+b,py+1)), screencol, nil, Point(0,0));
	}
}
