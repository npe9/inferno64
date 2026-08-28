implement Eqn2hoc;

# eqn2hoc: see module/eqn2hoc.m's header comment for the full account
# of what this is and is not (a new syntax-to-semantics mapping, not a
# 1:1 translation of eqn's own behavior - eqn has none to preserve) and
# the exact table of what maps to hoc and what is refused.
#
# Real eqn's own tokenizer (lex.c's yylex()/getstr()) splits on
# whitespace, and treats '{' '}' '~' '^' '"' as their own always-
# separate tokens (confirmed by reading getstr()'s stop-character set
# directly) - tokenize() below reproduces exactly that splitting rule.
# Everything past tokenizing (the grammar/precedence and every semantic
# action) is new: eqn.y's own actions build troff box-drawing calls,
# not hoc expressions, so there was nothing there to carry over besides
# the SHAPE of the grammar (eqn.y's own %left/%right precedence table,
# followed here) and the keyword vocabulary (lookup.c's keyword[]),
# both used to decide what a "sub"/"sup"/"over"/... token means
# syntactically, matched here by direct string comparison rather than
# a from-scratch symbol table the way real eqn's lookup() does it -
# there are only a few dozen keywords, not worth a hash table for.

include "sys.m";
	sys: Sys;
include "eqn2hoc.m";

toks: array of string;
ntok: int;
pos: int;

init()
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
}

# Piece: one already-translated hoc source fragment, and whether it is
# "simple" - a single bare identifier/number with no operators of its
# own, the only shape valid to fold a subscript or diacritical mark
# into (as a name suffix) or to treat as a function name. Anything
# built from an operator (over, sup, a braced group, ...) is NOT
# simple, even if it came from a single token - matches eqn's own real
# distinction between "a box" (anything) and specifically a bare
# CONTIG/QTEXT token in the grammar's own `text` nonterminal (only that
# feeds sub/sup's real grammar role; ANY box may be sub/sup'd there,
# but only a bare name can be MEANINGFULLY folded into one hoc
# identifier - anything else is refused, with a clear error, rather
# than producing a name that silently means something else).
Piece: adt
{
	s:	string;
	simple:	int;
};

translate(src: string): (string, string)
{
	init();
	(toklist, err) := tokenize(src);
	if(err != nil)
		return (nil, err);
	toks = l2a(toklist);
	ntok = len toks;
	pos = 0;
	(p, err2) := parsecompare();
	if(err2 != nil)
		return (nil, err2);
	if(pos != ntok)
		return (nil, "unexpected trailing input at '" + cur() + "'");
	return (p.s, nil);
}

l2a(l: list of string): array of string
{
	a := array[len l] of string;
	i := 0;
	for(; l != nil; l = tl l){
		a[i++] = hd l;
	}
	return a;
}

# --- tokenizer: reproduces getstr()'s real splitting rule ---

tokenize(src: string): (list of string, string)
{
	toks: list of string;
	n := len src;
	i := 0;
	while(i < n){
		c := src[i];
		if(c == ' ' || c == '\t' || c == '\n'){
			i++;
			continue;
		}
		if(c == '{' || c == '}' || c == '~' || c == '^'){
			toks = src[i:i+1] :: toks;
			i++;
			continue;
		}
		if(c == '"')
			return (nil, "quoted text (\"...\") is a troff label with no hoc meaning - not supported");
		j := i;
		while(j < n && !issep(src[j]))
			j++;
		toks = src[i:j] :: toks;
		i = j;
	}
	return (revstrs(toks), nil);
}

issep(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '{' || c == '}' || c == '~' || c == '^' || c == '"';
}

revstrs(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# --- parser: eqn.y's own grammar SHAPE and precedence, new actions ---

cur(): string
{
	if(pos < ntok)
		return toks[pos];
	return "";
}

advance(): string
{
	t := cur();
	if(pos < ntok)
		pos++;
	return t;
}

# parsecompare/parseadd/parsemul: real eqn's OWN grammar has no
# arithmetic operators at all above `over`/`sqrt`/sub/sup - "x + y" is
# just three boxes ("x", "+", "y") concatenated with no relationship
# between them (eqn: box | eqn box, confirmed directly in eqn.y), and
# "4 a c" (three more boxes) is exactly how eqn represents 4*a*c -
# ordinary juxtaposition IS the multiplication notation real printed
# mathematics already uses. So the actual `+ - * / = == != > < >= <=`
# structure below is new, not translated from anything (there's
# nothing there to translate) - it exists because refusing every
# juxtaposition as "unsupported" would refuse nearly every real
# equation (see doc/danby-tks-plan.md's own "make the rhs a parsable
# language" correction: the point is to accept the syntax people
# actually write, not the narrowest thing an implementation could get
# away with). Ordinary math precedence, loosest to tightest:
# compare, then +/-, then */over/implicit-juxtaposition, then
# sqrt/sub/sup/diacriticals (parsepostfix, above). Every operator
# wraps its own operands in explicit hoc parens on the way out, so
# hoc's own operator precedence never has to agree with this parser's
# - the output's grouping is already unambiguous either way.
parsecompare(): (ref Piece, string)
{
	(left, err) := parseadd();
	if(err != nil)
		return (left, err);
	t := cur();
	case t {
	"=" =>
		advance();
		(right, err2) := parseadd();
		if(err2 != nil)
			return (right, err2);
		return (ref Piece("(" + left.s + ")==(" + right.s + ")", 0), nil);
	"==" or "!=" or ">" or "<" or ">=" or "<=" =>
		advance();
		(right, err2) := parseadd();
		if(err2 != nil)
			return (right, err2);
		return (ref Piece("(" + left.s + ")" + t + "(" + right.s + ")", 0), nil);
	}
	return (left, nil);
}

parseadd(): (ref Piece, string)
{
	(left, err) := parsemul();
	if(err != nil)
		return (left, err);
	for(;;){
		t := cur();
		case t {
		"+" or "-" =>
			advance();
			(right, err2) := parsemul();
			if(err2 != nil)
				return (right, err2);
			left = ref Piece("(" + left.s + ")" + t + "(" + right.s + ")", 0);
		* =>
			return (left, nil);
		}
	}
}

# parsemul: `over` (real eqn keyword, division), explicit "*"/"/", and
# bare juxtaposition (implicit multiplication - "4 a c" = 4*a*c) all
# sit at the same precedence, left to right - matches ordinary
# convention (division and multiplication bind equally, evaluated
# left-to-right). isstopper() lists every token that means "this
# level is done", so juxtaposition can never accidentally swallow a
# lower-precedence operator, a closing delimiter, or end of input.
parsemul(): (ref Piece, string)
{
	(left, err) := parsepostfix();
	if(err != nil)
		return (left, err);
	for(;;){
		t := cur();
		if(isstopper(t))
			return (left, nil);
		op := "*";
		case t {
		"over" =>
			op = "/";
			advance();
		"*" or "/" =>
			op = t;
			advance();
		}
		(right, err2) := parsepostfix();
		if(err2 != nil)
			return (right, err2);
		left = ref Piece("(" + left.s + ")" + op + "(" + right.s + ")", 0);
	}
}

isstopper(t: string): int
{
	case t {
	"" or "}" or "right" or
	"+" or "-" or "=" or "==" or "!=" or ">" or "<" or ">=" or "<=" =>
		return 1;
	}
	return 0;
}

# parsepostfix: sub[+sup]/sup/diacritical marks, all postfix, all
# higher precedence than `over` (eqn.y declares SUP/SUB, then the
# diacriticals, later than OVER/SQRT - later declarations bind
# tighter). Diacriticals bind tightest of all (declared last).
parsepostfix(): (ref Piece, string)
{
	(b, err) := parseprefix();
	if(err != nil)
		return (b, err);
	for(;;){
		t := cur();
		case t {
		"sub" =>
			advance();
			(subp, err2) := parseprefix();
			if(err2 != nil)
				return (subp, err2);
			supp: ref Piece;
			if(cur() == "sup"){
				advance();
				(sp, err3) := parseprefix();
				if(err3 != nil)
					return (sp, err3);
				supp = sp;
			}
			(nb, err4) := foldsub(b, subp, supp);
			if(err4 != nil)
				return (nb, err4);
			b = nb;
		"sup" =>
			advance();
			(supp, err2) := parseprefix();
			if(err2 != nil)
				return (supp, err2);
			b = ref Piece("(" + b.s + ")^(" + supp.s + ")", 0);
		"hat" or "vec" or "dyad" or "dot" or "dotdot" or "bar" or
		"lowbar" or "highbar" or "tilde" or "utilde" or "under" =>
			advance();
			(nb, err2) := folddia(b, t);
			if(err2 != nil)
				return (nb, err2);
			b = nb;
		* =>
			return (b, nil);
		}
	}
}

# parseprefix: one "box" - sqrt/size/font/roman/italic/bold/fat/fwd/
# up/back/down are all prefix wrappers in eqn.y's own grammar (each
# takes the box that follows); size/font/roman/italic/bold/fat and
# fwd/up/back/down are pure typesetting with no hoc meaning at all, so
# they are parsed (to consume their own argument correctly) and
# discarded, keeping the box they wrap unchanged.
parseprefix(): (ref Piece, string)
{
	t := cur();
	case t {
	"" =>
		return (ref Piece("", 0), "unexpected end of input");
	"{" =>
		advance();
		(p, err) := parsecompare();
		if(err != nil)
			return (p, err);
		if(cur() != "}")
			return (p, "missing } to match {");
		advance();
		return (ref Piece(p.s, 0), nil);
	"sqrt" =>
		advance();
		(p, err) := parseprefix();
		if(err != nil)
			return (p, err);
		return (ref Piece("sqrt(" + p.s + ")", 0), nil);
	"left" =>
		advance();
		advance();	# the delimiter token itself (e.g. "(") - purely
				# display size in real eqn, no meaning here
		(p, err) := parsecompare();
		if(err != nil)
			return (p, err);
		if(cur() != "right")
			return (p, "'left' without a matching 'right'");
		advance();
		advance();	# the closing delimiter token, same reasoning
		return (ref Piece("(" + p.s + ")", 0), nil);
	"size" =>
		advance();
		advance();	# the size number - discarded
		return parseprefix();
	"font" =>
		advance();
		advance();	# the font name - discarded
		return parseprefix();
	"roman" or "italic" or "bold" or "fat" =>
		advance();
		return parseprefix();
	"fwd" or "up" or "back" or "down" =>
		advance();
		advance();	# the amount - discarded
		return parseprefix();
	"sum" or "prod" or "int" or "integral" or "union" or "inter" =>
		return (ref Piece("", 0), "'" + t + "' has no computational meaning in eqn itself (it only draws a symbol with sub/sup as visual limits) and no hoc equivalent - not supported");
	"matrix" or "pile" or "lpile" or "cpile" or "rpile" or
	"col" or "lcol" or "ccol" or "rcol" or "above" =>
		return (ref Piece("", 0), "'" + t + "' needs an array or matrix - hoc has no array type, so this can't be translated (the same boundary Orbital's plugins hit - see doc/danby-tks-plan.md)");
	"mark" or "lineup" =>
		return (ref Piece("", 0), "'" + t + "' is a troff alignment construct with no hoc meaning - not supported");
	"from" or "to" =>
		return (ref Piece("", 0), "'" + t + "' is only meaningful attached to sum/int/prod, which have no hoc target either - not supported");
	"define" or "tdefine" or "ndefine" or "ifdef" or "delim" or
	"gsize" or "gfont" or "include" or "copy" or "space" =>
		return (ref Piece("", 0), "'" + t + "' is eqn's own macro/preprocessing layer - out of scope, translate() takes one plain expression string, not a full .EQ/.EN document");
	"over" or "*" or "/" =>
		return (ref Piece("", 0), "'" + t + "' with nothing before it");
	"-" =>
		# unary minus - real eqn has no such notion (a leading "-" is
		# just another box, no different from any other), but "-b" and
		# "-1" are too common in real formulas (the quadratic formula's
		# own numerator starts with one) to refuse.
		advance();
		(p, err) := parseprefix();
		if(err != nil)
			return (p, err);
		return (ref Piece("-(" + p.s + ")", 0), nil);
	"+" =>
		advance();
		return parseprefix();	# unary plus: a no-op
	* =>
		advance();
		return atomorcall(t);
	}
}

# atomorcall: a bare word is either (a) a known hoc builtin name
# immediately followed by a "{...}" or "left(...)right" group - the
# real eqn convention for a roman-set word next to a parenthesized box
# (confirmed against lookup.c's own resword[] table: sin/cos/tan/sinh/
# cosh/tanh/log/exp are ALL there, just mapped to a font-escape string
# rather than a call - eqn itself never calls anything), which becomes
# an actual hoc function call here; or (b) an ordinary hoc identifier
# or number, exactly as ambiguous as every other eqn word already is
# (nothing in real eqn distinguishes "x" the variable from "sin" the
# word - both are just text to typeset).
atomorcall(t: string): (ref Piece, string)
{
	if(ishocfn(t) && (cur() == "{" || cur() == "left")){
		(arg, err) := parseprefix();
		if(err != nil)
			return (arg, err);
		return (ref Piece(t + "(" + arg.s + ")", 0), nil);
	}
	if(!validtoken(t))
		return (ref Piece("", 0), "cannot translate '" + t + "' to a hoc number or identifier");
	return (ref Piece(t, 1), nil);
}

ishocfn(t: string): int
{
	case t {
	"sin" or "cos" or "tan" or "sinh" or "cosh" or "tanh" or "log" or "exp" =>
		return 1;
	}
	return 0;
}

# validtoken: a plain decimal number, or a C-like identifier - hoc's
# own lexer accepts both; this just catches an untranslatable token
# HERE, with a clear message, rather than letting a garbled string
# reach hoc->compile() and produce a confusing parse error one layer
# down. Does not check against hoc's own reserved words (if/while/for/
# func/proc/return/print/read) - an eqn word that collides with one
# (eqn's own resword table has "if" and "for", as roman-typeset words)
# still reaches hoc->compile(), which will refuse it on its own; see
# man/1/eqn2hoctest's BUGS.
validtoken(t: string): int
{
	if(len t == 0)
		return 0;
	alldigits := 1;
	ndots := 0;
	for(i := 0; i < len t; i++){
		c := t[i];
		if(c == '.'){
			ndots++;
			continue;
		}
		if(c < '0' || c > '9')
			alldigits = 0;
	}
	if(alldigits && ndots <= 1)
		return 1;
	c0 := t[0];
	if(!((c0 >= 'A' && c0 <= 'Z') || (c0 >= 'a' && c0 <= 'z') || c0 == '_'))
		return 0;
	for(j := 0; j < len t; j++){
		c := t[j];
		if(!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
		     (c >= '0' && c <= '9') || c == '_'))
			return 0;
	}
	return 1;
}

# foldsub/folddia: fold a subscript or diacritical mark into ONE hoc
# identifier ("x sub i" -> "x_i", "x hat" -> "xhat") - name-mangling,
# not real indexing (hoc has no array/index type at all). Refused,
# with a clear error, on anything but a simple bare name on both
# sides - folding an arbitrary expression string into an identifier
# would silently produce a different, wrong name rather than erroring.
foldsub(b: ref Piece, subp: ref Piece, supp: ref Piece): (ref Piece, string)
{
	if(!b.simple)
		return (b, "subscript on a non-simple expression is not supported - hoc has no array/index type, only 'name sub name' folds into one identifier");
	if(!subp.simple)
		return (subp, "subscript '" + subp.s + "' is not a simple name - hoc has no array/index type, only 'name sub name' folds into one identifier");
	name := b.s + "_" + subp.s;
	if(supp == nil)
		return (ref Piece(name, 1), nil);
	return (ref Piece("(" + name + ")^(" + supp.s + ")", 0), nil);
}

folddia(b: ref Piece, mark: string): (ref Piece, string)
{
	if(!b.simple)
		return (b, "'" + mark + "' on a non-simple expression is not supported - only 'name " + mark + "' folds into one identifier (e.g. 'x hat' -> 'xhat')");
	return (ref Piece(b.s + mark, 1), nil);
}
