Femesh: module
{
	PATH: con "/dis/lib/femesh.dis";

	# A structured brick of hex8 elements - the mesh shape a real
	# finite-element assembly (unlike pde(2)'s finite-difference
	# stencils on a mesh(2) Grid) needs: nodes, elements, and which
	# nodes each element touches, not just a uniform array of values.
	# nx*ny*nz elements; (nx+1)*(ny+1)*(nz+1) nodes, node (i,j,k)
	# numbered id = k*(ny+1)*(nx+1) + j*(nx+1) + i.
	Grid: adt {
		nx, ny, nz:	int;
		dx, dy, dz:	real;
	};

	nnodes:	fn(g: ref Grid): int;
	nelem:	fn(g: ref Grid): int;

	nodeid:		fn(g: ref Grid, i, j, k: int): int;
	nodeijk:	fn(g: ref Grid, n: int): (int, int, int);
	nodecoord:	fn(g: ref Grid, n: int): (real, real, real);

	# 1 if node n lies on any of the brick's six outer faces (i==0,
	# i==nx, j==0, j==ny, k==0, or k==nz) - the set a Dirichlet
	# boundary condition applies to.
	isboundary:	fn(g: ref Grid, n: int): int;

	# The 8 global node ids of element e (0 <= e < nelem(g)), in
	# standard hex8 local order: bottom face counterclockwise
	# (local 0,1,2,3, at (ei,ej,ek), (ei+1,ej,ek), (ei+1,ej+1,ek),
	# (ei,ej+1,ek)), then the top face the same way (local 4,5,6,7,
	# each directly above the local node 4 below it, at k+1) - the
	# order fem(2)'s element stiffness matrix is written against.
	elemnodes:	fn(g: ref Grid, e: int): array of int;

	# Parses "mesh NXxNYxNZ [domain WxHxD]"; domain defaults to 1x1x1
	# (dx=1/NX, dy=1/NY, dz=1/NZ).
	parse:	fn(line: string): (ref Grid, string);
};
