Tiles: module
{
	PATH:	con "/dis/lib/tiles.dis";

	# An 8-bit-console look-alike: a fixed 256x240 logical screen made
	# of 8x8 tiles from a 64-entry master palette, four colours to a
	# tile, drawn through a scale so a logical pixel is a square block
	# of real ones.  None of it is emulation - there is no 6502 and no
	# PPU here, and the palette is computed rather than transcribed
	# from any real machine's tables.  It is the shape of that era's
	# graphics, which is what makes the games on top of it look right
	# and what makes them cheap enough to run in interpreted Limbo.
	#
	# The one thing to know before using it: draw() does not resample.
	# Everything is therefore built at the destination's scale up front
	# - a tile composite is 8*scale square and is blitted 1:1 - and no
	# scaling happens per frame at all.
	#
	# Include "draw.m" before this.

	W:	con 256;	# logical screen, in logical pixels
	H:	con 240;
	TW:	con 8;		# a tile
	TH:	con 8;
	NTW:	con W/TW;	# 32 tiles across a screen
	NTH:	con H/TH;	# 30 down

	MASTER:	con 64;		# entries in the master palette


	# put() flags
	FLIPX, FLIPY: con 1 << iota;

	init:	fn(): string;

	# --- the master palette ---
	#
	# 64 entries as four rows of sixteen: column 0 is a grey, columns
	# 1 to 12 are twelve hues, and 13 to 15 are black.  Row 0 is dark,
	# row 3 is nearly white.  Computed at init(), so the whole ramp
	# moves together if the constants at the top of tiles.b are changed.
	rgb:	fn(i: int): int;			# 0xRRGGBB00, for Display.rgb2cmap and friends
	colour:	fn(d: ref Draw->Display, i: int): ref Draw->Image;

	# GREY, and the twelve hues, as column numbers for pal().
	GREY, RED, ORANGE, YELLOW, LIME, GREEN, SPRING,
		CYAN, AZURE, BLUE, VIOLET, MAGENTA, ROSE: con iota;
	BLACK:	con 13;
	# Rows.
	DARK, MID, LIGHT, PALE: con iota;
	# entry: the master index for a row and column.
	entry:	fn(row, col: int): int;

	# --- a four-colour palette ---
	#
	# c[0] is the background colour for tile(), and transparent for
	# put().  The other three are the tile's colours 1, 2 and 3.
	Pal: adt {
		c:	array of int;
	};
	pal:	fn(a, b, c, d: int): ref Pal;

	# --- a tile sheet ---
	#
	# Art is eight strings of eight characters a tile, from ".123",
	# so a sheet reads as itself in the source and needs no asset
	# file.  Composites are built lazily, one per (tile, palette,
	# flip), and only for the combinations a game actually draws.
	Chr: adt {
		n:	int;			# tiles
		bits:	array of byte;		# n*64 colour indices
		scale:	int;
		disp:	ref Draw->Display;
		chans:	Draw->Chans;
		npal:	int;
		pals:	array of ref Pal;
		img:	array of ref Draw->Image;	# npal*n*4, by (pal, tile, flip)
		msk:	array of ref Draw->Image;

		pix:	fn(c: self ref Chr, t, x, y: int): int;
	};
	chr:	fn(d: ref Draw->Display, chans: Draw->Chans, scale: int, art: array of string): ref Chr;

	# Sixteen strings of sixteen characters are how a 16x16 character
	# actually wants to be written.  meta() cuts each such block into the
	# four 8x8 tiles chr() takes, in the order top left, top right,
	# bottom left, bottom right, so a sheet can mix hand-written 8x8
	# tiles and 16x16 ones by concatenating the two arrays.
	meta:	fn(art: array of string): array of string;

	# The 8x8 text font, built from /fonts/temple/temple.8x8 - which is
	# already in the tree and is already the right shape - rather than
	# from a table typed out again here.
	font:	fn(d: ref Draw->Display, chans: Draw->Chans, scale: int): ref Chr;

	# --- a drawing surface ---
	#
	# w and h are LOGICAL pixels; the image behind it is scale times
	# that.  A game keeps one surface the size of the screen to compose
	# each frame into, and usually one larger one holding a level's
	# tiles, built once and blitted from.
	Surface: adt {
		img:	ref Draw->Image;
		chr:	ref Chr;
		fnt:	ref Chr;
		scale:	int;
		w, h:	int;

		tile:	fn(s: self ref Surface, tx, ty, t: int, p: ref Pal);
		put:	fn(s: self ref Surface, x, y, t: int, p: ref Pal, flags: int);
		# A 16x16 metasprite: t is the first of the four tiles meta()
		# produced.  FLIPX swaps the halves as well as mirroring them,
		# which is the whole reason this is not four put() calls.
		put16:	fn(s: self ref Surface, x, y, t: int, p: ref Pal, flags: int);
		fill:	fn(s: self ref Surface, r: Draw->Rect, ci: int);
		text:	fn(s: self ref Surface, x, y: int, str: string, p: ref Pal);
		# Copy a W by H window of s, its top left at (sx, sy), into
		# dst.  This is the scroll.
		view:	fn(s: self ref Surface, dst: ref Surface, sx, sy: int);
		# Copy the whole of s into dst at logical (x, y).
		blit:	fn(s: self ref Surface, dst: ref Surface, x, y: int);
	};
	surface:	fn(d: ref Draw->Display, chr, fnt: ref Chr, w, h, bg: int): ref Surface;

	# --- the same thing as a command language ---
	#
	# Everything above is Limbo: a game compiles its art in as arrays
	# of strings and its palettes as calls.  That is fine and it is also
	# the only way to do it, which is the complaint.  A Screen is the
	# other way, and it is shaped like tk(2): named things, made and
	# drawn by text, so a level, a palette and a sheet of art are DATA
	# a program reads rather than source a program is built from.
	#
	# cmd() takes one command or several separated by newlines, and
	# returns a result - empty for a command that has none.  An error
	# comes back beginning with "!", which is tk(2)'s convention and
	# not plot(2)'s nil-or-error, because a command that answers a
	# question has to be able to answer "0".
	#
	#	palette NAME c0 c1 c2 c3
	#		colours as ROW.COLUMN - dark.red, pale.grey - or as
	#		a bare master index.  c0 is the background for tile
	#		and transparent for put.
	#	sheet NAME FILE          8x8 art, eight lines a tile
	#	sheet16 NAME FILE        16x16 art, sixteen lines each
	#	font NAME                the built-in 8x8 text font
	#	surface NAME W H COLOUR  W and H in logical pixels
	#	tile SURF TX TY SHEET N PAL
	#	put SURF X Y SHEET N PAL [flipx] [flipy]
	#	put16 SURF X Y SHEET N PAL [flipx] [flipy]
	#	text SURF X Y PAL WORDS...
	#	fill SURF X Y W H COLOUR
	#	view SRC DST SX SY       a screen-sized window of SRC
	#	blit SRC DST X Y
	#	map SURF SHEET FILE      a whole tile map, legend and all
	#	size SURF                -> "W H"
	#	colour NAME              -> "#rrggbb"
	#	count SHEET              -> how many tiles it holds
	#
	# An art file is lines of ".123", eight (or sixteen) to a tile;
	# blank lines and lines beginning with # are ignored.  A map file
	# carries its own legend: lines of "CHAR TILE PALETTE" until a line
	# of "%", then the map itself, one character a tile.
	Screen: adt {
		disp:	ref Draw->Display;
		chans:	Draw->Chans;
		scale:	int;

		cmd:	fn(s: self ref Screen, command: string): string;
		# The image behind a named surface, to blit onto a window.
		image:	fn(s: self ref Screen, name: string): ref Draw->Image;
		# The surface itself, for a program that wants to go on
		# calling the functions above on it.
		named:	fn(s: self ref Screen, name: string): ref Surface;
		# And the sheet, likewise: a name made by text is a thing the
		# rest of the program can still reach.
		sheet:	fn(s: self ref Screen, name: string): ref Chr;
		pal:	fn(s: self ref Screen, name: string): ref Pal;
	};
	screen:	fn(d: ref Draw->Display, chans: Draw->Chans, scale: int): ref Screen;
};
