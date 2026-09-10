implement Command;

# Checks nes(2) itself, which the games on top of it only exercise
# indirectly: a game's own test asserts on the game's state and would
# pass with every tile drawn in the wrong palette.  This one reads the
# pixels back and compares them against the palette entries they are
# supposed to be, so it can see what a game's test cannot.
#
# Everything is drawn into memory images.  Nothing here needs a window.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "keyboard.m";

include "nes.m";
	nes: Nes;
	Chr, Pal, Surface: import nes;

Command: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# Two tiles: a solid square of each colour in turn, and one with a hole
# in it, so transparency and flipping have something to show.
ART := array[] of {
	# 0: a ring of 1, a ring of 2, a middle of 3
	"11111111",
	"12222221",
	"12333321",
	"12333321",
	"12333321",
	"12333321",
	"12222221",
	"11111111",
	# 1: deliberately lopsided, so a flip is not a no-op
	"3.......",
	"33......",
	"333.....",
	"3333....",
	"22......",
	"22......",
	"11......",
	"11......",
};

# One 16x16, whose four quadrants each hold a different colour, so
# meta() putting them in the wrong order is visible.
ART16 := array[] of {
	"11111111 2222222",
	"11111111 2222222",
	"11111111 2222222",
	"11111111 2222222",
	"11111111 2222222",
	"11111111 2222222",
	"11111111 2222222",
	"11111111 2222222",
	"33333333 1111111",
	"33333333 1111111",
	"33333333 1111111",
	"33333333 1111111",
	"33333333 1111111",
	"33333333 1111111",
	"33333333 1111111",
	"33333333 1111111",
};

d: ref Display;
nfail := 0;

ck(what: string, got, want: int)
{
	if(got == want){
		sys->print("ok   %s = %d\n", what, got);
		return;
	}
	sys->print("FAIL %s = %d, want %d\n", what, got, want);
	nfail++;
}

ckx(what: string, got, want: int)
{
	if(got == want){
		sys->print("ok   %s = %06x\n", what, got & 16rFFFFFF);
		return;
	}
	sys->print("FAIL %s = %06x, want %06x\n", what,
		got & 16rFFFFFF, want & 16rFFFFFF);
	nfail++;
}

cktrue(what: string, v: int)
{
	if(v){
		sys->print("ok   %s\n", what);
		return;
	}
	sys->print("FAIL %s\n", what);
	nfail++;
}

# One pixel of a surface, as 0xRRGGBB.  RGB24 reads back blue, green,
# red, which is not the order anybody guesses.
at(s: ref Surface, x, y: int): int
{
	b := array[3] of byte;
	r := Rect((x, y), (x+1, y+1));
	if(s.img.readpixels(r, b) < 0)
		return -1;
	return (int b[2] << 16) | (int b[1] << 8) | int b[0];
}

rgb24(i: int): int
{
	return (nes->rgb(i) >> 8) & 16rFFFFFF;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	nes = load Nes Nes->PATH;
	if(nes == nil){
		sys->print("nestest: cannot load nes: %r\n");
		raise "fail:load";
	}
	e := nes->init();
	if(e != nil){
		sys->print("nestest: %s\n", e);
		raise "fail:init";
	}
	d = Display.allocate(nil);
	if(d == nil){
		sys->print("nestest: no display: %r\n");
		raise "fail:display";
	}
	palette();
	tiles();
	drawing();
	scrolling();
	input();
	if(nfail == 0)
		sys->print("nestest: PASSED\n");
	else{
		sys->print("nestest: FAILED (%d)\n", nfail);
		raise "fail:nestest";
	}
}

palette()
{
	sys->print("nestest: the master palette\n");
	# The greys are grey, and they climb.
	last := -1;
	up := 1;
	for(r := 0; r < 4; r++){
		v := rgb24(nes->entry(r, Nes->GREY));
		rr := (v >> 16) & 16rFF;
		gg := (v >> 8) & 16rFF;
		bb := v & 16rFF;
		if(rr != gg || gg != bb){
			sys->print("FAIL grey row %d is %06x\n", r, v);
			nfail++;
		}
		if(rr <= last)
			up = 0;
		last = rr;
	}
	cktrue("the greys climb from dark to pale", up);
	ckx("the palest grey is white", rgb24(nes->entry(Nes->PALE, Nes->GREY)),
		16rFFFFFF);
	ckx("column 13 is black", rgb24(nes->entry(Nes->MID, Nes->BLACK)), 0);

	# Twelve distinct hues on the mid row.
	n := 0;
	for(c := Nes->RED; c <= Nes->ROSE; c++)
		for(c2 := c+1; c2 <= Nes->ROSE; c2++)
			if(rgb24(nes->entry(Nes->MID, c)) ==
			   rgb24(nes->entry(Nes->MID, c2)))
				n++;
	ck("no two hues on a row are the same", n, 0);

	# A hue gets brighter across the rows.
	dark := rgb24(nes->entry(Nes->DARK, Nes->CYAN));
	pale := rgb24(nes->entry(Nes->PALE, Nes->CYAN));
	cktrue("a hue brightens down the rows", lum(pale) > lum(dark));

	# Out of range is clamped rather than faulting.
	ckx("entry clamps low", rgb24(nes->entry(-5, -5)),
		rgb24(nes->entry(0, 0)));
	ckx("entry clamps high", rgb24(nes->entry(99, 99)),
		rgb24(nes->entry(3, 15)));
}

lum(v: int): int
{
	return ((v>>16) & 16rFF) + ((v>>8) & 16rFF) + (v & 16rFF);
}

tiles()
{
	sys->print("nestest: tile sheets\n");
	c := nes->chr(d, Draw->RGB24, 2, ART);
	ck("two tiles", c.n, 2);
	ck("corner is colour 1", c.pix(0, 0, 0), 1);
	ck("inside is colour 2", c.pix(0, 1, 1), 2);
	ck("middle is colour 3", c.pix(0, 3, 3), 3);
	ck("a dot is colour 0", c.pix(1, 7, 0), 0);
	ck("out of range reads 0", c.pix(99, 0, 0), 0);

	# meta(): four quadrants, in the order top left, top right, bottom
	# left, bottom right.  Getting this wrong scrambles every 16x16
	# character in every game, so it is worth checking by colour rather
	# than by eye.
	m := nes->chr(d, Draw->RGB24, 2, nes->meta(ART16));
	ck("one 16x16 makes four tiles", m.n, 4);
	ck("top left quadrant", m.pix(0, 0, 0), 1);
	ck("top right quadrant", m.pix(1, 1, 0), 2);
	ck("bottom left quadrant", m.pix(2, 0, 0), 3);
	ck("bottom right quadrant", m.pix(3, 1, 0), 1);
	ck("the gap between them is colour 0", m.pix(1, 0, 0), 0);

	f := nes->font(d, Draw->RGB24, 2);
	cktrue("the font loads", f != nil);
	if(f != nil){
		ck("256 glyphs", f.n, 256);
		n := 0;
		for(y := 0; y < 8; y++)
			for(x := 0; x < 8; x++)
				if(f.pix('A', x, y) != 0)
					n++;
		cktrue("A is not blank", n > 4);
		n = 0;
		for(y = 0; y < 8; y++)
			for(x = 0; x < 8; x++)
				if(f.pix(' ', x, y) != 0)
					n++;
		ck("space is blank", n, 0);
	}
}

drawing()
{
	sys->print("nestest: drawing\n");
	SC: con 2;
	bk := nes->entry(Nes->DARK, Nes->BLACK);
	c := nes->chr(d, Draw->RGB24, SC, ART);
	f := nes->font(d, Draw->RGB24, SC);
	pa := nes->pal(bk, nes->entry(Nes->MID, Nes->RED),
		nes->entry(Nes->MID, Nes->GREEN), nes->entry(Nes->MID, Nes->BLUE));
	pb := nes->pal(bk, nes->entry(Nes->MID, Nes->CYAN),
		nes->entry(Nes->MID, Nes->YELLOW), nes->entry(Nes->MID, Nes->MAGENTA));
	s := nes->surface(d, c, f, 64, 64, nes->entry(Nes->PALE, Nes->GREY));
	cktrue("a surface is made", s != nil);
	if(s == nil)
		return;
	ck("the image is scale times the logical size", s.img.r.dx(), 64*SC);
	ckx("and starts in its background colour", at(s, 0, 0),
		rgb24(nes->entry(Nes->PALE, Nes->GREY)));

	# tile(): opaque, at tile coordinates, in the palette given.
	s.tile(1, 1, 0, pa);
	ckx("tile corner is palette colour 1", at(s, 8*SC, 8*SC),
		rgb24(nes->entry(Nes->MID, Nes->RED)));
	ckx("tile inside is colour 2", at(s, 9*SC, 9*SC),
		rgb24(nes->entry(Nes->MID, Nes->GREEN)));
	ckx("tile middle is colour 3", at(s, 11*SC, 11*SC),
		rgb24(nes->entry(Nes->MID, Nes->BLUE)));
	# and the scale really is a block, not a point
	ckx("a logical pixel is a block of real ones", at(s, 8*SC+1, 8*SC+1),
		rgb24(nes->entry(Nes->MID, Nes->RED)));

	# The composite cache is keyed by palette as well as by tile.  If it
	# were not, this second draw would come out in the first palette's
	# colours - which looks like a working game in one colour scheme.
	s.tile(3, 1, 0, pb);
	ckx("the same tile in another palette", at(s, 24*SC, 8*SC),
		rgb24(nes->entry(Nes->MID, Nes->CYAN)));
	s.tile(5, 1, 0, pa);
	ckx("and back again in the first", at(s, 40*SC, 8*SC),
		rgb24(nes->entry(Nes->MID, Nes->RED)));

	# put(): colour 0 is transparent.  Tile 1 is empty at its top right.
	s.fill(Rect((0, 24), (64, 32)), nes->entry(Nes->MID, Nes->LIME));
	s.put(0, 24, 1, pa, 0);
	ckx("put draws colour 3", at(s, 0, 24*SC),
		rgb24(nes->entry(Nes->MID, Nes->BLUE)));
	ckx("and leaves colour 0 alone", at(s, 7*SC, 24*SC),
		rgb24(nes->entry(Nes->MID, Nes->LIME)));

	# tile() does NOT: colour 0 is the background there.
	s.fill(Rect((16, 24), (64, 32)), nes->entry(Nes->MID, Nes->LIME));
	s.tile(2, 3, 1, pa);
	ckx("tile paints colour 0 as the background", at(s, 23*SC, 24*SC),
		rgb24(bk));

	# Flips.  Tile 1 is lopsided on purpose: colour 3 is at its left
	# edge and nothing is at its right.
	s.fill(Rect((0, 40), (64, 48)), nes->entry(Nes->MID, Nes->LIME));
	s.put(0, 40, 1, pa, Nes->FLIPX);
	ckx("flipx moves colour 3 to the right", at(s, 7*SC, 40*SC),
		rgb24(nes->entry(Nes->MID, Nes->BLUE)));
	ckx("and clears the left", at(s, 0, 40*SC),
		rgb24(nes->entry(Nes->MID, Nes->LIME)));
	s.fill(Rect((8, 40), (64, 48)), nes->entry(Nes->MID, Nes->LIME));
	s.put(8, 40, 1, pa, Nes->FLIPY);
	ckx("flipy moves colour 1 to the top", at(s, 8*SC, 40*SC),
		rgb24(nes->entry(Nes->MID, Nes->RED)));

	# put16: the quadrants land where meta() put them, and FLIPX swaps
	# the halves as well as mirroring each.
	m := nes->chr(d, Draw->RGB24, SC, nes->meta(ART16));
	s2 := nes->surface(d, m, f, 64, 64, bk);
	s2.put16(0, 0, 0, pa, 0);
	ckx("put16 top left", at(s2, 0, 0), rgb24(nes->entry(Nes->MID, Nes->RED)));
	ckx("put16 top right", at(s2, 9*SC, 0),
		rgb24(nes->entry(Nes->MID, Nes->GREEN)));
	ckx("put16 bottom left", at(s2, 0, 8*SC),
		rgb24(nes->entry(Nes->MID, Nes->BLUE)));
	s2.put16(16, 0, 0, pa, Nes->FLIPX);
	ckx("flipx swaps the halves", at(s2, (16+15)*SC, 0),
		rgb24(nes->entry(Nes->MID, Nes->RED)));

	# text: one glyph every eight logical pixels, and a space leaves the
	# ground alone.
	s.fill(Rect((0, 52), (64, 60)), nes->entry(Nes->MID, Nes->LIME));
	s.text(0, 52, "A A", pa);
	na := lit(s, 0, 52, 8, 8);
	nb := lit(s, 8, 52, 8, 8);
	ncc := lit(s, 16, 52, 8, 8);
	cktrue("text drew the first letter", na > 0);
	ck("and nothing where the space is", nb, 0);
	cktrue("and the second letter one glyph further on", ncc > 0);
	ck("both letters the same", na, ncc);
}

# Logical pixels in a box that are not the ground colour it was filled
# with.  Counting what CHANGED, not what is lit, so a glyph drawn in the
# ground's own colour would still read as nothing.
lit(s: ref Surface, x, y, w, h: int): int
{
	g := rgb24(nes->entry(Nes->MID, Nes->LIME));
	n := 0;
	for(j := 0; j < h; j++)
		for(i := 0; i < w; i++)
			if(at(s, (x+i)*s.scale, (y+j)*s.scale) != g)
				n++;
	return n;
}

scrolling()
{
	sys->print("nestest: view and blit\n");
	SC: con 2;
	bk := nes->entry(Nes->DARK, Nes->BLACK);
	c := nes->chr(d, Draw->RGB24, SC, ART);
	f := nes->font(d, Draw->RGB24, SC);
	# A level twice as wide as a screen, with a marker at each end.
	lvl := nes->surface(d, c, f, Nes->W*2, Nes->H, bk);
	scr := nes->surface(d, c, f, Nes->W, Nes->H, bk);
	lvl.fill(Rect((0,0),(8,8)), nes->entry(Nes->MID, Nes->YELLOW));
	lvl.fill(Rect((Nes->W*2-8, 0), (Nes->W*2, 8)),
		nes->entry(Nes->MID, Nes->CYAN));
	lvl.fill(Rect((Nes->W, 0), (Nes->W+8, 8)),
		nes->entry(Nes->MID, Nes->MAGENTA));

	lvl.view(scr, 0, 0);
	ckx("view at 0 shows the left end", at(scr, 0, 0),
		rgb24(nes->entry(Nes->MID, Nes->YELLOW)));
	lvl.view(scr, Nes->W, 0);
	ckx("view at one screen shows the middle marker", at(scr, 0, 0),
		rgb24(nes->entry(Nes->MID, Nes->MAGENTA)));
	# Clamping: a window asked for past the end shows the last screen,
	# not a repeat of the level.  draw() replicates a short source
	# rather than stopping, so without the clamp this tiles.
	lvl.view(scr, Nes->W*4, 0);
	ckx("view past the end clamps to the last screen",
		at(scr, (Nes->W-8)*SC, 0),
		rgb24(nes->entry(Nes->MID, Nes->CYAN)));
	lvl.view(scr, -100, 0);
	ckx("and a negative origin clamps to the first", at(scr, 0, 0),
		rgb24(nes->entry(Nes->MID, Nes->YELLOW)));

	small := nes->surface(d, c, f, 16, 16, nes->entry(Nes->MID, Nes->GREEN));
	scr.fill(Rect((0,0),(Nes->W, Nes->H)), bk);
	small.blit(scr, 32, 40);
	ckx("blit lands where it is put", at(scr, 32*SC, 40*SC),
		rgb24(nes->entry(Nes->MID, Nes->GREEN)));
	ckx("and not one tile over", at(scr, 31*SC, 40*SC), rgb24(bk));
}

input()
{
	sys->print("nestest: the pad\n");
	p := 0;
	p = nes->padkey(p, Keyboard->Right);
	ck("right presses", p, Nes->PRIGHT);
	p = nes->padkey(p, 'z');
	ck("and b as well", p, Nes->PRIGHT|Nes->PB);
	q := nes->edge(p, Nes->PRIGHT);
	ck("edge is what is new", q, Nes->PB);
	p = nes->padkey(p, Keyboard->Keyup | (Keyboard->Right & 16r7ff));
	ck("right releases", p, Nes->PB);
	p = nes->padkey(p, Keyboard->Keyup | 'z');
	ck("and b releases", p, 0);
	# The letters work the same pad as the arrows.
	p = nes->padkey(0, 'a');
	ck("a is left", p, Nes->PLEFT);
	p = nes->padkey(p, Keyboard->Keyup | 'a');
	ck("and releases", p, 0);
	p = nes->padkey(0, ' ');
	ck("space is a", p, Nes->PA);
	p = nes->padkey(p, '\n');
	ck("and enter is start", p, Nes->PA|Nes->PSTART);
	# Anything else is left alone rather than clearing the pad.
	p = nes->padkey(p, 'k');
	ck("an unknown key changes nothing", p, Nes->PA|Nes->PSTART);
	p = nes->padkey(p, Keyboard->Keyup | 'k');
	ck("and neither does its release", p, Nes->PA|Nes->PSTART);
}
