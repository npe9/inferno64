implement Grpalette;

# TempleOS's gr.palette, as a module instead of as a literal copied into
# fifty-one ports.
#
# Every port that drew in colour carried its own
#
#	cols := array[] of {
#		int 16r000000FF, int 16r0000AAFF, ...
#	};
#	for(i := 0; i < 16; i++)
#		ink[i] = d.color(cols[i]);
#
# which is the *contents* of a palette register file written out as if it
# were a constant.  In TempleOS it is not: GrPaletteColorSet rewrites the
# registers underneath a drawing that has already been made, which is the
# whole point of the Palette.HC demo this tree ports.  So the registers
# live here, one copy, and a port asks for images rather than for a
# literal.
#
# Having them in one place is also what makes a second palette possible.
# The sixteen EGA colours are what a 1980s DAC could reach; this display
# can reach sixteen million, and RICH spends them on the same sixteen
# meanings - same hue, same light/dark pairing, same index for the same
# thing - so a port keeps drawing exactly what it drew and only looks
# better doing it.  BLACK and WHITE are deliberately identical in both,
# because ports mix ink[BLACK] with Draw->Black in the same frame and a
# near-black would show as a seam.
#
# EGA remains exact, so "this port renders what the HolyC rendered" is
# still a checkable claim: set(Grpalette->EGA) and the pixels are the ones
# that were there before this module existed.  grpalettetest(1) checks that
# byte for byte.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image: import draw;

include "env.m";
	env: Env;

include "grpalette.m";

# The palette TempleOS boots with.  Byte-for-byte the literal that was in
# each port; do not tidy these numbers.
ega := array[] of {
	int 16r000000FF, int 16r0000AAFF, int 16r00AA00FF, int 16r00AAAAFF,
	int 16rAA0000FF, int 16rAA00AAFF, int 16rAA5500FF, int 16rAAAAAAFF,
	int 16r555555FF, int 16r5555FFFF, int 16r55FF55FF, int 16r55FFFFFF,
	int 16rFF5555FF, int 16rFF55FFFF, int 16rFFFF55FF, int 16rFFFFFFFF
};

# The same sixteen meanings on a display that is not an EGA DAC.  Each
# entry keeps its hue and keeps its position in the dark/light pair that
# TempleOS's index layout encodes (i and i+8 are the same colour, dim and
# bright), so nothing a port draws changes identity.
rich := array[] of {
	int 16r000000FF, int 16r1A3FBFFF, int 16r18913FFF, int 16r1795A6FF,
	int 16rC02428FF, int 16r9A2FB0FF, int 16rA55A1EFF, int 16rB0B4BAFF,
	int 16r585E67FF, int 16r5F92FFFF, int 16r5FDE78FF, int 16r5FE0F0FF,
	int 16rFF6B60FF, int 16rE084F5FF, int 16rFFD84AFF, int 16rFFFFFFFF
};

# What Palette.HC writes over the registers: 0xFFFF*i/15 in every channel,
# taken to eight bits.
grey: array of int;

names := array[] of {
	"BLACK", "BLUE", "GREEN", "CYAN", "RED", "PURPLE", "BROWN", "LTGRAY",
	"DKGRAY", "LTBLUE", "LTGREEN", "LTCYAN", "LTRED", "LTPURPLE",
	"YELLOW", "WHITE"
};

reg: array of int;		# the register file itself
cur := -1;			# which named palette was last loaded whole

init()
{
	if(reg != nil)
		return;
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grey = array[COLORS] of int;
	for(i := 0; i < COLORS; i++){
		g := 255*i/(COLORS-1);
		grey[i] = rgba(g, g, g, 16rFF);
	}
	reg = array[COLORS] of int;
	loadtable(fromenv());
}

# $grpalette picks the palette, so a whole session can be put back to the
# original sixteen without editing a port.  Unset means RICH: the ports are
# meant to look their best by default, and EGA is one word away.
fromenv(): int
{
	env = load Env Env->PATH;
	if(env == nil)
		return RICH;
	case env->getenv("grpalette") {
	"ega" or "EGA" =>	return EGA;
	"grey" or "gray" =>	return GREY;
	}
	return RICH;
}

table(which: int): array of int
{
	init();
	case which {
	EGA =>	return ega;
	GREY =>	return grey;
	}
	return rich;
}

set(which: int)
{
	init();
	loadtable(which);
}

loadtable(which: int)
{
	t := table(which);
	for(i := 0; i < COLORS; i++)
		reg[i] = t[i];
	cur = which;
}

setcolour(i, v: int)
{
	init();
	if(i < 0 || i >= COLORS)
		return;
	reg[i] = v;
	cur = -1;			# no longer any named palette
}

loaded(): int
{
	init();
	return cur;
}

value(i: int): int
{
	init();
	return reg[i&(COLORS-1)];
}

values(): array of int
{
	init();
	v := array[COLORS] of int;
	for(i := 0; i < COLORS; i++)
		v[i] = reg[i];
	return v;
}

name(i: int): string
{
	if(i < 0 || i >= COLORS)
		return "?";
	return names[i];
}

images(d: ref Display): array of ref Image
{
	init();
	ink := array[COLORS] of ref Image;
	for(i := 0; i < COLORS; i++)
		ink[i] = d.color(reg[i]);
	return ink;
}

# A colour is a 32-bit RGBA word, but this tree's int is 64 bits wide at
# run time (1<<40 is a perfectly good int here) while the compiler types a
# literal of 16r80000000 or more as big.  So a *literal* white is
# int 16rFFFFFFFF = -1, sign-extended by the compiler, and a *computed*
# white is 4294967295, not sign-extended by anything.  They draw the same,
# because emu takes the low 32 bits either way - and they compare unequal,
# silently, which is how a colour test can fail while printing the same
# %ux on both sides.  Every value this module hands out goes through here.
rgba(r, g, b, a: int): int
{
	v := (r<<24)|(g<<16)|(b<<8)|a;
	return (v<<32)>>32;
}

clamp(x: int): int
{
	if(x < 0)
		return 0;
	if(x > 255)
		return 255;
	return x;
}

# int of a real rounds in Limbo, which is what is wanted for a channel.
byteof(v: int, sh: int): int
{
	return (v>>sh)&16rFF;
}

shade(v: int, lit: real): int
{
	r := byteof(v, 24);
	g := byteof(v, 16);
	b := byteof(v, 8);
	a := byteof(v, 0);
	if(lit <= 1.0){
		if(lit < 0.0)
			lit = 0.0;
		r = clamp(int (real r*lit));
		g = clamp(int (real g*lit));
		b = clamp(int (real b*lit));
	}else{
		# past full brightness a channel cannot go further, so the
		# excess goes towards white instead of clipping to it.
		t := lit-1.0;
		if(t > 1.0)
			t = 1.0;
		r = clamp(r + int (real (255-r)*t));
		g = clamp(g + int (real (255-g)*t));
		b = clamp(b + int (real (255-b)*t));
	}
	return rgba(r, g, b, a);
}

mix(a, b: int, t: real): int
{
	if(t <= 0.0)
		return a;
	if(t >= 1.0)
		return b;
	r := byteof(a, 24) + int (real (byteof(b, 24)-byteof(a, 24))*t);
	g := byteof(a, 16) + int (real (byteof(b, 16)-byteof(a, 16))*t);
	bl := byteof(a, 8) + int (real (byteof(b, 8)-byteof(a, 8))*t);
	return rgba(clamp(r), clamp(g), clamp(bl), byteof(a, 0));
}

dither(a, b: int): int
{
	return mix(a, b, 0.5);
}

ramp(d: ref Display, v: int, n: int): array of ref Image
{
	if(n < 1)
		n = 1;
	im := array[n] of ref Image;
	if(n == 1){
		im[0] = d.color(v);
		return im;
	}
	# lit runs 0.25 .. 1.75 so the middle step is the colour itself.
	for(i := 0; i < n; i++)
		im[i] = d.color(shade(v, 0.25 + 1.5*real i/real (n-1)));
	return im;
}
