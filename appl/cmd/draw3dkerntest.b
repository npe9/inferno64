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

#
# 0x7FFFFFFF, and THIRTY-ONE bits rather than thirty-two on purpose.
#
# A 32-bit mask produces values above 2^31, and on this board that is
# unambiguous in the value and ambiguous in every PRINT: int is 64 bits
# at runtime here, so the masked result is +3748700864, while `%d' and
# `%#x' show a 32-bit signed view of it -- -545987904 and -0x208b1d40.
# A baseline pasted from that display is a different number that
# displays identically, so the assertion fails while the two printed
# values match character for character.  That happened three times
# before this line existed, and the poly checksum passed throughout
# only because it is below 2^31.
#
# 31 bits keeps every value positive and printable in both worlds, which
# also makes the baseline portable between the board and the QEMU arms.
# A 31-bit hash is ample for "have these pixels changed".
#
Mask31: con (big 1 << 31) - big 1;

ok, fail: int;
disp: ref Display;

#
# The device's checksums as last recorded on silicon, in the order the
# loop below walks: poly, line, plot.  Read with `draw3dkerntest -r',
# which prints a line that can be pasted here.
#
# These came off a Pi 3B, build 1791830376, and were confirmed
# byte-for-byte identical across two consecutive runs before being
# committed -- a baseline that is not reproducible is worse than none,
# because it fails for the wrong reason and teaches people to re-record.
#
Baseline: con 287627777;		# poly
Baselineline: con 1601495744;		# line
Baselineplot: con 1243760316;		# plot

expect: list of int;
recpoly, recline, recplot: int;


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
	#
	# THE MASK WAS INERT AND THE NAME WAS WRONG.
	#
	# `h & int 16rFFFFFFFF' looks like a truncation to 32 bits and is
	# not: int is 64 bits at runtime here, and `int 16rFFFFFFFF' is
	# the 32-bit literal sign-extended, which is -1.  Masking with
	# -1 keeps every bit, so h ran on as a full 64-bit value and
	# this function returned something that was not a 32-bit hash at
	# all.
	#
	# IT WAS INVISIBLE BECAUSE OF HOW IT WAS PRINTED.  `%#x' shows a
	# signed 32-bit view, so the line checksum displayed as
	# -0x208b1d40 while the value had bits above 31 -- and a
	# baseline pasted from that display compared UNEQUAL to the
	# value that printed it.  Three assertions failed against
	# numbers identical on screen, which is what sent me looking.
	#
	# `big' for the multiply, and a mask BUILT RATHER THAN WRITTEN:
	# `big 16rFFFFFFFF' is -1 as well, because the literal is parsed
	# as a 32-bit int before the widening, so the big form of the
	# bug is the same bug.  (big 1 << 32) - big 1 cannot be
	# sign-extended because nothing in it is a 32-bit literal.
	# Measured, not assumed: with `big 16rFFFFFFFF' the line
	# checksum was still -545987904, which is the signed reading of
	# 0xDF74E2C0 -- a negative result from a mask that is supposed
	# to clear the top 32 bits.
	#
	# Decimal everywhere below, because a 32-bit hash printed as
	# signed hex is how this hid in the first place.
	#
	h := int 2166136261;
	for(i := 0; i < len a; i++){
		h = h ^ int a[i];
		h = int ((big h * big 16777619) & Mask31);
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

init(nil: ref Draw->Context, args: list of string)
{
	record := 0;

	sys = load Sys Sys->PATH;
	#
	# -r records instead of asserting: it prints the three device
	# checksums in a form that can be pasted into the Baseline
	# constants above, and does NOT compare them.  Anything else is
	# an assertion against the recorded values.
	#
	# Two modes and not one, because the alternative is a test whose
	# baseline is whatever it just measured -- which passes always.
	#
	if(args != nil)
		args = tl args;
	if(args != nil && hd args == "-r")
		record = 1;
	else
		expect = Baseline :: Baselineline :: Baselineplot :: nil;
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
			#
			# STILL REPORTED AND NOT ASSERTED AS AN EQUALITY,
			# for the reason the man page gives: the two
			# providers disagree today on poly and line, that
			# is a pre-existing difference between the C and
			# Limbo rasterisers, and this test cannot fix it.
			#
			sys->print("     %s: device vs software, %d bytes differ\n",
				what, d);
			sys->print("     %s: device sum %d, software sum %d\n",
				what, sum32(sdev), sum32(ssoft));
			#
			# BUT THE DEVICE'S OWN PIXELS ARE ASSERTED AGAINST
			# A BASELINE, and that is what makes this a test a
			# GPU backend can be graded by.
			#
			# Without it the harness cannot fail on wrong
			# pixels: `6 ok, 0 fail' is what it printed on this
			# board while reporting 228 differing bytes on poly
			# and 18 on line, because the six were only the
			# `inked something' checks.  A backend assigned to
			# devdraw's gpudraw* hooks could rasterise anything
			# at all and this would have passed it -- which is
			# the one thing the header says the test exists to
			# prevent: "a device that accepts the letters and
			# rasterises them wrongly passes any `did it error'
			# test."
			#
			# The baseline is the device's checksum, not
			# equality with the software path, so it needs no
			# resolution of the C-against-Limbo difference to
			# be useful: it says THE PIXELS HAVE NOT CHANGED.
			# Measured byte-for-byte reproducible across runs
			# on silicon before being written down.
			#
			# Re-recording is deliberate, and the rule is the
			# one tools/ci/README already states for markers: a
			# changed value fails, and the fix is either the
			# backend or a reviewed new baseline -- never a
			# quiet pass.
			case what {
			"poly" => recpoly = sum32(sdev);
			"line" => recline = sum32(sdev);
			"plot" => recplot = sum32(sdev);
			}
			if(expect != nil){
				e := hd expect;
				expect = tl expect;
				report(e == sum32(sdev),
					sys->sprint("%s: device sum %d is the"
						+ " baseline %d", what,
						sum32(sdev), e));
			}
		}
	}
	if(record)
		sys->print("DRAW3D-RECORD paste into draw3dkerntest.b:\n"
			+ "Baseline: con %d;\t\t# poly\n"
			+ "Baselineline: con %d;\t\t# line\n"
			+ "Baselineplot: con %d;\t\t# plot\n",
			recpoly, recline, recplot);
	sys->print("DRAW3DKERNTEST %d ok, %d fail\n", ok, fail);
	if(fail > 0)
		raise "fail:draw3dkerntest";
}
