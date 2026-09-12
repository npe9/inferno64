implement Shellbuiltin;

# A shell interface to stats(2): a table of numbers, and the summaries
# and fits of it, without writing a Limbo program.
#
# The table is what makes this worth having.  A student's data is in a
# file of whitespace-separated numbers, and `read' takes it; everything
# after that names COLUMNS by number, so `stats $d linefit 0 1' fits the
# second column against the first.
#
# As with sh-circuit(1) and sh-control(1), anything that is a series
# comes back as one flat list, which is the shape sh-plot(1)'s `append'
# takes.

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
	sh: Sh;
	Listnode, Context: import sh;
	myself: Shellbuiltin;
include "stats.m";
	st: Stats;
	Line: import st;

Handle: adt {
	id:	int;
	ncols:	int;
	rows:	array of real;		# flat, ncols per row
	nrows:	int;
	line:	ref Line;
	coeff:	array of real;		# from polyfit or multifit
};

handles: array of list of ref Handle;
nexthandle := 0;

initbuiltin(ctxt: ref Context, shmod: Sh): string
{
	sys = load Sys Sys->PATH;
	sh = shmod;
	myself = load Shellbuiltin "$self";
	if (myself == nil)
		ctxt.fail("bad module", sys->sprint("stats: cannot load self: %r"));
	st = load Stats Stats->PATH;
	if (st == nil)
		ctxt.fail("bad module",
			sys->sprint("stats: cannot load %s: %r", Stats->PATH));
	st->init();
	handles = array[16] of list of ref Handle;
	ctxt.addbuiltin("stats", myself);
	ctxt.addsbuiltin("stats", myself);
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

USAGE: con "usage: stats (new|del|<id> ...) args...";
VERBS: con "usage: stats <id> (columns|data|read|clear|linefit|polyfit) args...";

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
	"columns" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: stats <id> columns n");
		n := int word(hd a);
		if (n < 1)
			ctxt.fail("usage", "stats: a table has at least one column");
		if (h.nrows > 0)
			ctxt.fail("stats", "stats: the table already has rows; say how many "+
				"columns before putting anything in it");
		h.ncols = n;
	"data" =>
		n := len a;
		if (n == 0)
			ctxt.fail("usage", "usage: stats <id> data value...");
		if (n % h.ncols != 0)
			ctxt.fail("stats", sys->sprint("stats: %d values is not a whole "+
				"number of rows of %d columns", n, h.ncols));
		v := array[n] of real;
		for (i := 0; a != nil; (a, i) = (tl a, i+1))
			v[i] = real word(hd a);
		addrows(h, v);
	"read" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: stats <id> read file");
		(v, err) := readnums(word(hd a));
		if (err != nil)
			ctxt.fail("stats", "stats: " + err);
		if (len v == 0)
			ctxt.fail("stats", "stats: there are no numbers in that file");
		if (len v % h.ncols != 0)
			ctxt.fail("stats", sys->sprint("stats: the file holds %d numbers, "+
				"which is not a whole number of rows of %d columns",
				len v, h.ncols));
		addrows(h, v);
	"clear" =>
		h.nrows = 0;
		h.line = nil;
		h.coeff = nil;
	"linefit" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: stats <id> linefit xcol ycol");
		x := ecol(ctxt, h, word(hd a));
		y := ecol(ctxt, h, word(hd tl a));
		(l, e) := st->linefit(x, y);
		if (e != nil)
			ctxt.fail("stats", "stats: " + e);
		h.line = l;
	"polyfit" =>
		if (len a != 3)
			ctxt.fail("usage", "usage: stats <id> polyfit xcol ycol degree");
		x := ecol(ctxt, h, word(hd a));
		y := ecol(ctxt, h, word(hd tl a));
		(c, e) := st->polyfit(x, y, int word(hd tl tl a));
		if (e != nil)
			ctxt.fail("stats", "stats: " + e);
		h.coeff = c;
	* =>
		ctxt.fail("usage", "stats: unknown command " + verb);
	}
	return nil;
}

SUSAGE: con "usage: stats <id> (rows|cols|column|table|mean|median|total|variance|stddev|popvariance|popstddev|min|max|quantile|covariance|correlation|line|coefficients|rsquared|predict|ttest1|ttest2|meanci|normalcdf|normalquantile|tcdf|tquantile) args...";

runsbuiltin(ctxt: ref Context, nil: Sh,
			argv: list of ref Listnode): list of ref Listnode
{
	if ((hd argv).word != "stats")
		return nil;
	argv = tl argv;
	if (argv == nil)
		ctxt.fail("usage", "usage: stats new");
	w := (hd argv).word;
	if (w == "new")
		return ref Listnode(nil, string newhandle().id) :: nil;
	if (!isnum(w))
		ctxt.fail("usage", "usage: stats new | stats <id> args...");
	h := ehandle(ctxt, w);
	rest := tl argv;
	if (rest == nil)
		ctxt.fail("usage", SUSAGE);
	verb := (hd rest).word;
	a := tl rest;
	case verb {
	"rows" =>
		return ref Listnode(nil, string h.nrows) :: nil;
	"cols" =>
		return ref Listnode(nil, string h.ncols) :: nil;
	"column" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: stats <id> column n");
		return nums(ecol(ctxt, h, word(hd a)));
	# the whole table, flat, row after row - which for a two-column
	# table is exactly what sh-plot's `append' wants for x and y
	"table" =>
		if (h.nrows == 0)
			ctxt.fail("stats", "stats: the table is empty");
		return nums(h.rows[0:h.nrows*h.ncols]);
	# the one-column summaries, which all take a column number
	"mean" or "median" or "total" or "variance" or "stddev" or
	"popvariance" or "popstddev" or "min" or "max" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: stats <id> " + verb + " col");
		c := ecol(ctxt, h, word(hd a));
		v := 0.0;
		case verb {
		"mean" =>		v = st->mean(c);
		"median" =>		v = st->median(c);
		"total" =>		v = st->total(c);
		"variance" =>		v = st->variance(c);
		"stddev" =>		v = st->stddev(c);
		"popvariance" =>	v = st->popvariance(c);
		"popstddev" =>		v = st->popstddev(c);
		"min" =>		v = st->minimum(c);
		"max" =>		v = st->maximum(c);
		}
		return num(v);
	"quantile" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: stats <id> quantile col p");
		return num(st->quantile(ecol(ctxt, h, word(hd a)), real word(hd tl a)));
	"covariance" or "correlation" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: stats <id> " + verb + " col col");
		x := ecol(ctxt, h, word(hd a));
		y := ecol(ctxt, h, word(hd tl a));
		if (verb == "covariance")
			return num(st->covariance(x, y));
		return num(st->correlation(x, y));
	# slope intercept r2 slopeerr intercepterr resid n
	"line" =>
		if (h.line == nil)
			ctxt.fail("stats", "stats: no line has been fitted - run "+
				"\"stats <id> linefit xcol ycol\" first");
		l := h.line;
		return ref Listnode(nil, sys->sprint("%g", l.slope)) ::
		       ref Listnode(nil, sys->sprint("%g", l.intercept)) ::
		       ref Listnode(nil, sys->sprint("%g", l.r2)) ::
		       ref Listnode(nil, sys->sprint("%g", l.slopeerr)) ::
		       ref Listnode(nil, sys->sprint("%g", l.intercepterr)) ::
		       ref Listnode(nil, sys->sprint("%g", l.resid)) ::
		       ref Listnode(nil, string l.n) :: nil;
	"coefficients" =>
		if (h.coeff == nil)
			ctxt.fail("stats", "stats: nothing has been fitted - run "+
				"\"stats <id> polyfit xcol ycol degree\" first");
		return nums(h.coeff);
	# How much of the variation whichever fit was last done accounts
	# for.  `line' carries this for a straight line; a polynomial fit
	# has no such record, and scoring it means evaluating it at every
	# x and comparing - which is what rsquared() is for.
	"rsquared" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: stats <id> rsquared xcol ycol");
		x := ecol(ctxt, h, word(hd a));
		y := ecol(ctxt, h, word(hd tl a));
		pred := array[len x] of real;
		i := 0;
		if (h.coeff != nil)
			for (i = 0; i < len x; i++)
				pred[i] = st->polyat(h.coeff, x[i]);
		else if (h.line != nil)
			for (i = 0; i < len x; i++)
				pred[i] = h.line.at(x[i]);
		else
			ctxt.fail("stats", "stats: nothing has been fitted to score");
		return num(st->rsquared(y, pred));
	# the fitted value at a point, from whichever fit was last done
	"predict" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: stats <id> predict x");
		x := real word(hd a);
		if (h.coeff != nil)
			return num(st->polyat(h.coeff, x));
		if (h.line != nil)
			return num(h.line.at(x));
		ctxt.fail("stats", "stats: nothing has been fitted to predict from");
	"ttest1" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: stats <id> ttest1 col mean");
		(t, e) := st->ttest1(ecol(ctxt, h, word(hd a)), real word(hd tl a));
		if (e != nil)
			ctxt.fail("stats", "stats: " + e);
		return ref Listnode(nil, sys->sprint("%g", t.statistic)) ::
		       ref Listnode(nil, sys->sprint("%g", t.df)) ::
		       ref Listnode(nil, sys->sprint("%g", t.p)) :: nil;
	"ttest2" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: stats <id> ttest2 col col");
		(t, e) := st->ttest2(ecol(ctxt, h, word(hd a)),
			ecol(ctxt, h, word(hd tl a)));
		if (e != nil)
			ctxt.fail("stats", "stats: " + e);
		return ref Listnode(nil, sys->sprint("%g", t.statistic)) ::
		       ref Listnode(nil, sys->sprint("%g", t.df)) ::
		       ref Listnode(nil, sys->sprint("%g", t.p)) :: nil;
	"meanci" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: stats <id> meanci col confidence");
		(lo, hi, e) := st->meanci(ecol(ctxt, h, word(hd a)), real word(hd tl a));
		if (e != nil)
			ctxt.fail("stats", "stats: " + e);
		return ref Listnode(nil, sys->sprint("%g", lo)) ::
		       ref Listnode(nil, sys->sprint("%g", hi)) :: nil;
	# the distributions, which need no table at all
	"normalcdf" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: stats <id> normalcdf x");
		return num(st->normalcdf(real word(hd a)));
	"normalquantile" =>
		if (len a != 1)
			ctxt.fail("usage", "usage: stats <id> normalquantile p");
		(v, e) := st->normalquantile(real word(hd a));
		if (e != nil)
			ctxt.fail("stats", "stats: " + e);
		return num(v);
	"tcdf" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: stats <id> tcdf t df");
		return num(st->tcdf(real word(hd a), real word(hd tl a)));
	"tquantile" =>
		if (len a != 2)
			ctxt.fail("usage", "usage: stats <id> tquantile p df");
		(v, e) := st->tquantile(real word(hd a), real word(hd tl a));
		if (e != nil)
			ctxt.fail("stats", "stats: " + e);
		return num(v);
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

ecol(ctxt: ref Context, h: ref Handle, w: string): array of real
{
	if (h.nrows == 0)
		ctxt.fail("stats", "stats: the table is empty");
	c := int w;
	if (c < 0 || c >= h.ncols)
		ctxt.fail("stats", sys->sprint("stats: there is no column %d; the table "+
			"has %d, numbered from 0", c, h.ncols));
	a := array[h.nrows] of real;
	for (i := 0; i < h.nrows; i++)
		a[i] = h.rows[i*h.ncols + c];
	return a;
}

addrows(h: ref Handle, v: array of real)
{
	n := len v / h.ncols;
	need := (h.nrows + n)*h.ncols;
	if (h.rows == nil || need > len h.rows) {
		cap := 2*need;
		if (cap < 128)
			cap = 128;
		a := array[cap] of real;
		if (h.rows != nil)
			a[0:] = h.rows[0:h.nrows*h.ncols];
		h.rows = a;
	}
	h.rows[h.nrows*h.ncols:] = v;
	h.nrows += n;
}

# Whitespace-separated numbers, however they are laid out: the rows of
# the table are made by the column count, not by the newlines, so a file
# with one number to a line reads the same as one with a row to a line.
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
		w := hd toks;
		# a comment runs to the end of the line, and tokenize has
		# already thrown the line endings away, so anything from a #
		# onwards would be read as a number.  Rather than half-handle
		# it, say so.
		if (w[0] == '#')
			return (nil, "the file has a # in it; this reads numbers only");
		a[i] = real w;
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
	h := ref Handle(nexthandle++, 1, nil, 0, nil, nil);
	addhandle(h);
	return h;
}

ehandle(ctxt: ref Context, w: string): ref Handle
{
	h := gethandle(int w);
	if (h == nil)
		ctxt.fail("bad id", "stats: unknown handle " + w);
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
