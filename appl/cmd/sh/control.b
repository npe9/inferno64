implement Shellbuiltin;

# A shell interface to control(2), so that a transfer function can be
# built, asked about and plotted without writing a Limbo program.
#
# As with sh-circuit(1), the thing that matters is that a response comes
# back as one flat list of numbers, which is the shape sh-plot(1)'s
# `append' takes.  A step response or a Bode plot is then one command.
#
# Coefficients go in HIGHEST POWER FIRST, which is control(2)'s order
# and the order a polynomial is written down in.  No vocabulary is added
# here beyond the handle bookkeeping.

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
	sh: Sh;
	Listnode, Context: import sh;
	myself: Shellbuiltin;
include "math.m";
	math: Math;
include "control.m";
	ctl: Control;
	Tf: import ctl;

Handle: adt {
	id:	int;
	num, den: array of real;
	tf:	ref Tf;
	rows:	array of real;
	nrows:	int;
	ncols:	int;
	names:	string;			# what the columns are, for `names'
};

handles: array of list of ref Handle;
nexthandle := 0;

initbuiltin(ctxt: ref Context, shmod: Sh): string
{
	sys = load Sys Sys->PATH;
	sh = shmod;
	myself = load Shellbuiltin "$self";
	if (myself == nil)
		ctxt.fail("bad module", sys->sprint("control: cannot load self: %r"));
	math = load Math Math->PATH;
	if (math == nil)
		ctxt.fail("bad module", sys->sprint("control: cannot load %s: %r", Math->PATH));
	ctl = load Control Control->PATH;
	if (ctl == nil)
		ctxt.fail("bad module",
			sys->sprint("control: cannot load %s: %r", Control->PATH));
	ctl->init();
	handles = array[16] of list of ref Handle;
	ctxt.addbuiltin("control", myself);
	ctxt.addsbuiltin("control", myself);
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

USAGE: con "usage: control (new|del|<id> ...) args...";
VERBS: con "usage: control <id> (num|den|pid|series|parallel|feedback|step|impulse|bode|clear) args...";

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
	"num" =>
		h.num = reals(ctxt, a, "num");
		h.tf = nil;
	"den" =>
		h.den = reals(ctxt, a, "den");
		h.tf = nil;
	"pid" =>
		if (len a != 4)
			ctxt.fail("usage", "usage: control <id> pid kp ki kd taud");
		v := reals(ctxt, a, "pid");
		(t, e) := ctl->pid(v[0], v[1], v[2], v[3]);
		if (e != nil)
			ctxt.fail("control", "control: " + e);
		setf(h, t);
	"series" or "parallel" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: control <id> " + verb + " <id2>");
		o := ehandle(ctxt, word(hd a));
		t := etf(ctxt, h);
		u := etf(ctxt, o);
		if (verb == "series")
			setf(h, ctl->series(t, u));
		else
			setf(h, ctl->parallel(t, u));
	"feedback" =>
		if (len a != 1 && len a != 2)
			ctxt.fail("usage", "usage: control <id> feedback <id2> [sign]");
		o := ehandle(ctxt, word(hd a));
		sign := -1;
		if (len a == 2)
			sign = int word(hd tl a);
		(t, e) := ctl->feedback(etf(ctxt, h), etf(ctxt, o), sign);
		if (e != nil)
			ctxt.fail("control", "control: " + e);
		setf(h, t);
	"step" or "impulse" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: control <id> " + verb + " dt n");
		dt := real word(hd a);
		n := int word(hd tl a);
		if (n <= 0)
			ctxt.fail("usage", "control: the number of samples is positive");
		y: array of real;
		e: string;
		if (verb == "step")
			(y, e) = ctl->stepresponse(etf(ctxt, h), dt, n);
		else
			(y, e) = ctl->impulseresponse(etf(ctxt, h), dt, n);
		if (e != nil)
			ctxt.fail("control", "control: " + e);
		h.ncols = 2;
		h.names = "t y";
		h.rows = array[2*n] of real;
		for (i := 0; i < n; i++) {
			h.rows[2*i] = real i*dt;
			h.rows[2*i+1] = y[i];
		}
		h.nrows = n;
	# frequencies spaced evenly in the logarithm, because that is how a
	# Bode plot is read and a linear sweep wastes nearly all its points
	# at the top of the range
	"bode" =>
		if (len a != 3)
			ctxt.fail("usage", "usage: control <id> bode wlo whi n");
		wlo := real word(hd a);
		whi := real word(hd tl a);
		n := int word(hd tl tl a);
		if (wlo <= 0.0 || whi <= wlo)
			ctxt.fail("usage", "control: the frequencies are positive and the "+
				"second is above the first");
		if (n < 2)
			ctxt.fail("usage", "control: a sweep needs at least two points");
		wa := array[n] of real;
		lo := log10(wlo);
		hi := log10(whi);
		for (i := 0; i < n; i++)
			wa[i] = pow10(lo + (hi-lo)*real i/real(n-1));
		(m, p) := ctl->bode(etf(ctxt, h), wa);
		h.ncols = 3;
		h.names = "w mag phase";
		h.rows = array[3*n] of real;
		for (i = 0; i < n; i++) {
			h.rows[3*i] = wa[i];
			h.rows[3*i+1] = m[i];
			h.rows[3*i+2] = p[i];
		}
		h.nrows = n;
	"clear" =>
		h.nrows = 0;
	* =>
		ctxt.fail("usage", "control: unknown command " + verb);
	}
	return nil;
}

SUSAGE: con "usage: control <id> (num|den|text|order|dcgain|poles|zeros|stable|routh|trace|names|rows|columns|margins|metrics) args...";

runsbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode): list of ref Listnode
{
	if ((hd argv).word != "control")
		return nil;
	argv = tl argv;
	if (argv == nil)
		ctxt.fail("usage", "usage: control new");
	w := (hd argv).word;
	if (w == "new")
		return ref Listnode(nil, string newhandle().id) :: nil;
	if (!isnum(w))
		ctxt.fail("usage", "usage: control new | control <id> args...");
	h := ehandle(ctxt, w);
	rest := tl argv;
	if (rest == nil)
		ctxt.fail("usage", SUSAGE);
	case (hd rest).word {
	# the coefficients back out, so that one handle's transfer function
	# can be copied into another - which is what combining systems in a
	# script needs, since series and feedback replace a handle in place
	"num" or "den" =>
		t := etf(ctxt, h);
		a := t.num;
		if ((hd rest).word == "den")
			a = t.den;
		l: list of ref Listnode;
		for (i := len a - 1; i >= 0; i--)
			l = ref Listnode(nil, sys->sprint("%g", a[i])) :: l;
		return l;
	"text" =>
		return ref Listnode(nil, etf(ctxt, h).text()) :: nil;
	"order" =>
		return ref Listnode(nil, string etf(ctxt, h).order()) :: nil;
	"dcgain" =>
		return num(etf(ctxt, h).dcgain());
	"poles" or "zeros" =>
		t := etf(ctxt, h);
		re, im: array of real;
		e: string;
		if ((hd rest).word == "poles")
			(re, im, e) = ctl->poles(t);
		else
			(re, im, e) = ctl->zeros(t);
		if (e != nil)
			ctxt.fail("control", "control: " + e);
		l: list of ref Listnode;
		for (i := len re - 1; i >= 0; i--)
			l = ref Listnode(nil, sys->sprint("%g", re[i])) ::
			    ref Listnode(nil, sys->sprint("%g", im[i])) :: l;
		return l;
	"stable" =>
		(st, e) := ctl->stable(etf(ctxt, h));
		if (e != nil)
			ctxt.fail("control", "control: " + e);
		return ref Listnode(nil, string st) :: nil;
	"routh" =>
		(n, e) := ctl->routh(etf(ctxt, h).den);
		if (e != nil)
			ctxt.fail("control", "control: " + e);
		return ref Listnode(nil, string n) :: nil;
	"rows" =>
		return ref Listnode(nil, string h.nrows) :: nil;
	"columns" =>
		return ref Listnode(nil, string h.ncols) :: nil;
	"names" =>
		l: list of ref Listnode;
		(nil, toks) := sys->tokenize(h.names, " ");
		for (; toks != nil; toks = tl toks)
			l = ref Listnode(nil, hd toks) :: l;
		return rev(l);
	"trace" =>
		l: list of ref Listnode;
		for (i := h.nrows*h.ncols - 1; i >= 0; i--)
			l = ref Listnode(nil, sys->sprint("%g", h.rows[i])) :: l;
		return l;
	# gain margin, its frequency, phase margin in DEGREES, its
	# frequency.  A margin that does not exist comes back as the word
	# `none' rather than a large number, because no gain margin at all
	# is not the same as a big one.
	"margins" =>
		(m, e) := ctl->margins(etf(ctxt, h));
		if (e != nil)
			ctxt.fail("control", "control: " + e);
		g := "none";
		gw := "none";
		if (m.hasgain) {
			g = sys->sprint("%g", m.gain);
			gw = sys->sprint("%g", m.gainw);
		}
		p := "none";
		pw := "none";
		if (m.hasphase) {
			p = sys->sprint("%g", m.phase*180.0/math->Pi);
			pw = sys->sprint("%g", m.phasew);
		}
		return ref Listnode(nil, g) :: ref Listnode(nil, gw) ::
		       ref Listnode(nil, p) :: ref Listnode(nil, pw) :: nil;
	# final rise peak peakt overshoot settle, from the last step
	# response computed
	"metrics" =>
		if (h.nrows == 0 || h.names != "t y")
			ctxt.fail("control", "control: metrics describe a step response, and "+
				"none has been computed - run \"control <id> step dt n\" first");
		y := array[h.nrows] of real;
		for (i := 0; i < h.nrows; i++)
			y[i] = h.rows[2*i+1];
		dt := 0.0;
		if (h.nrows > 1)
			dt = h.rows[2] - h.rows[0];
		m := ctl->metrics(y, dt);
		# settled first, because it says whether to believe the rest
		return ref Listnode(nil, string m.settled) ::
		       ref Listnode(nil, sys->sprint("%g", m.final)) ::
		       ref Listnode(nil, sys->sprint("%g", m.rise)) ::
		       ref Listnode(nil, sys->sprint("%g", m.peak)) ::
		       ref Listnode(nil, sys->sprint("%g", m.peakt)) ::
		       ref Listnode(nil, sys->sprint("%g", m.overshoot)) ::
		       ref Listnode(nil, sys->sprint("%g", m.settle)) :: nil;
	}
	ctxt.fail("usage", SUSAGE);
	return nil;
}

rev(l: list of ref Listnode): list of ref Listnode
{
	r: list of ref Listnode;
	for (; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

num(v: real): list of ref Listnode
{
	return ref Listnode(nil, sys->sprint("%g", v)) :: nil;
}

reals(ctxt: ref Context, a: list of ref Listnode, what: string): array of real
{
	n := len a;
	if (n == 0)
		ctxt.fail("usage", "control: " + what + " needs at least one coefficient");
	r := array[n] of real;
	for (i := 0; a != nil; (a, i) = (tl a, i+1))
		r[i] = real word(hd a);
	return r;
}

setf(h: ref Handle, t: ref Tf)
{
	h.tf = t;
	h.num = t.num;
	h.den = t.den;
}

# The transfer function is built the first time something needs it, so
# a script can set the numerator and the denominator in either order and
# never say "commit".
etf(ctxt: ref Context, h: ref Handle): ref Tf
{
	if (h.tf != nil)
		return h.tf;
	if (h.den == nil)
		ctxt.fail("control", "control: no denominator - use \"control <id> den ...\"");
	nu := h.num;
	if (nu == nil)
		nu = array[] of {1.0};
	(t, e) := ctl->tf(nu, h.den);
	if (e != nil)
		ctxt.fail("control", "control: " + e);
	h.tf = t;
	return t;
}

# Evenly spaced in the logarithm, from math(2).  An earlier version of
# this file computed the logarithm and the exponential itself, to avoid
# loading a module for two calls; that is inventing a numerical risk to
# save an include.
log10(x: real): real
{
	return math->log10(x);
}

pow10(x: real): real
{
	return math->pow(10.0, x);
}

remark(ctxt: ref Context, s: string)
{
	if (ctxt.options() & ctxt.INTERACTIVE)
		sys->print("%s\n", s);
}

newhandle(): ref Handle
{
	h := ref Handle(nexthandle++, nil, nil, nil, nil, 0, 0, nil);
	addhandle(h);
	return h;
}

ehandle(ctxt: ref Context, w: string): ref Handle
{
	h := gethandle(int w);
	if (h == nil)
		ctxt.fail("bad id", "control: unknown handle " + w);
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
