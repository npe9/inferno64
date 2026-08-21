implement Basic;

# Nelson's Dream Machines chapter on languages covers BASIC alongside
# TRAC and APL as one of the era's populist answers to "how should
# ordinary people program a computer" - line-numbered, imperative,
# built around PRINT/INPUT/GOTO/FOR rather than TRAC's pure string
# rewriting or APL's dense array notation. This is that shape: every
# line starts with a number (its address for GOTO/GOSUB), statements
# run top to bottom by line-number order unless control flow says
# otherwise, and there is no structure beyond what GOTO/GOSUB/FOR give
# you - the same "everything is a label and a jump" flavour as real
# 1970s-80s BASICs, not a tidied-up modern reinterpretation.
#
# Statements: LET (keyword optional - "X = 5" works same as "LET X =
# 5"), PRINT (comma inserts a tab, trailing semicolon suppresses the
# newline), INPUT (with an optional "INPUT "prompt"; VAR" prompt
# string), IF <cond> THEN <stmt-or-linenumber>, GOTO, GOSUB/RETURN,
# FOR/TO/STEP/NEXT, END, REM.
#
# Expressions: + - * / MOD, string concatenation via + when either
# side is a string, comparisons = <> < > <= >= (string operands compare
# lexicographically, matching Limbo's own native string ordering),
# parentheses, unary minus, and a small built-in function library -
# LEN(s$), VAL(s$), STR$(n), ABS(n), INT(n) - enough to write a real
# string-processing example, not just arithmetic. Variable names follow
# the classic convention: a trailing '$' makes it a string variable
# ("A$" and "A" are unrelated variables), everything else is numeric
# (a real, not distinguishing int/float - numbers print without a
# decimal point when they're whole, same as most BASICs' PRINT did).
#
# Left out, a genuine scope cut rather than an oversight: arrays/DIM,
# DEF FN, and any function beyond the five above. A program needing
# those just doesn't have them available, the same as it wouldn't in a
# BASIC that never implemented them either. String literals also can't
# contain a literal '"' at all - no doubled-quote ("" -> ") escaping
# like classic BASIC had, since the lexer just scans to the next '"'
# unconditionally; a title needing a quote mark has to work around it
# rather than escape it.
#
# usage: basic file.bas

include "sys.m";
	sys: Sys;

include "draw.m";
	Context: import Draw;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "math.m";
	math: Math;

Basic: module {
	init: fn(ctxt: ref Context, argv: list of string);
};

stdout, stderr: ref Sys->FD;
stdin: ref Iobuf;

# --- tokens ---

TKNUM, TKSTR, TKIDENT, TKOP, TKEOF: con iota;

Tok: adt {
	kind:	int;
	sval:	string;
	nval:	real;
};

# --- expressions ---

EKNUM, EKSTR, EKVAR, EKUNM, EKBIN, EKCALL: con iota;

Expr: adt {
	kind:	int;
	num:	real;
	str:	string;
	name:	string;
	op:	string;
	l, r:	ref Expr;
};

# --- statements ---

SKREM, SKLET, SKPRINT, SKIF, SKGOTO, SKGOSUB, SKRETURN, SKFOR, SKNEXT, SKINPUT, SKEND: con iota;

PrintItem: adt {
	e:	ref Expr;
	sep:	int;	# ',' or ';' if one follows this item in source, else 0
};

Stmt: adt {
	lineno:	int;
	kind:	int;
	var:	string;
	e1, e2, e3: ref Expr;		# LET rhs / IF cond+prompt(INPUT) / FOR start,limit,step
	items:	list of ref PrintItem;	# PRINT
	thenstmt: ref Stmt;		# IF ... THEN <stmt> (nil if THEN <linenumber> instead)
	n1:	int;			# GOTO/GOSUB/IF-THEN target line; also PRINT's trailing-";" flag
};

# --- values and variables ---

Value: adt {
	isstr:	int;
	num:	real;
	str:	string;
};

Var: adt {
	name:	string;
	val:	Value;
};

Forframe: adt {
	var:	string;
	limit:	real;
	step:	real;
	stmtidx: int;
};

vars: list of ref Var;
forstack: list of ref Forframe;
gosubstack: list of int;
prog: array of ref Stmt;

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	math = load Math Math->PATH;
	stdout = sys->fildes(1);
	stderr = sys->fildes(2);
	stdin = bufio->fopen(sys->fildes(0), Sys->OREAD);

	argv = tl argv;
	if(argv == nil){
		sys->fprint(stderr, "usage: basic file.bas\n");
		raise "fail:usage";
	}
	(src, err) := readfile(hd argv);
	if(src == nil){
		sys->fprint(stderr, "basic: %s\n", err);
		raise "fail:open";
	}

	(p, perr) := loadprogram(src);
	if(p == nil){
		sys->fprint(stderr, "basic: %s\n", perr);
		raise "fail:parse";
	}
	prog = p;
	run();
}

# --- loading ---

loadprogram(src: string): (array of ref Stmt, string)
{
	(nil, lines) := sys->tokenize(src, "\n");
	stmts: list of ref Stmt;
	for(l := lines; l != nil; l = tl l){
		line := hd l;
		toks := lex(line);
		if(toks[0].kind == TKEOF)
			continue;
		if(toks[0].kind != TKNUM)
			return (nil, sys->sprint("line %q: does not start with a line number", line));
		lineno := int toks[0].nval;
		pr := ref Parser(toks, 1);
		st := parsestmt(pr);
		st.lineno = lineno;
		stmts = st :: stmts;
	}
	arr := array[lenstmts(stmts)] of ref Stmt;
	i := 0;
	for(s := revstmts(stmts); s != nil; s = tl s){
		arr[i] = hd s;
		i++;
	}
	sortstmts(arr);
	return (arr, nil);
}

sortstmts(a: array of ref Stmt)
{
	# insertion sort - programs are small, and usually already ordered
	for(i := 1; i < len a; i++){
		v := a[i];
		j := i-1;
		while(j >= 0 && a[j].lineno > v.lineno){
			a[j+1] = a[j];
			j--;
		}
		a[j+1] = v;
	}
}

# --- lexer ---

lex(s: string): array of ref Tok
{
	toks: list of ref Tok;
	i := 0;
	n := len s;
	while(i < n){
		c := s[i];
		if(c == ' ' || c == '\t'){
			i++;
			continue;
		}
		if(isdigit(c) || (c == '.' && i+1 < n && isdigit(s[i+1]))){
			j := i;
			while(j < n && (isdigit(s[j]) || s[j] == '.'))
				j++;
			numstr := s[i:j];
			toks = ref Tok(TKNUM, numstr, real numstr) :: toks;
			i = j;
			continue;
		}
		if(c == '"'){
			j := i+1;
			buf := "";
			while(j < n && s[j] != '"'){
				buf += onechar(s[j]);
				j++;
			}
			toks = ref Tok(TKSTR, buf, 0.0) :: toks;
			i = j+1;
			continue;
		}
		if(isalpha(c)){
			j := i;
			while(j < n && (isalpha(s[j]) || isdigit(s[j])))
				j++;
			if(j < n && s[j] == '$')
				j++;
			toks = ref Tok(TKIDENT, upper(s[i:j]), 0.0) :: toks;
			i = j;
			continue;
		}
		if(c == '<' && i+1 < n && s[i+1] == '='){
			toks = ref Tok(TKOP, "<=", 0.0) :: toks;
			i += 2;
			continue;
		}
		if(c == '>' && i+1 < n && s[i+1] == '='){
			toks = ref Tok(TKOP, ">=", 0.0) :: toks;
			i += 2;
			continue;
		}
		if(c == '<' && i+1 < n && s[i+1] == '>'){
			toks = ref Tok(TKOP, "<>", 0.0) :: toks;
			i += 2;
			continue;
		}
		toks = ref Tok(TKOP, onechar(c), 0.0) :: toks;
		i++;
	}
	toks = ref Tok(TKEOF, "", 0.0) :: toks;
	toks = revtoks(toks);
	arr := array[lentoks(toks)] of ref Tok;
	i = 0;
	for(t := toks; t != nil; t = tl t){
		arr[i] = hd t;
		i++;
	}
	return arr;
}

# --- parser ---

Parser: adt {
	toks:	array of ref Tok;
	pos:	int;
};

peek(p: ref Parser): ref Tok
{
	return p.toks[p.pos];
}

advance(p: ref Parser): ref Tok
{
	t := p.toks[p.pos];
	if(p.pos < len p.toks - 1)
		p.pos++;
	return t;
}

iskw(t: ref Tok, w: string): int
{
	return t.kind == TKIDENT && t.sval == w;
}

isopch(t: ref Tok, w: string): int
{
	return t.kind == TKOP && t.sval == w;
}

parsestmt(p: ref Parser): ref Stmt
{
	t := peek(p);
	if(iskw(t, "REM")){
		while(peek(p).kind != TKEOF)
			advance(p);
		return ref Stmt(0, SKREM, "", nil, nil, nil, nil, nil, 0);
	}
	if(iskw(t, "PRINT"))
		return parseprint(p);
	if(iskw(t, "LET")){
		advance(p);
		return parselet(p);
	}
	if(iskw(t, "GOTO")){
		advance(p);
		ln := int peek(p).nval;
		advance(p);
		return ref Stmt(0, SKGOTO, "", nil, nil, nil, nil, nil, ln);
	}
	if(iskw(t, "GOSUB")){
		advance(p);
		ln := int peek(p).nval;
		advance(p);
		return ref Stmt(0, SKGOSUB, "", nil, nil, nil, nil, nil, ln);
	}
	if(iskw(t, "RETURN")){
		advance(p);
		return ref Stmt(0, SKRETURN, "", nil, nil, nil, nil, nil, 0);
	}
	if(iskw(t, "IF"))
		return parseif(p);
	if(iskw(t, "FOR"))
		return parsefor(p);
	if(iskw(t, "NEXT")){
		advance(p);
		vn := "";
		if(peek(p).kind == TKIDENT){
			vn = peek(p).sval;
			advance(p);
		}
		return ref Stmt(0, SKNEXT, vn, nil, nil, nil, nil, nil, 0);
	}
	if(iskw(t, "INPUT"))
		return parseinput(p);
	if(iskw(t, "END") || iskw(t, "STOP")){
		advance(p);
		return ref Stmt(0, SKEND, "", nil, nil, nil, nil, nil, 0);
	}
	return parselet(p);
}

parselet(p: ref Parser): ref Stmt
{
	vn := peek(p).sval;
	advance(p);
	if(isopch(peek(p), "="))
		advance(p);
	e := parseexpr(p);
	return ref Stmt(0, SKLET, vn, e, nil, nil, nil, nil, 0);
}

parseprint(p: ref Parser): ref Stmt
{
	advance(p);
	items: list of ref PrintItem;
	trailingsemi := 0;
	if(peek(p).kind != TKEOF){
		for(;;){
			e := parseexpr(p);
			sep := 0;
			nt := peek(p);
			if(isopch(nt, ",") || isopch(nt, ";")){
				sep = nt.sval[0];
				advance(p);
			}
			items = ref PrintItem(e, sep) :: items;
			if(sep == 0)
				break;
			if(peek(p).kind == TKEOF){
				if(sep == ';')
					trailingsemi = 1;
				break;
			}
		}
	}
	items = revitems(items);
	return ref Stmt(0, SKPRINT, "", nil, nil, nil, items, nil, trailingsemi);
}

parseif(p: ref Parser): ref Stmt
{
	advance(p);
	cond := parseexpr(p);
	if(iskw(peek(p), "THEN"))
		advance(p);
	nt := peek(p);
	if(nt.kind == TKNUM){
		ln := int nt.nval;
		advance(p);
		return ref Stmt(0, SKIF, "", cond, nil, nil, nil, nil, ln);
	}
	sub := parsestmt(p);
	return ref Stmt(0, SKIF, "", cond, nil, nil, nil, sub, 0);
}

parsefor(p: ref Parser): ref Stmt
{
	advance(p);
	vn := peek(p).sval;
	advance(p);
	if(isopch(peek(p), "="))
		advance(p);
	start := parseexpr(p);
	if(iskw(peek(p), "TO"))
		advance(p);
	limit := parseexpr(p);
	step: ref Expr;
	if(iskw(peek(p), "STEP")){
		advance(p);
		step = parseexpr(p);
	}else
		step = ref Expr(EKNUM, 1.0, "", "", "", nil, nil);
	return ref Stmt(0, SKFOR, vn, start, limit, step, nil, nil, 0);
}

parseinput(p: ref Parser): ref Stmt
{
	advance(p);
	prompt: ref Expr;
	if(peek(p).kind == TKSTR){
		prompt = ref Expr(EKSTR, 0.0, peek(p).sval, "", "", nil, nil);
		advance(p);
		if(isopch(peek(p), ",") || isopch(peek(p), ";"))
			advance(p);
	}
	vn := peek(p).sval;
	advance(p);
	return ref Stmt(0, SKINPUT, vn, prompt, nil, nil, nil, nil, 0);
}

parseexpr(p: ref Parser): ref Expr
{
	l := parseadd(p);
	t := peek(p);
	if(t.kind == TKOP && (t.sval == "=" || t.sval == "<" || t.sval == ">" ||
			      t.sval == "<=" || t.sval == ">=" || t.sval == "<>")){
		op := t.sval;
		advance(p);
		r := parseadd(p);
		return ref Expr(EKBIN, 0.0, "", "", op, l, r);
	}
	return l;
}

parseadd(p: ref Parser): ref Expr
{
	l := parsemul(p);
	for(;;){
		t := peek(p);
		if(isopch(t, "+") || isopch(t, "-")){
			advance(p);
			r := parsemul(p);
			l = ref Expr(EKBIN, 0.0, "", "", t.sval, l, r);
		}else
			break;
	}
	return l;
}

parsemul(p: ref Parser): ref Expr
{
	l := parseunary(p);
	for(;;){
		t := peek(p);
		if(isopch(t, "*") || isopch(t, "/") || iskw(t, "MOD")){
			advance(p);
			r := parseunary(p);
			l = ref Expr(EKBIN, 0.0, "", "", t.sval, l, r);
		}else
			break;
	}
	return l;
}

parseunary(p: ref Parser): ref Expr
{
	t := peek(p);
	if(isopch(t, "-")){
		advance(p);
		return ref Expr(EKUNM, 0.0, "", "", "-", parseunary(p), nil);
	}
	if(isopch(t, "+")){
		advance(p);
		return parseunary(p);
	}
	return parseprimary(p);
}

parseprimary(p: ref Parser): ref Expr
{
	t := peek(p);
	if(t.kind == TKNUM){
		advance(p);
		return ref Expr(EKNUM, t.nval, "", "", "", nil, nil);
	}
	if(t.kind == TKSTR){
		advance(p);
		return ref Expr(EKSTR, 0.0, t.sval, "", "", nil, nil);
	}
	if(t.kind == TKIDENT){
		advance(p);
		if(isopch(peek(p), "(")){
			advance(p);
			arg := parseexpr(p);
			if(isopch(peek(p), ")"))
				advance(p);
			return ref Expr(EKCALL, 0.0, "", t.sval, "", arg, nil);
		}
		return ref Expr(EKVAR, 0.0, "", t.sval, "", nil, nil);
	}
	if(isopch(t, "(")){
		advance(p);
		e := parseexpr(p);
		if(isopch(peek(p), ")"))
			advance(p);
		return e;
	}
	return ref Expr(EKNUM, 0.0, "", "", "", nil, nil);
}

# --- execution ---

run()
{
	ip := 0;
	steps := 0;
	while(ip < len prog){
		ip = exec(prog[ip], ip);
		steps++;
		if(steps > 1000000){
			sys->fprint(stderr, "basic: runaway program (>1000000 steps), aborting\n");
			break;
		}
	}
}

exec(st: ref Stmt, ip: int): int
{
	nextip := ip+1;
	case st.kind {
	SKREM =>
		;
	SKLET =>
		setvar(st.var, eval(st.e1));
	SKPRINT =>
		doprint(st);
	SKGOTO =>
		nextip = findline(st.n1);
	SKGOSUB =>
		gosubstack = (ip+1) :: gosubstack;
		nextip = findline(st.n1);
	SKRETURN =>
		if(gosubstack != nil){
			nextip = hd gosubstack;
			gosubstack = tl gosubstack;
		}
	SKIF =>
		c := eval(st.e1);
		if(c.num != 0.0){
			if(st.thenstmt != nil)
				nextip = exec(st.thenstmt, ip);
			else
				nextip = findline(st.n1);
		}
	SKFOR =>
		setvar(st.var, eval(st.e1));
		limitv := eval(st.e2);
		stepv := eval(st.e3);
		forstack = ref Forframe(st.var, limitv.num, stepv.num, ip) :: forstack;
	SKNEXT =>
		if(forstack != nil){
			fr := hd forstack;
			cur := getvar(fr.var);
			cur.num += fr.step;
			setvar(fr.var, cur);
			cont: int;
			if(fr.step >= 0.0)
				cont = cur.num <= fr.limit;
			else
				cont = cur.num >= fr.limit;
			if(cont)
				nextip = fr.stmtidx+1;
			else
				forstack = tl forstack;
		}
	SKINPUT =>
		if(st.e1 != nil)
			sys->fprint(stdout, "%s", tostr(eval(st.e1)));
		else
			sys->fprint(stdout, "? ");
		line := readinputline();
		if(endsdollar(st.var))
			setvar(st.var, Value(1, 0.0, line));
		else
			setvar(st.var, Value(0, real line, ""));
	SKEND =>
		nextip = len prog;
	}
	return nextip;
}

doprint(st: ref Stmt)
{
	s := "";
	for(it := st.items; it != nil; it = tl it){
		pi := hd it;
		s += tostr(eval(pi.e));
		if(pi.sep == ',')
			s += "\t";
	}
	if(st.n1 == 0)
		s += "\n";
	sys->fprint(stdout, "%s", s);
}

findline(n: int): int
{
	for(i := 0; i < len prog; i++)
		if(prog[i].lineno == n)
			return i;
	sys->fprint(stderr, "basic: no such line %d\n", n);
	return len prog;
}

eval(e: ref Expr): Value
{
	case e.kind {
	EKNUM =>
		return Value(0, e.num, "");
	EKSTR =>
		return Value(1, 0.0, e.str);
	EKVAR =>
		return getvar(e.name);
	EKUNM =>
		v := eval(e.l);
		return Value(0, -v.num, "");
	EKBIN =>
		return evalbin(e.op, eval(e.l), eval(e.r));
	EKCALL =>
		return evalcall(e.name, eval(e.l));
	}
	return Value(0, 0.0, "");
}

evalbin(op: string, lv: Value, rv: Value): Value
{
	if(op == "+"){
		if(lv.isstr || rv.isstr)
			return Value(1, 0.0, tostr(lv)+tostr(rv));
		return Value(0, lv.num+rv.num, "");
	}
	if(op == "-")
		return Value(0, lv.num-rv.num, "");
	if(op == "*")
		return Value(0, lv.num*rv.num, "");
	if(op == "/")
		return Value(0, lv.num/rv.num, "");
	if(op == "MOD")
		return Value(0, lv.num - math->floor(lv.num/rv.num)*rv.num, "");

	cmp := 0;
	eq: int;
	if(lv.isstr || rv.isstr){
		ls := tostr(lv);
		rs := tostr(rv);
		eq = ls == rs;
		if(ls < rs)
			cmp = -1;
		else if(ls > rs)
			cmp = 1;
	}else{
		eq = lv.num == rv.num;
		if(lv.num < rv.num)
			cmp = -1;
		else if(lv.num > rv.num)
			cmp = 1;
	}
	b := 0;
	case op {
	"=" =>	b = eq;
	"<>" =>	b = !eq;
	"<" =>	b = cmp < 0;
	">" =>	b = cmp > 0;
	"<=" =>	b = cmp <= 0;
	">=" =>	b = cmp >= 0;
	}
	if(b)
		return Value(0, 1.0, "");
	return Value(0, 0.0, "");
}

evalcall(name: string, arg: Value): Value
{
	case name {
	"LEN" =>
		return Value(0, real len arg.str, "");
	"VAL" =>
		return Value(0, real tostr(arg), "");
	"STR$" =>
		return Value(1, 0.0, tostr(arg));
	"ABS" =>
		v := arg.num;
		if(v < 0.0)
			v = -v;
		return Value(0, v, "");
	"INT" =>
		return Value(0, math->floor(arg.num), "");
	}
	return Value(0, 0.0, "");
}

tostr(v: Value): string
{
	if(v.isstr)
		return v.str;
	return fmtnum(v.num);
}

fmtnum(n: real): string
{
	if(n == real (int n))
		return string (int n);
	s := sys->sprint("%f", n);
	i := len s;
	while(i > 0 && s[i-1] == '0')
		i--;
	if(i > 0 && s[i-1] == '.')
		i--;
	return s[0:i];
}

setvar(name: string, val: Value)
{
	for(v := vars; v != nil; v = tl v){
		if((hd v).name == name){
			(hd v).val = val;
			return;
		}
	}
	vars = ref Var(name, val) :: vars;
}

getvar(name: string): Value
{
	for(v := vars; v != nil; v = tl v)
		if((hd v).name == name)
			return (hd v).val;
	if(endsdollar(name))
		return Value(1, 0.0, "");
	return Value(0, 0.0, "");
}

endsdollar(name: string): int
{
	return len name > 0 && name[len name - 1] == '$';
}

readinputline(): string
{
	line := stdin.gets('\n');
	if(line == nil)
		return "";
	if(len line > 0 && line[len line - 1] == '\n')
		line = line[0:len line - 1];
	return line;
}

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

isalpha(c: int): int
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

upper(s: string): string
{
	r := s;
	for(i := 0; i < len r; i++)
		if(r[i] >= 'a' && r[i] <= 'z')
			r[i] = r[i]-'a'+'A';
	return r;
}

onechar(c: int): string
{
	s := " ";
	s[0] = c;
	return s;
}

lenstmts(l: list of ref Stmt): int
{
	n := 0;
	for(; l != nil; l = tl l)
		n++;
	return n;
}

revstmts(l: list of ref Stmt): list of ref Stmt
{
	r: list of ref Stmt;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
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

revitems(l: list of ref PrintItem): list of ref PrintItem
{
	r: list of ref PrintItem;
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
