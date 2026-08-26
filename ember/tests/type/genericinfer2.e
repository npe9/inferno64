module Genericinfer2

import sys "sys"

// genericinfer.e covers the original, narrower inference (a parameter
// whose *entire* declared type is one bare type-parameter name).
// this file covers the newer, structural cases: a type parameter
// buried one level inside a slice, a chan, a ref, or another generic
// type's own instantiation (including two of those nested together).
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
}
