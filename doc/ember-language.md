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
the int). Character literals such as `'a'` and `'\n'` are ints.

`[]T` is an array. `[n]T` allocates a zero-filled array of `n`
elements, where `n` may be a runtime value; `[3]int{1, 2, 3}` is a
literal, `[3]int{}` is zero-filled. Arrays are shared by reference,
indexed with `a[i]`, sliced with `a[lo:hi]`, `a[lo:]` and `a[:hi]`,
and measured with `len(a)`. A two-dimensional array is an array of
arrays: `[3][]int`, then `grid[i] = [4]int`.

`list T` is a list: `1 :: 2 :: nil`, with `hd(l)`, `tl(l)` and
`len(l)`. `chan T` is a channel; `chan[n] T` allocates a buffered
channel value, `c <- v` sends, `<-c` receives.

`(T1, T2)` is a tuple. Multi-valued functions return tuples;
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

Conversions are written like calls: `int(3.7)` (rounds to nearest),
`real(i)`, `big(x)`, `byte(n)` (wraps), `string(42)`, `int("17")`
(strtol semantics, `int("abc")` is 0), `[]byte(s)` (UTF-8 bytes) and
`string(b)` for a byte array. Conversions between scalar literals
fold at compile time.

## Declarations and assignment

`x := e` declares a local from the expression's type. `var x T` and
`var x = e` also declare, at top level or in a function; a `var`
without initializer is zero each time the declaration executes (a
`var` inside a loop starts fresh every iteration). `const N = 4 * 2 + 1` declares a
constant; constant expressions of one type fold, and may refer to
earlier constants and size arrays (`[N]int`).

A multi-valued call may be the last argument of another call, its
results filling the remaining parameters one each: `show(divmod(17,
5))`, `acc.add(three())`. `a, b := f()` and `a, b = f()` destructure a
tuple result; `a, b =
b, a` assigns an expression list, evaluated whole before any store.
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
i, j = i+1, j-1`). `break` and `continue` take an optional label
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
lex.Eid:`). String labels must be distinct; int labels may not
overlap. There is no fall-through, and `continue` inside an arm
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
expression list. `raise expr` (a string) ends the process with that
error, the way a Limbo `raise` does; there is no catch, and a command
uses `raise "fail:reason"` to exit unsuccessfully.

## Functions, closures, generics, methods

Functions may return several values: `func count(name string) (ref
Stats, string)`. A trailing `...` parameter makes a function
variadic; `sys.print` is one. Function values are first class: `f :=
inc`, `apply(f, x)`, and closures `func(x int) int { return base + x
}`, which may be called at once, returned, or spawned.

Closures capture by value. `count++` inside a closure changes the
closure's copy, not the outer variable; to share state, capture a
ref and mutate through it.

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
and taken apart with `match`. The `?` postfix propagates an error tag
out of the enclosing function. A pick may be generic (`type Result[T]
pick { Ok(v T); Err(msg string) }`): its tags are named through the
instantiation, `ref Result[int].Ok{v: 3}` and `case
Result[int].Err(m):` (`tests/type/genpick.e`). A pick has no size of its own, only
each tag does, so the pick type exists only behind a `ref`: a
variable, field, parameter or element of type `Expr` (rather than
`ref Expr`) is an error, as in Limbo. A specific tag's value type
(`Expr.Num`) has a size and may be used by value.

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
sources again, requiring identical bytes.
