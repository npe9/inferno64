Tklayout: module
{
	PATH:	con "/dis/lib/tklayout.dis";

	Clipped, Overlap: con iota;

	Problem: adt {
		kind:	int;
		a:	string;			# the widget at fault
		b:	string;			# the one it overlaps, if any
		ra:	Draw->Rect;		# what it got
		rb:	Draw->Rect;		# what it needed, or the other widget

		text:	fn(p: self ref Problem): string;
	};

	init:	fn();

	# the paths one level below path, in creation order
	children:	fn(top: ref Tk->Toplevel, path: string): list of string;

	# every descendant of path, parents before children
	walk:	fn(top: ref Tk->Toplevel, path: string): list of string;

	# Every widget under root that did not get the room it asked for,
	# and any two siblings sharing pixels.
	check:	fn(top: ref Tk->Toplevel, root: string): list of ref Problem;

	# How wide a string would be in top's font, in pixels.
	measure:	fn(top: ref Tk->Toplevel, s: string): int;

	# The widest prefix of s that fits in w pixels, with an ellipsis if
	# it had to cut.  Measured rather than counted: this Tk's widths are
	# distances, and a proportional face has no character cell to divide
	# by.  Returns s unchanged when it already fits.
	#
	# NEVER returns something wider than w.  If not even one character
	# and an ellipsis fit it gives back the ellipsis alone, and if that
	# does not fit either it gives back nothing - a caller that wants a
	# floor has to clamp its own budget, because one over-wide label
	# costs a taskbar every task after it.
	elide:	fn(top: ref Tk->Toplevel, s: string, w: int): string;
};
