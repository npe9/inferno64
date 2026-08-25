implement Bc;

# A Limbo-native workalike for a bounded subset of bc(1), the arbitrary-
# precision calculator language - see doc/plan9-port.md's "Rule: Limbo-
# native, in a separate bindable tree". bc is an infix front end over
# exactly the same exact-fixed-point arithmetic p9/cmd/dc.b already
# implements and verified against the host oracle (add/sub take the max
# of operand scales; multiply's natural scale is the sum of operand
# scales, truncated toward zero only if that sum exceeds max(scale
# register, operand scales); divide always truncates to the scale
# register; a%b is a - (a/b)*b at the current scale, in that order) -
# copied here rather than shared via a module so this file stays
# independently readable and dc.b's already-verified code is untouched.
#
# NOT arbitrary precision, despite the name above: Limbo's `big` is a
# 64-bit signed integer (limbo/limbo.h: "Tbig, /* 64 bit int */"; real
# arbitrary-precision integers are module/ipints.m's IPint, a different
# type) - dc.b's own header comment carries the full correction and the
# reproducer that found it (`10k 2 v p` silently wrapping to a nonsense
# negative number at scale 10). bigmul/bigadd/bigsub/bigneg below are
# copied from that same fix: they turn the silent 64-bit wraparound
# into a loud "precision exceeded" failure instead of a wrong answer -
# see p9/man/1/bc's BUGS for the measured threshold (same as dc's:
# roughly 18-19 significant decimal digits, matching signed-64-bit
# range).
#
# The host oracle here is Gavin Howard's bc (bc 7.x, the common /usr/bin
# /bc on a modern Linux/macOS host, not the historical AT&T/GNU bc that
# most bc manuals describe) - every behavioural rule below (bare
# expressions print, assignments don't; unary minus binds TIGHTER than
# ^, so `-2^2` is `(-2)^2` = 4, not -4; length(x) counts the decimal
# digits of x's mantissa, ignoring scale entirely; scale(x) is just x's
# own fraction-digit count) was checked against it with targeted probes,
# not read off a bc manual from memory - same discipline as awk/dc/m4.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "arg.m";

Bc: module
{
	init:		fn(ctxt: ref Context, argv: list of string);

	# in-process test seam, matching awk.b/dc.b/m4.b's runstring.
	runstring:	fn(prog: string): string;
};

stdin, stdout, stderr: ref FD;

# --- exact fixed-point arithmetic, copied from p9/cmd/dc.b verbatim ---

Dnum: adt
{
	m:	big;	# mantissa: the value * 10^f, exact
	f:	int;	# number of fraction digits
};

scale:	int;

zero(): Dnum
{
	return Dnum(big 0, 0);
}

bigmul(a: big, b: big): big
{
	r := a * b;
	if(a != big 0 && r/a != b)
		fail("precision exceeded (big is a 64-bit integer here, not arbitrary precision)");
	return r;
}

bigadd(a: big, b: big): big
{
	r := a + b;
	if((b > big 0 && r < a) || (b < big 0 && r > a))
		fail("precision exceeded (big is a 64-bit integer here, not arbitrary precision)");
	return r;
}

bigsub(a: big, b: big): big
{
	return bigadd(a, bigneg(b));
}

bigneg(a: big): big
{
	r := -a;
	if(a != big 0 && (r > big 0) == (a > big 0))
		fail("precision exceeded (big is a 64-bit integer here, not arbitrary precision)");
	return r;
}

big10pow(n: int): big
{
	r := big 1;
	for(i := 0; i < n; i++)
		r = bigmul(r, big 10);
	return r;
}

scaleup(d: Dnum, tf: int): big
{
	if(d.f == tf)
		return d.m;
	return bigmul(d.m, big10pow(tf - d.f));
}

truncto(m: big, f: int, nf: int): big
{
	if(nf >= f)
		return m;
	return m / big10pow(f - nf);
}

dadd(a: Dnum, b: Dnum): Dnum
{
	tf := a.f;
	if(b.f > tf)
		tf = b.f;
	return Dnum(bigadd(scaleup(a, tf), scaleup(b, tf)), tf);
}

dsub(a: Dnum, b: Dnum): Dnum
{
	tf := a.f;
	if(b.f > tf)
		tf = b.f;
	return Dnum(bigsub(scaleup(a, tf), scaleup(b, tf)), tf);
}

dmul(a: Dnum, b: Dnum): Dnum
{
	m := bigmul(a.m, b.m);
	sumf := a.f + b.f;
	capf := scale;
	if(a.f > capf)
		capf = a.f;
	if(b.f > capf)
		capf = b.f;
	if(sumf > capf){
		m = truncto(m, sumf, capf);
		sumf = capf;
	}
	return Dnum(m, sumf);
}

ddiv(a: Dnum, b: Dnum): Dnum
{
	if(b.m == big 0)
		fail("divide by zero");
	num := bigmul(a.m, big10pow(scale + b.f));
	den := bigmul(b.m, big10pow(a.f));
	return Dnum(num / den, scale);
}

dmod(a: Dnum, b: Dnum): Dnum
{
	q := ddiv(a, b);
	return dsub(a, dmul(q, b));
}

dpow(a: Dnum, e: Dnum): Dnum
{
	if(e.f != 0)
		fail("exponent must be an integer");
	n := int e.m;
	neg := n < 0;
	if(neg)
		n = -n;
	r := Dnum(big 1, 0);
	for(i := 0; i < n; i++)
		r = dmul(r, a);
	if(neg)
		r = ddiv(Dnum(big 1, 0), r);
	return r;
}

bigisqrt(n: big): big
{
	if(n == big 0)
		return big 0;
	x := n;
	y := (x + big 1) / big 2;
	while(y < x){
		x = y;
		y = (x + n/x) / big 2;
	}
	return x;
}

dsqrt(a: Dnum): Dnum
{
	if(a.m < big 0)
		fail("square root of a negative number");
	shift := 2*scale - a.f;
	n: big;
	if(shift >= 0)
		n = bigmul(a.m, big10pow(shift));
	else
		n = a.m / big10pow(-shift);
	return Dnum(bigisqrt(n), scale);
}

bigstr(m: big): string
{
	if(m == big 0)
		return "0";
	s := "";
	for(; m > big 0; m /= big 10){
		d := int (m % big 10);
		s[len s] = '0' + d;
	}
	t := "";
	for(i := len s - 1; i >= 0; i--)
		t[len t] = s[i];
	return t;
}

fmtnum(d: Dnum): string
{
	if(d.m == big 0)
		return "0";
	neg := d.m < big 0;
	m := d.m;
	if(neg)
		m = -m;
	s := bigstr(m);
	f := d.f;
	if(f == 0){
		if(neg)
			return "-" + s;
		return s;
	}
	while(len s < f+1)
		s = "0" + s;
	intpart := s[0:len s - f];
	fracpart := s[len s - f:];
	out := "";
	if(intpart != "0")
		out += intpart;
	out += "." + fracpart;
	if(neg)
		out = "-" + out;
	return out;
}

# length(x): number of decimal digits in x's mantissa, ignoring scale
# entirely (checked: length(0.001) == 1, not 4 - confirmed against the
# host oracle, not assumed).
dlength(d: Dnum): int
{
	m := d.m;
	if(m < big 0)
		m = -m;
	return len bigstr(m);
}

# --- lexer ---

# token kinds
TNUM, TIDENT, TPLUS, TMINUS, TSTAR, TSLASH, TPCT, TCARET, TLPAREN, TRPAREN,
TLBRACE, TRBRACE, TSEMI, TCOMMA, TASSIGN, TEQ, TNE, TLT, TGT, TLE, TGE,
TANDAND, TOROR, TNOT, TPLUSEQ, TMINUSEQ, TSTAREQ, TSLASHEQ, TPCTEQ, TCARETEQ,
TINC, TDEC,
TEOF: con iota;

Token: adt
{
	kind:	int;
	s:	string;	# for TIDENT
	num:	Dnum;	# for TNUM
};

toks:	array of Token;
ntok:	int;
pos:	int;

isdig(c: int): int
{
	return c >= '0' && c <= '9';
}

isidstart(c: int): int
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

isidchar(c: int): int
{
	return isidstart(c) || isdig(c);
}

strtobig(s: string): big
{
	m := big 0;
	for(i := 0; i < len s; i++)
		m = m*big 10 + big (s[i] - '0');
	return m;
}

lex(src: string)
{
	# NB: the accumulator below is deliberately not called `tl` -
	# that shadows Limbo's own list-tail operator and produces very
	# confusing errors (the same class of gotcha as `fn` being
	# reserved, noted in p9/cmd/awk.b).
	toklist: list of Token;
	n := len src;
	i := 0;
	while(i < n){
		c := src[i];
		if(c == ' ' || c == '\t' || c == '\r'){
			i++;
			continue;
		}
		if(c == '\n'){
			toklist = Token(TSEMI, nil, zero()) :: toklist;
			i++;
			continue;
		}
		if(c == '/' && i+1 < n && src[i+1] == '*'){
			i += 2;
			while(i+1 < n && !(src[i] == '*' && src[i+1] == '/'))
				i++;
			i += 2;
			continue;
		}
		if(isdig(c) || c == '.'){
			start := i;
			while(i < n && isdig(src[i]))
				i++;
			f := 0;
			if(i < n && src[i] == '.'){
				i++;
				fs := i;
				while(i < n && isdig(src[i]))
					i++;
				f = i - fs;
			}
			digits := "";
			for(j := start; j < i; j++)
				if(src[j] != '.')
					digits[len digits] = src[j];
			if(digits == "")
				digits = "0";
			toklist = Token(TNUM, nil, Dnum(strtobig(digits), f)) :: toklist;
			continue;
		}
		if(isidstart(c)){
			start := i;
			while(i < n && isidchar(src[i]))
				i++;
			toklist = Token(TIDENT, src[start:i], zero()) :: toklist;
			continue;
		}
		# two-character operators before their one-character prefixes
		if(c == '=' && i+1 < n && src[i+1] == '='){
			toklist = Token(TEQ, nil, zero()) :: toklist; i += 2; continue;
		}
		if(c == '!' && i+1 < n && src[i+1] == '='){
			toklist = Token(TNE, nil, zero()) :: toklist; i += 2; continue;
		}
		if(c == '<' && i+1 < n && src[i+1] == '='){
			toklist = Token(TLE, nil, zero()) :: toklist; i += 2; continue;
		}
		if(c == '>' && i+1 < n && src[i+1] == '='){
			toklist = Token(TGE, nil, zero()) :: toklist; i += 2; continue;
		}
		if(c == '&' && i+1 < n && src[i+1] == '&'){
			toklist = Token(TANDAND, nil, zero()) :: toklist; i += 2; continue;
		}
		if(c == '|' && i+1 < n && src[i+1] == '|'){
			toklist = Token(TOROR, nil, zero()) :: toklist; i += 2; continue;
		}
		if(c == '+' && i+1 < n && src[i+1] == '='){
			toklist = Token(TPLUSEQ, nil, zero()) :: toklist; i += 2; continue;
		}
		if(c == '-' && i+1 < n && src[i+1] == '='){
			toklist = Token(TMINUSEQ, nil, zero()) :: toklist; i += 2; continue;
		}
		if(c == '+' && i+1 < n && src[i+1] == '+'){
			toklist = Token(TINC, nil, zero()) :: toklist; i += 2; continue;
		}
		if(c == '-' && i+1 < n && src[i+1] == '-'){
			toklist = Token(TDEC, nil, zero()) :: toklist; i += 2; continue;
		}
		if(c == '*' && i+1 < n && src[i+1] == '='){
			toklist = Token(TSTAREQ, nil, zero()) :: toklist; i += 2; continue;
		}
		if(c == '/' && i+1 < n && src[i+1] == '='){
			toklist = Token(TSLASHEQ, nil, zero()) :: toklist; i += 2; continue;
		}
		if(c == '%' && i+1 < n && src[i+1] == '='){
			toklist = Token(TPCTEQ, nil, zero()) :: toklist; i += 2; continue;
		}
		if(c == '^' && i+1 < n && src[i+1] == '='){
			toklist = Token(TCARETEQ, nil, zero()) :: toklist; i += 2; continue;
		}
		k := -1;
		case c {
		'+' => k = TPLUS;
		'-' => k = TMINUS;
		'*' => k = TSTAR;
		'/' => k = TSLASH;
		'%' => k = TPCT;
		'^' => k = TCARET;
		'(' => k = TLPAREN;
		')' => k = TRPAREN;
		'{' => k = TLBRACE;
		'}' => k = TRBRACE;
		';' => k = TSEMI;
		',' => k = TCOMMA;
		'=' => k = TASSIGN;
		'<' => k = TLT;
		'>' => k = TGT;
		'!' => k = TNOT;
		}
		if(k < 0)
			fail(sys->sprint("bad character '%c'", c));
		toklist = Token(k, nil, zero()) :: toklist;
		i++;
	}
	toklist = Token(TEOF, nil, zero()) :: toklist;
	r: list of Token;
	for(l1 := toklist; l1 != nil; l1 = tl l1)
		r = hd l1 :: r;
	toks = array[len r] of Token;
	i = 0;
	for(l2 := r; l2 != nil; l2 = tl l2){
		toks[i] = hd l2;
		i++;
	}
	ntok = len toks;
	pos = 0;
}

cur(): Token
{
	return toks[pos];
}

advance()
{
	if(pos < ntok-1)
		pos++;
}

expect(k: int, what: string)
{
	if(cur().kind != k)
		fail("expected " + what);
	advance();
}

# skip statement separators (newline/semicolon), which may repeat
skipseps()
{
	while(cur().kind == TSEMI)
		advance();
}

# --- AST ---

Expr: adt
{
	pick {
	Num =>
		v:	Dnum;
	Var =>
		name:	string;
	Assign =>
		name:	string;
		op:	int;	# TASSIGN or a compound-assign token
		e:	ref Expr;
	Bin =>
		op:	int;
		l, r:	ref Expr;
	Un =>
		op:	int;
		e:	ref Expr;
	Not =>
		e:	ref Expr;
	Call =>
		name:	string;
		args:	list of ref Expr;
	Builtin =>
		name:	string;	# "sqrt", "length", "scale"
		arg:	ref Expr;
	ScaleVar =>
		unused:	int;	# no real payload; a pick tag needs a field
	PostIncDec =>
		name:	string;
		op:	int;	# TINC or TDEC - postfix only, see BUGS
	}
};

Stmt: adt
{
	pick {
	SExpr =>
		e:	ref Expr;
	SIf =>
		cond:	ref Expr;
		then:	list of ref Stmt;
		els:	list of ref Stmt;	# nil if no else
	SWhile =>
		cond:	ref Expr;
		body:	list of ref Stmt;
	SFor =>
		init:	ref Expr;	# may be nil
		cond:	ref Expr;	# may be nil (treated as true)
		incr:	ref Expr;	# may be nil
		body:	list of ref Stmt;
	SReturn =>
		e:	ref Expr;	# nil for bare `return`
	SAuto =>
		names:	list of string;
	}
};

Func: adt
{
	name:	string;
	params:	list of string;
	body:	list of ref Stmt;
};

funcs:		list of ref Func;
vars:		list of (string, Dnum);	# most-recently-bound first

findfunc(name: string): ref Func
{
	for(l := funcs; l != nil; l = tl l)
		if((hd l).name == name)
			return hd l;
	return nil;
}

# variable storage - a flat association list. `vars` is a `list of
# (string, Dnum)`, not an array, so "find the i-th cell" is a walk, not
# an index; lookupvar()/setvar() below each do exactly one walk rather
# than going through a separate integer-index step.

# (found, value) - found is 0 for a name never assigned.
lookupvar(name: string): (int, Dnum)
{
	for(l := vars; l != nil; l = tl l){
		(nm, v) := hd l;
		if(nm == name)
			return (1, v);
	}
	return (0, zero());
}

getvar(name: string): Dnum
{
	(nil, v) := lookupvar(name);
	return v;	# uninitialized variables read as 0, matching lookupvar's default
}

setvar(name: string, v: Dnum)
{
	found := 0;
	r: list of (string, Dnum);
	for(l := vars; l != nil; l = tl l){
		(nm, ov) := hd l;
		if(nm == name){
			r = (nm, v) :: r;
			found = 1;
		} else
			r = (nm, ov) :: r;
	}
	if(!found){
		vars = (name, v) :: vars;
		return;
	}
	vl: list of (string, Dnum);
	for(; r != nil; r = tl r)
		vl = hd r :: vl;
	vars = vl;
}

# --- parser ---

parseprogram(): list of ref Stmt
{
	stmts: list of ref Stmt;
	skipseps();
	while(cur().kind != TEOF){
		if(cur().kind == TIDENT && cur().s == "define"){
			parsedefine();
		} else
			stmts = parsestmt() :: stmts;
		skipseps();
	}
	r: list of ref Stmt;
	for(; stmts != nil; stmts = tl stmts)
		r = hd stmts :: r;
	return r;
}

parsedefine()
{
	advance();	# "define"
	if(cur().kind != TIDENT)
		fail("define needs a function name");
	name := cur().s;
	advance();
	expect(TLPAREN, "(");
	params: list of string;
	if(cur().kind != TRPAREN){
		for(;;){
			if(cur().kind != TIDENT)
				fail("bad parameter name");
			params = cur().s :: params;
			advance();
			if(cur().kind == TCOMMA){
				advance();
				continue;
			}
			break;
		}
	}
	expect(TRPAREN, ")");
	rp: list of string;
	for(; params != nil; params = tl params)
		rp = hd params :: rp;
	skipseps();
	expect(TLBRACE, "{");
	body := parsestmtlist();
	expect(TRBRACE, "}");
	funcs = ref Func(name, rp, body) :: funcs;
}

parseblock(): list of ref Stmt
{
	skipseps();
	if(cur().kind == TLBRACE){
		advance();
		s := parsestmtlist();
		expect(TRBRACE, "}");
		return s;
	}
	return parsestmt() :: nil;
}

parsestmtlist(): list of ref Stmt
{
	stmts: list of ref Stmt;
	skipseps();
	while(cur().kind != TRBRACE && cur().kind != TEOF){
		stmts = parsestmt() :: stmts;
		skipseps();
	}
	r: list of ref Stmt;
	for(; stmts != nil; stmts = tl stmts)
		r = hd stmts :: r;
	return r;
}

parsestmt(): ref Stmt
{
	if(cur().kind == TIDENT){
		case cur().s {
		"if" =>
			advance();
			expect(TLPAREN, "(");
			c := parseexpr();
			expect(TRPAREN, ")");
			then := parseblock();
			els: list of ref Stmt;
			skipseps();
			if(cur().kind == TIDENT && cur().s == "else"){
				advance();
				els = parseblock();
			}
			return ref Stmt.SIf(c, then, els);
		"while" =>
			advance();
			expect(TLPAREN, "(");
			c := parseexpr();
			expect(TRPAREN, ")");
			body := parseblock();
			return ref Stmt.SWhile(c, body);
		"for" =>
			advance();
			expect(TLPAREN, "(");
			ini: ref Expr;
			if(cur().kind != TSEMI)
				ini = parseexpr();
			expect(TSEMI, ";");
			c: ref Expr;
			if(cur().kind != TSEMI)
				c = parseexpr();
			expect(TSEMI, ";");
			inc: ref Expr;
			if(cur().kind != TRPAREN)
				inc = parseexpr();
			expect(TRPAREN, ")");
			body := parseblock();
			return ref Stmt.SFor(ini, c, inc, body);
		"return" =>
			advance();
			if(cur().kind == TSEMI || cur().kind == TRBRACE || cur().kind == TEOF)
				return ref Stmt.SReturn(nil);
			# `return (expr)` and `return expr` are both accepted
			# since parseexpr()/parseprimary() already treat a
			# leading '(' as ordinary grouping; a bare `return`
			# with no expression at all is handled above.
			e := parseexpr();
			return ref Stmt.SReturn(e);
		"auto" =>
			advance();
			names: list of string;
			for(;;){
				if(cur().kind != TIDENT)
					fail("bad auto variable name");
				names = cur().s :: names;
				advance();
				if(cur().kind == TCOMMA){
					advance();
					continue;
				}
				break;
			}
			rn: list of string;
			for(; names != nil; names = tl names)
				rn = hd names :: rn;
			return ref Stmt.SAuto(rn);
		}
	}
	if(cur().kind == TLBRACE){
		advance();
		s := parsestmtlist();
		expect(TRBRACE, "}");
		# a brace-block used where a statement is expected: fold
		# into a single SIf(true,...)-free wrapper isn't needed
		# since callers (parseblock) already unwrap the common
		# case; represent a bare nested block as an always-true if.
		return ref Stmt.SIf(ref Expr.Num(Dnum(big 1, 0)), s, nil);
	}
	e := parseexpr();
	return ref Stmt.SExpr(e);
}

# precedence, low to high: assignment > || > && > relational > additive
# > multiplicative > unary minus > power > primary. Relational/&&/||
# are accepted here unconditionally (used both in if/while conditions
# and, same as the real oracle only inside parens, as general
# subexpressions) - seebc's man page BUGS for the one corner
# deliberately not replicated (a bare unparenthesized assignment mixed
# with a relational operator at top level parses differently in the
# real oracle; this parser requires parens there instead).
parseexpr(): ref Expr
{
	return parseassign();
}

parseassign(): ref Expr
{
	# assignment is right-associative and only valid when the left
	# side is a bare identifier - look ahead for that shape.
	if(cur().kind == TIDENT && !iskeyword(cur().s)){
		save := pos;
		name := cur().s;
		advance();
		op := cur().kind;
		if(op == TASSIGN || op == TPLUSEQ || op == TMINUSEQ ||
		   op == TSTAREQ || op == TSLASHEQ || op == TPCTEQ || op == TCARETEQ){
			advance();
			rhs := parseassign();
			return ref Expr.Assign(name, op, rhs);
		}
		pos = save;
	}
	return parseor();
}

iskeyword(s: string): int
{
	case s {
	"if" or "else" or "while" or "for" or "return" or "auto" or "define" =>
		return 1;
	}
	return 0;
}

parseor(): ref Expr
{
	l := parseand();
	while(cur().kind == TOROR){
		advance();
		r := parseand();
		l = ref Expr.Bin(TOROR, l, r);
	}
	return l;
}

parseand(): ref Expr
{
	l := parsenot();
	while(cur().kind == TANDAND){
		advance();
		r := parsenot();
		l = ref Expr.Bin(TANDAND, l, r);
	}
	return l;
}

parsenot(): ref Expr
{
	if(cur().kind == TNOT){
		advance();
		return ref Expr.Not(parsenot());
	}
	return parserel();
}

parserel(): ref Expr
{
	l := parseadd();
	case cur().kind {
	TEQ or TNE or TLT or TGT or TLE or TGE =>
		op := cur().kind;
		advance();
		r := parseadd();
		return ref Expr.Bin(op, l, r);
	}
	return l;
}

parseadd(): ref Expr
{
	l := parsemul();
	for(;;){
		if(cur().kind == TPLUS){
			advance();
			l = ref Expr.Bin(TPLUS, l, parsemul());
		} else if(cur().kind == TMINUS){
			advance();
			l = ref Expr.Bin(TMINUS, l, parsemul());
		} else
			break;
	}
	return l;
}

parsemul(): ref Expr
{
	l := parsepow();
	for(;;){
		case cur().kind {
		TSTAR or TSLASH or TPCT =>
			op := cur().kind;
			advance();
			l = ref Expr.Bin(op, l, parsepow());
		* =>
			return l;
		}
	}
}

# unary minus binds TIGHTER than ^ in the real oracle (`-2^2` == 4, i.e.
# `(-2)^2`, not -4 i.e. `-(2^2)`) - confirmed by probe, not assumed from
# the POSIX bc grammar most manuals describe. Getting this right needs
# unary minus to apply to the BASE only, so parseunarybase (not this
# function) is what actually consumes a leading '-'; parsepow calls it
# for both the base and, recursively, the exponent, so `2^-2` (a
# negative exponent, confirmed valid against the oracle) still works.
parsepow(): ref Expr
{
	l := parseunarybase();
	if(cur().kind == TCARET){
		advance();
		r := parsepow();	# right-assoc
		return ref Expr.Bin(TCARET, l, r);
	}
	return l;
}

parseunarybase(): ref Expr
{
	if(cur().kind == TMINUS){
		advance();
		return ref Expr.Un(TMINUS, parseunarybase());
	}
	return parseprimary();
}

parseprimary(): ref Expr
{
	t := cur();
	if(t.kind == TNUM){
		advance();
		return ref Expr.Num(t.num);
	}
	if(t.kind == TLPAREN){
		advance();
		e := parseexpr();
		expect(TRPAREN, ")");
		return e;
	}
	if(t.kind == TIDENT){
		name := t.s;
		case name {
		"sqrt" or "length" =>
			advance();
			expect(TLPAREN, "(");
			a := parseexpr();
			expect(TRPAREN, ")");
			return ref Expr.Builtin(name, a);
		"scale" =>
			advance();
			if(cur().kind == TLPAREN){
				advance();
				a := parseexpr();
				expect(TRPAREN, ")");
				return ref Expr.Builtin(name, a);
			}
			return ref Expr.ScaleVar(0);
		}
		advance();
		if(cur().kind == TLPAREN){
			advance();
			args: list of ref Expr;
			if(cur().kind != TRPAREN){
				for(;;){
					args = parseexpr() :: args;
					if(cur().kind == TCOMMA){
						advance();
						continue;
					}
					break;
				}
			}
			expect(TRPAREN, ")");
			ra: list of ref Expr;
			for(; args != nil; args = tl args)
				ra = hd args :: ra;
			return ref Expr.Call(name, ra);
		}
		if(cur().kind == TINC || cur().kind == TDEC){
			op := cur().kind;
			advance();
			return ref Expr.PostIncDec(name, op);
		}
		return ref Expr.Var(name);
	}
	fail("expected an expression");
	return nil;
}

# --- evaluator ---

Retsig: adt
{
	hit:	int;
	val:	Dnum;
	# names `auto` bound during THIS call, with what they shadowed
	# (existed?, old value) - restored by callfunc on return, the
	# same dynamic-scope save/restore parameters get. Without this,
	# `auto x` inside a function silently overwrote a same-named
	# global for good instead of shadowing it only for the call -
	# found by probing against the oracle, not assumed.
	autosaved: list of (string, int, Dnum);
};

truthy(d: Dnum): int
{
	return d.m != big 0;
}

boolnum(b: int): Dnum
{
	if(b)
		return Dnum(big 1, 0);
	return zero();
}

evalexpr(e: ref Expr): Dnum
{
	pick x := e {
	Num =>
		return x.v;
	Var =>
		return getvar(x.name);
	ScaleVar =>
		return Dnum(big scale, 0);
	PostIncDec =>
		# postfix only (see BUGS): returns the OLD value, then
		# stores the incremented/decremented one.
		old := getvar(x.name);
		one := Dnum(big 1, 0);
		if(x.op == TINC)
			setvar(x.name, dadd(old, one));
		else
			setvar(x.name, dsub(old, one));
		return old;
	Assign =>
		rhs := evalexpr(x.e);
		# `scale` is special: it's the real scale register every
		# arithmetic primitive reads (see dmul/ddiv/dsqrt above),
		# not an ordinary variable - assigning to it here must not
		# go through setvar()/vars, or a later `sqrt()`/division
		# would silently keep using the old scale. Read-side already
		# goes through ScaleVar above; this is the write side.
		old: Dnum;
		if(x.name == "scale")
			old = Dnum(big scale, 0);
		else
			old = getvar(x.name);
		v: Dnum;
		case x.op {
		TASSIGN =>
			v = rhs;
		TPLUSEQ =>
			v = dadd(old, rhs);
		TMINUSEQ =>
			v = dsub(old, rhs);
		TSTAREQ =>
			v = dmul(old, rhs);
		TSLASHEQ =>
			v = ddiv(old, rhs);
		TPCTEQ =>
			v = dmod(old, rhs);
		TCARETEQ =>
			v = dpow(old, rhs);
		}
		if(x.name == "scale"){
			if(v.f != 0)
				fail("scale must be an integer");
			scale = int v.m;
			if(scale < 0)
				fail("negative scale");
		} else
			setvar(x.name, v);
		return v;
	Un =>
		v := evalexpr(x.e);
		return Dnum(-v.m, v.f);
	Not =>
		return boolnum(!truthy(evalexpr(x.e)));
	Bin =>
		case x.op {
		TANDAND =>
			l := evalexpr(x.l);
			if(!truthy(l))
				return boolnum(0);
			return boolnum(truthy(evalexpr(x.r)));
		TOROR =>
			l := evalexpr(x.l);
			if(truthy(l))
				return boolnum(1);
			return boolnum(truthy(evalexpr(x.r)));
		}
		l := evalexpr(x.l);
		r := evalexpr(x.r);
		case x.op {
		TPLUS => return dadd(l, r);
		TMINUS => return dsub(l, r);
		TSTAR => return dmul(l, r);
		TSLASH => return ddiv(l, r);
		TPCT => return dmod(l, r);
		TCARET => return dpow(l, r);
		TEQ => return boolnum(numeq(l, r));
		TNE => return boolnum(!numeq(l, r));
		TLT => return boolnum(numcmp(l, r) < 0);
		TGT => return boolnum(numcmp(l, r) > 0);
		TLE => return boolnum(numcmp(l, r) <= 0);
		TGE => return boolnum(numcmp(l, r) >= 0);
		}
	Builtin =>
		a := evalexpr(x.arg);
		case x.name {
		"sqrt" => return dsqrt(a);
		"length" => return Dnum(big dlength(a), 0);
		"scale" => return Dnum(big a.f, 0);
		}
	Call =>
		return callfunc(x.name, x.args);
	}
	fail("internal: bad expr");
	return zero();
}

numeq(a, b: Dnum): int
{
	c := dsub(a, b);
	return c.m == big 0;
}

numcmp(a, b: Dnum): int
{
	c := dsub(a, b);
	if(c.m < big 0)
		return -1;
	if(c.m > big 0)
		return 1;
	return 0;
}

callfunc(name: string, args: list of ref Expr): Dnum
{
	f := findfunc(name);
	if(f == nil)
		fail("undefined function " + name);
	argv: list of Dnum;
	for(l1 := args; l1 != nil; l1 = tl l1)
		argv = evalexpr(hd l1) :: argv;
	ra: list of Dnum;
	for(; argv != nil; argv = tl argv)
		ra = hd argv :: ra;
	# dynamic-scope save/restore: remember each param's prior binding
	# (whether it existed, and its old value if so), bind the argument
	# values, run the body, then put every saved binding back exactly
	# as it was - matching bc's real semantics, where `auto` and
	# parameters shadow a same-named global only for this call.
	saved: list of (string, int, Dnum);
	pl := f.params;
	al := ra;
	while(pl != nil && al != nil){
		nm := hd pl;
		(existed, ov) := lookupvar(nm);
		saved = (nm, existed, ov) :: saved;
		setvar(nm, hd al);
		pl = tl pl;
		al = tl al;
	}
	rs := ref Retsig(0, zero(), nil);
	execstmts(f.body, rs);
	# undo the `auto` bindings the body itself introduced (found via
	# an oracle-caught bug: these were never being restored at all,
	# so `auto x` inside a function permanently clobbered a same-
	# named global instead of shadowing it), then the parameter
	# bindings above - innermost (most recently introduced) first.
	for(l3 := rs.autosaved; l3 != nil; l3 = tl l3){
		(nm, existed, ov) := hd l3;
		if(existed)
			setvar(nm, ov);
		else
			delvar(nm);
	}
	for(l2 := saved; l2 != nil; l2 = tl l2){
		(nm, existed, ov) := hd l2;
		if(existed)
			setvar(nm, ov);
		else
			delvar(nm);
	}
	return rs.val;
}

delvar(name: string)
{
	r: list of (string, Dnum);
	for(l := vars; l != nil; l = tl l){
		(nm, ov) := hd l;
		if(nm != name)
			r = (nm, ov) :: r;
	}
	vl: list of (string, Dnum);
	for(; r != nil; r = tl r)
		vl = hd r :: vl;
	vars = vl;
}

execstmts(stmts: list of ref Stmt, rs: ref Retsig)
{
	for(l := stmts; l != nil; l = tl l){
		execstmt(hd l, rs);
		if(rs.hit)
			return;
	}
}

execstmt(s: ref Stmt, rs: ref Retsig)
{
	pick x := s {
	SExpr =>
		v := evalexpr(x.e);
		# a bare expression statement prints; an assignment
		# (Assign at the top level) does not - checked against
		# the oracle, not assumed.
		pick tmp := x.e {
		Assign => ;
		* => emit(fmtnum(v) + "\n");
		}
	SIf =>
		if(truthy(evalexpr(x.cond)))
			execstmts(x.then, rs);
		else if(x.els != nil)
			execstmts(x.els, rs);
	SWhile =>
		while(truthy(evalexpr(x.cond))){
			execstmts(x.body, rs);
			if(rs.hit)
				return;
		}
	SFor =>
		if(x.init != nil)
			evalexpr(x.init);
		for(;;){
			if(x.cond != nil && !truthy(evalexpr(x.cond)))
				break;
			execstmts(x.body, rs);
			if(rs.hit)
				return;
			if(x.incr != nil)
				evalexpr(x.incr);
		}
	SReturn =>
		rs.hit = 1;
		if(x.e != nil)
			rs.val = evalexpr(x.e);
	SAuto =>
		for(l := x.names; l != nil; l = tl l){
			nm := hd l;
			(existed, ov) := lookupvar(nm);
			rs.autosaved = (nm, existed, ov) :: rs.autosaved;
			setvar(nm, zero());
		}
	}
}

# --- driver ---

capturing:	int;
outbuf:		string;

emit(s: string)
{
	if(capturing)
		outbuf += s;
	else
		sys->print("%s", s);
}

fail(msg: string)
{
	sys->fprint(stderr, "bc: %s\n", msg);
	raise "fail:bc";
}

resetstate()
{
	scale = 0;
	funcs = nil;
	vars = nil;
}

run(src: string)
{
	lex(src);
	prog := parseprogram();
	rs := ref Retsig(0, zero(), nil);
	execstmts(prog, rs);
}

runstring(prog: string): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(stderr == nil)
		stderr = sys->fildes(2);
	resetstate();
	outbuf = "";
	capturing = 1;
	run(prog);
	capturing = 0;
	return outbuf;
}

readall(f: ref Iobuf): string
{
	out := "";
	for(;;){
		s := f.gets('\n');
		if(s == nil)
			break;
		out += s;
	}
	return out;
}

usage()
{
	sys->fprint(stderr, "usage: bc [-e script] [-f scriptfile] [file...]\n");
	raise "fail:usage";
}

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stdin = sys->fildes(0);
	stdout = sys->fildes(1);
	stderr = sys->fildes(2);

	bufio = load Bufio Bufio->PATH;
	arg := load Arg Arg->PATH;
	if(bufio == nil || arg == nil){
		sys->fprint(stderr, "bc: cannot load a required module\n");
		raise "fail:module";
	}

	resetstate();

	prog := "";
	haveprog := 0;

	arg->init(argv);
	while((opt := arg->opt()) != 0){
		case opt {
		'e' =>
			prog += arg->earg() + "\n";
			haveprog = 1;
		'f' =>
			fname := arg->earg();
			f := bufio->open(fname, Bufio->OREAD);
			if(f == nil){
				sys->fprint(stderr, "bc: cannot open %s: %r\n", fname);
				raise "fail:open";
			}
			prog += readall(f);
			haveprog = 1;
		* =>
			usage();
		}
	}
	rest := arg->argv();
	arg = nil;

	if(!haveprog){
		if(rest != nil){
			for(; rest != nil; rest = tl rest){
				f := bufio->open(hd rest, Bufio->OREAD);
				if(f == nil){
					sys->fprint(stderr, "bc: cannot open %s: %r\n", hd rest);
					raise "fail:open";
				}
				prog += readall(f);
			}
		} else
			prog = readall(bufio->fopen(stdin, Bufio->OREAD));
	}

	run(prog);
}
