module Genericinfer2

import sys "sys"

// genericinfer.e covers the original, narrower inference (a parameter
// whose *entire* declared type is one bare type-parameter name).
// this file covers the newer, structural cases: a type parameter
// buried one level inside a slice, a chan, a ref, a function-typed
// parameter's own signature, or another generic type's own
// instantiation (including two of those nested together).
//
// no array/slice *composite literal* syntax exists yet in this
// compiler ("[]int{...}" -- compositefields() only accepts adt
// types), and indexing one isn't implemented in codegen either
// ("ecom: unsupported indx") -- both genuinely separate, pre-existing
// gaps, unrelated to generics. len() on a slice-typed parameter does
// work, so the slice-of-T case below is exercised through init()'s
// own argv parameter (always present, just empty under this test
// harness) rather than a literal: slicelen(argv) itself can't
// distinguish a right-vs-wrong T binding (len() doesn't depend on
// element type), so the actual proof that inference resolved T=string
// here, not e.g. int, is a separate check that isn't part of this
// file's own runtime output -- see the commit message.  no list
// *literal* syntax exists either (Ocons/"::" is in the AST enum but
// never wired into the parser), so the list-of-T unification branch
// (unifytparam(), check.c) is implemented but genuinely untested by
// any file, for the same reason arrays are; chan-of-T, below, is a
// real primitive and *is* exercised with discriminating output.

type Box[T] struct {
	val T
}

type Pair[A, B] struct {
	first  A
	second B
}

type Pt struct {
	x, y int
}

// "xs []T": unifies through the array element type.
func slicelen[T](xs []T) int {
	return len(xs)
}

// "b Box[T]": unifies through a generic type's own instantiation
// arguments -- Box[int] as an argument must resolve T=int without
// an explicit "unbox[int](...)".
func unbox[T](b Box[T]) T {
	return b.val
}

// "p Pair[A, B]": two type parameters, both buried inside the same
// generic instantiation.
func swappair[A, B](p Pair[A, B]) Pair[B, A] {
	return Pair[B, A]{first: p.second, second: p.first}
}

// "p ref T": unifies through a ref's target type.  T is otherwise
// unconstrained, but this instantiation is only ever called with a T
// that actually has an x field (Pt), which is all a monomorphized,
// per-instantiation-checked generic needs to typecheck -- the same
// duck-typing every other generic function in this compiler already
// relies on.
func getx[T](p ref T) int {
	return p.x
}

// "b ref Box[T]": two levels of the recursion nested together --
// Otref wrapping an Otinst, not just either alone.
func getval[T](b ref Box[T]) T {
	return b.val
}

// "c chan T", "v T": chan-of-T unification, plus a second parameter
// pinned to the same T a bare-name match would already have handled
// (genericinfer.e's own "a, b T" case) -- here as a sanity check that
// the two unification strategies agree when both apply to one call.
func feed[T](c chan T, v T) {
	c <- v
}

func recvfrom[T](c chan T) T {
	return <-c
}

// "f func(T) U": unifies through a function-typed parameter's own
// signature -- both its parameter type and its return type.
// tests/ok/generics.e's own map2[T, U](xs []T, f func(T) U) []U is
// the original motivating shape for this (that file is parse-only,
// see tests/run.sh's own tests/ok/ handling, so apply() here is a
// directly callable, runtime-verified stand-in for the same
// function-typed-parameter half of it).
func apply[T, U](f func(T) U, x T) U {
	return f(x)
}

// a *void* function-typed parameter ("f func(T)", no result): pt's
// own Otfunc syntax has a nil right (psignature()'s "no results"
// default) for this shape, so unifytparam()'s Otfunc case must not
// try to recurse into a return type that doesn't exist.
func applyvoid[T](f func(T), x T) {
	f(x)
}

// unlike apply()/applyvoid() above (both of which also take a plain
// "x T" argument, so T is separately inferable from that alone --
// this branch is redundant work for T there, only U genuinely needs
// it), T here appears *nowhere* except inside f's own signature: if
// unifytparam()'s Otfunc case only unified the return type and not
// the parameter list, this would regress to "cannot infer all type
// arguments" while apply()/applyvoid() kept compiling, silently
// hiding exactly that half of the mechanism.
func countargs[T](f func(T)) int {
	return 1
}

func double(x int) int {
	return x * 2
}

func greet(name string) string {
	return "hi " + name
}

func shout(x int) {
	sys.print("shout=%d\n", x)
}

func whisper(s string) {
	sys.print("whisper=%s\n", s)
}

func init(argv []string) {
	sys.print("slicelen=%d\n", slicelen(argv))

	b1 := Box[int]{val: 42}
	bi := unbox(b1)
	sys.print("unbox_int=%d\n", bi)

	b2 := Box[string]{val: "hi"}
	bs := unbox(b2)
	sys.print("unbox_str=%s\n", bs)

	p := Pair[int, string]{first: 1, second: "one"}
	q := swappair(p)
	sys.print("swap_first=%s swap_second=%d\n", q.first, q.second)

	pt := ref Pt{x: 7, y: 8}
	sys.print("getx=%d\n", getx(pt))

	rb := ref Box[int]{val: 99}
	sys.print("getval=%d\n", getval(rb))

	c := chan int
	spawn feed(c, 77)
	sys.print("recvfrom=%d\n", recvfrom(c))

	sys.print("apply_int=%d\n", apply(double, 21))
	sys.print("apply_str=%s\n", apply(greet, "ember"))
	applyvoid(shout, 5)

	// countargs(shout)'s own T=int and countargs(whisper)'s T=string
	// come *only* from unifying against each function's own parameter
	// type -- if that half of Otfunc's unification ever regressed,
	// both calls below would fail to compile at all ("cannot infer
	// all type arguments"), not silently misbehave at runtime; a
	// clean compile plus the correct count is the actual evidence
	// here, the same way genericinfer.e's own inference tests prove
	// themselves by compiling without an explicit "[...]" at all.
	sys.print("countargs=%d,%d\n", countargs(shout), countargs(whisper))
}
