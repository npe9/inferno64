implement Shellbuiltin;

# A shell interface to flow(2).
#
# A flow is a FIELD, not a series, which is the difficulty: there is no
# curve to hand to a plot.  Three things come back instead, and between
# them they are how a flow is looked at:
#
#	field	a coarse grid of x y dx dy, for a vector layer - arrows,
#		which here are right, because a velocity really is an
#		arrow at a point
#	profile	the velocity across a line, which IS a series, and is
#		what a channel flow is judged by
#	at	the velocity at one point
#
# The initial velocity is two hoc(2) expressions in x and y, as
# sh-optim(1) takes one: a shell has no functions to give, so the field
# is compiled from text.

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "sh.m";
	sh: Sh;
	Listnode, Context: import sh;
	myself: Shellbuiltin;
include "hoc.m";
	hoc: Hoc;
	Expr: import hoc;
include "flow.m";
	fl: Flow;
	Sim: import fl;

Handle: adt {
	id:	int;
	sim:	ref Sim;
	ue, ve:	ref Expr;		# the initial field, compiled
};

handles: array of list of ref Handle;
nexthandle := 0;
cur: ref Handle;

initbuiltin(ctxt: ref Context, shmod: Sh): string
{
	sys = load Sys Sys->PATH;
	sh = shmod;
	myself = load Shellbuiltin "$self";
	if (myself == nil)
		ctxt.fail("bad module", sys->sprint("flow: cannot load self: %r"));
	math = load Math Math->PATH;
	hoc = load Hoc Hoc->PATH;
	fl = load Flow Flow->PATH;
	if (fl == nil || hoc == nil || math == nil)
		ctxt.fail("bad module",
			sys->sprint("flow: cannot load %s: %r", Flow->PATH));
	hoc->init(nil, nil);
	fl->init();
	handles = array[16] of list of ref Handle;
	ctxt.addbuiltin("flow", myself);
	ctxt.addsbuiltin("flow", myself);
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

USAGE: con "usage: flow (new|del|<id> ...) args...";
VERBS: con "usage: flow <id> (grid|lid|force|init|step|run) args...";

edgesof(ctxt: ref Context, w: string): int
{
	case w {
	"periodic" =>	return fl->PERIODIC;
	"channel" =>	return fl->CHANNEL;
	"cavity" =>	return fl->CAVITY;
	}
	ctxt.fail("usage", "flow: the edges are periodic, channel or cavity");
	return 0;
}

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
	"grid" =>
		if (len a != 6)
			ctxt.fail("usage", "usage: flow <id> grid nx ny lx ly viscosity edges");
		(s, e) := fl->new(int word(hd a), int word(hd tl a),
			real word(hd tl tl a), real word(hd tl tl tl a),
			real word(hd tl tl tl tl a),
			edgesof(ctxt, word(hd tl tl tl tl tl a)));
		if (e != nil)
			ctxt.fail("flow", "flow: " + e);
		h.sim = s;
	"lid" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: flow <id> lid speed");
		esim(ctxt, h).lid = real word(hd a);
	"force" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: flow <id> force fx fy");
		s := esim(ctxt, h);
		s.fx = real word(hd a);
		s.fy = real word(hd tl a);
	# two hoc expressions in x and y, one per component
	"init" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: flow <id> init u-expr v-expr");
		s := esim(ctxt, h);
		h.ue = hoc->compile(word(hd a));
		h.ve = hoc->compile(word(hd tl a));
		if (h.ue == nil || h.ve == nil)
			ctxt.fail("flow", "flow: cannot compile the initial field");
		cur = h;
		fl->setvelocity(s, initial);
		cur = nil;
	"step" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: flow <id> step dt");
		e := fl->step(esim(ctxt, h), real word(hd a));
		if (e != nil)
			ctxt.fail("flow", "flow: " + e);
	"run" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: flow <id> run dt nsteps");
		s := esim(ctxt, h);
		dt := real word(hd a);
		n := int word(hd tl a);
		for (k := 0; k < n; k++) {
			e := fl->step(s, dt);
			if (e != nil)
				ctxt.fail("flow", sys->sprint("flow: step %d: %s", k+1, e));
		}
	* =>
		ctxt.fail("usage", "flow: unknown command " + verb);
	}
	return nil;
}

initial(x, y: real): (real, real)
{
	hoc->setvar("x", x);
	hoc->setvar("y", y);
	u := hoc->eval(cur.ue);
	hoc->setvar("x", x);
	hoc->setvar("y", y);
	return (u, hoc->eval(cur.ve));
}

SUSAGE: con "usage: flow <id> (at|profile|field|divergence|energy|courant|maxstep|time|nx|ny) args...";

runsbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode): list of ref Listnode
{
	if ((hd argv).word != "flow")
		return nil;
	argv = tl argv;
	if (argv == nil)
		ctxt.fail("usage", "usage: flow new");
	w := (hd argv).word;
	if (w == "new")
		return ref Listnode(nil, string newhandle().id) :: nil;
	if (!isnum(w))
		ctxt.fail("usage", "usage: flow new | flow <id> args...");
	h := ehandle(ctxt, w);
	rest := tl argv;
	if (rest == nil)
		ctxt.fail("usage", SUSAGE);
	a := tl rest;
	case (hd rest).word {
	"at" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: flow <id> at x y");
		s := esim(ctxt, h);
		(u, v) := s.at(real word(hd a), real word(hd tl a));
		return ref Listnode(nil, sys->sprint("%g", u)) ::
		       ref Listnode(nil, sys->sprint("%g", v)) :: nil;
	# the velocity across a vertical line: y, u, v for n points, which
	# is a series and is what a channel flow is judged by
	"profile" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: flow <id> profile x n");
		s := esim(ctxt, h);
		x := real word(hd a);
		n := int word(hd tl a);
		if (n < 2)
			ctxt.fail("usage", "flow: a profile needs at least two points");
		r := array[3*n] of real;
		for (i := 0; i < n; i++) {
			y := s.ly*(real i + 0.5)/real n;
			(u, v) := s.at(x, y);
			r[3*i] = y;
			r[3*i+1] = u;
			r[3*i+2] = v;
		}
		return nums(r);
	# a coarse grid of x y dx dy, for a vector layer.  The arrows are
	# scaled by the caller, since the right length depends on the box
	# and on how fast the flow happens to be.
	"field" =>
		if (len a != 2 && len a != 3)
			ctxt.fail("usage", "usage: flow <id> field nx ny [scale]");
		s := esim(ctxt, h);
		gx := int word(hd a);
		gy := int word(hd tl a);
		sc := 1.0;
		if (len a == 3)
			sc = real word(hd tl tl a);
		if (gx < 1 || gy < 1)
			ctxt.fail("usage", "flow: a field needs at least one arrow each way");
		r := array[4*gx*gy] of real;
		k := 0;
		for (j := 0; j < gy; j++)
			for (i := 0; i < gx; i++) {
				x := s.lx*(real i + 0.5)/real gx;
				y := s.ly*(real j + 0.5)/real gy;
				(u, v) := s.at(x, y);
				r[k++] = x;
				r[k++] = y;
				r[k++] = sc*u;
				r[k++] = sc*v;
			}
		return nums(r);
	"divergence" =>	return num(esim(ctxt, h).divergence());
	"energy" =>	return num(esim(ctxt, h).energy());
	"maxstep" =>	return num(fl->maxstep(esim(ctxt, h)));
	"courant" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: flow <id> courant dt");
		return num(esim(ctxt, h).courant(real word(hd a)));
	"time" =>	return num(esim(ctxt, h).t);
	"nx" =>		return ref Listnode(nil, string esim(ctxt, h).nx) :: nil;
	"ny" =>		return ref Listnode(nil, string esim(ctxt, h).ny) :: nil;
	}
	ctxt.fail("usage", SUSAGE);
	return nil;
}

num(v: real): list of ref Listnode
{
	return ref Listnode(nil, sys->sprint("%g", v)) :: nil;
}

nums(a: array of real): list of ref Listnode
{
	l: list of ref Listnode;
	for (i := len a - 1; i >= 0; i--)
		l = ref Listnode(nil, sys->sprint("%g", a[i])) :: l;
	return l;
}

esim(ctxt: ref Context, h: ref Handle): ref Sim
{
	if (h.sim == nil)
		ctxt.fail("flow", "flow: no grid - use \"flow <id> grid nx ny lx ly "+
			"viscosity edges\"");
	return h.sim;
}

remark(ctxt: ref Context, s: string)
{
	if (ctxt.options() & ctxt.INTERACTIVE)
		sys->print("%s\n", s);
}

newhandle(): ref Handle
{
	h := ref Handle(nexthandle++, nil, nil, nil);
	addhandle(h);
	return h;
}

ehandle(ctxt: ref Context, w: string): ref Handle
{
	h := gethandle(int w);
	if (h == nil)
		ctxt.fail("bad id", "flow: unknown handle " + w);
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
