# Where Limbo is verbose, and the Ember idiom

A survey of the Limbo in this tree (316 files, 105,000 lines under
`appl/cmd` and `appl/lib`) for the patterns that take the most lines
or the most attention, with the Ember form that replaces each now
that the modern-language plan is built. The counts are grep counts
over that corpus, so they are approximate; the point is which
patterns are everywhere.

| pattern in Limbo                                  | count | Ember                              |
|---------------------------------------------------|------:|------------------------------------|
| `x = load M M->PATH;` then `if(x == nil) ...`      | 958 loads, 316 checks | `import m "m"`     |
| `while((s := f()) != nil)` / `if((x := f()) != nil)` | 217 / 174 | `for s := f(); s != nil; s = f()`, `if x := f(); x != nil` |
| `for(; l != nil; l = tl l)` list walks            | 457   | `for x := range l`, `for i, x := range l` |
| `for(i := 0; i < len a; i++)` index loops         | 434   | `for i, v := range a`              |
| `(nil, x) := f()` dropping a result               | 989   | `_, x := f()`                      |
| `ref T(a, b, c)` positional adt literals          | 747   | `ref T{a: .., b: .., c: ..}`       |
| module-typed variables used as callbacks          | 453   | function values and closures       |
| `raise "fail:x"` after an `fprint`                | 266   | the same, or `exit()`; `expect` in tests |
| `exit;`                                           | 168   | `exit()`                           |
| `s[len s] = c` string building                    | 169   | the same (it is the idiom)         |
| `b[0:] = a` / `b[len a:] = a` array growing       | 162   | `append(a, x)`, `copy(b, a)`       |
| `sys->sprint` fed to `puts`                       | 67    | the same                           |
| `con iota` constant runs                          | 52    | `const ( A = iota; B; C )`         |
| `case 'a' to 'z' =>`                              | 44    | `case 'a'...'z':`                  |
| hand-rolled hash tables (files)                   | 39    | `map[K]V`                          |
| `pick` adts                                       | 5     | `pick` with common fields, matched with binders |

## What each looks like

The module preamble. Every Limbo command opens with ten to twenty
lines of `include`, module variables, `load`s and nil checks, and
the tree has 958 loads with only 316 of them checked; the unchecked
ones fault later with "module not loaded" if the file is missing.
Ember's `import` is one line, checked at link time, and the failure
names the module.

Loops. Limbo has no `for` over a collection, so a list walk is
`for(; l != nil; l = tl l)` with `hd l` inside, 457 times, and an
array walk is the three-part index loop, 434 times. Ember's `range`
covers arrays, strings, lists, maps and counts, with `_` for the
part not wanted.

Dropping results. Limbo's `(nil, x) := f()` appears 989 times, most
often `(nil, fields) := sys->tokenize(...)`. Ember's `_` reads the
same but is one character and never a declared name.

Literals. `ref Sedcom.S(ad1, ad2, negfl, 0, gfl, pfl, re, b, rhs)`
gives nine arguments by position; the reader has to know the adt.
Ember's keyed literal names them and leaves out the zero ones.

Callbacks. Limbo passes behaviour as a module reference (453
module-typed variables in the commands alone): to sort with a
comparison or apply a function, one writes a module. Ember passes a
function value or a closure, and the closure may keep state.

Hash tables. Thirty-nine files carry their own bucket arrays and
hash functions (`tcl_strhash.b`, `tcl_inthash.b`, `keyset.b`,
`tables.b`, `readdir.b`'s sort by name, and so on), and tsort.b
walks a linked list on every lookup with a comment saying a hash
table would do for larger inputs. Ember's `map[K]V` is a literal
away.

Growing arrays. `b := array[len a + Incr] of string; b[0:] = a; a =
b` is the shape 162 times; Ember's `append` is one call, and for
long arrays a list built with `::` and converted once.

Constants and cases. `con iota` runs (52) become const blocks; `'a'
to 'z'` labels (44) become ranges.

## Two translations done again the idiomatic way

`ember/limbo/tsort2.e` and `wc2.e` are tsort and wc written with the
new features rather than line for line; the differential harness
checks them against the originals like any other translation (a
`NAME.orig` file names the original).

tsort2 keeps the items in a `map[string]ref Item` instead of a
linked list searched on every lookup, the input order in an array
grown with `append`, flushes its output with a `defer`, and walks
every list with `range`. It is 94 lines against tsort.b's 115 and
the line-for-line translation's 112, and it is faster on large
inputs, which the original's own comment asks for.

wc2 has a `bool` per flag, one const block with `iota` for the
sixteen action codes, `range` over the option letters and the
buffer, the conditional expression for the report line, and
`exit()` where the original exits. The state tables are the bulk of
both versions; the rest shrank from 52 to 39 lines.

sed2 is sed with one `Sedcom` pick carrying the four fields every
command shares (as sed.b's adt does), tag groups for the thirteen
field-less commands, keyed literals in place of the `mk()` helper,
`case '0'...'9':`, a `map[string]list ref Sedcom` from each label to
the commands that follow it instead of a scan of the list on every
branch, and range loops. It is 924 lines against the line-for-line
translation's 954 and sed.b's 835; the pick declaration alone went
from 27 lines to 12.

## What the survey says the next features should be

The assignment-in-condition loop (`while((s := f()) != nil)`, 217
occurrences) is the one Limbo form that still reads better than the
Ember spelling; the three-part `for` with a repeated call is the
Go answer, and a `for s := f(); s != nil` sugar that repeats the
initializer as the post statement is the obvious next step.

Everything else the survey found is covered. What the corpus does
not exercise, because Limbo could not, is the new territory: closures
that hold state, interfaces, defer, and maps; the idiomatic rewrites
above are the first Ember written that way, and the next programs
should be new rather than translated.

## What the corpus asks for that the survey missed

The survey counted forms Limbo has. Writing new programs found the
ones it does not, and each is now in the language:

An enum is a named type and a typed const block, with its printing on
the type rather than in a `case` somewhere:

    type Level int

    const (
        Low Level = iota
        Mid
        High
    )

    func (l Level) label() string { ... }

Limbo spells this as a `con` run plus a free function taking an int,
and nothing keeps the two together; the Ember form cannot be passed a
plain int by mistake.

A struct that extends another embeds it, rather than repeating its
fields and forwarding its methods by hand:

    type Mid struct {
        ref Base
        kind int
    }

Two results with names read better than a tuple whose components a
comment explains:

    func divmod(a int, b int) (q int, r int)

Building a string a piece at a time is `s += "..."` on 162 lines of
`appl/cmd` and `appl/lib`, and 393 lines in `appl/cmd` append to a
string or an array with `+=` of any kind; each one inside a loop is
quadratic. `Builder` in the builtin library makes it linear without
changing how the loop reads. Eight commands there mention sorting
(`sort.b`, `tsort.b`, `diff.b`, `ls.b`, `cook.b`, `dossrv.b`,
`ttffs.b`, `yacc.b`), each with its own comparison plumbing;
`sort(a, cmp)` is now builtin.

A callback is a method value where Limbo needs a free function and
the receiver passed alongside it: `w.write` rather than `wwrite(w, s)`.

`ember/limbo/bytes.e` is a plain translation rather than an idiomatic
rewrite -- `appl/cmd/bytes.b` line for line, debug prints and all, so
the differential can check it -- and the only changes the language
forced were `len(x)` and `hd(l)`/`tl(l)` written as calls, `0x` for
`16r`, `copy(dst, src)` for a slice assignment, and `match` with
comma-separated and `...` case labels for Limbo's `or` and `to`.

`ember/limbo/sort2.e` is the first of these written out: `sort.b`'s
two hand-written merge sorts (25 lines each, one for text and one
for numbers) become the builtin `sort` with a comparison closure, the
input loop moves into a function returning the array, and the output
goes through a `Builder`. 105 lines against the line-for-line
translation's 135, and `sort.b`'s own 129.
