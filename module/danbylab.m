# danbylab - the seven families of danby(1) model, one library
#
# A model is a script.  Two languages share it: dynsys(2) reads the
# equations - param, state, derivative, eq, observable, point, maxtime -
# and this module reads everything that says what the picture is.  The
# split is the whole design:
#
#	Model	the equations		owned by dynsys(2)
#	Config	the picture		owned by this module
#
# parse() returns both and nothing else.  It touches no window, so a
# test can check a model's numbers with no display at all, which is the
# only check worth having for the equations; run() adds the window.
#
# A spec's first line says which family it belongs to.  The family
# chooses the panels, the graph, and the rules a step obeys; everything
# else - the parameter sliders, the buttons, the status line, the event
# loop - is shared, because seven copies of it were seven places for the
# same bug to live.

# A model includes sys.m, then draw.m, then this file, which includes
# dynsys.m itself - and dynsys.m includes hoc.m.  Limbo has no include
# guard, so a model must not include either of those again.
include "dynsys.m";

Danbylab: module
{
	PATH: con "/dis/lib/danbylab.dis";

	# the families, as named by the spec's "family" line
	Mechanism, Population, Trajectory, Orbit, Ecology, Flight, Profile: con iota;

	# What the spec says that dynsys(2) does not claim.  The first four
	# fields belong to every family; the rest belong to one each, and
	# are nil or zero in the others.
	Config: adt {
		family:		int;
		title:		string;
		manual:		string;	# the man page the wm menu opens

		# What the moving thing looks like: the name of an element
		# list in /lib/danby/sprites, drawn through vsprite(2) at
		# whatever size the pane wants and turned to face the way it
		# is going.  A spec that says nothing gets its family's
		# default, which is why 151 of them did not have to be
		# edited to gain a picture.
		sprite:		string;

		links:		array of int;		# Mechanism: pairs of point indices
		linkspr:	array of string;	# and the component each is drawn as
		bodies:		array of string;	# Orbit: what each body is called
		massexprs:	array of ref Hoc->Expr;	# Orbit: and what it weighs
		equilx, equily:	ref Hoc->Expr;		# Ecology: the fixed point
		fixedscale:	real;			# Ecology: 0 means grow to fit
		radius, span:	ref Hoc->Expr;		# Profile: where the march runs
		samples:	int;			# Profile: how many steps
		normalised:	int;			# Profile: observable index, -1 for none
	};

	# The whole of the script and nothing else.
	parse:	fn(spec: string): (ref Dynsys->Model, ref Config, string);

	# The script, a window, and the simulation until the window closes.
	# name is the model's own name, used to find its man page.
	run:	fn(ctxt: ref Draw->Context, name, spec: string): string;

	# The three families whose extra language is arithmetic evaluate it
	# here, so a test can ask for the same numbers the picture shows.
	# Each needs the model's parameters already bound, which
	# dynsys->initialstate() and dynsys->rhs() both do.
	masses:		fn(m: ref Dynsys->Model, c: ref Config): array of real;
	equilibrium:	fn(m: ref Dynsys->Model, c: ref Config): (real, real);
	march:		fn(m: ref Dynsys->Model, c: ref Config): array of real;
};
