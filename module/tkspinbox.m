Tkspinbox: module
{
	PATH:	con "/dis/lib/tkspinbox.dis";

	Spinbox: adt {
		top:	ref Tk->Toplevel;
		path:	string;			# the frame it was made in
		lo:	int;			# range, inclusive
		hi:	int;
		step:	int;			# what one press moves it by

		# the number showing, or lo if the person typed nonsense
		value:	fn(sb: self ref Spinbox): int;

		# put a number in, clamped to the range
		set:	fn(sb: self ref Spinbox, v: int);

		# act on a string that arrived on the channel new() returned.
		# Returns the value afterwards.  Anything unrecognised leaves
		# it alone, so an application can hand this every string it
		# gets without sorting them first.
		event:	fn(sb: self ref Spinbox, s: string): int;
	};

	init:	fn();

	# Make a spinbox at path inside an existing toplevel; the caller
	# packs path itself.  The channel is where the buttons report, and
	# an application must select on it and pass what arrives to event()
	# - the same arrangement every other widget in this toolkit uses,
	# because a Tk command is a string and cannot do arithmetic.
	new:	fn(top: ref Tk->Toplevel, path: string,
			lo, hi, step, start: int): (ref Spinbox, chan of string);
};
