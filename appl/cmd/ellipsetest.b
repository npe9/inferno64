implement Ellipsetest;

#
# Drives memellipse's brushed path, which is the one draw path that
# allocates an image with a NEGATIVE r.min.y -- bellipse's brush disc,
# Rect(-t,-t,t+1,t+1).  Two bugs lived there, both reachable only from a
# kernel and so invisible to any host run:
#
#	byteaddr computed its row offset as (s32)(sizeof(u32)*p.y*width)
#	and 7c dropped the narrowing cast, so a negative p.y left a
#	nonzero HIGH word on the pointer -- an address gigabytes past
#	anything mapped, written to by memfillcolor.
#
#	allocmemimage sized the disc with nw = l*Dy(r) in u32, so a
#	thickness whose true word count passed 2^32 wrapped to a small
#	one and the allocation came back far smaller than the rectangle.
#
# Reaching the brushed path at all needs a != b: the criterion is
# 2t(a-b) > b^2 for b<a, so a circle never gets there however thick it
# is, and neither does a fill, whose t of -1 makes the criterion false in
# both arms.  Every case below says which path it is aimed at, so a
# kernel that faults names the case on the line before it.
#
include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

Ellipsetest: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

ok := 0;
fail := 0;
disp: ref Display;
img: ref Image;
col: ref Image;

fatal(s: string)
{
	sys->fprint(sys->fildes(2), "ellipsetest: %s\n", s);
	raise "fail:bad";
}

#
# A case is only meaningful if it reaches the path it names, so each one
# states that in its own description rather than leaving it to the reader.
#
# EVERY CASE FLUSHES.  Draw operations are batched into the /dev/draw
# write buffer and executed when it is flushed, so without this the
# count below records how many messages were QUEUED and the drawing all
# happens afterwards, during teardown -- which is how an early version
# of this test printed "9 ok, 0 fail" on a kernel that then died in
# memfillcolor on its way out.  A count that cannot fail is not a test.
#
ecase(what: string, a, b, t: int)
{
	sys->print("	%s: a=%d b=%d t=%d\n", what, a, b, t);
	img.ellipse(Point(400, 300), a, b, t, col, Point(0, 0));
	img.flush(Draw->Flushnow);
	ok++;
}

fcase(what: string, a, b: int)
{
	sys->print("	%s: a=%d b=%d fill\n", what, a, b);
	img.fillellipse(Point(400, 300), a, b, col, Point(0, 0));
	img.flush(Draw->Flushnow);
	ok++;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	if(draw == nil)
		fatal("cannot load " + Draw->PATH);

	disp = Display.allocate(nil);
	if(disp == nil)
		fatal(sys->sprint("cannot allocate display: %r"));

	#
	# An ordinary image, origin at zero: the disc allocated per brushed
	# ellipse is the thing with the negative origin, not this.
	#
	img = disp.newimage(Rect((0, 0), (800, 600)), disp.image.chans, 0, Draw->White);
	if(img == nil)
		fatal(sys->sprint("cannot allocate image: %r"));
	col = disp.color(Draw->Black);
	if(col == nil)
		fatal(sys->sprint("cannot allocate colour: %r"));

	#
	# Which cases to run is an argument, because console output is
	# QUEUED: a sys->print and a trap print race, so the last line on
	# the wire does not say which case faulted.  Selecting one group per
	# boot attributes a fault by which invocation dies, which does not
	# depend on print ordering at all.
	#
	sel := "all";
	if(tl argv != nil)
		sel = hd tl argv;

	if(sel == "all" || sel == "brushed"){
	sys->print("ellipsetest: brushed path, which allocates a negative-origin disc\n");
	# 2t(a-b) = 4*39 = 156 > b^2 = 25, so these DO reach bellipse.
	ecase("brushed, wide", 44, 5, 2);
	ecase("brushed, tall", 5, 44, 2);
	ecase("brushed, barely", 20, 10, 2);
	}

	if(sel == "all" || sel == "plain"){
	sys->print("ellipsetest: the same radii on paths that do NOT reach it\n");
	# a == b: neither arm of the criterion can hold, so no disc at all.
	ecase("circle, not brushed", 20, 20, 2);
	# t < 0 is the fill sentinel; the criterion is false in both arms.
	fcase("fill, not brushed", 44, 5);
	}

	if(sel == "all" || sel == "wrapping"){
	sys->print("ellipsetest: thicknesses whose word count wraps u32\n");
	# nw = l*Dy(r) passed 2^32 for these and wrapped to a small value.
	ecase("wrapping", 10, 5, 92682);
	ecase("wrapping", 10, 5, 185352);
	ecase("wrapping", 10, 5, 185364);
	ecase("wrapping", 10, 5, 262144);
	}

	#
	# One more flush with nothing pending, so the line below cannot be
	# reached with work still outstanding.
	#
	img.flush(Draw->Flushnow);
	sys->print("ELLIPSETEST %d ok, %d fail\n", ok, fail);
}
