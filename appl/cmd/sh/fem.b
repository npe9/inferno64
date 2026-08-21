implement Shellbuiltin;

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
	sh: Sh;
	Listnode, Context: import sh;
	myself: Shellbuiltin;
include "femesh.m";
	femesh: Femesh;
include "sparse.m";
include "krylov.m";
include "gpu.m";
include "fem.m";
	fem: Fem;
	Problem: import fem;

# A handle is either a spec still being built (problem == nil, lines
# accumulating in spec) or a committed, solved-or-solvable problem
# (problem != nil) - the same incremental "fem $id mesh ...; fem $id
# material ...; fem $id commit" build-up sh-pde.b already gives
# pde(2), laid on top of fem(2)'s own single-string newproblem(),
# which never changes: this file owns the incremental UX only.
Handle: adt {
	id:		int;
	spec:		string;
	problem:	ref Problem;
	solution:	array of real;	# set by "solve"; nil until then
	iters:		int;
	resid:		real;
};

handles: array of list of ref Handle;
nexthandle := 0;

initbuiltin(ctxt: ref Context, shmod: Sh): string
{
	sys = load Sys Sys->PATH;
	sh = shmod;
	myself = load Shellbuiltin "$self";
	if (myself == nil)
		ctxt.fail("bad module", sys->sprint("fem: cannot load self: %r"));
	fem = load Fem Fem->PATH;
	if (fem == nil)
		ctxt.fail("bad module",
			sys->sprint("fem: cannot load %s: %r", Fem->PATH));
	fem->init();
	femesh = load Femesh Femesh->PATH;
	handles = array[16] of list of ref Handle;
	ctxt.addbuiltin("fem", myself);
	ctxt.addsbuiltin("fem", myself);
	return nil;
}

whatis(nil: ref Sh->Context, nil: Sh, nil: string, nil: int): string
{
	return nil;
}

getself(): Shellbuiltin
{
	return myself;
}

# usage:
#   id := ${fem new}
#   fem $id mesh 20x20x20 domain 1x1x1
#   fem $id material diffusivity 1.0
#   fem $id load 1.0
#   fem $id bc dirichlet 0.0
#   fem $id solver cg tolerance 1e-8
#   fem $id backend gpu precision f32
#   fem $id commit
#   fem $id solve
#   echo ${fem $id get 0}
#   fem del $id
# Each mesh/material/load/bc/solver/backend call appends one line of
# fem(2)'s own spec language, exactly as documented there - this file
# adds no vocabulary of its own beyond the handle/commit/solve
# bookkeeping.
runbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode, nil: int): string
{
	if (tl argv == nil)
		ctxt.fail("usage", "usage: fem (new|del|<id> ...) args...");
	argv = tl argv;
	w := (hd argv).word;
	case w {
	"new" =>
		h := ref Handle(nexthandle++, nil, nil, nil, 0, 0.0);
		addhandle(h);
		remark(ctxt, string h.id);
		return nil;
	"del" =>
		for (argv = tl argv; argv != nil; argv = tl argv)
			delhandle(int (hd argv).word);
		return nil;
	}
	if (!isnum(w))
		ctxt.fail("usage", "usage: fem (new|del|<id> ...) args...");
	h := ehandle(ctxt, w);
	rest := tl argv;
	if (rest == nil)
		ctxt.fail("usage", "usage: fem <id> (mesh|material|load|bc|solver|backend|commit|solve) args...");
	verb := (hd rest).word;
	case verb {
	"mesh" or "material" or "load" or "bc" or "solver" or "backend" =>
		if (h.problem != nil)
			ctxt.fail("fem", "fem: handle already committed");
		line := verb + " " + concat(tl rest);
		if (h.spec == nil)
			h.spec = line;
		else
			h.spec += "\n" + line;
	"commit" =>
		if (h.problem != nil)
			return nil;
		(p, err) := fem->newproblem(h.spec);
		if (err != nil)
			ctxt.fail("fem", "fem: " + err);
		h.problem = p;
	"solve" =>
		p := ecommitted(ctxt, h);
		(x, iters, resid, err) := fem->solve(p);
		if (err != nil)
			ctxt.fail("fem", "fem: " + err);
		h.solution = x;
		h.iters = iters;
		h.resid = resid;
	* =>
		ctxt.fail("usage", "fem: unknown command " + verb);
	}
	return nil;
}

# usage: fem <id> (get|getijk|nnodes|iters|resid|lasterror) args...
runsbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode): list of ref Listnode
{
	if ((hd argv).word != "fem")
		return nil;
	argv = tl argv;
	if (argv == nil)
		ctxt.fail("usage", "usage: fem new");
	w := (hd argv).word;
	if (w == "new") {
		h := ref Handle(nexthandle++, nil, nil, nil, 0, 0.0);
		addhandle(h);
		return ref Listnode(nil, string h.id) :: nil;
	}
	if (!isnum(w))
		ctxt.fail("usage", "usage: fem new | fem <id> args...");
	h := ehandle(ctxt, w);
	rest := tl argv;
	if (rest == nil)
		ctxt.fail("usage", "usage: fem <id> (get|getijk|nnodes|iters|resid|lasterror) args...");
	case (hd rest).word {
	"get" =>
		x := esolved(ctxt, h);
		a := tl rest;
		if (len a != 1)
			ctxt.fail("usage", "usage: fem <id> get n");
		n := int (hd a).word;
		if (n < 0 || n >= len x)
			ctxt.fail("fem", "fem: node out of range");
		return ref Listnode(nil, sys->sprint("%g", x[n])) :: nil;
	"getijk" =>
		x := esolved(ctxt, h);
		a := tl rest;
		if (len a != 3)
			ctxt.fail("usage", "usage: fem <id> getijk i j k");
		n := femesh->nodeid(h.problem.grid, int (hd a).word,
			int (hd tl a).word, int (hd tl tl a).word);
		if (n < 0 || n >= len x)
			ctxt.fail("fem", "fem: node out of range");
		return ref Listnode(nil, sys->sprint("%g", x[n])) :: nil;
	"nnodes" =>
		return ref Listnode(nil, string femesh->nnodes(ecommitted(ctxt, h).grid)) :: nil;
	"iters" =>
		esolved(ctxt, h);
		return ref Listnode(nil, string h.iters) :: nil;
	"resid" =>
		esolved(ctxt, h);
		return ref Listnode(nil, sys->sprint("%g", h.resid)) :: nil;
	"lasterror" =>
		p := ecommitted(ctxt, h);
		e := p.backend.lasterror;
		if (e == nil)
			e = "";
		return ref Listnode(nil, e) :: nil;
	}
	return nil;
}

remark(ctxt: ref Context, s: string)
{
	if (ctxt.options() & ctxt.INTERACTIVE)
		sys->print("%s\n", s);
}

ecommitted(ctxt: ref Context, h: ref Handle): ref Problem
{
	if (h.problem == nil)
		ctxt.fail("fem", "fem: handle not committed - run \"fem <id> commit\" first");
	return h.problem;
}

esolved(ctxt: ref Context, h: ref Handle): array of real
{
	ecommitted(ctxt, h);
	if (h.solution == nil)
		ctxt.fail("fem", "fem: handle not solved - run \"fem <id> solve\" first");
	return h.solution;
}

ehandle(ctxt: ref Context, w: string): ref Handle
{
	h := gethandle(int w);
	if (h == nil)
		ctxt.fail("bad id", "fem: unknown handle " + w);
	return h;
}

hashslot(id: int): int
{
	return id % len handles;
}

addhandle(h: ref Handle)
{
	slot := hashslot(h.id);
	handles[slot] = h :: handles[slot];
}

gethandle(id: int): ref Handle
{
	for (hl := handles[hashslot(id)]; hl != nil; hl = tl hl)
		if ((hd hl).id == id)
			return hd hl;
	return nil;
}

delhandle(id: int)
{
	slot := hashslot(id);
	nhl: list of ref Handle;
	for (hl := handles[slot]; hl != nil; hl = tl hl)
		if ((hd hl).id != id)
			nhl = hd hl :: nhl;
	handles[slot] = nhl;
}

isnum(s: string): int
{
	if (s == nil)
		return 0;
	for (i := 0; i < len s; i++)
		if (s[i] > '9' || s[i] < '0')
			return 0;
	return 1;
}

word(n: ref Listnode): string
{
	if (n.word != nil)
		return n.word;
	if (n.cmd != nil)
		n.word = sh->cmd2string(n.cmd);
	return n.word;
}

concat(argv: list of ref Listnode): string
{
	if (argv == nil)
		return nil;
	s := word(hd argv);
	for (argv = tl argv; argv != nil; argv = tl argv)
		s += " " + word(hd argv);
	return s;
}
