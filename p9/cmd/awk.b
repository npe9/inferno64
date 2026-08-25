implement Awk;

# A Limbo-native awk workalike: Dis bytecode, run by emu, not a host
# binary - see doc/plan9-port.md's "Rule: Limbo-native, in a separate
# bindable tree". This is a deliberately bounded subset, not the full
# POSIX grammar - see BUGS in man/1/awk (p9/man/1/awk) for exactly what
# is and isn't covered. Correctness is gated on matching utils/awk's own
# real, working C implementation on the same program and input, not on
# the language spec from memory.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "arg.m";
include "regex.m";
	regex: Regex;
	Re: import regex;
include "string.m";
	str: String;

Awk: module
{
	init:		fn(ctxt: ref Context, argv: list of string);

	# in-process test seam: run prog against input (a whole string, '\n'
	# separated, no real files/stdin/stdout involved) and return whatever
	# the program printed, as a string. Exists so p9/cmd/awktest.b can
	# check real programs against golden output without spawning a
	# subprocess or juggling fds - see doc/plan9-port.md.
	runstring:	fn(prog: string, input: string): string;
};

stdin, stdout, stderr: ref FD;

# ---------------------------------------------------------------- values

Val: adt
{
	s:	string;
	n:	real;
	isnum:	int;	# 1 if numeric context applies (literal, arithmetic
			# result, or input text that fully parses as a number -
			# awk's "strnum"); uninitialised vars are ("", 0.0, 1)
			# so they compare equal to both "" and 0, matching awk.
};

# ---------------------------------------------------------------- tokens

Tok: adt
{
	kind:	int;
	s:	string;
	n:	real;
};

TEOF, TNUM, TSTR, TREGEX, TIDENT,
TBEGIN, TEND, TIF, TELSE, TWHILE, TFOR, TPRINT, TPRINTF, TNEXT,
TLBRACE, TRBRACE, TLPAREN, TRPAREN, TLBRACK, TRBRACK,
TSEMI, TCOMMA, TDOLLAR,
TASSIGN, TADDASSIGN, TSUBASSIGN, TMULASSIGN, TDIVASSIGN, TMODASSIGN,
TOROR, TANDAND, TNOT,
TLT, TLE, TGT, TGE, TEQ, TNE,
TMATCH, TNOMATCH,
TPLUS, TMINUS, TSTAR, TSLASH, TPERCENT,
TQUESTION, TCOLON,
TINCR, TDECR:	con iota;

# ------------------------------------------------------------------ ast

Expr: adt
{
	pick
	{
	Num =>
		v:	real;
	Str =>
		v:	string;
	Regexlit =>
		src:	string;
	Field =>
		idx:	ref Expr;
	Var =>
		name:	string;
	Arrayref =>
		name:	string;
		idx:	ref Expr;
	Call =>
		name:	string;
		args:	list of ref Expr;
	Unary =>
		op:	int;
		e:	ref Expr;
	Bin =>
		op:	int;
		l:	ref Expr;
		r:	ref Expr;
	Assign =>
		op:	int;
		lhs:	ref Expr;
		rhs:	ref Expr;
	Ternary =>
		c:	ref Expr;
		t:	ref Expr;
		f:	ref Expr;
	Incdec =>
		prefix:	int;	# 1 = ++x/--x, 0 = x++/x--
		inc:	int;	# 1 = ++, 0 = --
		target:	ref Expr;	# lvalue: Var/Arrayref/Field
	}
};

UNEG, UPOS, UNOT: con iota;
OADD, OSUB, OMUL, ODIV, OMOD, OCONCAT,
OLT, OLE, OGT, OGE, OEQ, ONE,
OAND, OOR, OMATCH, ONOMATCH: con iota;
AASSIGN, AADD, ASUB, AMUL, ADIV, AMOD: con iota;

Stmt: adt
{
	pick
	{
	Exprstmt =>
		e:	ref Expr;
	Print =>
		args:	list of ref Expr;
	Printf =>
		args:	list of ref Expr;
	If =>
		c:	ref Expr;
		t:	ref Stmt;
		f:	ref Stmt;
	While =>
		c:	ref Expr;
		body:	ref Stmt;
	For =>
		init:	ref Stmt;
		cond:	ref Expr;
		post:	ref Stmt;
		body:	ref Stmt;
	Block =>
		stmts:	list of ref Stmt;
	Next =>
		dummy:	int;
	Foreach =>
		var:		string;
		arrname:	string;
		body:		ref Stmt;
	}
};

RBEGIN, REND, RALWAYS, RPAT: con iota;

Rule: adt
{
	kind:	int;
	pat:	ref Expr;	# nil for RBEGIN/REND/RALWAYS
	action:	ref Stmt;
};

SNORMAL, SNEXT: con iota;

# --------------------------------------------------------------- lexer

isalpha(c: int): int
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

keywordkind(w: string): int
{
	case w {
	"BEGIN" =>	return TBEGIN;
	"END" =>	return TEND;
	"if" =>		return TIF;
	"else" =>	return TELSE;
	"while" =>	return TWHILE;
	"for" =>	return TFOR;
	"print" =>	return TPRINT;
	"printf" =>	return TPRINTF;
	"next" =>	return TNEXT;
	* =>		return TIDENT;
	}
}

singlekind(c: int): int
{
	case c {
	'{' =>	return TLBRACE;
	'}' =>	return TRBRACE;
	'(' =>	return TLPAREN;
	')' =>	return TRPAREN;
	'[' =>	return TLBRACK;
	']' =>	return TRBRACK;
	';' =>	return TSEMI;
	',' =>	return TCOMMA;
	'$' =>	return TDOLLAR;
	'=' =>	return TASSIGN;
	'<' =>	return TLT;
	'>' =>	return TGT;
	'!' =>	return TNOT;
	'~' =>	return TMATCH;
	'+' =>	return TPLUS;
	'-' =>	return TMINUS;
	'*' =>	return TSTAR;
	'/' =>	return TSLASH;
	'%' =>	return TPERCENT;
	'?' =>	return TQUESTION;
	':' =>	return TCOLON;
	* =>	return -1;
	}
}

regexok(lastsig: int): int
{
	case lastsig {
	TNUM or TSTR or TIDENT or TRPAREN or TRBRACK or TREGEX or TINCR or TDECR =>
		return 0;
	* =>
		return 1;
	}
}

lexerror(msg: string)
{
	sys->fprint(stderr, "awk: %s\n", msg);
	raise "fail:syntax";
}

lex(src: string): array of ref Tok
{
	tv := array[len src + 4] of ref Tok;
	n := 0;
	i := 0;
	ns := len src;
	lastsig := -1;
	while(i < ns){
		c := src[i];
		if(c == ' ' || c == '\t' || c == '\n' || c == '\r'){
			i++;
			continue;
		}
		if(c == '#'){
			while(i < ns && src[i] != '\n')
				i++;
			continue;
		}
		if(isdigit(c) || (c == '.' && i+1 < ns && isdigit(src[i+1]))){
			start := i;
			while(i < ns && isdigit(src[i]))
				i++;
			if(i < ns && src[i] == '.'){
				i++;
				while(i < ns && isdigit(src[i]))
					i++;
			}
			if(i < ns && (src[i] == 'e' || src[i] == 'E')){
				j := i+1;
				if(j < ns && (src[j] == '+' || src[j] == '-'))
					j++;
				if(j < ns && isdigit(src[j])){
					i = j;
					while(i < ns && isdigit(src[i]))
						i++;
				}
			}
			numsrc := src[start:i];
			(v, nil) := str->toreal(numsrc, 10);
			tv[n++] = ref Tok(TNUM, numsrc, v);
			lastsig = TNUM;
			continue;
		}
		if(isalpha(c) || c == '_'){
			start := i;
			while(i < ns && (isalpha(src[i]) || isdigit(src[i]) || src[i] == '_'))
				i++;
			w := src[start:i];
			kind := keywordkind(w);
			tv[n++] = ref Tok(kind, w, 0.0);
			lastsig = kind;
			continue;
		}
		if(c == '"'){
			i++;
			s := "";
			while(i < ns && src[i] != '"'){
				cc := src[i];
				if(cc == '\\' && i+1 < ns){
					i++;
					esc := src[i];
					case esc {
					'n' =>	s[len s] = '\n';
					't' =>	s[len s] = '\t';
					'\\' =>	s[len s] = '\\';
					'"' =>	s[len s] = '"';
					* =>	s[len s] = esc;
					}
					i++;
				} else {
					s[len s] = cc;
					i++;
				}
			}
			if(i >= ns)
				lexerror("unterminated string literal");
			i++;
			tv[n++] = ref Tok(TSTR, s, 0.0);
			lastsig = TSTR;
			continue;
		}
		if(c == '/' && regexok(lastsig)){
			i++;
			s := "";
			while(i < ns && src[i] != '/'){
				cc := src[i];
				if(cc == '\\' && i+1 < ns){
					s[len s] = cc;
					i++;
					s[len s] = src[i];
					i++;
				} else {
					s[len s] = cc;
					i++;
				}
			}
			if(i >= ns)
				lexerror("unterminated regex literal");
			i++;
			tv[n++] = ref Tok(TREGEX, s, 0.0);
			lastsig = TREGEX;
			continue;
		}
		two := "";
		if(i+1 < ns)
			two = src[i:i+2];
		matched2 := 1;
		case two {
		"||" =>	tv[n++] = ref Tok(TOROR, two, 0.0);
		"&&" =>	tv[n++] = ref Tok(TANDAND, two, 0.0);
		"==" =>	tv[n++] = ref Tok(TEQ, two, 0.0);
		"!=" =>	tv[n++] = ref Tok(TNE, two, 0.0);
		"<=" =>	tv[n++] = ref Tok(TLE, two, 0.0);
		">=" =>	tv[n++] = ref Tok(TGE, two, 0.0);
		"!~" =>	tv[n++] = ref Tok(TNOMATCH, two, 0.0);
		"+=" =>	tv[n++] = ref Tok(TADDASSIGN, two, 0.0);
		"-=" =>	tv[n++] = ref Tok(TSUBASSIGN, two, 0.0);
		"*=" =>	tv[n++] = ref Tok(TMULASSIGN, two, 0.0);
		"/=" =>	tv[n++] = ref Tok(TDIVASSIGN, two, 0.0);
		"%=" =>	tv[n++] = ref Tok(TMODASSIGN, two, 0.0);
		"++" =>	tv[n++] = ref Tok(TINCR, two, 0.0);
		"--" =>	tv[n++] = ref Tok(TDECR, two, 0.0);
		* =>	matched2 = 0;
		}
		if(matched2){
			lastsig = tv[n-1].kind;
			i += 2;
			continue;
		}
		kind := singlekind(c);
		if(kind < 0)
			lexerror(sys->sprint("unexpected character '%c'", c));
		tv[n++] = ref Tok(kind, "", 0.0);
		lastsig = kind;
		i++;
	}
	tv[n++] = ref Tok(TEOF, "", 0.0);
	return tv[0:n];
}

# -------------------------------------------------------------- parser

toks: array of ref Tok;
pos: int;

cur(): ref Tok
{
	return toks[pos];
}

advance(): ref Tok
{
	t := toks[pos];
	if(pos < len toks - 1)
		pos++;
	return t;
}

parseerror(msg: string)
{
	sys->fprint(stderr, "awk: syntax error: %s\n", msg);
	raise "fail:syntax";
}

expect(k: int, what: string): ref Tok
{
	if(cur().kind != k)
		parseerror("expected " + what);
	return advance();
}

revexprlist(l: list of ref Expr): list of ref Expr
{
	r: list of ref Expr;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

revstmtlist(l: list of ref Stmt): list of ref Stmt
{
	r: list of ref Stmt;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

revrulelist(l: list of ref Rule): list of ref Rule
{
	r: list of ref Rule;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

islvalue(e: ref Expr): int
{
	pick x := e {
	Var =>		return 1;
	Arrayref =>	return 1;
	Field =>	return 1;
	* =>		return 0;
	}
}

# parseprimary0 does the actual parsing; parseprimary wraps it with a
# postfix ++/-- check, so every caller that wants "the tightest possible
# expression" (unary operands, $ operands, etc.) gets postfix handled
# too, without duplicating the check at each call site.
parseprimary(): ref Expr
{
	e := parseprimary0();
	if(cur().kind == TINCR){
		advance();
		return ref Expr.Incdec(0, 1, e);
	}
	if(cur().kind == TDECR){
		advance();
		return ref Expr.Incdec(0, 0, e);
	}
	return e;
}

parseprimary0(): ref Expr
{
	t := cur();
	case t.kind {
	TNUM =>
		advance();
		return ref Expr.Num(t.n);
	TSTR =>
		advance();
		return ref Expr.Str(t.s);
	TREGEX =>
		advance();
		return ref Expr.Regexlit(t.s);
	TDOLLAR =>
		advance();
		e := parseprimary();
		return ref Expr.Field(e);
	TLPAREN =>
		advance();
		e := parseassign();
		expect(TRPAREN, ")");
		return e;
	TMINUS =>
		advance();
		e := parseprimary();
		return ref Expr.Unary(UNEG, e);
	TPLUS =>
		advance();
		e := parseprimary();
		return ref Expr.Unary(UPOS, e);
	TNOT =>
		advance();
		e := parseprimary();
		return ref Expr.Unary(UNOT, e);
	TINCR =>
		advance();
		e := parseprimary();
		return ref Expr.Incdec(1, 1, e);
	TDECR =>
		advance();
		e := parseprimary();
		return ref Expr.Incdec(1, 0, e);
	TIDENT =>
		name := t.s;
		advance();
		if(cur().kind == TLPAREN){
			advance();
			args: list of ref Expr;
			if(cur().kind != TRPAREN){
				args = parseassign() :: args;
				while(cur().kind == TCOMMA){
					advance();
					args = parseassign() :: args;
				}
			}
			expect(TRPAREN, ")");
			return ref Expr.Call(name, revexprlist(args));
		}
		if(cur().kind == TLBRACK){
			advance();
			idx := parseassign();
			expect(TRBRACK, "]");
			return ref Expr.Arrayref(name, idx);
		}
		return ref Expr.Var(name);
	}
	parseerror("unexpected token");
	return nil;
}

parsemul(): ref Expr
{
	e := parseprimary();
	for(;;){
		k := cur().kind;
		if(k == TSTAR){
			advance();
			e = ref Expr.Bin(OMUL, e, parseprimary());
		} else if(k == TSLASH){
			advance();
			e = ref Expr.Bin(ODIV, e, parseprimary());
		} else if(k == TPERCENT){
			advance();
			e = ref Expr.Bin(OMOD, e, parseprimary());
		} else
			break;
	}
	return e;
}

parseadd(): ref Expr
{
	e := parsemul();
	for(;;){
		k := cur().kind;
		if(k == TPLUS){
			advance();
			e = ref Expr.Bin(OADD, e, parsemul());
		} else if(k == TMINUS){
			advance();
			e = ref Expr.Bin(OSUB, e, parsemul());
		} else
			break;
	}
	return e;
}

startsvalue(k: int): int
{
	case k {
	TNUM or TSTR or TREGEX or TIDENT or TDOLLAR or TLPAREN or
	TMINUS or TPLUS or TNOT or TINCR or TDECR =>
		return 1;
	* =>
		return 0;
	}
}

parseconcat(): ref Expr
{
	e := parseadd();
	while(startsvalue(cur().kind))
		e = ref Expr.Bin(OCONCAT, e, parseadd());
	return e;
}

parserel(): ref Expr
{
	e := parseconcat();
	k := cur().kind;
	if(k == TLT){
		advance();
		e = ref Expr.Bin(OLT, e, parseconcat());
	} else if(k == TLE){
		advance();
		e = ref Expr.Bin(OLE, e, parseconcat());
	} else if(k == TGT){
		advance();
		e = ref Expr.Bin(OGT, e, parseconcat());
	} else if(k == TGE){
		advance();
		e = ref Expr.Bin(OGE, e, parseconcat());
	} else if(k == TEQ){
		advance();
		e = ref Expr.Bin(OEQ, e, parseconcat());
	} else if(k == TNE){
		advance();
		e = ref Expr.Bin(ONE, e, parseconcat());
	}
	return e;
}

parsematch(): ref Expr
{
	e := parserel();
	for(;;){
		k := cur().kind;
		if(k == TMATCH){
			advance();
			e = ref Expr.Bin(OMATCH, e, parserel());
		} else if(k == TNOMATCH){
			advance();
			e = ref Expr.Bin(ONOMATCH, e, parserel());
		} else
			break;
	}
	return e;
}

parseand(): ref Expr
{
	e := parsematch();
	while(cur().kind == TANDAND){
		advance();
		e = ref Expr.Bin(OAND, e, parsematch());
	}
	return e;
}

parseor(): ref Expr
{
	e := parseand();
	while(cur().kind == TOROR){
		advance();
		e = ref Expr.Bin(OOR, e, parseand());
	}
	return e;
}

parseternary(): ref Expr
{
	e := parseor();
	if(cur().kind == TQUESTION){
		advance();
		t := parseassign();
		expect(TCOLON, ":");
		f := parseassign();
		return ref Expr.Ternary(e, t, f);
	}
	return e;
}

parseassign(): ref Expr
{
	e := parseternary();
	k := cur().kind;
	op := -1;
	case k {
	TASSIGN =>	op = AASSIGN;
	TADDASSIGN =>	op = AADD;
	TSUBASSIGN =>	op = ASUB;
	TMULASSIGN =>	op = AMUL;
	TDIVASSIGN =>	op = ADIV;
	TMODASSIGN =>	op = AMOD;
	}
	if(op != -1){
		if(!islvalue(e))
			parseerror("assignment to non-lvalue");
		advance();
		rhs := parseassign();
		return ref Expr.Assign(op, e, rhs);
	}
	return e;
}

parseexprlist(): list of ref Expr
{
	r: list of ref Expr;
	r = parseassign() :: r;
	while(cur().kind == TCOMMA){
		advance();
		r = parseassign() :: r;
	}
	return revexprlist(r);
}

parsesimplestmt(): ref Stmt
{
	e := parseassign();
	return ref Stmt.Exprstmt(e);
}

parseblock(): ref Stmt
{
	expect(TLBRACE, "{");
	stmts := parsestmtlistuntil(TRBRACE);
	expect(TRBRACE, "}");
	return ref Stmt.Block(stmts);
}

parsestmtlistuntil(endkind: int): list of ref Stmt
{
	r: list of ref Stmt;
	while(cur().kind != endkind && cur().kind != TEOF){
		if(cur().kind == TSEMI){
			advance();
			continue;
		}
		r = parsestmt() :: r;
	}
	return revstmtlist(r);
}

parsestmt(): ref Stmt
{
	t := cur();
	case t.kind {
	TLBRACE =>
		return parseblock();
	TIF =>
		advance();
		expect(TLPAREN, "(");
		c := parseassign();
		expect(TRPAREN, ")");
		th := parsestmt();
		el: ref Stmt;
		if(cur().kind == TELSE){
			advance();
			el = parsestmt();
		}
		return ref Stmt.If(c, th, el);
	TWHILE =>
		advance();
		expect(TLPAREN, "(");
		c := parseassign();
		expect(TRPAREN, ")");
		body := parsestmt();
		return ref Stmt.While(c, body);
	TFOR =>
		advance();
		expect(TLPAREN, "(");
		savedpos := pos;
		if(cur().kind == TIDENT){
			vname := cur().s;
			advance();
			if(cur().kind == TIDENT && cur().s == "in"){
				advance();
				arrname := expect(TIDENT, "array name").s;
				expect(TRPAREN, ")");
				body := parsestmt();
				return ref Stmt.Foreach(vname, arrname, body);
			}
		}
		pos = savedpos;
		ini: ref Stmt;
		if(cur().kind != TSEMI)
			ini = parsesimplestmt();
		expect(TSEMI, ";");
		cond: ref Expr;
		if(cur().kind != TSEMI)
			cond = parseassign();
		expect(TSEMI, ";");
		post: ref Stmt;
		if(cur().kind != TRPAREN)
			post = parsesimplestmt();
		expect(TRPAREN, ")");
		body := parsestmt();
		return ref Stmt.For(ini, cond, post, body);
	TPRINT =>
		advance();
		args: list of ref Expr;
		if(cur().kind != TSEMI && cur().kind != TRBRACE && cur().kind != TEOF)
			args = parseexprlist();
		if(cur().kind == TSEMI)
			advance();
		return ref Stmt.Print(args);
	TPRINTF =>
		advance();
		args: list of ref Expr;
		if(cur().kind != TSEMI && cur().kind != TRBRACE && cur().kind != TEOF)
			args = parseexprlist();
		if(cur().kind == TSEMI)
			advance();
		return ref Stmt.Printf(args);
	TNEXT =>
		advance();
		if(cur().kind == TSEMI)
			advance();
		return ref Stmt.Next(0);
	TSEMI =>
		advance();
		return ref Stmt.Block(nil);
	* =>
		e := parseassign();
		if(cur().kind == TSEMI)
			advance();
		return ref Stmt.Exprstmt(e);
	}
}

parserule(): ref Rule
{
	t := cur();
	if(t.kind == TBEGIN){
		advance();
		act := parseblock();
		return ref Rule(RBEGIN, nil, act);
	}
	if(t.kind == TEND){
		advance();
		act := parseblock();
		return ref Rule(REND, nil, act);
	}
	if(t.kind == TLBRACE){
		act := parseblock();
		return ref Rule(RALWAYS, nil, act);
	}
	pat := parseassign();
	if(cur().kind == TLBRACE){
		act := parseblock();
		return ref Rule(RPAT, pat, act);
	}
	defaction := ref Stmt.Print(ref Expr.Field(ref Expr.Num(0.0)) :: nil);
	return ref Rule(RPAT, pat, defaction);
}

parseprogram(src: string): list of ref Rule
{
	toks = lex(src);
	pos = 0;
	rules: list of ref Rule;
	while(cur().kind != TEOF){
		if(cur().kind == TSEMI){
			advance();
			continue;
		}
		rules = parserule() :: rules;
	}
	return revrulelist(rules);
}

# ---------------------------------------------------------- interpreter

Var: adt
{
	name:	string;
	val:	Val;
};

ACell: adt
{
	key:	string;
	val:	Val;
	next:	cyclic ref ACell;
};

Arr: adt
{
	name:		string;
	buckets:	array of ref ACell;
};

NBUCKETS: con 1021;

globalvars:	list of ref Var;
globalarrs:	list of ref Arr;
fields:		array of string;	# fields[0] == $0
nf:		int;
nr:		int;
fsvar:		string;
ofsvar:		string;
orsvar:		string;
fnamevar:	string;
capturing:	int;	# 1 inside runstring(): emit() appends to outbuf
outbuf:		string;	# instead of writing sys->print, for in-process tests

emit(s: string)
{
	if(capturing)
		outbuf += s;
	else
		sys->print("%s", s);
}

triml(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	return s[i:];
}

trimr(s: string): string
{
	i := len s;
	while(i > 0 && (s[i-1] == ' ' || s[i-1] == '\t'))
		i--;
	return s[0:i];
}

numstr(n: real): string
{
	return sys->sprint("%.6g", n);
}

mknum(n: real): Val
{
	return Val(numstr(n), n, 1);
}

mkstr(s: string): Val
{
	return Val(s, 0.0, 0);
}

mkstrnum(s: string): Val
{
	t := triml(s);
	if(t == "")
		return Val(s, 0.0, 0);
	(v, rem) := str->toreal(t, 10);
	rem = trimr(rem);
	if(rem == "")
		return Val(s, v, 1);
	return Val(s, 0.0, 0);
}

tonum(v: Val): real
{
	if(v.isnum)
		return v.n;
	t := triml(v.s);
	(n, nil) := str->toreal(t, 10);
	return n;
}

tostr(v: Val): string
{
	return v.s;
}

truthy(v: Val): int
{
	if(v.isnum)
		return v.n != 0.0;
	return len v.s > 0;
}

cmpval(a: Val, b: Val): int
{
	if(a.isnum && b.isnum){
		if(a.n < b.n)
			return -1;
		if(a.n > b.n)
			return 1;
		return 0;
	}
	if(a.s < b.s)
		return -1;
	if(a.s > b.s)
		return 1;
	return 0;
}

indexof(s: string, t: string): int
{
	if(len t == 0)
		return 0;
	n := len s;
	m := len t;
	for(i := 0; i <= n-m; i++)
		if(s[i:i+m] == t)
			return i;
	return -1;
}

substr(s: string, m: int, n: int): string
{
	L := len s;
	start := m - 1;
	if(start < 0)
		start = 0;
	if(start > L)
		start = L;
	e := L;
	if(n >= 0){
		e = m - 1 + n;
		if(e < start)
			e = start;
		if(e > L)
			e = L;
	}
	return s[start:e];
}

revstrarr(l: list of string): array of string
{
	n := len l;
	a := array[n] of string;
	i := n - 1;
	for(; l != nil; l = tl l){
		a[i] = hd l;
		i--;
	}
	return a;
}

splitws(line: string): array of string
{
	r: list of string;
	i := 0;
	n := len line;
	while(i < n){
		while(i < n && (line[i] == ' ' || line[i] == '\t' || line[i] == '\n'))
			i++;
		if(i >= n)
			break;
		start := i;
		while(i < n && !(line[i] == ' ' || line[i] == '\t' || line[i] == '\n'))
			i++;
		r = line[start:i] :: r;
	}
	return revstrarr(r);
}

splitchars(line: string): array of string
{
	a := array[len line] of string;
	for(i := 0; i < len line; i++)
		a[i] = line[i:i+1];
	return a;
}

splitonechar(line: string, sep: int): array of string
{
	r: list of string;
	start := 0;
	for(i := 0; i < len line; i++){
		if(line[i] == sep){
			r = line[start:i] :: r;
			start = i+1;
		}
	}
	r = line[start:len line] :: r;
	return revstrarr(r);
}

splitliteral(line: string, sep: string): array of string
{
	r: list of string;
	seplen := len sep;
	start := 0;
	i := 0;
	n := len line;
	while(i <= n - seplen){
		if(line[i:i+seplen] == sep){
			r = line[start:i] :: r;
			i += seplen;
			start = i;
		} else
			i++;
	}
	r = line[start:n] :: r;
	return revstrarr(r);
}

splitfields(line: string, fs: string): array of string
{
	if(fs == " ")
		return splitws(line);
	if(fs == "")
		return splitchars(line);
	if(len fs == 1)
		return splitonechar(line, fs[0]);
	return splitliteral(line, fs);
}

rebuild0()
{
	s := "";
	for(i := 1; i <= nf; i++){
		if(i > 1)
			s += ofsvar;
		s += fields[i];
	}
	fields[0] = s;
}

setrecord(line: string)
{
	parts := splitfields(line, fsvar);
	fields = array[len parts + 1] of string;
	fields[0] = line;
	for(i := 0; i < len parts; i++)
		fields[i+1] = parts[i];
	nf = len parts;
}

setnf(newnf: int)
{
	if(newnf < 0)
		newnf = 0;
	newfields := array[newnf+1] of string;
	m := newnf;
	if(nf < m)
		m = nf;
	for(i := 0; i <= m; i++)
		newfields[i] = fields[i];
	fields = newfields;
	nf = newnf;
	rebuild0();
}

getfield(idx: int): string
{
	if(idx == 0)
		return fields[0];
	if(idx < 0 || idx > nf)
		return "";
	return fields[idx];
}

setfield(idx: int, v: string)
{
	if(idx == 0){
		setrecord(v);
		return;
	}
	if(idx > nf){
		newfields := array[idx+1] of string;
		newfields[0:] = fields[0:nf+1];
		fields = newfields;
		nf = idx;
	}
	fields[idx] = v;
	rebuild0();
}

getvarcell(name: string): ref Var
{
	for(l := globalvars; l != nil; l = tl l)
		if((hd l).name == name)
			return hd l;
	v := ref Var(name, Val("", 0.0, 1));
	globalvars = v :: globalvars;
	return v;
}

getvar(name: string): Val
{
	case name {
	"NR" =>		return mknum(real nr);
	"NF" =>		return mknum(real nf);
	"FS" =>		return mkstr(fsvar);
	"OFS" =>	return mkstr(ofsvar);
	"ORS" =>	return mkstr(orsvar);
	"FILENAME" =>	return mkstr(fnamevar);
	}
	return getvarcell(name).val;
}

setvar(name: string, v: Val)
{
	case name {
	"NR" =>		nr = int tonum(v); return;
	"NF" =>		setnf(int tonum(v)); return;
	"FS" =>		fsvar = tostr(v); return;
	"OFS" =>	ofsvar = tostr(v); return;
	"ORS" =>	orsvar = tostr(v); return;
	"FILENAME" =>	fnamevar = tostr(v); return;
	}
	c := getvarcell(name);
	c.val = v;
}

findarr(name: string): ref Arr
{
	for(l := globalarrs; l != nil; l = tl l)
		if((hd l).name == name)
			return hd l;
	a := ref Arr(name, array[NBUCKETS] of ref ACell);
	globalarrs = a :: globalarrs;
	return a;
}

hashstr(s: string): int
{
	h := 0;
	for(i := 0; i < len s; i++)
		h = h*31 + s[i];
	if(h < 0)
		h = -h;
	return h % NBUCKETS;
}

arrget(a: ref Arr, key: string): Val
{
	h := hashstr(key);
	for(c := a.buckets[h]; c != nil; c = c.next)
		if(c.key == key)
			return c.val;
	nc := ref ACell(key, Val("", 0.0, 1), a.buckets[h]);
	a.buckets[h] = nc;
	return nc.val;
}

arrset(a: ref Arr, key: string, v: Val)
{
	h := hashstr(key);
	for(c := a.buckets[h]; c != nil; c = c.next){
		if(c.key == key){
			c.val = v;
			return;
		}
	}
	nc := ref ACell(key, v, a.buckets[h]);
	a.buckets[h] = nc;
}

clritems(a: ref Arr)
{
	for(i := 0; i < len a.buckets; i++)
		a.buckets[i] = nil;
}

matchre(s: string, pat: string): int
{
	(re, err) := regex->compile(pat, 0);
	if(re == nil){
		sys->fprint(stderr, "awk: bad regex /%s/: %s\n", pat, err);
		raise "fail:regex";
	}
	m := regex->execute(re, s);
	return m != nil;
}

exprvarname(e: ref Expr): string
{
	pick x := e {
	Var =>
		return x.name;
	* =>
		parseerror("split() needs a plain array name");
	}
	return "";
}

# sys->sprint requires its format argument to be a compile-time string
# constant (the compiler checks conversions against arg types), so a
# printf spec parsed from awk source at run time can never be handed to
# it directly. Width/precision are parsed here and applied by hand
# instead; the actual conversion goes through one of a fixed set of
# literal-constant format strings below, keyed on the parsed precision.

Fspec: adt
{
	leftalign:	int;
	zeropad:	int;
	width:		int;	# -1 if unspecified
	prec:		int;	# -1 if unspecified
};

parsespec(s: string): Fspec
{
	i := 1;	# skip leading '%'
	n := len s;
	leftalign := 0;
	zeropad := 0;
	while(i < n && (s[i] == '-' || s[i] == '0')){
		if(s[i] == '-')
			leftalign = 1;
		else
			zeropad = 1;
		i++;
	}
	width := -1;
	if(i < n && isdigit(s[i])){
		width = 0;
		while(i < n && isdigit(s[i])){
			width = width*10 + (s[i]-'0');
			i++;
		}
	}
	prec := -1;
	if(i < n && s[i] == '.'){
		i++;
		prec = 0;
		while(i < n && isdigit(s[i])){
			prec = prec*10 + (s[i]-'0');
			i++;
		}
	}
	return Fspec(leftalign, zeropad, width, prec);
}

pad(s: string, sp: Fspec): string
{
	if(sp.width < 0 || len s >= sp.width)
		return s;
	npad := sp.width - len s;
	padchar := ' ';
	if(sp.zeropad && !sp.leftalign)
		padchar = '0';
	padstr := "";
	for(i := 0; i < npad; i++)
		padstr[len padstr] = padchar;
	if(sp.leftalign)
		return s + padstr;
	return padstr + s;
}

applyprec(s: string, sp: Fspec): string
{
	if(sp.prec >= 0 && sp.prec < len s)
		return s[0:sp.prec];
	return s;
}

# prec clamped to [0,6] - plenty for demo-scale use, and lets the
# conversion go through a literal (compile-time-constant) format string
# per precision value instead of one built at run time.
fmtreal(conv: int, prec: int, v: real): string
{
	if(prec < 0)
		prec = 6;
	if(prec > 6)
		prec = 6;
	case conv {
	'f' =>
		case prec {
		0 =>	return sys->sprint("%.0f", v);
		1 =>	return sys->sprint("%.1f", v);
		2 =>	return sys->sprint("%.2f", v);
		3 =>	return sys->sprint("%.3f", v);
		4 =>	return sys->sprint("%.4f", v);
		5 =>	return sys->sprint("%.5f", v);
		* =>	return sys->sprint("%.6f", v);
		}
	'e' =>
		case prec {
		0 =>	return sys->sprint("%.0e", v);
		1 =>	return sys->sprint("%.1e", v);
		2 =>	return sys->sprint("%.2e", v);
		3 =>	return sys->sprint("%.3e", v);
		4 =>	return sys->sprint("%.4e", v);
		5 =>	return sys->sprint("%.5e", v);
		* =>	return sys->sprint("%.6e", v);
		}
	* =>
		case prec {
		0 =>	return sys->sprint("%.0g", v);
		1 =>	return sys->sprint("%.1g", v);
		2 =>	return sys->sprint("%.2g", v);
		3 =>	return sys->sprint("%.3g", v);
		4 =>	return sys->sprint("%.4g", v);
		5 =>	return sys->sprint("%.5g", v);
		* =>	return sys->sprint("%.6g", v);
		}
	}
}

doformat(args: list of ref Expr): string
{
	if(args == nil)
		return "";
	fmt := tostr(evalexpr(hd args));
	rest := tl args;
	out := "";
	i := 0;
	n := len fmt;
	while(i < n){
		c := fmt[i];
		if(c != '%'){
			out[len out] = c;
			i++;
			continue;
		}
		i++;
		if(i >= n)
			break;
		spec := "%";
		while(i < n && (fmt[i] == '-' || fmt[i] == '+' || fmt[i] == '0' ||
				isdigit(fmt[i]) || fmt[i] == '.')){
			spec[len spec] = fmt[i];
			i++;
		}
		if(i >= n)
			break;
		conv := fmt[i];
		i++;
		v: Val;
		if(conv != '%'){
			if(rest == nil)
				v = mkstr("");
			else {
				v = evalexpr(hd rest);
				rest = tl rest;
			}
		}
		sp := parsespec(spec);
		case conv {
		'%' =>
			out += "%";
		's' =>
			out += pad(applyprec(tostr(v), sp), sp);
		'd' or 'i' =>
			out += pad(sys->sprint("%d", int tonum(v)), sp);
		'f' =>
			out += pad(fmtreal('f', sp.prec, tonum(v)), sp);
		'g' =>
			out += pad(fmtreal('g', sp.prec, tonum(v)), sp);
		'e' =>
			out += pad(fmtreal('e', sp.prec, tonum(v)), sp);
		'c' =>
			s := tostr(v);
			if(len s > 0)
				out += s[0:1];
		* =>
			out += spec + string conv;
		}
	}
	return out;
}

evalcall(name: string, args: list of ref Expr): Val
{
	case name {
	"length" =>
		if(args == nil)
			return mknum(real (len getfield(0)));
		return mknum(real (len tostr(evalexpr(hd args))));
	"substr" =>
		s := tostr(evalexpr(hd args));
		rest := tl args;
		m := int tonum(evalexpr(hd rest));
		rest = tl rest;
		n := -1;
		if(rest != nil)
			n = int tonum(evalexpr(hd rest));
		return mkstr(substr(s, m, n));
	"index" =>
		s := tostr(evalexpr(hd args));
		t := tostr(evalexpr(hd tl args));
		return mknum(real (indexof(s, t)+1));
	"split" =>
		s := tostr(evalexpr(hd args));
		arglist := tl args;
		arrname := exprvarname(hd arglist);
		fs := fsvar;
		arglist = tl arglist;
		if(arglist != nil)
			fs = tostr(evalexpr(hd arglist));
		a := findarr(arrname);
		clritems(a);
		parts := splitfields(s, fs);
		for(i := 0; i < len parts; i++)
			arrset(a, string (i+1), mkstrnum(parts[i]));
		return mknum(real (len parts));
	"sprintf" =>
		return mkstr(doformat(args));
	"toupper" =>
		return mkstr(str->toupper(tostr(evalexpr(hd args))));
	"tolower" =>
		return mkstr(str->tolower(tostr(evalexpr(hd args))));
	"int" =>
		return mknum(real (int tonum(evalexpr(hd args))));
	}
	sys->fprint(stderr, "awk: unknown function %s\n", name);
	raise "fail:syntax";
	return mkstr("");
}

evalbin(op: int, le: ref Expr, re: ref Expr): Val
{
	case op {
	OAND =>
		if(!truthy(evalexpr(le)))
			return mknum(0.0);
		return mknum(real (truthy(evalexpr(re))));
	OOR =>
		if(truthy(evalexpr(le)))
			return mknum(1.0);
		return mknum(real (truthy(evalexpr(re))));
	OCONCAT =>
		return mkstr(tostr(evalexpr(le)) + tostr(evalexpr(re)));
	OMATCH =>
		return mknum(real (matchre(tostr(evalexpr(le)), tostr(evalexpr(re)))));
	ONOMATCH =>
		return mknum(real (!matchre(tostr(evalexpr(le)), tostr(evalexpr(re)))));
	}
	a := evalexpr(le);
	b := evalexpr(re);
	case op {
	OADD =>	return mknum(tonum(a) + tonum(b));
	OSUB =>	return mknum(tonum(a) - tonum(b));
	OMUL =>	return mknum(tonum(a) * tonum(b));
	ODIV =>	return mknum(tonum(a) / tonum(b));
	OMOD =>
		x := tonum(a);
		y := tonum(b);
		return mknum(x - y * real (int (x/y)));
	OLT =>	return mknum(real (cmpval(a,b) < 0));
	OLE =>	return mknum(real (cmpval(a,b) <= 0));
	OGT =>	return mknum(real (cmpval(a,b) > 0));
	OGE =>	return mknum(real (cmpval(a,b) >= 0));
	OEQ =>	return mknum(real (cmpval(a,b) == 0));
	ONE =>	return mknum(real (cmpval(a,b) != 0));
	}
	return mkstr("");
}

combine(op: int, cur: Val, rhse: ref Expr): Val
{
	rv := evalexpr(rhse);
	if(op == AASSIGN)
		return rv;
	cx := tonum(cur);
	cy := tonum(rv);
	case op {
	AADD =>	return mknum(cx+cy);
	ASUB =>	return mknum(cx-cy);
	AMUL =>	return mknum(cx*cy);
	ADIV =>	return mknum(cx/cy);
	AMOD =>	return mknum(cx - cy*real(int(cx/cy)));
	}
	return rv;
}

# shared by evalexpr's Incdec case; the same known limitation as
# evalassign's Arrayref/Field arms applies (a side-effecting index or
# field-number expression, e.g. arr[i++], evaluates that subexpression
# twice - once to read, once to write).
getlval(e: ref Expr): Val
{
	pick x := e {
	Var =>
		return getvar(x.name);
	Arrayref =>
		a := findarr(x.name);
		k := tostr(evalexpr(x.idx));
		return arrget(a, k);
	Field =>
		idx := int tonum(evalexpr(x.idx));
		return mkstrnum(getfield(idx));
	* =>
		parseerror("bad lvalue");
	}
	return mkstr("");
}

setlval(e: ref Expr, v: Val)
{
	pick x := e {
	Var =>
		setvar(x.name, v);
	Arrayref =>
		a := findarr(x.name);
		k := tostr(evalexpr(x.idx));
		arrset(a, k, v);
	Field =>
		idx := int tonum(evalexpr(x.idx));
		setfield(idx, tostr(v));
	* =>
		parseerror("bad lvalue");
	}
}

evalassign(op: int, lhs: ref Expr, rhs: ref Expr): Val
{
	pick x := lhs {
	Var =>
		rv := combine(op, getvar(x.name), rhs);
		setvar(x.name, rv);
		return rv;
	Arrayref =>
		a := findarr(x.name);
		k := tostr(evalexpr(x.idx));
		rv := combine(op, arrget(a, k), rhs);
		arrset(a, k, rv);
		return rv;
	Field =>
		idx := int tonum(evalexpr(x.idx));
		rv := combine(op, mkstrnum(getfield(idx)), rhs);
		setfield(idx, tostr(rv));
		return rv;
	* =>
		parseerror("bad assignment target");
	}
	return mkstr("");
}

evalexpr(e: ref Expr): Val
{
	pick x := e {
	Num =>
		return mknum(x.v);
	Str =>
		return mkstr(x.v);
	Regexlit =>
		return mknum(real (matchre(getfield(0), x.src)));
	Field =>
		idx := int tonum(evalexpr(x.idx));
		return mkstrnum(getfield(idx));
	Var =>
		return getvar(x.name);
	Arrayref =>
		a := findarr(x.name);
		k := tostr(evalexpr(x.idx));
		return arrget(a, k);
	Call =>
		return evalcall(x.name, x.args);
	Unary =>
		v := evalexpr(x.e);
		case x.op {
		UNEG =>	return mknum(-tonum(v));
		UPOS =>	return mknum(tonum(v));
		UNOT =>	return mknum(real (!truthy(v)));
		}
		return mknum(0.0);
	Bin =>
		return evalbin(x.op, x.l, x.r);
	Assign =>
		return evalassign(x.op, x.lhs, x.rhs);
	Ternary =>
		if(truthy(evalexpr(x.c)))
			return evalexpr(x.t);
		return evalexpr(x.f);
	Incdec =>
		oldn := tonum(getlval(x.target));
		newn := oldn;
		if(x.inc)
			newn = oldn + 1.0;
		else
			newn = oldn - 1.0;
		setlval(x.target, mknum(newn));
		if(x.prefix)
			return mknum(newn);
		return mknum(oldn);
	}
	return mkstr("");
}

doprint(args: list of ref Expr)
{
	if(args == nil){
		emit(getfield(0) + orsvar);
		return;
	}
	out := "";
	first := 1;
	for(l := args; l != nil; l = tl l){
		if(!first)
			out += ofsvar;
		first = 0;
		out += tostr(evalexpr(hd l));
	}
	emit(out + orsvar);
}

execstmt(s: ref Stmt): int
{
	pick x := s {
	Exprstmt =>
		evalexpr(x.e);
		return SNORMAL;
	Print =>
		doprint(x.args);
		return SNORMAL;
	Printf =>
		emit(doformat(x.args));
		return SNORMAL;
	If =>
		if(truthy(evalexpr(x.c)))
			return execstmt(x.t);
		if(x.f != nil)
			return execstmt(x.f);
		return SNORMAL;
	While =>
		while(truthy(evalexpr(x.c))){
			sig := execstmt(x.body);
			if(sig != SNORMAL)
				return sig;
		}
		return SNORMAL;
	For =>
		if(x.init != nil)
			execstmt(x.init);
		for(;;){
			if(x.cond != nil && !truthy(evalexpr(x.cond)))
				break;
			sig := execstmt(x.body);
			if(sig != SNORMAL)
				return sig;
			if(x.post != nil)
				execstmt(x.post);
		}
		return SNORMAL;
	Block =>
		for(l := x.stmts; l != nil; l = tl l){
			sig := execstmt(hd l);
			if(sig != SNORMAL)
				return sig;
		}
		return SNORMAL;
	Next =>
		return SNEXT;
	Foreach =>
		a := findarr(x.arrname);
		for(bi := 0; bi < len a.buckets; bi++){
			for(c := a.buckets[bi]; c != nil; c = c.next){
				setvar(x.var, mkstrnum(c.key));
				sig := execstmt(x.body);
				if(sig != SNORMAL)
					return sig;
			}
		}
		return SNORMAL;
	}
	return SNORMAL;
}

runrules(rules: list of ref Rule, kind: int)
{
	for(l := rules; l != nil; l = tl l){
		r := hd l;
		if(r.kind == kind)
			execstmt(r.action);
	}
}

processline(rules: list of ref Rule, line: string)
{
	setrecord(line);
	nr++;
	for(l := rules; l != nil; l = tl l){
		r := hd l;
		if(r.kind == RBEGIN || r.kind == REND)
			continue;
		fire := 1;
		if(r.kind == RPAT)
			fire = truthy(evalexpr(r.pat));
		if(fire){
			sig := execstmt(r.action);
			if(sig == SNEXT)
				return;
		}
	}
}

needsinput(rules: list of ref Rule): int
{
	for(l := rules; l != nil; l = tl l){
		k := (hd l).kind;
		if(k == RPAT || k == RALWAYS || k == REND)
			return 1;
	}
	return 0;
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

processfile(rules: list of ref Rule, f: ref Iobuf)
{
	for(;;){
		line := f.gets('\n');
		if(line == nil)
			break;
		if(len line > 0 && line[len line - 1] == '\n')
			line = line[0:len line - 1];
		processline(rules, line);
	}
}

isident(s: string): int
{
	if(len s == 0)
		return 0;
	c := s[0];
	if(!(isalpha(c) || c == '_'))
		return 0;
	for(i := 1; i < len s; i++){
		c = s[i];
		if(!(isalpha(c) || isdigit(c) || c == '_'))
			return 0;
	}
	return 1;
}

isassignarg(s: string): int
{
	i := indexof(s, "=");
	if(i < 0)
		return 0;
	return isident(s[0:i]);
}

applyassign(s: string)
{
	i := indexof(s, "=");
	if(i < 0)
		return;
	name := s[0:i];
	val := s[i+1:len s];
	if(!isident(name))
		return;
	setvar(name, mkstrnum(val));
}

usage()
{
	sys->fprint(stderr,
		"usage: awk [-F fs] [-v var=val] {-f progfile | 'program'} [file ...]\n");
	raise "fail:usage";
}

resetstate()
{
	globalvars = nil;
	globalarrs = nil;
	fields = nil;
	nf = 0;
	nr = 0;
	fsvar = " ";
	ofsvar = " ";
	orsvar = "\n";
	fnamevar = "";
}

runstring(prog: string, input: string): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(regex == nil)
		regex = load Regex Regex->PATH;
	if(str == nil)
		str = load String String->PATH;
	if(stderr == nil)
		stderr = sys->fildes(2);

	resetstate();
	outbuf = "";
	capturing = 1;

	if(len input > 0 && input[len input - 1] == '\n')
		input = input[0:len input - 1];

	rules := parseprogram(prog);
	runrules(rules, RBEGIN);
	if(needsinput(rules) && input != ""){
		lines := splitonechar(input, '\n');
		for(i := 0; i < len lines; i++)
			processline(rules, lines[i]);
	}
	runrules(rules, REND);

	capturing = 0;
	return outbuf;
}

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stdin = sys->fildes(0);
	stdout = sys->fildes(1);
	stderr = sys->fildes(2);

	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	regex = load Regex Regex->PATH;
	str = load String String->PATH;
	if(arg == nil || bufio == nil || regex == nil || str == nil){
		sys->fprint(stderr, "awk: cannot load a required module\n");
		raise "fail:module";
	}

	fsvar = " ";
	ofsvar = " ";
	orsvar = "\n";
	fnamevar = "";

	progtext := "";
	haveprog := 0;
	vassigns: list of string;

	arg->init(argv);
	while((opt := arg->opt()) != 0){
		case opt {
		'F' =>
			fsvar = arg->earg();
		'v' =>
			vassigns = arg->earg() :: vassigns;
		'f' =>
			fname := arg->earg();
			f := bufio->open(fname, Bufio->OREAD);
			if(f == nil){
				sys->fprint(stderr, "awk: cannot open %s: %r\n", fname);
				raise "fail:open";
			}
			progtext += readall(f);
			haveprog = 1;
		* =>
			usage();
		}
	}
	rest := arg->argv();
	arg = nil;

	if(!haveprog){
		if(rest == nil)
			usage();
		progtext = hd rest;
		rest = tl rest;
	}

	rules := parseprogram(progtext);

	for(l := vassigns; l != nil; l = tl l)
		applyassign(hd l);

	runrules(rules, RBEGIN);

	if(needsinput(rules)){
		if(rest == nil)
			processfile(rules, bufio->fopen(stdin, Bufio->OREAD));
		else {
			for(; rest != nil; rest = tl rest){
				curfile := hd rest;
				if(isassignarg(curfile)){
					applyassign(curfile);
					continue;
				}
				fnamevar = curfile;
				f := bufio->open(curfile, Bufio->OREAD);
				if(f == nil){
					sys->fprint(stderr, "awk: cannot open %s: %r\n", curfile);
					continue;
				}
				processfile(rules, f);
			}
		}
	}

	runrules(rules, REND);
}
