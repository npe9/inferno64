#
# Rasterise a decoded libtk render-node tree with draw(2).
#
# This is the half of doc/scene-graph-plan.ms item 1 that tknode(2)
# could not supply on its own.  tknode shows every field of a
# serialised tree SURVIVES the trip; this shows the tree is
# SUFFICIENT -- that what comes out the other end is enough to
# reproduce the picture, with no access to libtk at all.
#
# It is deliberately written against nothing but draw(2): Display.color,
# Image.draw, ellipse, fillellipse, fillpoly, bezspline, Image.text and
# Display.newimage.  Every libtk renderer case is one of those plus
# integer arithmetic, so a consumer needs no privileged access -- which
# is the claim the plan makes and this is the thing that tests it.
#
# What a caller gets back is counted, not assumed: how many nodes were
# drawn and how many were of a type this does not implement.  A
# rasteriser that silently skipped what it could not draw would compare
# equal on a tree of nothing.
#
Tkrender: module
{
	PATH:	con "/dis/lib/tkrender.dis";

	# Must be called before draw(), with the display the target image
	# belongs to.
	init:	fn(d: ref Draw->Display);

	#
	# Draw a decoded tree into dst, in dst's own coordinates (which is
	# what the tree carries: see tknode(2) on dumps being unscaled).
	# Returns the number of nodes drawn, the number whose type is not
	# implemented here, and an error.
	#
	draw:	fn(dst: ref Draw->Image, nodes: array of ref Tknode->Node): (int, int, string);

	# The corner arithmetic, exposed because it is the one piece of
	# libtk geometry a consumer has to reproduce rather than read off
	# a node, and a caller may want to check it independently.
	inset:		fn(radius, y: int): int;
	clamprad:	fn(r: Draw->Rect, radius: int): int;
};
