implement Shellbuiltin;

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
	sh: Sh;
	Listnode, Context: import sh;
	myself: Shellbuiltin;
include "pde.m";
	pde: Pde;
	Problem: import pde;

# A handle is either a spec still being built (problem == nil, lines
# accumulating in spec) or a committed, ready-to-step problem (problem
# != nil, spec no longer used) - the incremental "pde $id mesh ...;
# pde $id equation ...; pde $id commit" build-up a script needs, laid
# on top of pde(2)'s own single-string newproblem(), which never
# changes: this file owns the incremental UX, pde.m/pde.b stay exactly
# as already verified.
Handle: adt {
	id:		int;
	spec:		string;
	problem:	ref Problem;
};

handles: array of list of ref Handle;
nexthandle := 0;

initbuiltin(ctxt: ref Context, shmod: Sh): string
{
	sys = load Sys Sys->PATH;
	sh = shmod;
	myself = load Shellbuiltin "$self";
	if (myself == nil)
		ctxt.fail("bad module", sys->sprint("pde: cannot load self: %r"));
	pde = load Pde Pde->PATH;
	if (pde == nil)
		ctxt.fail("bad module",
			sys->sprint("pde: cannot load %s: %r", Pde->PATH));
	pde->init();
	handles = array[16] of list of ref Handle;
	ctxt.addbuiltin("pde", myself);
	ctxt.addsbuiltin("pde", myself);
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
#   id := `{pde new}
#   pde $id mesh 64x64 domain 1x1 bc clamp
#   pde $id equation diffuse diffusivity 0.05
#   pde $id solver gmres tolerance 1e-8 restart 30
#   pde $id time step 0.01
#   pde $id commit
#   pde $id step 0.5
#   pde del $id
# Each "mesh"/"equation"/"solver"/"time" call appends one line of
# pde(2)'s own spec language, exactly as documented there - this file
# adds no vocabulary of its own beyond the handle/commit bookkeeping.
runbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode, nil: int): string
{
	if (tl argv == nil)
		ctxt.fail("usage", "usage: pde (new|del|<id> ...) args...");
	argv = tl argv;
	w := (hd argv).word;
	case w {
	"new" =>
		h := ref Handle(nexthandle++, nil, nil);
		addhandle(h);
		remark(ctxt, string h.id);
		return nil;
	"del" =>
		for (argv = tl argv; argv != nil; argv = tl argv)
			delhandle(int (hd argv).word);
		return nil;
	}
	if (!isnum(w))
		ctxt.fail("usage", "usage: pde (new|del|<id> ...) args...");
	h := ehandle(ctxt, w);
	rest := tl argv;
	if (rest == nil)
		ctxt.fail("usage", "usage: pde <id> (mesh|equation|solver|time|commit|step|run|clear|set) args...");
	verb := (hd rest).word;
	case verb {
	"mesh" or "equation" or "solver" or "time" =>
		if (h.problem != nil)
			ctxt.fail("pde", "pde: handle already committed");
		line := verb + " " + concat(tl rest);
		if (h.spec == nil)
			h.spec = line;
		else
			h.spec += "\n" + line;
	"commit" =>
		if (h.problem != nil)
			return nil;
		(p, err) := pde->newproblem(h.spec);
		if (err != nil)
			ctxt.fail("pde", "pde: " + err);
		h.problem = p;
	"step" =>
		p := ecommitted(ctxt, h);
		if (len tl rest != 1)
			ctxt.fail("usage", "usage: pde <id> step dt");
		err := pde->step(p, real (hd tl rest).word);
		if (err != nil)
			ctxt.fail("pde", "pde: " + err);
	"clear" =>
		p := ecommitted(ctxt, h);
		if (len tl rest != 1)
			ctxt.fail("usage", "usage: pde <id> clear value");
		pde->clear(p.field, real (hd tl rest).word);
	"set" =>
		p := ecommitted(ctxt, h);
		a := tl rest;
		if (len a != 3)
			ctxt.fail("usage", "usage: pde <id> set x y value");
		pde->set(p.field, int (hd a).word, int (hd tl a).word,
			real (hd tl tl a).word);
	"splat" =>
		p := ecommitted(ctxt, h);
		a := tl rest;
		if (len a != 4)
			ctxt.fail("usage", "usage: pde <id> splat cx cy radius value");
		pde->splat(p.field, int (hd a).word, int (hd tl a).word,
			int (hd tl tl a).word, real (hd tl tl tl a).word);
	* =>
		ctxt.fail("usage", "pde: unknown command " + verb);
	}
	return nil;
}

# usage: pde <id> (get|run|nx|ny|dx|dy) args...
runsbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode): list of ref Listnode
{
	if ((hd argv).word != "pde")
		return nil;
	argv = tl argv;
	if (argv == nil)
		ctxt.fail("usage", "usage: pde new");
	w := (hd argv).word;
	if (w == "new") {
		h := ref Handle(nexthandle++, nil, nil);
		addhandle(h);
		return ref Listnode(nil, string h.id) :: nil;
	}
	if (!isnum(w))
		ctxt.fail("usage", "usage: pde new | pde <id> args...");
	h := ehandle(ctxt, w);
	rest := tl argv;
	if (rest == nil)
		ctxt.fail("usage", "usage: pde <id> (get|run|nx|ny|dx|dy) args...");
	case (hd rest).word {
	"get" =>
		p := ecommitted(ctxt, h);
		a := tl rest;
		if (len a != 2)
			ctxt.fail("usage", "usage: pde <id> get x y");
		v := pde->get(p.field, int (hd a).word, int (hd tl a).word);
		return ref Listnode(nil, sys->sprint("%g", v)) :: nil;
	"run" =>
		p := ecommitted(ctxt, h);
		a := tl rest;
		if (len a != 1)
			ctxt.fail("usage", "usage: pde <id> run until");
		(n, err) := pde->run(p, real (hd a).word);
		if (err != nil)
			ctxt.fail("pde", "pde: " + err);
		return ref Listnode(nil, string n) :: nil;
	"nx" =>
		return ref Listnode(nil, string ecommitted(ctxt, h).field.nx) :: nil;
	"ny" =>
		return ref Listnode(nil, string ecommitted(ctxt, h).field.ny) :: nil;
	"dx" =>
		return ref Listnode(nil, sys->sprint("%g", ecommitted(ctxt, h).field.dx)) :: nil;
	"dy" =>
		return ref Listnode(nil, sys->sprint("%g", ecommitted(ctxt, h).field.dy)) :: nil;
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
		ctxt.fail("pde", "pde: handle not committed - run \"pde <id> commit\" first");
	return h.problem;
}

ehandle(ctxt: ref Context, w: string): ref Handle
{
	h := gethandle(int w);
	if (h == nil)
		ctxt.fail("bad id", "pde: unknown handle " + w);
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
