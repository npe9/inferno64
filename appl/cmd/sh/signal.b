implement Shellbuiltin;

# A shell interface to signal(2): build a signal, look at its spectrum,
# design a filter and run it, without writing a Limbo program.
#
# Frequency is in CYCLES PER SAMPLE throughout, 0 to 0.5, exactly as in
# signal(2) - a sampled signal does not know its own sample rate.
#
# Anything that is a series comes back from `trace' as one flat list,
# which is the shape sh-plot(1)'s `append' takes.

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "sh.m";
	sh: Sh;
	Listnode, Context: import sh;
	myself: Shellbuiltin;
include "signal.m";
	sig: Signal;
	Biquad: import sig;

Handle: adt {
	id:	int;
	x:	array of real;		# the samples
	n:	int;
	taps:	array of real;		# the FIR, if one is designed
	iir:	array of ref Biquad;	# or the IIR
	rows:	array of real;		# whatever series was last computed
	nrows:	int;
	ncols:	int;
	names:	string;
	seed:	int;
};

handles: array of list of ref Handle;
nexthandle := 0;

initbuiltin(ctxt: ref Context, shmod: Sh): string
{
	sys = load Sys Sys->PATH;
	sh = shmod;
	myself = load Shellbuiltin "$self";
	if (myself == nil)
		ctxt.fail("bad module", sys->sprint("signal: cannot load self: %r"));
	math = load Math Math->PATH;
	sig = load Signal Signal->PATH;
	if (sig == nil || math == nil)
		ctxt.fail("bad module",
			sys->sprint("signal: cannot load %s: %r", Signal->PATH));
	sig->init();
	handles = array[16] of list of ref Handle;
	ctxt.addbuiltin("signal", myself);
	ctxt.addsbuiltin("signal", myself);
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

USAGE: con "usage: signal (new|del|<id> ...) args...";
VERBS: con "usage: signal <id> (length|tone|noise|data|read|spectrum|fir|butter|onepole|filter|response|clear) args...";

windowof(ctxt: ref Context, w: string): int
{
	case w {
	"rect" or "rectangular" =>	return sig->RECT;
	"hann" =>			return sig->HANN;
	"hamming" =>			return sig->HAMMING;
	"blackman" =>			return sig->BLACKMAN;
	}
	ctxt.fail("usage", "signal: the windows are rect, hann, hamming and blackman");
	return 0;
}

kindof(ctxt: ref Context, w: string): int
{
	case w {
	"lowpass" =>	return sig->LOWPASS;
	"highpass" =>	return sig->HIGHPASS;
	"bandpass" =>	return sig->BANDPASS;
	"bandstop" =>	return sig->BANDSTOP;
	}
	ctxt.fail("usage", "signal: the kinds are lowpass, highpass, bandpass and bandstop");
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
	"length" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: signal <id> length n");
		n := int word(hd a);
		if (n < 2)
			ctxt.fail("usage", "signal: a signal of fewer than two samples has "+
				"no spectrum worth the name");
		h.x = array[n] of real;
		for (i := 0; i < n; i++)
			h.x[i] = 0.0;
		h.n = n;
	# a sinusoid ADDED to whatever is already there, so a test signal
	# is built by saying what is in it
	"tone" =>
		if (len a != 2 && len a != 3)
			ctxt.fail("usage", "usage: signal <id> tone amplitude frequency [phase]");
		esignal(ctxt, h);
		amp := real word(hd a);
		f := real word(hd tl a);
		ph := 0.0;
		if (len a == 3)
			ph = real word(hd tl tl a);
		if (f < 0.0 || f > 0.5)
			ctxt.fail("usage", "signal: a frequency is in cycles per sample, "+
				"from 0 to 0.5, which is Nyquist");
		for (i := 0; i < h.n; i++)
			h.x[i] += amp*math->cos(2.0*math->Pi*f*real i + ph);
	"noise" =>
		if (len a != 1 && len a != 2)
			ctxt.fail("usage", "usage: signal <id> noise amplitude [seed]");
		esignal(ctxt, h);
		amp := real word(hd a);
		if (len a == 2)
			h.seed = int word(hd tl a);
		for (i := 0; i < h.n; i++) {
			h.seed = (h.seed*1103515245 + 12345) & 16r7fffffff;
			h.x[i] += amp*(real(h.seed % 20000 - 10000)/10000.0);
		}
	"data" =>
		if (len a == 0)
			ctxt.fail("usage", "usage: signal <id> data value...");
		v := array[len a] of real;
		for (i := 0; a != nil; (a, i) = (tl a, i+1))
			v[i] = real word(hd a);
		h.x = v;
		h.n = len v;
	"read" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: signal <id> read file");
		(v, err) := readnums(word(hd a));
		if (err != nil)
			ctxt.fail("signal", "signal: " + err);
		if (len v < 2)
			ctxt.fail("signal", "signal: fewer than two numbers in that file");
		h.x = v;
		h.n = len v;
	# the one-sided power spectrum, scaled so a sinusoid of amplitude A
	# reads A*A/2 in its bin whatever the window
	"spectrum" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: signal <id> spectrum window");
		esignal(ctxt, h);
		p := sig->periodogram(h.x[0:h.n], windowof(ctxt, word(hd a)));
		h.ncols = 2;
		h.names = "f power";
		h.rows = array[2*len p] of real;
		for (i := 0; i < len p; i++) {
			h.rows[2*i] = real i/real h.n;
			h.rows[2*i+1] = p[i];
		}
		h.nrows = len p;
	"fir" =>
		if (len a != 4 && len a != 5)
			ctxt.fail("usage", "usage: signal <id> fir kind ntaps f1 [f2] window");
		kind := kindof(ctxt, word(hd a));
		ntaps := int word(hd tl a);
		f1 := real word(hd tl tl a);
		f2 := 0.0;
		win := "";
		if (len a == 5) {
			f2 = real word(hd tl tl tl a);
			win = word(hd tl tl tl tl a);
		} else
			win = word(hd tl tl tl a);
		(t, e) := sig->firdesign(kind, ntaps, f1, f2, windowof(ctxt, win));
		if (e != nil)
			ctxt.fail("signal", "signal: " + e);
		h.taps = t;
		h.iir = nil;
	"butter" =>
		if (len a != 3)
			ctxt.fail("usage", "usage: signal <id> butter kind order fc");
		(b, e) := sig->butterworth(kindof(ctxt, word(hd a)),
			int word(hd tl a), real word(hd tl tl a));
		if (e != nil)
			ctxt.fail("signal", "signal: " + e);
		h.iir = b;
		h.taps = nil;
	"onepole" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: signal <id> onepole fc");
		(b, e) := sig->onepole(real word(hd a));
		if (e != nil)
			ctxt.fail("signal", "signal: " + e);
		h.iir = b;
		h.taps = nil;
	# run whichever filter is designed over the samples, in place
	"filter" =>
		esignal(ctxt, h);
		if (h.taps != nil)
			h.x = sig->fir(h.x[0:h.n], h.taps);
		else if (h.iir != nil) {
			for (i := 0; i < len h.iir; i++)
				h.iir[i].reset();
			h.x = sig->runiir(h.iir, h.x[0:h.n]);
		} else
			ctxt.fail("signal", "signal: no filter is designed - run \"signal "+
				"<id> fir ...\" or \"signal <id> butter ...\" first");
		h.n = len h.x;
	# the designed filter's own frequency response, from 0 to Nyquist
	"response" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: signal <id> response n");
		nf := int word(hd a);
		if (nf < 2)
			ctxt.fail("usage", "signal: a response needs at least two points");
		m, p: array of real;
		if (h.taps != nil)
			(m, p) = sig->firresponse(h.taps, nf);
		else if (h.iir != nil)
			(m, p) = sig->iirresponse(h.iir, nf);
		else
			ctxt.fail("signal", "signal: no filter is designed");
		h.ncols = 3;
		h.names = "f mag phase";
		h.rows = array[3*nf] of real;
		for (i := 0; i < nf; i++) {
			h.rows[3*i] = 0.5*real i/real(nf-1);
			h.rows[3*i+1] = m[i];
			h.rows[3*i+2] = p[i];
		}
		h.nrows = nf;
	"clear" =>
		h.nrows = 0;
	* =>
		ctxt.fail("usage", "signal: unknown command " + verb);
	}
	return nil;
}

SUSAGE: con "usage: signal <id> (samples|length|taps|trace|names|rows|columns|binfreq|realbins|peak) args...";

runsbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode): list of ref Listnode
{
	if ((hd argv).word != "signal")
		return nil;
	argv = tl argv;
	if (argv == nil)
		ctxt.fail("usage", "usage: signal new");
	w := (hd argv).word;
	if (w == "new")
		return ref Listnode(nil, string newhandle().id) :: nil;
	if (!isnum(w))
		ctxt.fail("usage", "usage: signal new | signal <id> args...");
	h := ehandle(ctxt, w);
	rest := tl argv;
	if (rest == nil)
		ctxt.fail("usage", SUSAGE);
	a := tl rest;
	case (hd rest).word {
	"samples" =>
		esignal(ctxt, h);
		return nums(h.x[0:h.n]);
	# the samples paired with their index, for plotting against time
	"waveform" =>
		esignal(ctxt, h);
		r := array[2*h.n] of real;
		for (i := 0; i < h.n; i++) {
			r[2*i] = real i;
			r[2*i+1] = h.x[i];
		}
		return nums(r);
	"length" =>
		return ref Listnode(nil, string h.n) :: nil;
	"taps" =>
		if (h.taps == nil)
			ctxt.fail("signal", "signal: no FIR filter is designed");
		return nums(h.taps);
	"trace" =>
		l: list of ref Listnode;
		for (i := h.nrows*h.ncols - 1; i >= 0; i--)
			l = ref Listnode(nil, sys->sprint("%g", h.rows[i])) :: l;
		return l;
	"names" =>
		l: list of ref Listnode;
		(nil, toks) := sys->tokenize(h.names, " ");
		for (; toks != nil; toks = tl toks)
			l = ref Listnode(nil, hd toks) :: l;
		return rev(l);
	"rows" =>
		return ref Listnode(nil, string h.nrows) :: nil;
	"columns" =>
		return ref Listnode(nil, string h.ncols) :: nil;
	"realbins" =>
		return ref Listnode(nil, string sig->realbins(h.n)) :: nil;
	"binfreq" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: signal <id> binfreq k");
		return num(sig->binfreq(int word(hd a), h.n));
	# where the largest value of the last computed series is, and what
	# it is: for a spectrum that is the strongest frequency present,
	# which is the question a spectrum is usually asked
	"peak" =>
		if (h.nrows == 0)
			ctxt.fail("signal", "signal: nothing has been computed to find a "+
				"peak in");
		col := 1;
		if (len a == 1)
			col = int word(hd a);
		if (col < 0 || col >= h.ncols)
			ctxt.fail("signal", "signal: no such column");
		best := 0;
		for (i := 1; i < h.nrows; i++)
			if (h.rows[i*h.ncols + col] > h.rows[best*h.ncols + col])
				best = i;
		l: list of ref Listnode;
		for (i = h.ncols - 1; i >= 0; i--)
			l = ref Listnode(nil, sys->sprint("%g", h.rows[best*h.ncols + i])) :: l;
		return l;
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

nums(a: array of real): list of ref Listnode
{
	l: list of ref Listnode;
	for (i := len a - 1; i >= 0; i--)
		l = ref Listnode(nil, sys->sprint("%g", a[i])) :: l;
	return l;
}

esignal(ctxt: ref Context, h: ref Handle)
{
	if (h.n == 0)
		ctxt.fail("signal", "signal: there is no signal - use \"signal <id> "+
			"length n\", \"data ...\" or \"read file\" first");
}

readnums(path: string): (array of real, string)
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
	(nw, toks) := sys->tokenize(s, " \t\r\n");
	a := array[nw] of real;
	for (i := 0; toks != nil; (toks, i) = (tl toks, i+1)) {
		if ((hd toks)[0] == '#')
			return (nil, "the file has a # in it; this reads numbers only");
		a[i] = real hd toks;
	}
	return (a, nil);
}

remark(ctxt: ref Context, s: string)
{
	if (ctxt.options() & ctxt.INTERACTIVE)
		sys->print("%s\n", s);
}

newhandle(): ref Handle
{
	h := ref Handle(nexthandle++, nil, 0, nil, nil, nil, 0, 0, nil, 12345);
	addhandle(h);
	return h;
}

ehandle(ctxt: ref Context, w: string): ref Handle
{
	h := gethandle(int w);
	if (h == nil)
		ctxt.fail("bad id", "signal: unknown handle " + w);
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
