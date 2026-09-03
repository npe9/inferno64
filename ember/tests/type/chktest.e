module Chktest

import sys "sys"

// "x?" -- pick-adt propagation. Mechanism (check.c's Ochk case, com.c's
// Ochk ecom() case): the user's own answered design fork -- the first
// tag in declaration order (Decl.tag == 0) is the success case,
// unwrapped as an ordinary expression value; any other tag makes "?"
// return the whole tagged value, unchanged, from the enclosing
// function. No limbo convention exists to port from (limbo has no ?
// operator at all). Subject must be a ref-to-tagged-adt (the only real
// value shape this can construct, per matchcheck()'s own precedent);
// the enclosing function's own declared return type must be exactly
// that same ref type, since a failing "?" returns the subject as-is.

type Result pick {
	Ok(val int)
	Err(msg string)
}

// a pointer-typed success payload (string, not int) -- the tdescmap()
// pointer-mp bug (a42b2046) hid behind an all-int tag; the ? payload
// read is a new, separate read site from that fix's own field-access
// and match-dispatch ones, so it gets its own dedicated check here
// rather than assuming the earlier fix covers every read site.
type Named pick {
	Ok(s string)
	Err(code int)
}

// a zero-field success tag: "?" only has control-flow to contribute,
// nothing to unwrap (n->ty == tnone).
type Status pick {
	Done()
	Failed(msg string)
}

// a struct with a ref-typed field, so "c.res?" exercises a subject
// that's already one indirection deep (sumark's Radr/Rmadr class) --
// the exact shape fpcall()'s own Radr/Rmadr gap (cb8dd160) was found
// through, checked here rather than assumed covered: com.c's Ochk
// case reaches this via ecom()'s own Oind case (fixdblind(), the
// o.in.v/f813f8c6 fix) on every use of the subject, not fpcall()'s
// separate direct addrmode-table lookup, so no extra widening turned
// out to be needed -- confirmed both empirically (instrumented
// subj->addable at runtime: Radr, exactly as predicted, ran and
// produced correct output 8x stable) and by reading why.
type C struct {
	res ref Result
}

func mk(which int) ref Result {
	if which == 0 {
		return ref Result.Ok{val: 99}
	}
	return ref Result.Err{msg: "oops"}
}

func mkname(which int) ref Named {
	if which == 0 {
		return ref Named.Ok{s: "hello"}
	}
	return ref Named.Err{code: 7}
}

func mkstatus(which int) ref Status {
	if which == 0 {
		return ref Status.Done{}
	}
	return ref Status.Failed{msg: "bad"}
}

// single-field success tag: "?" unwraps to the field's own value.
func addone(r ref Result) ref Result {
	v := r?
	return ref Result.Ok{val: v + 1}
}

// chained "?" across two calls -- the realistic use: propagate a
// failure up through more than one hop without ever touching it by
// hand.
func chain(which int) ref Result {
	r := mk(which)
	v := addone(r)?
	return ref Result.Ok{val: v}
}

// "?" used directly inside a further expression, not just := alone.
func plusten(which int) ref Result {
	v := mk(which)?
	return ref Result.Ok{val: v + 10}
}

// two "?" calls in sequence in one function -- the canonical use
// (propagate through several fallible steps in a row), exercised on
// both "the first one fails" and "the second one fails" separately,
// each emitting its own bcom/patch/IRET pair and its own retalloc().
func sum2(which1 int, which2 int) ref Result {
	x := mk(which1)?
	y := mk(which2)?
	return ref Result.Ok{val: x + y}
}

// "?" lexically inside an "if" body -- every case above puts it at
// function top level; this checks the IRET it emits still works
// correctly from inside a nested pushblock()/popblock() region.
func ifchk(which int, useit int) ref Result {
	if useit != 0 {
		v := mk(which)?
		return ref Result.Ok{val: v * 2}
	}
	return ref Result.Ok{val: -1}
}

// "?" lexically inside a "for" body -- an early return from inside a
// loop, not just an if.
func loopchk(n int) ref Result {
	total := 0
	i := 0
	for i < n {
		v := mk(i % 2)?
		total = total + v
		i = i + 1
	}
	return ref Result.Ok{val: total}
}

// pointer-typed (string) success payload: read it back and use it,
// not just pass it through, to actually exercise the value.
func shout(r ref Named) ref Named {
	s := r?
	return ref Named.Ok{s: s + "!"}
}

// zero-field success tag: nothing to unwrap, only control flow.
// "continued" must print exactly once per successful call, and never
// on a failing one -- the discriminating check that the early return
// really does fire, not just that this compiles.
func stepstatus(which int) ref Status {
	mkstatus(which)?
	sys.print("stepstatus continued\n")
	return ref Status.Done{}
}

// a struct field that's itself ref-typed: subj is one indirection
// deep before ? even starts (see the C/Named comments above).
func fieldchk(c ref C) ref Result {
	v := c.res?
	return ref Result.Ok{val: v + 1}
}

func init() {
	// success path: unwraps, keeps executing, returns a fresh Ok.
	a := addone(mk(0))
	match a {
	case Result.Ok(v):
		sys.print("addone ok v=%d\n", v)
	case Result.Err(e):
		sys.print("addone err e=%s\n", e)
	}

	// failure path: ? returns the whole Err value early -- addone's
	// own "return ref Result.Ok{val: v + 1}" line never runs.
	b := addone(mk(1))
	match b {
	case Result.Ok(v):
		sys.print("addone2 ok v=%d\n", v)
	case Result.Err(e):
		sys.print("addone2 err e=%s\n", e)
	}

	// chained ? across two function calls, both directions.
	c := chain(0)
	match c {
	case Result.Ok(v):
		sys.print("chain ok v=%d\n", v)
	case Result.Err(e):
		sys.print("chain err e=%s\n", e)
	}

	d := chain(1)
	match d {
	case Result.Ok(v):
		sys.print("chain2 ok v=%d\n", v)
	case Result.Err(e):
		sys.print("chain2 err e=%s\n", e)
	}

	// ? nested directly inside another expression, not bound to a
	// bare := first.
	e := plusten(0)
	match e {
	case Result.Ok(v):
		sys.print("plusten ok v=%d\n", v)
	case Result.Err(e2):
		sys.print("plusten err e=%s\n", e2)
	}

	f := plusten(1)
	match f {
	case Result.Ok(v):
		sys.print("plusten2 ok v=%d\n", v)
	case Result.Err(e2):
		sys.print("plusten2 err e=%s\n", e2)
	}

	// runtime-computed dispatch through ? in a loop, not just fixed
	// compile-time-obvious calls.
	i := 0
	for i < 3 {
		x := addone(mk(i % 2))
		match x {
		case Result.Ok(v):
			sys.print("loop ok %d\n", v)
		case Result.Err(e3):
			sys.print("loop err %s\n", e3)
		}
		i = i + 1
	}

	// two ? calls in sequence: first-fails and second-fails separately.
	h := sum2(0, 0)
	match h {
	case Result.Ok(v):
		sys.print("sum2 ok %d\n", v)
	case Result.Err(e5):
		sys.print("sum2 err %s\n", e5)
	}

	h2 := sum2(1, 0)
	match h2 {
	case Result.Ok(v):
		sys.print("sum2a ok %d\n", v)
	case Result.Err(e5):
		sys.print("sum2a err %s\n", e5)
	}

	h3 := sum2(0, 1)
	match h3 {
	case Result.Ok(v):
		sys.print("sum2b ok %d\n", v)
	case Result.Err(e5):
		sys.print("sum2b err %s\n", e5)
	}

	// ? inside if, both taken and not taken, both which values.
	j := ifchk(0, 1)
	match j {
	case Result.Ok(v):
		sys.print("ifchk ok %d\n", v)
	case Result.Err(e6):
		sys.print("ifchk err %s\n", e6)
	}

	j2 := ifchk(1, 1)
	match j2 {
	case Result.Ok(v):
		sys.print("ifchk2 ok %d\n", v)
	case Result.Err(e6):
		sys.print("ifchk2 err %s\n", e6)
	}

	j3 := ifchk(1, 0)
	match j3 {
	case Result.Ok(v):
		sys.print("ifchk3 ok %d\n", v)
	case Result.Err(e6):
		sys.print("ifchk3 err %s\n", e6)
	}

	// ? inside for: n=2 runs both iterations clean (0, then 1%2==1
	// would fail -- so use n that only hits which=0 first, then check
	// a failing case separately).
	k := loopchk(1)
	match k {
	case Result.Ok(v):
		sys.print("loopchk ok %d\n", v)
	case Result.Err(e7):
		sys.print("loopchk err %s\n", e7)
	}

	k2 := loopchk(2)
	match k2 {
	case Result.Ok(v):
		sys.print("loopchk2 ok %d\n", v)
	case Result.Err(e7):
		sys.print("loopchk2 err %s\n", e7)
	}

	// pointer-typed (string) success payload, both directions.
	m := shout(mkname(0))
	match m {
	case Named.Ok(s):
		sys.print("shout ok %s\n", s)
	case Named.Err(c):
		sys.print("shout err %d\n", c)
	}

	m2 := shout(mkname(1))
	match m2 {
	case Named.Ok(s):
		sys.print("shout2 ok %s\n", s)
	case Named.Err(c):
		sys.print("shout2 err %d\n", c)
	}

	// zero-field success tag -- "continued" must print exactly once
	// for the successful call and never for the failing one.
	p := stepstatus(0)
	match p {
	case Status.Done:
		sys.print("stepstatus done\n")
	case Status.Failed(msg):
		sys.print("stepstatus failed %s\n", msg)
	}

	p2 := stepstatus(1)
	match p2 {
	case Status.Done:
		sys.print("stepstatus2 done\n")
	case Status.Failed(msg):
		sys.print("stepstatus2 failed %s\n", msg)
	}

	// a struct field that's itself ref-typed, both directions.
	c3 := ref C{res: mk(0)}
	q := fieldchk(c3)
	match q {
	case Result.Ok(v):
		sys.print("fieldchk ok %d\n", v)
	case Result.Err(e8):
		sys.print("fieldchk err %s\n", e8)
	}

	c2 := ref C{res: mk(1)}
	q2 := fieldchk(c2)
	match q2 {
	case Result.Ok(v):
		sys.print("fieldchk2 ok %d\n", v)
	case Result.Err(e8):
		sys.print("fieldchk2 err %s\n", e8)
	}

	// a poisoned local right before more ? use, same methodology as
	// every other investigation this session.
	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
	g := addone(mk(0))
	match g {
	case Result.Ok(v):
		sys.print("final ok %d\n", v)
	case Result.Err(e4):
		sys.print("final err %s\n", e4)
	}
}
