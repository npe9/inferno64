implement Drawink;

#
# Draw known geometry into the screen image and read it back out of the
# screen image, so the pixels are checked where they actually landed
# rather than where the drawing code thought it put them.  On a board
# whose screen image points straight at the scanout buffer (raspi3b with
# Directfb), the readback comes out of video RAM, which is the whole
# point: it is the one check that distinguishes "memdraw ran" from "the
# display is showing what memdraw drew".
#
# Checks 1 and 2 are each other's control: the same pixels must read all
# zero after the clear and all non-zero after the fill, so neither a
# readback stuck at zero nor one stuck at full scale can pass both.
#
# A kernel with a software cursor composites a 16x16 overlay into the
# same memory, which on a direct framebuffer reads back as holes in a
# solid fill.  That is the cursor working, not the fill failing, so
# drawink makes the cursor invisible while it runs and restores the
# default on the way out.  Every check reports PASS or FAIL with the
# numbers it compared and, when it fails, the bounding box of the pixels
# that disagreed -- a 16x16 box at the pointer is a cursor that did not
# get hidden, and anything else is a drawing fault.
#
# The -k flag leaves the cursor alone.  On a kernel that composites one
# into the screen image it is expected to FAIL, with the box naming the
# pointer, and that is its purpose: it is how these checks are shown to
# be capable of failing at all, and it is how the restore on the way out
# gets verified -- a plain run followed by a -k run that sees the cursor
# again proves the default came back.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point, Font, Chans: import draw;

Drawink: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

nfail := 0;
ZR: con Rect((0, 0), (0, 0));

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	if(draw == nil){
		sys->print("drawink: load draw: %r\n");
		raise "fail:no draw";
	}

	dev := "/dev";
	keepcursor := 0;
	argv = tl argv;
	if(argv != nil && hd argv == "-k"){
		keepcursor = 1;
		argv = tl argv;
	}
	if(argv != nil)
		dev = hd argv;

	# The kernel draw and pointer devices may not be bound yet in this
	# namespace; binding after /dev is harmless if they already are.
	sys->bind("#i", dev, Sys->MAFTER);
	sys->bind("#m", dev, Sys->MAFTER);

	disp: ref Display;
	{
		disp = Display.allocate(dev);
	}exception e{
	"*" =>
		sys->print("drawink: Display.allocate: %s\n", e);
		raise "fail:no display";
	}
	if(disp == nil){
		sys->print("drawink: Display.allocate: %r\n");
		raise "fail:no display";
	}

	scr := disp.image;
	if(scr == nil){
		sys->print("drawink: no screen image\n");
		raise "fail:no screen";
	}
	r := scr.r;
	bpp := scr.depth / 8;
	sys->print("drawink: screen %dx%d %s depth %d\n",
		r.dx(), r.dy(), scr.chans.text(), scr.depth);
	if(bpp == 0){
		sys->print("drawink: sub-byte depth %d not handled\n", scr.depth);
		raise "fail:depth";
	}

	cf: ref Sys->FD;
	if(!keepcursor)
		cf = hidecursor(dev);

	black := disp.rgb(0, 0, 0);
	# Three channel-separable colours, so a swapped channel shows up as
	# the wrong count rather than as the wrong shade of grey.
	red := disp.rgb(255, 0, 0);
	green := disp.rgb(0, 255, 0);
	white := disp.rgb(255, 255, 255);

	# 1.  Clear, then read back a strip: proves a solid fill reaches the
	#     bytes we can see, and gives the other checks a known ground.
	scr.draw(r, black, nil, (0, 0));
	scr.flush(Draw->Flushnow);
	strip := Rect((r.min.x, r.min.y), (r.max.x, r.min.y + 1));
	buf := array[strip.dx() * bpp] of byte;
	if((n := scr.readpixels(strip, buf)) != len buf){
		sys->print("drawink: FAIL clear readpixels %d of %d: %r\n", n, len buf);
		nfail++;
	}else{
		bad := 0;
		for(i := 0; i < len buf; i++)
			if(int buf[i] != 0)
				bad++;
		report("clear", bad == 0, sys->sprint("%d of %d bytes non-zero", bad, len buf), ZR);
	}

	# 2.  A rectangle in the middle, read back inside and just outside.
	#     Catches an off-by-one in the row stride, which is what a direct
	#     framebuffer gets wrong: a stride mismatch leaves the inside
	#     right and smears the outside.
	w := r.dx() / 4;
	h := r.dy() / 4;
	box := Rect((r.min.x + w, r.min.y + h), (r.min.x + 3 * w, r.min.y + 3 * h));
	scr.draw(box, red, nil, (0, 0));
	scr.flush(Draw->Flushnow);
	(itot, iink, nil, iholes) := countink(scr,
		Rect((box.min.x + 1, box.min.y + 1), (box.max.x - 1, box.max.y - 1)), bpp);
	report("box inside", itot > 0 && iink == itot,
		sys->sprint("%d of %d pixels inked", iink, itot), iholes);
	(atot, aink, abox, nil) := countink(scr,
		Rect((box.min.x, r.min.y), (box.max.x, box.min.y - 1)), bpp);
	report("box outside", aink == 0,
		sys->sprint("%d of %d pixels above the box inked", aink, atot), abox);

	# 3.  Two abutting fills: a stride error paints the second one over
	#     the first.  Count each half separately, on the middle row.
	lh := Rect((r.min.x, r.min.y), (r.min.x + r.dx() / 2, r.max.y));
	rh := Rect((lh.max.x, r.min.y), (r.max.x, r.max.y));
	scr.draw(r, black, nil, (0, 0));
	scr.draw(lh, green, nil, (0, 0));
	scr.draw(rh, white, nil, (0, 0));
	scr.flush(Draw->Flushnow);
	my := r.min.y + r.dy() / 2;
	(ltot, link, nil, lholes) := countink(scr, Rect((lh.min.x, my), (lh.max.x, my + 1)), bpp);
	(rtot, rink, nil, rholes) := countink(scr, Rect((rh.min.x, my), (rh.max.x, my + 1)), bpp);
	report("halves", link == ltot && rink == rtot,
		sys->sprint("left %d/%d right %d/%d", link, ltot, rink, rtot),
		rectunion(lholes, rholes));

	# 4.  Glyph ink.  The built-in font needs no /fonts, so this runs on a
	#     board with no filesystem.  A text draw that lands nowhere is the
	#     failure the colour fills cannot see: it goes through a different
	#     memdraw path (a mask, not a solid source).
	scr.draw(r, black, nil, (0, 0));
	font := Font.open(disp, "*default*");
	if(font == nil)
		sys->print("drawink: SKIP text: Font.open: %r\n");
	else{
		p := scr.text((r.min.x + 8, r.min.y + 8), white, (0, 0), font, "drawink");
		scr.flush(Draw->Flushnow);
		tr := Rect((r.min.x, r.min.y), (p.x + 1, r.min.y + 8 + font.height + 1));
		(ttot, tink, tbox, nil) := countink(scr, tr, bpp);
		report("text ink", tink > 0 && tink < ttot,
			sys->sprint("%d of %d pixels inked, advance %d, ink box %d,%d %d,%d",
				tink, ttot, p.x - (r.min.x + 8),
				tbox.min.x, tbox.min.y, tbox.max.x, tbox.max.y), ZR);
	}

	# 5.  The region a frame did NOT redraw.  This is the acceptance test
	#     for double buffering with incremental drawing: with two buffers
	#     the back one holds the frame before last, so everything the
	#     current frame does not redraw has to be copied forward before
	#     the flip.  If that repair is missing -- or is a no-op, which is
	#     how the first version of it was written -- then the drawn region
	#     is still perfectly right and only the UNDRAWN region is wrong.
	#     None of checks 1-4 looks there: they all read where ink was just
	#     put.
	#
	#     Three presents with three distinct fills, capturing the actual
	#     bytes each time rather than assuming a channel order, so the
	#     failure can say WHICH generation it found:
	#
	#	present 1  all white     -> gen1 bytes
	#	present 2  all green     -> gen2 bytes
	#	present 3  a small box   -> read the same strip again
	#
	#     Outside the box the strip must still read gen2.  Reading gen1
	#     means the repair did not happen and the buffer is two frames
	#     stale, which is the exact signature of a missing or no-op copy.
	#
	#     WITH A SINGLE BUFFER THIS PASSES TRIVIALLY, and that is stated
	#     rather than hidden: it can only fail when double buffering is on
	#     and wrong, which is what it is for.  It is not blind -- a broken
	#     flip makes it fail -- but a PASS here is not evidence that double
	#     buffering is enabled.
	far := Rect((r.min.x, r.max.y - 2), (r.max.x, r.max.y - 1));
	gen1 := array[far.dx() * bpp] of byte;
	gen2 := array[far.dx() * bpp] of byte;
	gen3 := array[far.dx() * bpp] of byte;
	scr.draw(r, white, nil, (0, 0));
	scr.flush(Draw->Flushnow);
	n1 := scr.readpixels(far, gen1);
	scr.draw(r, green, nil, (0, 0));
	scr.flush(Draw->Flushnow);
	n2 := scr.readpixels(far, gen2);
	# A small box far from the strip: its damage must not cover the strip,
	# or there is nothing left for the repair to have to carry forward.
	tiny := Rect((r.min.x + 4, r.min.y + 4), (r.min.x + 20, r.min.y + 20));
	scr.draw(tiny, red, nil, (0, 0));
	scr.flush(Draw->Flushnow);
	n3 := scr.readpixels(far, gen3);
	if(n1 != len gen1 || n2 != len gen2 || n3 != len gen3){
		sys->print("drawink: FAIL undrawn readpixels %d %d %d of %d: %r\n",
			n1, n2, n3, len gen1);
		nfail++;
	}else if(eqbytes(gen1, gen2)){
		# The two fills read identically, so the check cannot tell a
		# stale buffer from a fresh one.  Say so instead of passing.
		sys->print("drawink: SKIP undrawn: white and green read alike\n");
	}else{
		detail := "";
		if(eqbytes(gen3, gen2))
			detail = "still the last frame's fill";
		else if(eqbytes(gen3, gen1))
			detail = "TWO FRAMES STALE -- the repair did not happen";
		else
			detail = sys->sprint("neither fill: %d bytes differ from the last",
				ndiff(gen3, gen2));
		report("undrawn region", eqbytes(gen3, gen2), detail, ZR);
	}

	# Leave something a human can recognise rather than the debris of the
	# last check, and put the cursor back the way it was.
	scr.draw(r, black, nil, (0, 0));
	if(font != nil)
		scr.text((r.min.x + 8, r.min.y + 8), white, (0, 0), font,
			sys->sprint("drawink: %d failures", nfail));
	scr.flush(Draw->Flushnow);
	if(cf != nil)
		sys->write(cf, array[0] of byte, 0);

	if(nfail > 0){
		sys->print("drawink: %d checks FAILED\n", nfail);
		raise "fail:checks failed";
	}
	sys->print("drawink: all checks passed\n");
}

# Make the pointer invisible for the duration by installing an all-zero
# 16x16 cursor, and hand back the open fd so the caller can restore the
# default with a zero-length write.  A kernel with no pointer device just
# gets no cursor, which is the state the test wants anyway.
hidecursor(dev: string): ref Sys->FD
{
	fd := sys->open(dev + "/cursor", Sys->OWRITE);
	if(fd == nil){
		sys->print("drawink: no %s/cursor (%r); a soft cursor would read as holes\n", dev);
		return nil;
	}
	# hotx[4] hoty[4] dx[4] dy[4] then dx/8*dy bytes of all-zero mask.
	# The four counts are little-endian: the device reads them with
	# BG32INT, which despite the name composes two little-endian halves
	# in little-endian order (include/draw.h).  devpointer.c's comment
	# calls them big-endian and is wrong.
	b := array[4 * 4 + 16 / 8 * 16] of {* => byte 0};
	b[8] = byte 16;			# dx
	b[12] = byte 16;		# dy
	if(sys->write(fd, b, len b) != len b){
		sys->print("drawink: write %s/cursor: %r\n", dev);
		return nil;
	}
	return fd;
}

report(what: string, ok: int, detail: string, where: Rect)
{
	if(ok){
		sys->print("drawink: PASS %s: %s\n", what, detail);
		return;
	}
	s := "";
	if(where.dx() > 0 && where.dy() > 0)
		s = sys->sprint(", disagreeing pixels within %d,%d %d,%d (%dx%d)",
			where.min.x, where.min.y, where.max.x, where.max.y,
			where.dx(), where.dy());
	sys->print("drawink: FAIL %s: %s%s\n", what, detail, s);
	nfail++;
}

eqbytes(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

ndiff(a, b: array of byte): int
{
	n := 0;
	for(i := 0; i < len a && i < len b; i++)
		if(a[i] != b[i])
			n++;
	return n;
}

rectunion(a, b: Rect): Rect
{
	if(a.dx() <= 0 || a.dy() <= 0)
		return b;
	if(b.dx() <= 0 || b.dy() <= 0)
		return a;
	return Rect((min(a.min.x, b.min.x), min(a.min.y, b.min.y)),
		(max(a.max.x, b.max.x), max(a.max.y, b.max.y)));
}

min(a, b: int): int
{
	if(a < b)
		return a;
	return b;
}

max(a, b: int): int
{
	if(a > b)
		return a;
	return b;
}

# Read r back out of the image and return (pixels, inked, inkbox,
# holebox), where inked counts pixels with any non-zero byte and the two
# boxes bound the inked and the un-inked pixels.  Reads a row at a time
# so the buffer stays small on a big screen.
countink(img: ref Image, r: Rect, bpp: int): (int, int, Rect, Rect)
{
	if(r.dx() <= 0 || r.dy() <= 0)
		return (0, 0, ZR, ZR);
	buf := array[r.dx() * bpp] of byte;
	tot := 0;
	ink := 0;
	inkbox := ZR;
	holebox := ZR;
	for(y := r.min.y; y < r.max.y; y++){
		row := Rect((r.min.x, y), (r.max.x, y + 1));
		if((n := img.readpixels(row, buf)) != len buf){
			sys->print("drawink: readpixels row %d: %d of %d: %r\n", y, n, len buf);
			return (tot, ink, inkbox, holebox);
		}
		for(x := 0; x < r.dx(); x++){
			tot++;
			lit := 0;
			for(i := 0; i < bpp; i++)
				if(int buf[x * bpp + i] != 0){
					lit = 1;
					break;
				}
			px := Rect((r.min.x + x, y), (r.min.x + x + 1, y + 1));
			if(lit){
				ink++;
				inkbox = rectunion(inkbox, px);
			}else
				holebox = rectunion(holebox, px);
		}
	}
	return (tot, ink, inkbox, holebox);
}
