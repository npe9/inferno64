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
};
