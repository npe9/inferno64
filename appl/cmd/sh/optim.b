implement Shellbuiltin;

# A shell interface to optim(2), with the function to be searched
# written as a hoc(2) expression.
#
# That is the whole reason this one is interesting.  optim(2) takes a
# function reference, and a shell has no functions to give it - so the
# objective is compiled from text by hoc(2) and evaluated by setting the
# named variables and calling eval.  `optim $o root 0 1' on the
# expression cos(x)-x is then a complete root-finding session typed at a
# prompt.
#
# Limbo has no closures, so the compiled expression and the variable
# names live in module variables that the objective reads - the
# arrangement optim.m describes and krylov(2) uses.

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
	sh: Sh;
	Listnode, Context: import sh;
	myself: Shellbuiltin;
include "hoc.m";
	hoc: Hoc;
	Expr: import hoc;
include "optim.m";
	op: Optim;
	Result: import op;

Handle: adt {
	id:	int;
	src:	string;			# the expression as written
	e:	ref Expr;		# compiled
	vars:	array of string;	# what its variables are called
	pars:	array of string;	# for a fit: the parameter names
	xs, ys:	array of real;		# for a fit: the data
	nd:	int;
	obj:	array of real;		# linear programme: the objective
	rows:	array of array of real;	# and its constraints
	rhs:	array of real;
	nrow:	int;
};

handles: array of list of ref Handle;
nexthandle := 0;

# what the objective is looking at, for the duration of one call
cur: ref Handle;

initbuiltin(ctxt: ref Context, shmod: Sh): string
{
	sys = load Sys Sys->PATH;
	sh = shmod;
	myself = load Shellbuiltin "$self";
	if (myself == nil)
		ctxt.fail("bad module", sys->sprint("optim: cannot load self: %r"));
	hoc = load Hoc Hoc->PATH;
	op = load Optim Optim->PATH;
	if (hoc == nil || op == nil)
		ctxt.fail("bad module", sys->sprint("optim: cannot load %s or %s: %r",
			Hoc->PATH, Optim->PATH));
	hoc->init(nil, nil);
	op->init();
	handles = array[16] of list of ref Handle;
	ctxt.addbuiltin("optim", myself);
	ctxt.addsbuiltin("optim", myself);
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

USAGE: con "usage: optim (new|del|<id> ...) args...";
VERBS: con "usage: optim <id> (expr|vars|params|data|objective|constraint|clear) args...";

runbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode, nil: int): string
{
	if (tl argv == nil)
		ctxt.fail("usage", USAGE);
	argv = tl argv;
	w := (hd argv).word;
	case w {
	"new" =>
		h := newhandle();
		remark(ctxt, string h.id);
		return nil;
	"del" =>
		for (argv = tl argv; argv != nil; argv = tl argv)
			delhandle(int (hd argv).word);
		return nil;
	}
	if (!isnum(w))
		ctxt.fail("usage", USAGE);
	h := ehandle(ctxt, w);
	rest := tl argv;
	if (rest == nil)
		ctxt.fail("usage", VERBS);
	verb := (hd rest).word;
	a := tl rest;
	case verb {
	"expr" =>
		if (a == nil)
			ctxt.fail("usage", "usage: optim <id> expr hoc-expression");
		h.src = concat(a);
		h.e = hoc->compile(h.src);
		if (h.e == nil)
			ctxt.fail("optim", "optim: cannot compile: " + h.src);
	"vars" =>
		if (a == nil)
			ctxt.fail("usage", "usage: optim <id> vars name...");
		h.vars = words(a);
	"params" =>
		if (a == nil)
			ctxt.fail("usage", "usage: optim <id> params name...");
		h.pars = words(a);
	"data" =>
		n := len a;
		if (n == 0 || n % 2 != 0)
			ctxt.fail("usage", "usage: optim <id> data x y [x y]...");
		v := array[n] of real;
		for (i := 0; a != nil; (a, i) = (tl a, i+1))
			v[i] = real word(hd a);
		nd := n/2;
		xs := array[h.nd + nd] of real;
		ys := array[h.nd + nd] of real;
		if (h.nd > 0) {
			xs[0:] = h.xs[0:h.nd];
			ys[0:] = h.ys[0:h.nd];
		}
		for (i = 0; i < nd; i++) {
			xs[h.nd + i] = v[2*i];
			ys[h.nd + i] = v[2*i+1];
		}
		h.xs = xs;
		h.ys = ys;
		h.nd += nd;
	"objective" =>
		if (a == nil)
			ctxt.fail("usage", "usage: optim <id> objective coefficient...");
		h.obj = reals(a);
		h.nrow = 0;
	"constraint" =>
		if (len a < 2)
			ctxt.fail("usage", "usage: optim <id> constraint coefficient... rhs");
		v := reals(a);
		n := len v - 1;
		if (h.obj == nil)
			ctxt.fail("optim", "optim: say the objective before the constraints");
		if (n != len h.obj)
			ctxt.fail("optim", sys->sprint("optim: the objective has %d "+
				"variables and this constraint has %d coefficients",
				len h.obj, n));
		if (h.rows == nil || h.nrow >= len h.rows) {
			nr := array[2*h.nrow + 8] of array of real;
			nb := array[2*h.nrow + 8] of real;
			for (i := 0; i < h.nrow; i++) {
				nr[i] = h.rows[i];
				nb[i] = h.rhs[i];
			}
			h.rows = nr;
			h.rhs = nb;
		}
		h.rows[h.nrow] = v[0:n];
		h.rhs[h.nrow] = v[n];
		h.nrow++;
	"clear" =>
		h.nd = 0;
		h.nrow = 0;
		h.obj = nil;
	* =>
		ctxt.fail("usage", "optim: unknown command " + verb);
	}
	return nil;
}

SUSAGE: con "usage: optim <id> (value|root|bracket|minimise1|minimise|fit|linprog|text) args...";

runsbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode): list of ref Listnode
{
	if ((hd argv).word != "optim")
		return nil;
	argv = tl argv;
	if (argv == nil)
		ctxt.fail("usage", "usage: optim new");
	w := (hd argv).word;
	if (w == "new")
		return ref Listnode(nil, string newhandle().id) :: nil;
	if (!isnum(w))
		ctxt.fail("usage", "usage: optim new | optim <id> args...");
	h := ehandle(ctxt, w);
	rest := tl argv;
	if (rest == nil)
		ctxt.fail("usage", SUSAGE);
	a := tl rest;
	case (hd rest).word {
	"text" =>
		return ref Listnode(nil, h.src) :: nil;
	# evaluate the expression at a point, which is how to check that
	# what was typed is what was meant before searching it
	"value" =>
		eexpr(ctxt, h);
		v := reals(a);
		# the same default the search verbs use: one unnamed variable
		# is called x, which is what anyone typing an expression at a
		# prompt means
		if (len h.vars == 0 && len v == 1)
			h.vars = array[] of {"x"};
		if (len v != len h.vars)
			ctxt.fail("optim", sys->sprint("optim: %d variables, %d values",
				len h.vars, len v));
		cur = h;
		for (i := 0; i < len v; i++)
			hoc->setvar(h.vars[i], v[i]);
		r := hoc->eval(h.e);
		cur = nil;
		return num(r);
	"root" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: optim <id> root a b");
		eexpr(ctxt, h);
		one(ctxt, h);
		cur = h;
		(r, e) := op->root(objective1, real word(hd a), real word(hd tl a), 0.0);
		cur = nil;
		if (e != nil)
			ctxt.fail("optim", "optim: " + e);
		return num(r);
	"bracket" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: optim <id> bracket a b");
		eexpr(ctxt, h);
		one(ctxt, h);
		cur = h;
		(lo, hi, e) := op->bracket(objective1, real word(hd a), real word(hd tl a));
		cur = nil;
		if (e != nil)
			ctxt.fail("optim", "optim: " + e);
		return ref Listnode(nil, sys->sprint("%g", lo)) ::
		       ref Listnode(nil, sys->sprint("%g", hi)) :: nil;
	# the x where it is least, and the value there
	"minimise1" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: optim <id> minimise1 a b");
		eexpr(ctxt, h);
		one(ctxt, h);
		cur = h;
		(x, fx, e) := op->minimise1(objective1, real word(hd a),
			real word(hd tl a), 0.0);
		cur = nil;
		if (e != nil)
			ctxt.fail("optim", "optim: " + e);
		return ref Listnode(nil, sys->sprint("%g", x)) ::
		       ref Listnode(nil, sys->sprint("%g", fx)) :: nil;
	# the point where it is least, then the value, then whether it
	# converged - which is worth having, because Nelder-Mead stopping
	# because it ran out of steps looks exactly like it finishing
	"minimise" =>
		eexpr(ctxt, h);
		if (len h.vars == 0)
			ctxt.fail("optim", "optim: say what the variables are called first");
		start := reals(a);
		if (len start != len h.vars)
			ctxt.fail("optim", sys->sprint("optim: %d variables, %d starting "+
				"values", len h.vars, len start));
		cur = h;
		(r, e) := op->minimise(objectiven, start, nil, 0.0, 0);
		cur = nil;
		if (e != nil)
			ctxt.fail("optim", "optim: " + e);
		return resultlist(r);
	# fit the parameters of a model to the data, the model being an
	# expression in the parameters and the one variable
	"fit" =>
		eexpr(ctxt, h);
		if (len h.pars == 0)
			ctxt.fail("optim", "optim: say what the parameters are called first");
		if (len h.vars != 1)
			ctxt.fail("optim", "optim: a fit needs exactly one variable, the one "+
				"the data is indexed by");
		if (h.nd == 0)
			ctxt.fail("optim", "optim: there is no data to fit");
		start := reals(a);
		if (len start != len h.pars)
			ctxt.fail("optim", sys->sprint("optim: %d parameters, %d starting "+
				"values", len h.pars, len start));
		cur = h;
		(r, e) := op->fit(model, h.xs[0:h.nd], h.ys[0:h.nd], start, 0.0, 0);
		cur = nil;
		if (e != nil)
			ctxt.fail("optim", "optim: " + e);
		return resultlist(r);
	# the values of the variables, then the value of the objective
	"linprog" =>
		if (h.obj == nil)
			ctxt.fail("optim", "optim: no objective - use \"optim <id> objective "+
				"c1 c2 ...\"");
		if (h.nrow == 0)
			ctxt.fail("optim", "optim: no constraints, so the objective is "+
				"unbounded by construction");
		(r, e) := op->linprog(h.obj, h.rows[0:h.nrow], h.rhs[0:h.nrow]);
		if (e != nil)
			ctxt.fail("optim", "optim: " + e);
		return resultlist(r);
	}
	ctxt.fail("usage", SUSAGE);
	return nil;
}

resultlist(r: ref Result): list of ref Listnode
{
	l := ref Listnode(nil, sys->sprint("%g", r.value)) ::
	     ref Listnode(nil, string r.converged) ::
	     ref Listnode(nil, string r.iterations) :: nil;
	for (i := len r.x - 1; i >= 0; i--)
		l = ref Listnode(nil, sys->sprint("%g", r.x[i])) :: l;
	return l;
}

# The objective, in the three shapes optim(2) asks for.  Each sets the
# named variables in hoc's symbol table and evaluates the compiled
# expression; `cur' is what makes that possible without closures.
objective1(x: real): real
{
	hoc->setvar(cur.vars[0], x);
	return hoc->eval(cur.e);
}

objectiven(x: array of real): real
{
	for (i := 0; i < len cur.vars && i < len x; i++)
		hoc->setvar(cur.vars[i], x[i]);
	return hoc->eval(cur.e);
}

model(p: array of real, x: real): real
{
	for (i := 0; i < len cur.pars && i < len p; i++)
		hoc->setvar(cur.pars[i], p[i]);
	hoc->setvar(cur.vars[0], x);
	return hoc->eval(cur.e);
}

eexpr(ctxt: ref Context, h: ref Handle)
{
	if (h.e == nil)
		ctxt.fail("optim", "optim: no expression - use \"optim <id> expr ...\"");
}

one(ctxt: ref Context, h: ref Handle)
{
	if (len h.vars == 0) {
		h.vars = array[] of {"x"};
		return;
	}
	if (len h.vars != 1)
		ctxt.fail("optim", "optim: this takes a function of one variable, and "+
			sys->sprint("%d are named", len h.vars));
}

num(v: real): list of ref Listnode
{
	return ref Listnode(nil, sys->sprint("%g", v)) :: nil;
}

reals(a: list of ref Listnode): array of real
{
	r := array[len a] of real;
	for (i := 0; a != nil; (a, i) = (tl a, i+1))
		r[i] = real word(hd a);
	return r;
}

words(a: list of ref Listnode): array of string
{
	r := array[len a] of string;
	for (i := 0; a != nil; (a, i) = (tl a, i+1))
		r[i] = word(hd a);
	return r;
}

remark(ctxt: ref Context, s: string)
{
	if (ctxt.options() & ctxt.INTERACTIVE)
		sys->print("%s\n", s);
}

newhandle(): ref Handle
{
	h := ref Handle(nexthandle++, nil, nil, nil, nil, nil, nil, 0, nil, nil, nil, 0);
	addhandle(h);
	return h;
}

ehandle(ctxt: ref Context, w: string): ref Handle
{
	h := gethandle(int w);
	if (h == nil)
		ctxt.fail("bad id", "optim: unknown handle " + w);
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
