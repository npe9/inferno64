Amr: module
{
	PATH: con "/dis/lib/amr.dis";

	# Block-structured AMR, the shape miniAMR itself uses (fixed-size
	# blocks refined/coarsened as a unit, NOT an arbitrary octree of
	# individual cells): the domain is tiled at level 0 by an
	# nx0 x ny0 x nz0 grid of blocks, each holding blocksize^3 cells.
	# Refining a block replaces it with 8 level+1 children, each still
	# blocksize^3 cells but covering half the parent's physical extent
	# per axis - i.e. refinement halves the cell size, not the block
	# count per block. A block's (bi,bj,bk) is its index in the level's
	# own *virtual* grid (size (nx0*2^level) x (ny0*2^level) x
	# (nz0*2^level)) - the standard level+integer-coordinate addressing
	# block/patch AMR codes use, here used directly rather than via a
	# hashed lookup structure.
	Block: adt {
		level:		int;
		bi, bj, bk:	int;
		active:		int;	# 1 = leaf (real data); 0 = refined (children hold the data)
		children:	cyclic array of ref Block;	# nil unless refined; else len 8
		# Interior + 1-cell ghost halo, flat (blocksize+2)^3, x fastest:
		# index (z+1)*(B+2)*(B+2) + (y+1)*(B+2) + (x+1) for interior
		# cell (x,y,z) in [0,blocksize); ghost cells at -1 and blocksize.
		u:		array of real;
	};

	Forest: adt {
		nx0, ny0, nz0:	int;
		blocksize:	int;	# B; must be even (refine()/coarsen() require it)
		maxlevel:	int;
		domainx, domainy, domainz: real;
		roots:		array of ref Block;	# nx0*ny0*nz0, row-major bi,bj,bk
	};

	new:	fn(nx0, ny0, nz0, blocksize, maxlevel: int,
			domainx, domainy, domainz: real): ref Forest;

	# Physical cell size at level (same for every block at that level).
	cellsize: fn(f: ref Forest, level: int): (real, real, real);

	# A block's physical centre and half-extent - what a Criterion is
	# evaluated against.
	blockbox: fn(f: ref Forest, b: ref Block): (real, real, real, real, real, real);

	# Every active (leaf) block, in a stable order.
	activeblocks: fn(f: ref Forest): array of ref Block;

	# Splits b into 8 level+1 children, seeding each with a real
	# piecewise-constant injection of b's own interior values (not a
	# placeholder). No-op if b is already refined or at f.maxlevel.
	refine:	fn(f: ref Forest, b: ref Block);

	# Merges b's 8 children back into b via real restriction (each of
	# b's interior cells becomes the volume-average of the matching
	# 2x2x2 block of fine cells), then discards the children. No-op
	# unless b is refined and all 8 children are themselves leaves
	# (coarsening only ever removes one level at a time, bottom-up).
	coarsen: fn(f: ref Forest, b: ref Block);

	# Bare function reference, not a closure (Limbo has no closure
	# literals - the same convention as krylov(2)'s Apply / fem(2)'s
	# Src): given a block's physical centre and half-extent, should it
	# be refined?
	Criterion: type ref fn(cx, cy, cz, hx, hy, hz: real): int;

	# One adaptation pass: refines every active block crit flags (down
	# to maxlevel), first extending the refine set until the forest is
	# 2:1 balanced (no two face-adjacent leaves differ by more than one
	# level - what bounds exchange() to only ever needing a same-level,
	# one-level-coarser, or up-to-4-one-level-finer neighbor per face,
	# the standard block-AMR technique, not a simplification specific
	# to this implementation); then coarsens every refined block whose
	# own box crit no longer flags and whose children are all
	# themselves leaves (coarsening never checks cross-neighbor
	# balance - a real, documented scope limit, not an oversight).
	adapt:	fn(f: ref Forest, crit: Criterion);

	# Fills every active block's 1-cell ghost halo from its neighbors:
	# same-level neighbor -> direct copy; one-level-coarser neighbor ->
	# piecewise-constant prolongation of its boundary cells; one-level-
	# finer neighbors (up to 4 per face) -> volume-averaged restriction
	# of their boundary cells. At the domain's own outer boundary,
	# ghosts are filled by clamping (copying the block's own boundary
	# cell outward - a zero-Neumann condition), matching pde(2)'s CLAMP.
	exchange: fn(f: ref Forest);

	# One explicit diffusion-stencil step (7-point 3D Laplacian) on
	# every active block's interior cells, using each block's own
	# (already-exchanged) ghost halo - the same stability-limited
	# explicit-substepping convention as pde(2)'s own diffuse().
	step:	fn(f: ref Forest, diffusivity, dt: real);

	# exchange() then step() - what a driver loop calls each iteration.
	sweep:	fn(f: ref Forest, diffusivity, dt: real);

	# Field access by physical cell index within one block (not a
	# global index - AMR has no single global grid). x,y,z in
	# [0,blocksize).
	get:	fn(b: ref Block, blocksize: int, x, y, z: int): real;
	set:	fn(b: ref Block, blocksize: int, x, y, z: int, value: real);
	clear:	fn(f: ref Forest, value: real);
	splat:	fn(f: ref Forest, cx, cy, cz, radius: real, value: real);

	# Total mass: the sum of value*cellsize^3 over every active block's
	# every interior cell - the invariant a diffusion/restrict/prolongate
	# cycle should conserve, used for verification.
	#
	# (This comment used to describe it as the total cell *volume*, which
	# omits the value and would make it independent of the field and
	# useless as an invariant. man/2/amr always had it right.)
	totalmass: fn(f: ref Forest): real;
};
