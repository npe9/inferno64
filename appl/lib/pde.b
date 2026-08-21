implement Pde;

include "sys.m";
	sys: Sys;

include "math.m";
	math: Math;

include "string.m";
	str: String;

include "pde.m";

# mesh(2) is the "mesh ..." line's own little language, shared
# infrastructure any future problem class reuses unchanged - not part of
# pde.m's own interface either, same reasoning as Krylov below.
include "mesh.m";
	mesh: Mesh;

# Krylov is an implementation detail of "solver gmres"/"solver cg" in
# newproblem()/step() - deliberately not part of pde.m's own interface,
# so nothing outside this file ever sees a Krylov type.
include "krylov.m";
	krylov: Krylov;
	Solver: import krylov;

init()
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(math == nil)
		math = load Math Math->PATH;
	if(str == nil)
		str = load String String->PATH;
	if(mesh == nil)
		mesh = load Mesh Mesh->PATH;
	if(krylov == nil)
		krylov = load Krylov Krylov->PATH;
}

new(nx, ny: int, dx, dy: real, bc: int): ref Field
{
	init();
	if(nx < 2) nx = 2;
	if(ny < 2) ny = 2;
	if(dx <= 0.0) dx = 1.0;
	if(dy <= 0.0) dy = 1.0;
	n := nx*ny;
	return ref Field(nx, ny, dx, dy, bc,
		array[n] of { * => 0.0 }, array[n] of { * => 0.0 }, array[n] of { * => 0.0 });
}

clear(f: ref Field, value: real)
{
	for(i := 0; i < len f.u; i++){
		f.u[i] = value;
		f.work[i] = value;
		f.old[i] = value;
	}
}

get(f: ref Field, x, y: int): real
{
	if(f.bc == PERIODIC){
		x = (x%f.nx + f.nx)%f.nx;
		y = (y%f.ny + f.ny)%f.ny;
	}else if(x < 0 || x >= f.nx || y < 0 || y >= f.ny){
		if(f.bc == ZERO)
			return 0.0;
		if(x < 0) x = 0;
		if(x >= f.nx) x = f.nx-1;
		if(y < 0) y = 0;
		if(y >= f.ny) y = f.ny-1;
	}
	return f.u[y*f.nx+x];
}

set(f: ref Field, x, y: int, value: real)
{
	if(x >= 0 && x < f.nx && y >= 0 && y < f.ny)
		f.u[y*f.nx+x] = value;
}

splat(f: ref Field, cx, cy, radius: int, value: real)
{
	for(y := cy-radius; y <= cy+radius; y++)
		for(x := cx-radius; x <= cx+radius; x++){
			dx := x-cx; dy := y-cy;
			if(dx*dx+dy*dy <= radius*radius)
				set(f, x, y, value);
		}
}

splatold(f: ref Field, cx, cy, radius: int, value: real)
{
	for(y := cy-radius; y <= cy+radius; y++)
		for(x := cx-radius; x <= cx+radius; x++){
			dx := x-cx; dy := y-cy;
			if(x >= 0 && x < f.nx && y >= 0 && y < f.ny && dx*dx+dy*dy <= radius*radius)
				f.old[y*f.nx+x] = value;
		}
}

lap(f: ref Field, x, y: int): real
{
	c := get(f, x, y);
	return (get(f,x-1,y)-2.0*c+get(f,x+1,y))/(f.dx*f.dx)
		+ (get(f,x,y-1)-2.0*c+get(f,x,y+1))/(f.dy*f.dy);
}

swap(f: ref Field)
{
	t := f.u; f.u = f.work; f.work = t;
}

# --- implicit (backward Euler) diffusion, matrix-free via krylov(2) ---

# The current problem, threaded into diffuseop() below through
# module-level state: Krylov->Apply is a bare function reference, not a
# closure (Limbo has no closure literals), so this is how context reaches
# it - the same reason lorenz.b's own rhs() reads a module-level model
# instead of capturing one. Not reentrant across concurrent solves within
# one process; every caller in this tree runs one physics update at a
# time, so that's not a real constraint here.
opfield: ref Field;
opdt, opdiffusivity: real;
opq: real;	# waveop's speed^2*dt^2 coefficient

# Same boundary-aware 5-point stencil as lap(), but reading an arbitrary
# vector laid out like f.u instead of f.u itself - what lets diffuseop()
# apply the operator to a Krylov basis vector rather than only ever to
# the field's own current state.
getvec(f: ref Field, x: array of real, ix, iy: int): real
{
	if(f.bc == PERIODIC){
		ix = (ix%f.nx + f.nx)%f.nx;
		iy = (iy%f.ny + f.ny)%f.ny;
	}else if(ix < 0 || ix >= f.nx || iy < 0 || iy >= f.ny){
		if(f.bc == ZERO)
			return 0.0;
		if(ix < 0) ix = 0;
		if(ix >= f.nx) ix = f.nx-1;
		if(iy < 0) iy = 0;
		if(iy >= f.ny) iy = f.ny-1;
	}
	return x[iy*f.nx+ix];
}

lapvec(f: ref Field, x: array of real, ix, iy: int): real
{
	c := getvec(f, x, ix, iy);
	return (getvec(f,x,ix-1,iy)-2.0*c+getvec(f,x,ix+1,iy))/(f.dx*f.dx)
		+ (getvec(f,x,ix,iy-1)-2.0*c+getvec(f,x,ix,iy+1))/(f.dy*f.dy);
}

# (I - dt*diffusivity*L)x, the backward-Euler system operator: exactly
# what a solver needs, no matrix ever assembled.
diffuseop(x: array of real): array of real
{
	f := opfield;
	y := array[len x] of real;
	for(iy := 0; iy < f.ny; iy++)
		for(ix := 0; ix < f.nx; ix++){
			i := iy*f.nx+ix;
			y[i] = x[i] - opdt*opdiffusivity*lapvec(f,x,ix,iy);
		}
	return y;
}

# Runs the backward-Euler implicit diffusion solve for one step, using
# whichever Krylov method p's spec named. Purely internal - newproblem()/
# step() are the only exported entry points that ever touch a Solver.
solvediffuse(p: ref Problem, dt: real): string
{
	f := p.field;
	if(p.diffusivity <= 0.0 || dt <= 0.0)
		return nil;
	opfield = f;
	opdt = dt;
	opdiffusivity = p.diffusivity;
	solver := krylov->new();
	solver.cmd(sys->sprint("method %s\ntolerance %g\nrestart %d\nmaxiter %d",
		p.solvermethod, p.tolerance, p.restart, p.maxiter));
	x := solver.solve(diffuseop, f.u, f.u);
	if(!solver.converged)
		return sys->sprint("step: %s failed to converge (residual %g after %d iterations)",
			p.solvermethod, solver.residual, solver.iterations);
	f.u[0:] = x;
	return nil;
}

# --- implicit wave, matrix-free via krylov(2) ---

# diffuse()'s implicit reformulation moves diffusion's own explicit
# term (h*d*lap(...)) to the new time level. This does exactly the same
# thing to wave()'s own explicit central-difference-in-time update
#   u_new = (2-damping*h)*u - (1-damping*h)*old + speed^2*h^2*lap(u)
# (see wave() above; h is the actual step, damping*h/speed^2*h^2
# written as d/q there) - only the lap(u) term moves to lap(u_new):
#   u_new - q*lap(u_new) = (2-d)*u - (1-d)*old
# a single linear solve for u_new alone, q=speed^2*dt^2, d=damping*dt.
# This is the point of doing it this way rather than the more obvious
# (u, du/dt) first-order-system reformulation: it keeps old's meaning
# exactly what explicit wave() and splatold() already document ("the
# previous time level"), not a second, incompatible convention a caller
# would have to know about depending on which solver is active. It is
# also symmetric positive definite for clamp/periodic boundaries (I
# minus a positive multiple of the same negative-semidefinite Laplacian
# diffusion's own implicit solve uses) - so unlike the (u,v) shape this
# replaced, "solver cg" is valid here too, not just gmres.
waveop(x: array of real): array of real
{
	f := opfield;
	y := array[len x] of real;
	for(iy := 0; iy < f.ny; iy++)
		for(ix := 0; ix < f.nx; ix++){
			i := iy*f.nx+ix;
			y[i] = x[i] - opq*lapvec(f,x,ix,iy);
		}
	return y;
}

solvewave(p: ref Problem, dt: real): string
{
	f := p.field;
	if(p.speed <= 0.0 || dt <= 0.0)
		return nil;
	d := p.damping*dt;
	q := p.speed*p.speed*dt*dt;
	rhs := array[len f.u] of real;
	for(i := 0; i < len rhs; i++)
		rhs[i] = (2.0-d)*f.u[i] - (1.0-d)*f.old[i];
	opfield = f;
	opq = q;
	solver := krylov->new();
	solver.cmd(sys->sprint("method %s\ntolerance %g\nrestart %d\nmaxiter %d",
		p.solvermethod, p.tolerance, p.restart, p.maxiter));
	x := solver.solve(waveop, rhs, f.u);
	if(!solver.converged)
		return sys->sprint("step: %s failed to converge (residual %g after %d iterations)",
			p.solvermethod, solver.residual, solver.iterations);
	f.old[0:] = f.u;
	f.u[0:] = x;
	return nil;
}

# --- the problem-specification "little language" ---

specwords(s: string): array of string
{
	l := str->fields(s);
	a := array[len l] of string;
	for(i := 0; l != nil; (i,l) = (i+1,tl l))
		a[i] = hd l;
	return a;
}

newproblem(spec: string): (ref Problem, string)
{
	init();
	grid: ref Mesh->Grid;
	equation := "";
	diffusivity := 0.0;
	speed := 0.0; damping := 0.0;
	da := 0.0; db := 0.0; feed := 0.0; kill := 0.0;
	solvermethod := "explicit";
	tolerance := 1.0e-8;
	restart := 30;
	maxiter := 200;
	defaultstep := 0.0;

	for(rest := spec; rest != nil;){
		(line, tail) := str->splitl(rest, "\n");
		if(tail != nil)
			tail = tail[1:];
		rest = tail;
		a := specwords(line);
		if(len a == 0)
			continue;
		case a[0] {
		"mesh" =>
			(g, err) := mesh->parse(line);
			if(err != nil)
				return (nil, err);
			grid = g;
		"equation" =>
			if(len a < 2)
				return (nil, "equation: usage: equation diffuse|wave <params...>");
			equation = a[1];
			case equation {
			"diffuse" =>
				for(i := 2; i+1 < len a; i += 2)
					if(a[i] == "diffusivity")
						diffusivity = real a[i+1];
					else
						return (nil, "equation diffuse: unknown option " + a[i]);
				if(diffusivity <= 0.0)
					return (nil, "equation diffuse: diffusivity must be given and positive");
			"wave" =>
				for(i := 2; i+1 < len a; i += 2)
					case a[i] {
					"speed" => speed = real a[i+1];
					"damping" => damping = real a[i+1];
					* => return (nil, "equation wave: unknown option " + a[i]);
					}
				if(speed <= 0.0)
					return (nil, "equation wave: speed must be given and positive");
			"gray" =>
				for(i := 2; i+1 < len a; i += 2)
					case a[i] {
					"da" => da = real a[i+1];
					"db" => db = real a[i+1];
					"feed" => feed = real a[i+1];
					"kill" => kill = real a[i+1];
					* => return (nil, "equation gray: unknown option " + a[i]);
					}
				if(da <= 0.0 || db <= 0.0)
					return (nil, "equation gray: da and db must be given and positive");
			* =>
				return (nil, "equation: unknown equation " + equation);
			}
		"solver" =>
			if(len a < 2)
				return (nil, "solver: usage: solver explicit|gmres|cg [tolerance T] [restart R] [maxiter N]");
			solvermethod = a[1];
			if(solvermethod != "explicit" && solvermethod != "gmres" && solvermethod != "cg")
				return (nil, "solver: method must be explicit, gmres, or cg, got " + solvermethod);
			for(i := 2; i+1 < len a; i += 2)
				case a[i] {
				"tolerance" => tolerance = real a[i+1];
				"restart" => restart = int a[i+1];
				"maxiter" => maxiter = int a[i+1];
				* => return (nil, "solver: unknown option " + a[i]);
				}
		"time" =>
			if(len a != 3 || a[1] != "step")
				return (nil, "time: usage: time step DT");
			defaultstep = real a[2];
			if(defaultstep <= 0.0)
				return (nil, "time: step must be positive");
		* =>
			return (nil, "unknown problem-spec line: " + a[0]);
		}
	}
	if(grid == nil)
		return (nil, "newproblem: spec has no mesh line");
	if(equation == "")
		return (nil, "newproblem: spec has no equation line");
	if(equation == "gray" && solvermethod != "explicit")
		return (nil, "equation gray: only solver explicit is valid - the reaction term is nonlinear");
	f := new(grid.nx, grid.ny, grid.dx, grid.dy, grid.bc);
	fb: ref Field;
	if(equation == "gray")
		fb = new(grid.nx, grid.ny, grid.dx, grid.dy, grid.bc);
	return (ref Problem(f, fb, equation, solvermethod, diffusivity, speed, damping,
		da, db, feed, kill, tolerance, restart, maxiter, defaultstep), nil);
}

# Batch/unattended driver: repeatedly step() by p's own "time step DT"
# until at least `until` total time has elapsed. For verification and UQ
# studies, which run a problem to completion without a redraw loop
# driving individual step() calls by wall-clock elapsed time the way an
# interactive caller (e.g. pdelab.b) does.
run(p: ref Problem, until: real): (int, string)
{
	if(p.defaultstep <= 0.0)
		return (0, "run: spec has no time step line");
	n := 0;
	elapsed := 0.0;
	for(; elapsed < until; elapsed += p.defaultstep){
		h := p.defaultstep;
		if(elapsed+h > until)
			h = until-elapsed;
		err := step(p, h);
		if(err != nil)
			return (n, err);
		n++;
	}
	return (n, nil);
}

step(p: ref Problem, dt: real): string
{
	case p.equation {
	"diffuse" =>
		if(p.solvermethod == "explicit"){
			diffuse(p.field, p.diffusivity, dt);
			return nil;
		}
		return solvediffuse(p, dt);
	"wave" =>
		if(p.solvermethod == "explicit"){
			wave(p.field, p.speed, p.damping, dt);
			return nil;
		}
		return solvewave(p, dt);
	"gray" =>
		gray(p.field, p.fieldb, p.da, p.db, p.feed, p.kill, dt);
		return nil;
	}
	return "step: unknown equation " + p.equation;
}

diffuse(f: ref Field, d, dt: real)
{
	if(d <= 0.0 || dt <= 0.0) return;
	h2 := f.dx*f.dx;
	if(f.dy*f.dy < h2) h2 = f.dy*f.dy;
	maxdt := 0.24*h2/d;
	ns := int (dt/maxdt)+1;
	h := dt/real(ns);
	for(s := 0; s < ns; s++){
		for(y := 0; y < f.ny; y++)
			for(x := 0; x < f.nx; x++)
				f.work[y*f.nx+x] = get(f,x,y)+h*d*lap(f,x,y);
		swap(f);
	}
}

wave(f: ref Field, speed, damping, dt: real)
{
	if(speed <= 0.0 || dt <= 0.0) return;
	hmin := f.dx;
	if(f.dy < hmin) hmin = f.dy;
	maxdt := 0.65*hmin/speed;
	ns := int (dt/maxdt)+1;
	h := dt/real(ns);
	for(s := 0; s < ns; s++){
		q := speed*speed*h*h;
		d := damping*h;
		for(y := 0; y < f.ny; y++)
			for(x := 0; x < f.nx; x++){
				i := y*f.nx+x;
				f.work[i] = (2.0-d)*f.u[i]-(1.0-d)*f.old[i]+q*lap(f,x,y);
			}
		t := f.old; f.old = f.u; f.u = f.work; f.work = t;
	}
}

gray(a, b: ref Field, da, db, feed, kill, dt: real)
{
	if(a.nx != b.nx || a.ny != b.ny || dt <= 0.0) return;
	h2 := a.dx*a.dx;
	if(a.dy*a.dy < h2) h2 = a.dy*a.dy;
	dmax := da; if(db > dmax) dmax = db;
	maxdt := dt;
	if(dmax > 0.0)
		maxdt = 0.20*h2/dmax;
	ns := int (dt/maxdt)+1;
	h := dt/real(ns);
	for(s := 0; s < ns; s++){
		for(y := 0; y < a.ny; y++)
			for(x := 0; x < a.nx; x++){
				i := y*a.nx+x;
				av := a.u[i]; bv := b.u[i]; ab2 := av*bv*bv;
				a.work[i] = av+h*(da*lap(a,x,y)-ab2+feed*(1.0-av));
				b.work[i] = bv+h*(db*lap(b,x,y)+ab2-(feed+kill)*bv);
				if(a.work[i] < 0.0) a.work[i] = 0.0;
				if(a.work[i] > 1.0) a.work[i] = 1.0;
				if(b.work[i] < 0.0) b.work[i] = 0.0;
				if(b.work[i] > 1.0) b.work[i] = 1.0;
			}
		swap(a); swap(b);
	}
}
