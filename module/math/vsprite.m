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

	kindname:	fn(k: int): string;
	kindof:		fn(name: string): int;
};
