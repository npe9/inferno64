# Ember beside Limbo

Nineteen of Inferno's commands, translated line for line from Limbo
into Ember and run against the originals on the same inputs. The
point was to find out whether Ember is a better way to write the same
program, and what a real program needs that the language did not
have. The translations are in `ember/limbo/`, the originals in
`appl/cmd/`, and `ember/tests/limbocmp.sh` (part of `mk test`)
compiles each pair with its own compiler and checks that every
argument line in `NAME.cases` prints the same thing under both,
error paths included (missing files, bad flags, seeks past the end,
ambiguous translations). All 90 runs agree.

## Size

Non-blank lines, Limbo first:

| program | Limbo | Ember | what it exercises                        |
|---------|------:|------:|------------------------------------------|
| cat     | 42    | 42    | sys, raise                               |
| freq    | 98    | 102   | bufio, big counters, range               |
| cmp     | 135   | 140   | bool flags, seek, byte slices            |
| uniq    | 71    | 71    | bufio lines                              |
| comm    | 108   | 128   | global array literal, exit               |
| sort    | 119   | 126   | slice assignment, string compare         |
| echo    | 33    | 31    | string append, write                     |
| seq     | 92    | 62    | reals, function values                   |
| wc      | 294   | 346   | 256-entry tables, byte state machine     |
| tr      | 291   | 366   | struct with methods, bit sets, globals   |
| fmt     | 186   | 192   | chan, spawn, tuple return, struct        |
| grep    | 136   | 124   | regex library through a new interface    |
| tsort   | 115   | 112   | self-referential structs, methods, lists |
| strings | 78    | 80    | string as a buffer, big offsets          |
| xargs   | 78    | 72    | `load` of a command at run time, generic |
| md5sum  | 58    | 59    | keyring digests                          |
| uuencode| 90    | 98    | fstat, byte arithmetic                   |
| uudecode| 123   | 145   | blank identifier, create, wstat          |
| sed     | 835   | 954   | two picks, labels, hold space, regex     |

Ember is shorter about as often as not, and never by much either
way (the table is after `exit()` and `_` were added; before them comm
was 134 lines and uudecode 146). The Go brace style costs a line for every
`else` and every one-statement `if` body that Limbo writes without
braces; a `case` arm that Limbo writes on one line (`'l' => pline++;`)
takes two; and Limbo's `while((s := bio.gets('\n')) != nil)` becomes
a `for` with a `break` inside, three lines for one. tr has a dozen of
those loops and wc has sixteen one-line arms, which is the whole of
their growth. The other way, a Limbo program spends ten to twenty
lines on `include`, `load` and nil-checking each module before it can
start, and Ember's `import` does that in one line per module, which
is where cat, uniq, echo and seq make the difference back.

## What reads better in Ember

The module preamble. `import bufio "bufio"` replaces an `include`, a
module variable, a `load` with a path constant, a nil test that
prints an error and raises, and an `Iobuf: import bufio` for the
type. Every one of the originals has this boilerplate; they get it
subtly different (freq never checks the load, sort and uniq report it
two ways, seq raises a bare string).

Flags. cmp's `lflag := 0` and `if(lflag)` are `lflag := false` and
`if lflag`; the compiler refuses `if n` on an int, which caught
nothing here but makes the intent visible. fmt's `join := 1` and
`bol` field are bools too.

Loops over data. freq's `for(; args != nil; args = tl args)` and
`for(i = 0; i < len count/4; i++)` are `for name := range args` and
`for i := range len(count) / 4`. cmp's inner byte loop is `for i :=
range n`, tr's table clear is `for i := range f`.

Types with methods. tr's `Pcb` adt with `getc`, `canon` and `rewind`
is a struct with three methods, declared on the receiver rather than
listed inside the type; the calls are the same. Its `Pcb.new`
constructor is a plain function returning a keyed literal, since
Ember has no static methods.

Match. Limbo's `case opt { 'u' => ...; * => ... }` is `match opt {
case 'u': ...; default: ... }`, the same shape. fmt's `'w' or 'l'` is
`case 'w', 'l':`. comm's `'1' to '3'` range label became `'1', '2',
'3'`; Ember has no range labels.

Multiple returns. fmt's `(line, ind) = indentof(line)` is `line, ind
= indentof(line)`, and the function returns `line, ind` without the
parentheses.

Concurrency. fmt's `words := chan of ref Word`, `spawn parser(f,
words)`, `words <-= w` and `<-words` are `chan ref Word`, `spawn
parser(f, words)`, `words <- w` and `<-words`: identical in shape,
and the spawned parser and the printer ran in lockstep with the
original on every case.

## What the translations forced into the language

`copy(dst, src)`. sort's merge step is `b[0:] = a[0:r]` and `a[k:] =
b[i:m]`: Limbo's slice assignment, a single Dis `slicela`. Ember had
slicing as an rvalue only. Adding it as Go's `copy` builtin was
small, but its first codegen was wrong in a way the unit test did not
see: the immediate 0 was emitted as `0(fp)`, the frame's return
link, which is zero in `init` and a code address everywhere else, so
the builtin worked in the test and faulted in sort. The differential
test found it on the first run; the unit test now copies inside a
helper too.

Global bools. tr's `cflag := 0` at file scope became `var cflag =
false`, and the compiler died with "can't dis global type bool": the
data-section writer had a case for every scalar but the newest one.
Two lines in each compiler, and `tests/type/boolglobal.e`.

The blank identifier. uudecode's `(mode, nil) = str->toint(s, 8)`
is Limbo's way of dropping a tuple element, and Ember had no way at
all: every name on the left of `:=` or `=` was a real variable.
`_` now works in both, and as a `range` binder, as a fresh hidden
local per use, so `_, r := divmod(a, b)` and `for _, v := range xs`
read as they do in Go.

Standard input in the harness. tr and fmt are filters, so
`NAME.cases` grew an `args < file` form; the emulator's console is
its own standard input, so the file simply becomes the emulator's.

Tuples of tags. sed's `address()` returns `(string, ref Addr)` and
builds `(s[1:], ref Addr.Dollar())`; Ember widened a lone `ref
Addr.Dollar` to `ref Addr` but not one inside a tuple, since tuple
assignability was whole-type equality. It is now element by element
in both compilers (`tests/type/tuplepick.e`).

Interfaces for two more Limbo modules. grep wanted `regex.ei`, whose
three adts had to be declared field for field as `regex.m` has them,
since every function signature is computed over them; the
signatures were checked equal by dumping both compilers' signature
strings (`o.out -D fn`, `limbo -D S`). xargs wanted `command.ei`,
the `Command` module type every Inferno program implements, so that
`sh := load command cmd` can load and run one by path.

Nothing else. Everything the other programs needed was there: bufio
through a hand-written interface, `arg` through a new eight-line
`arg.ei`, `big` counters, reals and `%g`, function values (`printer
:= iprint`, later `printer = rprint`), `raise "fail:..."`, string
comparison with `<` and `>`, `int(s)` and `real(s)` parsing, slicing
a string, `~` on a byte, `sys.Runemax`.

## What Limbo has that Ember does not, seen from these programs

`exit()`. comm's `copy()` (renamed `copyrest`, since `copy` is now a
builtin and builtins are resolved by name before user functions)
ends the program from three levels down; seq, wc and strings end
`init` with `exit`; uuencode's and uudecode's `fatal()` exit after
printing; sed's `q` command exits from inside `command()`. The first
translations replaced these with chains of returns and quit flags,
which made comm a quarter longer and sed's command loop carry a flag.
`exit()` is now a builtin (one Dis instruction, and the checker
knows a function may end with it), and the eight programs use it
where their originals do.

Module variables in an interface. uudecode reads `sys->nulldir`, a
variable of the Sys module; Ember interfaces for Limbo modules
declare functions, constants and types only, so the translation
builds the same all-ones Dir itself.

Assignment as an expression, with the declaring form `(s := f()) !=
nil` inside a loop condition. The Go idiom `for s := f(); s != nil; s
= f()` covers most of it; Ember has the `for` but the translations
kept the `break` form to stay line for line. This is the one place
the translation is worse every time, and tr shows it twelve times.

`++p.last` as a value. tr's `return ++p.last` is two statements.

Range labels in `case`. Rare; a comma list did the job.

Tuple declaration in a `for` header, `for((i, j, k) := (0, m, 0);
...)`. Ember declares the three before the loop; Go would too.

Static methods on a type (`Pcb.new`). A function does the job.

`con byte iota`. wc's sixteen action codes are bytes in Limbo so its
tables can be arrays of byte; Ember has `const` but no `iota`, so
they are sixteen numbered int constants and the tables are `[256]int`.

`array[3] of {...}` at file scope: Ember's `var ldr = [3]string{"",
"\t", "\t\t"}` works, so this is not a gap, only a note that the
global-initialiser path had not been exercised with a literal before;
wc's four 256-entry tables and tr's `bits` went through it after.

## What Ember has that these programs could not use

Closures with captured values, `try`/`catch`, and the header-only
libraries. Only xargs's `reverse[T]` used a generic, and that is
Limbo's own; sed's two picks are matched with binders throughout.
None of the nineteen
commands is the kind of program that wants closures: they are filters
written in 1990s C style and translated faithfully into Limbo in the
2000s. A program that keeps state in closures would have to be
written fresh rather than translated.
