implement Trac;

# Nelson's Dream Machines chapter on languages singles out Mooers' TRAC
# (Text Reckoning And Compiler, 1964) as the archetype of a pure string-
# rewriting/macro language, distinct from BASIC/APL's numeric-array bent -
# a "form" #(name,arg,arg,...) is replaced in place by whatever it
# evaluates to, and the replacement text is itself rescanned, which is
# TRAC's only control-flow primitive: there is no loop construct at all,
# recursion via a function calling itself (guarded by a comparison) is
# how you loop.
#
# Two kinds of form are distinguished purely by how many '#' precede the
# '(': #(...) is *active* - evaluated immediately, in place, as the
# scanner reaches it. ##(...) is *neutral* - the scanner strips exactly
# one '#' and copies everything up to the matching ')' through
# completely untouched (no evaluation, no recursion into it, not even
# echoed as output yet) - it becomes ordinary #(...) text sitting inert
# wherever it landed, eligible to fire the *next* time something rescans
# that particular stretch of text.
#
# That's the whole trick behind TRAC recursion. A stored function's body
# is scanned once, right when #(ds,...) defines it, so anything in the
# body meant to fire only on a *future* call - most importantly, any
# self-call - has to survive that one definition-time scan as inert
# text, i.e. be written ##(...) in the source. #(ds,fact,##(eq,N,0,1,
# ##(ml,N,##(cl,fact,##(su,N,1))))) stores literally
# "#(eq,N,0,1,##(ml,N,##(cl,fact,##(su,N,1))))" - the outer eq has had
# one '#' stripped (ds's own argument got scanned once, so it's now live
# next time this body is rescanned) but everything nested inside stays
# exactly as written. Each #(cl,fact,...) call substitutes parameters
# into the stored body and returns the result, which - like the result of
# *any* form - gets rescanned by whoever called it; on that rescan the
# outer eq fires for real, and whichever branch it picks (having itself
# been through one more round of #-stripping while eq's own arguments
# were being evaluated) becomes live in turn. Comparison/arithmetic
# operands are never protected this way - they're always meant to fire
# eagerly, right when the form holding them is scanned; only a
# conditional's *branch values* need the ## guard, and only far enough
# out that eager argument-evaluation elsewhere doesn't reach in and fire
# them regardless of which branch actually gets chosen. lib/trac/*.tc
# has worked examples (mod3/mod5/fbline/loop in fizzbuzz.tc is the
# fullest one - recursion, arithmetic and branching all doing real work).
#
# Primitives implemented: ds (define), ss (mark parameter positions in a
# ds'd body by literal substring), cl (call - also how a stored function
# gets invoked; calling any name, stored or primitive, by writing
# #(name,...) directly does the same lookup), dd (delete a definition),
# eq/gr (string-equal / numeric greater-than conditionals, each taking
# two values to compare and two branch strings), ad/su/ml/dv (integer
# arithmetic), ln (string length), cc/cn (first character / first n
# characters of a string), ps (print - the only primitive with an
# immediate side effect, besides rs), rs (read one line from the
# terminal, for interactive scripts).
#
# Real TRAC's cc/cn/cs primitives worked against a single mutable "active
# string pointer" that each call advanced - genuinely useful for writing
# a parser character by character. That's not implemented here; cc/cn
# are plain, non-destructive prefix extraction, a real simplification.
# ss's segment-position markers are single Private Use Area runes
# (U+E000..U+E013 - the same "pick a sentinel real text will never
# contain" trick include/keyboard.h uses for Spec/Keyup), capping any
# one function at 20 parameters - ample for a demo, not a spec limit
# lifted from real TRAC. An early version of this used low control
# codes (1..20) instead, which silently ate every literal '\n' (code 10)
# in a stored body - PUA runes have no such collision with anything a
# real script would contain. ss also does a flat,
# left-to-right literal-substring replace across a function's *entire*
# stored body (matching real TRAC - segmentation has no idea where form
# boundaries are), so two segment names where one is a substring of the
# other (say "N" and "NUM") will misfire; choose names that don't overlap.
#
# Unlike a real interactive TRAC session, the whole source file is
# scanned in one batch rather than character-by-character against a
# live terminal - ps and rs still take effect immediately, in program
# order, so a script that always routes its output through ps (the
# idiomatic way to write one) behaves identically either way. Only
# plain literal text sitting outside any form - incidental whitespace
# between #(ds,...) definitions, say - is deferred: it's accumulated and
# printed once at the very end rather than interleaved with ps/rs
# output. Trailing newlines left over from a script's own formatting are
# trimmed from that leftover text before printing, as a pragmatic nicety
# for a batch CLI tool - not something real TRAC would do.
#
# usage: trac file.tc

include "sys.m";
	sys: Sys;

include "draw.m";
	Context: import Draw;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

Trac: module {
	init: fn(ctxt: ref Context, argv: list of string);
};

Def: adt {
	name: string;
	body: string;
};

stdout, stderr: ref Sys->FD;
stdin: ref Iobuf;
defs: list of ref Def;

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	stdout = sys->fildes(1);
	stderr = sys->fildes(2);
	stdin = bufio->fopen(sys->fildes(0), Sys->OREAD);

	argv = tl argv;
	if(argv == nil){
		sys->fprint(stderr, "usage: trac file.tc\n");
		raise "fail:usage";
	}
	(src, err) := readfile(hd argv);
	if(src == nil){
		sys->fprint(stderr, "trac: %s\n", err);
		raise "fail:open";
	}

	out := scan(src);
	while(len out > 0 && out[len out - 1] == '\n')
		out = out[0:len out - 1];
	if(len out > 0)
		sys->fprint(stdout, "%s\n", out);
}

# The single evaluator: copy literal text through, and for every form -
# active or neutral - find its matching close-paren, deal with it, and
# keep going right after that close-paren. Any text a form's evaluation
# produces (a primitive/function's return value) is rescanned in turn,
# which is what lets a call's result contain further calls of its own.
scan(text: string): string
{
	out := "";
	n := len text;
	i := 0;
	while(i < n){
		if(text[i] == '#' && i+2 < n && text[i+1] == '#' && text[i+2] == '('){
			(close, nil) := scanbalanced(text, i+2);
			if(close < 0){
				out += text[i:];
				break;
			}
			content := text[i+3:close];
			out += "#(" + content + ")";
			i = close + 1;
			continue;
		}
		if(text[i] == '#' && i+1 < n && text[i+1] == '('){
			(close, commasabs) := scanbalanced(text, i+1);
			if(close < 0){
				out += text[i:];
				break;
			}
			contentstart := i+2;
			segs: list of int;
			for(c := commasabs; c != nil; c = tl c)
				segs = (hd c - contentstart) :: segs;
			segs = revints(segs);
			rawargs := splitat(text[contentstart:close], segs);
			evargs: list of string;
			for(a := rawargs; a != nil; a = tl a)
				evargs = scan(hd a) :: evargs;
			evargs = revstrs(evargs);
			if(evargs != nil){
				name := hd evargs;
				result := invoke(name, tl evargs);
				out += scan(result);
			}
			i = close + 1;
			continue;
		}
		out += onechar(text[i]);
		i++;
	}
	return out;
}

# text[open] is assumed to be '(' (the one opening either a "#(" or a
# "##(" span). Finds the matching ')' by depth-counting every "#(" or
# "##(" met along the way as +1 and every ')' as -1, without evaluating
# or otherwise caring what's inside - purely lexical, works the same for
# an active or a neutral span. Also collects, in increasing order, the
# absolute positions of every comma seen at depth 1 - i.e. belonging
# directly to *this* form, not some form nested inside it.
scanbalanced(text: string, open: int): (int, list of int)
{
	n := len text;
	depth := 1;
	i := open + 1;
	commas: list of int;
	while(i < n){
		c := text[i];
		if(c == '#'){
			if(i+2 < n && text[i+1] == '#' && text[i+2] == '('){
				depth++;
				i += 3;
				continue;
			}
			if(i+1 < n && text[i+1] == '('){
				depth++;
				i += 2;
				continue;
			}
			i++;
			continue;
		}
		if(c == ')'){
			depth--;
			if(depth == 0)
				return (i, revints(commas));
			i++;
			continue;
		}
		if(c == ',' && depth == 1)
			commas = i :: commas;
		i++;
	}
	return (-1, revints(commas));
}

# s here is always a sub-slice of the original scanned text, and seps
# are positions of top-level commas within it (increasing order) - split
# it into the pieces between them.
splitat(s: string, seps: list of int): list of string
{
	parts: list of string;
	prev := 0;
	for(p := seps; p != nil; p = tl p){
		parts = s[prev:hd p] :: parts;
		prev = hd p + 1;
	}
	parts = s[prev:] :: parts;
	return revstrs(parts);
}

invoke(name: string, args: list of string): string
{
	case name {
	"ds" =>
		if(args == nil)
			return "";
		nm := hd args;
		body := "";
		if(tl args != nil)
			body = hd tl args;
		setdef(nm, body);
		return "";
	"ss" =>
		if(args == nil)
			return "";
		d := finddef(hd args);
		if(d == nil)
			return "";
		i := 0;
		for(s := tl args; s != nil; s = tl s){
			seg := hd s;
			if(seg != "" && i < 20)
				d.body = replaceall(d.body, seg, marker(i));
			i++;
		}
		return "";
	"cl" =>
		if(args == nil)
			return "";
		return invoke(hd args, tl args);
	"dd" =>
		for(a := args; a != nil; a = tl a)
			deldef(hd a);
		return "";
	"eq" =>
		return cond(args, 1);
	"gr" =>
		return cond(args, 2);
	"ad" =>
		return arith(args, '+');
	"su" =>
		return arith(args, '-');
	"ml" =>
		return arith(args, '*');
	"dv" =>
		return arith(args, '/');
	"ln" =>
		if(args == nil)
			return "0";
		return string len hd args;
	"ps" =>
		s := "";
		for(a := args; a != nil; a = tl a)
			s += hd a;
		sys->fprint(stdout, "%s", s);
		return "";
	"rs" =>
		if(stdin == nil)
			return "";
		line := stdin.gets('\n');
		if(line == nil)
			return "";
		if(len line > 0 && line[len line - 1] == '\n')
			line = line[0:len line - 1];
		return line;
	"cc" =>
		if(args == nil || hd args == "")
			return "";
		return onechar((hd args)[0]);
	"cn" =>
		if(args == nil || tl args == nil)
			return "";
		cnt := toint(hd args);
		s := hd tl args;
		if(cnt <= 0)
			return "";
		if(cnt >= len s)
			return s;
		return s[0:cnt];
	* =>
		d := finddef(name);
		if(d == nil)
			return "";
		return substitute(d.body, args);
	}
}

cond(args: list of string, mode: int): string
{
	if(args == nil || tl args == nil || tl tl args == nil || tl tl tl args == nil)
		return "";
	a := hd args;
	b := hd tl args;
	tstr := hd tl tl args;
	fstr := hd tl tl tl args;
	match: int;
	if(mode == 1)
		match = a == b;
	else
		match = toint(a) > toint(b);
	if(match)
		return tstr;
	return fstr;
}

arith(args: list of string, op: int): string
{
	if(args == nil || tl args == nil)
		return "0";
	a := toint(hd args);
	b := toint(hd tl args);
	r := 0;
	case op {
	'+' =>	r = a+b;
	'-' =>	r = a-b;
	'*' =>	r = a*b;
	'/' =>
		if(b == 0)
			return "0";
		r = a/b;
	}
	return string r;
}

toint(s: string): int
{
	i := 0;
	n := len s;
	neg := 0;
	if(i < n && s[i] == '-'){
		neg = 1;
		i++;
	}
	v := 0;
	got := 0;
	while(i < n && s[i] >= '0' && s[i] <= '9'){
		v = v*10 + (s[i]-'0');
		got = 1;
		i++;
	}
	if(!got)
		return 0;
	if(neg)
		return -v;
	return v;
}

finddef(name: string): ref Def
{
	for(d := defs; d != nil; d = tl d)
		if((hd d).name == name)
			return hd d;
	return nil;
}

setdef(name: string, body: string)
{
	d := finddef(name);
	if(d != nil){
		d.body = body;
		return;
	}
	defs = ref Def(name, body) :: defs;
}

deldef(name: string)
{
	r: list of ref Def;
	for(d := defs; d != nil; d = tl d)
		if((hd d).name != name)
			r = hd d :: r;
	defs = r;
}

# Replaces every position-marker control character in a stored body with
# the corresponding argument (missing arguments substitute as empty) -
# a flat pass, the same as ss's own substring replacement, oblivious to
# any form structure the body's text happens to contain.
substitute(body: string, args: list of string): string
{
	r := "";
	for(i := 0; i < len body; i++){
		c := body[i];
		if(c >= MarkBase && c < MarkBase+20)
			r += argat(args, c-MarkBase);
		else
			r += onechar(c);
	}
	return r;
}

argat(args: list of string, idx: int): string
{
	i := 0;
	for(a := args; a != nil; a = tl a){
		if(i == idx)
			return hd a;
		i++;
	}
	return "";
}

MarkBase: con 16rE000;	# Unicode Private Use Area, same sentinel trick as include/keyboard.h's Spec

marker(i: int): string
{
	s := " ";
	s[0] = MarkBase + i;
	return s;
}

onechar(c: int): string
{
	s := " ";
	s[0] = c;
	return s;
}

indexof(s: string, sub: string, start: int): int
{
	ls := len s;
	lu := len sub;
	if(lu == 0)
		return -1;
	for(i := start; i <= ls - lu; i++){
		ok := 1;
		for(j := 0; j < lu; j++)
			if(s[i+j] != sub[j]){
				ok = 0;
				break;
			}
		if(ok)
			return i;
	}
	return -1;
}

replaceall(s: string, target: string, repl: string): string
{
	if(target == "")
		return s;
	r := "";
	i := 0;
	for(;;){
		p := indexof(s, target, i);
		if(p < 0){
			r += s[i:];
			break;
		}
		r += s[i:p];
		r += repl;
		i = p + len target;
	}
	return r;
}

revstrs(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

revints(l: list of int): list of int
{
	r: list of int;
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
