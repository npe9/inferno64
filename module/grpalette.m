Grpalette: module
{
	PATH:	con "/dis/lib/grpalette.dis";

	# TempleOS's sixteen colour *indices* (ST_COLORS).  An index is not a
	# colour: gr.palette says what each one currently means, and
	# GrPaletteColorSet rewrites it.  appl/temple/palette(1) is the port
	# built entirely around that fact.
	BLACK, BLUE, GREEN, CYAN, RED, PURPLE, BROWN, LTGRAY,
	DKGRAY, LTBLUE, LTGREEN, LTCYAN, LTRED, LTPURPLE,
	YELLOW, WHITE:	con iota;
	COLORS:		con 16;

	# Palettes the register file can be loaded with.  EGA is the exact
	# sixteen TempleOS boots with, kept byte-for-byte so a fidelity claim
	# stays checkable.  RICH keeps every hue and every index meaning but
	# spends the true colour this display has on them; BLACK and WHITE are
	# left exact in RICH too, because ports mix palette black with
	# Draw->Black and the two must not drift apart.  GREY is the ramp
	# palette(1) writes over the registers.
	EGA, RICH, GREY:	con iota;
	NPALETTE:		con 3;

	init:		fn();

	# --- the register file ---
	set:		fn(which: int);			# GrPaletteColorSet, wholesale
	setcolour:	fn(i, v: int);			# one register
	loaded:		fn(): int;			# which palette is in
	value:		fn(i: int): int;		# register i, as RGBA
	values:		fn(): array of int;		# a copy of all sixteen
	table:		fn(which: int): array of int;	# a named palette, unloaded
	name:		fn(i: int): string;		# "LTGREEN"

	# Images for the current registers, one per index.  Ports allocated
	# these themselves from a literal copied sixteen lines at a time; this
	# is that loop, once.
	images:		fn(d: ref Draw->Display): array of ref Draw->Image;

	# --- what sixteen registers cannot express ---
	# lit scales a colour towards black (lit < 1) or towards white
	# (lit > 1); this is the shading term fillpoly3 already takes.
	shade:		fn(v: int, lit: real): int;
	mix:		fn(a, b: int, t: real): int;	# a at t=0, b at t=1
	# What TempleOS's ROPF_DITHER checkerboard averages to.  The original
	# had no colour between two registers and faked one; here it exists.
	dither:		fn(a, b: int): int;
	# n images from dark to light through v, for gradients and lighting.
	ramp:		fn(d: ref Draw->Display, v: int, n: int): array of ref Draw->Image;
};
