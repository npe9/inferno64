# Callers must include "draw.m" and "mesh.m" themselves before including
# this file (this tree's own convention - wmclient.m/tk.m do the same:
# they reference Draw types without including draw.m, relying on
# whichever .b file consumes them to have included it first).
Meshview: module
{
	PATH: con "/dis/lib/meshview.dis";

	# A little language for turning a mesh(2) grid's worth of scalar
	# values into pixels - the same relationship plot(2) has to a
	# time-series chart, applied to a 2-D field instead: describe the
	# colour ramp once via cmd(), then draw() every frame, rather than
	# every caller hand-building its own 256-entry palette table and
	# per-cell blit loop the way pdelab.b did for each of its three
	# equations before this existed.
	View: adt {
		image:		ref Draw->Image;
		font:		ref Draw->Font;
		palette:	array of ref Draw->Image;
		lo, hi:		real;

		# colour lo hi rgba0 rgba1 [rgba2 ...]
		#   Maps [lo,hi] onto an evenly spaced, linearly interpolated
		#   ramp through the given 16rRRGGBBAA stops (2 stops is a
		#   simple two-colour gradient; 3+ gives a fuller heat ramp,
		#   e.g. the same blue/cyan/yellow pdelab.b built by hand:
		#   "colour 0 1 16r000030ff 16r0060c0ff 16rffe000ff"). Resolves
		#   colours via font.display, not image.display - same reason
		#   plot(2)'s own "colour" command does: image may still be nil
		#   at setup time (before the first reshape/onscreen), font
		#   isn't, so cmd() works regardless of setup order.
		cmd:	fn(v: self ref View, command: string): string;

		# Draws grid's nx by ny values into r, one sub-rectangle per
		# cell - the same cell-size arithmetic pdelab.b's own loop
		# used, generalized to any mesh(2) grid.
		draw:	fn(v: self ref View, r: Draw->Rect, grid: ref Mesh->Grid,
				values: array of real);
	};

	new:	fn(image: ref Draw->Image, font: ref Draw->Font): ref View;
};
