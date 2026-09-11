# frame - plane frames and trusses, by the direct stiffness method
#
# The structure is written down the way a statics problem is set out:
# where the joints are, what runs between them, what holds it up and
# what pushes on it.
#
#	node a 0 0
#	node b 4 0
#	node c 4 3
#	beam a b 200e9 0.01 1e-5	# E, A, I
#	bar  b c 200e9 0.005		# pin-jointed: axial only
#	pin a
#	roller b y
#	force c 0 -1000
#
# UNITS ARE THE CALLER'S, and must be consistent: newtons and metres
# throughout, or pounds and inches throughout.  Nothing here converts
# anything, and a structure given E in gigapascals and A in square
# millimetres will return a deflection that is wrong by a factor no
# check can notice.
#
# Every node has three degrees of freedom - across, up, and rotation -
# so one element type does both jobs.  A `bar' is the same element with
# no bending stiffness, which is what pin-jointed means; a `beam' is the
# full frame element.  A node where only bars meet then has nothing
# resisting its rotation, and that degree of freedom is held at zero
# rather than left to make the matrix singular - said out loud here
# because it is a decision about the model and not an implementation
# detail.  A node that is genuinely free to move IS refused.

Frame: module
{
	PATH: con "/dis/lib/frame.dis";

	init:	fn();

	BAR, BEAM: con iota;

	Member: adt {
		kind:	int;
		a, b:	int;		# node indices
		e, area, inertia: real;
		udl:	real;		# distributed load, positive across the member
		length:	real;
		c, s:	real;		# direction cosines
	};

	Node: adt {
		name:	string;
		x, y:	real;
	};

	# Degrees of freedom, in the order they are numbered at each node.
	DX, DY, DR: con iota;

	Struct: adt {
		nodes:	array of ref Node;
		members: array of ref Member;
		restrained:	array of int;		# per dof: held at zero
		applied:	array of real;		# per dof
		u:	array of real;		# the answer: displacement per dof
		reaction: array of real;	# per dof, nonzero only where fixed
		heldrot:	int;			# dofs held by the no-stiffness rule

		node:	fn(s: self ref Struct, name: string): int;
		dof:	fn(s: self ref Struct, node, which: int): int;
		displacement: fn(s: self ref Struct, name: string, which: int): real;
		reactionat: fn(s: self ref Struct, name: string, which: int): real;
	};

	# Read a structure.  Returns it, or nil and what was wrong and where.
	parse:	fn(spec: string): (ref Struct, string);

	# Solve it.  Returns a diagnostic if the structure is a mechanism -
	# if some part of it can move without stretching anything - which is
	# a real answer about the structure and not a numerical failure.
	solve:	fn(s: ref Struct): string;

	# The forces in a member after a solve, in its own directions:
	# axial (tension positive), then shear and moment at each end.
	Forces: adt {
		axial:	real;
		shear1, moment1: real;
		shear2, moment2: real;
	};
	memberforces: fn(s: ref Struct, i: int): ref Forces;

	# The check every statics answer must pass: the loads and the
	# reactions must sum to zero, and so must their moments about any
	# point.  Returns the worst residual of the three.
	equilibrium: fn(s: ref Struct): (real, real, real);
};
