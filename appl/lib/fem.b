implement Fem;

include "sys.m";
	sys: Sys;
include "string.m";
	str: String;
include "femesh.m";
	femesh: Femesh;
	Grid: import femesh;
include "sparse.m";
	sparse: Sparse;
	CSR: import sparse;
include "fem.m";

# Krylov is an implementation detail of "solver gmres"/"solver cg" here,
# same reasoning as pde(2): nothing outside this file ever sees a
# Krylov type, and there's no "solver explicit" to fall back to - an
# assembled sparse system always means a real linear solve.
include "krylov.m";
	krylov: Krylov;
	Solver: import krylov;
include "gpu.m";
	gpu: Gpu;
	Backend: import gpu;

init()
{
	if(sys == nil){
		sys = load Sys Sys->PATH;
		str = load String String->PATH;
		femesh = load Femesh Femesh->PATH;
		sparse = load Sparse Sparse->PATH;
		krylov = load Krylov Krylov->PATH;
		gpu = load Gpu Gpu->PATH;
	}
}

# --- element assembly: trilinear hex8 shape functions, 2x2x2 Gauss quadrature ---

Gp: con 0.5773502691896258;	# 1/sqrt(3), the 2-point Gauss quadrature abscissa

# Reference coords of the 8 local hex8 nodes, in femesh(2)'s own local
# order (bottom face ccw, then top face ccw directly above).
Rxi := array[] of {-1.0, 1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0};
Reta := array[] of {-1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, 1.0};
Rzeta := array[] of {-1.0, -1.0, -1.0, -1.0, 1.0, 1.0, 1.0, 1.0};

# The 8x8 local stiffness matrix for one axis-aligned dx x dy x dz hex8
# element with constant diffusivity D - the whole element (rather than
# per-degenerate-node) is why an FE assembly can't be a stencil closure
# the way pde(2)'s finite-difference lap() is: each entry mixes all 8
# nodes' shape-function gradients together at every quadrature point.
elemstiffness(dx, dy, dz, diffusivity: real): array of array of real
{
	detj := (dx/2.0)*(dy/2.0)*(dz/2.0);
	jx := 2.0/dx;
	jy := 2.0/dy;
	jz := 2.0/dz;

	k := array[8] of array of real;
	for(row := 0; row < 8; row++){
		k[row] = array[8] of real;
		# Explicit, not relying on implicit zero-init - see the note in
		# sparse(2)'s newfrompattern.
		for(col := 0; col < 8; col++)
			k[row][col] = 0.0;
	}

	gp := array[2] of real;
	gp[0] = -Gp;
	gp[1] = Gp;

	for(pi := 0; pi < 2; pi++)
		for(pj := 0; pj < 2; pj++)
			for(pk := 0; pk < 2; pk++){
				gx := gp[pi];
				gy := gp[pj];
				gz := gp[pk];
				dndx := array[8] of real;
				dndy := array[8] of real;
				dndz := array[8] of real;
				for(nd := 0; nd < 8; nd++){
					dndxi   := 0.125*Rxi[nd]  *(1.0+gy*Reta[nd]) *(1.0+gz*Rzeta[nd]);
					dndeta  := 0.125*Reta[nd] *(1.0+gx*Rxi[nd])  *(1.0+gz*Rzeta[nd]);
					dndzeta := 0.125*Rzeta[nd]*(1.0+gx*Rxi[nd])  *(1.0+gy*Reta[nd]);
					dndx[nd] = dndxi*jx;
					dndy[nd] = dndeta*jy;
					dndz[nd] = dndzeta*jz;
				}
				for(a := 0; a < 8; a++)
					for(b := 0; b < 8; b++)
						k[a][b] += diffusivity*detj*
							(dndx[a]*dndx[b]+dndy[a]*dndy[b]+dndz[a]*dndz[b]);
			}
	return k;
}

# The consistent element load vector: integral of N_i*src(x,y,z) over
# the element (ox,oy,oz its low corner), src evaluated at each real
# physical quadrature point via real 2x2x2 quadrature (not interpolated
# from nodal values or hand-simplified for a constant source) - so a
# non-constant src is exactly as correct as a constant one.
elemload(ox, oy, oz, dx, dy, dz: real, src: Src): array of real
{
	detj := (dx/2.0)*(dy/2.0)*(dz/2.0);
	r := array[8] of real;
	# Explicit, not relying on implicit zero-init - see the note in
	# sparse(2)'s newfrompattern.
	for(z0 := 0; z0 < 8; z0++)
		r[z0] = 0.0;
	gp := array[2] of real;
	gp[0] = -Gp;
	gp[1] = Gp;
	for(pi := 0; pi < 2; pi++)
		for(pj := 0; pj < 2; pj++)
			for(pk := 0; pk < 2; pk++){
				gx := gp[pi];
				gy := gp[pj];
				gz := gp[pk];
				px := ox + (gx+1.0)*0.5*dx;
				py := oy + (gy+1.0)*0.5*dy;
				pz := oz + (gz+1.0)*0.5*dz;
				sv := src(px, py, pz);
				for(nd := 0; nd < 8; nd++){
					n := 0.125*(1.0+gx*Rxi[nd])*(1.0+gy*Reta[nd])*(1.0+gz*Rzeta[nd]);
					r[nd] += n*sv*detj;
				}
			}
	return r;
}

assemble(g: ref Grid, diffusivity: real): ref CSR
{
	init();
	ne := femesh->nelem(g);
	elems := array[ne] of array of int;
	for(e := 0; e < ne; e++)
		elems[e] = femesh->elemnodes(g, e);
	m := sparse->newfrompattern(femesh->nnodes(g), elems);
	ke := elemstiffness(g.dx, g.dy, g.dz, diffusivity);
	for(e = 0; e < ne; e++){
		en := elems[e];
		for(a := 0; a < 8; a++)
			for(b := 0; b < 8; b++)
				sparse->add(m, en[a], en[b], ke[a][b]);
	}
	return m;
}

constq: real;

constsrc(nil: real, nil: real, nil: real): real
{
	return constq;
}

zeros(n: int): array of real
{
	z := array[n] of real;
	# Explicit, not relying on implicit zero-init - see the note in
	# sparse(2)'s newfrompattern.
	for(i := 0; i < n; i++)
		z[i] = 0.0;
	return z;
}

loadconst(g: ref Grid, q: real): array of real
{
	init();
	if(q == 0.0)
		return zeros(femesh->nnodes(g));
	constq = q;
	return loadfn(g, constsrc);
}

loadfn(g: ref Grid, src: Src): array of real
{
	init();
	b := zeros(femesh->nnodes(g));
	ne := femesh->nelem(g);
	for(e := 0; e < ne; e++){
		en := femesh->elemnodes(g, e);
		(ox, oy, oz) := femesh->nodecoord(g, en[0]);
		le := elemload(ox, oy, oz, g.dx, g.dy, g.dz, src);
		for(a := 0; a < 8; a++)
			b[en[a]] += le[a];
	}
	return b;
}

dirichlet(a: ref CSR, b: array of real, nodes: array of int, values: array of real)
{
	init();
	sparse->dirichlet(a, b, nodes, values);
}

# --- the declarative spec language ---

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
	grid: ref Grid;
	diffusivity := 0.0;
	loadq := 0.0;
	haddirichlet := 0;
	dirichletvalue := 0.0;
	solvermethod := "gmres";
	tolerance := 1.0e-8;
	restart := 30;
	maxiter := 200;
	backend := gpu->new();

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
			(gr, err) := femesh->parse(line);
			if(err != nil)
				return (nil, err);
			grid = gr;
		"material" =>
			if(len a != 3 || a[1] != "diffusivity")
				return (nil, "material: usage: material diffusivity D");
			diffusivity = real a[2];
			if(diffusivity <= 0.0)
				return (nil, "material: diffusivity must be positive");
		"load" =>
			if(len a != 2)
				return (nil, "load: usage: load Q");
			loadq = real a[1];
		"bc" =>
			if(len a != 3 || a[1] != "dirichlet")
				return (nil, "bc: usage: bc dirichlet V");
			haddirichlet = 1;
			dirichletvalue = real a[2];
		"solver" =>
			if(len a < 2)
				return (nil, "solver: usage: solver gmres|cg [tolerance T] [restart R] [maxiter N]");
			solvermethod = a[1];
			if(solvermethod != "gmres" && solvermethod != "cg")
				return (nil, "solver: method must be gmres or cg, got " + solvermethod);
			for(i := 2; i+1 < len a; i += 2)
				case a[i] {
				"tolerance" => tolerance = real a[i+1];
				"restart" => restart = int a[i+1];
				"maxiter" => maxiter = int a[i+1];
				* => return (nil, "solver: unknown option " + a[i]);
				}
		"backend" =>
			if(len a < 2)
				return (nil, "backend: usage: backend cpu|gpu [precision f32|f64] [resident on|off]");
			berr := backend.cmd("device " + a[1]);
			if(berr != nil)
				return (nil, "backend: " + berr);
			for(i := 2; i+1 < len a; i += 2){
				berr = backend.cmd(a[i] + " " + a[i+1]);
				if(berr != nil)
					return (nil, "backend: " + berr);
			}
		* =>
			return (nil, "unknown problem-spec line: " + a[0]);
		}
	}
	if(grid == nil)
		return (nil, "newproblem: spec has no mesh line");
	if(diffusivity <= 0.0)
		return (nil, "newproblem: spec has no material line");
	if(!haddirichlet)
		return (nil, "newproblem: spec has no bc line");

	a := assemble(grid, diffusivity);
	b := loadconst(grid, loadq);
	n := femesh->nnodes(grid);
	nb := 0;
	for(i := 0; i < n; i++)
		if(femesh->isboundary(grid, i))
			nb++;
	bnodes := array[nb] of int;
	bvalues := array[nb] of real;
	j := 0;
	for(i = 0; i < n; i++)
		if(femesh->isboundary(grid, i)){
			bnodes[j] = i;
			bvalues[j] = dirichletvalue;
			j++;
		}
	dirichlet(a, b, bnodes, bvalues);
	return (ref Problem(grid, a, b, solvermethod, tolerance, restart, maxiter, backend), nil);
}

# --- solve: krylov(2) against the assembled matrix's own matvec, via
# p.backend's apply() - cpu-backed today (device gpu falls back
# observably; see gpu(2)), gpu-backed transparently to this file and
# to krylov(2) itself once a real backend lands underneath the same
# interface. ---

solve(p: ref Problem): (array of real, int, real, string)
{
	init();
	b := p.backend;
	if(b == nil)
		b = gpu->new();
	apply := b.apply(p.a);
	solver := krylov->new();
	solver.cmd(sys->sprint("method %s\ntolerance %g\nrestart %d\nmaxiter %d",
		p.solvermethod, p.tolerance, p.restart, p.maxiter));
	x := solver.solve(apply, p.b, nil);
	if(!solver.converged)
		return (nil, solver.iterations, solver.residual,
			sys->sprint("solve: %s failed to converge (residual %g after %d iterations)",
				p.solvermethod, solver.residual, solver.iterations));
	return (x, solver.iterations, solver.residual, nil);
}
