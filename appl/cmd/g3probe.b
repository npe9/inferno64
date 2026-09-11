implement G3probe;

# Draw one quad at a series of depths, through fillpoly3 and through
# fillpoly3g, and count what lands.  The question is narrow: does the
# per-vertex entry point put a face in the same place as the flat one?
include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;
include "tk.m";
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "math/polyfill.m";
include "math/draw3d.m";

G3probe: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

win: ref Window;
d: ref Display;
dumpnext := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "g3probe", Wmclient->Appl);
	win.reshape(Rect((0,0),(640,480)));
	win.onscreen("place");
	d = win.display;
	sys->print("window image r=%d,%d..%d,%d  clipr=%d,%d..%d,%d\n",
		win.image.r.min.x, win.image.r.min.y, win.image.r.max.x, win.image.r.max.y,
		win.image.clipr.min.x, win.image.clipr.min.y,
		win.image.clipr.max.x, win.image.clipr.max.y);
	zs := array[] of {-6.0, -3.0, -2.0, -1.5, -1.2, -1.0};
	sys->print("%-28s %8s %8s %8s %8s\n", "provider", "z", "flat", "gouraud", "equal");
	one(Draw3d->PATH, "software", zs);
	one("/dis/math/draw3ddev.dis", "device", zs);

	# The depth test, which is what gorge(1) leans on: a near green quad
	# and a far red one, drawn in both orders, through both projections.
	# With a working z-buffer the order must not matter.
	sys->print("\n%-12s %-10s %-12s %8s %8s\n",
		"provider", "proj", "order", "red", "green");
	occ(Draw3d->PATH, "software", 0);
	occ("/dis/math/draw3ddev.dis", "device", 0);
	occ(Draw3d->PATH, "software", 1);
	occ("/dis/math/draw3ddev.dis", "device", 1);

	# Scale.  gorge(1) draws about two hundred faces a frame and is
	# wrong through Metal; everything above is a handful and is right.
	sys->print("\n%-12s %8s %10s %12s\n", "provider", "faces", "lit", "hash");
	for(n := 1; n <= 256; n *= 4){
		many(Draw3d->PATH, "software", n);
		many("/dis/math/draw3ddev.dis", "device", n);
	}

	# Frames.  Everything above draws one frame and reads it.  gorge(1)
	# draws ninety, with a present between each, and it is wrong.
	sys->print("\n%-12s %8s %10s %12s\n", "provider", "frames", "lit", "hash");
	frames(Draw3d->PATH, "software", 1);
	for(k := 0; k < 8; k++)
		frames("/dis/math/draw3ddev.dis", "device", 1);
	frames(Draw3d->PATH, "software", 8);
	for(k = 0; k < 4; k++)
		frames("/dis/math/draw3ddev.dis", "device", 8);

	# A model transform.  Everything above leaves the model matrix at
	# identity; gorge(1) rides the eye through the canyon with rotatex
	# and translate, and there is history in this tree about the GPU
	# path and non-identity model matrices.
	sys->print("\n%-12s %-10s %10s %12s\n", "provider", "model", "lit", "hash");
	model(Draw3d->PATH, "software", 0);
	model("/dis/math/draw3ddev.dis", "device", 0);
	model(Draw3d->PATH, "software", 1);
	model("/dis/math/draw3ddev.dis", "device", 1);

	# Geometry that crosses the eye plane.  gorge(1) flies a canyon
	# THROUGH the eye: every frame some faces have vertices behind it.
	# Nothing above does, and this is the last thing that differs.
	sys->print("\n%-12s %-10s %10s %12s\n", "provider", "spans", "lit", "hash");
	span(Draw3d->PATH, "software", 0);
	span("/dis/math/draw3ddev.dis", "device", 0);
	span(Draw3d->PATH, "software", 1);
	span("/dis/math/draw3ddev.dis", "device", 1);

	# line3 has the same shape of question: devdraw clips fillpoly3 and
	# fillpoly3 gouraud against the eye plane, and does not clip lines.
	sys->print("\n%-12s %-10s %10s %12s\n", "provider", "lines", "lit", "hash");
	lines3(Draw3d->PATH, "software", 0);
	lines3("/dis/math/draw3ddev.dis", "device", 0);
	lines3(Draw3d->PATH, "software", 1);
	lines3("/dis/math/draw3ddev.dis", "device", 1);

	# What does a lit value actually do to a colour?
	#
	# castlefrankenstein draws its walls with fillpoly3 at a per-face
	# lit of 0.82 and comes out at about half the brightness through
	# Metal that it does on the CPU.  This is that, with nothing else
	# in the way: one white quad, one lit, read the middle pixel.
	sys->print("\n%-10s %6s %16s %16s\n", "lit", "", "software r,g,b", "device r,g,b");
	lv := array[] of {1.0, 0.82, 0.6, 0.4, 0.2};
	for(i := 0; i < len lv; i++){
		(sr, sg, sb) := litpix(Draw3d->PATH, lv[i], Draw->White);
		(dr, dg, db) := litpix("/dis/math/draw3ddev.dis", lv[i], Draw->White);
		pct := 0;
		if(sr > 0)
			pct = dr*100/sr;
		sys->print("%-10g %6s %6d,%3d,%3d %9d,%3d,%3d   device is %d%%\n",
			lv[i], "", sr, sg, sb, dr, dg, db, pct);
	}

	# And a coloured pen, because scaling a colour is where the channel
	# order shows up: a red face that comes back blue is still "dimmer".
	sys->print("\n%-10s %6s %16s %16s\n", "lit (red)", "", "software r,g,b", "device r,g,b");
	for(i = 0; i < len lv; i++){
		(sr, sg, sb) := litpix(Draw3d->PATH, lv[i], Draw->Red);
		(dr, dg, db) := litpix("/dis/math/draw3ddev.dis", lv[i], Draw->Red);
		sys->print("%-10g %6s %6d,%3d,%3d %9d,%3d,%3d\n",
			lv[i], "", sr, sg, sb, dr, dg, db);
	}

	# Does geometry stay inside the window it is drawn into?  A window
	# smaller than the screen, and a face that projects bigger than the
	# window: anything outside is paint that escaped the clip.
	sys->print("\n%-12s %10s %10s\n", "provider", "inside", "ESCAPED");
	clipt(Draw3d->PATH, "software");
	clipt("/dis/math/draw3ddev.dis", "device");
}

frames(path, what: string, nf: int)
{
	d3 := load Draw3d path;
	if(d3 == nil)
		return;
	d3->init();
	img := win.image;
	c := d3->context(img);
	for(k := 0; k < nf; k++){
		img.draw(img.r, d.black, nil, img.r.min);
		d3->setzarea(c, img.r);
		d3->setz(c, 1);
		d3->viewport(c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
		d3->mode(Draw3d->PROJ);
		d3->identity();
		d3->frustumoffset(1.55, -1.55*456.0/638.0, 0.0);
		d3->mode(Draw3d->MODEL);
		d3->identity();
		d3->clearz(c);
		d3->setcolour(c, d.color(Draw->Red));
		lits := array[] of {0.4, 0.6, 1.0, 0.8};
		for(i := 0; i < 64; i++){
			z := -1.5 - real i * 0.12;
			x := 0.45;
			if(i & 1)
				x = -0.45;
			v := array[] of {
				Draw3d->Vector(x, -0.35, z),
				Draw3d->Vector(x,  0.35, z),
				Draw3d->Vector(x*0.5,  0.35, z - 0.12),
				Draw3d->Vector(x*0.5, -0.35, z - 0.12),
			};
			d3->fillpoly3g(c, v, lits);
		}
		img.flush(Draw->Flushnow);
	}
	(l, h) := lithash(img);
	sys->print("%-12s %8d %10d %12d\n", what, nf, l, h);
}

many(path, what: string, n: int)
{
	d3 := load Draw3d path;
	if(d3 == nil)
		return;
	d3->init();
	img := win.image;
	img.draw(img.r, d.black, nil, img.r.min);
	img.flush(Draw->Flushnow);
	c := d3->context(img);
	d3->setzarea(c, img.r);
	d3->setz(c, 1);
	d3->viewport(c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	d3->mode(Draw3d->PROJ);
	d3->identity();
	d3->frustumoffset(1.55, -1.55*456.0/638.0, 0.0);
	d3->mode(Draw3d->MODEL);
	d3->identity();
	d3->clearz(c);
	d3->setcolour(c, d.color(Draw->Red));
	lits := array[] of {0.4, 0.6, 1.0, 0.8};
	# A corridor: quads marching away from the eye, left and right,
	# which is the shape gorge draws.
	for(i := 0; i < n; i++){
		z := -1.5 - real i * 0.12;
		x := 0.45;
		if(i & 1)
			x = -0.45;
		v := array[] of {
			Draw3d->Vector(x, -0.35, z),
			Draw3d->Vector(x,  0.35, z),
			Draw3d->Vector(x*0.5,  0.35, z - 0.12),
			Draw3d->Vector(x*0.5, -0.35, z - 0.12),
		};
		d3->fillpoly3g(c, v, lits);
	}
	img.flush(Draw->Flushnow);
	(l, h) := lithash(img);
	sys->print("%-12s %8d %10d %12d\n", what, n, l, h);
}

model(path, what: string, xform: int)
{
	d3 := load Draw3d path;
	if(d3 == nil)
		return;
	d3->init();
	img := win.image;
	img.draw(img.r, d.black, nil, img.r.min);
	img.flush(Draw->Flushnow);
	c := d3->context(img);
	d3->setzarea(c, img.r);
	d3->setz(c, 1);
	d3->viewport(c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	d3->mode(Draw3d->PROJ);
	d3->identity();
	d3->frustumoffset(1.55, -1.55*456.0/638.0, 0.0);
	d3->mode(Draw3d->MODEL);
	d3->identity();
	if(xform){
		d3->rotatex(7.0);
		d3->translate(-0.3, -1.7, 0.0);
	}
	d3->clearz(c);
	d3->setcolour(c, d.color(Draw->Red));
	lits := array[] of {0.4, 0.6, 1.0, 0.8};
	for(i := 0; i < 64; i++){
		z := -1.5 - real i * 0.12;
		x := 0.45;
		if(i & 1)
			x = -0.45;
		v := array[] of {
			Draw3d->Vector(x, -0.35, z),
			Draw3d->Vector(x,  0.35, z),
			Draw3d->Vector(x*0.5,  0.35, z - 0.12),
			Draw3d->Vector(x*0.5, -0.35, z - 0.12),
		};
		d3->fillpoly3g(c, v, lits);
	}
	img.flush(Draw->Flushnow);
	(l, h) := lithash(img);
	nm := "identity";
	if(xform)
		nm = "rot+trans";
	sys->print("%-12s %-10s %10d %12d\n", what, nm, l, h);
}

span(path, what: string, cross: int)
{
	d3 := load Draw3d path;
	if(d3 == nil)
		return;
	d3->init();
	img := win.image;
	img.draw(img.r, d.black, nil, img.r.min);
	img.flush(Draw->Flushnow);
	c := d3->context(img);
	d3->setzarea(c, img.r);
	d3->setz(c, 1);
	d3->viewport(c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	d3->mode(Draw3d->PROJ);
	d3->identity();
	d3->frustumoffset(1.55, -1.55*456.0/638.0, 0.0);
	d3->mode(Draw3d->MODEL);
	d3->identity();
	d3->clearz(c);
	d3->setcolour(c, d.color(Draw->Red));
	lits := array[] of {0.4, 0.6, 1.0, 0.8};
	# A wall running away from the eye.  With cross set, its near end is
	# BEHIND the eye, so each near quad straddles the eye plane.
	z0 := -0.4;
	if(cross)
		z0 = 0.8;
	for(i := 0; i < 32; i++){
		za := z0 - real i * 0.4;
		zb := za - 0.4;
		v := array[] of {
			Draw3d->Vector(-0.45, -0.35, za),
			Draw3d->Vector(-0.45,  0.35, za),
			Draw3d->Vector(-0.45,  0.35, zb),
			Draw3d->Vector(-0.45, -0.35, zb),
		};
		d3->fillpoly3g(c, v, lits);
	}
	img.flush(Draw->Flushnow);
	(l, h) := lithash(img);
	nm := "in front";
	if(cross)
		nm = "thru eye";
	sys->print("%-12s %-10s %10d %12d\n", what, nm, l, h);
}

lines3(path, what: string, cross: int)
{
	d3 := load Draw3d path;
	if(d3 == nil)
		return;
	d3->init();
	img := win.image;
	img.draw(img.r, d.black, nil, img.r.min);
	img.flush(Draw->Flushnow);
	c := d3->context(img);
	d3->setzarea(c, img.r);
	d3->setz(c, 1);
	d3->viewport(c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	d3->mode(Draw3d->PROJ);
	d3->identity();
	d3->frustumoffset(1.55, -1.55*456.0/638.0, 0.0);
	d3->mode(Draw3d->MODEL);
	d3->identity();
	d3->clearz(c);
	d3->setcolour(c, d.color(Draw->Red));
	z0 := -0.4;
	if(cross)
		z0 = 0.8;
	for(i := 0; i < 24; i++){
		y := -0.3 + real i * 0.025;
		d3->line3(c, Draw3d->Vector(-0.4, y, z0),
			Draw3d->Vector(-0.4, y, z0 - 8.0), 1);
	}
	img.flush(Draw->Flushnow);
	(l, h) := lithash(img);
	nm := "in front";
	if(cross)
		nm = "thru eye";
	sys->print("%-12s %-10s %10d %12d\n", what, nm, l, h);
}

clipt(path, what: string)
{
	d3 := load Draw3d path;
	if(d3 == nil)
		return;
	d3->init();
	# A window well inside the screen, so there is an outside to spill
	# into.  The screen is cleared first, so anything lit beyond the
	# window came from this drawing and nothing else.
	win.reshape(Rect((120,90),(420,330)));
	win.onscreen("place");
	d.image.draw(d.image.r, d.black, nil, d.image.r.min);
	d.image.flush(Draw->Flushnow);
	img := win.image;
	img.draw(img.r, d.black, nil, img.r.min);
	img.flush(Draw->Flushnow);
	c := d3->context(img);
	d3->setzarea(c, img.r);
	d3->setz(c, 1);
	d3->viewport(c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	d3->mode(Draw3d->PROJ);
	d3->identity();
	d3->frustum(0.1, 0.1, 100.0);
	d3->mode(Draw3d->MODEL);
	d3->identity();
	d3->clearz(c);
	d3->setcolour(c, d.color(Draw->Red));
	lits := array[] of {0.5, 0.7, 1.0, 0.8};
	# Deliberately larger than the window once projected.
	v := array[] of {
		Draw3d->Vector(-0.9, -0.9, -1.2), Draw3d->Vector( 0.9, -0.9, -1.2),
		Draw3d->Vector( 0.9,  0.9, -1.2), Draw3d->Vector(-0.9,  0.9, -1.2),
	};
	d3->fillpoly3g(c, v, lits);
	img.flush(Draw->Flushnow);
	(inside, out) := insideout(img.r);
	sys->print("%-12s %10d %10d\n", what, inside, out);
}

# Lit pixels within r, and lit pixels anywhere else on the screen.
insideout(r: Rect): (int, int)
{
	sr := d.image.r;
	bpl := (sr.dx() * d.image.depth + 7) / 8;
	pxb := d.image.depth / 8;
	buf := array[bpl] of byte;
	ins := 0;
	out := 0;
	for(y := sr.min.y; y < sr.max.y; y++){
		if(d.image.readpixels(Rect((sr.min.x, y), (sr.max.x, y+1)), buf) != bpl)
			return (-1, -1);
		for(i := 0; i < sr.dx(); i++){
			if(buf[i*pxb] == byte 0 && buf[i*pxb+1] == byte 0
			&& buf[i*pxb+2] == byte 0)
				continue;
			x := sr.min.x + i;
			if(x >= r.min.x && x < r.max.x && y >= r.min.y && y < r.max.y)
				ins++;
			else
				out++;
		}
	}
	return (ins, out);
}

# One white quad at a given lit, and the pixel in the middle of it.
litpix(path: string, lit: real, colour: int): (int, int, int)
{
	d3 := load Draw3d path;
	if(d3 == nil)
		return (-1, -1, -1);
	d3->init();
	win.reshape(Rect((0,0),(640,480)));
	win.onscreen("place");
	img := win.image;
	img.draw(img.r, d.black, nil, img.r.min);
	img.flush(Draw->Flushnow);
	c := d3->context(img);
	d3->setzarea(c, img.r);
	d3->setz(c, 1);
	d3->viewport(c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	d3->mode(Draw3d->PROJ);
	d3->identity();
	d3->frustum(0.1, 0.1, 100.0);
	d3->mode(Draw3d->MODEL);
	d3->identity();
	d3->clearz(c);
	d3->setcolour(c, d.color(colour));
	v := array[] of {
		Draw3d->Vector(-0.5, -0.4, -3.0), Draw3d->Vector( 0.5, -0.4, -3.0),
		Draw3d->Vector( 0.5,  0.4, -3.0), Draw3d->Vector(-0.5,  0.4, -3.0),
	};
	d3->fillpoly3(c, v, Draw3d->Vector(0.0, 0.0, 1.0), lit);
	img.flush(Draw->Flushnow);
	mid := Point((img.r.min.x+img.r.max.x)/2, (img.r.min.y+img.r.max.y)/2);
	buf := array[4] of byte;
	if(d.image.readpixels(Rect(mid, (mid.x+1, mid.y+1)), buf) < 0)
		return (-1, -1, -1);
	# read back as it lies; the two providers are compared with each
	# other, so the channel order only has to be consistent
	return (int buf[2], int buf[1], int buf[0]);
}

lithash(img: ref Image): (int, int)
{
	r := img.r;
	bpl := (r.dx() * img.depth + 7) / 8;
	pxb := img.depth / 8;
	buf := array[bpl] of byte;
	n := 0;
	h := 0;
	for(y := r.min.y; y < r.max.y; y++){
		if(d.image.readpixels(Rect((r.min.x, y), (r.max.x, y+1)), buf) != bpl)
			return (-1, -1);
		for(i := 0; i < r.dx(); i++){
			if(buf[i*pxb] != byte 0 || buf[i*pxb+1] != byte 0
			|| buf[i*pxb+2] != byte 0){
				n++;
				h = (h*31 + int buf[i*pxb] + int buf[i*pxb+2]) & 16r3FFFFFFF;
			}
		}
	}
	return (n, h);
}

occ(path, what: string, offset: int)
{
	d3 := load Draw3d path;
	if(d3 == nil)
		return;
	d3->init();
	pn := "frustum";
	if(offset)
		pn = "offset";
	(r0, g0) := occ1(d3, offset, 0);
	sys->print("%-12s %-10s %-12s %8d %8d\n", what, pn, "far,near", r0, g0);
	(r1, g1) := occ1(d3, offset, 1);
	sys->print("%-12s %-10s %-12s %8d %8d\n", what, pn, "near,far", r1, g1);
}

occ1(d3: Draw3d, offset, nearfirst: int): (int, int)
{
	img := win.image;
	img.draw(img.r, d.black, nil, img.r.min);
	img.flush(Draw->Flushnow);
	c := d3->context(img);
	d3->setzarea(c, img.r);
	d3->setz(c, 1);
	d3->viewport(c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	d3->mode(Draw3d->PROJ);
	d3->identity();
	if(offset)
		d3->frustumoffset(1.55, -1.55*456.0/638.0, 0.0);
	else
		d3->frustum(0.1, 0.1, 100.0);
	d3->mode(Draw3d->MODEL);
	d3->identity();
	d3->clearz(c);
	far := array[] of {
		Draw3d->Vector(-0.5, -0.4, -6.0), Draw3d->Vector( 0.5, -0.4, -6.0),
		Draw3d->Vector( 0.5,  0.4, -6.0), Draw3d->Vector(-0.5,  0.4, -6.0),
	};
	near := array[] of {
		Draw3d->Vector(-0.08, -0.06, -2.0), Draw3d->Vector( 0.08, -0.06, -2.0),
		Draw3d->Vector( 0.08,  0.06, -2.0), Draw3d->Vector(-0.08,  0.06, -2.0),
	};
	lits := array[] of {0.5, 0.7, 1.0, 0.8};
	if(nearfirst){
		d3->setcolour(c, d.color(Draw->Green));
		d3->fillpoly3g(c, near, lits);
		d3->setcolour(c, d.color(Draw->Red));
		d3->fillpoly3g(c, far, lits);
	}else{
		d3->setcolour(c, d.color(Draw->Red));
		d3->fillpoly3g(c, far, lits);
		d3->setcolour(c, d.color(Draw->Green));
		d3->fillpoly3g(c, near, lits);
	}
	img.flush(Draw->Flushnow);
	return count2(img);
}

count2(img: ref Image): (int, int)
{
	r := img.r;
	bpl := (r.dx() * img.depth + 7) / 8;
	pxb := img.depth / 8;
	buf := array[bpl] of byte;
	nr := 0;
	ng := 0;
	for(y := r.min.y; y < r.max.y; y++){
		if(d.image.readpixels(Rect((r.min.x, y), (r.max.x, y+1)), buf) != bpl)
			return (-1, -1);
		for(i := 0; i < r.dx(); i++){
			a := int buf[i*pxb];
			b := int buf[i*pxb+1];
			cc := int buf[i*pxb+2];
			# whichever of the two outer channels dominates; the
			# probe only ever draws one pure red and one pure green
			if(a > b + 24 && a > cc + 24)
				nr++;
			else if(cc > b + 24 && cc > a + 24)
				ng++;
			else if(b > a + 24 && b > cc + 24)
				ng++;
		}
	}
	return (nr, ng);
}

one(path, what: string, zs: array of real)
{
	d3 := load Draw3d path;
	if(d3 == nil){
		sys->print("cannot load %s\n", path);
		return;
	}
	d3->init();
	for(i := 0; i < len zs; i++){
		if(what == "device" && i == 0)
			dumpnext = 1;
		f := quad(d3, zs[i], 0);
		g := quad(d3, zs[i], 1);
		eq := "no";
		if(f == g)
			eq = "yes";
		else if(f > 0 && g > 0)
			eq = "both";
		sys->print("%-28s %8g %8d %8d %8s\n", what, zs[i], f, g, eq);
	}
}

quad(d3: Draw3d, z: real, gouraud: int): int
{
	img := win.image;
	img.draw(img.r, d.black, nil, img.r.min);
	img.flush(Draw->Flushnow);
	c := d3->context(img);
	d3->setzarea(c, img.r);
	d3->setz(c, 1);
	d3->viewport(c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	d3->mode(Draw3d->PROJ);
	d3->identity();
	d3->frustum(0.1, 0.1, 100.0);
	d3->mode(Draw3d->MODEL);
	d3->identity();
	d3->clearz(c);
	d3->setcolour(c, d.color(Draw->Red));
	v := array[] of {
		Draw3d->Vector(-0.5, -0.4, z), Draw3d->Vector( 0.5, -0.4, z),
		Draw3d->Vector( 0.5,  0.4, z), Draw3d->Vector(-0.5,  0.4, z),
	};
	if(gouraud){
		lits := array[] of {0.5, 0.7, 1.0, 0.8};
		d3->fillpoly3g(c, v, lits);
	}else
		d3->fillpoly3(c, v, Draw3d->Vector(0.0, 0.0, 1.0), 0.8);
	img.flush(Draw->Flushnow);
	n := lit(img);
	if(dumpnext){
		dumpnext = 0;
		dump(img);
	}
	return n;
}

dump(img: ref Image)
{
	r := img.r;
	bpl := (r.dx() * img.depth + 7) / 8;
	buf := array[bpl] of byte;
	fd := sys->create("g3probe.raw", Sys->OWRITE, 8r666);
	if(fd == nil)
		return;
	for(y := r.min.y; y < r.max.y; y++){
		if(d.image.readpixels(Rect((r.min.x, y), (r.max.x, y+1)), buf) != bpl)
			return;
		sys->write(fd, buf, bpl);
	}
	sys->print("g3probe: wrote g3probe.raw %dx%d depth %d\n", r.dx(), r.dy(), img.depth);
}

lit(img: ref Image): int
{
	r := img.r;
	bpl := (r.dx() * img.depth + 7) / 8;
	pxb := img.depth / 8;
	buf := array[bpl] of byte;
	n := 0;
	for(y := r.min.y; y < r.max.y; y++){
		if(d.image.readpixels(Rect((r.min.x, y), (r.max.x, y+1)), buf) != bpl)
			return -1;
		for(i := 0; i < r.dx(); i++)
			if(buf[i*pxb] != byte 0 || buf[i*pxb+1] != byte 0 || buf[i*pxb+2] != byte 0)
				n++;
	}
	return n;
}
