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
# is independently testable without needing the rest. In the real
# source, the lexer and grammar are NOT independent of each other -
# yacc generates the token constants lex.c returns - but that coupling
# doesn't bind THIS translation, since the Rc module interface below
# declares its own Tokbase/iota token constants directly rather than
# having them generated from a grammar; the fourth slice (see below)
# translated lex.c standalone on exactly that basis, with real tests
# passing before any grammar exists. The first real slice, below, is
# word.c + var.c's pure list/table logic:
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
	testlexinit:	fn(s: string): ref Lexstate;
	testlexnext:	fn(ls: ref Lexstate): (int, ref Tree);

	# pcmd.c: the tree-to-source pretty-printer.
	testpcmd:	fn(t: ref Tree): string;
	testfnstr:	fn(t: ref Tree): string;
	testparseprint:		fn(s: string): string;
	testparseprintfn:	fn(s: string): string;

	# code.c: tree-to-instruction-vector compilation.
	testcompile:	fn(s: string, eflag: int): string;

	# syn.y: the grammar. Each of these lexes+parses a fresh string
	# from scratch and returns the result as a treeshape() string
	# (see rc.b's header comment) rather than a raw ref Tree, so
	# rctest.b can compare a whole parse in one assertion.
	testparseword:	fn(s: string): string;
	testparsewords:	fn(s: string): string;
	testparsesimple:	fn(s: string): string;
	testparsecmd:	fn(s: string): string;
	testparsebody:	fn(s: string): string;
	testparseline:	fn(s: string): string;
	testcurtok:	fn(): int;
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

# --- lex.c: the tokenizer ---------------------------------------------
#
# Fourth slice, and the first genuinely large one: real rc's lexer
# reads from `runq->cmdfd` (the current thread's input), a dependency
# every earlier slice deliberately avoided. There is no Thread yet, so
# this version reads from an in-memory string instead (`Lexstate.buf`)
# - real lexical behavior (word/glob/quote/redirection-arrow scanning)
# doesn't care where its characters come from, only the real source's
# own interactive bookkeeping does (`doprompt`/`pprompt()`/the
# `flag['V']`-gated echo in `getnext()`), and that bookkeeping is
# dropped here, not translated - deferred to when there's a real
# Thread to prompt on behalf of.
#
# Two omissions are C-buffer artifacts, not rc language semantics, and
# have no Limbo counterpart needed: `tok[NTOK]`'s fixed 8192-byte cap
# (and the "token buffer too short" error it can raise) - Limbo
# strings grow; and `addutf`'s manual multi-byte UTF-8 assembly - same
# simplification as glob.c's match(), since Limbo strings are already
# rune sequences. A token is accumulated with `sys->sprint("%c", c)`
# per rune (confirmed against this tree's own p9/cmd/ascii.b, which
# names the one real gotcha: that format verb genuinely emits a
# proper multi-byte UTF-8 encoding for a rune above 127, which is
# exactly what's wanted here - a raw single BYTE 0-255 would be the
# wrong tool, and ascii.b's own header comment explains why for its
# own, different, reason).
#
# yyerror() prints a real diagnostic to `err` and resyncs input to the
# next newline - deferred with everything else that needs a Thread;
# a lex error here just returns Eof/nil, the same "no valid token"
# outcome the real source reaches right after calling it.
#
# Real rc.h's redirection-type constants (APPEND/WRITE/READ/HERE/
# DUPFD/CLOSE = 1..6) are copied verbatim, not reassigned via the
# Tokbase/iota scheme - they're plain #defines in the real source, not
# yacc-generated tokens, so there's a real, specific numbering to be
# faithful to rather than an internal-consistency-only choice.
Append: con 1;
Write: con 2;
Read: con 3;
Here: con 4;
Dupfd: con 5;
Close: con 6;

Eof: con -1;

Lexstate: adt
{
	buf:		string;
	pos:		int;
	future:		int;	# one-rune lookahead; Eof means "empty"
	peekc:		int;	# backslash-newline pushback; Eof means "empty"
	lastc:		int;
	lastdol:	int;	# was the last token '$', '$#', or '"'?
	lastword:	int;	# was the last token a word or word terminator?
	inquote:	int;
};

lexinit(s: string): ref Lexstate
{
	return ref Lexstate(s, 0, Eof, Eof, 0, 0, 0, 0);
}

Wordstops: con "\n \t\r#;&|^$=`'{}()<>";
Idstops: con "!\"#$%&'()+,-./:;<=>?@[\\]^`{|}~";

inset(set: string, c: int): int
{
	for(i := 0; i < len set; i++)
		if(set[i] == c)
			return 1;
	return 0;
}

wordchr(c: int): int
{
	return inset(Wordstops, c) == 0 && c != Eof;
}

idchr(c: int): int
{
	return c > ' ' && inset(Idstops, c) == 0;
}

rawgetc(ls: ref Lexstate): int
{
	if(ls.pos >= len ls.buf)
		return Eof;
	c := ls.buf[ls.pos];
	ls.pos++;
	return c;
}

# backslash-newline is a line continuation (becomes a space);
# backslash followed by anything else is a literal backslash, with
# the following character pushed back for the next call to see.
getnext(ls: ref Lexstate): int
{
	c: int;
	if(ls.peekc != Eof){
		c = ls.peekc;
		ls.peekc = Eof;
		return c;
	}
	c = rawgetc(ls);
	if(ls.inquote == 0 && c == '\\'){
		c = rawgetc(ls);
		if(c == '\n')
			c = ' ';
		else{
			ls.peekc = c;
			c = '\\';
		}
	}
	return c;
}

nextc(ls: ref Lexstate): int
{
	if(ls.future == Eof)
		ls.future = getnext(ls);
	return ls.future;
}

advance(ls: ref Lexstate): int
{
	c := nextc(ls);
	ls.lastc = ls.future;
	ls.future = Eof;
	return c;
}

nextis(ls: ref Lexstate, c: int): int
{
	if(nextc(ls) == c){
		advance(ls);
		return 1;
	}
	return 0;
}

skipwhite(ls: ref Lexstate)
{
	for(;;){
		c := nextc(ls);
		if(c == '#'){
			for(;;){
				c = nextc(ls);
				if(c == '\n' || c == Eof)
					break;
				advance(ls);
			}
		}
		if(c == ' ' || c == '\t' || c == '\r')
			advance(ls);
		else
			return;
	}
}

skipnl(ls: ref Lexstate)
{
	for(;;){
		skipwhite(ls);
		c := nextc(ls);
		if(c != '\n')
			return;
		advance(ls);
	}
}

# the shared arrow-parsing code real rc's '|'/'<'/'>' switch cases
# fall through into (single '|', not '||', is a real PIPE token too).
lexredir(ls: ref Lexstate, c0: int): (int, ref Tree)
{
	ls.lastdol = 0;
	t := newtree();
	case c0 {
	'|' =>
		t.ttype = Tpipe;
		t.fd0 = 1;
		t.fd1 = 0;
	'>' =>
		t.ttype = Tredir;
		if(nextis(ls, c0))
			t.rtype = Append;
		else
			t.rtype = Write;
		t.fd0 = 1;
	'<' =>
		t.ttype = Tredir;
		if(nextis(ls, c0))
			t.rtype = Here;
		else
			t.rtype = Read;
		t.fd0 = 0;
	}
	if(nextis(ls, '[')){
		c := advance(ls);
		if(c < '0' || c > '9')
			return (Eof, nil);	# syntax error - see header comment
		t.fd0 = 0;
		do{
			t.fd0 = t.fd0*10 + c - '0';
			c = advance(ls);
		}while(c >= '0' && c <= '9');
		if(c == '='){
			if(t.ttype == Tredir)
				t.ttype = Tdup;
			c = advance(ls);
			if(c >= '0' && c <= '9'){
				t.rtype = Dupfd;
				t.fd1 = t.fd0;
				t.fd0 = 0;
				do{
					t.fd0 = t.fd0*10 + c - '0';
					c = advance(ls);
				}while(c >= '0' && c <= '9');
			}else{
				if(t.ttype == Tpipe)
					return (Eof, nil);
				t.rtype = Close;
			}
		}
		if(c != ']' ||
		   (t.ttype == Tdup && (t.rtype == Here || t.rtype == Append)))
			return (Eof, nil);
	}
	if(t.ttype == Tpipe)
		skipnl(ls);
	return (t.ttype, t);
}

lexquote(ls: ref Lexstate): (int, ref Tree)
{
	ls.lastdol = 0;
	ls.lastword = 1;
	ls.inquote = 1;
	acc := "";
	for(;;){
		c := advance(ls);
		if(c == Eof)
			break;
		if(c == '\''){
			if(nextc(ls) != '\'')
				break;
			advance(ls);
		}
		acc += sys->sprint("%c", c);
	}
	t := token(acc, Tword);
	t.quoted = 1;
	return (t.ttype, t);
}

lexword(ls: ref Lexstate, c0: int): (int, ref Tree)
{
	acc := "";
	c := c0;
	for(;;){
		if(c == '*' || c == '[' || c == '?' || c == Glob)
			acc += sys->sprint("%c", Glob);
		acc += sys->sprint("%c", c);
		c = nextc(ls);
		wantmore: int;
		if(ls.lastdol)
			wantmore = idchr(c);
		else
			wantmore = wordchr(c);
		if(wantmore == 0)
			break;
		advance(ls);
	}
	ls.lastword = 1;
	ls.lastdol = 0;
	t := klook(acc);
	if(t.ttype != Tword)
		ls.lastword = 0;
	t.quoted = 0;
	return (t.ttype, t);
}

lexnext(ls: ref Lexstate): (int, ref Tree)
{
	d := nextc(ls);

	if(ls.lastword){
		ls.lastword = 0;
		if(d == '('){
			advance(ls);
			return (Tsub, nil);
		}
		if(wordchr(d) || d == '\'' || d == '`' || d == '$' || d == '"')
			return ('^', nil);
	}
	ls.inquote = 0;
	skipwhite(ls);
	c := advance(ls);

	case c {
	Eof =>
		ls.lastdol = 0;
		return (Eof, nil);
	'$' =>
		ls.lastdol = 1;
		if(nextis(ls, '#'))
			return (Tcount, nil);
		if(nextis(ls, '"'))
			return ('"', nil);
		return ('$', nil);
	'&' =>
		ls.lastdol = 0;
		if(nextis(ls, '&')){
			skipnl(ls);
			return (Tandand, nil);
		}
		return ('&', nil);
	'|' =>
		ls.lastdol = 0;
		if(nextis(ls, '|')){
			skipnl(ls);
			return (Toror, nil);
		}
		return lexredir(ls, c);
	'<' or '>' =>
		return lexredir(ls, c);
	'\'' =>
		return lexquote(ls);
	* =>
		if(wordchr(c) == 0){
			ls.lastdol = 0;
			return (c, nil);
		}
		return lexword(ls, c);
	}
}

testlexinit(s: string): ref Lexstate
{
	return lexinit(s);
}

testlexnext(ls: ref Lexstate): (int, ref Tree)
{
	return lexnext(ls);
}

# --- pcmd.c: the tree-to-source pretty-printer -----------------------
#
# Sixth slice, brought forward ahead of code.c on purpose: this is
# what code.c's own fnstr() needs for four opcodes (Xasync/Xbackq/
# Xsubshell/Xpipe all hand their child command's SOURCE TEXT to
# exec.c, via fnstr()'s pfmt(s,"%t",t) call), and it's also
# simplemung()'s own long-deferred `t.str` field (see this file's
# earlier note on that, in the syn.y section below) - both blocked on
# the exact same real function, so it gets done once, here, rather
# than deferred twice.
#
# Purely a tree-to-string walk, no `runq`/Thread dependency at all -
# same "real, testable value semantics" shape as tree.c's own node
# constructors. Real pcmd() writes into an `Io` buffer via `pfmt`;
# Limbo has no need for that intermediate buffered-writer abstraction
# at all - string concatenation already builds the whole result
# directly, so this returns a `string` rather than writing to
# anything, and there is no Limbo counterpart to `Io`/`pfmt`/`pchr`/
# `pstr` here (this translation's own version of the same
# simplification already made for match()'s manual UTF-8 decoding:
# the intermediate C machinery existed only because C has no
# growable-string type, and Limbo already does).
#
# Real pcmd()'s own `pdeglob()` helper - print a word's string with
# each GLOB escape byte stripped, printing whatever follows it - is
# not a new function at all: it is glob.c's own `deglob()`, byte for
# byte (skip a GLOB, then copy the next rune, whether or not that rune
# was escaped). Reused directly rather than re-implemented.
#
# real rc's own global `nl` (`\n` normally, temporarily `;` inside
# fnstr() - "change to semicolon for bourne-proofing", per its own
# comment) is a real global there because pcmd() is a single global
# function with no per-call parameter for it. `nlchar` below is the
# same kind of module-global stand-in as `curlocal`/`iflast`, correct
# for the same reason: there is exactly one thing calling pcmd() at a
# time right now (no concurrent compilation), so a global is
# equivalent to threading it as a parameter, until that stops being
# true.
nlchar := '\n';

pcmd(t: ref Tree): string
{
	if(t == nil)
		return "";
	case t.ttype {
	'$' =>		return "$" + pcmd(t.child[0]);
	'"' =>		return "$\"" + pcmd(t.child[0]);
	'&' =>		return pcmd(t.child[0]) + "&";
	'^' =>		return pcmd(t.child[0]) + "^" + pcmd(t.child[1]);
	'`' =>		return "`" + pcmd(t.child[0]);
	Tandand =>	return pcmd(t.child[0]) + " && " + pcmd(t.child[1]);
	Targlist =>	return pcmd(t.child[0]) + " " + pcmd(t.child[1]);
	Tbang =>	return "! " + pcmd(t.child[0]);
	Tbrace =>	return "{" + pcmd(t.child[0]) + "}";
	Tcount =>	return "$#" + pcmd(t.child[0]);
	Tfn =>		return "fn " + pcmd(t.child[0]) + " " + pcmd(t.child[1]);
	Tif =>		return "if" + pcmd(t.child[0]) + pcmd(t.child[1]);
	Tnot =>		return "if not " + pcmd(t.child[0]);
	Toror =>	return pcmd(t.child[0]) + " || " + pcmd(t.child[1]);
	Tpcmd or Tparen =>
			return "(" + pcmd(t.child[0]) + ")";
	Tsub =>		return "$" + pcmd(t.child[0]) + "(" + pcmd(t.child[1]) + ")";
	Tsimple =>	return pcmd(t.child[0]);
	Tsubshell =>	return "@ " + pcmd(t.child[0]);
	Tswitch =>	return "switch " + pcmd(t.child[0]) + " " + pcmd(t.child[1]);
	Ttwiddle =>	return "~ " + pcmd(t.child[0]) + " " + pcmd(t.child[1]);
	Twhile =>	return "while " + pcmd(t.child[0]) + pcmd(t.child[1]);
	';' =>
		if(t.child[0] != nil){
			if(t.child[1] != nil)
				return pcmd(t.child[0]) + sys->sprint("%c", nlchar) +
					pcmd(t.child[1]);
			return pcmd(t.child[0]);
		}
		return pcmd(t.child[1]);
	Twords =>
		s := "";
		if(t.child[0] != nil)
			s = pcmd(t.child[0]) + " ";
		return s + pcmd(t.child[1]);
	Tfor =>
		s := "for(" + pcmd(t.child[0]);
		if(t.child[1] != nil)
			s += " in " + pcmd(t.child[1]);
		return s + ")" + pcmd(t.child[2]);
	Tword =>
		if(t.quoted)
			return "'" + strreplace(t.str, "'", "''") + "'";
		return deglob(t.str);
	Tdup =>
		s := sys->sprint(">[%d=", t.fd0);
		if(t.rtype == Dupfd)
			s += string t.fd1;
		return s + "]";
	Tpipefd or Tredir =>
		s := "";
		case t.rtype {
		Here =>
			s = "<<";
			if(t.fd0 != 0)
				s += sys->sprint("[%d]", t.fd0);
		Read =>
			s = "<";
			if(t.fd0 != 0)
				s += sys->sprint("[%d]", t.fd0);
		Append =>
			s = ">>";
			if(t.fd0 != 1)
				s += sys->sprint("[%d]", t.fd0);
		Write =>
			s = ">";
			if(t.fd0 != 1)
				s += sys->sprint("[%d]", t.fd0);
		}
		s += pcmd(t.child[0]);
		if(t.child[1] != nil)
			s += " " + pcmd(t.child[1]);
		return s;
	'=' =>
		s := pcmd(t.child[0]) + "=" + pcmd(t.child[1]);
		if(t.child[2] != nil)
			s += " " + pcmd(t.child[2]);
		return s;
	Tpipe =>
		s := pcmd(t.child[0]) + "|";
		if(t.fd1 == 0){
			if(t.fd0 != 1)
				s += sys->sprint("[%d]", t.fd0);
		}else
			s += sys->sprint("[%d=%d]", t.fd0, t.fd1);
		return s + pcmd(t.child[1]);
	}
	return sys->sprint("bad %d", t.ttype);
}

strreplace(s: string, pat: string, rep: string): string
{
	r := "";
	i := 0;
	n := len s;
	fl := len pat;
	while(i < n){
		if(fl > 0 && i+fl <= n && s[i:i+fl] == pat){
			r += rep;
			i += fl;
		}else{
			r += s[i:i+1];
			i++;
		}
	}
	return r;
}

# fnstr(): pcmd() with the statement separator forced to `;` instead
# of `\n` ("bourne-proofing" a multi-line compound command down to one
# line of source text, e.g. for a job-control display or - the reason
# code.c needs this at all - the text handed to Xasync/Xbackq/
# Xsubshell/Xpipe as what exec.c actually runs).
fnstr(t: ref Tree): string
{
	save := nlchar;
	nlchar = ';';
	s := pcmd(t);
	nlchar = save;
	return s;
}

testpcmd(t: ref Tree): string
{
	return pcmd(t);
}

testfnstr(t: ref Tree): string
{
	return fnstr(t);
}

# combined parse+print seams - real rc never runs pcmd() on anything
# except a tree the grammar itself produced, so a round trip through
# THIS translation's own parser is the natural way to test it, rather
# than hand-building trees for every case.
testparseprint(s: string): string
{
	pinit(s);
	return pcmd(parsecmd());
}

testparseprintfn(s: string): string
{
	pinit(s);
	return fnstr(parsecmd());
}

# --- syn.y: the grammar, hand-written recursive descent -------------
#
# Fifth slice. Real rc's grammar is yacc, generating an LALR table
# from syn.y's `%left`/`%right` priority declarations; this is a
# hand-written recursive-descent parser instead, following
# p9/cmd/hoc.b's own precedent for a yacc-based real source (curtok/
# padvance as module globals, not threaded parameters - matching
# hoc.b's curtok/advance() convention, a deliberate departure from
# this file's own lexer section, which threads Lexstate explicitly;
# the grammar layer is new machinery replacing yacc, not more of the
# lexer, so it gets its own convention rather than force-fitting one).
#
# The priority table is NOT a precedence-climbing chain the way
# hoc.b's arithmetic operators are - most of it exists to resolve
# yacc shift/reduce conflicts in an ambiguous grammar, not to encode a
# clean operator hierarchy. Two lines are real precedence and become
# the loop-based chain below:
#
#	%left ANDAND OROR	(loosest of the two real levels)
#	%left PIPE		(tighter)
#
# `%left BANG SUBSHELL` and the two explicit `%prec BANG` annotations
# on `redir cmd` and `assign cmd` are NOT "these bind like `!`" - they
# put all four prefix forms (`!`, `@`, a leading redirection, a
# leading assignment) at one shared precedence level that sits between
# the two real ones: tighter than ANDAND/OROR, looser than PIPE. That
# was checked by hand against two concrete cases before any code was
# written, not assumed:
#
#   `!a && b`  - BANG's rule precedence (its own level, since no
#   %prec override) is LOWER than ANDAND's, so on seeing ANDAND next
#   yacc reduces `!a` first, then joins: `(!a) && b`. So the operand
#   of BANG/SUBSHELL/a prefix redir/a prefix assign must NOT extend
#   through ANDAND/OROR - it's parsed at the pipe level, not the
#   looser top level.
#
#   `>f a | b`  - the prefix redir's rule precedence (%prec BANG) is
#   LOWER than PIPE's, so on seeing PIPE next yacc shifts, extending
#   the redirection's operand through the whole pipeline: `>f (a|b)`,
#   not `(>f a) | b`. So that same operand DOES extend through PIPE -
#   it has to be parsed by the level that itself loops on PIPE, not a
#   bare atom.
#
# Both facts together mean: BANG/SUBSHELL/prefix-redir/prefix-assign
# all recurse into parsePipend() (the PIPE-looping level) for their
# operand, never into parseCmd() (the ANDAND/OROR-looping top level).
# IF/WHILE/FOR/SWITCH sit at the OTHER extreme on purpose - their own
# rule precedence is the LOWEST of anything in the table (lower than
# ANDAND/OROR too), so their body always shift-extends through
# everything: `if(x) a && b` is `if(x) (a&&b)`, not `(if(x) a) && b`.
# Their bodies are parsed via the full parseCmd(), not parsePipend().
#
# `word: keyword {$1->type=WORD;}` vs `first: comword` (no keyword
# alternative) is the other real trap: a bare keyword can start a
# command (`if`, `while`, ...) but can NEVER be the command's own NAME
# - `echo if` must treat `if` as a plain argument word, and a keyword
# reaching the position where `first` is expected (i.e. every keyword
# case in parseCmdUnit() below has already claimed it) is structurally
# unreachable, not separately guarded. parseWordAtom() below is the
# shared "an atom that may be a demoted keyword" step used by every
# word position AFTER the first one; parseFirst() calls parseComword()
# directly for its own first atom, which has no keyword case at all.
#
# One grammar action this slice's tests exercise is only partially
# real, explicitly noted where it's defined below: `heredoc()` returns a
# clearly-marked placeholder WORD token in the real tag's place - the
# real one opens a temp file that exec.c later fills with the heredoc
# BODY (source lines read up to a line matching the tag), which needs
# a source-reading front end this translation doesn't have yet (no
# Thread, no interactive/file reader). Both let `<<TAG`/braces/parens/
# simple commands parse into the right SHAPE now; neither can actually
# run anything yet, same as everything else in this file.
#
# treeshape() is a test-only structural dump (`(TYPENAME child...)`),
# not real rc's own `%t` pretty-printer (which reproduces rc source
# text) - it exists purely so parser tests can compare a whole tree in
# one string instead of walking .child/.ttype/.str by hand the way
# earlier slices had to.

parls:	ref Lexstate;
curtok:	int;
curtree: ref Tree;

pinit(s: string)
{
	parls = lexinit(s);
	padvance();
}

padvance()
{
	(curtok, curtree) = lexnext(parls);
}

expect(tok: int): int
{
	if(curtok != tok)
		return 0;
	padvance();
	return 1;
}

# real skipnl() operates directly on the raw Lexstate, correct for
# every OTHER caller in this file (lexnext's own `&&`/`||`/pipe cases
# all call it before ever fetching a lookahead token). It is NOT
# correct here: by the time a grammar mid-rule reaches `{skipnl();}`,
# this parser has already padvance()'d one token past the preceding
# `)` - unlike yacc, which (for a definite reduce like `paren: '('
# body ')'') doesn't fetch a lookahead token for `cmd` until AFTER the
# mid-rule action runs. Calling the raw skipnl(parls) here would skip
# characters from underneath an already-fetched curtok, leaving curtok
# stuck on a stale `'\n'` while the underlying stream moved on past it
# - found by a multi-line `if(a)\n\tb` test that silently parsed `b`
# right out of the tree. This is the token-level equivalent instead:
# real rc's own skipnl() loop (skip whitespace/comments, stop at
# anything but a newline, otherwise consume it and repeat) already
# happens naturally here because each padvance() re-runs lexnext()'s
# own skipwhite() before deciding the next token.
pskipnl()
{
	while(curtok == '\n')
		padvance();
}

iskeywordtok(t: int): int
{
	return t >= Tfor && t <= Tfn;
}

startsword(t: int): int
{
	if(t == Tword || t == '$' || t == '"' || t == Tcount ||
	   t == '`' || t == '(')
		return 1;
	return iskeywordtok(t);
}

# comword: the atomic word-forming constructs - never a bare keyword
# (that's `word`'s/`parseWordAtom`'s job, one layer up).
parsecomword(): ref Tree
{
	case curtok {
	'$' =>
		padvance();
		w := parseword();
		if(curtok == Tsub){
			padvance();
			wl := parsewords();
			if(expect(')') == 0)
				return nil;
			return tree2(Tsub, w, wl);
		}
		return tree1('$', w);
	'"' =>
		padvance();
		return tree1('"', parseword());
	Tcount =>
		padvance();
		return tree1(Tcount, parseword());
	Tword =>
		t := curtree;
		padvance();
		return t;
	'`' =>
		padvance();
		return tree1('`', parsebrace());
	'(' =>
		padvance();
		wl := parsewords();
		if(expect(')') == 0)
			return nil;
		return tree1(Tparen, wl);
	}
	return nil;	# not a comword - caller's mistake, matches the
			# lexer's own "no valid token" -> nil convention
}

# the shared "atom that may be a demoted keyword" step - used for
# every word position except the very first of a simple command.
parsewordatom(): ref Tree
{
	if(iskeywordtok(curtok)){
		t := curtree;
		padvance();
		t.ttype = Tword;	# `word: keyword {$1->type=WORD;}`
		return t;
	}
	return parsecomword();
}

# word: keyword|comword, then a left-associative `^` chain - one loop
# handles the whole chain (matching `%left '^'`), not recursion, the
# same shape as this file's other left-associative chains below.
parseword(): ref Tree
{
	t := parsewordatom();
	while(curtok == '^'){
		padvance();
		t = tree2('^', t, parsewordatom());
	}
	return t;
}

# first: comword, then the same `^` chain - but the FIRST atom can
# never be a bare keyword (see header comment).
parsefirst(): ref Tree
{
	t := parsecomword();
	while(curtok == '^'){
		padvance();
		t = tree2('^', t, parsewordatom());
	}
	return t;
}

# words: zero or more words, left-folded (`words: |words word
# {tree2(WORDS,$1,$2)}` - empty list is a nil tree, matching $$=0).
parsewords(): ref Tree
{
	t: ref Tree = nil;
	while(startsword(curtok))
		t = tree2(Twords, t, parseword());
	return t;
}

# redir: REDIR word | DUP - a DUP-typed redir (`>[2=1]`) is complete
# in the token itself, no trailing word.
parseredir(): ref Tree
{
	t := curtree;
	if(curtok == Tredir){
		padvance();
		w := parseword();
		if(t.rtype == Here)
			w = heredoc(w);
		return mung1(t, w);
	}
	padvance();	# Tdup
	return t;
}

# epilog: | redir epilog {mung2($1, $1->child[0], $2)} - builds the
# forward chain epimung() later walks to its tail.
parseepilog(): ref Tree
{
	if(curtok != Tredir && curtok != Tdup)
		return nil;
	r := parseredir();
	rest := parseepilog();
	return mung2(r, r.child[0], rest);
}

# heredoc: deferred (see header comment) - returns a clearly-marked
# placeholder in the tag's own real return shape (token(name, WORD)),
# not a crash and not silently wrong-but-plausible.
heredoc(tag: ref Tree): ref Tree
{
	if(tag.ttype != Tword)
		return nil;	# real yyerror("Bad here tag") - no Thread
				# to unwind through yet, so: no valid tree
	return token("#here-unimplemented:"+tag.str+"#", Tword);
}

# simplemung: now fully real, including t.str, once pcmd() (above)
# existed to compute it - builds the SIMPLE node, sets its display
# string from the ARGLIST-with-trailing-redirs shape exactly as it
# was before percolation (matching real simplemung()'s own order:
# t->str is set right after wrapping in SIMPLE, before the
# percolation loop below reassigns `t` to a DUP/REDIR node that
# absorbed it), then does the real percolation of trailing DUP/REDIR
# nodes up to the new root, exactly as tree.c's own loop does.
simplemung(t: ref Tree): ref Tree
{
	t = tree1(Tsimple, t);
	t.str = pcmd(t);
	u := t.child[0];
	while(u != nil && u.ttype == Targlist){
		if(u.child[1] != nil &&
		   (u.child[1].ttype == Tdup || u.child[1].ttype == Tredir)){
			u.child[1].child[1] = t;
			t = u.child[1];
			u.child[1] = nil;
		}
		u = u.child[0];
	}
	return t;
}

# the atom/prefix level: everything that can start a `cmd`, including
# the four prefix forms whose operand is parsePipend() (not the
# looser parseCmd()) per the header comment's precedence trace.
parsecmdunit(): ref Tree
{
	case curtok {
	'{' =>
		b := parsebrace();
		e := parseepilog();
		return epimung(b, e);
	Tif =>
		iftok := curtree;
		padvance();
		if(curtok == Tnot){
			nottok := curtree;
			padvance();
			pskipnl();
			return mung1(nottok, parsepipend());
		}
		p := parseparen();
		pskipnl();
		return mung2(iftok, p, parsecmd());	# IF: lowest
							# precedence, grabs
							# the full cmd
	Twhile =>
		whiletok := curtree;
		padvance();
		p := parseparen();
		pskipnl();
		return mung2(whiletok, p, parsecmd());
	Tfor =>
		fortok := curtree;
		padvance();
		if(expect('(') == 0)
			return nil;
		w := parseword();
		if(curtok == Tin){
			padvance();
			wl := parsewords();
			if(expect(')') == 0)
				return nil;
			pskipnl();
			return mung3(fortok, w, tree1(Tparen, wl), parsecmd());
		}
		if(expect(')') == 0)
			return nil;
		pskipnl();
		return mung3(fortok, w, nil, parsecmd());
	Tswitch =>
		padvance();
		w := parseword();
		pskipnl();
		return tree2(Tswitch, w, parsebrace());
	Ttwiddle =>
		twtok := curtree;
		padvance();
		w := parseword();
		return mung2(twtok, w, parsewords());
	Tbang =>
		bt := curtree;
		padvance();
		return mung1(bt, parsepipend());
	Tsubshell =>
		st := curtree;
		padvance();
		return mung1(st, parsepipend());
	Tfn =>
		padvance();
		wl := parsewords();
		if(curtok == '{')
			return tree2(Tfn, wl, parsebrace());
		return tree1(Tfn, wl);
	Tredir or Tdup =>
		r := parseredir();
		return mung2(r, r.child[0], parsepipend());
	* =>
		if(startsword(curtok) == 0)
			return nil;	# cmd: {$$=0} - nothing here starts one
		f := parsefirst();
		if(curtok == '='){
			padvance();
			v := parseword();
			asgn := tree2('=', f, v);
			return mung3(asgn, asgn.child[0], asgn.child[1],
				     parsepipend());
		}
		# not an assignment - f is a simple command's own name;
		# `simple: first | simple word | simple redir`
		s := f;
		for(;;){
			if(startsword(curtok))
				s = tree2(Targlist, s, parseword());
			else if(curtok == Tredir || curtok == Tdup)
				s = tree2(Targlist, s, parseredir());
			else
				break;
		}
		return simplemung(s);
	}
	return nil;
}

# the PIPE level: `cmd PIPE cmd`, left-associative - also what a
# BANG/SUBSHELL/prefix-redir/prefix-assign's own operand is parsed by
# (see header comment).
parsepipend(): ref Tree
{
	l := parsecmdunit();
	while(curtok == Tpipe){
		pt := curtree;
		padvance();
		l = mung2(pt, l, parsecmdunit());
	}
	return l;
}

# the top level: `cmd ANDAND cmd | cmd OROR cmd`, one shared
# left-associative level (`%left ANDAND OROR` is a single line).
parsecmd(): ref Tree
{
	l := parsepipend();
	while(curtok == Tandand || curtok == Toror){
		op := curtok;
		padvance();
		l = tree2(op, l, parsepipend());
	}
	return l;
}

parseparen(): ref Tree
{
	if(expect('(') == 0)
		return nil;
	b := parsebody();
	if(expect(')') == 0)
		return nil;
	return tree1(Tparen, b);
}

parsebrace(): ref Tree
{
	if(expect('{') == 0)
		return nil;
	b := parsebody();
	if(expect('}') == 0)
		return nil;
	return tree1(Tbrace, b);
}

# body: used inside `{}`/`()` - unlike top-level `line`, a bare `\n`
# also continues it (`cmdsan: cmdsa | cmd '\n'`), matching real rc
# accepting unsemicoloned multi-line blocks inside braces.
parsebody(): ref Tree
{
	c := parsecmd();
	case curtok {
	';' =>
		padvance();
		return tree2(';', c, parsebody());
	'&' =>
		padvance();
		return tree2(';', tree1('&', c), parsebody());
	'\n' =>
		padvance();
		return tree2(';', c, parsebody());
	}
	return c;
}

# line: top-level only - a bare `\n` ends it (does NOT continue, per
# the outer `rc: line '\n'` rule consuming exactly one terminator);
# only `;`/`&` chain further commands onto the same line.
parseline(): ref Tree
{
	c := parsecmd();
	case curtok {
	';' =>
		padvance();
		return tree2(';', c, parseline());
	'&' =>
		padvance();
		return tree2(';', tree1('&', c), parseline());
	}
	return c;
}

toknamestr(t: int): string
{
	case t {
	';' =>		return ";";
	'&' =>		return "&";
	'=' =>		return "=";
	'^' =>		return "^";
	'$' =>		return "$";
	'"' =>		return "\"";
	'`' =>		return "`";
	Tword =>	return "WORD";
	Tredir =>	return "REDIR";
	Tdup =>		return "DUP";
	Tpipe =>	return "PIPE";
	Tcount =>	return "COUNT";
	Tsub =>		return "SUB";
	Tsimple =>	return "SIMPLE";
	Targlist =>	return "ARGLIST";
	Twords =>	return "WORDS";
	Tbrace =>	return "BRACE";
	Tparen =>	return "PAREN";
	Tandand =>	return "ANDAND";
	Toror =>	return "OROR";
	Tif =>		return "IF";
	Twhile =>	return "WHILE";
	Tfor =>		return "FOR";
	Tswitch =>	return "SWITCH";
	Ttwiddle =>	return "TWIDDLE";
	Tbang =>	return "BANG";
	Tsubshell =>	return "SUBSHELL";
	Tfn =>		return "FN";
	Tnot =>		return "NOT";
	}
	return sys->sprint("?%d", t);
}

# test-only structural dump - see header comment; not real rc's %t.
treeshape(t: ref Tree): string
{
	if(t == nil)
		return "nil";
	s := "(" + toknamestr(t.ttype);
	if(t.str != "")
		s += ":" + t.str;
	for(i := 0; i < len t.child; i++)
		if(t.child[i] != nil)
			s += " " + treeshape(t.child[i]);
	return s + ")";
}

testparseword(s: string): string
{
	pinit(s);
	return treeshape(parseword());
}

testparsewords(s: string): string
{
	pinit(s);
	return treeshape(parsewords());
}

testparsesimple(s: string): string
{
	pinit(s);
	return treeshape(parsecmdunit());
}

testparsecmd(s: string): string
{
	pinit(s);
	return treeshape(parsecmd());
}

testparsebody(s: string): string
{
	pinit(s);
	return treeshape(parsebody());
}

testparseline(s: string): string
{
	pinit(s);
	return treeshape(parseline());
}

testcurtok(): int
{
	return curtok;
}

# --- code.c: tree-to-instruction-vector compilation ------------------
#
# Seventh slice: outcode()/codeswitch()/iscase()/compile() - a pure
# tree walk emitting a linear instruction vector, still no runq/Thread
# dependency of its own beyond `iflast` (below), and still nothing
# that RUNS the vector - that's exec.c, not translated yet. Stops
# exactly at `compile()`, per the same boundary real code.c itself
# draws: `codecopy()`/`codefree()` are reference-counting and
# bulk-free bookkeeping for the compiled vector, the same "no
# counterpart under a real garbage collector" category as tree.c's own
# `Treenodes`/`freenodes`, already documented once in this file -
# not translated for the same reason, not re-noted at each omission.
# `cleanhere()` (emits `Xdelhere`) is deferred along with `heredoc()`,
# for the reason already given where `heredoc()` is defined. Real
# `compile()`'s own `readhere()` call is already commented out in the
# real source itself (`/* readhere(); */`) - that's upstream's own
# state, not something dropped in translation.
#
# Real `Code` is a C union (`void(*f)(void)`, `int i`, `char *s`) with
# no tag of its own - the real `emitf`/`emiti`/`emits` macros just
# write whichever field a given instruction's own fixed layout calls
# for, and the reader (exec.c, not translated yet) knows which fields
# to expect at which offset from the opcode alone, the same contract
# `outcode()` and `pfnc()` already share in the real source. `Codecell`
# below keeps all three fields on every cell instead of a union
# (Limbo has no untagged union), which costs a little memory and
# changes nothing about how any cell is actually used.
#
# `stuffdot()` (patching a forward jump target into an ALREADY-EMITTED
# cell, once the jump's real destination is known) needs random-access
# mutation of a specific earlier slot - a `list of Codecell` cannot do
# that, so `codebuf` is a real growable ARRAY plus a fill pointer
# (`codep`), grown in chunks the way real `morecode()` grows its own
# `realloc`, not a list. The real `emitf`/`emiti`/`emits` macros are
# also C's pre-increment idiom in disguise: `p=emiti(0)` captures the
# INDEX just written, for a later `stuffdot(p, ...)` to patch - so
# `emitop`/`emitint`/`emitstr` below all return the index they wrote,
# not the new fill pointer, on purpose (an off-by-one here would
# silently corrupt every jump target while still looking like a
# plausible address in a codeshape() dump - the two cheapest tests
# that would catch it, `if(a) b` and `while(a) b`, both patch exactly
# one forward jump and are in this slice's own test set).
#
# `runq->iflast` (real `outcode()` reads AND writes it, and `case NOT`
# raises a real error - "'if not' does not follow 'if(...)'" - if it
# isn't set) is real per-thread parse-time state, the same category as
# `curlocal`/`nlchar` before it: a module-global `iflast` stands in for
# it, correct for exactly the same reason those two already are -
# there is only one thing compiling at a time right now.
# real rc has no numeric opcode values at all - every `X...` is a
# distinct C function's own address, so a null function pointer can
# never collide with a real one. This translation's opcodes ARE plain
# ints (same internal-consistency-only convention as the token
# constants), so 0 is deliberately left unused by any real opcode
# here - the whole chain starts at `Xbase`+1, not +0 - specifically so
# compile()'s own trailing null-sentinel cell (0) can never be
# mistaken for a real instruction by codeshape() or anything reading
# this vector later. A first version put `Xmark` in its own separate
# `con 1` statement and started this list's `iota` fresh at 0 -
# meaning `Xappend` (this list's own first name) silently became
# `Xmark+0`, i.e. the SAME value as `Xmark` itself; the compiler
# caught it immediately as an overlapping case qualifier in opname()'s
# own switch, not a value collision either the compiler or a
# hand-check would otherwise have noticed. Fixed by putting `Xmark`
# back in the SAME iota chain as everything else, first in the list.
Xbase: con 0;
Xmark, Xappend, Xasync, Xbang, Xclose, Xdup, Xeflag, Xexit, Xfalse,
Xifnot, Xjump, Xpopm, Xread, Xreturn, Xtrue, Xif, Xwastrue, Xword,
Xwrite, Xmatch, Xcase, Xconc, Xassign, Xdol, Xcount, Xlocal, Xunlocal,
Xfn, Xdelfn, Xpipe, Xpipewait, Xrdcmds, Xbackq, Xpipefd, Xsubshell,
Xdelhere, Xfor, Xglob, Xsimple, Xqdol, Xpopredir, Xsettrue, Xsub:
	con Xbase+1+iota;

Codecell: adt
{
	op:	int;	# meaningful only on a cell an opcode was emitted
			# into - never inspected otherwise, same as the real
			# union's own reader-side contract
	ival:	int;
	sval:	string;
};

codebuf: array of ref Codecell;
codep: int;

iflast := 0;

growcode()
{
	nc := array[len codebuf + 100] of ref Codecell;
	for(i := 0; i < len codebuf; i++)
		nc[i] = codebuf[i];
	codebuf = nc;
}

emitop(op: int): int
{
	if(codep >= len codebuf)
		growcode();
	i := codep;
	codebuf[codep] = ref Codecell(op, 0, "");
	codep++;
	return i;
}

emitint(v: int): int
{
	if(codep >= len codebuf)
		growcode();
	i := codep;
	codebuf[codep] = ref Codecell(0, v, "");
	codep++;
	return i;
}

emitstr(v: string): int
{
	if(codep >= len codebuf)
		growcode();
	i := codep;
	codebuf[codep] = ref Codecell(0, 0, v);
	codep++;
	return i;
}

stuffdot(a: int)
{
	codebuf[a].ival = codep;
}

outcode(t: ref Tree, eflag: int)
{
	if(t == nil)
		return;
	if(t.ttype != Tnot && t.ttype != ';')
		iflast = 0;
	p, q: int;
	case t.ttype {
	'$' =>
		emitop(Xmark);
		outcode(t.child[0], eflag);
		emitop(Xdol);
	'"' =>
		emitop(Xmark);
		outcode(t.child[0], eflag);
		emitop(Xqdol);
	Tsub =>
		emitop(Xmark);
		outcode(t.child[0], eflag);
		emitop(Xmark);
		outcode(t.child[1], eflag);
		emitop(Xsub);
	'&' =>
		emitop(Xasync);
		emitstr(fnstr(t.child[0]));
	';' =>
		outcode(t.child[0], eflag);
		outcode(t.child[1], eflag);
	'^' =>
		emitop(Xmark);
		outcode(t.child[1], eflag);
		emitop(Xmark);
		outcode(t.child[0], eflag);
		emitop(Xconc);
	'`' =>
		emitop(Xbackq);
		emitstr(fnstr(t.child[0]));
	Tandand =>
		outcode(t.child[0], 0);
		emitop(Xtrue);
		p = emitint(0);
		outcode(t.child[1], eflag);
		stuffdot(p);
	Targlist =>
		outcode(t.child[1], eflag);
		outcode(t.child[0], eflag);
	Tbang =>
		outcode(t.child[0], eflag);
		emitop(Xbang);
	Tpcmd or Tbrace =>
		outcode(t.child[0], eflag);
	Tcount =>
		emitop(Xmark);
		outcode(t.child[0], eflag);
		emitop(Xcount);
	Tfn =>
		emitop(Xmark);
		outcode(t.child[0], eflag);
		if(t.child[1] != nil){
			emitop(Xfn);
			p = emitint(0);
			emitstr(fnstr(t.child[1]));
			outcode(t.child[1], eflag);
			emitop(Xunlocal);
			emitop(Xreturn);
			stuffdot(p);
		}else
			emitop(Xdelfn);
	Tif =>
		outcode(t.child[0], 0);
		emitop(Xif);
		p = emitint(0);
		outcode(t.child[1], eflag);
		emitop(Xwastrue);
		stuffdot(p);
	Tnot =>
		# real yyerror() prints and resyncs at the next newline -
		# there is no Thread/input stream to resync here yet, so
		# this just leaves the vector as-is past this point (the
		# same "no valid result" outcome a lex/parse error already
		# reaches elsewhere in this file) rather than raising
		# something with nothing to catch it.
		if(iflast)
			emitop(Xifnot);
		p = emitint(0);
		outcode(t.child[0], eflag);
		stuffdot(p);
	Toror =>
		outcode(t.child[0], 0);
		emitop(Xfalse);
		p = emitint(0);
		outcode(t.child[1], eflag);
		stuffdot(p);
	Tparen =>
		outcode(t.child[0], eflag);
	Tsimple =>
		emitop(Xmark);
		outcode(t.child[0], eflag);
		emitop(Xsimple);
		if(eflag)
			emitop(Xeflag);
	Tsubshell =>
		emitop(Xsubshell);
		emitstr(fnstr(t.child[0]));
		if(eflag)
			emitop(Xeflag);
	Tswitch =>
		codeswitch(t, eflag);
	Ttwiddle =>
		emitop(Xmark);
		outcode(t.child[1], eflag);
		emitop(Xmark);
		outcode(t.child[0], eflag);
		emitop(Xmatch);
		if(eflag)
			emitop(Xeflag);
	Twhile =>
		q = codep;
		emitop(Xsettrue);
		outcode(t.child[0], 0);
		emitop(Xtrue);
		p = emitint(0);
		outcode(t.child[1], eflag);
		emitop(Xjump);
		emitint(q);
		stuffdot(p);
	Twords =>
		outcode(t.child[1], eflag);
		outcode(t.child[0], eflag);
	Tfor =>
		emitop(Xmark);
		if(t.child[1] != nil){
			outcode(t.child[1], eflag);
			emitop(Xglob);
		}else{
			emitop(Xmark);
			emitop(Xword);
			emitstr("*");
			emitop(Xdol);
		}
		emitop(Xmark);		# dummy value for Xlocal
		emitop(Xmark);
		outcode(t.child[0], eflag);
		emitop(Xlocal);
		p = emitop(Xfor);
		q = emitint(0);
		outcode(t.child[2], eflag);
		emitop(Xjump);
		emitint(p);
		stuffdot(q);
		emitop(Xunlocal);
	Tword =>
		emitop(Xword);
		emitstr(t.str);
	Tdup =>
		if(t.rtype == Dupfd){
			emitop(Xdup);
			emitint(t.fd0);
			emitint(t.fd1);
		}else{
			emitop(Xclose);
			emitint(t.fd0);
		}
		outcode(t.child[1], eflag);
		emitop(Xpopredir);
	Tredir =>
		emitop(Xmark);
		outcode(t.child[0], eflag);
		emitop(Xglob);
		case t.rtype {
		Append =>
			emitop(Xappend);
		Write =>
			emitop(Xwrite);
		Read or Here =>
			emitop(Xread);
		}
		emitint(t.fd0);
		outcode(t.child[1], eflag);
		emitop(Xpopredir);
	'=' =>
		tt := t;
		u := t;
		while(u != nil && u.ttype == '=')
			u = u.child[2];
		if(u != nil){
			for(t = tt; t.ttype == '='; t = t.child[2]){
				emitop(Xmark);
				outcode(t.child[1], eflag);
				emitop(Xmark);
				outcode(t.child[0], eflag);
				emitop(Xlocal);
			}
			outcode(u, eflag);
			for(t = tt; t.ttype == '='; t = t.child[2])
				emitop(Xunlocal);
		}else{
			for(t = tt; t != nil; t = t.child[2]){
				emitop(Xmark);
				outcode(t.child[1], eflag);
				emitop(Xmark);
				outcode(t.child[0], eflag);
				emitop(Xassign);
			}
		}
		# `for(t=tt;...)` above walks the shared parameter `t` all
		# the way to nil (that's its own loop-exit condition) - real
		# code.c's own `t=tt;` reset right here, before its `break`,
		# exists for exactly this reason ("so tests below will work",
		# its own comment): without it, the epilogue just past this
		# whole case block dereferences whatever `t` was last left
		# pointing at, which - for a bare assignment with no trailing
		# command ("x=5") - is nil. Found by testcompile("x=5", 0)
		# crashing outright; restored to match the real source rather
		# than routing around it with a differently-named variable.
		t = tt;
	Tpipe =>
		emitop(Xpipe);
		emitint(t.fd0);
		emitint(t.fd1);
		emitstr(fnstr(t.child[0]));
		q = emitint(0);
		outcode(t.child[1], eflag);
		emitop(Xreturn);
		stuffdot(q);
		emitop(Xpipewait);
	}
	if(t.ttype != Tnot && t.ttype != ';')
		iflast = t.ttype == Tif;
	else if(t.child[0] != nil)
		iflast = t.child[0].ttype == Tif;
}

# switch code looks like this (real code.c's own comment, unchanged):
#	Xmark
#	(get switch value)
#	Xjump	1f
# out:	Xjump	leave
# 1:	Xmark
#	(get case values)
#	Xcase	1f
#	(commands)
#	Xjump	out
# 1:	Xmark
#	(get case values)
#	Xcase	1f
#	(commands)
#	Xjump	out
# 1:
# leave:
#	Xpopm
# Real code.c's own version of this function reuses ONE mutable `t`
# throughout, read through the `c0`/`c1` macros (`t->child[0]`/
# `t->child[1]`) - since those macros are re-evaluated fresh at every
# use, "c0" and "c1" mean something different every time `t` itself
# has been reassigned since the last use. A first translation attempt
# here mistranslated exactly that: it introduced separate `u`/`w`
# variables for the case-value walk instead of reusing the same
# walking pointer real `t`/`c0`/`c1` do, producing a walk that didn't
# match the real algorithm at all (found by hand-deriving the real
# trace for a concrete `switch(x){case a\nb}` and comparing against
# what this function actually emitted); and it computed `tt` from the
# ORIGINAL function parameter (`t.child[1]`, a constant, the BRACE
# node) rather than from `body.child[1]` (`c1` relative to whatever
# `body` - the real code's own `t` - currently pointed at). `body`
# below plays the exact role real `t` does for the rest of this
# function: the function's own parameter `t` is only ever read before
# `body` is introduced.
codeswitch(t: ref Tree, eflag: int)
{
	if(t.child[1].child[0].ttype != ';' ||
	   iscase(t.child[1].child[0].child[0]) == 0){
		# real yyerror("case missing in switch") - see the NOT
		# case's own comment on why this just stops instead.
		return;
	}
	emitop(Xmark);
	outcode(t.child[0], eflag);
	emitop(Xjump);
	nextcase := emitint(0);
	out := emitop(Xjump);
	leave := emitint(0);
	stuffdot(nextcase);
	body := t.child[1].child[0];
	while(body.ttype == ';'){
		tt := body.child[1];
		emitop(Xmark);
		x := body.child[0].child[0];
		while(x.ttype == Targlist){
			outcode(x.child[1], eflag);
			x = x.child[0];
		}
		emitop(Xcase);
		nextcase = emitint(0);
		body = tt;
		for(;;){
			if(body.ttype == ';'){
				if(iscase(body.child[0]))
					break;
				outcode(body.child[0], eflag);
				body = body.child[1];
			}else{
				outcode(body, eflag);
				break;
			}
		}
		emitop(Xjump);
		emitint(out);
		stuffdot(nextcase);
	}
	stuffdot(leave);
	emitop(Xpopm);
}

iscase(t: ref Tree): int
{
	if(t.ttype != Tsimple)
		return 0;
	u := t.child[0];
	while(u.ttype == Targlist)
		u = u.child[0];
	return u.ttype == Tword && u.quoted == 0 && u.str == "case";
}

# the trailing `emitf(0)` in real compile() is a null-function-pointer
# SENTINEL cell, not an operand of Xreturn (Xreturn itself is a plain
# 1-cell opcode, per opsize() above) - it's what real codefree()'s own
# `for(p=cp+1;p->f;)` loop stops at. `emitop(0)` here is that same
# sentinel, correctly distinguishable from every real opcode ONLY
# because Xmark's own chain starts at 1, not 0 (see that declaration's
# own comment) - opname(0) falls through to its numeric fallback
# rather than ever being mistaken for a real instruction.
compile(t: ref Tree, eflag: int): array of ref Codecell
{
	codebuf = array[100] of ref Codecell;
	codep = 0;
	outcode(t, eflag);
	emitop(Xreturn);
	emitop(0);
	return codebuf[0:codep];
}

opname(op: int): string
{
	case op {
	Xmark =>	return "Xmark";
	Xappend =>	return "Xappend";
	Xasync =>	return "Xasync";
	Xbang =>	return "Xbang";
	Xclose =>	return "Xclose";
	Xdup =>		return "Xdup";
	Xeflag =>	return "Xeflag";
	Xexit =>	return "Xexit";
	Xfalse =>	return "Xfalse";
	Xifnot =>	return "Xifnot";
	Xjump =>	return "Xjump";
	Xpopm =>	return "Xpopm";
	Xread =>	return "Xread";
	Xreturn =>	return "Xreturn";
	Xtrue =>	return "Xtrue";
	Xif =>		return "Xif";
	Xwastrue =>	return "Xwastrue";
	Xword =>	return "Xword";
	Xwrite =>	return "Xwrite";
	Xmatch =>	return "Xmatch";
	Xcase =>	return "Xcase";
	Xconc =>	return "Xconc";
	Xassign =>	return "Xassign";
	Xdol =>		return "Xdol";
	Xcount =>	return "Xcount";
	Xlocal =>	return "Xlocal";
	Xunlocal =>	return "Xunlocal";
	Xfn =>		return "Xfn";
	Xdelfn =>	return "Xdelfn";
	Xpipe =>	return "Xpipe";
	Xpipewait =>	return "Xpipewait";
	Xrdcmds =>	return "Xrdcmds";
	Xbackq =>	return "Xbackq";
	Xpipefd =>	return "Xpipefd";
	Xsubshell =>	return "Xsubshell";
	Xdelhere =>	return "Xdelhere";
	Xfor =>		return "Xfor";
	Xglob =>	return "Xglob";
	Xsimple =>	return "Xsimple";
	Xqdol =>	return "Xqdol";
	Xpopredir =>	return "Xpopredir";
	Xsettrue =>	return "Xsettrue";
	Xsub =>		return "Xsub";
	}
	return sys->sprint("?%d", op);
}

# how many cells - the opcode's own cell plus its fixed operand cells
# - a given instruction occupies, matching outcode()'s own real
# emission order exactly (cross-checked against, but derived
# independently of, real codefree()'s own per-opcode classification -
# see this file's header comment above codefree if that's ever ported:
# codefree() itself appears to be MISSING Xif from its own "2 cells"
# group, which this table does not reproduce, since nothing here
# walks the vector for freeing - only for display).
opsize(op: int): int
{
	case op {
	Xasync or Xbackq or Xtrue or Xif or Xifnot or Xfalse or Xword or
	Xclose or Xappend or Xwrite or Xread or Xjump or Xcase or
	Xdelhere =>
		return 2;
	Xfn or Xdup or Xpipefd =>
		return 3;
	Xpipe =>
		return 5;
	* =>
		return 1;
	}
}

# renders one instruction (starting at code[i]) as "i:Op(operands)",
# operands shown as whatever real outcode() actually put there (an
# int shown plain, a string shown quoted) - and returns how many
# cells it consumed, so codeshape() below can just keep asking for
# the next instruction rather than know any of this itself.
formatinstr(code: array of ref Codecell, i: int): (string, int)
{
	op := code[i].op;
	sz := opsize(op);
	name := opname(op);
	s: string;
	case op {
	Xasync or Xbackq or Xdelhere =>
		s = name + "(" + code[i+1].sval + ")";
	Xword =>
		s = name + "(" + code[i+1].sval + ")";
	Xtrue or Xif or Xifnot or Xfalse or Xclose or Xappend or Xwrite or
	Xread or Xjump or Xcase =>
		s = name + "(" + string code[i+1].ival + ")";
	Xfn =>
		s = name + "(" + string code[i+1].ival + "," +
			code[i+2].sval + ")";
	Xdup =>
		s = name + "(" + string code[i+1].ival + "," +
			string code[i+2].ival + ")";
	Xpipefd =>
		s = name + "(" + string code[i+1].ival + "," +
			string code[i+2].ival + ")";
	Xpipe =>
		s = name + "(" + string code[i+1].ival + "," +
			string code[i+2].ival + "," + code[i+3].sval + "," +
			string code[i+4].ival + ")";
	* =>
		s = name;
	}
	return (string i + ":" + s, sz);
}

# test-only dump of a compiled vector, the same role treeshape() plays
# for a parsed tree - not a real rc facility (real rc's own debug
# tracing, pfnc(), formats one instruction at a time as it EXECUTES,
# via exec.c's runq->pc; there is no execution here yet to drive that,
# so this instead renders the whole vector at once, directly from the
# array compile() returns). Jump-target operands are printed AFTER
# compile() has fully run, so a printed target already reflects
# whatever stuffdot() patched it to - this is what a backpatching bug
# (an off-by-one in emitint's own "return the index written, not the
# new fill pointer") would show up as: a plausible-looking but wrong
# address, not a crash.
codeshape(code: array of ref Codecell): string
{
	s := "";
	i := 0;
	while(i < len code){
		(instr, sz) := formatinstr(code, i);
		if(i > 0)
			s += " ";
		s += instr;
		i += sz;
	}
	return s;
}

testcompile(s: string, eflag: int): string
{
	pinit(s);
	return codeshape(compile(parsecmd(), eflag));
}

# loads sys too, not just the keyword/variable tables - lexword() and
# lexquote() need sys->sprint() to build a token one rune at a time
# (see this file's header comment on why %c is the right tool for
# that). Found the hard way: rctest.b calls bootstrap(), never init(),
# so sys stayed nil and the first %c call crashed the whole module
# with "module not loaded" until this was added here too.
bootstrap()
{
	sys = load Sys Sys->PATH;
	gvar = array[NVAR] of ref Var;
	initkw();
}

init(nil: ref Draw->Context, nil: list of string)
{
	bootstrap();
	print("rc: word-list/variable-table foundation only, no parser yet\n");
}
