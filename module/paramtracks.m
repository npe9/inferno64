Paramtracks: module
{
	PATH: con "/dis/lib/paramtracks.dis";

	# A small Tk/Plot-style command language for the labelled parameter-track
	# control band several danby models draw along one edge of the window:
	# equal-width horizontal sliders, one per live parameter, hit-tested by
	# fraction-across-the-slot and drawn as a line, a dot at the current
	# value, and a "name value" label underneath. Collapses what was
	# independently hand-rolled per model (drawcontrol/drawcontrols/
	# setpointer's band-hit-test arithmetic) into one small reusable module,
	# the same way plot(2) replaced per-model chart-drawing code.

	Track: adt {
		name:	string;
		lo, hi:	real;
		value:	real;
		colour:	string;
	};

	Tracks: adt {
		image:		ref Draw->Image;
		font:		ref Draw->Font;
		tracks:		array of ref Track;
		bandheight:	int;
		colours:	list of (string, ref Draw->Image);

		# Commands (newline-separated, like plot(2)'s cmd):
		#   colour name rgba
		#   band height
		#   track name lo hi [colour name]
		#   set name value
		# Returns an error string, or nil on success.
		cmd:	fn(t: self ref Tracks, command: string): string;

		# Draws the band (one slot per track, left to right) within the
		# bottom t.bandheight pixels of r.
		draw:	fn(t: self ref Tracks, r: Draw->Rect);

		# If p falls within the band inside r, updates the hit track's
		# value from p's fractional position across its slot (clamped to
		# [0.01, 0.99] of the slot) and returns (name, new value, 1).
		# Otherwise returns ("", 0.0, 0).
		hit:	fn(t: self ref Tracks, p: Draw->Point, r: Draw->Rect):
				(string, real, int);

		# Current value of a named track (0.0 if no such track).
		value:	fn(t: self ref Tracks, name: string): real;
	};

	new:	fn(image: ref Draw->Image, font: ref Draw->Font): ref Tracks;
};
