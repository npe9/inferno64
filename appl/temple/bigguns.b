implement Bigguns;

# TempleOS Demo/Games/BigGuns.HC — artillery over the ODE solver, and a
# lecture on fixed point: the terrain is generated with the elevation
# held as a 32.32 fixed-point number and only its integer half kept.
#
# Two PopUpOks open it, both reproduced here: Terry's "I refuse to
# rip-off the original", and then "The map scrolls."
#
# A shot hits when its own circle touches the map, not when its centre
# passes a number:
#
#	map->color=ROP_COLLISION;
#	map->bkcolor=LTCYAN;
#	map->collision_cnt=0;
#	GrCircle(map,tmpm->x,tmpm->y,2);
#	if (map->collision_cnt) tmpm->collision=TRUE;
#
# a circle drawn in a raster op that paints nothing and counts the pixels
# it would have set that are not the sky colour.  The map holds nothing
# but the terrain, so that reduces exactly to asking whether any point of
# a radius-2 circle is at or below elevs[] — which is what is done here,
# rather than the centre test the port used to have.
#
# Craters are cut into elevs and the map is redrawn, so the ground a
# later shot lands on is the ground the earlier ones left.
#
# GAP: no map scroll widgets; the view is moved with , and . instead.
# left/right aim  space=fire  Enter=restart  q=quit

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "math.m";
	math: Math;

include "math/polyfill.m";
include "math/draw3d.m";
	draw3d: Draw3d;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";

include "rand.m";
	rand: Rand;

include "ode.m";
	ode: Ode;
	ODE, Mass: import ode;

include "tone.m";
	tone: Tone;

Bigguns: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

MAPW: con 2048;			# MAP_WIDTH
MAPH: con 400;			# MAP_HEIGHT
DUST: con 512;			# DUST_NUM
PI: con 3.141592653589793;

win: ref Window;
font: ref Font;
sim: ref ODE;
ink: array of ref Image;
help := 2;			# the two opening PopUpOks
guns, gunmasks: array of ref Image;
elevs: array of int;
dustx, dusty: array of int;
gunx, guny: int;
gunang := 0.0;	# radians, 0=right, -PI=left, typically negative for up-left/right
recoil := 0;
wind := 0.0;
camx := 0;
have_tone := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	draw3d = load Draw3d Draw3d->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	ode = load Ode Ode->PATH;
	tone = load Tone Tone->PATH;
	if(ode == nil || draw3d == nil){
		sys->fprint(sys->fildes(2), "bigguns: no ode\n");
		raise "fail:load";
	}
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	ode->init();
	draw3d->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS BigGuns", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	# the exact TempleOS 16-colour palette, index = TempleOS colour: the
	# sky is LTCYAN, the ground BROWN, the dust LTGRAY
	ink = array[16] of ref Image;
	cols := array[] of {
		int 16r000000FF, int 16r0000AAFF, int 16r00AA00FF, int 16r00AAAAFF,
		int 16rAA0000FF, int 16rAA00AAFF, int 16rAA5500FF, int 16rAAAAAAFF,
		int 16r555555FF, int 16r5555FFFF, int 16r55FF55FF, int 16r55FFFFFF,
		int 16rFF5555FF, int 16rFF55FFFF, int 16rFFFF55FF, int 16rFFFFFFFF
	};
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);
	guns = array[3] of ref Image;
	gunmasks = array[3] of ref Image;
	for(i = 1; i <= 2; i++){
		guns[i] = d.open(sys->sprint("/icons/temple/bigguns_%d.bit", i));
		gunmasks[i] = d.open(sys->sprint("/icons/temple/bigguns_%d.mask", i));
	}

	elevs = array[MAPW] of int;
	dustx = array[DUST] of int;
	dusty = array[DUST] of int;
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
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) == Keyboard->Keyup)
			continue;
		if(help){		# PopUpOk: any key dismisses one
			help--;
			redraw();
			continue;
		}
		key(k);
	<-ticks =>
		if(help)
			continue;	# the PopUpOks hold the game
		if(recoil > 0)
			recoil--;
		step();
		manage();
		redraw();
	}
}

reset()
{
	sim = ode->new();
	sim.drag_v2 = 0.002;
	sim.drag_v3 = 0.0001;
	sim.accel_limit = 5e5;
	sim.h = 0.005;
	y := 0.7 * real MAPH;
	dy := 0.0;
	for(x := 0; x < MAPW; x++){
		s := 1.0;
		if(rn(2) == 0)
			s = -1.0;
		dy = clamp(dy + s * 0.4, -3.0, 3.0);
		y = clamp(y + dy, 0.3*real MAPH, real(MAPH-2));
		elevs[x] = int y;
	}
	gunx = 50 + rn(MAPW - 100);
	guny = elevs[gunx];
	for(x = gunx - 20; x <= gunx + 20; x++)
		if(x >= 0 && x < MAPW)
			elevs[x] = guny;
	gunang = -PI/4.0;
	recoil = 0;
	wind = real(rn(200) - 100) / 250.0;
	for(i := 0; i < DUST; i++){
		dustx[i] = rn(MAPW);
		dusty[i] = rn(MAPH);
	}
	camx = gunx - vieww()/2;
	clampcam();
}

key(k: int)
{
	case k {
	16r1b or 'q' or 'Q' =>
		exit;
	'\n' =>
		reset();
	' ' =>
		fire();
	Keyboard->Left or 'a' or 'A' =>
		gunang -= 2.0*PI/180.0;
		if(gunang < -PI)
			gunang = -PI;
	Keyboard->Right or 'd' or 'D' =>
		gunang += 2.0*PI/180.0;
		if(gunang > 0.0)
			gunang = 0.0;
	',' =>
		camx -= 20;
		clampcam();
	'.' =>
		camx += 20;
		clampcam();
	}
}

fire()
{
	if(recoil > 0)
		return;
	c := math->cos(gunang);
	s := math->sin(gunang);
	m := ref Mass(
		real gunx + 27.0*c, real guny + 27.0*s, 0.0,
		600.0*c, 600.0*s, 0.0,
		0.0, 0.0, 0.0,
		10.0, 0.1, 0, 0, 2.0, 0
	);
	ode->addmass(sim, m);
	recoil = 12;
	if(have_tone)
		tone->beep(40 + rn(50), 80);
}

step()
{
	ode->clearforces(sim);
	for(l := sim.masses; l != nil; l = tl l){
		m := hd l;
		m.fy += 1000.0 * m.mass;	# gravity down (+y)
		m.fx += 25.0 * wind * m.mass;
	}
	ode->update(sim, 0.016);
}

# TempleOS's Sprite3 family places a sprite by its ORIGIN - the (0,0) of
# the bin's own rectangle - and turns it about that point.  draw3d's
# sprite2d places the middle of the bitmap, so carry the origin-to-middle
# offset through the mirror and the rotation and ask for the middle where
# it lands.  Getting this wrong shifts a sprite by however far its origin
# sits from its centre, which for bigguns_1 is eighteen pixels.
sprorigin(img: ref Image, x, y: int, spr, msk: ref Image, deg: real, flipx: int)
{
	if(spr == nil)
		return;
	ox := real spr.r.min.x + real spr.r.dx() / 2.0;
	oy := real spr.r.min.y + real spr.r.dy() / 2.0;
	if(flipx)
		ox = -ox;
	rad := deg * PI / 180.0;
	cs := math->cos(rad);
	sn := math->sin(rad);
	draw3d->sprite2d(img, Point(x + int (ox*cs - oy*sn), y + int (ox*sn + oy*cs)),
		spr, msk, spr.r.dx(), spr.r.dy(), deg, flipx);
}

manage()
{
	kill: list of ref Mass;
	for(l := sim.masses; l != nil; l = tl l){
		m := hd l;
		ix := int m.x;
		hit := 0;
		if(ix < 0 || ix >= MAPW)
			hit = 1;
		else if(collides(int m.x, int m.y))
			hit = 1;
		if(hit)
			kill = m :: kill;
	}
	for(k := kill; k != nil; k = tl k){
		m := hd k;
		ix := int m.x;
		for(i := ix - 4; i <= ix + 4; i++)
			if(i >= 0 && i < MAPW){
				d := i - ix;
				if(d < 0) d = -d;
				elevs[i] = clampi(elevs[i] + 10 - 2*d, 0, MAPH-2);
			}
		ode->remmass(sim, m);
		if(have_tone)
			tone->beep(20, 40);
	}
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	# sky
	img.draw(img.r, ink[11], nil, Point(0, 0));	# LTCYAN
	# terrain silhouette
	for(x := 0; x < w; x++){
		mx := camx + x;
		if(mx < 0 || mx >= MAPW)
			continue;
		ey := elevs[mx];
		if(ey < h)
			img.draw(Rect((o.x+x, o.y+ey), (o.x+x+1, o.y+h)), ink[6], nil, Point(0, 0));
		if(ey > 0 && ey < h)
			img.draw(Rect((o.x+x, o.y+ey), (o.x+x+1, o.y+ey+1)), ink[0], nil, Point(0, 0));
	}
	# dust
	wx := int(real(sys->millisec()) * wind / 50.0);
	for(i := 0; i < DUST; i++){
		dx := (dustx[i] + wx) % MAPW;
		if(dx < 0) dx += MAPW;
		dy := dusty[i];
		if(dy < elevs[dx]){
			sx := dx - camx;
			if(sx >= 0 && sx < w && dy < h)
				img.draw(Rect((o.x+sx, o.y+dy), (o.x+sx+1, o.y+dy+1)), ink[7], nil, Point(0, 0));	# LTGRAY
		}
	}
	# gun base
	gx := gunx - camx;
	gy := guny;
	if(gx >= -40 && gx < w + 40){
		c := math->cos(gunang);
		s := math->sin(gunang);
		bx := real gx - real recoil * c;
		by := real gy - real recoil * s;
		if(guns[2] != nil)
			# Sprite3(dc,gun_x+h,gun_y+v,0,<2>): placed by the sprite's
			# own origin, which for bin 2 is (-14,-18) into its bitmap.
			# The -5 that used to be here was a fudge for the same thing.
			sprorigin(img, o.x+gx, o.y+gy, guns[2], gunmasks[2], 0.0, 0);
		else
			img.fillellipse(Point(o.x+gx, o.y+gy), 8, 6, ink[0], Point(0, 0));
		if(guns[1] != nil){
			# Sprite3ZB(dc,gun_x+h-recoil*Cos(a),gun_y+v-recoil*Sin(a)-10,
			#           0,<1>,a), with a mirror while aiming left:
			#
			#   if (a<-PI/2) { DCF_SYMMETRY|DCF_JUST_MIRROR;
			#                  DCSymmetrySet(dc,gun_x+h,0,gun_x+h,1);
			#                  a=-a-PI; }
			#
			# The symmetry plane is the vertical through the gun, applied
			# to what the rotation produced.  Reflecting a rotation about
			# a vertical axis is the same as reflecting the source and
			# turning the other way (M.R(a) = R(-a).M), so the mirrored
			# branch is a flipped sprite at -a with its origin reflected
			# through the gun's x - which is what the arithmetic below
			# does, rather than mirroring the finished frame.
			a := gunang;
			flip := 0;
			if(a < -PI/2.0){
				a = -a - PI;
				flip = 1;
			}
			ac := math->cos(a);
			as := math->sin(a);
			ox := real gx - real recoil * ac;
			oy := real gy - real recoil * as - 10.0;
			if(flip){
				ox = 2.0 * real gx - ox;
				a = -a;
			}
			sprorigin(img, o.x+int ox, o.y+int oy, guns[1], gunmasks[1],
				a*180.0/PI, flip);
		}else{
			ex := bx + 30.0*c;
			ey := by + 30.0*s;
			img.line(Point(o.x+int bx, o.y+int by), Point(o.x+int ex, o.y+int ey),
				0, 0, 2, ink[0], Point(0, 0));
		}
	}
	# shots
	for(l := sim.masses; l != nil; l = tl l){
		m := hd l;
		sx := int m.x - camx;
		sy := int m.y;
		if(sx >= 0 && sx < w && sy >= 0 && sy < h)
			img.fillellipse(Point(o.x+sx, o.y+sy), 2, 2, ink[0], Point(0, 0));
	}
	if(help)
		popup(img, o, w, h);
	img.flush(Draw->Flushnow);
}

clamp(v, lo, hi: real): real
{
	if(v < lo) return lo;
	if(v > hi) return hi;
	return v;
}

clampi(v, lo, hi: int): int
{
	if(v < lo) return lo;
	if(v > hi) return hi;
	return v;
}

rn(n: int): int
{
	if(n <= 0) return 0;
	if(rand == nil) return sys->millisec() % n;
	return rand->rand(n);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}

# ROP_COLLISION with bkcolor=LTCYAN, for GrCircle(map,x,y,2): the map has
# nothing on it but the ground, so a pixel of the circle is a collision
# exactly when it is at or below elevs[].
collides(x, y: int): int
{
	for(dx := -2; dx <= 2; dx++){
		d := 2*2 - dx*dx;
		dy := 0;
		while(dy*dy <= d)
			dy++;
		dy--;
		cx := x + dx;
		if(cx < 0 || cx >= MAPW)
			continue;	# GrCircle clips; leaving is ManageShots'
					# own bounds test, not a collision
		if(y + dy >= elevs[cx])
			return 1;
	}
	return 0;
}

# The two opening PopUpOks, verbatim.  help counts down, so the first
# key shows the second panel and the second starts the game.
popup(img: ref Image, o: Point, w, h: int)
{
	lines := array[] of {"The map scrolls."};
	if(help > 1)
		lines = array[] of {
			"I refuse to rip-off the original",
			"so this is intentionally crappy",
			"and included for demonstration",
			"purposes.",
			"",
			"Write games, don't play them.",
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
	img.draw(Rect((bx-2, by-2), (bx+bw+2, by+bh+2)), ink[0], nil, Point(0, 0));
	img.draw(Rect((bx, by), (bx+bw, by+bh)), ink[15], nil, Point(0, 0));
	y := by + pad;
	for(i = 0; i < len lines; i++){
		img.text(Point(bx+pad, y), ink[0], Point(0, 0), font, lines[i]);
		y += font.height + 2;
	}
	ok := "any key";
	img.text(Point(bx + (bw - font.width(ok))/2, y + font.height/2),
		ink[1], Point(0, 0), font, ok);
}

# horz_scroll.min=0, horz_scroll.max=MAP_WIDTH-pix_width
vieww(): int
{
	img := win.image;
	if(img == nil)
		return 640;
	return img.r.dx();
}

clampcam()
{
	hi := MAPW - vieww();
	if(hi < 0)
		hi = 0;
	if(camx > hi)
		camx = hi;
	if(camx < 0)
		camx = 0;
}
