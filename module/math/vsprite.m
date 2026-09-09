Vsprite: module
{
	PATH:	con "/dis/math/vsprite.dis";

	# Element kinds, numerically matching TempleOS's SPT_* and the names
	# scripts/tos_extract_sprites.py writes into lib/temple/sprites/*.spr.
	SEND, SCOLOR, SDITHER, STHICK, SPLANARSYM,
	STRANSON, STRANSOFF, SSHIFT, SPT, SPOLYPT,
	SLINE, SPOLYLINE, SRECT, SROTRECT, SCIRCLE,
	SELLIPSE, SPOLYGON, SBSPLINE2, SBSPLINE2C,
	SBSPLINE3, SBSPLINE3C, SFLOOD, SFLOODNOT,
	SBITMAP, SMESH, SSHIFTMESH, SARROW, STEXT,
	STEXTBOX, STEXTDIAMOND:	con iota;
	NKIND:		con STEXTDIAMOND+1;

	TRANSP:		con 255;	# the index that means "no pixel"

	Elem: adt
	{
		kind:	int;
		a:	array of int;		# fixed args
		ang:	real;			# rotrect / ellipse / polygon
		pts:	array of int;		# polyline (2/pt), bsplines (3/pt)
		data:	array of byte;		# bitmap pixels, polypt steps
		txt:	string;			# the text family
		tw, th:	int;			# cached text raster
		tras:	array of byte;

		# Not used by this module.  An editor needs somewhere to
		# mark an element selected, and giving it a field here is
		# cheaper than keeping a parallel array in step with every
		# insertion and deletion.
		tag:	int;
	};

	Sprite: adt
	{
		elems:	array of ref Elem;

		# The image the element list draws, at its natural size, with
		# the rect it occupies in the sprite's own coordinates - the
		# same box scripts/tos_extract_sprites.py writes into the .bit,
		# and computed the same way, from the pixels that actually
		# came out rather than from the elements' nominal extents.
		# Returns an RGB24 image and a GREY1 mask; nil if nothing drew.
		# The rect the sprite occupies, from the elements' nominal
		# extents with the pen's half-width as a margin - the rule
		# scripts/tos_extract_sprites.py used to set the rect of
		# every .bit in icons/temple.  The int is 0 if the list
		# draws nothing.
		bounds:	fn(s: self ref Sprite): (Draw->Rect, int);

		raster:	fn(s: self ref Sprite, d: ref Draw->Display):
				(ref Draw->Image, ref Draw->Image, Draw->Rect);
		# Palette indices, TRANSP where nothing drew, row-major over
		# the returned rect.  This is what a caller comparing against
		# an m8 .bit wants, and what raster() is built on.
		pixels:	fn(s: self ref Sprite, d: ref Draw->Display):
				(array of byte, Draw->Rect);
	};

	init:	fn();

	parse:	fn(text: string): (ref Sprite, string);
	read:	fn(path: string): (ref Sprite, string);

	# Rasterise an element list onto a canvas of w x h palette indices,
	# TRANSP where nothing drew, with the sprite's origin at (ox, oy)
	# and row-major order.  Sprite.pixels is this over the sprite's own
	# box; an editor draws the same list onto a fixed page instead, and
	# that difference in canvas is the only thing that should make the
	# two disagree.
	canvas:	fn(elems: array of ref Elem, w, h, ox, oy: int,
			d: ref Draw->Display): array of byte;

	# The element list as text, and back: the form
	# scripts/tos_extract_sprites.py writes and temple/spriteedit(1)
	# saves.  Exported so an editor does not carry a second copy of the
	# grammar that would drift from this one.
	mkelem:		fn(kind, na: int): ref Elem;
	copyelem:	fn(e: ref Elem): ref Elem;
	elemline:	fn(e: ref Elem): string;
	parseline:	fn(line: string): (ref Elem, string);
	parselist:	fn(body: string): (array of ref Elem, int, string);

	# Which of the sixteen a rendered colour is.
	nearest:	fn(v: int): int;

	# The compass step a polypt's 3-bit code means.  An editor walks
	# the same eight as the rasteriser, and two copies of a table this
	# small are exactly how a sprite ends up drawn two ways.
	polystep:	fn(code: int): (int, int);

	kindname:	fn(k: int): string;
	kindof:		fn(name: string): int;
};
