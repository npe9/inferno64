implement Pde;

include "sys.m";
	sys: Sys;

include "math.m";
	math: Math;

include "string.m";
	str: String;

# pde.m itself requires "draw.m" already included first - see its own
# header comment (hoc.m's init()/run() entries need Draw->Context, and
# Limbo has no include-guard to let pde.m safely include it itself).
# This file never uses Draw directly; this include exists purely to
# satisfy that requirement.
include "draw.m";

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

# hoc(2)'s Hoc type is already visible here - pde.m itself now includes
# hoc.m (Problem.hocmod/hocra/hocrb) - so there's no separate include for
# it in this file, unlike mesh/krylov above. "equation hoc" lets a
# caller write the PDE itself as hoc(2) expression strings instead of
# one of the three fixed Limbo functions above; see pde.m's own grammar
# comment. Deliberately no module-level loaded instance: every hoc-
# driven Problem gets its OWN, loaded fresh in newproblem() below - a
# compiled Expr's Sym handles are tied to whichever instance compiled
# them, so two such Problems sharing one symbol table would silently
# overwrite each other's variables.

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
#
# This runs once per Krylov iteration and was 78 to 82 per cent of a solve as a
# Limbo loop, so it goes through math(2): lap5 for the stencil, then axpby to
# combine, which is y = 1*x + (-c)*lap. Two C calls and no loop here at all.
# The Limbo version is kept below as the fallback and as the statement of what
# the operator is - pdetest(1) checks the two against each other.
# lap5 needs somewhere to put the Laplacian that is not the array it is
# reading. The explicit steppers below all want it for a whole grid at once, so
# one buffer is kept and grown rather than allocated per substep.
lapbuf: array of real;
lapbufb: array of real;		# gray needs both fields' Laplacians at once

lapinto(f: ref Field): array of real
{
	if(math == nil)
		return nil;
	if(lapbuf == nil || len lapbuf < f.nx*f.ny)
		lapbuf = array[f.nx*f.ny] of real;
	math->lap5(f.nx, f.ny, f.dx, f.dy, f.bc, f.u, lapbuf);
	return lapbuf;
}

lapintob(f: ref Field): array of real
{
	if(math == nil)
		return nil;
	if(lapbufb == nil || len lapbufb < f.nx*f.ny)
		lapbufb = array[f.nx*f.ny] of real;
	math->lap5(f.nx, f.ny, f.dx, f.dy, f.bc, f.u, lapbufb);
	return lapbufb;
}

applyop(x: array of real, c: real): array of real
{
	f := opfield;
	y := array[len x] of real;
	if(math != nil){
		math->lap5(f.nx, f.ny, f.dx, f.dy, f.bc, x, y);
		math->axpby(1.0, x, -c, y);
		return y;
	}
	for(iy := 0; iy < f.ny; iy++)
		for(ix := 0; ix < f.nx; ix++){
			i := iy*f.nx+ix;
			y[i] = x[i] - c*lapvec(f,x,ix,iy);
		}
	return y;
}

diffuseop(x: array of real): array of real
{
	return applyop(x, opdt*opdiffusivity);
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
	return applyop(x, opq);
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

# joinwords: the inverse of specwords(), from some starting index -
# used only for "rhs" lines. hoc(2)'s own grammar is whitespace-
# insensitive between tokens (like any ordinary expression language),
# so re-joining the already-tokenized words with single spaces gives
# hoc an equivalent source string to whatever the user actually wrote,
# without needing a separate non-word-splitting parse path just for
# this one line kind.
joinwords(a: array of string, from: int): string
{
	s := "";
	for(i := from; i < len a; i++){
		if(i > from)
			s += " ";
		s += a[i];
	}
	return s;
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

	# "equation hoc" - see pde.m's own grammar comment. Collected across
	# possibly-interleaved "equation hoc"/"substeps"/"param"/"rhs" lines,
	# compiled once at the very end once the whole spec has been read.
	hocname := ""; hocnameb := "";
	hocsubsteps := 0;
	hocparams: list of (string, real);
	hocrhssrc := ""; hocrhsbsrc := "";

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
			"hoc" =>
				if(len a < 3 || len a > 4)
					return (nil, "equation hoc: usage: equation hoc NAME [NAMEB]");
				hocname = a[2];
				if(len a == 4)
					hocnameb = a[3];
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
		"substeps" =>
			if(len a != 2)
				return (nil, "substeps: usage: substeps N");
			hocsubsteps = int a[1];
			if(hocsubsteps <= 0)
				return (nil, "substeps: must be positive");
		"param" =>
			if(len a != 3)
				return (nil, "param: usage: param NAME VALUE");
			hocparams = (a[1], real a[2]) :: hocparams;
		"rhs" =>
			if(len a < 3)
				return (nil, "rhs: usage: rhs NAME hoc-expression...");
			expr := joinwords(a, 2);
			if(a[1] == hocname)
				hocrhssrc = expr;
			else if(a[1] == hocnameb && hocnameb != "")
				hocrhsbsrc = expr;
			else
				return (nil, "rhs: " + a[1] + " does not match equation hoc's own field name(s)");
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
	if(equation == "hoc" && solvermethod != "explicit")
		return (nil, "equation hoc: only solver explicit is valid - the update rule is arbitrary, not necessarily linear");
	f := new(grid.nx, grid.ny, grid.dx, grid.dy, grid.bc);
	fb: ref Field;
	if(equation == "gray" || (equation == "hoc" && hocnameb != ""))
		fb = new(grid.nx, grid.ny, grid.dx, grid.dy, grid.bc);

	hocmod: Hoc;
	hocra, hocrb: ref Hoc->Expr;
	if(equation == "hoc"){
		if(hocsubsteps <= 0)
			return (nil, "equation hoc: spec has no substeps line");
		if(hocrhssrc == "")
			return (nil, "equation hoc: spec has no \"rhs " + hocname + " ...\" line");
		if(hocnameb != "" && hocrhsbsrc == "")
			return (nil, "equation hoc: spec has no \"rhs " + hocnameb + " ...\" line");
		hocmod = load Hoc Hoc->PATH;
		if(hocmod == nil)
			return (nil, "equation hoc: cannot load " + Hoc->PATH);
		hocmod->reset();
		for(pl := hocparams; pl != nil; pl = tl pl){
			(pname, pval) := hd pl;
			hocmod->setvar(pname, pval);
		}
		hocra = hocmod->compile(hocrhssrc);
		if(hocra == nil)
			return (nil, "equation hoc: could not parse rhs " + hocname + " " + hocrhssrc);
		if(hocnameb != ""){
			hocrb = hocmod->compile(hocrhsbsrc);
			if(hocrb == nil)
				return (nil, "equation hoc: could not parse rhs " + hocnameb + " " + hocrhsbsrc);
		}
	}
	return (ref Problem(f, fb, equation, solvermethod, diffusivity, speed, damping,
		da, db, feed, kill, tolerance, restart, maxiter, defaultstep,
		hocmod, hocname, hocnameb, hocra, hocrb, hocsubsteps), nil);
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
	"hoc" =>
		hocstep(p, dt);
		return nil;
	}
	return "step: unknown equation " + p.equation;
}

# hocstep: gray()'s own shape (subdivide dt into p.hocsubsteps equal
# substeps, gather each field's whole-grid Laplacian the fast way once
# per substep, update every cell, swap) with the per-cell update itself
# coming from the user's own compiled hoc(2) expression(s) instead of a
# fixed formula - walked with evalarray() (once per substep, over the
# whole grid) rather than eval() (once per cell), for the reason
# doc/danby-tks-plan.md's own measurement gives. No stability heuristic
# here unlike diffuse/wave/gray - p.hocsubsteps is exactly what
# newproblem() parsed from the spec's own "substeps N" line, since
# there is no general way to derive one for an arbitrary user rhs.
hocstep(p: ref Problem, dt: real)
{
	h := dt/real(p.hocsubsteps);
	hs := p.hocmod->symbol("h");
	hs.val = h;
	fs := p.hocmod->symbol(p.hocname);
	ls := p.hocmod->symbol("lap_"+p.hocname);
	fbs: ref Hoc->Sym; lbs: ref Hoc->Sym;
	if(p.fieldb != nil){
		fbs = p.hocmod->symbol(p.hocnameb);
		lbs = p.hocmod->symbol("lap_"+p.hocnameb);
	}
	n := p.field.nx*p.field.ny;
	for(s := 0; s < p.hocsubsteps; s++){
		la := lapinto(p.field);
		if(la == nil)
			la = lapfallback(p.field);
		lb: array of real;
		fs.vals = p.field.u;
		ls.vals = la;
		if(p.fieldb != nil){
			lb = lapintob(p.fieldb);
			if(lb == nil)
				lb = lapfallback(p.fieldb);
			fbs.vals = p.fieldb.u;
			lbs.vals = lb;
		}
		newa := p.hocmod->evalarray(p.hocra, n);
		for(i := 0; i < n; i++)
			p.field.work[i] = newa[i];
		if(p.fieldb != nil){
			newb := p.hocmod->evalarray(p.hocrb, n);
			for(j := 0; j < n; j++)
				p.fieldb.work[j] = newb[j];
		}
		swap(p.field);
		if(p.fieldb != nil)
			swap(p.fieldb);
	}
}

# lapfallback: lapinto()/lapintob() are only nil when math(2) has no
# lap5/lap7 builtin on this build - the same fallback diffuse()/wave()/
# gray() already reach for via their own inline lap(f,x,y) loop, factored
# out here so hocstep() doesn't need a fourth copy of it.
lapfallback(f: ref Field): array of real
{
	r := array[f.nx*f.ny] of real;
	for(y := 0; y < f.ny; y++)
		for(x := 0; x < f.nx; x++)
			r[y*f.nx+x] = lap(f, x, y);
	return r;
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
		# u + h*d*lap(u), which is axpby's shape once the Laplacian
		# exists: work = lap, then work = 1*u + (h*d)*work.
		l := lapinto(f);
		if(l != nil){
			f.work[0:] = l[0:f.nx*f.ny];
			math->axpby(1.0, f.u, h*d, f.work);
		}else
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
		l := lapinto(f);
		if(l != nil){
			# work = q*lap + (2-d)*u - (1-d)*old, in three steps
			# that are each a single pass.
			f.work[0:] = l[0:f.nx*f.ny];
			math->axpby(2.0-d, f.u, q, f.work);
			math->axpby(-(1.0-d), f.old, 1.0, f.work);
		}else
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
		# The reaction term is nonlinear and per-cell, so this loop
		# stays in Limbo - but the five-point gather that dominates it
		# does not have to. Both Laplacians are computed for the whole
		# grid first and read back here.
		la := lapinto(a);
		lb := lapintob(b);
		for(y := 0; y < a.ny; y++)
			for(x := 0; x < a.nx; x++){
				i := y*a.nx+x;
				av := a.u[i]; bv := b.u[i]; ab2 := av*bv*bv;
				lav, lbv: real;
				if(la != nil){
					lav = la[i];
					lbv = lb[i];
				}else{
					lav = lap(a,x,y);
					lbv = lap(b,x,y);
				}
				a.work[i] = av+h*(da*lav-ab2+feed*(1.0-av));
				b.work[i] = bv+h*(db*lbv+ab2-(feed+kill)*bv);
				if(a.work[i] < 0.0) a.work[i] = 0.0;
				if(a.work[i] > 1.0) a.work[i] = 1.0;
				if(b.work[i] < 0.0) b.work[i] = 0.0;
				if(b.work[i] > 1.0) b.work[i] = 1.0;
			}
		swap(a); swap(b);
	}
}
