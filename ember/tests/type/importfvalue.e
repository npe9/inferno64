module Importfvalue

import sys "sys"

// an *imported* module's function taken as a plain value ("g :=
// sys.print"), not just called directly -- previously a compile-time
// fatal ("ecom: unsupported mdot"), since echk's Odot case always
// returned a module member's *bare* Tfn (unlike a same-module Dfn
// read as a value, which stype()'s Otfunc/envfn() wraps in
// Tref{envfn(...)} via synthfvwrap()), and com.c's ecom() had no case
// for a bare Omdot used as anything other than callcom()'s own
// direct-call decomposition.
//
// mechanism: synthimportwrap() (check.c) is the Odot analogue of
// synthfvwrap() -- synthesizes (once, cached by name through the
// ordinary install()/lookup() symbol table, since the *shared*
// module-interface Decl readiface() hands back can't itself carry a
// per-importer wrapdecl the way a same-module Dfn does) a wrapper Dfn
// in *this* module whose body calls through "alias.fn", then
// rewrites the read into a plain Oname naming the wrapper -- the
// exact shape a same-module function value already is, so com.c's
// existing Oname/Dfn ecom() case (the tfnptr/ISELF construction)
// needed zero changes.
//
// Ocall's own callee-shape resolution gets a new fast path
// (modcallee()) so a literal direct call ("sys.print(...)") still
// compiles to a plain Omdot, unaffected -- without it, *every*
// ordinary "mod.fn(...)" call would pay the wrapper-synthesis cost,
// the same problem the pre-existing same-module "literal f(...)"
// fast path (Ocall, above) already solves for a bare name. the
// discrimination is the same one echk's own Odot case already uses
// to separate a module member from a struct field/bound method (a
// bound method's own receiver is never itself a Tmodule-typed
// Dglobal), so it can't regress method dispatch by construction, not
// just by reasoning about what receivers happen to exist -- proven
// below by exercising a direct module call, a value use, and a bound
// method call all in the same file.
//
// two known, pre-existing (not this feature's own) scope limits,
// found while testing this and deliberately not triggered below:
//
// (1) RESOLVED (see tests/type/varargvalue.e) for a same-module
// varargs function taken as a value: calling *through* a value now
// correctly compiles and executes a varargs call, any number of
// extra arguments, without corrupting the frame. still NOT possible,
// a real but separate and deeper limitation: a *specifically
// imported* varargs function like sys.print, called through a value,
// since every import-function-value goes through synthimportwrap()'s
// synthesized wrapper (this feature, above), and that wrapper's own
// inner call is built once, at wrapper-construction time, from a
// *fixed* parameter list with no way to relay whatever varargs its
// own caller passed it onward to the real sys.print -- see
// varargvalue.e's own header for the full mechanism and why this
// isn't specific to values at all (no ember/limbo *source* function,
// value or not, can introspect or forward its own received varargs;
// only a native C builtin like sys.print itself can). sys.sleep/
// sys.remove below are both non-varargs, unaffected either way.
//
// (2) a value-call whose own destination is itself forwarded (an
// existing local being read back, or an argument slot a prior
// statement's own temp already occupied) loses its result when
// called with a *literal constant* argument whose value is <= 0 --
// confirmed general and pre-existing (reproducible on the compiler
// *before* this feature existed, and via a hand-written same-module
// function whose own body bare-returns sys.sleep(period) taken as a
// value, using none of this feature's own code), and deterministic,
// not a timing-dependent race: with nothing preceding the value-call,
// a fresh frame's zero-fill makes the lost write look like a correct
// 0 (the trap that hid this at first); with an earlier statement's
// own temp having occupied the same frame slot first (an ordinary,
// otherwise-invisible compiler optimization), the failure becomes
// visible instead as that earlier statement's own leftover value.
//
// this file's own earlier revision attributed it to os/port/
// inferno.c's Sys_sleep conditionally skipping tsleep() for
// period<=0 -- WRONG, retracted: a *variable* holding the identical
// value (0, -1, -2, -100 all tried) never reproduces it, only a
// literal does, and the compiler has no visibility into what an
// opaque C builtin does at runtime to make that distinction --
// proving whatever Sys_sleep does internally isn't the actual cause,
// just a coincidental correlation (a literal argument's own value
// happening to also be what determines Sys_sleep's own tsleep-skip
// branch, for the specific case that was tested first). the real
// axis, confirmed by direct A/B comparison of the actual compiled
// frame layout for a literal-argument vs. variable-argument call
// (identical in both cases, ruling out a frame-offset collision):
// literal <= 0 -- broken; literal > 0 (1, 2, 3, 5 all tried) --
// works; *any* variable, any value -- works. root cause still NOT
// identified beyond this. every sys.sleep call through a value below
// uses a positive literal for exactly this reason. see the
// ember-language-status memory file for the full isolation,
// including this same correction.

type Rect struct {
	minx, miny, maxx, maxy int
}

func (r ref Rect) area() int {
	return (r.maxx - r.minx) * (r.maxy - r.miny)
}

func addone(n int) int {
	return n + 1
}

func init() {
	// a direct call, unaffected by any of this.
	sys.print("direct=%d\n", 1)

	// a bound method call -- the actual regression risk this whole
	// feature was parked over until modcallee()'s own discrimination
	// was found to already exist, structurally separate.
	r := ref Rect{minx: 0, miny: 0, maxx: 4, maxy: 3}
	sys.print("area=%d\n", r.area())

	// the new feature itself: an imported function taken as a value,
	// called back through it.
	s := sys.sleep
	sys.print("sleep=%d\n", s(1))

	// passed to a same-module function as an ordinary int result --
	// proves the value genuinely round-trips through an intervening
	// call, not just a direct call-through.
	sys.print("call=%d\n", addone(s(1)))

	// re-taken as a value a second time, in the same function: proves
	// synthimportwrap()'s own by-name caching hands back the *same*
	// wrapper rather than synthesizing (and fnchk()ing) a fresh one
	// every reference.
	t := sys.sleep
	sys.print("second=%d\n", t(2))

	// a *different* imported function taken as a value in the same
	// file, non-varargs, its own return value genuinely depending on
	// the argument (unlike sleep, which always returns 0 on success)
	// -- rules out any "reads back whatever's already zero" false
	// positive, and confirms this doesn't hit limitation (2) above
	// (sys.remove has no argument-conditional release()/tsleep()/
	// acquire() skip in its own C implementation).
	g := sys.remove
	sys.print("remove=%d\n", g("/definitely/does/not/exist/xyz123"))
}
