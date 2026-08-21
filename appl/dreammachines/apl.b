implement Apl;

# Nelson's Dream Machines chapter on languages names APL alongside BASIC
# and TRAC as the third distinct answer to "how should people program a
# computer" - and the one with the least in common with the other two:
# every value is an array (a scalar is just a one-element array here -
# genuine multi-dimensional arrays are a real, documented scope cut,
# see below), a small set of primitives apply to a whole array at once
# rather than looping over it by hand, and - the single most notorious
# thing about the language - expressions have NO operator precedence at
# all and evaluate strictly right to left. "2×3+4" is 2×(3+4)=14, not
# (2×3)+4=10, because APL evaluates 3+4 first (it's further right) and
# only then applies × to 2 and that result. Parentheses are how you
# override this, same as anywhere else, and appl/basic.bas-style
# familiarity is actively the wrong intuition here.
#
# The real APL glyphs are used throughout, not ASCII substitutes -
# they're confirmed to round-trip correctly through this tree's file
# I/O (UTF-8 in, one rune per glyph out) via a throwaway probe before
# any of this was written:
#   ← assign        ⍴ shape/reshape       ⍳ iota (1..N, index origin 1)
#   + - × ÷ ⌈ ⌊     (monadic and dyadic each - see below)
#   = ≠ < > ≤ ≥     comparisons (dyadic only, elementwise 1/0)
#   /               reduce, as a suffix on a dyadic-capable function:
#                   +/V -/V ×/V ÷/V ⌈/V ⌊/V - real APL's reduce folds
#                   from the right (so -/1 2 3 4 is 1-(2-(3-4)) = -2,
#                   not ((1-2)-3)-4 = -8 - this implementation does too
#   ⍝               comment to end of line
#   ¯               a literal negative number's own prefix (¯5), never
#                   fused from the "-" function - APL keeps these two
#                   entirely separate, and so does this
#
# Monadic meanings (applied when nothing valid stands to a function's
# immediate left - see the evaluator below for exactly what "valid"
# means): + is identity, - is negation, × is sign (-1/0/1), ÷ is
# reciprocal, ⌈/⌊ are ceiling/floor, ⍳ is the index generator, ⍴ is
# shape (a vector's own length, wrapped in a 1-element result, since
# there's no rank beyond 1 here). Dyadic ⍴ reshapes: a⍴v is a
# length-a vector cycling through v's elements. Dyadic arithmetic and
# comparisons apply elementwise, with scalar extension - a one-element
# array broadcasts against a longer one, matching two same-length
# arrays does elementwise, and mismatched unequal lengths beyond that
# aren't checked for or rejected, just read out of range as an
# interpreter error would be. There is no bracket indexing (V[I]) -
# a real, deliberate scope cut alongside multi-dimensional arrays,
# user-defined functions (∇), and doubled-quote-style anything, kept
# out to keep the right-to-left evaluator itself - the actual point of
# this exercise - tractable and correct rather than merely large.
#
# A script is a sequence of immediate-execution lines, same as typing
# into a real APL session: NAME←expr assigns silently; a bare
# expression evaluates and auto-prints its result, space-separated,
# negative numbers shown with ¯ rather than a hyphen, matching how real
# APL displays them too.
#
# usage: apl file.apl

include "sys.m";
	sys: Sys;

include "draw.m";
	Context: import Draw;

include "math.m";
	math: Math;

Apl: module {
	init: fn(ctxt: ref Context, argv: list of string);
};

stdout, stderr: ref Sys->FD;

# --- tokens ---

TKNUM, TKIDENT, TKFUNC, TKSLASH, TKARROW, TKLPAREN, TKRPAREN: con iota;

Tok: adt {
	kind:	int;
	sval:	string;
	nval:	real;
};

# --- values: every value is a 1-D array of real; a scalar is length 1 ---

Value: adt {
	data:	array of real;
};

Var: adt {
	name:	string;
	val:	ref Value;
};

vars: list of ref Var;

# --- a Parser is a view onto toks[lo:hi); evaluation always consumes
#     from the hi end, moving right to left ---

Parser: adt {
	toks:	array of ref Tok;
	lo, hi:	int;
};

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	stdout = sys->fildes(1);
	stderr = sys->fildes(2);

	argv = tl argv;
	if(argv == nil){
		sys->fprint(stderr, "usage: apl file.apl\n");
		raise "fail:usage";
	}
	(src, err) := readfile(hd argv);
	if(src == nil){
		sys->fprint(stderr, "apl: %s\n", err);
		raise "fail:open";
	}

	(nil, lines) := sys->tokenize(src, "\n");
	for(l := lines; l != nil; l = tl l){
		toks := lex(hd l);
		if(len toks == 0)
			continue;
		if(len toks >= 2 && toks[0].kind == TKIDENT && toks[1].kind == TKARROW){
			sub := ref Parser(toks, 2, len toks);
			setvar(toks[0].sval, evalfrom(sub));
		}else{
			p := ref Parser(toks, 0, len toks);
			printvalue(evalfrom(p));
		}
	}
}

# --- lexer ---

lex(s: string): array of ref Tok
{
	funcglyphs := "+-×÷⌈⌊=≠<>≤≥⍳⍴";
	cmtg := "⍝";
	arrowg := "←";
	hmg := "¯";

	toks: list of ref Tok;
	i := 0;
	n := len s;
	while(i < n){
		c := s[i];
		if(c == cmtg[0])
			break;
		if(c == ' ' || c == '\t'){
			i++;
			continue;
		}
		if(isdigit(c) || c == hmg[0]){
			neg := 0;
			j := i;
			if(c == hmg[0]){
				neg = 1;
				j++;
			}
			start := j;
			while(j < n && (isdigit(s[j]) || s[j] == '.'))
				j++;
			numstr := s[start:j];
			v := real numstr;
			if(neg)
				v = -v;
			toks = ref Tok(TKNUM, "", v) :: toks;
			i = j;
			continue;
		}
		if(isalpha(c)){
			j := i;
			while(j < n && (isalpha(s[j]) || isdigit(s[j])))
				j++;
			toks = ref Tok(TKIDENT, s[i:j], 0.0) :: toks;
			i = j;
			continue;
		}
		if(c == '('){
			toks = ref Tok(TKLPAREN, "(", 0.0) :: toks;
			i++;
			continue;
		}
		if(c == ')'){
			toks = ref Tok(TKRPAREN, ")", 0.0) :: toks;
			i++;
			continue;
		}
		if(c == '/'){
			toks = ref Tok(TKSLASH, "/", 0.0) :: toks;
			i++;
			continue;
		}
		if(c == arrowg[0]){
			toks = ref Tok(TKARROW, "←", 0.0) :: toks;
			i++;
			continue;
		}
		if(indexofrune(funcglyphs, c) >= 0){
			toks = ref Tok(TKFUNC, onechar(c), 0.0) :: toks;
			i++;
			continue;
		}
		i++;	# unrecognised character - skip it
	}
	toks = revtoks(toks);
	arr := array[lentoks(toks)] of ref Tok;
	k := 0;
	for(t := toks; t != nil; t = tl t){
		arr[k] = hd t;
		k++;
	}
	return arr;
}

# --- evaluator: strictly right to left, no precedence ---

evalfrom(p: ref Parser): ref Value
{
	cur := evaloperand(p);
	while(p.hi > p.lo){
		t := p.toks[p.hi-1];
		if(t.kind == TKSLASH){
			if(p.hi-2 >= p.lo && p.toks[p.hi-2].kind == TKFUNC){
				fname := p.toks[p.hi-2].sval;
				p.hi -= 2;
				cur = applyreduce(fname, cur);
				continue;
			}
			break;
		}
		if(t.kind != TKFUNC)
			break;
		fname := t.sval;
		if(p.hi-2 >= p.lo && isoperandstart(p.toks[p.hi-2])){
			p.hi--;
			leftval := evaloperand(p);
			cur = applydyadic(fname, leftval, cur);
		}else{
			p.hi--;
			cur = applymonadic(fname, cur);
		}
	}
	return cur;
}

isoperandstart(t: ref Tok): int
{
	return t.kind == TKNUM || t.kind == TKIDENT || t.kind == TKRPAREN;
}

# Consumes exactly one operand from the right end of p's range: a
# parenthesised sub-expression, or a "strand" of one or more adjacent
# number/variable tokens (APL's own juxtaposition notation for building
# a vector literal - "1 2 3" is one 3-element vector, no comma needed;
# a stranded variable holding its own multi-element vector is spliced
# in whole, not just its first element).
evaloperand(p: ref Parser): ref Value
{
	if(p.hi <= p.lo){
		sys->fprint(stderr, "apl: unexpected end of expression\n");
		return ref Value(array[1] of {0 => 0.0});
	}
	t := p.toks[p.hi-1];
	if(t.kind == TKRPAREN){
		depth := 1;
		j := p.hi-2;
		while(j >= p.lo && depth > 0){
			if(p.toks[j].kind == TKRPAREN)
				depth++;
			else if(p.toks[j].kind == TKLPAREN)
				depth--;
			if(depth > 0)
				j--;
		}
		sub := ref Parser(p.toks, j+1, p.hi-1);
		val := evalfrom(sub);
		p.hi = j;
		return val;
	}
	if(t.kind == TKNUM || t.kind == TKIDENT){
		vlist: list of ref Value;
		while(p.hi > p.lo && (p.toks[p.hi-1].kind == TKNUM || p.toks[p.hi-1].kind == TKIDENT)){
			tt := p.toks[p.hi-1];
			v: ref Value;
			if(tt.kind == TKNUM)
				v = ref Value(array[1] of {0 => tt.nval});
			else
				v = getvar(tt.sval);
			vlist = v :: vlist;
			p.hi--;
		}
		return concatvalues(vlist);
	}
	sys->fprint(stderr, "apl: unexpected token in expression\n");
	p.hi--;
	return ref Value(array[1] of {0 => 0.0});
}

applymonadic(fname: string, v: ref Value): ref Value
{
	n := len v.data;
	r := array[n] of real;
	case fname {
	"+" =>
		return v;
	"-" =>
		for(i := 0; i < n; i++)
			r[i] = -v.data[i];
	"×" =>	# ×  sign
		for(i := 0; i < n; i++){
			if(v.data[i] > 0.0)
				r[i] = 1.0;
			else if(v.data[i] < 0.0)
				r[i] = -1.0;
			else
				r[i] = 0.0;
		}
	"÷" =>	# ÷  reciprocal
		for(i := 0; i < n; i++)
			r[i] = 1.0/v.data[i];
	"⌈" =>	# ⌈  ceiling
		for(i := 0; i < n; i++)
			r[i] = math->ceil(v.data[i]);
	"⌊" =>	# ⌊  floor
		for(i := 0; i < n; i++)
			r[i] = math->floor(v.data[i]);
	"⍳" =>	# ⍳  iota
		cnt := int v.data[0];
		rr := array[cnt] of real;
		for(i := 0; i < cnt; i++)
			rr[i] = real (i+1);
		return ref Value(rr);
	"⍴" =>	# ⍴  shape
		return ref Value(array[1] of {0 => real len v.data});
	* =>
		return v;
	}
	return ref Value(r);
}

applydyadic(fname: string, l: ref Value, rgt: ref Value): ref Value
{
	if(fname == "⍴"){	# ⍴  reshape
		cnt := int l.data[0];
		rr := array[cnt] of real;
		src := rgt.data;
		for(i := 0; i < cnt; i++)
			rr[i] = src[i % len src];
		return ref Value(rr);
	}
	n := len l.data;
	if(len rgt.data > n)
		n = len rgt.data;
	r := array[n] of real;
	for(i := 0; i < n; i++){
		a := l.data[i % len l.data];
		b := rgt.data[i % len rgt.data];
		case fname {
		"+" =>	r[i] = a+b;
		"-" =>	r[i] = a-b;
		"×" => r[i] = a*b;
		"÷" => r[i] = a/b;
		"⌈" => r[i] = maxreal(a, b);
		"⌊" => r[i] = minreal(a, b);
		"=" =>	r[i] = boolreal(a == b);
		"≠" => r[i] = boolreal(a != b);
		"<" =>	r[i] = boolreal(a < b);
		">" =>	r[i] = boolreal(a > b);
		"≤" => r[i] = boolreal(a <= b);
		"≥" => r[i] = boolreal(a >= b);
		}
	}
	return ref Value(r);
}

# Reduce folds from the right - -/1 2 3 4 is 1-(2-(3-4)), not the other
# way around - so is ÷, and it matters for both the same way it would
# in real APL.
applyreduce(fname: string, v: ref Value): ref Value
{
	n := len v.data;
	if(n == 0)
		return ref Value(array[1] of {0 => 0.0});
	acc := v.data[n-1];
	for(i := n-2; i >= 0; i--){
		case fname {
		"+" =>	acc = v.data[i]+acc;
		"-" =>	acc = v.data[i]-acc;
		"×" => acc = v.data[i]*acc;
		"÷" => acc = v.data[i]/acc;
		"⌈" => acc = maxreal(v.data[i], acc);
		"⌊" => acc = minreal(v.data[i], acc);
		}
	}
	return ref Value(array[1] of {0 => acc});
}

maxreal(a, b: real): real
{
	if(a > b)
		return a;
	return b;
}

minreal(a, b: real): real
{
	if(a < b)
		return a;
	return b;
}

boolreal(b: int): real
{
	if(b)
		return 1.0;
	return 0.0;
}

concatvalues(l: list of ref Value): ref Value
{
	total := 0;
	for(x := l; x != nil; x = tl x)
		total += len (hd x).data;
	r := array[total] of real;
	i := 0;
	for(x = l; x != nil; x = tl x){
		d := (hd x).data;
		for(k := 0; k < len d; k++){
			r[i] = d[k];
			i++;
		}
	}
	return ref Value(r);
}

getvar(name: string): ref Value
{
	for(v := vars; v != nil; v = tl v)
		if((hd v).name == name)
			return (hd v).val;
	sys->fprint(stderr, "apl: undefined variable %s\n", name);
	return ref Value(array[1] of {0 => 0.0});
}

setvar(name: string, val: ref Value)
{
	for(v := vars; v != nil; v = tl v){
		if((hd v).name == name){
			(hd v).val = val;
			return;
		}
	}
	vars = ref Var(name, val) :: vars;
}

printvalue(v: ref Value)
{
	s := "";
	for(i := 0; i < len v.data; i++){
		if(i > 0)
			s += " ";
		s += fmtnum(v.data[i]);
	}
	sys->fprint(stdout, "%s\n", s);
}

fmtnum(n: real): string
{
	neg := n < 0.0;
	a := n;
	if(neg)
		a = -a;
	rounded := real (int a);
	diff := a-rounded;
	if(diff < 0.0)
		diff = -diff;
	s: string;
	if(diff < 1e-9)
		s = string (int a);
	else{
		s = sys->sprint("%f", a);
		i := len s;
		while(i > 0 && s[i-1] == '0')
			i--;
		if(i > 0 && s[i-1] == '.')
			i--;
		s = s[0:i];
	}
	if(neg)
		return "¯"+s;
	return s;
}

indexofrune(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return i;
	return -1;
}

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

isalpha(c: int): int
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

onechar(c: int): string
{
	s := " ";
	s[0] = c;
	return s;
}

lentoks(l: list of ref Tok): int
{
	n := 0;
	for(; l != nil; l = tl l)
		n++;
	return n;
}

revtoks(l: list of ref Tok): list of ref Tok
{
	r: list of ref Tok;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

readfile(path: string): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("cannot open %s: %r", path));
	(ok, d) := sys->fstat(fd);
	if(ok < 0 || (d.mode & Sys->DMDIR))
		return (nil, "not a regular file: "+path);
	a := array[int d.length] of byte;
	n := sys->read(fd, a, len a);
	if(n < 0)
		return (nil, sys->sprint("cannot read %s: %r", path));
	return (string a[0:n], nil);
}
