# The Ember Language, as Implemented

This is a reference for Ember as the compiler under `ember/` actually
accepts and runs it today. Every construct here is covered by a test
under `ember/tests/` that compiles and, where it has a golden output,
runs under the hosted Inferno VM. Where Ember differs from Limbo or
from Go, the difference is stated. The design background is in
`doc/ember-repository-study.md`.

## Building and running

The bootstrap compiler is C. Build it with `mk` in `ember/`; the
binary is `ember/o.out` (installed as `ember` under the host bin
directory). Compile a module with:

    ember -I ember/module -o prog.dis prog.e

The `-I` directories are searched for interface files (`.ei`) in the
order given, and the built-in `ember/module` directory is searched
last. A compiled module runs under the hosted VM, with the tree as its
root so `/dis/lib` and `/ember/tests` resolve inside it:

    emu-g -r . -c0 -d '#U*/absolute/host/path/prog.dis'

The `#U*` prefix loads a host path without copying it into the tree.
`-d` runs the module's `init` with no arguments. To run a program as
an Inferno command with arguments, build the emulator's startup
module and its dependency once (`mk emuinit.dis` in `appl/cmd`, `mk
arg.dis` in `appl/lib`, installed as `dis/emuinit.dis` and
`dis/lib/arg.dis`), put the program inside the tree, and give its
tree path and arguments:

    emu-g -r . /tmp/args.dis one two three

The program's `init(ctxt ref draw.Context, argv list string)` links
as a Limbo `Command`; `argv` holds the program path and its
arguments. `mk test` in `ember/` runs the compile suite and then the
runtime suite (`tests/runtime.sh`), which compares each program's
output with its golden file.

## Modules and program shape

A source file is one module:

    module Wc

    import sys "sys"
    import bufio "bufio"

    func init() {
        sys.print("hello\n")
    }

The import path names an interface file (`sys.ei`, `bufio.ei`) found
on the search path. The alias is a variable holding the loaded
module; it is loaded automatically before `init` runs, from the
`PATH` constant declared in the interface. Members are reached with a
dot: `sys.print(...)`, `bufio.OREAD`, `bufio.Iobuf`.

The entry point is `init`, either with no parameters or with the
Inferno command signature `init(ctxt ref draw.Context, argv list
string)`. Top-level declarations are `const`, `var`, `type` and
`func`, in any order; a struct type may refer to itself or to a type
declared later in the file.

Every top-level function and method is exported. There is no
visibility keyword. A module's imports are loaded and its global
initializers run once, on the first entry into any of its functions,
so a library module without `init` needs no setup call.

## Types

The scalar types are `int` (32 bits at runtime), `big` (64 bits),
`byte`, `real` (64-bit floating point) and `string`. An integer
literal that does not fit in 32 bits is a `big`; so is `-2147483648`,
since the literal itself is out of range (write `-2147483647 - 1` for
the int). `0x1f`, `0o17`, `0b101` and, as in Go, a leading zero
(`0666`) give hexadecimal, octal and binary literals. Character
literals such as `'a'` and `'\n'` are ints.

`[]T` is an array. `[n]T` allocates a zero-filled array of `n`
elements, where `n` may be a runtime value; `[3]int{1, 2, 3}` is a
literal, `[3]int{}` is zero-filled. Arrays are shared by reference,
indexed with `a[i]`, sliced with `a[lo:hi]`, `a[lo:]` and `a[:hi]`,
and measured with `len(a)`. `copy(dst, src)` copies the elements of
one array into another (either may be a slice, and they may overlap);
it is a statement with no value, and `src` must fit in `dst` or the
VM raises an array bounds error. This is Limbo's `dst[0:] = src`. A
two-dimensional array is an array of arrays: `[3][]int`, then
`grid[i] = [4]int`.

`append(a, x)` returns a fresh array one element longer, and
`append(a, xs...)` one longer by all of `xs`; Dis arrays have no
spare capacity, so every append copies, and a long array is better
built as a list and converted, or allocated at its final size.

`map[K]V` is a hash map with keys of type `int`, `big`, `byte` or
`string`: `m := map[string]int{"a": 1}`, `m[k] = v`, `m[k] += 1`,
`m[k]` (the zero value when absent), `v, ok := m[k]`, `delete(m, k)`,
`len(m)`, and `for k, v := range m` (in no particular order, over a
snapshot). A map is a reference; the zero value of a map variable is
`nil`, so declare with a literal. `map` is a keyword. Under the
covers a map is `Map[K, V]` from `module/builtin.ei`, an implicit
header-only import every module has as the unnameable alias
`.builtin`; the checker rewrites each operation into a method call,
so a map costs what that struct costs.

`list T` is a list: `1 :: 2 :: nil`, with `hd(l)`, `tl(l)` and
`len(l)`. `chan T` is a channel; `chan[n] T` allocates a buffered
channel value, `c <- v` sends, `<-c` receives.

`a?.f` is `a.f` when `a` is not nil and nil otherwise, and guards the
whole postfix chain after it (`a?.next?.name`, `a?.last()?.name`);
`a ?? b` is `a` unless it is nil. Both are sugar for a conditional
expression, so the result must be a type that can be nil (a ref,
string, array or list), and `a` is evaluated twice.

`c ? a : b` is the conditional expression, at the lowest precedence
and right-associative; the arms must have one type (a `nil` arm
takes the other's). It is distinct from the `?` that propagates an
error tag: `x?` alone, `x? a : b` a choice.

`(T1, T2)` is a tuple, assignable element by element (so a tuple
holding a `ref Addr.Line` may be returned as `(string, ref Addr)`).
Multi-valued functions return tuples;
destructure with `a, b := f()` or read the components as `t.t0`,
`t.t1`, which are the only component names.

`struct { x int; y int }` declares fields; a struct is a value type.
`ref T` is a pointer to a struct or a function; `ref T{...}` allocates.
Field access through a ref needs no explicit dereference; there is no
`*p` syntax. To copy a ref's value, build a literal from its fields.

`func(int) int` is a function value type, wherever it is written: a
variable, struct field, list or array element, channel or type
argument of that type holds a closure or a function value, `nil`
included, and is called like a function. Diagnostics print such a
type as `func(int): int`. A library function that takes a variable
number of arguments (`sys.print`) cannot be used as a value. A
module's type name (for example `Rand` after `import rand "rand"`) is
a type whose values are loaded modules.

`bool` is the type of `true`, `false`, comparisons and the logical
operators; `if` and `for` conditions and the operands of `&&`, `||`
and `!` want one (an `int` flag is still accepted there, for code
that predates the type). A `bool` converts to `int` implicitly, as 0
or 1, so `return n > 2` from a function declared to return `int`
still works and `%d` prints it; nothing converts to `bool` but a
comparison (`n != 0`), and `bool` takes part in no arithmetic.

Conversions are written like calls: `int(3.7)` (rounds to nearest),
`real(i)`, `big(x)`, `byte(n)` (wraps), `string(42)`, `int("17")`
(strtol semantics, `int("abc")` is 0), `[]byte(s)` (UTF-8 bytes) and
`string(b)` for a byte array. `string(c)` of an int is its decimal
form even when c holds a rune; a rune becomes a string through
`sys.sprint("%c", c)` or by appending it, `s[len(s)] = c`.
Conversions between scalar literals fold at compile time.

## Declarations and assignment

`x := e` declares a local from the expression's type. `var x T` and
`var x = e` also declare, at top level or in a function; a `var`
without initializer is zero each time the declaration executes (a
`var` inside a loop starts fresh every iteration). `const N = 4 * 2 + 1` declares a
constant; constant expressions of one type fold, and may refer to
earlier constants and size arrays (`[N]int`). A block `const ( Red =
iota; Green; Blue )` declares several: `iota` is the item's index
from zero, and an item with no expression repeats the previous one
(`KB = 1 << (10 * (iota + 1)); MB; GB`). `const` works inside a
function too.

A multi-valued call may be the last argument of another call, its
results filling the remaining parameters one each: `show(divmod(17,
5))`, `acc.add(three())`. `a, b := f()` and `a, b = f()` destructure a
tuple result; `a, b =
b, a` assigns an expression list, evaluated whole before any store.
`_` in any of these, or as a `range` binder, discards that value: `_,
r := divmod(a, b)`, `for _, v := range xs`. Each `_` is a fresh
hidden local, so it may be repeated and is never readable.
The compound assignments `+= -= *= /= %= &= |= ^= <<= >>=` and `++`,
`--` exist. A store target must be storage: a variable, a module
global, an array element, a string element (`s[i] = 'x'`, which copies
a shared string first), or a field reached through a ref or a
variable. Assigning to a constant, a call result, a function or a
type is an error.

A literal assigned to a variable it reads is safe: `l = ref Node{val:
v, next: l}` and `p = Point{x: p.y, y: p.x}` build the new value
before storing it.

## Expressions

The operators are the usual `+ - * / %`, `& | ^ << >>`, `== != < >
<= >=`, `&& || !`, unary `-` and `~`. Operands must have the same
type, except that a shift count is always an int. `+` concatenates
strings; strings compare by value and by order. `==` and `!=` apply to
scalars, strings, refs (identity), and to arrays, lists, channels and
modules against `nil`. They do not apply to struct or tuple values;
compare the fields. Ordering applies to numbers and strings only.

Integer division by zero does not fault on this host (arm64 returns
0); check divisors explicitly.

`len` works on arrays, strings and lists. `hd` and `tl` are call-style
builtins. `s[i]` indexes a string by rune.

## Statements

`if cond { } else if cond { } else { }` takes an optional init
statement: `if x := f(); x > 2 { ... }`. `for` has three forms: `for
{ }`, `for cond { }`, and `for init; cond; post { }`, where init and
post may be expression-list assignments (`for i, j := 0, 10; i < j;
i, j = i+1, j-1`). `for i, v := range xs { ... }` walks an array or
string with the index and the element (one name gives the index
alone), `for v := range l` a list's elements, and `for i := range n`
counts from 0 to n-1; the operand is evaluated once. `break` and
`continue` take an optional label
naming an enclosing loop or match.

`match` dispatches on an int, a string, or a pick value:

    match n {
    case 1, 2:
        ...
    case 3:
        ...
    default:
        ...
    }

Labels may be literals or named constants (`case Eid:`, `case
lex.Eid:`), or int ranges, `case 'a'...'z', 'A'...'Z':`. String
labels must be distinct; int labels may not overlap. There is no fall-through, and `continue` inside an arm
continues the enclosing loop. Matching a pick binds its fields:

    match e {
    case Expr.Num(v):
        return v
    case Expr.Bin(op, l, r):
        ...
    }

`alt` waits on several channel operations at once:

    alt {
    case v := <-a:
        ...
    case s = <-b:
        ...
    case <-c:
        ...
    case out <- value:
        ...
    default:
        ...
    }

A `default` makes it non-blocking. The channel expressions may be any
expressions (an array element, a call).

`spawn f(args)`, `spawn obj.method(args)` and `spawn func(k int) {
... }(i)` start a new process. `return` returns one value or an
expression list. A function with a result must return or `raise` on
every path: the last statement must be a `return`, a `raise`, an
`if` with an `else` both of which do, a `match` or `alt` with a
`default` all of whose arms do, or a `for` without a condition that
no `break` leaves. An `if` or `for` condition must be a `bool` or
an `int` flag; a string or ref is not a condition. `:=` may not redeclare a name already declared in the
same scope (a parameter counts as declared in the body's outermost
block), though an inner scope may shadow it. `raise expr` (a string) raises that error, the way a Limbo `raise`
does; a command uses `raise "fail:reason"` to exit unsuccessfully.
`exit()` ends the process at once from anywhere, Limbo's `exit`; a
function may end with it in place of a `return`.

`defer f(a, b)` records a call to run when the enclosing function
returns, by `return` or by reaching its end; deferred calls run last
first. The arguments are evaluated at the `defer`; the callee
expression (`c.close`, say) when the call runs. A `defer` in a loop
records one call per iteration. `raise`, `exit()` and VM faults do
not run deferred calls. `match` takes an initializer like `if`:
`match x := f(); x { ... }`.
Integer division or modulus by zero raises "zero divide", indexing
past an array or string "array bounds error", and using a nil ref
"dereference of nil", as in Limbo. An uncaught error ends the
process.

    try {
        n := parse(s)
        ...
    } catch e {
        sys.print("bad input: %s\n", e)
    }

`try` runs its block; a raise in it, or in any function it calls,
unwinds to the handler with the error string in `e` (a local of the
handler, string typed; `catch {` without a name is allowed). The
VM's own errors are caught the same way. A raise inside a handler
goes to the next enclosing `try`, which may be in a caller. A `try`
whose block and handler both return terminates.

## Functions, closures, generics, methods

Functions may return several values: `func count(name string) (ref
Stats, string)`. A trailing `xs ...T` parameter makes a function
variadic: inside, `xs` is a `[]T` holding the extra arguments, a
call packs them (`join(", ", "a", "b")`, or none), and `join(sep,
parts...)` passes an array through. A bare trailing `...` is Limbo's
untyped form, which `sys.print` uses. Function values are first class: `f :=
inc`, `apply(f, x)`, and closures `func(x int) int { return base + x
}`, which may be called at once, returned, or spawned.

Closures capture by reference: a variable that any closure uses is
shared between the enclosing function and every closure that
captures it, so `n++` inside a closure changes the `n` outside, and
an assignment outside is seen by the closure after it was created.
(The compiler moves such a variable into a heap cell at its
declaration; a variable no closure captures stays in the frame.) A
variable declared inside a loop body is fresh each iteration, so
closures made in the loop each keep their own; the variable of a
three-part `for` header is one variable for the whole loop, as in Go
before 1.22. Calling an element of an array of functions, `fs[i](x)`,
works as expected.

Generic functions and types take type parameters in brackets: `func
first[T](xs []T) T`, `type Pair[T] struct { a T; b T }`. Type
arguments are inferred at call sites from the argument types,
including for higher-order functions such as `mapa[T, U](xs []T, f
func(T) U) []U`. A generic struct may refer to itself (`type Node[T]
struct { val T; next ref Node[T] }`) and a generic function or
method may call itself (`tests/type/genlist.e`). A type argument
may be any type, in a declaration or in an expression
(`Box[func(int) int]{val: f}`, `Box[[]int]{...}`, `Box[ref P]{...}`);
every mention of an instantiation names the same instance, however
the argument is spelled. Inference from a tag value (`ok(ref
Option[int].Some{v: 5})`) binds the parameter to the pick, `ref
Option[int]`.

Methods are declared with a receiver: `func (p ref Point) norm() int`
or `func (p Point) sum() int`. A value receiver gets a copy. Methods
are called as `p.norm()` and may be spawned; a method is not a value
(`g := p.norm` is an error; wrap it in a closure).

## Structs and picks

    type Point struct {
        x int
        y int
    }

    p := Point{x: 1, y: 2}
    q := Point{y: 5}
    r := ref Point{x: 3, y: 4}

Literals are keyed; unset fields are zero. A literal may appear
anywhere a value may: as an argument, nested in another literal, or
with a field read directly off it (`Point{x: 8, y: 9}.x`). Fields may
be read directly off a call result (`mkpoint().x`, `mkref().y`) and
off array elements (`ps[i].name`).

A pick is a tagged union:

    type Expr pick {
        Num(val int)
        Neg(e ref Expr)
        Bin(op int, l ref Expr, r ref Expr)
    }

    e := ref Expr.Bin{op: '+', l: a, r: b}

Tags are constructed as `Type.Tag{...}` (value) or `ref Type.Tag{...}`
and taken apart with `match`. Fields declared before the tags belong
to every tag, laid out first, and are reachable through the pick
reference without matching (`c.line` on a `ref Cmd`); several tags may
share one field list, `Branch, Label(lab string)`, and field-less
tags may be grouped, `Delete, Quit()`:

    type Cmd pick {
        line int
        Print()
        Delete, Quit()
        Subst(from string, to string)
        Branch, Label(lab string)
    }

Binders in a pattern name the tag's own fields only. The `?` postfix propagates an error tag
out of the enclosing function. A pick may be generic (`type Result[T]
pick { Ok(v T); Err(msg string) }`): its tags are named through the
instantiation, `ref Result[int].Ok{v: 3}` and `case
Result[int].Err(m):` (`tests/type/genpick.e`). A pick has no size of its own, only
each tag does, so the pick type exists only behind a `ref`: a
variable, field, parameter or element of type `Expr` (rather than
`ref Expr`) is an error, as in Limbo. A specific tag's value type
(`Expr.Num`) has a size and may be used by value.

## Interface types

    type Shape interface {
        area() int
        name() string
    }

A value of an interface type holds any `ref` to a struct or pick
whose methods include the interface's, with the same signatures; the
check is structural and happens where the value is assigned, passed,
returned or put in a literal. Calls go through it (`s.area()`), `nil`
is its zero value, and a pick's tags convert as the pick. Under the
covers the interface is a struct of method closures and a hidden
generic converter the parser writes (`.Shape$from[T]`), so a
conversion allocates once and a call through the interface is a
call of a field. There is no type assertion back to the concrete
type. An interface declared in a `.ei` file works across modules.

## Unit tests

A file of `func test_xxx()` functions, each checking with
`expect(cond, "what")`, is a unit test: `ember -t file.e` adds an
`init` that runs every `test_` function in order, reports each
failure as `FAIL test_xxx: expect: what` and carries on, then prints
`PASS n tests` or ends with `raise "fail:tests"`. `expect` is a
builtin unless the program declares its own. `tests/unit/*_test.e`
with their `.out` files are run by `tests/unittest.sh`.

## Formatting

`ember -F file.e` prints the file formatted: tabs for indentation,
one statement per line, canonical spacing around operators, and the
comments and blank lines of the original kept where they were. It
works from the parse tree alone, so it needs no interfaces to be
present, and every construct prints back as written, including
`defer`, `?.`, `??`, `match` initializers and const blocks.
`tests/fmt.sh` formats every test and translation and checks that
the result compiles to the same code and formats to itself.

## Deriving an interface file

`ember -i file.e` prints the module's interface file: its imports,
constants, types (an interface type as declared, a pick with its
tags, a struct with its methods' signatures), variables and function
signatures, in source order. Generic and inline declarations are
left out with a comment, since an interface must carry their bodies;
write those by hand. `tests/gen/` holds sources with their expected
output, checked by `tests/ifacegen.sh`.

## Interfaces and separate compilation

A module's interface is an `.ei` file: Ember syntax with signatures
only.

    module Bufio

    import sys "sys"

    const PATH = "/dis/lib/bufio.dis"
    const OREAD = 0
    const EOF = -1

    type Iobuf struct {
        fd ref sys.FD
        buffer []byte
        ...
    }

    func (b ref Iobuf) gets(sep int) string
    func open(name string, mode int) ref Iobuf

An interface may import other interfaces and name their types as
`alias.Type`; it may declare constants (expressions of literals and
of the interface's earlier constants fold: `const Degree = Pi /
180.0`), struct and pick types, functions and methods.

Interfaces describe both Ember-compiled and Limbo-compiled modules:
`module/sys.ei`, `math.ei`, `rand.ei`, `hash.ei`, `string.ei` and
`bufio.ei` describe the real Inferno libraries, and programs using them run
against the Limbo-compiled `.dis` files. The link signatures Ember
computes match Limbo's, so a mismatch between an interface and the
module it describes is refused at load time (`link typecheck
Module->fn()`) rather than miscalled. Every field of an adt is part
of the signature of each function that mentions it, so an interface
for a Limbo module must list the adt's fields exactly, in order.

`load` loads a module explicitly:

    r := load Rand "/dis/lib/rand.dis"
    if r == nil { ... }
    r.init(42)

The result is a value of the module type, usable as a local, a
parameter, or assigned back to the import alias; an import used only
through `load` is not loaded automatically at start.

An Ember library is just a module without `init` compiled to a
`.dis`, with a hand-written `.ei` naming its `PATH`; the tests use
`tests/type/libpoint.e` and `libpoint.ei` this way, including a pick
and methods used from the client (`libpoint.Shape.Circle{...}`).

An interface may also declare variables (`var count int`), and a
client reads and writes them through the alias: `lib.count++`,
`lib.origin.y = 5`. This works when the interface is the module's
own declaration, as a Limbo implementation includes its `.m`: when
the compiler finds `<module>.ei` (the module name in lower case)
beside the source file or on the include path, every variable that
file declares must exist in the module with the same type, or the
compile fails, and exactly those variables are exported, laid out
first in the module's data in the interface's name-sorted order, so
an importer addresses them through the module link. The link
signature of that record is checked at load time like any
function's. Variables the interface omits stay private. Interfaces
for Limbo modules should not declare variables. `tests/type/libvars.e`
and `modvars.e` show the pattern.

A generic function is instantiated from its body at compile time,
so an interface that declares one carries the body, as a C++ header
does, and every importer instantiates it for itself: `gen.mapa(xs,
f)` or `gen.reduce[int, int](xs, 0, f)` compiles the instance into
the importing module (no link entry is involved). A template body
sees its own module's types, constants and functions by name (calls
to the plain ones go through the alias); anything it uses from
another module, such as `sys`, must be imported by the user too.
A generic struct or pick declared in an interface is a template the
same way: `gen.Pair[int, string]{a: 1, b: "one"}`, `var r
gen.Pair[string, int]`, `case gen.Opt[int].Some(v):`, and so is a
method of such a type (`func (m ref Map[K, V]) put(k K, v V) {...}`),
instantiated with the type: `m.put(k, v)`. A plain function with
its body in an interface is inline the same way: each importer gets
its own copy, called or taken as a value (`maps.strhash`), and no
link entry exists for it. A method with type parameters of its own
cannot be declared anywhere, and only a generic type's method may
carry a body in an interface. `tests/type/libgen.ei` and `usegen.e`
show the pattern.
A template call does not reference the module, so an interface made
only of templates is a header-only library needing no `.dis` at
all: `module/lists.ei` (`lists.mapl`, `lists.filter`, `lists.foldl`,
`lists.sorta`, ...) is one, used by `tests/type/uselists.e`, and
`module/maps.ei` is a generic hash map (`maps.newmap[string, int](n,
hash, eq)`, then `m.put`, `m.find`, `m.del`, `m.keys`) whose
key hashing and equality are closures the importer supplies, with
`maps.strhash`, `maps.streq`, `maps.inthash` and `maps.inteq`
provided inline (`tests/type/usemaps.e`); `module/strings.ei` is a
set of inline string utilities (`strings.split`, `join`, `trim`,
`fields`, `index`, `hasprefix`, `tolower`, `atoi`, ...)
(`tests/type/usestrings.e`).
When the module's own interface is found, its functions and methods
are checked the same way: one the module does not define, or defines
with a different signature, is a compile error (generic functions
are not compared), so a stale interface is caught before load time.

## Things to know

Every module that imports another gets its own instance of it, with
its own copy of the imported module's variables (Limbo's model). A
module whose state must be shared, such as the compiler's types
module, is handed down explicitly: assign the caller's module value
to the import alias (`types = t` inside a `usetypes(t Types)`
function) and forward it to further importers.

A process left blocked on an unbuffered channel keeps the emulator
alive after `init` returns; drain or buffer such channels in tests.
`sys.file2chan` needs a directory served by the srv device: bind
`#s` somewhere first (`tests/type/fileserver.e`). A tuple literal
with `nil` components (`rc <- (nil, nil)`, `return nil, err`) takes
the tuple type expected where it is used.
`pick`, `alt`, `match`, `load`, `spawn`, `chan`, `list`, `ref` and
`interface` are keywords. `bufio`'s `gett` returns the terminator with
the token. The compiler stops after twenty errors.

## The self-hosted compiler

`appl/cmd/ember/` holds the compiler written in Ember itself, built
with the C bootstrap by `mk install` there (into `dis/ember`). It is
complete: the lexer (`lex.e`), the parser (`parse.e`), the shared
data structures and types code (`types.e`), constant folding
(`fold.e`), the interface reader (`iface.e`), the type checker
(`check.e`), the code generator (`com.e`, lowering; `gen.e`,
instruction assembly and the opcode tables; `disw.e`, the `.dis`
writer) and the driver `emberc.e`, each with an interface, plus dump
drivers `lexdump.e`, `astdump.e` and `chkdump.e`.

    emu-g -r $ROOT -c0 /dis/ember/emberc.dis [-I dir] [-o out.dis] file.e

compiles a file inside the emulator exactly as `ember` does on the
host. `ember -T`, `-A` and `-C` print the C compiler's token stream,
syntax tree and checked tree (every node with its type) in the same
formats as the dump drivers, and `tests/lexcmp.sh`, `astcmp.sh` and
`chkcmp.sh` check that the Ember and C versions agree on every source
file in the tree, diagnostics included; `tests/discmp.sh` checks that
`emberc.dis` writes a byte-identical `.dis` file for every one of them
(only the trailing source path differs, and is stripped). All four are
part of `mk test`.

Because every importer gets its own instance of an imported module,
the driver hands its `types` and `check` instances down (`usetypes`,
`usecheck`) so that the whole pipeline shares one set of basic types,
descriptors and declarations. The instruction and operand structures
live in `types.e` because a function declaration points at its first
instruction.

## Tests

`tests/type/*.e` must compile; those with a `.out` golden are also
run and compared. `tests/typeerr/*.e` must fail to typecheck with the
diagnostics in the matching `.err` file, never with a compiler
fatal. `tests/err/*.e` must fail to parse. `tests/run.sh` and
`tests/runtime.sh` are the runners; `mk test` runs both, then the
four C-versus-Ember comparisons (`lexcmp.sh`, `astcmp.sh`,
`chkcmp.sh`, `discmp.sh`) and `bootstrap.sh`, which has the
self-hosted compiler compile itself and that compiler compile the
sources again, requiring identical bytes; then `ifacegen.sh` (the
`-i` goldens) and `unittest.sh` (the `-t` unit tests). Last, `limbocmp.sh` runs
the Limbo commands translated into Ember in `limbo/` (`cat`, `freq`,
`cmp`, `uniq`, `comm`, `sort`, `echo`, `seq`, `wc`, `tr`, `fmt`,
`grep`, `tsort`, `strings`, `xargs`, `md5sum`, `uuencode`,
`uudecode`, `sed`) against their originals in `appl/cmd/`, both compiled
with their own compiler, on every argument line in the matching
`.cases` file (`args < file` feeds a file to standard input); every
run must print the same thing. The script builds the Limbo libraries
the programs load (`dis/` is not in git) with `limbo` from the same
`bin` directory as `emu-g`. The translations are also in the four
comparison scripts' file lists. `doc/ember-vs-limbo.md` is what the
translations showed.
