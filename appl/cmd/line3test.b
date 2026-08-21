implement Command;

#
# Checks that draw3d's /dev/draw-backed provider (draw3ddev) renders the
# same line3 segments as the software provider.
#
# It counts SEGMENTS, not lit pixels: a pixel count cannot tell sixty
# thin segments from twenty thick ones, which is the failure this is
# looking for.  Each spoke is probed where it is expected to be.
#
# The GPU line hook only accepts the screen as a destination, so this
# draws to the display image and reads it back; devdraw runs any queued
# GPU work before serving a read, so the readback sees it.
#


include "sys.m";
	sys: Sys;
	print: import sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;
include "math/polyfill.m";
include "math/draw3d.m";
include "math.m";
	math: Math;

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

NSEG: con 60;	# spokes in the test fan

# Draw NSEG radial spokes and report how many pixels ended up set.
runprovider(disp: ref Display, path: string, kind: string): int
{
	d3 := load Draw3d path;
	if(d3 == nil){
		print("  cannot load %s: %r\n", path);
		return -1;
	}
	d3->init();

	dst := disp.image;		# the screen: the only dst the GPU line hook accepts
	black := disp.color(Draw->Black);
	white := disp.color(Draw->White);
	dst.draw(dst.r, black, nil, dst.r.min);

	c := d3->context(dst);
	c.colour = white;
	c.zenable = 0;
	c.clipbehind = 0;
	d3->viewport(c, dst.r.min.x, dst.r.min.y, dst.r.max.x, dst.r.max.y);
	d3->mode(Draw3d->PROJ);
	d3->identity();
	d3->ortho(1.0, -10.0, 10.0);
	d3->mode(Draw3d->MODEL);
	d3->identity();

	if(kind == "line3"){
		for(i := 0; i < NSEG; i++){
			t := real i / real NSEG * 6.28318530718;
			a := Draw3d->Vector(0.0, 0.0, 0.0);
			b := Draw3d->Vector(math->cos(t)*0.8, math->sin(t)*0.8, 0.0);
			d3->line3(c, a, b, 0);
		}
	} else {
		# control: a filled triangle through the same provider
		v := array[3] of Draw3d->Vector;
		v[0] = Draw3d->Vector(-0.6, -0.6, 0.0);
		v[1] = Draw3d->Vector( 0.6, -0.6, 0.0);
		v[2] = Draw3d->Vector( 0.0,  0.6, 0.0);
		d3->fillpoly3(c, v, Draw3d->Vector(0.0, 0.0, 1.0), 1.0);
	}
	dst.flush(Draw->Flushnow);

	if(kind != "line3")
		return -1;
	# Count how many of the NSEG spokes actually left ink: probe a small
	# box around a point 60% of the way out along each spoke.  Counting
	# total lit pixels cannot tell 60 thin segments from 20 thick ones,
	# which is exactly the failure being looked for.
	found := 0;
	for(i := 0; i < NSEG; i++){
		t := real i / real NSEG * 6.28318530718;
		wx := math->cos(t)*0.8*0.6;
		wy := math->sin(t)*0.8*0.6;
		(pt, nil, ok) := d3->project(c, Draw3d->Vector(wx, wy, 0.0));
		if(!ok)
			continue;
		if(probe(dst, pt))
			found++;
	}
	return found;
}

# any non-black pixel within +/-3 of p?
probe(dst: ref Image, p: Point): int
{
	r := Rect(Point(p.x-3, p.y-3), Point(p.x+4, p.y+4));
	if(r.min.x < dst.r.min.x) r.min.x = dst.r.min.x;
	if(r.min.y < dst.r.min.y) r.min.y = dst.r.min.y;
	if(r.max.x > dst.r.max.x) r.max.x = dst.r.max.x;
	if(r.max.y > dst.r.max.y) r.max.y = dst.r.max.y;
	if(r.dx() <= 0 || r.dy() <= 0)
		return 0;
	nb := r.dy() * draw->bytesperline(r, dst.depth);
	buf := array[nb] of byte;
	if(dst.readpixels(r, buf) != nb)
		return 0;
	for(k := 0; k < nb; k++)
		if(buf[k] != byte 0)
			return 1;
	return 0;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	disp := Display.allocate(nil);
	if(disp == nil){
		print("no display: %r\n");
		return;
	}
	for(kl := list of {"line3"}; kl != nil; kl = tl kl){
		k := hd kl;
		soft := runprovider(disp, "/dis/math/draw3d.dis", k);
		dev := runprovider(disp, "/dis/math/draw3ddev.dis", k);
		print("%s: software %d/%d, draw3ddev %d/%d\n", k, soft, NSEG, dev, NSEG);
		if(soft != NSEG)
			print("FAIL: software provider dropped segments\n");
		else if(dev != NSEG)
			print("FAIL: draw3ddev dropped %d of %d segments\n", NSEG-dev, NSEG);
		else
			print("PASS\n");
	}
}
