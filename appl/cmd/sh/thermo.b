implement Shellbuiltin;

# A shell interface to thermo(2): a gas, a state, a process, a cycle,
# and the heat-exchange formulas.
#
# The part that is not a thin wrapper is `path'.  A cycle's four corners
# are not a diagram - the curve between two of them is an isentrope or
# an isotherm, not the straight line that joining the corners would
# draw, and the AREA inside the loop is the work, so a diagram drawn
# with straight sides reports the wrong work to the eye.  `path'
# interpolates along the actual process between each pair, which is what
# a P-v diagram is.

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "sh.m";
	sh: Sh;
	Listnode, Context: import sh;
	myself: Shellbuiltin;
include "thermo.m";
	th: Thermo;
	Gas, State, Change, Cycle: import th;

Handle: adt {
	id:	int;
	gas:	ref Gas;
	st:	ref State;		# the current state
	ch:	ref Change;		# the last process
	cy:	ref Cycle;		# the last cycle
	kind:	string;			# which cycle it was, for path()
};

handles: array of list of ref Handle;
nexthandle := 0;

initbuiltin(ctxt: ref Context, shmod: Sh): string
{
	sys = load Sys Sys->PATH;
	sh = shmod;
	myself = load Shellbuiltin "$self";
	if (myself == nil)
		ctxt.fail("bad module", sys->sprint("thermo: cannot load self: %r"));
	math = load Math Math->PATH;
	th = load Thermo Thermo->PATH;
	if (th == nil || math == nil)
		ctxt.fail("bad module",
			sys->sprint("thermo: cannot load %s: %r", Thermo->PATH));
	th->init();
	handles = array[16] of list of ref Handle;
	ctxt.addbuiltin("thermo", myself);
	ctxt.addsbuiltin("thermo", myself);
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

USAGE: con "usage: thermo (new|del|<id> ...) args...";
VERBS: con "usage: thermo <id> (gas|state|isothermal|isobaric|isochoric|isentropic|polytropic|carnot|otto|diesel|brayton) args...";

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
	e: string;
	case verb {
	"gas" =>
		if (len a == 1 && word(hd a) == "air") {
			h.gas = th->air();
			return nil;
		}
		if (len a != 3)
			ctxt.fail("usage", "usage: thermo <id> gas air | gas NAME mw gamma");
		(g, ge) := th->fromgamma(word(hd a), real word(hd tl a),
			real word(hd tl tl a));
		if (ge != nil)
			ctxt.fail("thermo", "thermo: " + ge);
		h.gas = g;
	"state" =>
		if (len a != 3)
			ctxt.fail("usage", "usage: thermo <id> state (pt|pv|vt) a b");
		g := egas(ctxt, h);
		(x, y) := (real word(hd tl a), real word(hd tl tl a));
		s: ref State;
		case word(hd a) {
		"pt" =>	(s, e) = th->statept(g, x, y);
		"pv" =>	(s, e) = th->statepv(g, x, y);
		"vt" =>	(s, e) = th->statevt(g, x, y);
		* =>	ctxt.fail("usage", "thermo: a state is fixed by pt, pv or vt");
		}
		if (e != nil)
			ctxt.fail("thermo", "thermo: " + e);
		h.st = s;
		h.ch = nil;
	# each process moves the current state and records what it cost
	"isothermal" or "isentropic" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: thermo <id> " + verb + " p2");
		g := egas(ctxt, h);
		s := estate(ctxt, h);
		c: ref Change;
		if (verb == "isothermal")
			(c, e) = th->isothermal(g, s, real word(hd a));
		else
			(c, e) = th->isentropic(g, s, real word(hd a));
		if (e != nil)
			ctxt.fail("thermo", "thermo: " + e);
		h.ch = c;
		h.st = c.b;
	"isobaric" or "isochoric" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: thermo <id> " + verb + " t2");
		g := egas(ctxt, h);
		s := estate(ctxt, h);
		c: ref Change;
		if (verb == "isobaric")
			(c, e) = th->isobaric(g, s, real word(hd a));
		else
			(c, e) = th->isochoric(g, s, real word(hd a));
		if (e != nil)
			ctxt.fail("thermo", "thermo: " + e);
		h.ch = c;
		h.st = c.b;
	"polytropic" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: thermo <id> polytropic p2 n");
		(c, pe) := th->polytropic(egas(ctxt, h), estate(ctxt, h),
			real word(hd a), real word(hd tl a));
		if (pe != nil)
			ctxt.fail("thermo", "thermo: " + pe);
		h.ch = c;
		h.st = c.b;
	"carnot" =>
		if (len a != 4)
			ctxt.fail("usage", "usage: thermo <id> carnot tc th p1 p2");
		v := reals(a);
		(c, ce) := th->carnot(egas(ctxt, h), v[0], v[1], v[2], v[3]);
		if (ce != nil)
			ctxt.fail("thermo", "thermo: " + ce);
		h.cy = c;
		h.kind = "carnot";
	"otto" =>
		if (len a != 4)
			ctxt.fail("usage", "usage: thermo <id> otto ratio t1 p1 qin");
		v := reals(a);
		(c, ce) := th->otto(egas(ctxt, h), v[0], v[1], v[2], v[3]);
		if (ce != nil)
			ctxt.fail("thermo", "thermo: " + ce);
		h.cy = c;
		h.kind = "otto";
	"diesel" =>
		if (len a != 4)
			ctxt.fail("usage", "usage: thermo <id> diesel ratio cutoff t1 p1");
		v := reals(a);
		(c, ce) := th->diesel(egas(ctxt, h), v[0], v[1], v[2], v[3]);
		if (ce != nil)
			ctxt.fail("thermo", "thermo: " + ce);
		h.cy = c;
		h.kind = "diesel";
	"brayton" =>
		if (len a != 4)
			ctxt.fail("usage", "usage: thermo <id> brayton ratio t1 p1 t3");
		v := reals(a);
		(c, ce) := th->brayton(egas(ctxt, h), v[0], v[1], v[2], v[3]);
		if (ce != nil)
			ctxt.fail("thermo", "thermo: " + ce);
		h.cy = c;
		h.kind = "brayton";
	* =>
		ctxt.fail("usage", "thermo: unknown command " + verb);
	}
	return nil;
}

SUSAGE: con "usage: thermo <id> (r|cp|cv|gamma|p|v|t|u|h|s|work|heat|du|ds|efficiency|wnet|qin|qout|states|path|lmtd|effectiveness|fin) args...";

runsbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode): list of ref Listnode
{
	if ((hd argv).word != "thermo")
		return nil;
	argv = tl argv;
	if (argv == nil)
		ctxt.fail("usage", "usage: thermo new");
	w := (hd argv).word;
	if (w == "new")
		return ref Listnode(nil, string newhandle().id) :: nil;
	if (!isnum(w))
		ctxt.fail("usage", "usage: thermo new | thermo <id> args...");
	h := ehandle(ctxt, w);
	rest := tl argv;
	if (rest == nil)
		ctxt.fail("usage", SUSAGE);
	a := tl rest;
	case (hd rest).word {
	"r" =>		return num(egas(ctxt, h).r);
	"cp" =>		return num(egas(ctxt, h).cp);
	"cv" =>		return num(egas(ctxt, h).cv);
	"gamma" =>	return num(egas(ctxt, h).gamma());
	"p" =>		return num(estate(ctxt, h).p);
	"v" =>		return num(estate(ctxt, h).v);
	"t" =>		return num(estate(ctxt, h).t);
	"u" =>		return num(estate(ctxt, h).u);
	"h" =>		return num(estate(ctxt, h).h);
	"s" =>		return num(estate(ctxt, h).s);
	"work" =>	return num(echange(ctxt, h).work);
	"heat" =>	return num(echange(ctxt, h).heat);
	"du" =>		return num(echange(ctxt, h).du);
	"ds" =>		return num(echange(ctxt, h).ds);
	"efficiency" =>	return num(ecycle(ctxt, h).efficiency);
	"wnet" =>	return num(ecycle(ctxt, h).wnet);
	"qin" =>	return num(ecycle(ctxt, h).qin);
	"qout" =>	return num(ecycle(ctxt, h).qout);
	# the corners: p v T for each, in order round the loop
	"states" =>
		c := ecycle(ctxt, h);
		r := array[3*len c.states] of real;
		for (i := 0; i < len c.states; i++) {
			r[3*i] = c.states[i].p;
			r[3*i+1] = c.states[i].v;
			r[3*i+2] = c.states[i].t;
		}
		return nums(r);
	"names" =>
		c := ecycle(ctxt, h);
		l: list of ref Listnode;
		for (i := len c.names - 1; i >= 0; i--)
			l = ref Listnode(nil, c.names[i]) :: l;
		return l;
	# the loop itself, v and p, interpolated along the real process
	# between each pair of corners rather than straight across
	"path" =>
		n := 40;
		if (len a == 1)
			n = int word(hd a);
		# one a side is exactly the corners, which is what a plot of
		# the state points wants, so it is allowed rather than refused
		if (n < 1)
			ctxt.fail("usage", "thermo: a path needs at least one point a side");
		return nums(cyclepath(ctxt, h, n));
	"lmtd" =>
		if (len a != 5)
			ctxt.fail("usage", "usage: thermo <id> lmtd (parallel|counter) thi tho tci tco");
		v := reals(tl a);
		(d, e) := th->lmtd(arrangement(ctxt, word(hd a)), v[0], v[1], v[2], v[3]);
		if (e != nil)
			ctxt.fail("thermo", "thermo: " + e);
		return num(d);
	"effectiveness" =>
		if (len a != 3)
			ctxt.fail("usage", "usage: thermo <id> effectiveness (parallel|counter) ntu cr");
		(v, e) := th->effectiveness(arrangement(ctxt, word(hd a)),
			real word(hd tl a), real word(hd tl tl a));
		if (e != nil)
			ctxt.fail("thermo", "thermo: " + e);
		return num(v);
	"fin" =>
		if (len a != 4)
			ctxt.fail("usage", "usage: thermo <id> fin h k thickness length");
		v := reals(a);
		(f, e) := th->finefficiency(v[0], v[1], v[2], v[3]);
		if (e != nil)
			ctxt.fail("thermo", "thermo: " + e);
		return num(f);
	}
	ctxt.fail("usage", SUSAGE);
	return nil;
}

arrangement(ctxt: ref Context, w: string): int
{
	case w {
	"parallel" =>	return th->PARALLEL;
	"counter" =>	return th->COUNTER;
	}
	ctxt.fail("usage", "thermo: an exchanger is parallel or counter");
	return 0;
}

# Which process joins each pair of corners, for each cycle this knows.
# A P-v diagram's AREA is the work, so joining the corners with straight
# lines would draw the wrong work - an isentrope bows away from the
# chord, and by a lot at a high compression ratio.
cyclepath(ctxt: ref Context, h: ref Handle, n: int): array of real
{
	c := ecycle(ctxt, h);
	g := egas(ctxt, h);
	ns := len c.states;
	out := array[2*ns*n] of real;
	k := 0;
	for (i := 0; i < ns; i++) {
		s := c.states[i];
		e := c.states[(i+1)%ns];
		how := leg(h.kind, i);
		for (j := 0; j < n; j++) {
			f := real j/real n;
			(p, v) := (0.0, 0.0);
			case how {
			'v' =>			# constant volume
				v = s.v;
				p = s.p + f*(e.p - s.p);
			'p' =>			# constant pressure
				p = s.p;
				v = s.v + f*(e.v - s.v);
			't' =>			# isothermal: pv constant
				v = s.v*math->pow(e.v/s.v, f);
				p = s.p*s.v/v;
			* =>			# isentropic: pv^gamma constant
				v = s.v*math->pow(e.v/s.v, f);
				p = s.p*math->pow(s.v/v, g.gamma());
			}
			out[k++] = v;
			out[k++] = p;
		}
	}
	return out;
}

leg(kind: string, i: int): int
{
	case kind {
	"otto" =>
		# compress, burn at volume, expand, reject at volume
		if (i == 1 || i == 3)
			return 'v';
		return 's';
	"diesel" =>
		if (i == 1)
			return 'p';
		if (i == 3)
			return 'v';
		return 's';
	"brayton" =>
		if (i == 1 || i == 3)
			return 'p';
		return 's';
	"carnot" =>
		if (i == 0 || i == 2)
			return 't';
		return 's';
	}
	return 's';
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

reals(a: list of ref Listnode): array of real
{
	r := array[len a] of real;
	for (i := 0; a != nil; (a, i) = (tl a, i+1))
		r[i] = real word(hd a);
	return r;
}

egas(ctxt: ref Context, h: ref Handle): ref Gas
{
	if (h.gas == nil)
		ctxt.fail("thermo", "thermo: no gas - use \"thermo <id> gas air\"");
	return h.gas;
}

estate(ctxt: ref Context, h: ref Handle): ref State
{
	if (h.st == nil)
		ctxt.fail("thermo", "thermo: no state - use \"thermo <id> state pt p T\"");
	return h.st;
}

echange(ctxt: ref Context, h: ref Handle): ref Change
{
	if (h.ch == nil)
		ctxt.fail("thermo", "thermo: no process has been run");
	return h.ch;
}

ecycle(ctxt: ref Context, h: ref Handle): ref Cycle
{
	if (h.cy == nil)
		ctxt.fail("thermo", "thermo: no cycle has been run");
	return h.cy;
}

remark(ctxt: ref Context, s: string)
{
	if (ctxt.options() & ctxt.INTERACTIVE)
		sys->print("%s\n", s);
}

newhandle(): ref Handle
{
	h := ref Handle(nexthandle++, nil, nil, nil, nil, nil);
	addhandle(h);
	return h;
}

ehandle(ctxt: ref Context, w: string): ref Handle
{
	h := gethandle(int w);
	if (h == nil)
		ctxt.fail("bad id", "thermo: unknown handle " + w);
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
