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
	testlexinit:	fn(s: string): ref Lexstate;
	testlexnext:	fn(ls: ref Lexstate): (int, ref Tree);

	testparseword:	fn(s: string): string;
	testparsewords:	fn(s: string): string;
	testparsesimple:	fn(s: string): string;
	testparsecmd:	fn(s: string): string;
	testparsebody:	fn(s: string): string;
	testparseline:	fn(s: string): string;
	testcurtok:	fn(): int;
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

Lexstate: adt
{
	buf:		string;
	pos:		int;
	future:		int;
	peekc:		int;
	lastc:		int;
	lastdol:	int;
	lastword:	int;
	inquote:	int;
};

Eof: con -1;
Append: con 1;
Write: con 2;
Read: con 3;
Here: con 4;
Dupfd: con 5;
Close: con 6;

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

	# --- lex.c: the tokenizer ---
	checktokseq("lex: empty input is immediate Eof", "", Eof :: nil);
	checktokseq("lex: plain word", "hello", Rc->Tword :: nil);

	ls := rc->testlexinit("for");
	(lt1, tr1) := rc->testlexnext(ls);
	checkint("lex: \"for\" tokenizes as Tfor", lt1, Rc->Tfor);
	checkint("lex: \"for\" sets iskw", tr1.iskw, 1);

	ls = rc->testlexinit("format");
	(lt1, tr1) = rc->testlexnext(ls);
	checkint("lex: \"format\" is NOT mistaken for the \"for\" keyword "+
		"(exact match only)", lt1, Rc->Tword);
	checkint("lex: \"format\" leaves iskw at 0", tr1.iskw, 0);

	# skipwhite() only eats leading space/tab/cr and a comment's own
	# body text - NOT the newline that ends the comment line. That
	# newline becomes a real '\n' TOKEN (rc's own statement
	# separator, matching cmdsan's grammar rule), not silently
	# discarded whitespace the way it would be in a C-like language.
	# A first draft of this test wrongly assumed full skipping,
	# expected Tword directly, and got '\n' (10) instead - which then
	# crashed the very next assertion, since a bare single-character
	# token's Tree really is nil (yylval.tree is only ever set inside
	# the cases that build one), and that next line dereferenced it
	# unguarded. Both the wrong expectation and the missing nil guard
	# are fixed here, not just the visible test failure.
	ls = rc->testlexinit("  # a comment\n  hello");
	(lt1, nil) = rc->testlexnext(ls);
	checkint("lex: a comment's own newline is a real token, not "+
		"silently skipped whitespace", lt1, '\n');
	(lt1, tr1) = rc->testlexnext(ls);
	checkint("lex: the word after that newline tokenizes correctly",
		lt1, Rc->Tword);
	checkstr("lex: word text survives comment/whitespace skipping",
		tr1.str, "hello");

	ls = rc->testlexinit("'a b'");
	(lt1, tr1) = rc->testlexnext(ls);
	checkint("lex: quoted word tokenizes as Tword", lt1, Rc->Tword);
	checkstr("lex: quoted word preserves the embedded space",
		tr1.str, "a b");
	checkint("lex: quoted word sets quoted", tr1.quoted, 1);

	ls = rc->testlexinit("'it''s'");
	(lt1, tr1) = rc->testlexnext(ls);
	checkstr("lex: a doubled quote inside a quoted word is one "+
		"literal quote character", tr1.str, "it's");

	checktokseq("lex: &&", "&&", Rc->Tandand :: nil);
	checktokseq("lex: ||", "||", Rc->Toror :: nil);
	checktokseq("lex: & alone", "&", '&' :: nil);
	checktokseq("lex: $ alone", "$", '$' :: nil);
	checktokseq("lex: $#", "$#", Rc->Tcount :: nil);
	checktokseq("lex: $\" (dollar-quote)", "$\"", '"' :: nil);
	checktokseq("lex: ; alone", ";", ';' :: nil);
	checktokseq("lex: ( alone", "(", '(' :: nil);
	checktokseq("lex: x=5 tokenizes as WORD = WORD",
		"x=5", Rc->Tword :: '=' :: Rc->Tword :: nil);

	ls = rc->testlexinit(">");
	(lt1, tr1) = rc->testlexnext(ls);
	checkint("lex: > tokenizes as Tredir", lt1, Rc->Tredir);
	checkint("lex: > sets rtype Write", tr1.rtype, Write);
	checkint("lex: > sets fd0 1", tr1.fd0, 1);

	ls = rc->testlexinit(">>");
	(lt1, tr1) = rc->testlexnext(ls);
	checkint("lex: >> sets rtype Append", tr1.rtype, Append);

	ls = rc->testlexinit("<");
	(lt1, tr1) = rc->testlexnext(ls);
	checkint("lex: < sets rtype Read", tr1.rtype, Read);
	checkint("lex: < sets fd0 0", tr1.fd0, 0);

	ls = rc->testlexinit("<<");
	(lt1, tr1) = rc->testlexnext(ls);
	checkint("lex: << sets rtype Here", tr1.rtype, Here);

	ls = rc->testlexinit("|");
	(lt1, tr1) = rc->testlexnext(ls);
	checkint("lex: single | tokenizes as Tpipe", lt1, Rc->Tpipe);
	checkint("lex: | sets fd0 1", tr1.fd0, 1);
	checkint("lex: | sets fd1 0", tr1.fd1, 0);

	ls = rc->testlexinit(">[2]");
	(lt1, tr1) = rc->testlexnext(ls);
	checkint("lex: >[2] stays Tredir", lt1, Rc->Tredir);
	checkint("lex: >[2] overrides fd0 to 2", tr1.fd0, 2);
	checkint("lex: >[2] keeps rtype Write", tr1.rtype, Write);

	ls = rc->testlexinit(">[2=1]");
	(lt1, tr1) = rc->testlexnext(ls);
	checkint("lex: >[2=1] becomes Tdup", lt1, Rc->Tdup);
	checkint("lex: >[2=1] sets fd0 to 1 (the SECOND number)", tr1.fd0, 1);
	checkint("lex: >[2=1] sets fd1 to 2 (the FIRST number)", tr1.fd1, 2);
	checkint("lex: >[2=1] sets rtype Dupfd", tr1.rtype, Dupfd);

	ls = rc->testlexinit(">[2=]");
	(lt1, tr1) = rc->testlexnext(ls);
	checkint("lex: >[2=] becomes Tdup", lt1, Rc->Tdup);
	checkint("lex: >[2=] sets rtype Close", tr1.rtype, Close);
	checkint("lex: >[2=] keeps fd0 as 2", tr1.fd0, 2);

	ls = rc->testlexinit("|[2=1]");
	(lt1, tr1) = rc->testlexnext(ls);
	checkint("lex: |[2=1] stays Tpipe (only REDIR becomes DUP, not PIPE)",
		lt1, Rc->Tpipe);
	checkint("lex: |[2=1] sets rtype Dupfd", tr1.rtype, Dupfd);
	checkint("lex: |[2=1] sets fd0 to 1", tr1.fd0, 1);
	checkint("lex: |[2=1] sets fd1 to 2", tr1.fd1, 2);

	# A genuine finding in the REAL source, not a translation bug: the
	# check "can't dup a heredoc/append fd" (utils/rcsh/lex.c's own
	# `t->type==DUP && (t->rtype==HERE || t->rtype==APPEND)`) is
	# unreachable dead code there. Traced by hand against the real C
	# before writing this down: t->type only ever becomes DUP inside
	# the `if(c=='=')` block, and EVERY path through that block
	# unconditionally overwrites t->rtype to DUPFD or CLOSE first -
	# so by the time the HERE/APPEND check runs, rtype can never still
	# be HERE or APPEND. Real `rc` genuinely accepts `<<[2=1]` and
	# `>>[2=1]` without complaint (a real dup of a heredoc/append fd,
	# not a rejected one) - a first draft of this test wrongly assumed
	# the naive reading of the check's intent instead of tracing what
	# it actually does, and was corrected here instead of "fixing" the
	# translation to match a behavior the real source doesn't have.
	ls = rc->testlexinit("<<[2=1]");
	(lt1, tr1) = rc->testlexnext(ls);
	checkint("lex: <<[2=1] succeeds (the HERE/APPEND dup guard is dead "+
		"code in the real source - see comment above)", lt1, Rc->Tdup);
	checkint("lex: <<[2=1] sets rtype Dupfd (overwriting HERE, per the "+
		"real source's own logic)", tr1.rtype, Dupfd);
	ls = rc->testlexinit(">>[2=1]");
	(lt1, tr1) = rc->testlexnext(ls);
	checkint("lex: >>[2=1] succeeds for the same reason", lt1, Rc->Tdup);
	checkint("lex: >>[2=1] sets rtype Dupfd (overwriting APPEND)",
		tr1.rtype, Dupfd);
	ls = rc->testlexinit("|[2=]");
	(lt1, nil) = rc->testlexnext(ls);
	checkint("lex: |[2=] is a syntax error (a pipe fd can't be closed)",
		lt1, Eof);

	# the lastword-triggered `^` insertion and SUB detection - both
	# depend on exact adjacency (no intervening skipwhite), which is
	# why the lookahead for them happens BEFORE skipwhite is called.
	ls = rc->testlexinit("'a'b");
	(lt1, tr1) = rc->testlexnext(ls);
	checkint("lex: 'a'b first token is quoted Tword \"a\"", lt1, Rc->Tword);
	checkstr("lex: 'a'b first token text", tr1.str, "a");
	(lt2, nil) := rc->testlexnext(ls);
	checkint("lex: 'a'b second token is an inserted ^ (adjacency, no gap)",
		lt2, '^');
	(lt3, tr3) := rc->testlexnext(ls);
	checkint("lex: 'a'b third token is Tword \"b\"", lt3, Rc->Tword);
	checkstr("lex: 'a'b third token text", tr3.str, "b");

	ls = rc->testlexinit("x(1)");
	(lt1, nil) = rc->testlexnext(ls);
	checkint("lex: x(1) first token Tword \"x\"", lt1, Rc->Tword);
	(lt2, nil) = rc->testlexnext(ls);
	checkint("lex: x(1) second token Tsub (adjacent open paren)",
		lt2, Rc->Tsub);
	(lt3, tr3) = rc->testlexnext(ls);
	checkint("lex: x(1) third token Tword \"1\"", lt3, Rc->Tword);
	checkstr("lex: x(1) third token text", tr3.str, "1");
	(lt4, nil) := rc->testlexnext(ls);
	checkint("lex: x(1) fourth token literal )", lt4, ')');

	checktokseq("lex: x (1) - a space before ( suppresses SUB detection "+
		"(adjacency required)",
		"x (1)", Rc->Tword :: '(' :: Rc->Tword :: ')' :: nil);

	# --- syn.y: the grammar ------------------------------------------
	# treeshape() strings (see rc.b's own header comment) - a compact
	# structural dump, not real rc's %t pretty-printer.

	checkstr("parse: plain word", rc->testparseword("hello"),
		"(WORD:hello)");

	checkstr("parse: word: keyword demotes a bare keyword to WORD "+
		"(`word: keyword {$1->type=WORD;}')",
		rc->testparseword("if"), "(WORD:if)");

	checkstr("parse: word: left-associative ^ chain",
		rc->testparseword("a^b^c"),
		"(^ (^ (WORD:a) (WORD:b)) (WORD:c))");

	checkstr("parse: comword: $word", rc->testparseword("$x"),
		"($ (WORD:x))");

	checkstr("parse: comword: $word(sub words) - SUB via lexer "+
		"adjacency",
		rc->testparseword("$x(1 2)"),
		"(SUB (WORD:x) (WORDS (WORDS (WORD:1)) (WORD:2)))");

	checkstr("parse: comword: $\"word (dollar-quote prefix)",
		rc->testparseword("$\"x"), "(\" (WORD:x))");

	checkstr("parse: comword: $#word (COUNT)",
		rc->testparseword("$#x"), "(COUNT (WORD:x))");

	checkstr("parse: comword: `{brace} (backquote command substitution)",
		rc->testparseword("`{echo hi}"),
		"(` (BRACE (SIMPLE (ARGLIST (WORD:echo) (WORD:hi)))))");

	checkstr("parse: comword: (words) paren word-list",
		rc->testparseword("(a b)"),
		"(PAREN (WORDS (WORDS (WORD:a)) (WORD:b)))");

	checkstr("parse: comword: () empty paren word-list",
		rc->testparseword("()"), "(PAREN)");

	checkstr("parse: comword: unterminated ( is a parse error, not a "+
		"crash (same nil convention as a lex error)",
		rc->testparseword("("), "nil");

	checkstr("parse: comword: nested parens in a word-list",
		rc->testparseword("((a))"),
		"(PAREN (WORDS (PAREN (WORDS (WORD:a)))))");

	checkstr("parse: comword: a nested paren mixed with plain words",
		rc->testparseword("(a (b) c)"),
		"(PAREN (WORDS (WORDS (WORDS (WORD:a)) "+
		"(PAREN (WORDS (WORD:b)))) (WORD:c)))");

	checkstr("parse: simple command, one word",
		rc->testparsecmd("a"), "(SIMPLE (WORD:a))");

	checkstr("parse: simple command, multiple words",
		rc->testparsecmd("echo hi there"),
		"(SIMPLE (ARGLIST (ARGLIST (WORD:echo) (WORD:hi)) "+
		"(WORD:there)))");

	checkstr("parse: a keyword in argument position is a plain WORD, "+
		"not a nested construct (`echo if` must not misparse)",
		rc->testparsecmd("echo if"),
		"(SIMPLE (ARGLIST (WORD:echo) (WORD:if)))");

	checkstr("parse: simplemung percolates a trailing redirection up "+
		"to the tree's own root (real tree.c's own algorithm, not "+
		"just field-copying)",
		rc->testparsecmd("echo hi >f"),
		"(REDIR (WORD:f) (SIMPLE (ARGLIST (ARGLIST (WORD:echo) "+
		"(WORD:hi)))))");

	checkstr("parse: pipe chain is left-associative (`%left PIPE`)",
		rc->testparsecmd("a|b|c"),
		"(PIPE (PIPE (SIMPLE (WORD:a)) (SIMPLE (WORD:b))) "+
		"(SIMPLE (WORD:c)))");

	checkstr("parse: && and || share one left-associative level "+
		"(`%left ANDAND OROR` is a single line)",
		rc->testparsecmd("a&&b||c"),
		"(OROR (ANDAND (SIMPLE (WORD:a)) (SIMPLE (WORD:b))) "+
		"(SIMPLE (WORD:c)))");

	# The two cases traced by hand against syn.y's priority table
	# before any of this was written (see rc.b's header comment) -
	# BANG/SUBSHELL/a prefix redir/a prefix assign all sit at one
	# precedence level strictly between the two real ones (ANDAND/OROR
	# loosest, PIPE tightest): their own operand extends through PIPE
	# but stops at ANDAND/OROR.
	checkstr("parse: ! binds tighter than && - `! a && b` is `(!a) && b`"+
		", not `!(a && b)` (BANG's own rule precedence is LOWER "+
		"than ANDAND's, so yacc reduces `!a` before joining)",
		rc->testparsecmd("! a && b"),
		"(ANDAND (BANG:! (SIMPLE (WORD:a))) (SIMPLE (WORD:b)))");

	# `!` is deliberately absent from Wordstops in the real source
	# (utils/rcsh/lex.c's own wordchr() - checked directly), so with
	# no space it's not its own token at all: `!a` lexes as one plain
	# WORD "!a", the same way a following digit or letter joins any
	# other word character. Real rc genuinely requires the space -
	# `!cmd` is not the same as `! cmd`. Confirmed as a real property
	# of the upstream source, not a translation gap, by tracing
	# wordchr()'s own stop-character string.
	checkstr("parse: ! with no following space is not a token at all - "+
		"it joins the word (real wordchr()'s stop-set has no '!')",
		rc->testparsecmd("!a"), "(SIMPLE (WORD:!a))");

	checkstr("parse: a prefix redirection binds LOOSER than | - "+
		"`>f a | b` is `>f (a|b)`, not `(>f a) | b` (the prefix "+
		"redir's rule precedence, %prec BANG, is LOWER than PIPE's, "+
		"so yacc shifts through the whole pipeline)",
		rc->testparsecmd(">f a | b"),
		"(REDIR (WORD:f) (PIPE (SIMPLE (WORD:a)) (SIMPLE (WORD:b))))");

	checkstr("parse: @ (SUBSHELL) is a plain prefix, same precedence "+
		"level as ! - also needs the same space (same wordchr() "+
		"reason)",
		rc->testparsecmd("@ a && b"),
		"(ANDAND (SUBSHELL:@ (SIMPLE (WORD:a))) (SIMPLE (WORD:b)))");

	# testparsesimple() parses at the atom/prefix level directly
	# (parsecmdunit(), no PIPE or ANDAND/OROR loop above it) - the one
	# place that level's own boundary is directly observable: parsing
	# "a && b" through it must stop at "a", leaving && unconsumed,
	# rather than silently continuing (which is exactly what a wrong
	# level assignment for a prefix operand would look like from the
	# outside).
	checkstr("parse: testparsesimple() stops at the atom/prefix level "+
		"- it does not loop over && itself (that is parsecmd()'s "+
		"own job, one level up)",
		rc->testparsesimple("a && b"), "(SIMPLE (WORD:a))");
	checkint("parse: ...confirmed by the leftover && still unconsumed",
		rc->testcurtok(), Rc->Tandand);

	# heredoc() is deferred (see rc(1)'s DESCRIPTION/BUGS) - it checks
	# the here-tag is a real WORD token, exactly as real heredoc()'s
	# own `if(tag->type!=WORD) yyerror(...)` does, and returns nil
	# rather than a placeholder when it isn't. "<<$x" gives a `$x`
	# comword tag ('$'-typed, not WORD), so this exercises that path:
	# mung1(t, nil) leaves the REDIR node with no tag child at all,
	# not a crash and not a silently-wrong placeholder.
	checkstr("parse: heredoc() rejects a non-WORD tag the same way "+
		"real yyerror(\"Bad here tag\") does - nil, not a crash "+
		"or a wrong-but-plausible placeholder",
		rc->testparsecmd("<<$x"), "(REDIR)");

	checkstr("parse: assign-prefix builds `=` from `first`/`word`, "+
		"then attaches the rest of the command as a third child "+
		"(mung3, reusing the `=` node - real tree.c's own trick)",
		rc->testparsecmd("x=5 echo hi"),
		"(= (WORD:x) (WORD:5) (SIMPLE (ARGLIST (WORD:echo) "+
		"(WORD:hi))))");

	checkstr("parse: a bare assignment with nothing after it has an "+
		"empty (nil) trailing cmd - `cmd: {$$=0}`'s base case",
		rc->testparsecmd("x=5"),
		"(= (WORD:x) (WORD:5))");

	checkstr("parse: IF, single line",
		rc->testparsecmd("if(a) b"),
		"(IF:if (PAREN (SIMPLE (WORD:a))) (SIMPLE (WORD:b)))");

	# IF's own rule precedence is the LOWEST in the whole table -
	# lower even than ANDAND/OROR - specifically so its body always
	# shift-extends through everything: `if(x) a && b` is
	# `if(x) (a&&b)`, never `(if(x) a) && b`.
	checkstr("parse: IF's body binds looser than && (IF has the "+
		"lowest rule precedence in the table, so it always grabs "+
		"the full cmd)",
		rc->testparsecmd("if(x) a && b"),
		"(IF:if (PAREN (SIMPLE (WORD:x))) (ANDAND (SIMPLE (WORD:a)) "+
		"(SIMPLE (WORD:b))))");

	checkstr("parse: IF NOT (`if not cmd`, mung1 on the NOT token, "+
		"discarding IF itself)",
		rc->testparsecmd("if not a"),
		"(NOT:not (SIMPLE (WORD:a)))");

	checkstr("parse: WHILE, single line",
		rc->testparsecmd("while(a) b"),
		"(WHILE:while (PAREN (SIMPLE (WORD:a))) (SIMPLE (WORD:b)))");

	checkstr("parse: FOR with an explicit `in` word-list",
		rc->testparsecmd("for(x in a b) c"),
		"(FOR:for (WORD:x) (PAREN (WORDS (WORDS (WORD:a)) (WORD:b))) "+
		"(SIMPLE (WORD:c)))");

	checkstr("parse: FOR with no `in` (defaults to $*, left as a nil "+
		"middle child here - exec.c's job to fill in, not parse.c's)",
		rc->testparsecmd("for(x) c"),
		"(FOR:for (WORD:x) (SIMPLE (WORD:c)))");

	# `SWITCH word` takes a bare `word`, NOT a `paren` the way IF/WHILE
	# do (there is no dedicated "switch condition parens" rule in
	# syn.y at all) - so `switch(x)` with no space parses the SAME
	# generic comword `'(' words ')'` paren-word-list every other word
	# position uses (the same syntax `x=(a b c)` uses for an array
	# literal), giving a PAREN-wrapped one-word list here, not a
	# condition. Traced against syn.y directly after this test's first
	# draft (which assumed C-like switch(...) parens) failed.
	checkstr("parse: SWITCH takes a bare word - `switch(x)` with no "+
		"space is that word's own generic (words) paren-list form, "+
		"not a dedicated condition syntax (tree2 also discards the "+
		"SWITCH token itself, matching tree2(SWITCH,$2,$4))",
		rc->testparsecmd("switch(x) {a}"),
		"(SWITCH (PAREN (WORDS (WORD:x))) (BRACE (SIMPLE (WORD:a))))");

	checkstr("parse: TWIDDLE (`~ word words`, rc's own pattern-match "+
		"builtin - both operands are bare `word`/`words`, not `cmd`, "+
		"so neither gets wrapped in SIMPLE)",
		rc->testparsecmd("~ a b c"),
		"(TWIDDLE:~ (WORD:a) (WORDS (WORDS (WORD:b)) (WORD:c)))");

	checkstr("parse: FN with a brace body",
		rc->testparsecmd("fn f {a}"),
		"(FN (WORDS (WORD:f)) (BRACE (SIMPLE (WORD:a))))");

	checkstr("parse: FN with no body (a bare function reference)",
		rc->testparsecmd("fn f"),
		"(FN (WORDS (WORD:f)))");

	checkstr("parse: body (used inside {}/()) treats a bare newline "+
		"as a real separator, same as ; (`cmdsan: cmdsa|cmd '\\n'`)",
		rc->testparsebody("a\nb"),
		"(; (SIMPLE (WORD:a)) (SIMPLE (WORD:b)))");

	checkstr("parse: line (top level only) does NOT treat a bare "+
		"newline as a separator - only ; and & chain further "+
		"commands on the same line",
		rc->testparseline("a;b"),
		"(; (SIMPLE (WORD:a)) (SIMPLE (WORD:b)))");

	rc->testparseline("a\nb");
	checkint("parse: line stops BEFORE an unconsumed bare newline "+
		"(real rc's outer `rc: line '\\n'` rule consumes exactly "+
		"one terminator itself, line doesn't reach across it)",
		rc->testcurtok(), '\n');

	checkstr("parse: multi-line IF via skipnl() - `{skipnl();}` runs "+
		"after the paren, before the body, so a real newline there "+
		"is skipped just like real rc's own multi-line if(x)\\n\\tcmd",
		rc->testparsecmd("if(a)\n\tb"),
		"(IF:if (PAREN (SIMPLE (WORD:a))) (SIMPLE (WORD:b)))");

	checkstr("parse: & backgrounds a cmd within a body",
		rc->testparsebody("a& b"),
		"(; (& (SIMPLE (WORD:a))) (SIMPLE (WORD:b)))");

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

# tokenizes s from a fresh Lexstate and checks the resulting token
# TYPE sequence against want, stopping at the first disagreement or
# once want is exhausted (a real Eof reached before want runs out
# counts as disagreeing with whatever want expected there).
# Compares token TYPES only, deliberately - it never looks at the
# Tree lexnext also returns, so it never has to know which token
# classes carry one (a bare single-character token like ';' or '('
# legitimately returns a nil Tree; a test that read .str/.rtype off
# every result would need to special-case that, the way rc.b's
# comment-newline test discovered the hard way - see rc(1)'s BUGS).
checktokseq(desc: string, s: string, want: list of int)
{
	ls := rc->testlexinit(s);
	i := 0;
	for(w := want; w != nil; w = tl w){
		(got, nil) := rc->testlexnext(ls);
		if(got != hd w){
			nfail++;
			sys->fprint(stderr,
				"FAIL: %s: token %d: got %d, want %d\n",
				desc, i, got, hd w);
			return;
		}
		i++;
	}
	npass++;
}
