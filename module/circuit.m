# circuit - lumped electrical circuits, by modified nodal analysis
#
# A circuit is a NETLIST: one component per line, in the form every
# engineering student already knows, because the point of this is to be
# the thing they were taught rather than a private notation.
#
#	R1 in out 1k
#	C1 out 0 1u
#	V1 in 0 5
#	.tran 10u 5m
#
# and a capacitor that already has charge on it, or an inductor that
# already has current in it, says so:
#
#	.ic C1 5
#	.ic L1 100m
#
# Modified nodal analysis is the standard formulation and the reason it
# is standard is worth knowing: plain nodal analysis writes KCL at every
# node and cannot express a voltage source, because a voltage source
# says nothing about its own current.  MNA adds that current as an
# unknown of its own and the source's defining equation as a row.  The
# matrix that results is NOT positive definite - it has zeros on the
# diagonal where those rows are - so it is solved directly and not with
# krylov(2)'s conjugate gradients, which would need it to be.

Circuit: module
{
	PATH: con "/dis/lib/circuit.dis";

	# component kinds
	Res, Cap, Ind, Vsrc, Isrc: con iota;

	Part: adt {
		kind:	int;
		name:	string;
		a, b:	int;	# node indices; 0 is ground
		value:	real;
		# transient state: the voltage across and current through this
		# part at the end of the last step, which the companion models
		# for a capacitor and an inductor both need
		vprev, iprev: real;
		# the initial condition: a capacitor's voltage or an
		# inductor's current at t=0, from a `.ic' line.  Zero unless
		# hasic, which is not the same thing as absent - `.ic C1 0' is
		# a statement and not a default.
		ic:	real;
		hasic:	int;
		slot:	int;	# Vsrc: which extra unknown is its current
	};

	Net: adt {
		parts:	array of ref Part;
		names:	array of string;	# node index -> name; [0] is ground
		nnodes:	int;			# including ground
		nsrc:	int;			# voltage sources, each an extra unknown
		# what the spec asked for
		analysis: string;		# "dc" or "tran"
		tstep, tstop: real;
		method:	string;		# "trap" or "be"

		node:	fn(n: self ref Net, name: string): int;
		# the solution of the last solve: node voltages by index, then
		# the source currents
		x:	array of real;
		t:	real;
	};

	init:	fn();

	# Parse a netlist.  Returns the circuit or an error describing what
	# was wrong with the text.
	parse:	fn(spec: string): (ref Net, string);

	# The DC operating point: capacitors open, inductors shorted.
	dc:	fn(n: ref Net): string;

	# Set the initial condition; one of these must be called before the
	# first step.  begin() is the circuit at rest - no charge on any
	# capacitor and no current in any inductor, except where a `.ic'
	# line says otherwise - and beginfromdc() is
	# the circuit that has been switched on a long time already.
	#
	# Both then solve once more with each element HOLDING that state,
	# to find the other half of it: the current through each capacitor
	# and the voltage across each inductor.  At rest does not mean
	# those are zero - at t=0 in an RC the capacitor carries V/R - and
	# the trapezoidal rule reads them on its very first step.
	begin:	fn(n: ref Net): string;
	beginfromdc: fn(n: ref Net): string;

	# One transient step of h seconds from wherever the circuit is.
	step:	fn(n: ref Net, h: real): string;

	# Voltage at a node, and current through a part, by name.
	nodev:	fn(n: ref Net, name: string): real;
	parti:	fn(n: ref Net, name: string): real;

	# Solve A x = b for a small dense A, by Gaussian elimination with
	# partial pivoting.  Here because MNA needs it and nothing in the
	# tree had one; it belongs somewhere more general if a second
	# caller ever wants it.
	solve:	fn(a: array of array of real, b: array of real): (array of real, string);
};
