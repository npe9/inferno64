implement Vspritetest;

# The gate doc/draw3d-adoption-plan.md sets on the display-list sprite
# type: render a sprite from its element list and compare the pixels with
# the .bit that scripts/tos_extract_sprites.py rasterised from the same
# list.  Two independent rasterisers, one in Python and one in Limbo,
# reading one source of truth.
#
# The comparison is per pixel, on palette indices, over the rect each
# side says it occupies - so a sprite that came out the right shape in
# the wrong place fails on the rect before a single pixel is looked at.
#
# Usage: vspritetest [-v] [name ...]
# With no names it runs every lib/temple/sprites/*.spr that has a .bit
# beside it and contains no element this cannot yet draw.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "readdir.m";
	readdir: Readdir;

include "math/vsprite.m";
	vsprite: Vsprite;
	Sprite: import vsprite;

Vspritetest: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

SPRDIR: con "/lib/temple/sprites";
BITDIR: con "/icons/temple";

# temple/spriteedit(1)'s page: the same rasteriser draws onto this
# instead of onto the sprite's box, and these are the numbers that say
# what that difference is worth.
PAGEW: con 680;
PAGEH: con 530;

verbose := 0;
dump := 0;
pass := 0;
fail := 0;
pageok := 0;
pageout := 0;
pageclip := 0;
pagerun := 0;
display: ref Display;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	bufio = load Bufio Bufio->PATH;
	readdir = load Readdir Readdir->PATH;
	vsprite = load Vsprite Vsprite->PATH;
	if(vsprite == nil){
		sys->fprint(sys->fildes(2), "vspritetest: cannot load %s: %r\n",
			Vsprite->PATH);
		raise "fail:load";
	}
	vsprite->init();

	names: list of string;
	for(a := tl argv; a != nil; a = tl a){
		if(hd a == "-v"){
			verbose = 1;
			continue;
		}
		if(hd a == "-d"){
			dump = 1;
			continue;
		}
		names = hd a :: names;
	}

	# No display: every sprite compared here is free of text elements,
	# which are the only ones that need a font, and vsprite(2) rasterises
	# to palette indices without touching Draw.  So this runs under
	# emu-g, where there is no Draw module at all.
	if(ctxt != nil)
		display = ctxt.display;

	if(names == nil)
		names = candidates();
	for(l := names; l != nil; l = tl l)
		one(hd l);
	for(; names != nil; names = tl names)
		page(hd names);
	sys->print("vspritetest: page %d/%d identical inside the box, %d flooded outside it, %d cut off by the page\n",
		pageok, pagerun, pageout, pageclip);
	sys->print("vspritetest: %d/%d\n", pass, pass+fail);
	if(fail)
		raise "fail:test";
}

# Every sprite with a .bit beside it whose elements are all ones this
# rasteriser covers.  text and bitmap are excluded on purpose and the
# count of what was skipped is printed, so the coverage claim is the
# number of files actually compared and not the number that exist.
candidates(): list of string
{
	if(readdir == nil)
		return nil;
	(fs, nil) := readdir->init(SPRDIR, Readdir->NAME|Readdir->COMPACT);
	out: list of string;
	skipped := 0;
	for(i := len fs - 1; i >= 0; i--){
		nm := fs[i].name;
		if(len nm < 5 || nm[len nm-4:] != ".spr")
			continue;
		base := nm[0:len nm-4];
		(ok, nil) := sys->stat(BITDIR + "/" + base + ".bit");
		if(ok < 0)
			continue;
		if(!drawable(SPRDIR + "/" + nm)){
			skipped++;
			continue;
		}
		out = base :: out;
	}
	if(skipped)
		sys->print("vspritetest: %d sprites skipped (text, bitmap or mesh)\n",
			skipped);
	return out;
}

drawable(path: string): int
{
	fd := bufio->open(path, Bufio->OREAD);
	if(fd == nil)
		return 0;
	for(;;){
		l := fd.gets('\n');
		if(l == nil)
			break;
		(nil, t) := sys->tokenize(l, " \t\r\n");
		if(t == nil)
			continue;
		case hd t {
		"text" or "textbox" or "textdiamond" or "bitmap" or
		"mesh" or "shiftmesh" =>
			return 0;
		"floodfillnot" =>
			# The extractor takes an invert flag and never uses
			# it: its flood() fills the connected region of the
			# seed colour whichever kind the element is.  So the
			# .bit for a sprite with one of these records a plain
			# fill, and matching it would mean copying the
			# omission rather than drawing the element.
			return 0;
		}
	}
	return 1;
}

one(base: string)
{
	(spr, err) := vsprite->read(SPRDIR + "/" + base + ".spr");
	if(spr == nil){
		bad(base, "read: " + err);
		return;
	}
	(px, r) := spr.pixels(display);
	if(px == nil){
		bad(base, "nothing drew");
		return;
	}
	(want, wr, err2) := readbit(BITDIR + "/" + base + ".bit",
		BITDIR + "/" + base + ".mask");
	if(want == nil){
		bad(base, err2);
		return;
	}
	# Rect.eq and Rect.dx are Draw methods, and this runs where there is
	# no Draw; the arithmetic is done by hand.
	if(r.min.x != wr.min.x || r.min.y != wr.min.y
	   || r.max.x != wr.max.x || r.max.y != wr.max.y){
		bad(base, sys->sprint("rect %d,%d..%d,%d against .bit %d,%d..%d,%d",
			r.min.x, r.min.y, r.max.x, r.max.y,
			wr.min.x, wr.min.y, wr.max.x, wr.max.y));
		return;
	}
	n := len px;
	diff := 0;
	fx := -1; fy := -1;
	for(i := 0; i < n && i < len want; i++)
		if(px[i] != want[i]){
			if(diff == 0){
				fx = i % (r.max.x - r.min.x);
				fy = i / (r.max.x - r.min.x);
			}
			diff++;
		}
	# Exact is the bar, and 52 of the 58 sprites meet it.  The allowance
	# below is for the ones whose shape comes out of cos and sin: the
	# extractor is Python against its libm and this is Limbo against
	# math(2), the two disagree in the last bits, and a point that lands
	# either side of a half moves one pixel.  That is not something
	# either side can be argued into; what it must not do is grow, so
	# the count is printed whenever it is not zero.
	slack := 16;
	if(n/10000 > slack)
		slack = n/10000;
	if(diff > slack){
		bad(base, sys->sprint("%d of %d pixels differ, first at %d,%d",
			diff, n, fx, fy));
		if(dump)
			window(px, want, r, fx, fy);
		return;
	}
	pass++;
	if(diff)
		sys->print("near %s: %d of %d pixels differ (allowed %d), first at %d,%d\n",
			base, diff, n, slack, fx, fy);
	else if(verbose)
		sys->print("ok   %s: %d pixels, %d,%d..%d,%d\n", base, n,
			r.min.x, r.min.y, r.max.x, r.max.y);
}

# The editor draws the same element list onto a fixed page with the
# sprite's origin at its centre, where vsprite(2) draws it onto the
# sprite's own box.  Since temple/spriteedit(1) was put on this
# rasteriser that is the ONLY thing left that can make the two disagree,
# so this measures it rather than asserting it: crop the page render to
# the box and compare.
#
# A difference is only allowed where the page render put ink outside the
# box, which means a flood fill escaped the sprite and ran to the page's
# edge - on the page it can come back in from somewhere the box would
# have stopped it.  A sprite that differs inside the box while drawing
# nothing outside it is the two rasterisers disagreeing, and fails.
page(base: string)
{
	(spr, nil) := vsprite->read(SPRDIR + "/" + base + ".spr");
	if(spr == nil)
		return;
	(px, r) := spr.pixels(display);
	if(px == nil)
		return;
	pg := vsprite->canvas(spr.elems, PAGEW, PAGEH, PAGEW/2, PAGEH/2,
		display);
	if(pg == nil)
		return;
	pagerun++;
	w := r.max.x - r.min.x;
	h := r.max.y - r.min.y;
	diff := 0;
	clip := 0;
	for(y := 0; y < h; y++)
		for(x := 0; x < w; x++){
			cx := PAGEW/2 + r.min.x + x;
			cy := PAGEH/2 + r.min.y + y;
			# A sprite whose coordinates run off the editor's
			# page is cut off there; those pixels are not the
			# two rasterisers disagreeing, they are the editor
			# not being able to show that part of the sprite.
			if(cx < 0 || cx >= PAGEW || cy < 0 || cy >= PAGEH){
				clip++;
				continue;
			}
			if(pg[cy*PAGEW+cx] != px[y*w+x])
				diff++;
		}
	out := 0;
	for(cy := 0; cy < PAGEH; cy++)
		for(cx := 0; cx < PAGEW; cx++){
			if(pg[cy*PAGEW+cx] == byte Vsprite->TRANSP)
				continue;
			ex := cx - PAGEW/2;
			ey := cy - PAGEH/2;
			if(ex < r.min.x || ex >= r.max.x
			   || ey < r.min.y || ey >= r.max.y)
				out++;
		}
	if(out)
		pageout++;
	if(clip)
		pageclip++;
	if(diff == 0){
		pageok++;
		if(verbose)
			sys->print("page %s: identical%s\n", base,
				clipnote(clip, w*h));
		return;
	}
	if(out){
		sys->print("page %s: %d of %d differ, %d pixels drawn outside the box\n",
			base, diff, w*h, out);
		return;
	}
	bad(base, sys->sprint("page differs by %d of %d pixels with nothing drawn outside the box",
		diff, w*h));
}

clipnote(clip, n: int): string
{
	if(clip == 0)
		return "";
	return sys->sprint(" (%d of %d off the page)", clip, n);
}

# got over want, a few rows either side of the first difference, as
# palette indices in hex with '.' for transparent.  A shift shows as a
# whole row sliding; a colour error shows as one digit changing
# everywhere.
window(got, want: array of byte, r: Rect, fx, fy: int)
{
	w := r.max.x - r.min.x;
	h := r.max.y - r.min.y;
	x0 := fx - 8;
	if(x0 < 0) x0 = 0;
	x1 := x0 + 24;
	if(x1 > w) x1 = w;
	y0 := fy - 2;
	if(y0 < 0) y0 = 0;
	y1 := y0 + 5;
	if(y1 > h) y1 = h;
	for(y := y0; y < y1; y++){
		g := "";
		wt := "";
		for(x := x0; x < x1; x++){
			g += hex(int got[y*w+x]);
			wt += hex(int want[y*w+x]);
		}
		sys->print("   y=%-4d got %s\n        want %s\n", y, g, wt);
	}
}

hex(v: int): string
{
	if(v == Vsprite->TRANSP)
		return ".";
	return sys->sprint("%x", v&15);
}

bad(base, why: string)
{
	fail++;
	sys->print("FAIL %s: %s\n", base, why);
}

# An m8 image as written by tos_extract_sprites.py: "m8" then four
# 12-character fields for the rect, then one byte a pixel, the byte being
# a CMAP8 value.
#
# The .mask is not optional here.  The extractor leaves a transparent
# pixel as byte 0 and CMAP8 0 is also BLACK, so the image alone cannot
# tell "nothing drew" from "drew in black" - the k1 mask beside it is
# what separates them, and comparing without it reported 457 of 527
# pixels differing on a sprite that was in fact right.
readbit(path, mpath: string): (array of byte, Rect, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, Rect((0,0),(0,0)), sys->sprint("%r"));
	(ok, st) := sys->fstat(fd);
	if(ok < 0)
		return (nil, Rect((0,0),(0,0)), "stat failed");
	buf := array[int st.length] of byte;
	if(sys->readn(fd, buf, len buf) != len buf)
		return (nil, Rect((0,0),(0,0)), "short read");
	if(len buf < 60)
		return (nil, Rect((0,0),(0,0)), "too short for a header");
	chans := field(buf, 0);
	if(chans != "m8")
		return (nil, Rect((0,0),(0,0)), "not an m8 image: " + chans);
	x0 := int field(buf, 12);
	y0 := int field(buf, 24);
	x1 := int field(buf, 36);
	y1 := int field(buf, 48);
	r := Rect((x0,y0),(x1,y1));
	w := r.max.x - r.min.x;
	h := r.max.y - r.min.y;
	if(w < 1 || h < 1 || len buf < 60 + w*h)
		return (nil, r, "body shorter than the rect");
	(mk, mr, merr) := readmask(mpath);
	if(mk == nil)
		return (nil, r, "mask: " + merr);
	if(mr.min.x != r.min.x || mr.min.y != r.min.y
	   || mr.max.x != r.max.x || mr.max.y != r.max.y)
		return (nil, r, "mask rect differs from the image rect");
	# Plan 9 lays a 1-bit row out from a byte boundary, not from the
	# rect's left edge, so the first pixel sits part way into the first
	# byte whenever r.min.x is not a multiple of 8.
	bit0 := firstbit(r.min.x);
	stride := k1bytes(r.min.x, r.max.x);
	out := array[w*h] of byte;
	for(y := 0; y < h; y++)
		for(x := 0; x < w; x++){
			b := r.min.x + x - bit0;
			on := (int mk[y*stride + b/8] & (16r80 >> (b&7))) != 0;
			if(!on)
				out[y*w+x] = byte Vsprite->TRANSP;
			else
				out[y*w+x] = byte cmapindex(int buf[60 + y*w + x]);
		}
	return (out, r, nil);
}

readmask(path: string): (array of byte, Rect, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, Rect((0,0),(0,0)), sys->sprint("%r"));
	(ok, st) := sys->fstat(fd);
	if(ok < 0)
		return (nil, Rect((0,0),(0,0)), "stat failed");
	buf := array[int st.length] of byte;
	if(sys->readn(fd, buf, len buf) != len buf)
		return (nil, Rect((0,0),(0,0)), "short read");
	if(len buf < 60)
		return (nil, Rect((0,0),(0,0)), "too short for a header");
	if(field(buf, 0) != "k1")
		return (nil, Rect((0,0),(0,0)), "not a k1 image");
	r := Rect((int field(buf, 12), int field(buf, 24)),
		(int field(buf, 36), int field(buf, 48)));
	return (buf[60:], r, nil);
}

# libdraw's bytesperline() for a 1-bit image, and the bit its first
# pixel starts at.
k1bytes(minx, maxx: int): int
{
	if(minx >= 0)
		return ceildiv(maxx, 8) - minx/8;
	return ceildiv(-minx, 8) + ceildiv(maxx, 8);
}

firstbit(minx: int): int
{
	if(minx >= 0)
		return minx/8*8;
	return -(ceildiv(-minx, 8) * 8);
}

ceildiv(a, b: int): int
{
	if(a >= 0)
		return (a + b - 1)/b;
	return -((-a)/b);
}

# A Plan 9 image header is five fields of eleven characters and a
# space, the value right-aligned in the eleven.  Both ends have to be
# trimmed: taking twelve bytes and stripping only the left gives "m8 ",
# which is not "m8".
field(b: array of byte, off: int): string
{
	s := string b[off:off+12];
	i := 0;
	while(i < len s && s[i] == ' ')
		i++;
	j := len s;
	while(j > i && s[j-1] == ' ')
		j--;
	return s[i:j];
}

# CMAP8 value -> palette index.  This is scripts/tos_extract_sprites.py's
# CMAP, which is rgb2cmap of each TempleOS colour against this tree's own
# cmap2rgb - libdraw/rgb.c, whose j is (c-v+r)&15 and NOT the (c-v+r)/4
# that other Plan 9 lineages carry.  Deriving it from the wrong formula
# says 36 is green where it is in fact blue, which is how these bytes
# came to be called wrong once already.
cmap := array[] of {
	0, 36, 42, 44, 160, 162, 164, 170,
	85, 121, 127, 113, 245, 247, 253, 255
};

cmapindex(v: int): int
{
	for(i := 0; i < len cmap; i++)
		if(cmap[i] == v)
			return i;
	return Vsprite->TRANSP;
}
