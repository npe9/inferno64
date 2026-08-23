implement Verify;

include "sys.m";
	sys: Sys;
include "math.m";
	math: Math;
include "pde.m";
	pde: Pde;
	Field: import pde;
include "verify.m";

Pi: con 3.14159265358979323846;

init()
{
	if(sys == nil){
		sys = load Sys Sys->PATH;
		math = load Math Math->PATH;
		pde = load Pde Pde->PATH;
		pde->init();
	}
}

exact(x, y: real): real
{
	return math->sin(2.0*Pi*x)*math->sin(2.0*Pi*y);
}

# Laplacian of sin(2 pi x) sin(2 pi y) is -2*(2 pi)^2 times itself - each
# second partial contributes -(2 pi)^2 times the same product.
exactlap(x, y: real): real
{
	k := 2.0*Pi;
	return -2.0*k*k*exact(x,y);
}

absreal(x: real): real
{
	if(x < 0.0)
		return -x;
	return x;
}

exact3(x, y, z: real): real
{
	k := 2.0*Pi;
	return math->sin(k*x)*math->sin(k*y)*math->sin(k*z);
}

# Three second partials, each contributing -(2 pi)^2 times the same product.
exactlap3(x, y, z: real): real
{
	k := 2.0*Pi;
	return -3.0*k*k*exact3(x,y,z);
}

laplacian7order(n0, levels: int): (array of ref Level, string)
{
	init();
	if(math == nil)
		return (nil, "laplacian7order: no math module");
	if(n0 < 4)
		return (nil, "laplacian7order: n0 must be at least 4");
	if(levels < 1)
		return (nil, "laplacian7order: levels must be at least 1");
	results := array[levels] of ref Level;
	preverror := 0.0;
	n := n0;
	for(lv := 0; lv < levels; lv++){
		h := 1.0/real n;
		p := n+2;
		np := p*p*p;
		u := array[np] of real;
		y := array[np] of real;
		ix := 0; iy := 0;	# Limbo scopes a for-init to the function
		# Halo included, filled with the exact function: lap7 does no
		# boundary treatment, so this is what isolates the interior
		# stencil - the same purpose periodicity serves in 2-D.
		for(z := -1; z <= n; z++)
			for(iy = -1; iy <= n; iy++)
				for(ix = -1; ix <= n; ix++)
					u[(z+1)*p*p + (iy+1)*p + (ix+1)] =
						exact3(real ix*h, real iy*h, real z*h);
		for(i0 := 0; i0 < np; i0++)
			y[i0] = 0.0;
		# a = 1, so y = u + lap and the Laplacian is y - u.
		math->lap7(n, h, h, h, 1.0, u, y);
		maxerr := 0.0;
		for(z = 0; z < n; z++)
			for(iy = 0; iy < n; iy++)
				for(ix = 0; ix < n; ix++){
					i := (z+1)*p*p + (iy+1)*p + (ix+1);
					lh := y[i] - u[i];
					e := absreal(lh - exactlap3(real ix*h, real iy*h, real z*h));
					if(e > maxerr)
						maxerr = e;
				}
		order := 0.0;
		if(lv > 0 && maxerr > 0.0)
			order = math->log(preverror/maxerr)/math->log(2.0);
		results[lv] = ref Level(n, maxerr, order);
		preverror = maxerr;
		n *= 2;
	}
	return (results, nil);
}

laplacianorder(n0, levels: int): (array of ref Level, string)
{
	init();
	if(n0 < 4)
		return (nil, "laplacianorder: n0 must be at least 4");
	if(levels < 1)
		return (nil, "laplacianorder: levels must be at least 1");
	results := array[levels] of ref Level;
	preverror := 0.0;
	n := n0;
	for(lv := 0; lv < levels; lv++){
		f := pde->new(n, n, 1.0/real(n), 1.0/real(n), Pde->PERIODIC);
		for(iy := 0; iy < n; iy++)
			for(ix := 0; ix < n; ix++)
				pde->set(f, ix, iy, exact(real(ix)*f.dx, real(iy)*f.dy));
		before := array[len f.u] of real;
		before[0:] = f.u;
		# Comfortably under diffuse()'s own 0.24*h^2/d stability bound,
		# so it takes this as one unsubdivided explicit-Euler step.
		h2 := f.dx*f.dx;
		if(f.dy*f.dy < h2)
			h2 = f.dy*f.dy;
		step := 0.2*h2;
		pde->diffuse(f, 1.0, step);
		maxerr := 0.0;
		for(iy = 0; iy < n; iy++)
			for(ix = 0; ix < n; ix++){
				i := iy*n+ix;
				lh := (f.u[i]-before[i])/step;
				e := absreal(lh-exactlap(real(ix)*f.dx, real(iy)*f.dy));
				if(e > maxerr)
					maxerr = e;
			}
		order := 0.0;
		if(lv > 0 && maxerr > 0.0)
			order = math->log(preverror/maxerr)/math->log(2.0);
		results[lv] = ref Level(n, maxerr, order);
		preverror = maxerr;
		n *= 2;
	}
	return (results, nil);
}
