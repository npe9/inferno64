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
  `func (c Color) name() string` is refused ("receiver type must be a
  struct or ref struct"). Limbo adts are the only receiver, so this
  needs a wrapper or a dispatch rewrite; medium.
- A single evaluation of the operand of `?.` and `x.(T)`: both
  duplicated the operand, so a call there ran more than once. A
  plain name is still mentioned twice (the same code as before);
  anything else becomes the parameter of a hidden closure, which the
  chain or the assertion runs inside (`tests/type/once.e`). Done.
