Wmtheme: module
{
	PATH:	con "/dis/lib/wmtheme.dis";

	# The colours the window system draws its own furniture with.  Not a
	# palette a program picks from: these are the specific things the
	# chrome is made of, and a theme is a different set of values for
	# exactly these names.
	Inactive,	# titlebar of a window without the keyboard
	Focused,	# titlebar of the one that has it
	Chrome,		# the titlebar's buttons
	Glyph,		# the artwork on them
	Label,		# the title's text
	Desktop:	# what is behind every window
		con iota;
	Ncolour: con Desktop+1;

	init:	fn();

	# for draw(2), which wants a packed RGBA
	rgba:	fn(i: int): int;

	# for tk(2), which wants "#rrggbb"
	hex:	fn(i: int): string;

	set:	fn(i, rgba: int);
	name:	fn(i: int): string;
};
