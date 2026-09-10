Tknotebook: module
{
	PATH:	con "/dis/lib/tknotebook.dis";

	Notebook: adt {
		top:	ref Tk->Toplevel;
		path:	string;			# the frame it was made in
		tabs:	array of string;	# the labels, in order
		sel:	int;			# which page is showing

		# the widget path to pack a page's contents into
		page:	fn(nb: self ref Notebook, i: int): string;

		# show page i, hiding whatever was showing
		select:	fn(nb: self ref Notebook, i: int);

		# the tab the person last chose, or -1 if none since the last ask
		chosen:	fn(nb: self ref Notebook): int;
	};

	init:	fn();

	# Make a notebook at path inside an existing toplevel.  The caller
	# packs path itself, and packs each page's contents into page(i).
	new:	fn(top: ref Tk->Toplevel, path: string,
			tabs: array of string): ref Notebook;
};
