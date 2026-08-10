Draw3d: module
{
	PATH:	con "/dis/math/draw3d.dis";

	# Fixed-point scale for Polyfill plane coefficients (matches wm/polyhedra).
	ZSCALE:	con real (1<<20);

	MODEL, PROJ: con iota;

	# Immediate-mode primitive kinds (collide / GL-ish).
	POLY, FILLPOLY, CIRCLE, FILLCIRCLE, ELLIPSE, FILLELLIPSE: con iota;

	Vector: adt
	{
		x, y, z: real;
	};

	Matrix: type array of array of real;

	Context: adt
	{
		dst:		ref Draw->Image;
		zstate:	ref Polyfill->Zstate;
		zenable:	int;		# use z-buffer for fillpoly3 / sprites
		clipbehind:	int;		# reject eye z >= 0 (collide/frustum); 0 for ortho
		colour:		ref Draw->Image;
		# Optional foreshortening (TempleOS dc->transform); nil = identity.
		transform:	ref fn(v: Vector): Vector;
		# viewport: NDC → screen
		mx, cx, my, cy: real;
	};

	init:		fn();

	# --- context / frame ---
	context:	fn(dst: ref Draw->Image): ref Context;
	resize:		fn(c: ref Context, dst: ref Draw->Image);
	# Allocate z-buffer for a sub-rect (e.g. square inset); nil clears.
	setzarea:	fn(c: ref Context, r: Draw->Rect);
	clearz:		fn(c: ref Context);
	setz:		fn(c: ref Context, on: int);
	setzclip:	fn(c: ref Context, on: int);	# clipbehind gate
	setcolour:	fn(c: ref Context, col: ref Draw->Image);
	settransform:	fn(c: ref Context, t: ref fn(v: Vector): Vector);
	viewport:	fn(c: ref Context, x1, y1, x2, y2: int);

	# --- matrix stack (model / projection) ---
	mode:		fn(which: int);
	push:		fn();
	pop:		fn();
	identity:	fn();
	translate:	fn(x, y, z: real);
	scale:		fn(x, y, z: real);
	rotatex:	fn(deg: real);
	rotatey:	fn(deg: real);
	rotatez:	fn(deg: real);
	rotate:		fn(deg, l, m, n: real);	# axis (l,m,n) unit
	frustum:	fn(l, n, f: real);		# symmetric frustum helper
	ortho:		fn(l, n, f: real);
	loadmatrix:	fn(m: Matrix);
	storematrix:	fn(m: Matrix);
	matmul:		fn();			# proj * model → current MVP

	# --- project ---
	# Returns screen point, eye-space z, and ok (0 if clipped).
	project:	fn(c: ref Context, v: Vector): (Draw->Point, real, int);
	mulpoint:	fn(m: Matrix, v: Vector): Vector;

	# --- immediate mode (uses current MVP; draws to c.dst) ---
	begin:		fn(c: ref Context, kind, nvert: int);
	vertex:		fn(c: ref Context, x, y, z: real): (real, real);
	circle:		fn(c: ref Context, x, y, z, r: real);
	ellipse:	fn(c: ref Context, x, y, z: real, axes: Vector);
	end:		fn(c: ref Context);

	# --- TempleOS-parity primitives ---
	line3:		fn(c: ref Context, a, b: Vector, thick: int);
	plot3:		fn(c: ref Context, v: Vector);
	# Flat shaded poly; if zenable, computes plane depth for Polyfill.
	# normal is face normal in the same space as verts (for lighting/cull optional).
	fillpoly3:	fn(c: ref Context, verts: array of Vector, normal: Vector, lit: real);

	# Sprite3 family: img + optional mask (coffee-style).
	# scale is world-space half-width hint for perspective size; 0 → use img pixel size.
	sprite3:	fn(c: ref Context, p: Vector, img, mask: ref Draw->Image, scale: real);
	sprite3zb:	fn(c: ref Context, p: Vector, img, mask: ref Draw->Image, scale, degz: real);
	sprite3yb:	fn(c: ref Context, p: Vector, img, mask: ref Draw->Image, scale: real);
	sprite3mat:	fn(c: ref Context, p: Vector, m: Matrix, img, mask: ref Draw->Image, scale: real);

	# Utility
	newmatrix:	fn(): Matrix;
	vdot:		fn(a, b: Vector): real;
	vcross:		fn(a, b: Vector): Vector;
	vnorm:		fn(v: Vector): Vector;
};
