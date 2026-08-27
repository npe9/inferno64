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

# --- var.c: variables and the keyword table -------------------------

NVAR: con 521;	# real rc's own hash-table size, "big enough" not tuned
NKW: con 30;	# real rc's own keyword-table size

# token constants, matching real rc's yacc-generated ones in spirit
# (single-character tokens use their own rune value below 256, named
# tokens are allocated above it - the same scheme yacc itself uses) -
# not required to match rc's own numeric values, since nothing outside
# this translation ever sees them; only internal consistency matters.
Tokbase: con 256;
Tfor, Tin, Twhile, Tif, Tnot, Ttwiddle, Tbang, Tsubshell, Tswitch, Tfn: con Tokbase+iota;

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
