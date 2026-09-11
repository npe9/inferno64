# flow - incompressible flow in two dimensions
#
# The Navier-Stokes equations for a fluid that cannot be compressed,
# solved by Chorin's projection method on a staggered grid.
#
# THE STAGGERED GRID IS NOT A DETAIL.  Pressure lives at cell centres
# and each velocity component on the faces it points through, so that
# the divergence of the velocity and the gradient of the pressure are
# each a difference between neighbours rather than across a skipped
# cell.  Putting everything at the centres instead is the obvious
# arrangement and it is wrong: it leaves the pressure free to oscillate
# cell by cell without the velocity noticing - the chequerboard mode -
# and a solution full of it looks perfectly smooth in the velocity and
# is nonsense in the pressure.
#
# THE PROJECTION.  A step is taken ignoring the pressure, which leaves a
# velocity field that does not conserve mass; the pressure is then what
# must be subtracted to make it do so, and finding it is a Poisson
# equation.  That system IS symmetric positive definite - unlike
# circuit(2)'s, which is why that one is solved directly - so it goes to
# krylov(2)'s conjugate gradients, which is what they are for.
#
# With every boundary periodic the pressure is determined only up to a
# constant, and the Poisson operator is singular.  That is a property of
# the physics and not a fault: only the GRADIENT of pressure appears in
# the equations.  The mean is removed from the right-hand side and from
# the answer, which is what makes the iteration converge.

Flow: module
{
	PATH: con "/dis/lib/flow.dis";

	init:	fn();

	# What happens at the edges.  PERIODIC wraps both directions;
	# CHANNEL wraps left to right and puts walls top and bottom;
	# CAVITY is walls all round, with the top one allowed to slide.
	PERIODIC, CHANNEL, CAVITY: con iota;

	# an initial velocity field, as a function of position
	Velocity: type ref fn(x, y: real): (real, real);

	Sim: adt {
		nx, ny:	int;		# interior cells
		dx, dy:	real;
		lx, ly:	real;		# the size of the box
		visc:	real;		# kinematic viscosity
		edges:	int;
		lid:	real;		# how fast the top wall slides, for CAVITY
		fx, fy:	real;		# a body force per unit mass, uniform
		t:	real;

		# the staggered fields, with one ghost layer all round
		u, v, p: array of real;

		# The velocity at a point, interpolated from the faces around
		# it, which is the only honest way to ask: no single array
		# holds both components at the same place.
		at:	fn(s: self ref Sim, x, y: real): (real, real);
		# the pressure at a point, likewise
		pressureat: fn(s: self ref Sim, x, y: real): real;

		# The largest divergence anywhere.  After a step this is the
		# projection's own residual and should sit at rounding; if it
		# grows, mass is being created.
		divergence: fn(s: self ref Sim): real;
		# the kinetic energy per unit area, which a decaying flow
		# loses at a rate the viscosity fixes
		energy:	fn(s: self ref Sim): real;
		# The Courant number at this step size.  Above about one the
		# explicit advection is unstable, and this is how a caller
		# finds out before rather than after.
		courant: fn(s: self ref Sim, dt: real): real;
	};

	new:	fn(nx, ny: int, lx, ly, visc: real, edges: int): (ref Sim, string);
	# Set the velocity from a function of position.  Each component is
	# sampled where it lives, not at the cell centre.
	setvelocity: fn(s: ref Sim, f: Velocity);
	# Advance by dt.  Returns a diagnostic if the pressure solve fails
	# or the step is one the scheme cannot take.
	step:	fn(s: ref Sim, dt: real): string;
	# The largest dt that is stable for advection and for diffusion,
	# whichever binds - a step no larger than this is the rule, and
	# step() refuses one that is far beyond it rather than returning
	# numbers that are about to become infinite.
	maxstep: fn(s: ref Sim): real;
};
