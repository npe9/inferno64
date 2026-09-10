implement Command;

# Checks tiles(2) itself, which the games on top of it only exercise
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

include "tiles.m";
	tiles: Tiles;
	Chr, Pal, Surface, Screen: import tiles;

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
	return (tiles->rgb(i) >> 8) & 16rFFFFFF;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tiles = load Tiles Tiles->PATH;
	if(tiles == nil){
		sys->print("tilestest: cannot load tiles: %r\n");
		raise "fail:load";
	}
	e := tiles->init();
	if(e != nil){
		sys->print("tilestest: %s\n", e);
		raise "fail:init";
	}
	d = Display.allocate(nil);
	if(d == nil){
		sys->print("tilestest: no display: %r\n");
		raise "fail:display";
	}
	palette();
	sheets();
	drawing();
	scrolling();
	language();
	if(nfail == 0)
		sys->print("tilestest: PASSED\n");
	else{
		sys->print("tilestest: FAILED (%d)\n", nfail);
		raise "fail:tilestest";
	}
}

palette()
{
	sys->print("tilestest: the master palette\n");
	# The greys are grey, and they climb.
	last := -1;
	up := 1;
	for(r := 0; r < 4; r++){
		v := rgb24(tiles->entry(r, Tiles->GREY));
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
	ckx("the palest grey is white", rgb24(tiles->entry(Tiles->PALE, Tiles->GREY)),
		16rFFFFFF);
	ckx("column 13 is black", rgb24(tiles->entry(Tiles->MID, Tiles->BLACK)), 0);

	# Twelve distinct hues on the mid row.
	n := 0;
	for(c := Tiles->RED; c <= Tiles->ROSE; c++)
		for(c2 := c+1; c2 <= Tiles->ROSE; c2++)
			if(rgb24(tiles->entry(Tiles->MID, c)) ==
			   rgb24(tiles->entry(Tiles->MID, c2)))
				n++;
	ck("no two hues on a row are the same", n, 0);

	# A hue gets brighter across the rows.
	dark := rgb24(tiles->entry(Tiles->DARK, Tiles->CYAN));
	pale := rgb24(tiles->entry(Tiles->PALE, Tiles->CYAN));
	cktrue("a hue brightens down the rows", lum(pale) > lum(dark));

	# Out of range is clamped rather than faulting.
	ckx("entry clamps low", rgb24(tiles->entry(-5, -5)),
		rgb24(tiles->entry(0, 0)));
	ckx("entry clamps high", rgb24(tiles->entry(99, 99)),
		rgb24(tiles->entry(3, 15)));
}

lum(v: int): int
{
	return ((v>>16) & 16rFF) + ((v>>8) & 16rFF) + (v & 16rFF);
}

sheets()
{
	sys->print("tilestest: tile sheets\n");
	c := tiles->chr(d, Draw->RGB24, 2, ART);
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
	m := tiles->chr(d, Draw->RGB24, 2, tiles->meta(ART16));
	ck("one 16x16 makes four tiles", m.n, 4);
	ck("top left quadrant", m.pix(0, 0, 0), 1);
	ck("top right quadrant", m.pix(1, 1, 0), 2);
	ck("bottom left quadrant", m.pix(2, 0, 0), 3);
	ck("bottom right quadrant", m.pix(3, 1, 0), 1);
	ck("the gap between them is colour 0", m.pix(1, 0, 0), 0);

	f := tiles->font(d, Draw->RGB24, 2);
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
	sys->print("tilestest: drawing\n");
	SC: con 2;
	bk := tiles->entry(Tiles->DARK, Tiles->BLACK);
	c := tiles->chr(d, Draw->RGB24, SC, ART);
	f := tiles->font(d, Draw->RGB24, SC);
	pa := tiles->pal(bk, tiles->entry(Tiles->MID, Tiles->RED),
		tiles->entry(Tiles->MID, Tiles->GREEN), tiles->entry(Tiles->MID, Tiles->BLUE));
	pb := tiles->pal(bk, tiles->entry(Tiles->MID, Tiles->CYAN),
		tiles->entry(Tiles->MID, Tiles->YELLOW), tiles->entry(Tiles->MID, Tiles->MAGENTA));
	s := tiles->surface(d, c, f, 64, 64, tiles->entry(Tiles->PALE, Tiles->GREY));
	cktrue("a surface is made", s != nil);
	if(s == nil)
		return;
	ck("the image is scale times the logical size", s.img.r.dx(), 64*SC);
	ckx("and starts in its background colour", at(s, 0, 0),
		rgb24(tiles->entry(Tiles->PALE, Tiles->GREY)));

	# tile(): opaque, at tile coordinates, in the palette given.
	s.tile(1, 1, 0, pa);
	ckx("tile corner is palette colour 1", at(s, 8*SC, 8*SC),
		rgb24(tiles->entry(Tiles->MID, Tiles->RED)));
	ckx("tile inside is colour 2", at(s, 9*SC, 9*SC),
		rgb24(tiles->entry(Tiles->MID, Tiles->GREEN)));
	ckx("tile middle is colour 3", at(s, 11*SC, 11*SC),
		rgb24(tiles->entry(Tiles->MID, Tiles->BLUE)));
	# and the scale really is a block, not a point
	ckx("a logical pixel is a block of real ones", at(s, 8*SC+1, 8*SC+1),
		rgb24(tiles->entry(Tiles->MID, Tiles->RED)));

	# The composite cache is keyed by palette as well as by tile.  If it
	# were not, this second draw would come out in the first palette's
	# colours - which looks like a working game in one colour scheme.
	s.tile(3, 1, 0, pb);
	ckx("the same tile in another palette", at(s, 24*SC, 8*SC),
		rgb24(tiles->entry(Tiles->MID, Tiles->CYAN)));
	s.tile(5, 1, 0, pa);
	ckx("and back again in the first", at(s, 40*SC, 8*SC),
		rgb24(tiles->entry(Tiles->MID, Tiles->RED)));

	# put(): colour 0 is transparent.  Tile 1 is empty at its top right.
	s.fill(Rect((0, 24), (64, 32)), tiles->entry(Tiles->MID, Tiles->LIME));
	s.put(0, 24, 1, pa, 0);
	ckx("put draws colour 3", at(s, 0, 24*SC),
		rgb24(tiles->entry(Tiles->MID, Tiles->BLUE)));
	ckx("and leaves colour 0 alone", at(s, 7*SC, 24*SC),
		rgb24(tiles->entry(Tiles->MID, Tiles->LIME)));

	# tile() does NOT: colour 0 is the background there.
	s.fill(Rect((16, 24), (64, 32)), tiles->entry(Tiles->MID, Tiles->LIME));
	s.tile(2, 3, 1, pa);
	ckx("tile paints colour 0 as the background", at(s, 23*SC, 24*SC),
		rgb24(bk));

	# Flips.  Tile 1 is lopsided on purpose: colour 3 is at its left
	# edge and nothing is at its right.
	s.fill(Rect((0, 40), (64, 48)), tiles->entry(Tiles->MID, Tiles->LIME));
	s.put(0, 40, 1, pa, Tiles->FLIPX);
	ckx("flipx moves colour 3 to the right", at(s, 7*SC, 40*SC),
		rgb24(tiles->entry(Tiles->MID, Tiles->BLUE)));
	ckx("and clears the left", at(s, 0, 40*SC),
		rgb24(tiles->entry(Tiles->MID, Tiles->LIME)));
	s.fill(Rect((8, 40), (64, 48)), tiles->entry(Tiles->MID, Tiles->LIME));
	s.put(8, 40, 1, pa, Tiles->FLIPY);
	ckx("flipy moves colour 1 to the top", at(s, 8*SC, 40*SC),
		rgb24(tiles->entry(Tiles->MID, Tiles->RED)));

	# put16: the quadrants land where meta() put them, and FLIPX swaps
	# the halves as well as mirroring each.
	m := tiles->chr(d, Draw->RGB24, SC, tiles->meta(ART16));
	s2 := tiles->surface(d, m, f, 64, 64, bk);
	s2.put16(0, 0, 0, pa, 0);
	ckx("put16 top left", at(s2, 0, 0), rgb24(tiles->entry(Tiles->MID, Tiles->RED)));
	ckx("put16 top right", at(s2, 9*SC, 0),
		rgb24(tiles->entry(Tiles->MID, Tiles->GREEN)));
	ckx("put16 bottom left", at(s2, 0, 8*SC),
		rgb24(tiles->entry(Tiles->MID, Tiles->BLUE)));
	s2.put16(16, 0, 0, pa, Tiles->FLIPX);
	ckx("flipx swaps the halves", at(s2, (16+15)*SC, 0),
		rgb24(tiles->entry(Tiles->MID, Tiles->RED)));

	# text: one glyph every eight logical pixels, and a space leaves the
	# ground alone.
	s.fill(Rect((0, 52), (64, 60)), tiles->entry(Tiles->MID, Tiles->LIME));
	s.text(0, 52, "A A", pa);
	na := lit(s, 0, 52, 8, 8);
	nb := lit(s, 8, 52, 8, 8);
	ncc := lit(s, 16, 52, 8, 8);
	cktrue("text drew the first letter", na > 0);
	ck("and nothing where the space is", nb, 0);
	cktrue("and the second letter one glyph further on", ncc > 0);
	ck("both letters the same", na, ncc);
}

# The command language.  What is being checked is that text does the
# same thing the calls do - the point of having it is that a level and a
# sheet of art stop being source, so a level that draws differently
# through cmd() than through the functions would be worse than no level
# language at all.
language()
{
	sys->print("tilestest: the command language\n");
	SC: con 2;
	sc := tiles->screen(d, Draw->RGB24, SC);
	cktrue("a screen is made", sc != nil);
	if(sc == nil)
		return;

	ck2("an unknown command is refused", iserr(sc.cmd("wibble")), 1);
	ck2("and a bad colour", iserr(sc.cmd("palette p mid.plaid a b c")), 1);
	ck2("and a bad row", iserr(sc.cmd("palette p wrong.red a b c")), 1);

	e := sc.cmd("palette steel dark.black dark.azure mid.cyan light.cyan");
	ck2("a palette is made", iserr(e), 0);
	e = sc.cmd("sheet art /lib/tiles/demo.chr");
	ck2("a sheet loads from a file", iserr(e), 0);
	# Tracks /lib/tiles/demo.chr: add a tile there and this number
	# changes, which is the point - it is what catches a sheet that was
	# mis-parsed into the wrong number of tiles.
	cks("and has the tiles the file holds", sc.cmd("count art"), "7");
	ck2("a missing file is an error",
		iserr(sc.cmd("sheet gone /lib/tiles/nosuch.chr")), 1);

	e = sc.cmd("font font");
	ck2("the font loads", iserr(e), 0);
	e = sc.cmd("surface scr 64 64 dark.black");
	ck2("a surface is made", iserr(e), 0);
	cks("and knows its size", sc.cmd("size scr"), "64 64");
	cks("a colour reads back as a colour",
		sc.cmd("colour pale.grey"), "#ffffff");

	# The real comparison: a map painted from a file against the same
	# cells painted through the Surface calls, with the sheet and the
	# palette the file named.  Anything less says only that cmd() drew
	# SOMETHING.
	sc.cmd("palette turf dark.black dark.green mid.lime light.lime");
	sc.cmd("palette soil dark.black dark.orange dark.red mid.orange");
	sc.cmd("palette brick dark.black dark.orange mid.orange light.orange");
	sc.cmd("palette ladder dark.black mid.orange light.orange pale.yellow");
	sc.cmd("palette coin dark.black dark.yellow pale.yellow mid.yellow");
	sc.cmd("surface lvl 256 96 dark.black");
	e = sc.cmd("map lvl art /lib/tiles/demo.map");
	ck2("a map paints from a file", iserr(e), 0);
	cktrue("and puts something on the surface", litpix(sc.image("lvl")) > 3000);

	art := sc.sheet("art");
	tp := sc.pal("turf");
	cktrue("the sheet and palette it named are reachable",
		art != nil && tp != nil);
	if(art == nil || tp == nil)
		return;
	hand := tiles->surface(d, art, nil, 256, 96,
		tiles->entry(Tiles->DARK, Tiles->BLACK));
	if(hand == nil){
		sys->print("FAIL no scratch surface\n");
		nfail++;
		return;
	}
	# row 10 of the map file is all "=", which the legend gives as tile
	# 2 in palette turf
	for(x := 0; x < 32; x++)
		hand.tile(x, 10, 2, tp);
	same := 1;
	for(x = 0; x < 32; x++)
		for(dy := 0; dy < 8*SC; dy += 3)
			if(pixat(sc.image("lvl"), x*8*SC + 3, 10*8*SC + dy)
			!= pixat(hand.img, x*8*SC + 3, 10*8*SC + dy))
				same = 0;
	cktrue("and the pixels are the ones the calls make", same);

	# The legend's own trap.  "#" is the obvious character for a wall
	# and was also the comment marker, so the legend line "# 1 brick"
	# was thrown away and every brick in the map silently failed to
	# draw - visible only by looking at the picture.  The demo map has
	# bricks at row 5, columns 17 to 19.
	cktrue("a # in a legend is data and not a comment",
		pixat(sc.image("lvl"), 17*8*SC + 3, 5*8*SC + 3) != 0);

	# A cell the legend does not mention is left alone, which is how a
	# map says sky without naming it.
	ck2("an unnamed character paints nothing",
		pixat(sc.image("lvl"), 2, 2),
		pixat(sc.image("lvl"), 6, 6));

	# A map is remembered as well as painted, or a script on the far
	# side of this language can draw a maze and not ask whether the
	# thing it is about to walk into is a wall.
	cks("at reads a cell", sc.cmd("at lvl 0 10"), "=");
	cks("and an empty one", sc.cmd("at lvl 0 0"), ".");
	cks("off the map reads empty", sc.cmd("at lvl 999 999"), "");
	ck2("at on a surface with no map is an error",
		iserr(sc.cmd("at scr 0 0")), 1);
	e = sc.cmd("set lvl 0 10 o");
	ck2("set changes a cell", iserr(e), 0);
	cks("and at agrees", sc.cmd("at lvl 0 10"), "o");
	cktrue("and the cell was repainted",
		pixat(sc.image("lvl"), 3, 10*8*SC + 3)
		!= pixat(hand.img, 3, 10*8*SC + 3));
	sc.cmd("set lvl 0 10 =");
	cks("and back again", sc.cmd("at lvl 0 10"), "=");

	# A whole screen from one string, the way a Tk program builds a
	# window: several commands, newline separated, first error wins.
	r := sc.cmd("surface two 32 32 mid.blue\n" +
		"fill two 0 0 8 8 pale.grey\n" +
		"text two 0 16 steel HI\n");
	ck2("a script of commands runs", iserr(r), 0);
	r = sc.cmd("surface three 32 32 mid.blue\nwibble\nfill three 0 0 8 8 pale.grey\n");
	ck2("and stops at the first error", iserr(r), 1);
}

ck2(what: string, got, want: int)
{
	if(got == want){
		sys->print("ok   %s\n", what);
		return;
	}
	sys->print("FAIL %s = %d, want %d\n", what, got, want);
	nfail++;
}

cks(what, got, want: string)
{
	if(got == want){
		sys->print("ok   %s = %s\n", what, got);
		return;
	}
	sys->print("FAIL %s = %s, want %s\n", what, got, want);
	nfail++;
}

iserr(r: string): int
{
	return len r > 0 && r[0] == '!';
}

pixat(im: ref Image, x, y: int): int
{
	b := array[3] of byte;
	if(im.readpixels(Rect((x,y),(x+1,y+1)), b) < 0)
		return -1;
	return (int b[2] << 16) | (int b[1] << 8) | int b[0];
}

litpix(im: ref Image): int
{
	if(im == nil)
		return -1;
	w := im.r.dx();
	h := im.r.dy();
	b := array[w*h*3] of byte;
	if(im.readpixels(im.r, b) < 0)
		return -1;
	n := 0;
	for(i := 0; i < w*h; i++)
		if(b[i*3] != byte 0 || b[i*3+1] != byte 0 || b[i*3+2] != byte 0)
			n++;
	return n;
}

# Logical pixels in a box that are not the ground colour it was filled
# with.  Counting what CHANGED, not what is lit, so a glyph drawn in the
# ground's own colour would still read as nothing.
lit(s: ref Surface, x, y, w, h: int): int
{
	g := rgb24(tiles->entry(Tiles->MID, Tiles->LIME));
	n := 0;
	for(j := 0; j < h; j++)
		for(i := 0; i < w; i++)
			if(at(s, (x+i)*s.scale, (y+j)*s.scale) != g)
				n++;
	return n;
}

scrolling()
{
	sys->print("tilestest: view and blit\n");
	SC: con 2;
	bk := tiles->entry(Tiles->DARK, Tiles->BLACK);
	c := tiles->chr(d, Draw->RGB24, SC, ART);
	f := tiles->font(d, Draw->RGB24, SC);
	# A level twice as wide as a screen, with a marker at each end.
	lvl := tiles->surface(d, c, f, Tiles->W*2, Tiles->H, bk);
	scr := tiles->surface(d, c, f, Tiles->W, Tiles->H, bk);
	lvl.fill(Rect((0,0),(8,8)), tiles->entry(Tiles->MID, Tiles->YELLOW));
	lvl.fill(Rect((Tiles->W*2-8, 0), (Tiles->W*2, 8)),
		tiles->entry(Tiles->MID, Tiles->CYAN));
	lvl.fill(Rect((Tiles->W, 0), (Tiles->W+8, 8)),
		tiles->entry(Tiles->MID, Tiles->MAGENTA));

	lvl.view(scr, 0, 0);
	ckx("view at 0 shows the left end", at(scr, 0, 0),
		rgb24(tiles->entry(Tiles->MID, Tiles->YELLOW)));
	lvl.view(scr, Tiles->W, 0);
	ckx("view at one screen shows the middle marker", at(scr, 0, 0),
		rgb24(tiles->entry(Tiles->MID, Tiles->MAGENTA)));
	# Clamping: a window asked for past the end shows the last screen,
	# not a repeat of the level.  draw() replicates a short source
	# rather than stopping, so without the clamp this tiles.
	lvl.view(scr, Tiles->W*4, 0);
	ckx("view past the end clamps to the last screen",
		at(scr, (Tiles->W-8)*SC, 0),
		rgb24(tiles->entry(Tiles->MID, Tiles->CYAN)));
	lvl.view(scr, -100, 0);
	ckx("and a negative origin clamps to the first", at(scr, 0, 0),
		rgb24(tiles->entry(Tiles->MID, Tiles->YELLOW)));

	small := tiles->surface(d, c, f, 16, 16, tiles->entry(Tiles->MID, Tiles->GREEN));
	scr.fill(Rect((0,0),(Tiles->W, Tiles->H)), bk);
	small.blit(scr, 32, 40);
	ckx("blit lands where it is put", at(scr, 32*SC, 40*SC),
		rgb24(tiles->entry(Tiles->MID, Tiles->GREEN)));
	ckx("and not one tile over", at(scr, 31*SC, 40*SC), rgb24(bk));
}
