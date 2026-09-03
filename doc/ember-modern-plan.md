# Ember: the comforts still missing, and the plan for them

Written after the nineteen Limbo translations (`doc/ember-vs-limbo.md`)
and the best-practice pass that added `bool`, `range`, `try`/`catch`,
`copy`, `_` and `exit()`. This is the list of what a programmer from
Go, Rust, Swift or Kotlin still misses, each with a design, the
compiler work it needs, and its tests. The items are in the order
they will be built; each lands as its own commit with both compilers
(C bootstrap in `ember/`, self-hosted in `appl/cmd/ember/`) in
lockstep and `mk test` green.

One correction to the assessment that produced this list: `if x :=
f(); x > 2 {` already exists (parse.c's `pif`), as does the three-part
`for`. Only `match` lacked the initializer.

## 1. Initializer on `match`

`match x := f(); x { ... }`, the same `psimple(); if ';'` prefix `pif`
uses, wrapped in an `Oscope` so the name is local to the statement.
Parser only. Test: `tests/type/matchinit.e`.

## 2. `defer`

`defer f(args)` and `defer func() { ... }()` push a call onto a
per-function list evaluated at that point; the calls run in reverse
order when the function returns, whether by `return` or by falling
off the end. Lowering in the checker, no runtime support: the parser
evaluates the arguments into hidden temps and wraps the call in a
`func()` literal; the checker conses that closure onto a hidden local
`list func()` (`.defers`), and every `return e` in the function (not
in nested closures) becomes `{ .ret := e; walk the list calling each;
return .ret }`, with the same walk appended to a void function's end.
A list rather than one slot per statement, so a `defer` in a loop
records one call per iteration. A `raise` or `exit()` does not run
them, and neither does a VM fault; documented. Test:
`tests/type/defer.e` (order, arguments evaluated at the defer, defer
in a loop, early return, a method receiver, a tuple result).

## 3. Closures capturing by reference

Today a closure copies each captured variable into its environment
record, and a write to a capture is a compile error. The fix is the
classic one: a variable that any closure captures lives in a box (a
one-field `ref` cell) from its declaration on; the enclosing
function and every closure hold the same pointer, so writes are
shared and the existing by-value environment machinery carries the
box unchanged.

Work, as built: when the checker first sees a capture (echk's Oname
case) it makes the box type `.boxN$x{v T}` and a hidden local
`.bN$x` of type `ref .box` in the owning function (`boxvar`); the
closure's environment field is typed as that ref, and every use
inside the closure becomes a double indirection (env field, then
`.v`). Once the owner is fully checked, a post-pass (`boxpass`)
rewrites its own uses of the variable to `box.v` and follows each
declaration site (`x := e`, `var x T`, a `range` or pattern binder,
a `catch` binder, a parameter at function entry) with `box = ref
.box{v: x}`; closure creation copies the box pointer. The
capture-write error is gone. A loop body's declaration executes each
iteration, so each closure gets its own box; a three-part `for`'s
variable is one box (Go before 1.22). Along the way `fs[i](x)`, a
call through an indexed function value, stopped parsing as a generic
instantiation. Tests: `tests/type/capture.e`, `capturewrite.e`
(moved from `typeerr/`), `closurecaptures.e` regolden.

## 4. `append`, map literals, ranging over maps

As built. `ember/module/builtin.ei` is a header-only module every
compilation imports implicitly under the alias `.builtin` (a name
no source can spell); it holds `append[T]`, `appendall[T]`, the
`Map[K, V]` struct with its methods, `newmap`, `mput`, and the hash
and equality functions for `int`, `big`, `byte` and `string` keys.
`append(a, x)` and `append(a, xs...)` (the parser now accepts `...`
after a call argument) become calls of the templates. Arrays have
no capacity, so every append copies; documented rather than hidden.
`map[K]V` is parsed as `ref .builtin.Map[K, V]` with the
instantiation flagged, and the checker marks the instance type
(`Type.ismap`); `map[K]V{k: v}` becomes nested `mput` calls around
`newmap[K, V](hash, eq)` with the pair chosen by K; `m[k]`,
`m[k] = v`, `m[k] op= v`, `m[k]++`, `v, ok := m[k]`, `delete`, `len`
and `range` (over `m.entries()`) are rewritten into method calls.
`map` became a keyword, which renamed a field in the compiler's own
sources and a variable in five tests. Tests: `tests/type/maptype.e`,
`appendarr.e`.

## 5. Enumerations and pick conveniences

As built. `const ( A = iota; B; C )` blocks: the parser appends one
`Ocondecl` per item carrying its index, deep-copying a repeated
expression (the checker folds in place), and the checker declares
`iota` in a scope around each item's folding; `const` inside a
function is now a statement (it never was). Pick common fields and
tag groups needed only the parser and `picktags`: the checker's
field lookup, composite literals, sizing and signatures already
followed Limbo's model, where the pick adt's own ids are the common
fields laid out after the tag word. Case ranges `lo...hi` are an
`Orange` pattern whose two constants become a label's start and
stop; the lexer stops a number before `...` so `1...5` is not `1.`
and `..`. Tests: `tests/type/iota.e`, `pickcommon.e`, `caserange.e`.

## 6. Variadic functions, string builder, conditional expression

As built. `func join(sep string, parts ...string)`: the parameter
is an array of the type (`Type.varargs == 2`, against 1 for Limbo's
untyped `...`), the checker packs a call's trailing arguments into
an array literal (an `Oarray` whose element type is carried by a new
`Otypeval` node, since no source syntax could name an arbitrary
type after checking), `xs...` passes an array through, and the
function-value wrappers pass their own array through; a value call
is checked twice, so the call node remembers it was packed. `c ? a :
b` is an `Ocond` parsed at the lowest precedence (the postfix `?`
that propagates an error yields when an expression follows), checked
like an `if` whose arms must agree, and compiled by branching into
one destination. Not done: a string `Builder`, because Dis strings
keep slack after `s[len(s)] = c` and appending in place is already
the idiom; and match guards, because the case table dispatches once
and a failed guard would need a second chain of tests per arm --
left for a later round. Tests: `tests/type/variadic.e`, `cond.e`.

## 7. Interfaces

As built, and much smaller than planned: no new type kind, no
codegen. The parser turns `type W interface { m(params) results }`
into three declarations: `type .W$s struct { m func(params) results }`
(a struct of method closures, flagged so the checker knows it is an
interface), `type W ref .W$s` (the interface name is the reference),
and a generic converter `func .W$from[.T](.x .T) W { return ref
.W$s{m: func(params) results { return .x.m(params) }} }`. The checker's
`assignable()` recognises an interface target, checks structurally
that the source's methods exist with matching signatures
(`implements()`, a readable error otherwise), and rewrites the value
in place into a call of the converter, instantiated for the source
type by the ordinary generic machinery; the closures capture the
receiver by reference. A call through the interface is a call of a
field of closure type, which already worked. Tag values are widened
to their pick first. Not done: type assertions back to the concrete
type, embedding, and generic interfaces. Tests: `tests/type/iface.e`,
`useiface.e` with `shapelib.ei`.

## 8. Nullability

As built: `?.` and `??` are lexer tokens and parser sugar over the
conditional expression (`a?.f` guards the rest of its postfix chain:
`a != nil ? a.f... : nil`; `a ?? b` is `a != nil ? a : b`), with the
receiver deep-copied, so it is evaluated twice. A `ref` stays
nullable; a non-null type is not attempted, since every Limbo
library returns nil for failure. Tests: `tests/type/nilsafe.e`.

## 9. Integer types

Not planned. `int` is the Dis 32-bit word and `big` its 64-bit
sibling; unsigned and 8/16-bit types would need new VM instructions,
and a native-width `int` would change every signature the Limbo
libraries expose. The doc says so plainly; `byte` remains the only
narrow type.

## 10. Tooling

Done: `ember -i` derives a module's `.ei` from its checked
declarations (every top-level name; generic and inline declarations
are noted for hand-writing), checked against goldens by
`tests/ifacegen.sh`; the unit-test convention is `func test_xxx()`
with `expect(cond, msg)` (an inline function in `builtin.ei`) and
`ember -t`, which appends an `init` that runs each test under
`try`/`catch`, reports failures by name, and prints `PASS n tests`;
`tests/unittest.sh` runs `tests/unit/*_test.e`. Both are in the C
compiler only (driver options, not language). `ember -F` is the formatter: the
lexer keeps comments (with positions) when asked, the parser keeps
sugar unexpanded in a raw mode, and `fmt.c` prints the tree with the
comments interleaved by line; `tests/fmt.sh` round-trips every test
and translation (same code, idempotent). Packages
as directories are not planned (one file, one module,
Inferno-style); a language server and a REPL are last.

## Order and status

| # | item                          | status |
|---|-------------------------------|--------|
| 1 | match initializer             | done   |
| 2 | defer                         | done   |
| 3 | capture by reference          | done   |
| 4 | append, maps                  | done   |
| 5 | iota, pick common fields      | done   |
| 6 | variadics, builder, ?:, guards| mostly |
| 7 | interfaces                    | done   |
| 8 | ?. and ??                     | done   |
| 9 | integer types (not planned)   |   --   |
| 10| emberfmt, .ei derivation, tests| done   |
