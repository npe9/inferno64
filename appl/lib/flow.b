implement Flow;

# Incompressible flow in two dimensions, by Chorin's projection method
# on a staggered grid.  See flow.m for why the grid is staggered and
# why the pressure system goes to conjugate gradients.
#
# INDEXING.  Every array is (nx+2) by (ny+2) so that there is one ghost
# layer all round and the boundary conditions can be written once, as a
# fill of the ghosts, instead of appearing inside every loop.  Interior
# cells are i = 1..nx and j = 1..ny.
#
#	p[i][j]  at the centre of cell (i,j)
#	u[i][j]  on the face between cell (i,j) and cell (i+1,j)
#	v[i][j]  on the face between cell (i,j) and cell (i,j+1)
#
# so u[0][j] is the left boundary face of the interior and u[nx][j] the
# right one; v[i][0] and v[i][ny] are the bottom and top.

include "sys.m";
	sys: Sys;
include "math.m";
	math: Math;
include "krylov.m";
	krylov: Krylov;
	Solver: import krylov;
include "flow.m";

init()
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	krylov = load Krylov Krylov->PATH;
}

# the one simulation the pressure operator is being applied to; Limbo
# has no closures and krylov(2) takes a bare function reference
cur: ref Sim;

new(nx, ny: int, lx, ly, visc: real, edges: int): (ref Sim, string)
{
	if(nx < 2 || ny < 2)
		return (nil, "a grid needs at least two cells each way");
	if(lx <= 0.0 || ly <= 0.0)
		return (nil, "the box must have a size");
	if(visc < 0.0)
		return (nil, "a negative viscosity would add energy rather than remove it");
	if(edges != PERIODIC && edges != CHANNEL && edges != CAVITY)
		return (nil, "the edges are periodic, a channel or a cavity");
	s := ref Sim;
	s.nx = nx;
	s.ny = ny;
	s.lx = lx;
	s.ly = ly;
	s.dx = lx/real nx;
	s.dy = ly/real ny;
	s.visc = visc;
	s.edges = edges;
	s.lid = 0.0;
	s.fx = s.fy = 0.0;
	s.t = 0.0;
	n := (nx+2)*(ny+2);
	s.u = array[n] of real;
	s.v = array[n] of real;
	s.p = array[n] of real;
	for(i := 0; i < n; i++)
		s.u[i] = s.v[i] = s.p[i] = 0.0;
	return (s, nil);
}

ix(s: ref Sim, i, j: int): int
{
	return i + (s.nx+2)*j;
}

setvelocity(s: ref Sim, f: Velocity)
{
	# each component is sampled where it actually lives
	for(j := 0; j <= s.ny+1; j++)
		for(i := 0; i <= s.nx+1; i++){
			(ux, nil) := f(real i*s.dx, (real j - 0.5)*s.dy);
			s.u[ix(s, i, j)] = ux;
			(nil, vy) := f((real i - 0.5)*s.dx, real j*s.dy);
			s.v[ix(s, i, j)] = vy;
		}
	ghosts(s);
}

# Fill the ghost layer so that every interior loop can read its
# neighbours without asking where it is.
ghosts(s: ref Sim)
{
	(nx, ny) := (s.nx, s.ny);
	if(s.edges == PERIODIC || s.edges == CHANNEL){
		# Left and right wrap.  The faces that are solved for are
		# u[1..nx]; u[0] is the same face as u[nx] seen from the other
		# end of the box, and is a ghost, so it is copied and never
		# computed.  Getting this the other way round - computing u[0]
		# and copying u[nx] - loses the last column's contribution to
		# the divergence.
		for(j := 0; j <= ny+1; j++){
			s.u[ix(s, 0, j)] = s.u[ix(s, nx, j)];
			s.u[ix(s, nx+1, j)] = s.u[ix(s, 1, j)];
			s.v[ix(s, 0, j)] = s.v[ix(s, nx, j)];
			s.v[ix(s, nx+1, j)] = s.v[ix(s, 1, j)];
			s.p[ix(s, 0, j)] = s.p[ix(s, nx, j)];
			s.p[ix(s, nx+1, j)] = s.p[ix(s, 1, j)];
		}
	} else {
		# walls left and right: no flow through, no slip along
		for(j := 0; j <= ny+1; j++){
			s.u[ix(s, 0, j)] = 0.0;
			s.u[ix(s, nx, j)] = 0.0;
			s.u[ix(s, nx+1, j)] = 0.0;
			s.u[ix(s, 1, j)] = s.u[ix(s, 1, j)];
			s.v[ix(s, 0, j)] = -s.v[ix(s, 1, j)];
			s.v[ix(s, nx+1, j)] = -s.v[ix(s, nx, j)];
			s.p[ix(s, 0, j)] = s.p[ix(s, 1, j)];
			s.p[ix(s, nx+1, j)] = s.p[ix(s, nx, j)];
		}
	}
	if(s.edges == PERIODIC){
		for(i := 0; i <= nx+1; i++){
			s.v[ix(s, i, 0)] = s.v[ix(s, i, ny)];
			s.v[ix(s, i, ny+1)] = s.v[ix(s, i, 1)];
			s.u[ix(s, i, 0)] = s.u[ix(s, i, ny)];
			s.u[ix(s, i, ny+1)] = s.u[ix(s, i, 1)];
			s.p[ix(s, i, 0)] = s.p[ix(s, i, ny)];
			s.p[ix(s, i, ny+1)] = s.p[ix(s, i, 1)];
		}
	} else {
		# walls top and bottom.  No flow through them, so v on the
		# boundary face is zero; no slip along them, so u's ghost is
		# the mirror of the cell inside, which puts zero half way
		# between - except at a lid, which drags the fluid with it.
		for(i := 0; i <= nx+1; i++){
			s.v[ix(s, i, 0)] = 0.0;
			s.v[ix(s, i, ny)] = 0.0;
			s.v[ix(s, i, ny+1)] = 0.0;
			s.u[ix(s, i, 0)] = -s.u[ix(s, i, 1)];
			s.u[ix(s, i, ny+1)] = 2.0*s.lid - s.u[ix(s, i, ny)];
			s.p[ix(s, i, 0)] = s.p[ix(s, i, 1)];
			s.p[ix(s, i, ny+1)] = s.p[ix(s, i, ny)];
		}
	}
}

# The faces that are solved for run 1..uhi across and 1..vhi up.  Where
# a direction wraps, the last face is a real unknown and the ZEROTH is
# its ghost; where it is walled, the first and last faces are the walls
# themselves and neither is an unknown.
uhi(s: ref Sim): int
{
	if(s.edges == CAVITY)
		return s.nx-1;		# u[0] and u[nx] are walls
	return s.nx;
}

vhi(s: ref Sim): int
{
	if(s.edges == PERIODIC)
		return s.ny;
	return s.ny-1;			# v[0] and v[ny] are walls
}

maxstep(s: ref Sim): real
{
	(umax, vmax) := (0.0, 0.0);
	for(j := 1; j <= s.ny; j++)
		for(i := 1; i <= s.nx; i++){
			a := math->fabs(s.u[ix(s, i, j)]);
			if(a > umax)
				umax = a;
			a = math->fabs(s.v[ix(s, i, j)]);
			if(a > vmax)
				vmax = a;
		}
	huge := 1.0e30;
	adv := huge;
	if(umax > 0.0)
		adv = s.dx/umax;
	if(vmax > 0.0 && s.dy/vmax < adv)
		adv = s.dy/vmax;
	dif := huge;
	if(s.visc > 0.0)
		dif = 0.25/(s.visc*(1.0/(s.dx*s.dx) + 1.0/(s.dy*s.dy)));
	if(dif < adv)
		return dif;
	return adv;
}

Sim.courant(s: self ref Sim, dt: real): real
{
	m := maxstep(s);
	if(m >= 1.0e30)
		return 0.0;
	return dt/m;
}

Sim.divergence(s: self ref Sim): real
{
	worst := 0.0;
	for(j := 1; j <= s.ny; j++)
		for(i := 1; i <= s.nx; i++){
			d := (s.u[ix(s, i, j)] - s.u[ix(s, i-1, j)])/s.dx +
			     (s.v[ix(s, i, j)] - s.v[ix(s, i, j-1)])/s.dy;
			if(d < 0.0)
				d = -d;
			if(d > worst)
				worst = d;
		}
	return worst;
}

Sim.energy(s: self ref Sim): real
{
	e := 0.0;
	for(j := 1; j <= s.ny; j++)
		for(i := 1; i <= s.nx; i++){
			# the cell-centre velocity is the average of its two faces
			uc := 0.5*(s.u[ix(s, i, j)] + s.u[ix(s, i-1, j)]);
			vc := 0.5*(s.v[ix(s, i, j)] + s.v[ix(s, i, j-1)]);
			e += 0.5*(uc*uc + vc*vc);
		}
	return e*s.dx*s.dy/(s.lx*s.ly);
}

# Bilinear interpolation from the faces to an arbitrary point.  No
# single array holds both components at one place, so asking for the
# velocity somewhere means interpolating each from where it lives.
Sim.at(s: self ref Sim, x, y: real): (real, real)
{
	return (interp(s, s.u, x/s.dx, y/s.dy + 0.5),
		interp(s, s.v, x/s.dx + 0.5, y/s.dy));
}

Sim.pressureat(s: self ref Sim, x, y: real): real
{
	return interp(s, s.p, x/s.dx + 0.5, y/s.dy + 0.5);
}

# a and b are in units of cells, measured from the array's own origin
interp(s: ref Sim, f: array of real, a, b: real): real
{
	i := floorint(a);
	j := floorint(b);
	fa := a - real i;
	fb := b - real j;
	if(i < 0){ i = 0; fa = 0.0; }
	if(j < 0){ j = 0; fb = 0.0; }
	if(i > s.nx){ i = s.nx; fa = 0.0; }
	if(j > s.ny){ j = s.ny; fb = 0.0; }
	return (1.0-fa)*(1.0-fb)*f[ix(s, i, j)] +
	       fa*(1.0-fb)*f[ix(s, i+1, j)] +
	       (1.0-fa)*fb*f[ix(s, i, j+1)] +
	       fa*fb*f[ix(s, i+1, j+1)];
}

# Limbo's int rounds to nearest; this wants the floor, and the
# difference shows up as an interpolation reaching the wrong cell for
# every negative coordinate and for every second positive one.
floorint(x: real): int
{
	i := int x;
	if(real i > x)
		i--;
	return i;
}

step(s: ref Sim, dt: real): string
{
	if(krylov == nil)
		return "krylov is not loaded";
	if(dt <= 0.0)
		return "a step must be positive";
	m := maxstep(s);
	if(dt > 4.0*m)
		return sys->sprint("a step of %g is %.1f times the stable one (%g): the "+
			"explicit scheme would not survive it", dt, dt/m, m);
	ghosts(s);
	(nx, ny) := (s.nx, s.ny);
	i := 0;
	n := (nx+2)*(ny+2);
	us := array[n] of real;
	vs := array[n] of real;
	us[0:] = s.u;
	vs[0:] = s.v;

	# the momentum step, without the pressure: advection by a centred
	# difference and diffusion by the five-point Laplacian
	uh := uhi(s);
	vh := vhi(s);
	for(j := 1; j <= ny; j++)
		for(i = 1; i <= uh; i++){
			u0 := s.u[ix(s, i, j)];
			# d(uu)/dx at this face, from the two cell centres beside it
			ue := 0.5*(u0 + s.u[ix(s, i+1, j)]);
			uw := 0.5*(u0 + s.u[ix(s, i-1, j)]);
			duudx := (ue*ue - uw*uw)/s.dx;
			# d(uv)/dy, with v averaged onto the corners above and below
			vn := 0.5*(s.v[ix(s, i, j)] + s.v[ix(s, i+1, j)]);
			vsou := 0.5*(s.v[ix(s, i, j-1)] + s.v[ix(s, i+1, j-1)]);
			un := 0.5*(u0 + s.u[ix(s, i, j+1)]);
			usu := 0.5*(u0 + s.u[ix(s, i, j-1)]);
			duvdy := (vn*un - vsou*usu)/s.dy;
			lap := (s.u[ix(s, i+1, j)] - 2.0*u0 + s.u[ix(s, i-1, j)])/(s.dx*s.dx) +
			       (s.u[ix(s, i, j+1)] - 2.0*u0 + s.u[ix(s, i, j-1)])/(s.dy*s.dy);
			us[ix(s, i, j)] = u0 + dt*(-duudx - duvdy + s.visc*lap + s.fx);
		}
	for(j = 1; j <= vh; j++)
		for(i = 1; i <= nx; i++){
			v0 := s.v[ix(s, i, j)];
			vn := 0.5*(v0 + s.v[ix(s, i, j+1)]);
			vsou := 0.5*(v0 + s.v[ix(s, i, j-1)]);
			dvvdy := (vn*vn - vsou*vsou)/s.dy;
			ue := 0.5*(s.u[ix(s, i, j)] + s.u[ix(s, i, j+1)]);
			uw := 0.5*(s.u[ix(s, i-1, j)] + s.u[ix(s, i-1, j+1)]);
			ve := 0.5*(v0 + s.v[ix(s, i+1, j)]);
			vw := 0.5*(v0 + s.v[ix(s, i-1, j)]);
			duvdx := (ue*ve - uw*vw)/s.dx;
			lap := (s.v[ix(s, i+1, j)] - 2.0*v0 + s.v[ix(s, i-1, j)])/(s.dx*s.dx) +
			       (s.v[ix(s, i, j+1)] - 2.0*v0 + s.v[ix(s, i, j-1)])/(s.dy*s.dy);
			vs[ix(s, i, j)] = v0 + dt*(-dvvdy - duvdx + s.visc*lap + s.fy);
		}
	(s.u, s.v) = (us, vs);
	ghosts(s);

	# the projection: solve for the pressure that makes it divergence
	# free, then subtract its gradient
	rhs := array[nx*ny] of real;
	for(j = 1; j <= ny; j++)
		for(i = 1; i <= nx; i++){
			d := (s.u[ix(s, i, j)] - s.u[ix(s, i-1, j)])/s.dx +
			     (s.v[ix(s, i, j)] - s.v[ix(s, i, j-1)])/s.dy;
			# negated, because poisson() applies MINUS the
			# Laplacian so that the operator is positive definite
			rhs[(i-1) + nx*(j-1)] = -d/dt;
		}
	# With every edge closed or periodic the operator is singular -
	# adding a constant to the pressure changes nothing - so the
	# right-hand side must have no constant part either, or there is no
	# solution at all.  Removing its mean is what makes the problem
	# solvable in principle - but for all three edge conditions here
	# the sum of the divergences telescopes to the net flux through the
	# boundary, which is zero by construction (periodic wraps cancel,
	# walls carry nothing), so what is actually removed is rounding and
	# deleting this loop changes no answer in flowtest(1).  Measured,
	# not assumed.  It stays because it costs one pass and because the
	# next boundary condition added may not telescope.
	mean := 0.0;
	for(k := 0; k < nx*ny; k++)
		mean += rhs[k];
	mean /= real(nx*ny);
	for(k = 0; k < nx*ny; k++)
		rhs[k] -= mean;

	cur = s;
	sol := krylov->new();
	sol.cmd("method cg");
	sol.cmd("tolerance 1e-12");
	sol.cmd(sys->sprint("maxiter %d", 10*nx*ny));
	x0 := array[nx*ny] of real;
	for(k = 0; k < nx*ny; k++)
		x0[k] = 0.0;
	ph := sol.solve(poisson, rhs, x0);
	cur = nil;
	if(ph == nil)
		return "the pressure solve returned nothing";
	if(!sol.converged)
		return sys->sprint("the pressure did not converge: residual %g after "+
			"%d iterations", sol.residual, sol.iterations);
	pmean := 0.0;
	for(k = 0; k < nx*ny; k++)
		pmean += ph[k];
	pmean /= real(nx*ny);
	for(j = 1; j <= ny; j++)
		for(i = 1; i <= nx; i++)
			s.p[ix(s, i, j)] = ph[(i-1) + nx*(j-1)] - pmean;
	ghosts(s);
	for(j = 1; j <= ny; j++)
		for(i = 1; i <= uh; i++)
			s.u[ix(s, i, j)] -= dt*(s.p[ix(s, i+1, j)] - s.p[ix(s, i, j)])/s.dx;
	for(j = 1; j <= vh; j++)
		for(i = 1; i <= nx; i++)
			s.v[ix(s, i, j)] -= dt*(s.p[ix(s, i, j+1)] - s.p[ix(s, i, j)])/s.dy;
	ghosts(s);
	s.t += dt;
	return nil;
}

# The Laplacian on cell centres, as krylov(2) wants it: a function that
# applies the operator, with no matrix anywhere.  The sign is chosen so
# that the operator is positive definite, which conjugate gradients
# requires - the Laplacian itself is negative definite, so what is
# applied is minus it, and the right-hand side is negated to match.
poisson(x: array of real): array of real
{
	s := cur;
	(nx, ny) := (s.nx, s.ny);
	y := array[nx*ny] of real;
	(hx, hy) := (1.0/(s.dx*s.dx), 1.0/(s.dy*s.dy));
	for(j := 0; j < ny; j++)
		for(i := 0; i < nx; i++){
			c := x[i + nx*j];
			(e, w, n, so) := (c, c, c, c);
			# a wall is a zero normal derivative on the pressure,
			# which is the same as the neighbour being a copy - so
			# leaving it equal to the centre is exactly right
			if(i < nx-1)
				e = x[(i+1) + nx*j];
			else if(s.edges != CAVITY)
				e = x[0 + nx*j];
			if(i > 0)
				w = x[(i-1) + nx*j];
			else if(s.edges != CAVITY)
				w = x[(nx-1) + nx*j];
			if(j < ny-1)
				n = x[i + nx*(j+1)];
			else if(s.edges == PERIODIC)
				n = x[i + nx*0];
			if(j > 0)
				so = x[i + nx*(j-1)];
			else if(s.edges == PERIODIC)
				so = x[i + nx*(ny-1)];
			y[i + nx*j] = -((e - 2.0*c + w)*hx + (n - 2.0*c + so)*hy);
		}
	return y;
}
