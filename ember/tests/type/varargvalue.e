module Varargvalue

import sys "sys"

// calling *through* a function value with varargs -- the design fork
// put to the user directly (chose "build the descriptor from the
// call site, not the callee" over leaving it unsupported or some
// other mechanism). callcom()'s own per-call-site frame descriptor
// used to be built via dupdecl(ind->decl), sound for a direct call
// (the callee is a specific, known Dfn) but structurally nonsensical
// for a value-call, where ind->decl is nil -- fpcall()'s own ind is a
// freshly built address-computation node, never a reference to any
// specific function. Previously this crashed outright (dupdecl(nil))
// for any varargs value-call.
//
// three real bugs found and fixed, in the order they had to be:
// 1. com.c's fpcall() unconditionally overwrote n->left->ty with
//    e->ty->tof (the value's own *generic*, non-per-call-site Tfn)
//    when building the Omdot it hands to callcom() -- discarding the
//    real, call-site-specific varargs Tfn check.c's own Ocall
//    handling had already built (real argument types, matching the
//    existing literal-varargs-call mechanism). fixed by capturing
//    n->left->ty *before* fpcall() replaces the node.
// 2. callcom()'s own dupdecl(ind->decl) crash on nil, for exactly
//    the reason above -- fixed by building a fresh, minimal Decl
//    (mkdecl()) carrying nothing but the descriptor instead, when
//    there's no real callee Decl to clone from. confirmed via
//    resolvepcs() (gen.c) that Adesc addressing reads *only* .desc
//    off this Decl -- nothing else about a "real" callee's Decl
//    (sym/store/offset/iface) is ever consulted for it, so a minimal
//    synthetic one is exactly as correct as dupdecl()-ing a real one
//    would have been.
// 3. check.c's own varargs-Tfn-building loop (Ocall's "varargs calls
//    get a per-call fn type" block) cloned *every* id in ft->ids,
//    including the synthesized wrapper's own leading "env any"
//    parameter (envfn()/synthfvwrap()) -- which the user never
//    writes at the call site, so it isn't present in n->right at
//    all. this overcounted the fixed-arg baseline by one for a
//    value-call, misaligning every real argument against the newly
//    built type by one position and silently dropping the *last*
//    real vararg -- confirmed via callcom()'s own "too many args"
//    fatal on a value-call passing more varargs than happened to
//    survive the misalignment. env itself correctly stays in the
//    built type (fpcall() genuinely does prepend a real env argument
//    to the call at codegen time, so the runtime frame needs the
//    slot) -- only the *counting* needed the adjustment.
//
// what this proves, and what it deliberately does NOT: a varargs
// function taken as a value can now be called with any number of
// extra arguments beyond its fixed ones, correctly and without
// corrupting the frame -- verified below with 0, 1, and 5 extra
// arguments, plus a poisoned-local check. what's NOT attempted, a
// real, separate, deeper, language-wide limitation this doesn't
// touch: a function's own body cannot introspect or forward
// whatever varargs *it itself* received to another call -- there is
// no va_arg-equivalent anywhere in this compiler (confirmed: even
// literal source like "sys.print(fmt, ...)" inside a user function
// doesn't parse), and the synthesized wrapper every function value
// calls through (synthimportwrap()/synthfvwrap()) builds its own
// inner call from a *fixed* parameter list captured once, at
// wrapper-construction time, with no way to relay a caller's varargs
// onward. this was never possible for a *direct*, non-value varargs
// call either -- sys.print's own ability to read its varargs is a
// native C builtin directly interpreting the raw Dis frame, not
// something ember/limbo source can do -- so it isn't a regression or
// a gap this fix introduced, just a pre-existing, unrelated ceiling.
// every function below simply ignores whatever varargs it receives,
// which is the most any ember-source varargs function could ever do
// with them regardless of the value-call question.

func myprint(fmt string, n int, ...) int {
	return n
}

func init() {
	p := myprint

	r0 := p("zero extra", 10)
	sys.print("r0=%d\n", r0)

	r1 := p("one extra", 20, 1)
	sys.print("r1=%d\n", r1)

	r2 := p("five extra", 30, 1, 2, 3, 4, 5)
	sys.print("r2=%d\n", r2)

	// a poisoned local before a varargs value-call -- same
	// methodology as the nil/list/array investigations -- catches a
	// stale-frame-slot bug if the fixed descriptor construction is
	// still subtly wrong.
	poison := 77777
	poison = 0
	sys.print("poison=%d\n", poison)
	r3 := p("after poison", 40, 9, 9, 9)
	sys.print("r3=%d\n", r3)
}
