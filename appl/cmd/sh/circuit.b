implement Shellbuiltin;

# A shell interface to circuit(2), so that a netlist can be run and its
# answer looked at without writing a Limbo program.
#
# The point of it is the last step: `trace' hands back the recorded
# waveform as one flat list of numbers, which is exactly what sh-plot's
# `append' takes, so a transient analysis becomes a picture in one line
# of sh(1).  That is the whole reason this file exists - circuit(2) was
# already complete and tested, and what was missing was a way for a
# person to use it.
#
# No netlist vocabulary is added here.  The spec handed to `spec' or
# read by `read' is circuit(2)'s own language, documented in circuit(2),
# and this file only accumulates it and calls out.

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
	sh: Sh;
	Listnode, Context: import sh;
	myself: Shellbuiltin;
include "circuit.m";
	ckt: Circuit;
	Net: import ckt;

# what a handle is recording: a node voltage or a part current
VOLT, AMP: con iota;

Watch: adt {
	kind:	int;
	name:	string;
};

Handle: adt {
	id:	int;
	spec:	string;
	net:	ref Net;
	watches: array of ref Watch;
	rows:	array of real;		# (1 + len watches) per row: t, then each
	nrows:	int;
	started: int;			# begin() or beginfromdc() has been called
};

handles: array of list of ref Handle;
nexthandle := 0;

initbuiltin(ctxt: ref Context, shmod: Sh): string
{
	sys = load Sys Sys->PATH;
	sh = shmod;
	myself = load Shellbuiltin "$self";
	if (myself == nil)
		ctxt.fail("bad module", sys->sprint("circuit: cannot load self: %r"));
	ckt = load Circuit Circuit->PATH;
	if (ckt == nil)
		ctxt.fail("bad module",
			sys->sprint("circuit: cannot load %s: %r", Circuit->PATH));
	ckt->init();
	handles = array[16] of list of ref Handle;
	ctxt.addbuiltin("circuit", myself);
	ctxt.addsbuiltin("circuit", myself);
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

USAGE: con "usage: circuit (new|del|<id> ...) args...";
VERBS: con "usage: circuit <id> (spec|read|dc|begin|begindc|watch|step|run|clear) args...";

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
	"spec" =>
		if (h.net != nil)
			ctxt.fail("circuit", "circuit: the netlist is already parsed; "+
				"use a new handle to change it");
		line := concat(a);
		if (h.spec == nil)
			h.spec = line;
		else
			h.spec += "\n" + line;
	"read" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: circuit <id> read file");
		(txt, err) := readfile(word(hd a));
		if (err != nil)
			ctxt.fail("circuit", "circuit: " + err);
		if (h.spec == nil)
			h.spec = txt;
		else
			h.spec += "\n" + txt;
	"dc" =>
		n := eparsed(ctxt, h);
		e := ckt->dc(n);
		if (e != nil)
			ctxt.fail("circuit", "circuit: " + e);
		h.started = 0;
	"begin" or "begindc" =>
		n := eparsed(ctxt, h);
		e: string;
		if (verb == "begin")
			e = ckt->begin(n);
		else
			e = ckt->beginfromdc(n);
		if (e != nil)
			ctxt.fail("circuit", "circuit: " + e);
		h.started = 1;
		h.nrows = 0;
		record(h, 0.0);
	"watch" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: circuit <id> watch (v|i) name");
		k := word(hd a);
		if (k != "v" && k != "i")
			ctxt.fail("usage", "circuit: watch v NODE, or watch i PART");
		if (h.nrows > 0)
			ctxt.fail("circuit", "circuit: what to record must be said before "+
				"the run, or the earlier rows would have fewer columns");
		kind := VOLT;
		if (k == "i")
			kind = AMP;
		addwatch(h, ref Watch(kind, word(hd tl a)));
	"step" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: circuit <id> step dt");
		n := estarted(ctxt, h);
		dt := real word(hd a);
		e := ckt->step(n, dt);
		if (e != nil)
			ctxt.fail("circuit", "circuit: " + e);
		record(h, n.t);
	"run" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: circuit <id> run dt nsteps");
		n := estarted(ctxt, h);
		dt := real word(hd a);
		ns := int word(hd tl a);
		if (ns < 0)
			ctxt.fail("usage", "circuit: a negative number of steps");
		for (k := 0; k < ns; k++) {
			e := ckt->step(n, dt);
			if (e != nil)
				ctxt.fail("circuit", sys->sprint("circuit: step %d: %s", k+1, e));
			record(h, n.t);
		}
	"clear" =>
		h.nrows = 0;
	* =>
		ctxt.fail("usage", "circuit: unknown command " + verb);
	}
	return nil;
}

SUSAGE: con "usage: circuit <id> (node|current|time|rows|columns|names|trace|analysis|text) args...";

runsbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode): list of ref Listnode
{
	if ((hd argv).word != "circuit")
		return nil;
	argv = tl argv;
	if (argv == nil)
		ctxt.fail("usage", "usage: circuit new");
	w := (hd argv).word;
	if (w == "new")
		return ref Listnode(nil, string newhandle().id) :: nil;
	if (!isnum(w))
		ctxt.fail("usage", "usage: circuit new | circuit <id> args...");
	h := ehandle(ctxt, w);
	rest := tl argv;
	if (rest == nil)
		ctxt.fail("usage", SUSAGE);
	a := tl rest;
	case (hd rest).word {
	"node" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: circuit <id> node name");
		n := esolved(ctxt, h);
		return num(ckt->nodev(n, word(hd a)));
	"current" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: circuit <id> current part");
		n := esolved(ctxt, h);
		return num(ckt->parti(n, word(hd a)));
	"time" =>
		return num(eparsed(ctxt, h).t);
	"rows" =>
		return ref Listnode(nil, string h.nrows) :: nil;
	"columns" =>
		return ref Listnode(nil, string (1 + len h.watches)) :: nil;
	"names" =>
		l: list of ref Listnode;
		for (i := len h.watches - 1; i >= 0; i--)
			l = ref Listnode(nil, h.watches[i].name) :: l;
		return ref Listnode(nil, "t") :: l;
	"analysis" =>
		return ref Listnode(nil, eparsed(ctxt, h).analysis) :: nil;
	"text" =>
		return ref Listnode(nil, h.spec) :: nil;
	# The recorded waveform, flattened: t and every watched value for
	# each row in turn.  That is the shape sh-plot's `append' takes,
	# so a whole transient goes into a graph in one command.
	"trace" =>
		nc := 1 + len h.watches;
		l: list of ref Listnode;
		for (i := h.nrows*nc - 1; i >= 0; i--)
			l = ref Listnode(nil, sys->sprint("%g", h.rows[i])) :: l;
		return l;
	}
	ctxt.fail("usage", SUSAGE);
	return nil;
}

num(v: real): list of ref Listnode
{
	return ref Listnode(nil, sys->sprint("%g", v)) :: nil;
}

record(h: ref Handle, t: real)
{
	nc := 1 + len h.watches;
	need := (h.nrows+1)*nc;
	if (h.rows == nil || need > len h.rows) {
		cap := 2*need;
		if (cap < 64*nc)
			cap = 64*nc;
		a := array[cap] of real;
		if (h.rows != nil)
			a[0:] = h.rows[0:h.nrows*nc];
		h.rows = a;
	}
	base := h.nrows*nc;
	h.rows[base] = t;
	for (i := 0; i < len h.watches; i++) {
		wv := h.watches[i];
		if (wv.kind == VOLT)
			h.rows[base+1+i] = ckt->nodev(h.net, wv.name);
		else
			h.rows[base+1+i] = ckt->parti(h.net, wv.name);
	}
	h.nrows++;
}

addwatch(h: ref Handle, wv: ref Watch)
{
	a := array[len h.watches + 1] of ref Watch;
	a[0:] = h.watches;
	a[len h.watches] = wv;
	h.watches = a;
}

readfile(path: string): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if (fd == nil)
		return (nil, sys->sprint("cannot open %s: %r", path));
	s := "";
	buf := array[8192] of byte;
	for (;;) {
		n := sys->read(fd, buf, len buf);
		if (n < 0)
			return (nil, sys->sprint("reading %s: %r", path));
		if (n == 0)
			break;
		s += string buf[0:n];
	}
	return (s, nil);
}

remark(ctxt: ref Context, s: string)
{
	if (ctxt.options() & ctxt.INTERACTIVE)
		sys->print("%s\n", s);
}

# The netlist is parsed the first time anything needs it, so that a
# script can build it up line by line and never say "commit".
eparsed(ctxt: ref Context, h: ref Handle): ref Net
{
	if (h.net != nil)
		return h.net;
	if (h.spec == nil)
		ctxt.fail("circuit", "circuit: no netlist - use \"circuit <id> spec ...\" "+
			"or \"circuit <id> read file\"");
	(n, e) := ckt->parse(h.spec);
	if (e != nil)
		ctxt.fail("circuit", "circuit: " + e);
	h.net = n;
	return n;
}

esolved(ctxt: ref Context, h: ref Handle): ref Net
{
	n := eparsed(ctxt, h);
	if (n.x == nil)
		ctxt.fail("circuit", "circuit: nothing has been solved yet - run "+
			"\"circuit <id> dc\" or a transient first");
	return n;
}

estarted(ctxt: ref Context, h: ref Handle): ref Net
{
	n := eparsed(ctxt, h);
	if (!h.started)
		ctxt.fail("circuit", "circuit: a transient needs an initial condition - "+
			"run \"circuit <id> begin\" or \"circuit <id> begindc\" first");
	return n;
}

newhandle(): ref Handle
{
	h := ref Handle(nexthandle++, nil, nil, array[0] of ref Watch, nil, 0, 0);
	addhandle(h);
	return h;
}

ehandle(ctxt: ref Context, w: string): ref Handle
{
	h := gethandle(int w);
	if (h == nil)
		ctxt.fail("bad id", "circuit: unknown handle " + w);
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
