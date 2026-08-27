implement Rc;

# Real Plan 9 rc, translated 1:1 - not a workalike. Source:
# utils/rcsh/ in this tree (rc.h, word.c, var.c, and eventually
# lex.c/syn.y/tree.c/code.c/exec.c/glob.c/here.c/io.c/main.c/pcmd.c/
# pfnc.c/trap.c). See doc/plan9-terminal-plan.md for why this exists
# (mk.b needs a real rc to run genuine Plan 9 mkfile recipes) and for
# the one real correction that changed this translation's shape before
# it started: utils/rcsh was never a portable rc. Its own mkfile
# refuses to build for anything but Windows NT/95 - `Nt.c` (549 lines)
# is the ONLY platform binding that was ever written, and no Posix.c
# ever existed here, unlike other utils/ tools (utils/mk/Posix.c,
# utils/cc/Posix.c). So this translation splits into two different
# kinds of work: 4,273 lines of real, portable rc-language core
# (lexer, grammar, word lists, variables, the code-vector execution
# engine) to translate directly, plus an entirely new platform layer
# (process spawn/wait, pipes) to design against Limbo's spawn/channel
# model from scratch, informed by Nt.c's own 18-function interface as
# a checklist of responsibilities, not by anything to transliterate.
#
# This file is being built incrementally, in slices sized so each one
# is independently testable without needing the rest - per plan, the
# lexer and grammar are NOT independent of each other (yacc generates
# the token constants lex.c returns), so lexer-first would have been
# the weakest-verified slice in this whole backlog's history. The
# first real slice, below, is word.c + var.c's pure list/table logic:
# no parser, no execution engine, no `runq` (the real source's global
# "currently running thread" pointer) needed at all for the functions
# translated so far - real, direct, testable value semantics.
#
# Real rc frees Word/List/Var/Redir cells explicitly (freewords,
# freelist, turfredir in the real source). Limbo has a real garbage
# collector; every one of those free-paths is simply omitted here,
# the same adaptation this whole backlog makes wherever C's manual
# memory management has no Limbo counterpart to translate - not
# silently, stated here once rather than re-noted at each omission.
#
# `vlook`'s real source consults `runq->local` (the current thread's
# local-variable list) before falling back to the global hash table.
# There is no Thread/runq yet - `curlocal` below stands in for it,
# always nil until code.c/exec.c introduce a real running thread, at
# which point `vlook` starts consulting the real thing instead.
#
# Second slice: glob.c's pure pattern-matching logic (deglob, match,
# matchfn, and a reduced haswild standing in for globsize - see below)
# plus word.c's subwords, deferred from the first slice because it
# needs deglob. glob.c's directory-walking half (globdir, glob,
# globsort, globlist, globlist1) stays deferred - it needs runq's
# argument stack and real directory reads, the same "needs a running
# thread" boundary as pushword/popword/pushlist/poplist already are.
#
# A real simplification, not a mechanical translation: match()'s real
# source manually decodes UTF-8 byte sequences itself (equtf/nextutf/
# unicode helpers, operating on a raw `char*` byte stream), because
# C's `char*` has no idea what a multi-byte code point is. Limbo's
# `string` type already IS a rune sequence - `s[i]` is already a
# decoded code point, not a raw byte - so those three helpers have no
# Limbo equivalent needed at all; this translation indexes strings
# directly instead. The `GLOB` escape sentinel (rune value 2, matching
# the real `((char)0x02)`) is an ordinary rune value and lives inside
# ordinary Limbo `string`s throughout this file - no `array of byte`
# anywhere here, unlike marshal.b's `Outbuf`, because glob patterns
# and file names are always textual, never arbitrary binary content.
# rctest.b's test patterns embed the GLOB sentinel as a RAW U+0002
# byte written directly into the source file, not as a textual escape
# sequence - Limbo parses a literal control character inside a string
# literal exactly the same as it would parse an escape for the same
# rune, so this is equivalent, not a workaround. It is also invisible
# in an ordinary editor: anyone touching a glob pattern in rctest.b
# must confirm the byte survived (e.g. dump the line's repr()),
# since a tool that normalizes or strips control characters would
# silently turn a wildcard test into a literal-character test while
# every assertion still compiles and the test names still read the
# same.
#
# One real, deliberate behavioral divergence, not an oversight: real
# match()'s `[...]` case has no bounds check for a pattern that runs
# out before the closing `]`, or for `GLOB` as the pattern's very last
# rune with nothing after it - both read past the string's own NUL
# terminator in C (undefined behavior on a well-formed C string, since
# a real caller-supplied pattern ending in a syntax error is not
# expected). Limbo strings carry their own length and bounds-check
# every index at runtime, so an equivalent out-of-bounds read would
# not silently continue - it would abort the whole program in a way
# nothing here can recover from. This translation adds explicit
# `return 0` guards at exactly those two spots instead, matching the
# real source's own EXISTING syntax-error-returns-0 handling in every
# other branch of the same function, and named here as a divergence
# specifically because it changes what an actually-malformed pattern
# does (a clean "no match" instead of undefined behavior), not because
# it changes what a well-formed one does.

include "sys.m";
	sys: Sys;
	print: import sys;

include "draw.m";

Rc: module
{
	init:		fn(ctxt: ref Draw->Context, argv: list of string);

	# sets up gvar/kw - real rc does this kind of thing at process
	# startup, before anything else runs. init() calls this; so must
	# any test that pokes at gvlook/vlook/iskeyword directly, since
	# init() is the CLI entry point and tests shouldn't invoke that
	# (same convention as marshal.b's tests calling run(), not init()).
	bootstrap:	fn();

	# token constants, matching real rc's yacc-generated ones in
	# spirit (single-character tokens use their own rune value below
	# 256, named tokens are allocated above it - the same scheme yacc
	# itself uses) - not required to match rc's own numeric values,
	# since nothing outside this translation ever sees them; only
	# internal consistency matters. Declared here, in the interface,
	# rather than as a plain top-level `con` in the implementation,
	# specifically so rctest.b can build meaningful Tree nodes to test
	# against (a bare int literal in the test file would be opaque and
	# would silently go stale if this list is ever reordered).
	Tokbase: con 256;
	Tfor, Tin, Twhile, Tif, Tnot, Ttwiddle, Tbang, Tsubshell, Tswitch, Tfn,
	Tword, Tredir, Tdup, Tpipe, Tsub, Tsimple, Targlist, Twords, Tbrace,
	Tparen, Tpcmd, Tpipefd, Tandand, Toror, Tcount: con Tokbase+iota;

	# exposed for rctest.b - none of these need a parser or a
	# running thread, per the header comment above.
	testhash:	fn(s: string, n: int): int;
	testnewword:	fn(wd: string): ref Word;
	testcount:	fn(w: ref Word): int;
	testcopywords:	fn(a: ref Word, tail: ref Word): ref Word;
	testlist2str:	fn(w: ref Word): string;
	testconclist:	fn(lp: ref Word, rp: ref Word, tail: ref Word): ref Word;
	testgvlook:	fn(name: string): ref Var;
	testvlook:	fn(name: string): ref Var;
	testsetvar:	fn(name: string, val: ref Word);
	testiskeyword:	fn(name: string): int;
	testwordlist:	fn(words: list of string): ref Word;	# helper for tests

	testdeglob:	fn(s: string): string;
	testmatch:	fn(s: string, p: string, stop: int): int;
	testmatchfn:	fn(s: string, p: string): int;
	testhaswild:	fn(p: string): int;
	testsubwords:	fn(val: ref Word, wlen: int, sub: ref Word, a: ref Word): ref Word;

	testnewtree:	fn(): ref Tree;
	testtree1:	fn(ttype: int, c0: ref Tree): ref Tree;
	testtree2:	fn(ttype: int, c0: ref Tree, c1: ref Tree): ref Tree;
	testtree3:	fn(ttype: int, c0: ref Tree, c1: ref Tree, c2: ref Tree): ref Tree;
	testmung1:	fn(t: ref Tree, c0: ref Tree): ref Tree;
	testmung2:	fn(t: ref Tree, c0: ref Tree, c1: ref Tree): ref Tree;
	testmung3:	fn(t: ref Tree, c0: ref Tree, c1: ref Tree, c2: ref Tree): ref Tree;
	testepimung:	fn(comp: ref Tree, epi: ref Tree): ref Tree;
	testtoken:	fn(str: string, ttype: int): ref Tree;
	testklook:	fn(name: string): ref Tree;
	testtokenspread:	fn(): int;
};

# --- word.c: word lists ---------------------------------------------

Word: adt
{
	word:	string;
	next:	cyclic ref Word;
};

newword(wd: string, next: ref Word): ref Word
{
	return ref Word(wd, next);
}

count(w: ref Word): int
{
	n := 0;
	for(; w != nil; w = w.next)
		n++;
	return n;
}

# copy arglist a, adding the copy to the front of tail. The real
# source builds this with a manual end-of-list pointer
# (Word**); Limbo has no address-of/pointer-to-pointer, so this is
# recursive instead - same result (a[0..n-1] in order, then tail),
# different mechanism.
copywords(a: ref Word, tail: ref Word): ref Word
{
	if(a == nil)
		return tail;
	return newword(a.word, copywords(a.next, tail));
}

list2str(words: ref Word): string
{
	s := "";
	for(ap := words; ap != nil; ap = ap.next)
		s += ap.word + " ";
	if(s != "")
		s = s[0:len s-1];	# drop the trailing separator, matching
					# the real source's own s[-1]='\0'
	return s;
}

# the `^' operator: pairwise-concatenate two word lists, continuing
# on whichever list is longer by repeating the shorter list's last
# word (real conclist's own recursion: lp->next==0?lp:lp->next).
conclist(lp: ref Word, rp: ref Word, tail: ref Word): ref Word
{
	if(lp.next != nil || rp.next != nil){
		nlp := lp.next;
		if(nlp == nil)
			nlp = lp;
		nrp := rp.next;
		if(nrp == nil)
			nrp = rp;
		tail = conclist(nlp, nrp, tail);
	}
	return newword(lp.word + rp.word, tail);
}

testnewword(wd: string): ref Word
{
	return newword(wd, nil);
}

testcount(w: ref Word): int
{
	return count(w);
}

testcopywords(a: ref Word, tail: ref Word): ref Word
{
	return copywords(a, tail);
}

testlist2str(w: ref Word): string
{
	return list2str(w);
}

testconclist(lp: ref Word, rp: ref Word, tail: ref Word): ref Word
{
	return conclist(lp, rp, tail);
}

testwordlist(words: list of string): ref Word
{
	if(words == nil)
		return nil;
	return newword(hd words, testwordlist(tl words));
}

# subwords: the `$var(n m ...)' subscript operator. sub is a word list
# of subscript specs, walked in the real source's own reverse order
# (it recurses before doing anything, so the LAST subscript is
# resolved first, prepended as the recursion unwinds - the final
# result is in the original subscript order). Each subscript is
# deglobbed (unescaping a literal digit is unlikely but matches the
# source), then parsed as a run of leading decimal digits (anything
# after the digits, or a non-digit subscript entirely, is simply
# ignored - matching the real source's own unchecked `while('0'<=*s
# && *s<='9')` scan, not a translation gap).
subwords(val: ref Word, wlen: int, sub: ref Word, a: ref Word): ref Word
{
	if(sub == nil)
		return a;
	a = subwords(val, wlen, sub.next, a);
	s := deglob(sub.word);
	n := 0;
	i := 0;
	while(i < len s && s[i] >= '0' && s[i] <= '9'){
		n = n*10 + (s[i] - '0');
		i++;
	}
	if(n < 1 || wlen < n)
		return a;
	v := val;
	for(; n != 1; n--)
		v = v.next;
	return newword(v.word, a);
}

testsubwords(val: ref Word, wlen: int, sub: ref Word, a: ref Word): ref Word
{
	return subwords(val, wlen, sub, a);
}

# --- glob.c (partial): pure pattern-matching logic ------------------
#
# See this file's own header comment for why match()'s manual UTF-8
# decoding has no Limbo equivalent, why GLOB lives in an ordinary
# string, and for the one deliberate divergence (explicit bounds
# guards where the real source would read past its own NUL
# terminator on a malformed pattern).

Glob: con 2;	# real rc's ((char)0x02) escape sentinel

deglob(s: string): string
{
	r := "";
	n := len s;
	for(i := 0; i < n; i++){
		if(s[i] == Glob)
			i++;
		if(i < n)
			r += s[i:i+1];
	}
	return r;
}

# does p contain at least one real glob metacharacter (as opposed to
# only escaped-literal-GLOB sequences or plain characters) - the
# boolean the real source's globsize() computes as a side effect of
# sizing a malloc buffer Limbo strings don't need. GLOB as the very
# last rune with nothing after it (malformed, never produced by real
# code) is treated here as "not a wildcard"; the real globsize() would
# read past the string's own NUL terminator and count it as one, which
# isn't meaningful to replicate for an input that shouldn't occur.
haswild(p: string): int
{
	isglob := 0;
	n := len p;
	i := 0;
	while(i < n){
		if(p[i] == Glob){
			i++;
			if(i < n && p[i] != Glob)
				isglob++;
		}
		i++;
	}
	return isglob != 0;
}

# does s match pattern p, stopping the scan of p at the sentinel rune
# `stop' (real rc calls this with stop=='/' to match one path
# component at a time out of a `/'-separated pattern).
match(s: string, p: string, stop: int): int
{
	sn := len s;
	pn := len p;
	si := 0;
	pi := 0;
	while(pi < pn && p[pi] != stop){
		if(p[pi] != Glob){
			if(si >= sn || p[pi] != s[si])
				return 0;
		}else{
			pi++;
			if(pi >= pn)
				return 0;	# GLOB with nothing after it -
						# see header comment
			case p[pi] {
			Glob =>
				if(si >= sn || s[si] != Glob)
					return 0;
			'*' =>
				for(;;){
					if(match(s[si:], p[pi+1:], stop))
						return 1;
					if(si >= sn)
						break;
					si++;
				}
				return 0;
			'?' =>
				if(si >= sn)
					return 0;
			'[' =>
				if(si >= sn)
					return 0;
				c := s[si];
				pi++;
				compl := pi < pn && p[pi] == '~';
				if(compl)
					pi++;
				hit := 0;
				while(1){
					if(pi >= pn)
						return 0;	# unterminated [...]
					if(p[pi] == ']')
						break;
					lo := p[pi];
					pi++;
					hi := lo;
					if(pi < pn && p[pi] == '-'){
						pi++;
						if(pi >= pn)
							return 0;	# unterminated [...]
						hi = p[pi];
						pi++;
						if(hi < lo){
							t := lo;
							lo = hi;
							hi = t;
						}
					}
					if(lo <= c && c <= hi)
						hit = 1;
				}
				if(compl)
					hit = !hit;
				if(hit == 0)
					return 0;
			}
		}
		si++;
		pi++;
	}
	return si >= sn;
}

# . and .. are only matched by patterns starting with `.'
matchfn(s: string, p: string): int
{
	if(len s > 0 && s[0] == '.' &&
	   (len s == 1 || (s[1] == '.' && len s == 2)) &&
	   (len p == 0 || p[0] != '.'))
		return 0;
	return match(s, p, '/');
}

testdeglob(s: string): string
{
	return deglob(s);
}

testmatch(s: string, p: string, stop: int): int
{
	return match(s, p, stop);
}

testmatchfn(s: string, p: string): int
{
	return matchfn(s, p);
}

testhaswild(p: string): int
{
	return haswild(p);
}

# --- tree.c (partial): the Tree node constructors -------------------
#
# Third slice: the parse-tree constructors real rc's grammar actions
# call (tree1/tree2/tree3/mung1/mung2/mung3/epimung/token), independent
# of the lexer/grammar pair itself - these are called BY grammar
# actions, not coupled to the lexer the way lex.c and syn.y are coupled
# to each other, so they're testable now the same way word.c/var.c/
# glob.c's pure pieces were. `simplemung` is deferred: it needs a
# tree-to-source pretty-printer (`pfmt(s, "%t", t)` in the real source,
# from io.c/pfnc.c) that doesn't exist yet, so it waits for that.
#
# Real rc's own Treenodes/freenodes machinery is a bulk-allocation
# list kept ONLY so every tree node can be freed at once later - not
# just "don't call free()" like every other omission so far, this
# whole bookkeeping mechanism has no purpose to translate at all under
# a real garbage collector, so the Tree adt below has no `next` field
# corresponding to it.
#
# `type' is a reserved word in Limbo - the C source's own `type` field
# is named `ttype` here, matching the same rename already used for
# `type`-as-a-parameter elsewhere in this file (Kw.toktype).

Tree: adt
{
	ttype:	int;
	rtype:	int;
	fd0, fd1: int;
	str:	string;
	quoted:	int;
	iskw:	int;
	child:	array of ref Tree;	# always length 3, matching child[3]
};

newtree(): ref Tree
{
	return ref Tree(0, 0, 0, 0, "", 0, 0, array[3] of ref Tree);
}

tree3(ttype: int, c0: ref Tree, c1: ref Tree, c2: ref Tree): ref Tree
{
	if(ttype == ';'){
		if(c0 == nil)
			return c1;
		if(c1 == nil)
			return c0;
	}
	t := newtree();
	t.ttype = ttype;
	t.child[0] = c0;
	t.child[1] = c1;
	t.child[2] = c2;
	return t;
}

tree1(ttype: int, c0: ref Tree): ref Tree
{
	return tree3(ttype, c0, nil, nil);
}

tree2(ttype: int, c0: ref Tree, c1: ref Tree): ref Tree
{
	return tree3(ttype, c0, c1, nil);
}

mung1(t: ref Tree, c0: ref Tree): ref Tree
{
	t.child[0] = c0;
	return t;
}

mung2(t: ref Tree, c0: ref Tree, c1: ref Tree): ref Tree
{
	t.child[0] = c0;
	t.child[1] = c1;
	return t;
}

mung3(t: ref Tree, c0: ref Tree, c1: ref Tree, c2: ref Tree): ref Tree
{
	t.child[0] = c0;
	t.child[1] = c1;
	t.child[2] = c2;
	return t;
}

# epilog chains build up in forward order via repeated mung2(child[1] =
# the rest of the chain); epimung walks to the tail (the first node
# whose child[1] is nil) and attaches comp there.
epimung(comp: ref Tree, epi: ref Tree): ref Tree
{
	if(epi == nil)
		return comp;
	p := epi;
	while(p.child[1] != nil)
		p = p.child[1];
	p.child[1] = comp;
	return epi;
}

token(str: string, ttype: int): ref Tree
{
	t := newtree();
	t.ttype = ttype;
	t.str = str;
	return t;
}

testnewtree(): ref Tree
{
	return newtree();
}

testtree1(ttype: int, c0: ref Tree): ref Tree
{
	return tree1(ttype, c0);
}

testtree2(ttype: int, c0: ref Tree, c1: ref Tree): ref Tree
{
	return tree2(ttype, c0, c1);
}

testtree3(ttype: int, c0: ref Tree, c1: ref Tree, c2: ref Tree): ref Tree
{
	return tree3(ttype, c0, c1, c2);
}

testmung1(t: ref Tree, c0: ref Tree): ref Tree
{
	return mung1(t, c0);
}

testmung2(t: ref Tree, c0: ref Tree, c1: ref Tree): ref Tree
{
	return mung2(t, c0, c1);
}

testmung3(t: ref Tree, c0: ref Tree, c1: ref Tree, c2: ref Tree): ref Tree
{
	return mung3(t, c0, c1, c2);
}

testepimung(comp: ref Tree, epi: ref Tree): ref Tree
{
	return epimung(comp, epi);
}

testtoken(str: string, ttype: int): ref Tree
{
	return token(str, ttype);
}

# --- var.c: variables and the keyword table -------------------------

NVAR: con 521;	# real rc's own hash-table size, "big enough" not tuned
NKW: con 30;	# real rc's own keyword-table size

# the token constants themselves are declared in the Rc module
# interface above, not here - see that declaration's own comment for
# why (rctest.b needs to build real Tree nodes to test against).

Var: adt
{
	name:		string;
	val:		ref Word;
	changed:	int;
	next:		cyclic ref Var;
	# fn, fnchanged, pc (function-definition fields) are added
	# when code.c/exec.c are translated - every real rc Var has
	# them, but nothing here yet uses them.
};

Kw: adt
{
	name:		string;
	toktype:	int;	# `type' is a reserved word in Limbo
	next:		cyclic ref Kw;
};

gvar: array of ref Var;
kw: array of ref Kw;
curlocal: ref Var;	# stands in for runq->local until Thread exists

hash(s: string, n: int): int
{
	h := 0;
	i := 1;
	for(k := 0; k < len s; k++){
		h += s[k]*i;
		i++;
	}
	h %= n;
	if(h < 0)
		h += n;
	return h;
}

kenter(toktype: int, name: string)
{
	h := hash(name, NKW);
	kw[h] = ref Kw(name, toktype, kw[h]);
}

initkw()
{
	kw = array[NKW] of ref Kw;
	# real lex.c's own kenter() call list, same order (order only
	# matters for hash-bucket chain order, not lookup correctness).
	kenter(Tfor, "for");
	kenter(Tin, "in");
	kenter(Twhile, "while");
	kenter(Tif, "if");
	kenter(Tnot, "not");
	kenter(Ttwiddle, "~");
	kenter(Tbang, "!");
	kenter(Tsubshell, "@");
	kenter(Tswitch, "switch");
	kenter(Tfn, "fn");
}

# real klook() wraps this in a Tree node via token(name, WORD) - not
# translated yet (tree.c isn't). This is the part of klook that's
# genuinely independent: is `name' one of rc's reserved words, and if
# so which token does it become.
iskeyword(name: string): int
{
	for(p := kw[hash(name, NKW)]; p != nil; p = p.next)
		if(p.name == name)
			return p.toktype;
	return 0;
}

testiskeyword(name: string): int
{
	return iskeyword(name);
}

# the real klook(), now that Tree exists (tree.c's section above) -
# builds a real WORD-typed token, then overwrites its type and sets
# iskw if the name turns out to be a reserved word. iskeyword() above
# stays as its own tested function rather than being rewritten in
# terms of this one, since existing tests already pin its behavior
# directly.
klook(name: string): ref Tree
{
	t := token(name, Tword);
	for(p := kw[hash(name, NKW)]; p != nil; p = p.next){
		if(p.name == name){
			t.ttype = p.toktype;
			t.iskw = 1;
			break;
		}
	}
	return t;
}

testklook(name: string): ref Tree
{
	return klook(name);
}

# rctest.b hand-copies the whole Tokbase/iota chain above into its own
# mirror of this module's interface (see that declaration's own
# comment for why). A bare `Rc->Tcount` reference from rctest.b does
# NOT cross the module boundary at runtime - module interface `con`s
# are compile-time constants, resolved from EACH file's own copy of
# the declaration, so a `Rc->X` comparison in rctest.b can never
# detect the two copies disagreeing (confirmed directly: a deliberate
# drift introduced during development left such a check passing while
# real behavioral tests like klook's caught the same drift instead).
# This function returns the value as REAL DATA, computed here, at
# runtime, inside this module - the only way rctest.b can actually
# compare rc.b's real constants against its own copy instead of
# silently trusting two independently-typed lists to agree.
testtokenspread(): int
{
	return Tcount - Tfor;
}

newvar(name: string, next: ref Var): ref Var
{
	return ref Var(name, nil, 0, next);
}

gvlook(name: string): ref Var
{
	h := hash(name, NVAR);
	for(v := gvar[h]; v != nil; v = v.next)
		if(v.name == name)
			return v;
	gvar[h] = newvar(name, gvar[h]);
	return gvar[h];
}

vlook(name: string): ref Var
{
	for(v := curlocal; v != nil; v = v.next)
		if(v.name == name)
			return v;
	return gvlook(name);
}

setvar(name: string, val: ref Word)
{
	v := vlook(name);
	v.val = val;
	v.changed = 1;
}

testhash(s: string, n: int): int
{
	return hash(s, n);
}

testgvlook(name: string): ref Var
{
	return gvlook(name);
}

testvlook(name: string): ref Var
{
	return vlook(name);
}

testsetvar(name: string, val: ref Word)
{
	setvar(name, val);
}

bootstrap()
{
	gvar = array[NVAR] of ref Var;
	initkw();
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	bootstrap();
	print("rc: word-list/variable-table foundation only, no parser yet\n");
}
