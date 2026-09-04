# Ember: what is left, after the modern-language plan

`doc/ember-modern-plan.md` is done through interfaces, nil-safe
operators, the formatter, interface derivation and unit tests. This
is what remains, ordered by how much it would change day-to-day
writing, with the design each would take.

## 1. `for s := f(); s != nil` with the post statement implied

The survey in `doc/ember-idioms.md` finds 217 `while((s := f()) !=
nil)` loops in the Limbo tree; the Ember spelling repeats the call
in the post statement. Allow a two-part `for init; cond {` to repeat
the initializer's right side as the post statement when the
initializer is `name := expr`: `for s := b.gets('\n'); s != nil {`.
Parser only (`pfor` builds the `Oforctl` post from a copy of the
initializer as an assignment). Small, and the most-used gap. Done
in the same round as this plan: `for s := b.gets('\n'); s != nil {`
works, and the formatter prints it back that way.

## 2. Per-iteration loop variables

A closure made in a three-part `for` sees the loop's one variable
(Go before 1.22). Go 1.22 gives each iteration its own. The boxing
pass (`boxpass`) can do this: when a boxed variable is the loop
variable of a `for` header, copy it into a fresh box at the top of
each iteration and back at the end. Checker only. Done in this round: the copy happens before the post
statement, so `continue` reaches it too.

## 3. Type assertions and interface extras

`x.(T)` back from an interface, embedding one interface in another,
and generic interfaces. The converter struct can carry a hidden
field holding the receiver as `any`, giving `x.(T)` a runtime tag
check; embedding is a parser matter (copy the embedded methods in);
generic interfaces fall out of the generic struct machinery if the
converter is instantiated per type argument. Medium; none of the
translations wanted them. Done so far: `x.(T)` and `v, ok := x.(T)`
(`tests/type/assert.e`, `tests/typeerr/asserterr.e`); the converter
stores the receiver and its type's printed name in hidden `.self`
and `.tag` fields. Embedding too (`tests/type/embed.e`): the parser
copies the embedded interface's methods in, so the embedded one must
be declared earlier in the same file; and an interface value now
converts to any narrower interface. Generic interfaces too
(`tests/type/geniface.e`): the struct, its reference alias and the
converter take the interface's type parameters, the converter is
instantiated outright from the target's type arguments, and a
generic type may now have a non-struct body (the alias is
`ref .W$s[T]`). Item done.

## 4. Errors as values

`try`/`catch` and `raise` cover exceptions; the `?` operator covers
picks with an error tag; nothing yet says which functions can fail.
A `Result[T]` type in `builtin.ei` (`Ok(v T)`, `Err(e string)`) with
`?` propagation would give a convention without a new mechanism.
Small; mostly library and documentation. Done in this round:
`Result[T]` is in `builtin.ei` and bound by its bare name
(`tests/type/result.e`).

## 5. Tooling parity in the self-hosted compiler

`-i`, `-t` and `-F` lived in the C compiler only. The self-hosted
compiler is the one that runs under Inferno, so the formatter and
interface derivation should be ported so they work there too. Done
in this round for the formatter: `appl/cmd/ember/fmt.e` and
`emberc -F` (the comments are handed over from the driver's parser
instance, since a module's state lives with the instance that made
it). `-i` and `-t` followed: `appl/cmd/ember/ifacegen.e` (a port of
`ifacegen.c`, resolving names through the driver's checker instance)
and `addtestmain` in `emberc.e`; `tests/selftools.sh` checks both
print or compile the same as the C compiler. Item done.

## 6. Semicolon-free interface files and exports

`ember -i` derives every top-level name. An `export` marker (or
Go's capital-letter rule) would let a module keep helpers private
without hand-editing the derived file. Small; parser keyword plus a
filter in the generator and a check in the interface reader. Done in
this round: `export` before a declaration marks it, and `-i` derives
only marked declarations when any are (`tests/gen/exported.e`).

## 7. Integer types (not planned)

`int` is 32 bits, `big` 64, `byte` 8; no unsigned. This is the Dis
VM's word model and changing it means new instructions and a new
signature for every Limbo library. Documented; not planned.

## 8. Packages, language server, REPL

One file is one module, Inferno-style, and that stays. A language
server needs the checker to report positions and types for a file
without generating code, which the `-c` check-only path already
does; a REPL exists for Limbo (`limborepl`) and could be adapted. Last.

## Order

1, 5 and 6 are small and the most useful; 2 and 4 next; 3 when a
program wants it; 8 last.

## 9. Next gaps (found by probing after items 1 to 8)

Small programs written against the compiler once items 3 and 5 were
done showed what a Go programmer still reaches for and misses. Each
is planned:

- Array literals: `[]int{1, 2, 3}` and `[]Shape{a, b}` parsed as a
  conversion; `[n]T{...}` already existed, so the size-less form is
  the count of its elements (`tests/type/arrlit.e`). Done.
- Type switch: `match v := s.(type) { case ref Rect: ... }`, sugar
  over a chain of type assertions binding `v` at each arm's type
  (the interface's in an arm of several types; a `break` in an arm
  is the enclosing loop's). Lowered in the parsers
  (`tests/type/tswitch.e`). Done.
- Explicit interface conversion: `Shape(x)` was refused by
  `castable`; it now goes through the same converter as an
  assignment (`tests/type/ifconv.e`). Done.
- Range over a channel: `for x := range c` receives until the loop
  breaks (there is no close in Dis, so the loop ends by `break`;
  `tests/type/rangechan.e`). Done.
- Methods on named non-struct types: `type Color int` with
  `func (c Color) label() string` was refused. A named type with
  methods is now a copy of its base type, distinct enough to carry
  them and structurally equal everywhere else
  (`tests/type/namedtype.e`, and across a module boundary in
  `tests/type/loadlib.e`). Done, and it turned up a latent bug: two
  module members of the same name (a method and a function, say)
  silently mislinked, and are now an error.
- A single evaluation of the operand of `?.` and `x.(T)`: both
  duplicated the operand, so a call there ran more than once. A
  plain name is still mentioned twice (the same code as before);
  anything else becomes the parameter of a hidden closure, which the
  chain or the assertion runs inside (`tests/type/once.e`). Done.

## 10. Gaps after item 9 (probed the same way)

Every bullet of item 9 is done, so another batch of small programs
went looking for what is still awkward. Each is planned:

- Typed constants: `const ( Low Level = iota; Mid; High )` was
  refused, so an enum could not have the named type its methods are
  on. A constant may now declare its type, which the repeats of a
  block inherit (`tests/type/enum.e`). Done.
- Named result parameters: `func divmod(a int, b int) (q int, r int)`
  with a bare `return`. The names are locals of the body, zero at
  entry, and a bare `return` returns them
  (`tests/type/namedres.e`). Done.
- Method values: `f := c.get` was refused ("a method is not a
  value"), though a plain function name was already a value through
  its `$fv` wrapper. A method used as a value now becomes the
  closure a programmer would write, the receiver evaluated once and
  captured (`tests/type/methval.e`). Done.
- A string builder in the builtin library: `+=` in a loop is O(n^2),
  and the modern-language plan left this open. `Builder` is in
  `builtin.ei` (`puts`, `putc`, `len`, `reset`, `string`), which
  needed one compiler change: a method declared with its body in an
  interface is now inlined into each importer, as a function with a
  body already was. Done.
- A `sort` in the builtin library, over `[]T` with a comparison
  function: `sort(a, cmp)`, quicksort with insertion sort on short
  ranges (`tests/type/builtinlib.e`). Done.
- Struct embedding: `type Derived struct { Base; name string }` (or
  `ref Base`, for a method with a ref receiver) promotes the
  embedded type's fields and methods
  (`tests/type/embedstruct.e`). Done.

Not gaps, checked while probing: `for i, r := range s` walks a string
by rune with rune indices (Limbo's string model, not Go's bytes), and
`for k := range m` over a map gives the keys.

## 11. Gaps after item 10

The same probing again, once item 10 was done. Each is planned:

- A named type satisfies an interface: the converter takes it, and
  the method closures hold the value
  (`tests/type/ifacenamed.e`). A type assertion back to a named type
  is refused (`x.(Level)`: "type assertion needs a reference type"),
  since the hidden `.self` holds a reference and a value has none.
  Done.
- A `match` with no subject: `match { case x < 3: ... }`, the Go
  `switch` that is an if/else chain, lowered in the parsers
  (`tests/type/matchcond.e`). Done.
- Struct value equality: `a == b` is the field-by-field comparison,
  nested structs included, each operand evaluated once
  (`tests/type/structeq.e`). A pick, a tuple or a field with no
  equality of its own (an array) is still refused. Done.

Not gaps, checked while probing: `defer` inside a loop, `try`/`catch`
with `raise`, `sort` over an array of refs, and a map with struct
values (`m["a"].n++`) all work.

## 12. Gaps after item 11

Found by writing two programs rather than probing: a small expression
interpreter (lexer, pick AST, `Result` errors, a map environment) and
a channel worker pool. Both came out in about 130 and 70 lines, and
between them they used picks, generics, maps, `?`, closures, `alt`,
`sort` and `Builder` without friction — except one thing, now done:

- A `match` that declares its subject: `match s := shape(n) { ... }`,
  which had to be written `match s := shape(n); s { ... }`
  (`tests/type/matchbind.e`). Done.

The interpreter is a fair sample of what the language is like to
write now; nothing else it wanted was missing.

## 13. Gaps after item 12

A word-frequency program (the `strings` library, a map, the builtin
`sort` and `Builder`) came out in 55 lines, of which eight were a
loop copying a `list string` into a `[]string` because the library
returns lists and everything else in Ember is array-shaped. So:

- `[]T(l)` converts a list to an array, the way `[]byte(s)` converts
  a string, and `tolist(a)` goes back
  (`tests/type/listarray.e`). Done.
- The builtin `sort` is a stable bottom-up merge sort, so a
  comparison on a key keeps equal elements in order. Done.

`ember/limbo/sort2.e` is `appl/cmd/sort.b` written with them: the two
hand-written merge sorts are the builtin `sort` with a closure, and
the output goes through a `Builder`. It is 105 lines against the
line-for-line translation's 135.

## 14. Gaps after item 13

A generic binary search tree with a closure iterator, written to see
how generics feel, found a real bug rather than a missing feature: a
template instantiated *inside a closure* — a generic function, or one
of the builtin library's inline methods — had its own locals mistaken
for captures of that closure ("cannot resolve capture of s" from
`builtin.ei`). The instantiation now checks the body outside the
current closure (`tests/type/tmplclosure.e`). Nothing else the tree
wanted was missing: generic structs, methods on them, closures as
fields, and a generic function taking a comparison all worked.

## 15. A platform bug the probing found

Formatting a real with a precision is wrong under the hosted
emulator: `sys.print("%8.2f", 1.25)` prints `      1.` and `%.3f`
prints `1.2`, one fractional digit short of the precision asked for,
and `%.0f` prints nothing at all. It is not an Ember bug — a Limbo
program compiled with `limbo` prints the same — and the cause is not
in the source either: `libmath/gfltconv.c` compiled today is correct.

`MacOSX/arm64/lib/libmath.a` carries a `gfltconv.o` built on 25
August at 06:08, before `MacOSX/arm64/include/lib9.h` was replaced at
06:42, and the `Fmt` structure moved: the stale object reads `f->prec`
at the wrong offset. The mkfiles do not track header dependencies, so
`mk` never rebuilt it. `libsec` and `libbio` have objects older than
that header too.

The fix is to rebuild those libraries and relink `emu`, then check
that nothing in the suite depended on the wrong output. Worth doing
on its own commit, since it changes the emulator every test runs on.
