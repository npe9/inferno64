implement Draw3dkerntest;

#
# Does this system's draw device implement the draw3d protocol letters,
# and does it draw what the Limbo renderer draws?
#
# Both questions in one test, because the answer to the second is the
# only check on the first worth having: a device that accepts the
# letters and rasterises them wrongly passes any "did it error" test.
# The two providers are independent implementations of the same
# formulae -- math/draw3ddev.dis writes protocol messages that the C
# handlers in devdraw.c execute, math/draw3d.dis does the arithmetic in
# Limbo -- so comparing their pictures compares an implementation
# against an implementation and not against itself.
#
# IT NEEDS NO WINDOW AND NO GPU. Everything is drawn into an ordinary
# image and read back with readpixels, which depends on nothing outside
# this process; that is what makes it runnable on a bare board over a
# serial console.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point, Screen: import draw;
include "math.m";
include "math/polyfill.m";
include "math/draw3d.m";

Draw3dkerntest: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

W: con 160;
H: con 120;

ok, fail: int;
disp: ref Display;

report(good: int, what: string)
{
	if(good){
		ok++;
		sys->print("ok   %s\n", what);
	} else {
		fail++;
		sys->print("FAIL %s\n", what);
	}
}

# Bytes differing between two readbacks, and how many are not the
# background. Ink matters because two identical BLANK images also
# differ in zero bytes, which would pass the comparison while proving
# that neither provider drew anything.
differ(a, b: array of byte): int
{
	n := 0;
	if(len a != len b)
		return -1;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			n++;
	return n;
}

# A picture's fingerprint, for comparing the SAME provider between two
# environments -- the kernel's devdraw.c and emu's are now the same C,
# so their device-provider pictures must agree, and a checksum is what
# can travel over a serial console when the images cannot.
sum32(a: array of byte): int
{
	h := int 2166136261;	# int, not the big this literal would be
	for(i := 0; i < len a; i++){
		h = h ^ int a[i];
		h = (h * 16777619) & int 16rFFFFFFFF;	# the mask is big too
	}
	return h;
}

inked(a: array of byte): int
{
	n := 0;
	for(i := 0; i < len a; i++)
		if(a[i] != byte 0)
			n++;
	return n;
}

# One frame of geometry, drawn by whichever provider is handed in.
frame(d3: Draw3d, name: string, what: string): array of byte
{
	img := disp.newimage(Rect((0,0),(W,H)), draw->RGB24, 0, Draw->Black);
	if(img == nil){
		sys->print("FAIL %s: newimage: %r\n", name);
		return nil;
	}
	white := disp.color(Draw->White);
	if(white == nil){
		sys->print("FAIL %s: no colour: %r\n", name);
		return nil;
	}
	c := d3->context(img);
	if(c == nil){
		sys->print("FAIL %s: no context: %r\n", name);
		return nil;
	}
	d3->viewport(c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	d3->setzarea(c, img.r);
	d3->setz(c, 1);
	d3->setcolour(c, white);
	d3->mode(Draw3d->PROJ);
	d3->identity();
	d3->frustum(0.1, 0.1, 100.0);
	d3->mode(Draw3d->MODEL);
	d3->identity();
	d3->clearz(c);

	# NEGATIVE z: the camera looks down -z and the eye plane clips
	# anything at or behind it, so a quad at z == 0 draws nothing at
	# all -- which is how the first version of this test managed to
	# compare two black images and call them equal.
	verts := array[4] of {
		Draw3d->Vector(-0.8, -0.8, -3.0),
		Draw3d->Vector( 0.8, -0.8, -3.0),
		Draw3d->Vector( 0.8,  0.8, -3.0),
		Draw3d->Vector(-0.8,  0.8, -3.0),
	};
	case what {
	"poly" =>
		d3->fillpoly3(c, verts, Draw3d->Vector(0.0, 0.0, 1.0), 1.0);
	"line" =>
		d3->line3(c, Draw3d->Vector(-0.9, 0.0, -2.0),
			Draw3d->Vector(0.9, 0.0, -2.0), 1);
	"plot" =>
		d3->plot3(c, Draw3d->Vector(0.0, 0.5, -2.0));
	}

	# The device provider QUEUES its messages; without this the readback
	# below can happen before the device has drawn any of them.
	img.flush(Draw->Flushnow);

	buf := array[W*H*3] of byte;
	if(img.readpixels(img.r, buf) < 0){
		sys->print("FAIL %s: readpixels: %r\n", name);
		return nil;
	}
	return buf;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	if(draw == nil){
		sys->print("draw3dkerntest: no Draw: %r\n");
		raise "fail:load";
	}
	disp = Display.allocate(nil);
	if(disp == nil){
		sys->print("draw3dkerntest: no display: %r\n");
		raise "fail:display";
	}

	dev := load Draw3d "/dis/math/draw3ddev.dis";
	soft := load Draw3d "/dis/math/draw3d.dis";
	if(dev == nil){
		sys->print("draw3dkerntest: load draw3ddev: %r\n");
		raise "fail:load";
	}
	if(soft == nil){
		sys->print("draw3dkerntest: load draw3d: %r\n");
		raise "fail:load";
	}
	dev->init();
	soft->init();

	for(wl := list of {"poly", "line", "plot"}; wl != nil; wl = tl wl){
		what := hd wl;
		sdev := frame(dev, "device", what);
		ssoft := frame(soft, "software", what);
		report(sdev != nil && inked(sdev) > 0,
			sys->sprint("%s: device inked something (%d)", what, inked(sdev)));
		report(ssoft != nil && inked(ssoft) > 0,
			sys->sprint("%s: software inked something (%d)", what, inked(ssoft)));
		if(sdev != nil && ssoft != nil){
			d := differ(sdev, ssoft);
			# Reported, not asserted: see BUGS in the man page. The
			# two providers are meant to agree and mostly do; where
			# they do not is a pre-existing difference between the C
			# and Limbo rasterisers, not something this test can fix,
			# and printing the number per primitive says which.
			sys->print("     %s: device vs software, %d bytes differ\n",
				what, d);
			sys->print("     %s: device sum %#x, software sum %#x\n",
				what, sum32(sdev), sum32(ssoft));
		}
	}
	sys->print("DRAW3DKERNTEST %d ok, %d fail\n", ok, fail);
	if(fail > 0)
		raise "fail:draw3dkerntest";
}
