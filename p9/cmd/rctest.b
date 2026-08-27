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
