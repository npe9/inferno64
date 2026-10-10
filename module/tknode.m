#
# Decode the node tree libtk serialises through `render tree'.
#
# This is the consumer side of item 1 of doc/scene-graph-plan.ms: the
# render-node tree exists inside libtk and holds nothing display-side,
# and this is what lets a program outside libtk read one -- for
# recording, for sending somewhere else to draw, or for a backend that
# wants geometry rather than a raster.
#
# The wire form is one node per line:
#
#	NAME r.min.x r.min.y r.max.x r.max.y
#	     dstr.min.x dstr.min.y dstr.max.x dstr.max.y
#	     sp.x sp.y rgba radius width npts [x y]...
#	     "fontname" "text"
#
# all on one line.  The two strings are quoted and escaped because both
# can hold anything: a canvas text item's string is whatever the
# application put there, newline included.
#
Tknode: module
{
	PATH:	con "/dis/lib/tknode.dis";

	#
	# The node types, in the enum's order, which is the order in
	# include/tk.h and must not move: a number identifies a node type
	# to a backend that has seen it.
	#
	Tgroup,
	Tcolour,
	Troundfill,
	Tborder,
	Tcorners,
	Tlayer,
	Tlayerend,
	Ttexture,
	Tglyphs,
	Tlinear,
	Tshadow,
	Tclip,
	Ttransform,
	Topacity,
	Tellipse,
	Tellipsefill,
	Tpolyfill,
	Tspline,
	Tclipend,
	Ttransformend,
	Topacityend:	con iota;

	Nodetypes:	con Topacityend+1;

	Node: adt {
		ntype:		int;	# T* above, or -1 for a name libtk
					# emitted that this does not know
		r:		Draw->Rect;
		dstr:		Draw->Rect;
		sp:		Draw->Point;
		rgba:		int;
		radius:		int;
		width:		int;
		pts:		array of Draw->Point;
		fontname:	string;
		text:		string;

		#
		# The type name exactly as libtk wrote it, kept so that a
		# node this module does not know -- which libtk emits as
		# `unknown-N' -- survives a decode and encode unchanged.
		# Without it ntype -1 loses the N and the tree could not be
		# written back as it was read.
		#
		rawname:	string;

		name:	fn(n: self ref Node): string;
	};

	init:	fn();

	# Decode a whole dump.  On success the error is nil; on a
	# malformed line the nodes decoded so far come back WITH the
	# error, because a truncated tree is more use than nothing when
	# the question is what went wrong.
	decode:	fn(dump: string): (array of ref Node, string);

	# Write nodes back out in the same form decode reads, so a tree
	# can be modified outside libtk.  This is the other half of item 1
	# of doc/scene-graph-plan.ms.
	#
	# It is held to libtk's own output, not to its own round trip:
	# encode(decode(d)) must equal d byte for byte where d came from
	# libtk's C serialiser, which is an independent producer.  A
	# round trip against itself would pass with both halves wrong the
	# same way.
	encode:	fn(nodes: array of ref Node): string;

	# The name for a type, and the type for a name.  typeof returns
	# -1 for a name this module does not know, which is what a tree
	# from a newer libtk looks like.
	typename:	fn(t: int): string;
	typeof:		fn(name: string): int;
};
