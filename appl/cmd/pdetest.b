implement Command;

#
# Tests math(2)'s stencil builtins - lap5 and lap7 - against the Limbo loops
# they replaced.
#
# The interior of that kernel is easy and the border is not: it exists so the
# interior loop can run without a boundary test in it, which means the edges
# are computed by separate code, once, per boundary condition. Getting one of
# those wrong changes a result by a few cells out of thousands - invisible in
# a solve, which is why this compares every cell against the obvious version
# rather than checking that a solve still looks right.
#
# All three boundary conditions are checked, because a solve run to try the
# thing out will use one of them and leave the other two unexercised. That is
# exactly what happened: lap5 was measured on clamp alone.
#
# Grids that are thin in one direction are checked too. The border walk treats
# rows and columns separately and guards against a grid one cell wide, and
# those guards had never been run.
#
include "sys.m";
	sys: Sys;
	print, sprint: import sys;
include "math.m";
	math: Math;
include "draw.m";

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

# Same values pde(2) uses.
CLAMP, PERIODIC, ZERO: con iota;

fail := 0;

bad(s: string)
{
	print("FAIL: %s\n", s);
	fail = 1;
}

bcname(bc: int): string
{
	case bc {
	CLAMP =>	return "clamp";
	PERIODIC =>	return "periodic";
	ZERO =>		return "zero";
	}
	return "?";
}

# What pde(2)'s getvec does, and the definition lap5 has to match.
get(x: array of real, nx, ny, bc, ix, iy: int): real
{
	if(bc == PERIODIC){
		ix = (ix%nx + nx)%nx;
		iy = (iy%ny + ny)%ny;
	}else if(ix < 0 || ix >= nx || iy < 0 || iy >= ny){
		if(bc == ZERO)
			return 0.0;
		if(ix < 0) ix = 0;
		if(ix >= nx) ix = nx-1;
		if(iy < 0) iy = 0;
		if(iy >= ny) iy = ny-1;
	}
	return x[iy*nx+ix];
}

reflap(x, y: array of real, nx, ny: int, dx, dy: real, bc: int)
{
	for(iy := 0; iy < ny; iy++)
		for(ix := 0; ix < nx; ix++){
			c := get(x, nx, ny, bc, ix, iy);
			y[iy*nx+ix] =
				(get(x,nx,ny,bc,ix-1,iy)-2.0*c+get(x,nx,ny,bc,ix+1,iy))/(dx*dx)
			      + (get(x,nx,ny,bc,ix,iy-1)-2.0*c+get(x,nx,ny,bc,ix,iy+1))/(dy*dy);
		}
}

seed := 7;

rnd(): real
{
	seed = (seed*1103515245 + 12345) & 16r7fffffff;
	return real ((seed >> 9) % 2000 - 1000) / 100.0;
}

# Every cell, against the reference. Not an equality: the C loop contracts a
# multiply and an add into a fused one where the Limbo loop does not, so a few
# units in the last place are expected and anything larger is not rounding.
check(nx, ny: int, dx, dy: real, bc: int)
{
	n := nx*ny;
	i := 0;			# Limbo scopes a for-init to the whole function
	x := array[n] of real;
	for(i = 0; i < n; i++)
		x[i] = rnd();
	got := array[n] of real;
	want := array[n] of real;
	math->lap5(nx, ny, dx, dy, bc, x, got);
	reflap(x, want, nx, ny, dx, dy, bc);

	worst := 0.0;
	nbad := 0;
	wix := -1;
	wiy := -1;
	for(iy := 0; iy < ny; iy++)
		for(ix := 0; ix < nx; ix++){
			i = iy*nx+ix;
			d := got[i] - want[i];
			if(d < 0.0)
				d = -d;
			if(want[i] != 0.0)
				d /= math->fabs(want[i]);
			if(d > 1e-12)
				nbad++;
			if(d > worst){
				worst = d;
				wix = ix;
				wiy = iy;
			}
		}
	if(nbad != 0)
		bad(sprint("%dx%d %s: %d cells differ, worst %g at (%d,%d): %g against %g",
			nx, ny, bcname(bc), nbad, worst, wix, wiy,
			got[wiy*nx+wix], want[wiy*nx+wix]));
	else
		print("  %3dx%-3d %-8s worst relative difference %g\n",
			nx, ny, bcname(bc), worst);
}

# lap7 works on a padded cube whose one-cell halo the caller has filled, so it
# has no boundary handling at all - the risk is entirely in the strides, which
# are p and p*p for a p=(n+2) cube, and in the fused "c + a*lap". Both are
# invisible in a solve: a wrong stride reads a real number from the wrong cell.
pidx(n, x, y, z: int): int
{
	p := n+2;
	return (z+1)*p*p + (y+1)*p + (x+1);
}

reflap7(n: int, dx, dy, dz, a: real, u, y: array of real)
{
	for(z := 0; z < n; z++)
		for(yy := 0; yy < n; yy++)
			for(x := 0; x < n; x++){
				c := u[pidx(n,x,yy,z)];
				l := (u[pidx(n,x-1,yy,z)]-2.0*c+u[pidx(n,x+1,yy,z)])/(dx*dx)
				   + (u[pidx(n,x,yy-1,z)]-2.0*c+u[pidx(n,x,yy+1,z)])/(dy*dy)
				   + (u[pidx(n,x,yy,z-1)]-2.0*c+u[pidx(n,x,yy,z+1)])/(dz*dz);
				y[pidx(n,x,yy,z)] = c + a*l;
			}
}

check7(n: int, dx, dy, dz, a: real)
{
	p := n+2;
	np := p*p*p;
	u := array[np] of real;
	j := 0;
	for(j = 0; j < np; j++)
		u[j] = rnd();		# halo included: it is real data here
	got := array[np] of real;
	want := array[np] of real;
	for(j = 0; j < np; j++){
		got[j] = -12345.0;	# so an unwritten interior cell shows up
		want[j] = -12345.0;
	}
	math->lap7(n, dx, dy, dz, a, u, got);
	reflap7(n, dx, dy, dz, a, u, want);

	worst := 0.0;
	nbad := 0;
	for(z := 0; z < n; z++)
		for(y := 0; y < n; y++)
			for(x := 0; x < n; x++){
				i := pidx(n,x,y,z);
				d := got[i] - want[i];
				if(d < 0.0)
					d = -d;
				if(want[i] != 0.0)
					d /= math->fabs(want[i]);
				if(d > 1e-12)
					nbad++;
				if(d > worst)
					worst = d;
			}
	if(nbad != 0)
		bad(sprint("lap7 %d^3: %d interior cells differ, worst %g", n, nbad, worst));
	else
		print("  lap7 %2d^3   worst relative difference %g\n", n, worst);

	# The halo must not be written: amr(2) relies on it being refilled by
	# exchange() rather than on whatever a stencil left behind, and a
	# kernel that ran one cell too far would still produce a correct
	# interior.
	nh := 0;
	for(z = -1; z <= n; z++)
		for(y = -1; y <= n; y++)
			for(x = -1; x <= n; x++)
				if(x < 0 || x >= n || y < 0 || y >= n || z < 0 || z >= n)
					if(got[pidx(n,x,y,z)] != -12345.0)
						nh++;
	if(nh != 0)
		bad(sprint("lap7 %d^3 wrote %d halo cells", n, nh));
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	if(math == nil){
		print("pdetest: load Math: %r\n");
		raise "fail:load";
	}

	for(bc := 0; bc <= 2; bc++){
		check(37, 29, 0.031, 0.047, bc);	# nothing square or round
		check(64, 64, 0.015625, 0.015625, bc);
		check(1, 1, 0.5, 0.5, bc);		# no interior at all
		check(1, 12, 0.5, 0.25, bc);		# one column
		check(12, 1, 0.25, 0.5, bc);		# one row
		check(2, 2, 0.5, 0.5, bc);		# border only
	}

	# A grid where the answer is known independently: the discrete
	# Laplacian of a plane is zero everywhere inside, whatever the
	# spacing. This catches a sign or a spacing error that comparing
	# against a reference cannot, because both would share it.
	nx := 20;
	ny := 16;
	x := array[nx*ny] of real;
	for(iy := 0; iy < ny; iy++)
		for(ix := 0; ix < nx; ix++)
			x[iy*nx+ix] = 3.0*real ix - 2.0*real iy + 1.0;
	y := array[nx*ny] of real;
	math->lap5(nx, ny, 0.1, 0.2, CLAMP, x, y);
	worst := 0.0;
	for(iy = 1; iy < ny-1; iy++)
		for(ix = 1; ix < nx-1; ix++){
			d := y[iy*nx+ix];
			if(d < 0.0)
				d = -d;
			if(d > worst)
				worst = d;
		}
	if(worst > 1e-9)
		bad(sprint("the Laplacian of a plane is %g, expected 0", worst));
	else
		print("  the Laplacian of a plane is %g inside\n", worst);

	# lap7: no boundary conditions, so the cases that matter are the
	# strides and the halo.
	check7(1, 0.5, 0.5, 0.5, 0.01);		# a single interior cell
	check7(2, 0.5, 0.25, 0.125, 0.02);
	check7(8, 0.031, 0.047, 0.019, 0.005);	# nothing square
	check7(16, 0.0625, 0.0625, 0.0625, 0.0);	# a = 0: pure copy of c

	if(fail)
		raise "fail:test";
	print("PASS\n");
}
