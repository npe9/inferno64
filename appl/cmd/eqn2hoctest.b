implement Command;

# eqn2hoctest(1) - translates a real eqn expression, then EVALUATES the
# result through hoc(2) and checks the actual NUMBER, not just that a
# translation was produced. A translation that compiles but computes
# the wrong thing is worse than one that refuses - this is the check
# that would catch that.

include "sys.m";
	sys: Sys;
include "draw.m";
include "eqn2hoc.m";
	eqn2hoc: Eqn2hoc;
include "hoc.m";
	hoc: Hoc;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

nfail := 0;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	eqn2hoc = load Eqn2hoc Eqn2hoc->PATH;
	hoc = load Hoc Hoc->PATH;
	if(eqn2hoc == nil || hoc == nil){
		sys->print("load: eqn2hoc=%d hoc=%d\n", eqn2hoc != nil, hoc != nil);
		raise "fail:load";
	}

	# --- real translations, checked by evaluating the result ---
	# x=3, y=4: pythagorean triple, checks sup (^) and plain +
	checkeval("x sup 2 + y sup 2",
		"x" :: "y" :: nil, 3.0 :: 4.0 :: nil,
		25.0, "x^2+y^2");
	# checks over (/)
	checkeval("a over b",
		"a" :: "b" :: nil, 6.0 :: 3.0 :: nil,
		2.0, "a/b");
	# checks sqrt, over (dividing a WHOLE braced numerator, not just
	# the sqrt term), unary minus, and + all together - the real
	# quadratic formula, one full root of x^2-3x+2=0 (roots 1 and 2;
	# the "+" branch gives (3+1)/2 = 2)
	checkeval("{- b + sqrt {b sup 2 - 4 a c}} over {2 a}",
		"a" :: "b" :: "c" :: nil, 1.0 :: -3.0 :: 2.0 :: nil,
		2.0, "quadratic formula, x=(-b+sqrt(b^2-4ac))/(2a), root of x^2-3x+2");
	# checks a known hoc builtin name applied as a real function call
	checkeval("sin { x }", "x" :: nil, 0.0 :: nil, 0.0, "sin(0)");
	checkeval("sqrt { x }", "x" :: nil, 16.0 :: nil, 4.0, "sqrt(16)");
	# checks left/right delimiters as plain grouping
	checkeval("left ( a + b right ) sup 2",
		"a" :: "b" :: nil, 1.0 :: 2.0 :: nil,
		9.0, "(a+b)^2");
	# checks braces as grouping, nested
	checkeval("{ a + b } over { c - d }",
		"a" :: "b" :: "c" :: "d" :: nil, 5.0 :: 3.0 :: 10.0 :: 6.0 :: nil,
		2.0, "(a+b)/(c-d)");
	# checks subscript name-folding: "x sub i" -> the hoc identifier x_i
	checkeval("x sub i + 1", "x_i" :: nil, 4.0 :: nil, 5.0,
		"x_i+1, subscript folded into one name");
	# checks a diacritical mark folded into a name: "x hat" -> xhat
	checkeval("x hat - 1", "xhat" :: nil, 10.0 :: nil, 9.0,
		"xhat-1, diacritical folded into one name");
	# checks combined sub then sup on the same box: (x_i)^2
	checkeval("x sub i sup 2", "x_i" :: nil, 5.0 :: nil, 25.0,
		"(x_i)^2 - sub then sup on the same name");

	# --- refusals: these must fail to translate, with a real error,
	# not silently produce something ---
	checkrefuse("sum from i=1 to n x sub i", "sum/from/to have no hoc target");
	checkrefuse("matrix { ccol { a above b } }", "hoc has no array type");
	checkrefuse("\"total cost\"", "quoted text has no hoc meaning");
	checkrefuse("x sub {i+1}", "subscript must be a simple name, not an expression");
	checkrefuse("over b", "'over' with nothing before it");

	# "x y" is NOT refused - bare juxtaposition is implicit
	# multiplication, the ordinary printed-math convention ("4 a c"
	# in the quadratic formula test above relies on the same rule).
	checkeval("4 a c", "a" :: "c" :: nil, 3.0 :: 5.0 :: nil, 60.0,
		"4 a c - implicit multiplication via juxtaposition");

	if(nfail == 0)
		sys->print("PASS\n");
	else{
		sys->print("%d test(s) failed\n", nfail);
		raise "fail:tests";
	}
}

checkeval(eq: string, names: list of string, vals: list of real, want: real, what: string)
{
	(hocsrc, err) := eqn2hoc->translate(eq);
	if(err != nil){
		sys->print("FAIL: translate(%q): %s\n", eq, err);
		nfail++;
		return;
	}
	hoc->reset();
	for(n := names; n != nil; (n, vals) = (tl n, tl vals))
		hoc->setvar(hd n, hd vals);
	e := hoc->compile(hocsrc);
	if(e == nil){
		sys->print("FAIL: hoc could not compile %q (from eqn %q)\n", hocsrc, eq);
		nfail++;
		return;
	}
	got := hoc->eval(e);
	diff := got - want;
	if(diff < 0.0)
		diff = -diff;
	if(diff > 1.0e-9){
		sys->print("FAIL: %q -> %q = %g, want %g [%s]\n",
			eq, hocsrc, got, want, what);
		nfail++;
		return;
	}
	sys->print("ok: %q -> %q = %g [%s]\n", eq, hocsrc, got, what);
}

checkrefuse(eq: string, why: string)
{
	(hocsrc, err) := eqn2hoc->translate(eq);
	if(err == nil){
		sys->print("FAIL: %q should have been refused (%s) but translated to %q\n",
			eq, why, hocsrc);
		nfail++;
		return;
	}
	sys->print("ok: %q correctly refused: %s\n", eq, err);
}
