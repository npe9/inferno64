Mesh: module
{
	PATH: con "/dis/lib/mesh.dis";

	# Shared with pde(2)'s own Field.bc, deliberately the same values -
	# a Grid is exactly the geometry half of a Field, split out so any
	# future problem class (not just pde(2)'s finite-difference solvers)
	# describes its domain the same way instead of re-deriving "NXxNY
	# domain WxH bc ..." parsing on its own. This is the layering point:
	# a mesh is infrastructure every problem class shares; the equation
	# on top of it is each class's own small language.
	CLAMP, PERIODIC, ZERO: con iota;

	Grid: adt {
		nx, ny:	int;
		dx, dy:	real;
		bc:		int;
	};

	# Parses one line: "mesh NXxNY [domain WxH] [bc clamp|periodic|zero]".
	# domain defaults to 1x1 (dx=1/NX, dy=1/NY); bc defaults to clamp.
	parse:	fn(line: string): (ref Grid, string);
};
