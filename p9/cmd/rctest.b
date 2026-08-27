implement Rctest;

# Regression test for p9/cmd/rc.b's first translated slice - word
# lists and the variable/keyword tables, per that file's own header
# comment on why this slice was chosen first (real, testable value
# semantics with no parser or execution engine needed yet).
#
# hash()'s expected values were computed independently in Python from
# the real algorithm in utils/rcsh/var.c (h=sum(s[i]*(i+1)) mod n,
# renormalized non-negative), not derived from this translation, so a
# transcription bug in rc.b's hash() would actually be caught here.
#
# conclist()'s expected result - conclist(["a","b"], ["x","y","z"])
# == ["ax","by","bz"] - is real rc's own documented `^` behavior for
# unequal-length lists (the shorter list's last word is reused for the
# longer list's remaining elements), traced by hand against the real
# recursive algorithm in utils/rcsh/word.c before being written down
# here, not assumed.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;

Rctest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

Rc: module
{
	PATH:		con "/p9/dis/rc.dis";
	init:		fn(ctxt: ref Context, argv: list of string);
	bootstrap:	fn();

	Tokbase: con 256;
	Tfor, Tin, Twhile, Tif, Tnot, Ttwiddle, Tbang, Tsubshell, Tswitch, Tfn,
	Tword, Tredir, Tdup, Tpipe, Tsub, Tsimple, Targlist, Twords, Tbrace,
	Tparen, Tpcmd, Tpipefd, Tandand, Toror, Tcount: con Tokbase+iota;

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
	testwordlist:	fn(words: list of string): ref Word;

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

Word: adt
{
	word:	string;
	next:	cyclic ref Word;
};

Var: adt
{
	name:		string;
	val:		ref Word;
	changed:	int;
	next:		cyclic ref Var;
};

Tree: adt
{
	ttype:	int;
	rtype:	int;
	fd0, fd1: int;
	str:	string;
	quoted:	int;
	iskw:	int;
	child:	array of ref Tree;
};

stderr: ref FD;
rc: Rc;
npass, nfail: int;

init(nil: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	rc = load Rc Rc->PATH;
	if(rc == nil){
		sys->fprint(stderr, "rctest: cannot load %s: %r\n", Rc->PATH);
		raise "fail:bad module";
	}
	rc->bootstrap();

	# rctest.b hand-copies rc.b's entire token-constant iota chain (see
	# both files' own comments on why). If the two lists ever drift -
	# a name inserted or removed at either end - every constant after
	# the drift point silently shifts to a different value in rc.b's
	# REAL, compiled implementation, while rctest.b's own compile-time
	# copy of the same names stays whatever it was last edited to.
	# A bare `Rc->Tcount - Rc->Tfor` comparison here CANNOT catch that:
	# module-interface `con`s are resolved at compile time from each
	# file's own declaration, never fetched from the loaded module at
	# runtime, so such a comparison only checks rctest.b's copy against
	# itself - confirmed directly during development, not assumed: a
	# deliberate drift introduced into rc.b left exactly that comparison
	# passing, while the real klook() tests below (which exercise
	# rc.b's actual runtime values) caught the same drift immediately.
	# testtokenspread() is real data, computed inside rc.dis at
	# runtime from rc.b's own actual constants - comparing THAT against
	# rctest.b's expectation is the only way this guard can mean
	# anything.
	#
	# One more thing confirmed, not assumed: testtokenspread() only
	# catches a drift that changes the RELATIVE spacing inside the
	# Tfor..Tcount chain (a name inserted or removed between them) - a
	# second negative control (a name inserted BEFORE the whole chain,
	# shifting every value uniformly) left testtokenspread() passing,
	# since Tcount-Tfor stays the same when both shift together.
	# klook()'s own tests below happen to catch that second case
	# instead, because they compare rc.b's real runtime values against
	# rctest.b's literal ABSOLUTE expectations (256, 266), not a
	# difference. Both drift patterns are covered, but by two different
	# mechanisms working together, not by this guard alone.
	checkint("token-constant lists haven't drifted between rc.b and "+
		"rctest.b (see comment above)", rc->testtokenspread(), 24);

	# --- hash(), independently computed, not derived from rc.b ---
	checkint("hash(\"path\", 521) == 28", rc->testhash("path", 521), 28);
	checkint("hash(\"for\", 30) == 6", rc->testhash("for", 30), 6);
	checkint("hash(\"if\", 30) == 9", rc->testhash("if", 30), 9);
	checkint("hash(\"banana\", 30) == 12", rc->testhash("banana", 30), 12);
	checkint("hash(\"\", 521) == 0 (empty name)", rc->testhash("", 521), 0);

	# --- word lists ---
	checkint("count(nil) == 0", rc->testcount(nil), 0);
	w := rc->testwordlist("a" :: "b" :: "c" :: nil);
	checkint("count([a,b,c]) == 3", rc->testcount(w), 3);

	checkstr("list2str([a,b,c]) == \"a b c\"", rc->testlist2str(w), "a b c");
	checkstr("list2str(nil) == \"\"", rc->testlist2str(nil), "");
	checkstr("list2str([solo]) == \"solo\"",
		rc->testlist2str(rc->testwordlist("solo" :: nil)), "solo");

	tail := rc->testwordlist("x" :: nil);
	cp := rc->testcopywords(w, tail);
	checkstr("copywords([a,b,c], [x]) == \"a b c x\"",
		rc->testlist2str(cp), "a b c x");
	checkstr("copywords leaves the original list untouched",
		rc->testlist2str(w), "a b c");

	lp := rc->testwordlist("a" :: "b" :: nil);
	rp := rc->testwordlist("x" :: "y" :: "z" :: nil);
	cl := rc->testconclist(lp, rp, nil);
	checkstr("conclist([a,b], [x,y,z]) == \"ax by bz\" (shorter list's "+
		"last word repeats)", rc->testlist2str(cl), "ax by bz");

	equallp := rc->testwordlist("p" :: "q" :: nil);
	equalrp := rc->testwordlist("1" :: "2" :: nil);
	checkstr("conclist([p,q], [1,2]) == \"p1 q2\" (equal lengths)",
		rc->testlist2str(rc->testconclist(equallp, equalrp, nil)),
		"p1 q2");

	# --- variables ---
	v1 := rc->testgvlook("myvar");
	checkptr("gvlook(\"myvar\") starts with val == nil", v1.val == nil);
	rc->testsetvar("myvar", rc->testwordlist("hello" :: "world" :: nil));
	v2 := rc->testvlook("myvar");
	checkstr("vlook(\"myvar\") sees the value setvar just stored",
		rc->testlist2str(v2.val), "hello world");
	checkint("setvar marks the variable changed", v2.changed, 1);
	v3 := rc->testgvlook("myvar");
	checkptr("gvlook(\"myvar\") returns the SAME Var, not a new one",
		v3 == v1);

	unset := rc->testgvlook("neverassigned");
	checkptr("an unset variable's val is nil", unset.val == nil);

	# --- keyword table ---
	checkint("iskeyword(\"for\") is non-zero", rc->testiskeyword("for") != 0, 1);
	checkint("iskeyword(\"if\") is non-zero", rc->testiskeyword("if") != 0, 1);
	checkint("iskeyword(\"fn\") is non-zero", rc->testiskeyword("fn") != 0, 1);
	checkint("iskeyword(\"~\") is non-zero", rc->testiskeyword("~") != 0, 1);
	checkint("iskeyword(\"notakeyword\") == 0",
		rc->testiskeyword("notakeyword"), 0);
	checkint("iskeyword(\"\") == 0", rc->testiskeyword(""), 0);
	checkint("\"for\" and \"if\" get different token values",
		rc->testiskeyword("for") != rc->testiskeyword("if"), 1);

	# --- deglob() ---
	checkstr("deglob(GLOB *) == \"*\" (unescape a literal asterisk)",
		rc->testdeglob("*"), "*");
	checkstr("deglob(plain) == plain (nothing to unescape)",
		rc->testdeglob("plain"), "plain");
	checkstr("deglob(GLOB GLOB) == GLOB (an escaped literal GLOB char)",
		rc->testdeglob(""), "");

	# --- haswild() ---
	checkint("haswild(plain) == 0", rc->testhaswild("plain"), 0);
	checkint("haswild(GLOB *) == 1 (a real wildcard)",
		rc->testhaswild("*"), 1);
	checkint("haswild(GLOB GLOB) == 0 (only an escaped literal, no "+
		"real wildcard)", rc->testhaswild(""), 0);
	checkint("haswild(a GLOB ? b) == 1", rc->testhaswild("a?b"), 1);

	# --- match() ---
	checkint("match(abc, abc, 0) == 1 (literal match)",
		rc->testmatch("abc", "abc", 0), 1);
	checkint("match(abc, abd, 0) == 0 (literal mismatch)",
		rc->testmatch("abc", "abd", 0), 0);
	checkint("match(abc, a GLOB * , 0) == 1 (* matches \"bc\")",
		rc->testmatch("abc", "a*", 0), 1);
	checkint("match(abc, GLOB *, 0) == 1 (* matches the whole string)",
		rc->testmatch("abc", "*", 0), 1);
	checkint("match(\"\", GLOB *, 0) == 1 (* matches empty)",
		rc->testmatch("", "*", 0), 1);
	checkint("match(abc, a GLOB ? c, 0) == 1 (? matches exactly one char)",
		rc->testmatch("abc", "a?c", 0), 1);
	checkint("match(ac, a GLOB ? c, 0) == 0 (? needs a char that isn't there)",
		rc->testmatch("ac", "a?c", 0), 0);
	checkint("match(abc, GLOB [a-c] bc, 0) == 1 (in-range bracket class)",
		rc->testmatch("abc", "[a-c]bc", 0), 1);
	checkint("match(dbc, GLOB [a-c] bc, 0) == 0 (out-of-range)",
		rc->testmatch("dbc", "[a-c]bc", 0), 0);
	checkint("match(abc, GLOB [~a-c] bc, 0) == 0 (negated, in-range so excluded)",
		rc->testmatch("abc", "[~a-c]bc", 0), 0);
	checkint("match(dbc, GLOB [~a-c] bc, 0) == 1 (negated, out-of-range so included)",
		rc->testmatch("dbc", "[~a-c]bc", 0), 1);
	checkint("match(dir, dir/file, '/') == 1 (stop truncates the pattern scan)",
		rc->testmatch("dir", "dir/file", '/'), 1);
	checkint("match(dirx, dir/file, '/') == 0 (extra char past the stop point)",
		rc->testmatch("dirx", "dir/file", '/'), 0);
	checkint("match(GLOB, GLOB GLOB, 0) == 1 (a literal GLOB byte matches itself)",
		rc->testmatch("", "", 0), 1);

	# --- matchfn() (the "." and ".." exclusion wrapper) ---
	checkint("matchfn(\".\", GLOB *) == 0 (dot excluded by a wildcard pattern)",
		rc->testmatchfn(".", "*"), 0);
	checkint("matchfn(\"..\", GLOB *) == 0 (dot-dot excluded too)",
		rc->testmatchfn("..", "*"), 0);
	checkint("matchfn(\".\", . GLOB *) == 1 (pattern itself starts with '.')",
		rc->testmatchfn(".", ".*"), 1);
	checkint("matchfn(foo, GLOB *) == 1 (non-dot name, ordinary match)",
		rc->testmatchfn("foo", "*"), 1);

	# --- subwords(): $var(n m ...) subscripting ---
	vals := rc->testwordlist("v1" :: "v2" :: "v3" :: "v4" :: "v5" :: nil);
	sub1 := rc->testwordlist("2" :: "4" :: nil);
	checkstr("subwords picks out elements 2 and 4, in that order",
		rc->testlist2str(rc->testsubwords(vals, 5, sub1, nil)), "v2 v4");
	sub2 := rc->testwordlist("0" :: "6" :: "3" :: nil);
	checkstr("subwords silently drops out-of-range subscripts (0 and 6)",
		rc->testlist2str(rc->testsubwords(vals, 5, sub2, nil)), "v3");
	checkptr("subwords(val, 5, nil, nil) == nil (no subscripts at all)",
		rc->testsubwords(vals, 5, nil, nil) == nil);

	# --- tree.c: node constructors ---
	nt := rc->testnewtree();
	checkint("newtree() zero-initializes ttype", nt.ttype, 0);
	checkstr("newtree() zero-initializes str", nt.str, "");
	checkptr("newtree() zero-initializes all 3 children",
		nt.child[0] == nil && nt.child[1] == nil && nt.child[2] == nil);

	leaf := rc->testtoken("hello", Rc->Tword);
	checkint("token() sets ttype", leaf.ttype, Rc->Tword);
	checkstr("token() sets str", leaf.str, "hello");

	t1 := rc->testtree1(Rc->Tbang, leaf);
	checkint("tree1() sets ttype", t1.ttype, Rc->Tbang);
	checkptr("tree1() sets child[0], leaves child[1]/[2] nil",
		t1.child[0] == leaf && t1.child[1] == nil && t1.child[2] == nil);

	c1 := rc->testtoken("a", Rc->Tword);
	c2 := rc->testtoken("b", Rc->Tword);
	t2 := rc->testtree2(Rc->Tandand, c1, c2);
	checkptr("tree2() sets child[0] and child[1]",
		t2.child[0] == c1 && t2.child[1] == c2 && t2.child[2] == nil);

	# real tree3()'s one real optimization: a ';' node with either
	# child nil returns the OTHER child directly instead of allocating
	# a new node - checked here because it's a semantic shortcut, not
	# just a constructor, and easy to lose in translation.
	checkptr("tree3(';', c1, nil, nil) == c1, no new node allocated",
		rc->testtree3(';', c1, nil, nil) == c1);
	checkptr("tree3(';', nil, c2, nil) == c2, no new node allocated",
		rc->testtree3(';', nil, c2, nil) == c2);
	seq := rc->testtree3(';', c1, c2, nil);
	checkptr("tree3(';', c1, c2, nil) with BOTH real allocates a new node",
		seq != c1 && seq != c2 && seq.child[0] == c1 && seq.child[1] == c2);

	m := rc->testtoken("m", Rc->Tredir);
	m = rc->testmung1(m, c1);
	checkptr("mung1() sets child[0] on the SAME node, doesn't allocate",
		m.child[0] == c1);
	m = rc->testmung2(m, c2, c1);
	checkptr("mung2() overwrites child[0] and sets child[1]",
		m.child[0] == c2 && m.child[1] == c1);
	c3 := rc->testtoken("c", Rc->Tword);
	m = rc->testmung3(m, c1, c2, c3);
	checkptr("mung3() sets all three children",
		m.child[0] == c1 && m.child[1] == c2 && m.child[2] == c3);

	# epimung: walk an epilog chain (linked via child[1]) to its tail
	# and attach comp there - built directly rather than via a real
	# parse, since the chain shape is all epimung actually looks at.
	r1 := rc->testtoken("r1", Rc->Tredir);
	r2 := rc->testtoken("r2", Rc->Tredir);
	r1 = rc->testmung1(r1, nil);	# r1.child[0] irrelevant to epimung
	comp := rc->testtoken("comp", Rc->Tsimple);
	# hand-link r1 -> r2 -> nil by reusing mung2 (child[1] is what
	# epimung follows; child[0] is untouched by this test).
	r1 = rc->testmung2(r1, nil, r2);
	result := rc->testepimung(comp, r1);
	checkptr("epimung() returns the chain's head unchanged", result == r1);
	checkptr("epimung() attaches comp at the tail (r2.child[1])",
		r2.child[1] == comp);
	checkptr("epimung(comp, nil) == comp (no epilog at all)",
		rc->testepimung(comp, nil) == comp);

	# --- klook(): the real keyword lookup, now returning a Tree ---
	forkw := rc->testklook("for");
	checkint("klook(\"for\") sets ttype to the real keyword's token",
		forkw.ttype, Rc->Tfor);
	checkint("klook(\"for\") sets iskw", forkw.iskw, 1);
	checkstr("klook(\"for\") keeps the original name in str",
		forkw.str, "for");
	notkw := rc->testklook("somevar");
	checkint("klook(\"somevar\") (not a keyword) leaves ttype as Tword",
		notkw.ttype, Rc->Tword);
	checkint("klook(\"somevar\") leaves iskw at 0", notkw.iskw, 0);

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail > 0)
		raise "fail:test failure";
}

checkint(desc: string, got: int, want: int)
{
	if(got == want){
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL: %s: got %d, want %d\n", desc, got, want);
}

checkstr(desc: string, got: string, want: string)
{
	if(got == want){
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL: %s: got %q, want %q\n", desc, got, want);
}

checkptr(desc: string, cond: int)
{
	if(cond){
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL: %s\n", desc);
}
