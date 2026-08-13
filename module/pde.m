Pde: module
{
	PATH:	con "/dis/lib/pde.dis";

	# Boundary conditions for scalar fields.
	CLAMP, PERIODIC, ZERO: con iota;

	Field: adt {
		nx, ny:	int;
		dx, dy:	real;
		bc:		int;
		u:		array of real;
		work:		array of real;
		old:		array of real;
	};

	init:		fn();
	new:		fn(nx, ny: int, dx, dy: real, bc: int): ref Field;
	clear:		fn(f: ref Field, value: real);
	get:		fn(f: ref Field, x, y: int): real;
	set:		fn(f: ref Field, x, y: int, value: real);
	splat:		fn(f: ref Field, cx, cy, radius: int, value: real);
	splatold:	fn(f: ref Field, cx, cy, radius: int, value: real);

	# Explicit finite-difference solvers.  They subdivide dt to remain stable.
	diffuse:	fn(f: ref Field, diffusivity, dt: real);
	wave:		fn(f: ref Field, speed, damping, dt: real);
	gray:		fn(a, b: ref Field, da, db, feed, kill, dt: real);
};
