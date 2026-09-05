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

Fixed by rebuilding `libmath`, `libbio` and `libsec` from scratch —
`mk` alone will not do it, since the archive is newer than the
sources; the archive has to be removed first — and relinking `emu`.
`sys.print("%8.2f", 1.25)` now prints `    1.25`, `%.3f` prints
`1.250` and `%.0f` prints `1`, from Limbo and from Ember alike. The
libraries and the emulator are build output, not in git, so the fix
is in the tree's state rather than in a commit; what is committed is
this note and the rule in `AGENTS.md`.

The general hazard remains: the mkfiles list no header dependencies,
so any object built before a header changes stays stale until its own
source is touched. When a program's output is wrong in a way its
source cannot explain, rebuild the library it comes from before
believing the code.

## 16. A JSON reader and writer, and what writing it found

`ember/tests/unit/json_test.e` is a JSON parser and printer in Ember
with its unit tests: a pick for the value, `Result` for the errors, a
map for an object's members with an array of keys beside it to keep
their order, and a `Builder` for the text. 366 lines, against the
619 of `appl/lib/json.b`, and it reads like the Go one.

Writing it found a compiler bug that predates this round: a pick
whose case holds a `map[K]ref V` or an array of the pick itself
crashed the compiler ("sizetype: unknown type kind 2"). The map's
instantiation asks for the size of `ref V.Tag` while `V` is still
being built, and a pick's case is normally sized by the pick, so
nothing handled being asked directly. Both compilers now size a case
through its pick (`tests/type/pickmap.e`).

Two smaller things: `?` propagates only its own `Result[T]`, so a
`Result[string]` inside a function returning `Result[ref Value]` has
to be matched by hand -- which is Go's rule for errors of different
types too, and reads fine. And the formatter printed a backspace
character literal as its numeric escape, which it no longer does.

## 17. Gaps after item 16

More probing, this time at generics and at what a loop that grows an
array costs:

- Generic code needs no constraints: `func maxof[T](a T, b T) T` with
  `a > b` compiles, because a template is instantiated by
  substitution and the comparison is checked against the concrete
  type. `map`, `filter` and `reduce` over `[]T` with closures all
  work. Not a gap; worth writing down, since a Go programmer expects
  to have to say `constraints.Ordered`.
- `append(a, x)` copies the whole array each time, because a Dis
  array has no spare capacity, so building an array in a loop is
  quadratic — the same trap `Builder` was added for. `Vec[T]` is now
  in the builtin library (`push`, `len`, `at`, `set`, `slice`,
  `reset`) and doubles, so building an array in a loop is linear;
  `sort(v.slice(), cmp)` sorts it in place
  (`tests/type/vec.e`). Done.

## 18. An Ember library with its own interface

`appl/ember/` holds Ember libraries and commands, built by its own
mkfile into `/dis/ember`: `json.e` (the JSON reader and writer, now a
module with `json.ei` beside it) and `jsonfmt.e`, which loads it and
prints JSON indented. `ember/tests/type/usejson.e` exercises the
library across the module boundary, and the runtime harness builds it.

Writing the interface found the next gap and closed it: an interface
file could not name a generic instantiation at all ("unsupported
interface type tinst"), so no library API could mention `map[K]V`,
`Result[T]` or a generic type of its own. The interface reader now
hands such a type expression to the checker, which instantiates it
with the interface's own types in scope (`ifacetinst`); the
self-hosted compiler passes its resolver over as a function value,
since the checker already imports the interface reader.

One case remains open, and is documented in the language reference:
a generic instantiated by a type declared in the same interface -- a
pick whose case holds a `map[string]ref V` of the pick itself --
signs differently on the two sides, because the recursion ids in the
signature depend on how the type graph is shared. The JSON value
keeps its members in parallel arrays for that reason.

The signature algorithm is Limbo's and cannot change without
breaking every `.dis` in the tree, so the fix would have to make the
two sides share one instantiation rather than build two structurally
equal graphs. Until then the diagnostic says what is happening: the
two types print the same, so the error explains that it is the link
signature that differs and what to do about it.

Two compiler fixes came with it: a pick is no longer sized or
equivalence-classed while its cases are still being built (sizing it
then fixed every case's field offsets against fields that were not
all there yet, which is what made a client read a member at the wrong
offset), and the interface reader knows `bool`.

## 19. What was tried for the interface-recursion limit

Two attempts, both recorded so the next session does not repeat them.

Making `sametype()` compare adts structurally (so that the interface's
copy of a type and the module's copy share one instantiation, and the
map inside a pick signs the same on both sides) does not help: at the
moment the map is instantiated the module's own pick is still being
built, so `tequal` rightly says the two are not the same type yet.
Sharing the instantiation would need the instantiation deferred until
the pick is complete, or the interface's type unified with the
module's rather than built separately -- either is a redesign of how
an interface is read.

Changing the signature algorithm is not open: it is Limbo's, and
every `.dis` in the tree carries signatures computed with it.

So the limit stands, with a diagnostic that explains it.

## 20. A read-eval-print loop

`appl/ember/emberepl.e` is the last item of item 8: a REPL. Each line
becomes a module -- the session's declarations, then an `init` with
its statements -- compiled by the self-hosted compiler in the same
process, loaded and run. An expression prints its value, a
declaration joins the preamble, and a line that fails to compile is
reported and dropped, leaving the session as it was.
`ember/tests/repl/session.e` is a scripted session with its expected
output, run by `tests/repl.sh` as part of `mk test`.

It found one thing worth knowing: the compiler's modules keep a
compilation's state in their globals, so compiling twice in one
process needs a fresh instance of each (`load Parse parse.PATH` and
so on, wired the way `emberc` wires its imports). Nothing before the
REPL had ever compiled twice in one process.

What is left of item 8 is a language server, which wants the checker
to report positions and types for a file without generating code --
the `-c` path already does the work, so it is mostly a protocol.
Item 22 is the half of that which is not protocol.

## 21. Another translation: bytes

`ember/limbo/bytes.e` translates `appl/cmd/bytes.b` (212 lines) line
for line, with its own debug prints kept so the differential can hold
the two to the same output; ten cases in `bytes.cases` cover the
range, the replacement, the escapes and the error paths, and all ten
matched by hand before they went in -- with one rule learned the hard
way: a case whose program ends before reading its input must not
redirect a file into standard input, since the emulator echoes a
console nobody read and where that echo lands among the program's own
output is a matter of timing. Nothing in it needed a language
change, which is the first translation in a while that found nothing:
`len(x)`, `hd(l)`, `tl(l)` as calls, `0x` for `16r`, `copy` for a
slice assignment, and `match` labels for `or` and `to` were the only
edits.

## 22. Cross-references: what an editor asks the compiler

`ember -X file.e` (and `emberc -X`, `appl/cmd/ember/xref.e`) prints
the file's declarations and every use of one, each with a position
and a type, and each use naming the declaration the checker resolved
it to. That is what a language server answers "go to definition",
"hover" and "find references" with; what is left over is the
protocol, which is JSON over a pipe and needs no compiler work
(`appl/ember/json.e` already writes it).

The dump runs after checking, on the checked tree, which decides what
it can and cannot see. It sees every declaration in the file and the
uses in every function body, with the imported declarations named by
their module (`Sys:119:1`), since an interface file's lines are its
own. It does not see what the checker rewrote away: a constant
folded into its value, a field access lowered to address arithmetic,
or the body of a closure, which is lifted into a function that never
reaches the function list -- the local it captures still shows as a
use, at the enclosing function's position. A generic function appears
twice, once as the template (no type of its own) and once per
instantiation, named `first[string]`.

Two positions had to be got right for the two compilers to agree.
The C compiler numbers every line of every file it reads on one
absolute scale and maps it back with `fline()`; the self-hosted one
parses a file at a time and keeps each file's own numbers. Printing
`file:line:col` would have needed that map in both, so the format
names the module instead of the file, which both have. And a
top-level name is resolved through the checker's binding
(`sym->decl`, `check.lookup`), not the symbol table: after checking,
the two differ.

`ember/tests/xref/*.e` are dumped and compared with the recorded
`.x` files by `tests/xref.sh`, which then has the self-hosted
compiler dump the same files and requires the same bytes.

## 23. A language server, and the transport it took

`appl/ember/emberls.e` is the rest of item 8: a language server
speaking JSON-RPC, answering `definition`, `hover`, `references` and
`documentSymbol` from the `-X` dump (read back through the
`xref.setout` added for it) and publishing the compiler's own
diagnostics after every `didOpen` and `didChange`. It is 500 lines
and needed no language change, which is worth recording on its own:
picks with binders, maps of refs, multiple results, `try`/`catch`,
string slicing and the builtin `Builder` were enough to write a
protocol server.

What it could not have was a transport over the emulator's console.
That console is a keyboard, not a pipe: `kbdslave`
(`emu/port/devcons.c:100`) echoes every byte it reads back to file
descriptor 1 unless the console has been put in raw mode, and it runs
ahead of the program, so a `rawon` written at startup arrives too
late -- a probe showed the whole of a redirected file echoed before
the program's first read. And `readkbd` (`emu/MacOSX/os.c:505`)
turns a carriage return into a newline, which the protocol's
`Content-Length` framing is made of. Both together mean a client
that spawns the emulator and talks to it over pipes reads its own
requests back, mangled.

Two ways out were open. The narrow one is to stop the echo when the
host's standard input is not a terminal -- a flag in `devcons.c` set
from each platform's `os.c` -- which touches every host and still
leaves the carriage-return rewriting. The one taken is a socket:
`emberls -p 17777` binds `#I` on `/net`, announces on the port and
serves each connection in turn, and a client on the host side of the
emulator reaches it without the console in the way. `ember/tests/ls.sh` runs the same scripted session twice, once framed into a file
and once over a connection made by `tests/lstcp.py`, and requires
both to produce the recorded replies byte for byte -- which they do,
so the two transports are not merely both working but identical.

What is left of the echo is a note for whoever next wants a Dis
program to speak a byte protocol over the emulator's standard input:
it cannot, and the socket is the way.

One of the two things the dump's shape left over is now fixed: a use
of an imported module's member had the position of the module name it
was reached through (`sys.print` reported `print` at the `s`), which
made a hover over the member name answer about the module. Both
checkers were building the member's name node fresh and giving it the
whole dot expression's source range; they now keep the member name's
own, so `print` is reported at the `p`, and a hover lands where the
editor's cursor is. The other is fixed too, differently: a constant
folded by the checker is gone from the tree, name and all, so there
is nothing left to walk. Both checkers now record the use as they
fold it -- position, name and declaration -- and the dump looks that
table up at each `Oconst` it walks, so `High.name()` reports `High`
where it is written. That is what makes an enum navigable, which is
most of what a constant is for.
