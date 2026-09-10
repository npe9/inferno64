implement Wmtheme;

#
# The window system's own colours, in one place.
#
# They were literals: four in titlebar.b written out fourteen times,
# three more in wmclient.b as Limbo constants, and the desktop background
# 16rC4C0B4FF written twice - wmclient.b and wm.b - which is the
# duplication a register exists to remove, already happening.
#
# This is deliberately not grpalette(2).  That is TempleOS's sixteen
# colour indexed file, where a colour IS an index and a program rewrites
# the table underneath a finished drawing; these are specific values, and
# routing them through sixteen slots would either change them or bolt
# custom entries onto a fixed table.  The right shape, the wrong table.
#
# The defaults are exactly what was written down before, so putting this
# in changes no pixel.  That is the point, and it is what wmtheme's check
# in tkofftest(1) asserts.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "wmtheme.m";

# Soft Plan9 Paper: a cool slate for a window that is not in use, a
# stronger blue for the one that is, and soft chrome behind the button
# bitmaps so they stay readable.
cols := array[Ncolour] of {
	Inactive =>	int 16r8A9098FF,
	Focused =>	int 16r3D6A9AFF,
	Chrome =>	int 16rD4D0C4FF,
	Glyph =>	int 16r2A2A22FF,
	Label =>	int 16rFFFFFFFF,
	Desktop =>	int 16rC4C0B4FF,
};

names := array[Ncolour] of {
	Inactive => "inactive",
	Focused => "focused",
	Chrome => "chrome",
	Glyph => "glyph",
	Label => "label",
	Desktop => "desktop",
};

init()
{
	sys = load Sys Sys->PATH;
}

rgba(i: int): int
{
	if(i < 0 || i >= Ncolour)
		return int 16r000000FF;
	return cols[i];
}

hex(i: int): string
{
	c := rgba(i);
	# The alpha is dropped: tk(2) takes #rrggbb, and every colour here is
	# opaque.
	return sys->sprint("#%.2X%.2X%.2X",
		(c >> 24) & 16rFF, (c >> 16) & 16rFF, (c >> 8) & 16rFF);
}

set(i, c: int)
{
	if(i >= 0 && i < Ncolour)
		cols[i] = c;
}

name(i: int): string
{
	if(i < 0 || i >= Ncolour)
		return "?";
	return names[i];
}
