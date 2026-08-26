implement Hoc;

# A structural Limbo translation of hoc6, Kernighan and Pike's desk-
# calculator language from "The Unix Programming Environment" -
# plan9port's src/cmd/hoc (code.c 666 lines, hoc.y 398, init.c/math.c/
# symbol.c small) - one of the "residual" real Plan 9 commands flagged
# in doc/plan9-port.md's item 9 list. UNLIKE every other p9/cmd
# translation so far, no local 9front source tree could be checked
# against plan9port's copy here (the same "headers/APE + two prebuilt
# binaries only, not source" checkout item 8 already found) - so this
# is translated and verified directly against plan9port's own hoc
# binary, with no independent 9front diff to confirm no divergence
# (the same allowance already used for split.c: "ok to use plan9port
# when a 9front difference can't be verified", see
# doc/plan9-port.md). hoc6 is a well-documented, widely archived
# program (the book's own appendix), so the risk of an unnoticed
# 9front-specific divergence is believed low, but is honestly
# unverified, unlike pr.c/tar.c/file.c's diffed sources.
#
# THE ORIGINAL'S OWN EXECUTION MODEL, understood by reading before
# writing any Limbo: hoc6 is a one-pass compiler into a literal
# "threaded code" array (Inst = an array of C function pointers, with
# operands like a Symbol* or a double's raw bytes stored INLINE
# between instructions via pointer casts) plus a small stack machine
# that runs it. That specific internal representation is not
# reproduced here - Limbo has no equivalent of casting a double's
# bytes into a function-pointer array - but every OBSERVABLE behavior
# it produces (grammar, operator precedence, control flow, function/
# procedure semantics, error recovery) is, checked against the real
# oracle at each step, the same discipline already used for tar.b's
# simplified block buffering and pr.b's Colpts representation.
#
# THE GRAMMAR'S OWN top-level rule (`list: ... | list asgn '\n' {code2
# (xpop,STOP); return 1;} | list stmt '\n' {code(STOP); return 1;} |
# list expr '\n' {code2(printtop,STOP); return 1;} | list defn '\n' |
# ...`) means hoc parses ONE top-level construct at a time and
# executes it IMMEDIATELY - a function/procedure `defn` just gets
# filed away (no `return 1`, so yacc keeps parsing more input in the
# same pass), but a bare assignment, statement, or expression each
# triggers an immediate execute-then-continue. This matters because
# `read(x)` (see below) reads raw characters from the SAME input
# stream the parser itself is still consuming - so this port cannot
# pre-lex or pre-parse a whole file the way p9/cmd/bc.b does; it has
# to parse one top-level unit, execute it, and only then look at more
# input, exactly interleaved. rundriver() below is that loop.
#
# read(x): confirmed against the oracle (a `while(read(x)) print
# x*2,"\n"` loop with data values on later lines of the SAME file)
# that read() pulls a raw number directly off the current input
# stream at RUNTIME, not from a separate data source - and since the
# whole while-loop's own source text is fully parsed (and its
# terminating newline consumed) BEFORE it starts executing, the
# classic hoc idiom is a loop whose body reads values that appear
# AFTER the loop's own closing brace in the same file. mgetc()/
# mungetc() below give both the tokenizer and varread() the same
# character-level pushback so a lookahead token peeked by the parser
# and a raw read() call see one consistent stream position.
#
# THREE THINGS CONFIRMED EMPIRICALLY BEFORE TRUSTING THEM, NOT ASSUMED
# FROM THE C SOURCE ALONE (probed against the real oracle directly,
# outside emu, the same discipline pr.c's -n/-b bug used):
#
# 1. Unary minus binds LOOSER than `^`, the opposite of bc.b's own
#    oracle-confirmed rule for bc/dc: `-2^2` is -4 (i.e. -(2^2)), not
#    (-2)^2=4, and `2^-2` is 0.25. Read from the yacc precedence table
#    (`%left ... UNARYMINUS ...` listed BELOW `%right '^'`, i.e. binding
#    looser) and confirmed by direct invocation before any Limbo was
#    written. parseunary() below therefore sits ABOVE parsepow() in the
#    call chain (parsemul calls parseunary, which falls through to
#    parsepow for its own operand and for a leading unary's operand),
#    the mirror image of bc.b's parsepow()-calls-parseunarybase()
#    shape.
#
# 2. `&&`/`||` do NOT short-circuit: and()/or() in code.c pop BOTH
#    already-evaluated operands off the stack, since the grammar
#    compiles code for both sides of `expr AND expr`/`expr OR expr`
#    unconditionally before the and/or opcode runs. Confirmed directly:
#    `print (0 && (1/0))` and `print (1 || (1/0))` BOTH report "division
#    by zero" against the real oracle - the right side runs regardless
#    of the left side's value. evalexpr()'s Bin/TAND/TOR case below
#    always evaluates both operands, unlike bc.b's own (real,
#    genuinely short-circuiting) `&&`/`||`.
#
# 3. `%` and `%=` are NOT the same operation: mod()'s binary `%` is a
#    real fmod() (`7.5 % 2` is 1.5, confirmed), but modeq()'s `%=`
#    truncates BOTH operands to a C `long` first, then does integer
#    modulo (`x=7.5; x %= 2` gives 1, confirmed, from 7%2 not
#    fmod(7.5,2)=1.5) - a real asymmetry in the original, preserved
#    exactly rather than "fixed" to be consistent, per this tree's
#    translate-what's-there discipline (see pr.c's -n/-b fallthrough,
#    tar.c's uname/gname bug for the precedent). The truncation itself
#    uses Limbo's 32-bit `int`, not a 64-bit C `long` the way this host's
#    real hoc does - an unreproduced platform detail for very large
#    operands, noted in BUGS, not expected to matter for realistic input.
#
# ALSO CONFIRMED, matching the C read closely rather than assumed:
# - A bare top-level expression prints its value (`3+4` -> "7"); a bare
#   top-level assignment does not (`x=5` prints nothing) - the same
#   Assign-vs-other-Expr distinction bc.b's own SExpr execution already
#   makes, reused verbatim here.
# - print's own prexpr()/prstr() never add a newline or any separator
#   beyond a single trailing space after each NUMERIC item (`print
#   1,2,3` is "1 2 3 " with no trailing newline at all) - confirmed
#   directly; a script wanting a newline has to ask for one explicitly
#   (`print ...,"\n"`).
# - `_` (underscore) is a real, lazily-installed variable holding the
#   last value a bare top-level expression printed (`3+4` then `_+1`
#   prints 7 then 8) - kept, not dropped as a curiosity.
# - A `return;` with no expression ALWAYS compiles the same
#   (procret-equivalent) regardless of whether the enclosing definition
#   is a func or a proc, and likewise `return expr;` always compiles as
#   funcret-equivalent - the func/proc MISMATCH ("f (func) returns no
#   value" / "p (proc) returns value") is entirely a RUNTIME check that
#   only fires the first time that particular return statement actually
#   executes, not a parse-time rejection - confirmed directly (`func
#   f(x){return}` parses fine and only errors when `f(1)` is actually
#   called). SReturn's execution below carries the enclosing call's
#   kind for exactly this check.
# - Calling a PROCEDURE from inside an expression (`y = p(1) + 1`) is a
#   SYNTAX error, not a runtime one - the grammar's `expr` production
#   only ever accepts a FUNCTION-typed call, never a PROCEDURE-typed
#   one (only `stmt` does) - confirmed directly. This port reproduces
#   it by dispatching on the callee symbol's kind at PARSE time in
#   parseprimary(), the same way the original's own type-carrying
#   lexer token does.
# - Trying to redefine a builtin name as a func/proc (`func sin(x)
#   {...}`) is also a parse-time syntax error, not a runtime redefinition
#   - confirmed directly - since `defn: FUNC procname` requires a
#   VAR/FUNCTION/PROCEDURE-typed token and a builtin's own symbol is
#   permanently BLTIN-typed. Reproduced the same way.
# - Any runtime OR parse error aborts the REST of the current input
#   argument (file, "-", or "-e" string) and moves on to the next
#   command-line argument if there is one - confirmed directly with two
#   real files, an error partway through the first, and a `print` after
#   it in the SAME file that never runs, while the second file's own
#   output still appears. This also means the grammar's own `list error
#   '\n' {yyerrok;}` resync rule is dead code in practice: yyerror()
#   calls execerror() directly, which always unwinds past yyparse()
#   entirely before that resync rule could ever fire - the same kind of
#   vestigial-but-real finding as pr.c's own unused deferred-error
#   mechanism. Also confirmed: hoc always exits 0, even after reporting
#   an error - main() calls exits(0) unconditionally, with no error
#   code path at all.
# - Exponent notation numbers (`1e3` -> 1000) ARE accepted - checked
#   directly rather than assumed, since Bgetd()'s own grammar wasn't
#   available to read. readfloat() below scans it via one-character,
#   non-destructively-peeked lookahead (mgetc()/mungetc()'s own 2-slot
#   pushback queue only needed for the rare "looked like an exponent,
#   wasn't" backtrack).
#
# Recursion depth: the original caps call nesting at a fixed 100
# frames (NFRAME) with a clean "call nested too deeply" error; this
# port has no such cap and recurses natively through Limbo's own
# interpreter call stack instead, so a genuinely runaway recursive
# script fails some other way here rather than with that specific
# message - not expected to matter for realistic scripts, noted in
# BUGS rather than silently reproduced or silently ignored.
#
# Identifier/string lexical length caps (both a fixed 100-byte C
# buffer in the original, with a "name too long"/"string too long"
# error) are not reproduced either - Limbo strings are not a fixed
# buffer, so there is no equivalent limit to hit. Also not reproduced:
# the original's own recovery of a genuinely truncated final line (no
# trailing newline before EOF causes a real syntax error there,
# confirmed directly) - this port accepts EOF in place of a required
# trailing newline for the last top-level unit in a file, a small
# deliberate leniency rather than a faithfully-reproduced edge case,
# since it costs nothing in the common (newline-terminated) case.
#
# ERROR HANDLING: an earlier draft of this file modeled execerror()'s
# setjmp/longjmp with a Limbo exception (Hocerr), caught once at the
# top of rundriver(). That crashed this emu build outright (a native
# disfault, not a clean trap) the moment a real error fired several
# call-frames deep - isolated with a minimal standalone probe down to
# a hard rule: an exception here cannot unwind through ANY function
# frame lacking its own exception handler, even one bare passthrough
# frame, no matter how shallow (see the memory file this produced,
# inferno-rio-exception-frame-bug, for the full probe chain). Rather
# than wrap every one of this file's ~20 parser/evaluator functions in
# a trivial catch-and-rethrow, hocerror() below just sets a plain
# `hadeerror` flag instead (arguably MORE faithful anyway, since
# setjmp/longjmp is itself a single non-local jump with no per-frame
# C-stack unwinding, not a structured mechanism either) - checked at
# the handful of places that would otherwise do something actually
# unsafe with a post-error value (an integer modulo by zero, a
# mismatched-arity formal-binding walk, an infinite loop re-parsing
# the same unconsumed bad token) or produce a visible wrong side
# effect (printing a bogus value the original's longjmp would never
# have reached). Every other call site just lets its current
# computation finish somewhat-meaninglessly - real division by zero
# is silently Inf/NaN in Limbo, not a trap - since nothing downstream
# ever looks at it again once rundriver() sees hadeerror set and
# abandons the rest of this input argument.
#
# A REAL BUG IN THE TRANSLATION, found by testing (not by re-reading):
# `int x` on a Limbo `real` ROUNDS to the nearest integer - it does
# NOT truncate toward zero the way a C `(long)` cast does. Confirmed
# directly (`int(7.6)` gave 8, `int(-7.5)` gave -8) after `x=7.5;
# x%=2` gave 0 here instead of the oracle's 1 (int(7.5) rounding up to
# 8, 8%2=0, instead of truncating to 7, 7%2=1). trunctoward0() below
# (floor/ceil toward zero, then convert) fixes both modeq()'s own
# truncate-then-modulo and hocint() (the `int()` builtin, matching
# integer()'s `(double)(long)x`) - a genuine, general Limbo fact
# worth knowing beyond this file, now its own memory entry
# (inferno-rio-int-real-rounds), sibling to plan9-long-is-32-bits.
#
# A CHARACTERIZED, NOT FIXED, DIVERGENCE: printtop()/prexpr() both use
# "%.17g" verbatim, matched here via sys->sprint("%.17g", v) - but the
# real oracle's own print() (Plan9's libfmt, not glibc) appears to
# print the SHORTEST decimal that still round-trips to the same
# double, capped at 17 significant digits, not always exactly 17
# significant digits the way glibc's (and Limbo's) %.17g does -
# confirmed directly: `0.1` prints as `0.1` there but
# `0.10000000000000001` here; `1/3` prints one digit shorter there
# than here; but `2/7` prints IDENTICALLY on both sides (that
# particular value's shortest round-trip happens to need all 17
# digits anyway). Implementing shortest-round-trip formatting would
# need a real strtod() this tree doesn't have, just to chase a
# formatting-library difference below either side's own code - not
# attempted. hoctest.b's own cases exercising PI/E/sqrt/etc compare
# with a digit-count tolerance rather than exact string equality for
# exactly this reason; every case using integers or short exact
# decimals (the vast majority) still compares byte-exact.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "math.m";
	math: Math;

Hoc: module
{
	init:	fn(ctxt: ref Context, argv: list of string);

	# in-process test seam: run the given command-line-style argument
	# list (files, "-", "-e expr") exactly as init() would, returning
	# captured stdout and an ok flag (0 if any runtime/parse error was
	# ever reported to stderr during the run, matching the fact that
	# the real hoc itself always exits 0 regardless - this seam adds
	# the ok flag purely so hoctest.b can tell the two cases apart
	# without scraping stderr text).
	run:	fn(argv: list of string): (string, int);
};

stdin, stdout, stderr: ref FD;

# --- symbol table ---

SKUNDEF, SKVAR, SKBLTIN, SKFUNC, SKPROC: con iota;

Sym: adt
{
	name:	string;
	kind:	int;
	val:	real;		# for SKUNDEF/SKVAR
	fdefn:	ref Fn;		# for SKFUNC/SKPROC
};

Fn: adt
{
	kind:	int;		# SKFUNC or SKPROC
	params:	list of string;
	body:	list of ref Stmt;
};

symtab: list of ref Sym;
lastvalsym: ref Sym;	# "_" - installed lazily, matching the original

findsym(name: string): ref Sym
{
	for(l := symtab; l != nil; l = tl l)
		if((hd l).name == name)
			return hd l;
	return nil;
}

# find-or-create-as-SKUNDEF: matches yylex()'s own auto-install-on-
# first-mention behaviour for any identifier that isn't a keyword.
getsym(name: string): ref Sym
{
	s := findsym(name);
	if(s == nil){
		s = ref Sym(name, SKUNDEF, 0.0, nil);
		symtab = s :: symtab;
	}
	return s;
}

installconst(name: string, v: real)
{
	symtab = ref Sym(name, SKVAR, v, nil) :: symtab;
}

installbltin(name: string)
{
	symtab = ref Sym(name, SKBLTIN, 0.0, nil) :: symtab;
}

# (resetstate() is defined once, near the driver at the end of this
# file, since it also resets the input/lexer/driver state alongside
# the symbol table.)

# --- math builtins ---

errcheck(d: real, s: string): real
{
	if(math->isnan(d))
		hocerror(s, "argument out of domain");
	else if(!math->finite(d))
		hocerror(s, "result out of range");
	return d;
}

# trunctoward0: `int x` for a Limbo `real` ROUNDS to nearest - it does
# NOT truncate toward zero the way a C `(long)` cast does. Confirmed
# directly, not assumed (`int(7.6)` gave 8, `int(-7.5)` gave -8): a
# genuine, general Limbo fact worth knowing for any future real-to-int
# conversion in this tree, not specific to hoc. Both hocint() (the
# `int()` builtin, matching integer()'s own `(double)(long)x`) and
# modeq()'s own truncate-then-modulo need real truncation, so this
# floors/ceils toward zero first (already-integral by construction,
# so the final `int` conversion can no longer round anything).
trunctoward0(x: real): int
{
	if(x >= 0.0)
		return int math->floor(x);
	return int math->ceil(x);
}

hocint(x: real): real
{
	if(x < -2147483648.0 || x > 2147483647.0)
		hocerror("argument out of domain", nil);
	return real trunctoward0(x);
}

callbuiltin(name: string, x: real): real
{
	case name {
	"sin" =>	return math->sin(x);
	"cos" =>	return math->cos(x);
	"tan" =>	return math->tan(x);
	"atan" =>	return math->atan(x);
	"asin" =>	return errcheck(math->asin(x), "asin");
	"acos" =>	return errcheck(math->acos(x), "acos");
	"sinh" =>	return errcheck(math->sinh(x), "sinh");
	"cosh" =>	return errcheck(math->cosh(x), "cosh");
	"tanh" =>	return math->tanh(x);
	"log" =>	return errcheck(math->log(x), "log");
	"log10" =>	return errcheck(math->log10(x), "log10");
	"exp" =>	return errcheck(math->exp(x), "exp");
	"sqrt" =>	return errcheck(math->sqrt(x), "sqrt");
	"int" =>	return hocint(x);
	"abs" =>	return math->fabs(x);
	}
	hocerror("internal", "bad builtin");
	return 0.0;
}

hocpow(x, y: real): real
{
	return errcheck(math->pow(x, y), "exponentiation");
}

# --- character-level input, shared by the tokenizer and read() ---
#
# mgetc()/mungetc() are a small 2-slot pushback queue layered UNDER
# Iobuf's own single-level ungetc (used transiently, get-then-
# immediately-unget, only inside peekc() below, never left pending
# across calls) - needed because readfloat()'s exponent scan
# sometimes has to back out of TWO already-consumed characters (the
# 'e' and an optional sign) when what looked like an exponent turns
# out not to be one (e.g. "3e" at end of input, or "3e+q"). Every
# other character read in this file, including ordinary two-character
# operator lookahead, goes through this same pair for one consistent
# stream position - the tokenizer's own one-token lookahead and a
# read() call mid-execution must never disagree about where the raw
# stream cursor actually is.

bin: ref Iobuf;
pb0, pb1: int;
npb: int;

mgetc(): int
{
	if(npb > 0){
		c := pb0;
		pb0 = pb1;
		npb--;
		return c;
	}
	return bin.getc();
}

mungetc(c: int)
{
	if(npb == 0)
		pb0 = c;
	else{
		pb1 = pb0;
		pb0 = c;
	}
	npb++;
}

peekc(): int
{
	c := mgetc();
	if(c != Bufio->EOF)
		mungetc(c);
	return c;
}

# --- number scanning, shared by the tokenizer's NUMBER token and by
# read()'s own raw scan (which additionally accepts a leading sign,
# matching varread()'s own "+-.0123456789" acceptance set - the
# tokenizer never sees a leading sign since a NUMBER token is only
# entered after already having peeked a digit or '.', with unary minus
# handled separately by the grammar/parser, exactly as in the
# original). ---

isdig(c: int): int
{
	return c >= '0' && c <= '9';
}

# (v, ok) - ok=0 means no digits were found at all (nothing consumed
# beyond a leading sign, which is pushed back too in that case).
readfloat(allowsign: int): (real, int)
{
	signchar := 0;	# 0 none, else '+' or '-'
	c := mgetc();
	if(allowsign && (c == '+' || c == '-')){
		signchar = c;
		c = mgetc();
	}
	v := 0.0;
	ndig := 0;
	while(isdig(c)){
		v = v*10.0 + real (c - '0');
		c = mgetc();
		ndig++;
	}
	if(c == '.'){
		c = mgetc();
		frac := 0.1;
		while(isdig(c)){
			v += real (c - '0') * frac;
			frac /= 10.0;
			c = mgetc();
			ndig++;
		}
	}
	if(ndig == 0){
		# nothing numeric found at all - push back the character
		# that stopped us, then (if consumed) the leading sign,
		# leaving the stream exactly as it was found.
		if(c != Bufio->EOF)
			mungetc(c);
		if(signchar != 0)
			mungetc(signchar);
		return (0.0, 0);
	}
	# exponent - peek without truly consuming until fully committed,
	# so a false start ("3e", "3e+q") can be backed out of cleanly.
	if(c == 'e' || c == 'E'){
		p2 := peekc();
		esign := 0;
		if(p2 == '+' || p2 == '-'){
			mgetc();	# really consume the sign now
			esign = p2;
			p2 = peekc();
		}
		if(isdig(p2)){
			ed := 0.0;
			d := mgetc();
			while(isdig(d)){
				ed = ed*10.0 + real (d - '0');
				d = mgetc();
			}
			if(d != Bufio->EOF)
				mungetc(d);
			if(esign == '-')
				ed = -ed;
			v *= math->pow(10.0, ed);
		} else {
			# false start: back out whatever was truly consumed -
			# the sign (if any), then 'e'/'E' itself, in that
			# order so 'e' reads first on the next mgetc(). Nothing
			# else to push back afterward: unlike the mantissa
			# path below, the character that ended the (failed)
			# exponent scan was only ever peeked, never consumed.
			if(esign != 0)
				mungetc(esign);
			mungetc(c);
			if(signchar == '-')
				v = -v;
			return (v, 1);
		}
	} else if(c != Bufio->EOF)
		mungetc(c);
	if(signchar == '-')
		v = -v;
	return (v, 1);
}

# --- tokenizer ---

TNUM, TIDENT, TSTRING,
TPLUS, TMINUS, TSTAR, TSLASH, TPCT, TCARET,
TLPAREN, TRPAREN, TLBRACE, TRBRACE, TSEMI, TCOMMA,
TASSIGN, TADDEQ, TSUBEQ, TMULEQ, TDIVEQ, TMODEQ,
TEQ, TNE, TLT, TGT, TLE, TGE,
TAND, TOR, TNOT, TINC, TDEC,
TIF, TELSE, TWHILE, TFOR, TFUNC, TPROC, TRETURN, TPRINT, TREAD,
TNEWLINE, TOTHER, TEOF: con iota;

Token: adt
{
	kind:	int;
	sym:	ref Sym;	# TIDENT
	num:	real;		# TNUM
	str:	string;		# TSTRING
	ch:	int;		# TOTHER - the raw unrecognized character
};

lineno: int;
infile: string;	# "" for stdin/interactive, else the current file name

# backslash-escape translation inside a quoted string, matching
# backslash(): only b/f/n/r/t are special; anything else (including a
# literal '\\' or '\"') passes through as itself.
unescape(c: int): int
{
	case c {
	'b' => return '\b';
	'f' => return '\f';
	'n' => return '\n';
	'r' => return '\r';
	't' => return '\t';
	}
	return c;
}

isidstart(c: int): int
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

isidchar(c: int): int
{
	return isidstart(c) || isdig(c);
}

keywordkind(s: string): int
{
	case s {
	"if" =>		return TIF;
	"else" =>	return TELSE;
	"while" =>	return TWHILE;
	"for" =>	return TFOR;
	"func" =>	return TFUNC;
	"proc" =>	return TPROC;
	"return" =>	return TRETURN;
	"print" =>	return TPRINT;
	"read" =>	return TREAD;
	}
	return -1;
}

lexone(): Token
{
	c := mgetc();
	for(;;){
		while(c == ' ' || c == '\t')
			c = mgetc();
		if(c == '\\'){
			c2 := mgetc();
			if(c2 == '\n'){
				lineno++;
				c = mgetc();
				continue;
			}
			# A backslash NOT followed by a newline is dropped
			# in the original too, but it then falls through
			# LINEARLY into the rest of that same yylex() call
			# (still checking for '#', still not re-skipping any
			# further whitespace) rather than looping. Reloops
			# here instead (re-skipping whitespace/comments
			# fresh) - a small, deliberate divergence for this
			# essentially-malformed corner (a lone backslash not
			# escaping a real newline), not expected to affect any
			# realistic script.
			c = c2;
			continue;
		}
		if(c == '#'){
			while(c != '\n' && c != Bufio->EOF)
				c = mgetc();
			if(c == '\n'){
				lineno++;
				return Token(TNEWLINE, nil, 0.0, nil, 0);
			}
			return Token(TEOF, nil, 0.0, nil, 0);
		}
		break;
	}
	if(c == Bufio->EOF)
		return Token(TEOF, nil, 0.0, nil, 0);
	if(c == '\n'){
		lineno++;
		return Token(TNEWLINE, nil, 0.0, nil, 0);
	}
	if(isdig(c) || c == '.'){
		mungetc(c);
		(v, nil) := readfloat(0);
		return Token(TNUM, nil, v, nil, 0);
	}
	if(isidstart(c)){
		name := "";
		while(isidchar(c)){
			name[len name] = c;
			c = mgetc();
		}
		if(c != Bufio->EOF)
			mungetc(c);
		kk := keywordkind(name);
		if(kk >= 0)
			return Token(kk, nil, 0.0, nil, 0);
		return Token(TIDENT, getsym(name), 0.0, nil, 0);
	}
	if(c == '"'){
		s := "";
		c = mgetc();
		while(c != '"'){
			if(c == '\n' || c == Bufio->EOF){
				# hocerror() no longer aborts (see its own
				# header comment) - bin is now at EOF, so
				# without this return the loop above would
				# spin forever appending EOF to s (found by
				# testing an unterminated string once
				# exceptions were dropped).
				hocerror("missing quote", nil);
				return Token(TEOF, nil, 0.0, nil, 0);
			}
			if(c == '\\')
				c = unescape(mgetc());
			s[len s] = c;
			c = mgetc();
		}
		return Token(TSTRING, nil, 0.0, s, 0);
	}
	# two-character operators before their one-character prefixes -
	# matches follow()'s own pairing exactly, including which
	# character is checked first for '+' and '-' (another copy of the
	# same char, THEN '=' - not the other way around).
	case c {
	'+' =>
		c2 := mgetc();
		if(c2 == '+') return Token(TINC, nil, 0.0, nil, 0);
		if(c2 == '=') return Token(TADDEQ, nil, 0.0, nil, 0);
		if(c2 != Bufio->EOF) mungetc(c2);
		return Token(TPLUS, nil, 0.0, nil, 0);
	'-' =>
		c2 := mgetc();
		if(c2 == '-') return Token(TDEC, nil, 0.0, nil, 0);
		if(c2 == '=') return Token(TSUBEQ, nil, 0.0, nil, 0);
		if(c2 != Bufio->EOF) mungetc(c2);
		return Token(TMINUS, nil, 0.0, nil, 0);
	'*' =>
		c2 := mgetc();
		if(c2 == '=') return Token(TMULEQ, nil, 0.0, nil, 0);
		if(c2 != Bufio->EOF) mungetc(c2);
		return Token(TSTAR, nil, 0.0, nil, 0);
	'/' =>
		c2 := mgetc();
		if(c2 == '=') return Token(TDIVEQ, nil, 0.0, nil, 0);
		if(c2 != Bufio->EOF) mungetc(c2);
		return Token(TSLASH, nil, 0.0, nil, 0);
	'%' =>
		c2 := mgetc();
		if(c2 == '=') return Token(TMODEQ, nil, 0.0, nil, 0);
		if(c2 != Bufio->EOF) mungetc(c2);
		return Token(TPCT, nil, 0.0, nil, 0);
	'>' =>
		c2 := mgetc();
		if(c2 == '=') return Token(TGE, nil, 0.0, nil, 0);
		if(c2 != Bufio->EOF) mungetc(c2);
		return Token(TGT, nil, 0.0, nil, 0);
	'<' =>
		c2 := mgetc();
		if(c2 == '=') return Token(TLE, nil, 0.0, nil, 0);
		if(c2 != Bufio->EOF) mungetc(c2);
		return Token(TLT, nil, 0.0, nil, 0);
	'=' =>
		c2 := mgetc();
		if(c2 == '=') return Token(TEQ, nil, 0.0, nil, 0);
		if(c2 != Bufio->EOF) mungetc(c2);
		return Token(TASSIGN, nil, 0.0, nil, 0);
	'!' =>
		c2 := mgetc();
		if(c2 == '=') return Token(TNE, nil, 0.0, nil, 0);
		if(c2 != Bufio->EOF) mungetc(c2);
		return Token(TNOT, nil, 0.0, nil, 0);
	'&' =>
		c2 := mgetc();
		if(c2 == '&') return Token(TAND, nil, 0.0, nil, 0);
		if(c2 != Bufio->EOF) mungetc(c2);
		return Token(TOTHER, nil, 0.0, nil, '&');
	'|' =>
		c2 := mgetc();
		if(c2 == '|') return Token(TOR, nil, 0.0, nil, 0);
		if(c2 != Bufio->EOF) mungetc(c2);
		return Token(TOTHER, nil, 0.0, nil, '|');
	'^' =>	return Token(TCARET, nil, 0.0, nil, 0);
	'(' =>	return Token(TLPAREN, nil, 0.0, nil, 0);
	')' =>	return Token(TRPAREN, nil, 0.0, nil, 0);
	'{' =>	return Token(TLBRACE, nil, 0.0, nil, 0);
	'}' =>	return Token(TRBRACE, nil, 0.0, nil, 0);
	';' =>	return Token(TSEMI, nil, 0.0, nil, 0);
	',' =>	return Token(TCOMMA, nil, 0.0, nil, 0);
	}
	return Token(TOTHER, nil, 0.0, nil, c);
}

# --- AST ---

Expr: adt
{
	pick {
	Num =>
		v:	real;
	Var =>
		sym:	ref Sym;
	Assign =>
		sym:	ref Sym;
		op:	int;	# TASSIGN or a compound-assign token
		e:	ref Expr;
	Bin =>
		op:	int;
		l, r:	ref Expr;
	Un =>
		e:	ref Expr;	# unary minus only
	Not =>
		e:	ref Expr;
	PreIncDec =>
		sym:	ref Sym;
		op:	int;	# TINC or TDEC
	PostIncDec =>
		sym:	ref Sym;
		op:	int;
	Call =>
		sym:	ref Sym;	# kind == SKFUNC
		args:	list of ref Expr;
	Bltin =>
		name:	string;
		arg:	ref Expr;
	ReadE =>
		sym:	ref Sym;
	}
};

PrItem: adt
{
	pick {
	PExpr =>
		e:	ref Expr;
	PStr =>
		s:	string;
	}
};

Stmt: adt
{
	pick {
	SExpr =>
		e:	ref Expr;
	SBlock =>
		body:	list of ref Stmt;
	SIf =>
		cond:	ref Expr;
		then:	list of ref Stmt;
		els:	list of ref Stmt;	# nil if no else
	SWhile =>
		cond:	ref Expr;
		body:	list of ref Stmt;
	SFor =>
		init:	ref Expr;	# any may be nil
		cond:	ref Expr;
		incr:	ref Expr;
		body:	list of ref Stmt;
	SReturn =>
		e:	ref Expr;	# nil for a bare `return`
	SPrint =>
		items:	list of ref PrItem;
	SCall =>
		sym:	ref Sym;	# kind == SKPROC
		args:	list of ref Expr;
	}
};

# --- parser: one token of lookahead, matching the tokenizer's own
# stream position exactly (see the header comment on read()). ---

curtok:	Token;
peektok: ref Token;	# nil if not yet peeked past curtok
indef:	int;	# 1 while parsing inside a func/proc body - matches the
		# original's own parse-time `indef` flag, gating `return`.

advance()
{
	if(peektok != nil){
		curtok = *peektok;
		peektok = nil;
	} else
		curtok = lexone();
}

# peek: the token after curtok, without consuming curtok - used only
# by parseassign() to decide, without any backtracking, whether a
# leading identifier is the start of an assignment (`x = ...`) or an
# ordinary expression (`x + 1`). Unlike p9/cmd/bc.b's own array-of-
# tokens parser, this one lexes directly off a live character stream
# (see the header comment on read()), so there is no cheap way to
# "unread" a whole token the way bc.b rewinds its `pos` index - two
# tokens of live lookahead here instead, exactly as much as is ever
# needed, and never more (peektok is consumed into curtok by the very
# next advance(), never held across two).
peek(): Token
{
	if(peektok == nil){
		t := lexone();
		peektok = ref t;
	}
	return *peektok;
}

# fail: unlike hocerror() itself (also called directly from the
# evaluator, where "advance the parser" would be meaningless), every
# PARSE-time error goes through fail(), which additionally forces the
# token stream forward once here. hocerror() has already seeked `bin`
# to its own end by the time this runs, so this guarantees any
# enclosing parse loop that keeps going until TEOF (parsestmtlist(),
# rundriver() itself) is guaranteed to reach TEOF and stop rather than
# spinning forever re-parsing the same still-unconsumed bad token -
# found necessary by testing (an early version left curtok completely
# unchanged on a "expected an expression" failure inside a brace
# block, which looped forever re-hitting the same error).
fail(msg: string)
{
	hocerror(msg, nil);
	advance();
}

expect(k: int, what: string)
{
	if(curtok.kind != k)
		fail("expected " + what);
	else
		advance();
}

skipnewlines()
{
	while(curtok.kind == TNEWLINE)
		advance();
}

# parseblock: a statement's body is grammatically a single `stmt`
# (not necessarily a `{ }` block - `func f(x) return x*x` with no
# braces at all is valid) - `{ ... }` is simply one of the shapes
# `stmt` itself can take (SBlock below), so this is just parsestmt()
# wrapped in a list for callers (SIf/SWhile/SFor/defn bodies) that
# want "the statements to run", not "the one Stmt node".
parseblock(): list of ref Stmt
{
	s := parsestmt();
	pick x := s {
	SBlock => return x.body;
	* => return s :: nil;
	}
}

parsestmtlist(): list of ref Stmt
{
	stmts: list of ref Stmt;
	skipnewlines();
	while(curtok.kind != TRBRACE && curtok.kind != TEOF){
		stmts = parsestmt() :: stmts;
		skipnewlines();
	}
	r: list of ref Stmt;
	for(; stmts != nil; stmts = tl stmts)
		r = hd stmts :: r;
	return r;
}

parsestmt(): ref Stmt
{
	case curtok.kind {
	TIF =>
		advance();
		expect(TLPAREN, "(");
		c := parseexpr();
		expect(TRPAREN, ")");
		then := parseblock();
		els: list of ref Stmt;
		if(curtok.kind == TELSE){
			advance();
			els = parseblock();
		}
		return ref Stmt.SIf(c, then, els);
	TWHILE =>
		advance();
		expect(TLPAREN, "(");
		c := parseexpr();
		expect(TRPAREN, ")");
		body := parseblock();
		return ref Stmt.SWhile(c, body);
	TFOR =>
		advance();
		expect(TLPAREN, "(");
		ini: ref Expr;
		if(curtok.kind != TSEMI)
			ini = parseexpr();
		expect(TSEMI, ";");
		c: ref Expr;
		if(curtok.kind != TSEMI)
			c = parseexpr();
		expect(TSEMI, ";");
		inc: ref Expr;
		if(curtok.kind != TRPAREN)
			inc = parseexpr();
		expect(TRPAREN, ")");
		body := parseblock();
		return ref Stmt.SFor(ini, c, inc, body);
	TRETURN =>
		if(!indef)
			fail("return used outside definition");
		advance();
		if(curtok.kind == TNEWLINE || curtok.kind == TRBRACE || curtok.kind == TEOF){
			advance();
			# NB: the trailing newline that closes this bare
			# `return` is consumed HERE (a single-statement
			# defn-body case, e.g. `func f(x) return`), matching
			# parsestmt() otherwise never consuming its own
			# trailing separator - see the note below on why
			# every other arm leaves it alone.
			return ref Stmt.SReturn(nil);
		}
		e := parseexpr();
		return ref Stmt.SReturn(e);
	TPRINT =>
		advance();
		items: list of ref PrItem;
		for(;;){
			if(curtok.kind == TSTRING){
				items = ref PrItem.PStr(curtok.str) :: items;
				advance();
			} else
				items = ref PrItem.PExpr(parseexpr()) :: items;
			if(curtok.kind == TCOMMA){
				advance();
				continue;
			}
			break;
		}
		r: list of ref PrItem;
		for(; items != nil; items = tl items)
			r = hd items :: r;
		return ref Stmt.SPrint(r);
	TLBRACE =>
		advance();
		s := parsestmtlist();
		expect(TRBRACE, "}");
		return ref Stmt.SBlock(s);
	}
	# a procedure call used as a statement, or a bare expression
	# (which also covers a top-level-looking assignment nested inside
	# a block, e.g. inside an if-body).
	if(curtok.kind == TIDENT && curtok.sym.kind == SKPROC){
		sym := curtok.sym;
		advance();
		expect(TLPAREN, "(");
		args := parsearglist();
		expect(TRPAREN, ")");
		return ref Stmt.SCall(sym, args);
	}
	e := parseexpr();
	return ref Stmt.SExpr(e);
}

parsearglist(): list of ref Expr
{
	args: list of ref Expr;
	if(curtok.kind != TRPAREN){
		for(;;){
			args = parseexpr() :: args;
			if(curtok.kind == TCOMMA){
				advance();
				continue;
			}
			break;
		}
	}
	r: list of ref Expr;
	for(; args != nil; args = tl args)
		r = hd args :: r;
	return r;
}

parseexpr(): ref Expr
{
	return parseassign();
}

# assignment is right-associative (`x = y = 3`) and only valid when
# the left side is a bare, non-function/procedure/builtin identifier -
# peek() (see above) decides this WITHOUT consuming the identifier
# unless it really does turn out to be an assignment, so there is
# nothing to backtrack either way.
parseassign(): ref Expr
{
	if(curtok.kind == TIDENT && curtok.sym.kind != SKBLTIN
	   && curtok.sym.kind != SKFUNC && curtok.sym.kind != SKPROC){
		op := peek().kind;
		if(op == TASSIGN || op == TADDEQ || op == TSUBEQ ||
		   op == TMULEQ || op == TDIVEQ || op == TMODEQ){
			sym := curtok.sym;
			advance();	# consumes the identifier; curtok becomes the operator (already peeked)
			advance();	# consumes the operator
			rhs := parseassign();
			return ref Expr.Assign(sym, op, rhs);
		}
	}
	return parseor();
}

parseor(): ref Expr
{
	l := parseand();
	while(curtok.kind == TOR){
		advance();
		r := parseand();
		l = ref Expr.Bin(TOR, l, r);
	}
	return l;
}

parseand(): ref Expr
{
	l := parserel();
	while(curtok.kind == TAND){
		advance();
		r := parserel();
		l = ref Expr.Bin(TAND, l, r);
	}
	return l;
}

parserel(): ref Expr
{
	l := parseadd();
	case curtok.kind {
	TGT or TGE or TLT or TLE or TEQ or TNE =>
		op := curtok.kind;
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
		if(curtok.kind == TPLUS){
			advance();
			l = ref Expr.Bin(TPLUS, l, parsemul());
		} else if(curtok.kind == TMINUS){
			advance();
			l = ref Expr.Bin(TMINUS, l, parsemul());
		} else
			break;
	}
	return l;
}

parsemul(): ref Expr
{
	l := parseunary();
	for(;;){
		case curtok.kind {
		TSTAR or TSLASH or TPCT =>
			op := curtok.kind;
			advance();
			l = ref Expr.Bin(op, l, parseunary());
		* =>
			return l;
		}
	}
}

# unary minus/not/prefix-inc-dec bind LOOSER than `^` here (the
# opposite of bc.b's own bc/dc precedence) - confirmed against the
# oracle, see this file's header comment. parseunary() therefore sits
# ABOVE parsepow() in this chain: its own operand (and, recursively, a
# chained `--x`/`!!x`) is parsed via parsepow(), so a leading `^`
# inside that operand binds before the unary operator wraps around it
# (`-2^2` -> Un(-, Bin(^,2,2)) = -4).
parseunary(): ref Expr
{
	if(curtok.kind == TMINUS){
		advance();
		return ref Expr.Un(parseunary());
	}
	if(curtok.kind == TNOT){
		advance();
		return ref Expr.Not(parseunary());
	}
	if(curtok.kind == TINC || curtok.kind == TDEC){
		op := curtok.kind;
		advance();
		sym := expectvarident();
		return ref Expr.PreIncDec(sym, op);
	}
	return parsepow();
}

# right-associative, and binds TIGHTER than unary (see above): its own
# exponent is parsed via parseunary() (not parsepow() directly) so a
# leading `-` on the exponent itself still works (`2^-2` == 0.25) while
# a chain (`2^3^2`) still nests right (parseunary falls straight
# through to parsepow with no unary prefix present, same as calling
# parsepow() would, so this costs nothing in the common case).
parsepow(): ref Expr
{
	l := parseprimary();
	if(curtok.kind == TCARET){
		advance();
		r := parseunary();
		return ref Expr.Bin(TCARET, l, r);
	}
	return l;
}

expectvarident(): ref Sym
{
	if(curtok.kind != TIDENT || curtok.sym.kind == SKBLTIN
	   || curtok.sym.kind == SKFUNC || curtok.sym.kind == SKPROC)
		fail("expected a variable");
	sym := curtok.sym;
	advance();
	return sym;
}

parseprimary(): ref Expr
{
	t := curtok;
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
	if(t.kind == TREAD){
		advance();
		expect(TLPAREN, "(");
		sym := expectvarident();
		expect(TRPAREN, ")");
		return ref Expr.ReadE(sym);
	}
	if(t.kind == TIDENT){
		sym := t.sym;
		if(sym.kind == SKBLTIN){
			advance();
			expect(TLPAREN, "(");
			a := parseexpr();
			expect(TRPAREN, ")");
			return ref Expr.Bltin(sym.name, a);
		}
		if(sym.kind == SKFUNC){
			advance();
			expect(TLPAREN, "(");
			args := parsearglist();
			expect(TRPAREN, ")");
			return ref Expr.Call(sym, args);
		}
		if(sym.kind == SKPROC){
			fail(sym.name + ": a procedure cannot be used in an expression");
			return nil;
		}
		# SKVAR or SKUNDEF: a plain variable, or its postfix ++/--
		# (grammar: `VAR INC | VAR DEC` - note NOT valid for a
		# builtin/func/proc name, all excluded above already).
		advance();
		if(curtok.kind == TINC || curtok.kind == TDEC){
			op := curtok.kind;
			advance();
			return ref Expr.PostIncDec(sym, op);
		}
		return ref Expr.Var(sym);
	}
	fail("expected an expression");
	return nil;
}

# isplainvar: true for a symbol that may legally serve as a func/proc
# name or formal-parameter name - matches the grammar's own `procname:
# VAR | FUNCTION | PROCEDURE` (redefining an existing func/proc is
# fine; a builtin name is not, since BLTIN never matches that rule -
# confirmed directly, see the header comment) and `formals: VAR`
# (a formal must be a plain variable name, never a builtin/func/proc).
isplainvar(sym: ref Sym): int
{
	return sym.kind != SKBLTIN;
}

isformalvar(sym: ref Sym): int
{
	return sym.kind == SKVAR || sym.kind == SKUNDEF;
}

# defn: FUNC|PROC procname '(' formals ')' stmt - a function/procedure
# body is (like any other stmt) not necessarily a brace block.
# parsedefn: no exception handling here at all (see hocerror()'s own
# header comment for why) - fail() forces the token stream to TEOF on
# any error, so an early `return` right after each fail() call here is
# what keeps this function from dereferencing a token field (like
# curtok.sym) that the very fail() call just proved might not exist -
# found necessary by testing (a bad function name crashed with a nil
# dereference on `sym.kind = fkind` until these were added). Nothing
# downstream ever calls a function whose parsing was abandoned this
# way, since rundriver() checks hadeerror right after parsing and never
# executes a unit that hit one - see rundriver()'s own comment.
parsedefn()
{
	fkind := SKFUNC;
	if(curtok.kind == TPROC)
		fkind = SKPROC;
	advance();
	if(curtok.kind != TIDENT || !isplainvar(curtok.sym)){
		fail("bad function/procedure name");
		return;
	}
	sym := curtok.sym;
	advance();
	expect(TLPAREN, "(");
	if(hadeerror)
		return;
	params: list of string;
	if(curtok.kind != TRPAREN){
		for(;;){
			if(curtok.kind != TIDENT || !isformalvar(curtok.sym)){
				fail("bad parameter name");
				return;
			}
			params = curtok.sym.name :: params;
			advance();
			if(curtok.kind == TCOMMA){
				advance();
				continue;
			}
			break;
		}
	}
	expect(TRPAREN, ")");
	if(hadeerror)
		return;
	rp: list of string;
	for(; params != nil; params = tl params)
		rp = hd params :: rp;
	# sym.kind must be set to fkind BEFORE parsing the body, not after
	# - a recursive self-call inside the body (`func fact(n) {...
	# fact(n-1)...}`) looks "fact" up via the SAME shared symbol while
	# ITS OWN body is still being parsed, and parseprimary() dispatches
	# on sym.kind at that point to decide Call-vs-Var. Found by testing
	# (a real recursive function faulted with "attempt to evaluate
	# non-variable" until this was reordered), not by re-reading -
	# sym.fdefn itself is set only after the body is fully parsed since
	# nothing needs it before then (calls are only ever made after
	# parsing this whole defn completes).
	sym.kind = fkind;
	saveindef := indef;
	indef = 1;
	body := parseblock();
	indef = saveindef;
	sym.fdefn = ref Fn(fkind, rp, body);
}

# --- evaluator ---

# Ret: the per-call "has a return happened, and with what value" signal
# threaded through execstmt()/execstmts(), matching p9/cmd/bc.b's own
# Retsig - plus `kind`/`name`, since (unlike bc, which has no func/proc
# distinction) a bare `return`/`return expr` always compiles the same
# regardless of which kind of definition it's inside, and the actual
# func-vs-proc mismatch is checked HERE, at the point a return statement
# actually executes - not at parse time. See the header comment.
Ret: adt
{
	hit:	int;
	val:	real;
	kind:	int;	# the CURRENTLY EXECUTING call's kind (SKFUNC/SKPROC), or 0 at top level
	name:	string;
};

# hocerror: reports one error and marks the rest of the CURRENT input
# argument as abandoned - but, unlike an earlier draft of this file,
# does NOT use a Limbo exception to unwind there. Empirically (see
# doc/plan9-port.md and the cmd-device-oracle memory's own note on
# this), an exception raised many call-frames deep in this emu build
# crashes the VM outright unless EVERY intermediate frame between the
# raise and its catch has its own exception handler - confirmed with
# a minimal standalone probe (a bare two-frame passthrough with no
# handler already crashes it) well before hoc.b's own ~20-deep parser/
# evaluator call chain was reached. Wrapping every one of those frames
# was the first fix attempted; the actual fix is simpler and more
# faithful to the original anyway: hoc.c doesn't unwind the Limbo/C
# call stack via a structured per-frame mechanism either - it uses
# setjmp/longjmp, a single non-local jump straight back to run()'s own
# top with NO per-frame cleanup along the way (Saveval restoration is
# its own explicit walk, restoreall(), not stack unwinding). A plain
# `hadeerror` flag, checked at the few spots that would otherwise do
# something actually unsafe (an integer modulo by zero, a mismatched-
# arity formal-binding walk) reproduces exactly that "jump to the top,
# skip everything else" effect without needing Limbo's own per-frame
# exception machinery at all. Every other call site simply lets its
# current expression/statement finish somewhat-meaninglessly (dividing
# by zero as a `real` is silently Inf/NaN, not a trap) since nothing
# downstream ever looks at that value again once rundriver() sees
# hadeerror set and abandons the rest of this input argument, the same
# way nothing downstream of a longjmp in the original ever runs again
# either.
hocerror(s, t: string)
{
	msg := "hoc: " + s;
	if(t != nil)
		msg += " " + t;
	if(infile != nil && infile != "")
		msg += " in " + infile;
	msg += sys->sprint(" near line %d", lineno);
	sys->fprint(stderr, "%s\n", msg);
	hadeerror = 1;
	everhaderror = 1;
	# abandon the rest of the current input argument entirely - matches
	# execerror()'s own Bseek(bin,0,2) before its longjmp (see the
	# header comment on why the grammar's own error-resync rule is
	# never actually reached in practice).
	if(bin != nil)
		bin.seek(big 0, Bufio->SEEKEND);
	npb = 0;
	peektok = nil;
}

hadeerror: int;	# set by hocerror(), reset at the top of each
		# rundriver() unit - "did THIS unit hit an error"
everhaderror: int;	# set by hocerror(), never reset - "did the whole
			# run() hit an error at all" (run()'s own ok flag)

truthy(v: real): int
{
	return v != 0.0;
}

boolreal(b: int): real
{
	if(b)
		return 1.0;
	return 0.0;
}

verifysym(sym: ref Sym)
{
	if(sym.kind != SKVAR && sym.kind != SKUNDEF)
		hocerror("attempt to evaluate non-variable", sym.name);
	if(sym.kind == SKUNDEF)
		hocerror("undefined variable", sym.name);
}

evalexpr(e: ref Expr): real
{
	pick x := e {
	Num =>
		return x.v;
	Var =>
		verifysym(x.sym);
		return x.sym.val;
	Assign =>
		rhs := evalexpr(x.e);
		if(x.sym.kind != SKVAR && x.sym.kind != SKUNDEF)
			hocerror("assignment to non-variable", x.sym.name);
		v: real;
		case x.op {
		TASSIGN =>
			v = rhs;
		TADDEQ =>
			v = x.sym.val + rhs;
		TSUBEQ =>
			v = x.sym.val - rhs;
		TMULEQ =>
			v = x.sym.val * rhs;
		TDIVEQ =>
			if(rhs == 0.0)
				hocerror("division by zero", nil);
			v = x.sym.val / rhs;
		TMODEQ =>
			# matches modeq(): both operands truncated to an
			# integer FIRST, then integer modulo - not the same
			# operation as binary `%` below (confirmed against
			# the oracle, see the header comment). Truncation is
			# trunctoward0(), NOT a bare `int` conversion - see its
			# own comment (Limbo's `int x` rounds a real to the
			# nearest integer, it does not truncate toward zero
			# the way a C `(long)` cast does; confirmed directly
			# after `x=7.5; x%=2` gave 0 instead of the oracle's 1,
			# from int(7.5) rounding up to 8 rather than truncating
			# to 7). Also unreproduced: Limbo's `int` is 32 bits,
			# not the host's own 64-bit C `long` - a platform detail
			# for very large operands, see BUGS.
			xi := trunctoward0(x.sym.val);
			ri := trunctoward0(rhs);
			if(ri == 0){
				# unlike real division (silently Inf/NaN),
				# integer modulo by zero is a genuine Limbo-
				# level fault, not just a wrong answer - must
				# not fall through to computing it (found by
				# testing once exceptions were dropped in favor
				# of the hadeerror flag, see hocerror()'s own
				# header comment).
				hocerror("division by zero", nil);
				v = 0.0;
			} else
				v = real (xi % ri);
		}
		x.sym.val = v;
		x.sym.kind = SKVAR;
		return v;
	Bin =>
		# && and || do NOT short-circuit here - both operands are
		# always evaluated, confirmed against the oracle (see the
		# header comment) and unlike p9/cmd/bc.b's own (genuinely
		# short-circuiting) && / ||.
		l := evalexpr(x.l);
		r := evalexpr(x.r);
		case x.op {
		TPLUS => return l + r;
		TMINUS => return l - r;
		TSTAR => return l * r;
		TSLASH =>
			if(r == 0.0)
				hocerror("division by zero", nil);
			return l / r;
		TPCT =>
			if(r == 0.0)
				hocerror("division by zero", nil);
			return math->fmod(l, r);
		TCARET =>
			return hocpow(l, r);
		TGT => return boolreal(l > r);
		TGE => return boolreal(l >= r);
		TLT => return boolreal(l < r);
		TLE => return boolreal(l <= r);
		TEQ => return boolreal(l == r);
		TNE => return boolreal(l != r);
		TAND => return boolreal(truthy(l) && truthy(r));
		TOR => return boolreal(truthy(l) || truthy(r));
		}
	Un =>
		return -evalexpr(x.e);
	Not =>
		return boolreal(!truthy(evalexpr(x.e)));
	PreIncDec =>
		verifysym(x.sym);
		if(x.op == TINC)
			x.sym.val += 1.0;
		else
			x.sym.val -= 1.0;
		return x.sym.val;
	PostIncDec =>
		verifysym(x.sym);
		old := x.sym.val;
		if(x.op == TINC)
			x.sym.val = old + 1.0;
		else
			x.sym.val = old - 1.0;
		return old;
	Call =>
		return callfn(x.sym, x.args);
	Bltin =>
		return callbuiltin(x.name, evalexpr(x.arg));
	ReadE =>
		return varread(x.sym);
	}
	hocerror("internal", "bad expr");
	return 0.0;
}

# callfn: bind formals by VALUE, in the CALLER's scope, before
# rebinding - matches call()'s own arg-evaluation-before-binding order.
# Formals are bound by literally swapping the SAME global Sym's kind/
# val in and out (matching the original's own Symbol* aliasing - a
# formal parameter and a same-named global ARE the same symbol table
# entry there, and the "local" binding is just a temporary overwrite,
# restored on the way out), so recursion nests correctly via Limbo's
# own call stack plus this explicit save/restore around each call - the
# same shape p9/cmd/bc.b's own callfunc()/saved list already uses for
# `auto` variables and parameters, just simpler here since there is no
# separate name-keyed association list to rebuild: a ref Sym can be
# mutated in place.
callfn(sym: ref Sym, args: list of ref Expr): real
{
	f := sym.fdefn;
	argv: list of real;
	for(l := args; l != nil; l = tl l)
		argv = evalexpr(hd l) :: argv;
	ra: list of real;
	for(; argv != nil; argv = tl argv)
		ra = hd argv :: ra;
	if(len ra != len f.params){
		hocerror(sym.name, "called with wrong number of arguments");
		# a mismatched length would otherwise run `tl al`/`tl pl` off
		# the end of the shorter list below - a real Limbo-level
		# fault, not merely a wrong answer, so this returns instead
		# of falling through (found by testing an arity-mismatch
		# call once exceptions were dropped in favor of the
		# hadeerror flag - see hocerror()'s own header comment).
		return 0.0;
	}
	psyms: list of ref Sym;
	savedkinds: list of int;
	savedvals: list of real;
	pl := f.params;
	al := ra;
	while(pl != nil){
		psym := getsym(hd pl);
		psyms = psym :: psyms;
		savedkinds = psym.kind :: savedkinds;
		savedvals = psym.val :: savedvals;
		psym.kind = SKVAR;
		psym.val = hd al;
		pl = tl pl;
		al = tl al;
	}
	rs := ref Ret(0, 0.0, f.kind, sym.name);
	execstmts(f.body, rs);
	# no exception to catch here - restoreformals() always runs on the
	# way out, error or not, matching restoreall()'s eventual effect in
	# the original without needing per-frame exception handling to get
	# there (see hocerror()'s own header comment).
	restoreformals(psyms, savedkinds, savedvals);
	return rs.val;
}

restoreformals(psyms: list of ref Sym, kinds: list of int, vals: list of real)
{
	k := kinds;
	v := vals;
	for(; psyms != nil; psyms = tl psyms){
		sym := hd psyms;
		sym.kind = hd k;
		sym.val = hd v;
		k = tl k;
		v = tl v;
	}
}

# varread: reads a raw number directly off the CURRENT input stream at
# RUNTIME (see the header comment) - matches varread()'s own retry-
# across-file-boundaries loop (skip whitespace; on real end of ALL
# input, store 0 and report failure; on a non-numeric character,
# error; otherwise read a signed float and report success).
varread(sym: ref Sym): real
{
	for(;;){
		c := mgetc();
		while(c == ' ' || c == '\t')
			c = mgetc();
		if(c == Bufio->EOF){
			if(moreinput())
				continue;
			sym.val = 0.0;
			sym.kind = SKVAR;
			return 0.0;
		}
		if(c != '+' && c != '-' && c != '.' && !isdig(c)){
			# the original's own execerror() aborts everything
			# immediately here, never falling through to retry
			# across a file boundary the way the EOF case above
			# does - matched explicitly (not merely by luck of
			# readfloat() also happening to fail gracefully on
			# non-numeric input) since falling through here would
			# let a later moreinput() call switch to input the
			# original would never have touched.
			hocerror("non-number read into", sym.name);
			return 0.0;
		}
		mungetc(c);
		(v, ok) := readfloat(1);
		if(!ok){
			if(moreinput())
				continue;
			sym.val = 0.0;
			sym.kind = SKVAR;
			return 0.0;
		}
		sym.val = v;
		sym.kind = SKVAR;
		return 1.0;
	}
}

# execstmts/execstmt: every point below that evaluates an expression
# and then DOES something with the result (print it, branch on it,
# decide whether to keep looping) checks hadeerror immediately
# afterward and stops - not because the value itself is unsafe to use
# (a `real` computed after an error is just some meaningless-but-
# harmless number, same as the original's own d1.val/d2.val would be
# for the one Inst that runs right before a longjmp fires), but because
# nothing downstream of an error should have any FURTHER observable
# effect - matching the original's own longjmp-straight-out-of-
# everything behaviour without needing a per-frame Limbo exception
# handler to get there (see hocerror()'s own header comment). Found
# necessary by testing: without these checks, `1/0` printed
# "Infinity" to stdout (evalexpr() dutifully computed and returned it,
# and nothing stopped execstmt()'s own printtop() from using it) where
# the real oracle prints nothing at all past the error.
execstmts(stmts: list of ref Stmt, rs: ref Ret)
{
	for(l := stmts; l != nil; l = tl l){
		execstmt(hd l, rs);
		if(rs.hit || hadeerror)
			return;
	}
}

execstmt(s: ref Stmt, rs: ref Ret)
{
	pick x := s {
	SExpr =>
		v := evalexpr(x.e);
		if(hadeerror)
			return;
		pick tmp := x.e {
		Assign => ;
		* => printtop(v);
		}
	SBlock =>
		execstmts(x.body, rs);
	SIf =>
		c := evalexpr(x.cond);
		if(hadeerror)
			return;
		if(truthy(c))
			execstmts(x.then, rs);
		else if(x.els != nil)
			execstmts(x.els, rs);
	SWhile =>
		for(;;){
			c := evalexpr(x.cond);
			if(hadeerror)
				return;
			if(!truthy(c))
				break;
			execstmts(x.body, rs);
			if(rs.hit || hadeerror)
				return;
		}
	SFor =>
		if(x.init != nil){
			evalexpr(x.init);
			if(hadeerror)
				return;
		}
		for(;;){
			if(x.cond != nil){
				c := evalexpr(x.cond);
				if(hadeerror)
					return;
				if(!truthy(c))
					break;
			}
			execstmts(x.body, rs);
			if(rs.hit || hadeerror)
				return;
			if(x.incr != nil){
				evalexpr(x.incr);
				if(hadeerror)
					return;
			}
		}
	SReturn =>
		if(x.e == nil){
			if(rs.kind == SKFUNC)
				hocerror(rs.name, "(func) returns no value");
			rs.hit = 1;
		} else {
			if(rs.kind == SKPROC)
				hocerror(rs.name, "(proc) returns value");
			else
				rs.val = evalexpr(x.e);
			rs.hit = 1;
		}
	SPrint =>
		for(l := x.items; l != nil; l = tl l){
			pick it := hd l {
			PExpr =>
				v := evalexpr(it.e);
				if(hadeerror)
					return;
				emit(sys->sprint("%.17g ", v));
			PStr =>
				emit(it.s);
			}
		}
	SCall =>
		callfn(x.sym, x.args);
	}
}

# printtop: a bare top-level expression's own auto-print, including
# the lazily-installed "_" variable holding the last such value -
# both confirmed real, not a curiosity, against the oracle (see the
# header comment).
printtop(v: real)
{
	if(lastvalsym == nil)
		lastvalsym = getsym("_");
	emit(sys->sprint("%.17g\n", v));
	lastvalsym.val = v;
	lastvalsym.kind = SKVAR;
}

# --- output capture, matching every other p9/cmd translation's own
# in-process test seam convention ---

capturing: int;
outbuf: string;

emit(s: string)
{
	if(capturing)
		outbuf += s;
	else
		sys->print("%s", s);
}

# --- driver: argument walking (moreinput()) + the parse-one-unit-
# execute-it-immediately loop (rundriver(), replacing run()) ---

pendingargs: list of string;
bingen: int;	# bumped every time moreinput() switches `bin`

# moreinput: advance `bin`/`infile`/`lineno` to the next pending
# command-line argument - "-" for stdin, "-eEXPR"/"-e EXPR" for an
# inline expression (via bufio->sopen(), simpler than the original's
# own mkstemp()-based workaround for the same thing), otherwise a
# filename. Returns 0 once there is nothing left at all. Used both
# by rundriver()'s own top loop (moving to the next file after this
# one's own real EOF) AND by varread() (moving to the next file when
# read() itself hits real EOF mid-execution) - matching the original's
# own single moreinput(), called from both main() and varread().
moreinput(): int
{
	for(;;){
		if(pendingargs == nil)
			return 0;
		arg := hd pendingargs;
		pendingargs = tl pendingargs;
		lineno = 1;
		if(arg == "-"){
			bin = bufio->fopen(stdin, Bufio->OREAD);
			infile = nil;
		} else if(len arg >= 2 && arg[0:2] == "-e"){
			expr: string;
			if(len arg == 2){
				if(pendingargs == nil){
					sys->fprint(stderr, "hoc: no argument for -e\n");
					continue;
				}
				expr = hd pendingargs;
				pendingargs = tl pendingargs;
			} else
				expr = arg[2:];
			bin = bufio->sopen(expr + "\n");
			infile = nil;
		} else {
			f := bufio->open(arg, Bufio->OREAD);
			if(f == nil){
				sys->fprint(stderr, "hoc: can't open %s\n", arg);
				continue;
			}
			bin = f;
			infile = arg;
		}
		npb = 0;
		peektok = nil;
		bingen++;
		return 1;
	}
}

# rundriver: parses one top-level unit (a func/proc defn, filed away
# with nothing to execute, or a runnable stmt/expr/asgn, executed
# immediately) and repeats, switching files via moreinput() at real
# EOF, until there is nothing left at all. Any parse or runtime error
# sets hadeerror (see hocerror()'s own header comment on why this is a
# flag, not a Limbo exception) and has already seeked the CURRENT
# `bin` to its own end - so this checks hadeerror after parsing (to
# skip executing a unit that never fully parsed) and again after
# executing, and either way it is the ONE place that needs to notice
# "did bin just change out from under an already-buffered lookahead
# token" and resync curtok by re-lexing - whether that change came
# from an error's own EOF-seek or from read() switching files in the
# middle of a still-running top-level unit.
rundriver()
{
	if(!moreinput())
		return;
	advance();
	for(;;){
		skipnewlines();
		if(curtok.kind == TEOF){
			if(!moreinput())
				return;
			advance();
			continue;
		}
		hadeerror = 0;
		g := bingen;
		if(curtok.kind == TFUNC || curtok.kind == TPROC){
			parsedefn();
		} else {
			s := parsestmt();
			if(!hadeerror){
				if(curtok.kind == TNEWLINE)
					advance();
				else if(curtok.kind != TEOF)
					fail("expected newline");
			}
			if(!hadeerror){
				rs := ref Ret(0, 0.0, 0, "");
				execstmt(s, rs);
			}
		}
		if(hadeerror || bingen != g)
			advance();
	}
}

resetstate()
{
	symtab = nil;
	lastvalsym = nil;
	installconst("PI", 3.14159265358979323846);
	installconst("E", 2.71828182845904523536);
	installconst("GAMMA", 0.57721566490153286060);
	installconst("DEG", 57.29577951308232087680);
	installconst("PHI", 1.61803398874989484820);
	bnames := list of {"sin","cos","tan","atan","asin","acos","sinh",
		"cosh","tanh","log","log10","exp","sqrt","int","abs"};
	for(l := bnames; l != nil; l = tl l)
		installbltin(hd l);
	bin = nil;
	npb = 0;
	pb0 = 0;
	pb1 = 0;
	peektok = nil;
	lineno = 1;
	infile = nil;
	indef = 0;
	bingen = 0;
	hadeerror = 0;
	everhaderror = 0;
	pendingargs = nil;
}

run(argv: list of string): (string, int)
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(stderr == nil)
		stderr = sys->fildes(2);
	if(bufio == nil)
		bufio = load Bufio Bufio->PATH;
	if(math == nil)
		math = load Math Math->PATH;
	resetstate();
	pendingargs = argv;
	if(pendingargs == nil)
		pendingargs = list of {"-"};
	capturing = 1;
	outbuf = "";
	rundriver();
	capturing = 0;
	return (outbuf, !everhaderror);
}

init(ctxt: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stdin = sys->fildes(0);
	stdout = sys->fildes(1);
	stderr = sys->fildes(2);
	bufio = load Bufio Bufio->PATH;
	math = load Math Math->PATH;
	if(bufio == nil || math == nil){
		sys->fprint(stderr, "hoc: cannot load a required module\n");
		raise "fail:module";
	}
	resetstate();
	args := argv;
	if(args != nil)
		args = tl args;	# drop argv[0], matching main()'s own argv+1
	pendingargs = args;
	if(pendingargs == nil)
		pendingargs = list of {"-"};
	rundriver();
}
