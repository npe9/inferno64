# Inferno as a Plan 9 terminal personality: a plan

Written 2026-08-27, after being asked to audit the existing `p9/cmd/`
Limbo-translation backlog against a much bigger, previously undocumented
goal: **Inferno should be able to act as a Plan 9 terminal - the role
`drawterm` plays for non-Plan-9 hosts - and go further than `drawterm`
does, by being able to compile a real Plan 9 source tree from inside
itself, using Limbo-native tools running under Dis/`emu`, not host
binaries.** `doc/plan9-port.md`'s own closed backlog (21 command-line
utilities, individually translated and tested) never claimed to be this,
and auditing it against this bar found real, substantial gaps - but also
real, substantial existing assets nobody had credited yet. Both are
below, checked directly against this tree as it stands today, not
recalled.

## The three separable pieces, and what's real about each

This goal splits into three genuinely independent projects. They don't
block each other's *value* - each is separately useful even if the
other two never happen - but two of them share a real, checked
dependency (below).

### 1. Protocol/auth/namespace interoperability - smallest in code, blocked on a test target

**More already exists than the earlier audit credited.** `module/styx.m`
- Inferno's own native mount protocol module, used by `mount()`,
`import`, `cpu`, everything - declares `VERSION: con "9P2000"` and
defines the identical message set to real Plan 9's wire protocol
(`Tversion`..`Rwstat`, the same tag numbering, the same `STATFIXLEN`
fixed-length stat layout). This is not a look-alike sharing a name by
coincidence; it is structurally the real thing. `appl/cmd/auth/factotum/
proto/p9any.b` is a real implementation of Plan 9's own `p9any` auth
negotiation. `appl/cmd/import.b`, `appl/cmd/9export.b`, `appl/cmd/cpu.b`
are real dial-auth-mount machinery, the same shape as `drawterm`'s job.

**What's unverified, and is the actual crux question:** `import.b` dials
a remote host's own `exportfs` service and layers Inferno-specific
framing (`impo nofilter clear/ssl`) on top of the raw dial - it does not
connect bare to a real Plan 9 cpu-server listener. Whether any of this
stack - `styx.m`'s 9P2000 encoding, `p9any`'s negotiation, `cpu.b`'s
session setup - can actually complete a handshake with an unmodified
Plan 9 or 9front box has never been tested in this tree. There is no
evidence either way; this is a real unknown, not a known-working thing
described unclearly.

**Correction to an earlier pass of this audit: `9front/` is not
headers-only.** An initial listing sampled only the first 20 of 195
files and happened to land entirely inside `include/`, which was then
wrongly generalized. The real listing (`find 9front -type f -not -path
'*/include/*'`) shows a full compiled amd64 library set - real `ar`
archives for `libc`, `libbio`, `libauth`, `lib9p`, `libthread`,
`libdraw`, and about thirty more, plus **two real binaries**:
`9front/amd64/9pc64` and `9front/amd64/bin/auth/factotum` (a genuine
compiled factotum). This is a substantially more complete build than
"headers-only" claimed, and that claim should not have been written
without checking past the first page of results.

**But it is not neutral, stock 9front either - it's a different, parallel
effort's own variant, and that matters for what it can answer.** The same
library set includes `libosprey.a` and `lib9front.a` alongside the
standard libraries, and `os/pc64/9front/` (Codex's own native kernel
work, not this plan's territory, not touched here) sits next to compiled
objects named `osprey.6`, `osprey-core.6`, `osprey-process.6`,
`osprey-queue.6`, `osprey-edf.6` - consistent with the Osprey microkernel
work tracked elsewhere in this project's memory, not a vanilla upstream
9front build. That reframes the open question: it isn't just "is
`9pc64` bootable," it's **"is this a stock 9front whose behavior matches
real Plan 9 servers, or an Osprey-personality build that may differ from
one in exactly the ways this plan needs to test" - and separately,
whether it runs a `cpu` or `exportfs` listener at all** (a kernel image
and a factotum binary don't by themselves imply a running, dialable
service). Both questions should be answered by whoever owns that work,
not assumed from a file listing.

### 2. `rc` in Limbo - not a from-scratch design, a real translation, and the one with a genuine semantic gap

`doc/plan9-port.md` explicitly ruled `rc` itself out of scope ("What
should NOT be ported"), on the grounds that `sh(1)` already covers its
role. That call doesn't survive contact with this goal. A real, current
9front `mkfile` (fetched live from `github.com/9front/9front`,
`sys/src/cmd/mkfile`, during this audit) hands every recipe body to a
shell, and is saturated with `rc`-specific syntax inline in those
recipes - backquote command substitution, `rc`'s `~` list-matching
operator, `rc`'s own `for(...)` loop syntax:

```
YTARG=`{ls | sed -n '/\.y$/s/\.y$//p'}
NOMK=$NOMK test `{~ $objtype (386 amd64) || echo $PCONLY} ...
%.cpus:V:
	for(objtype in $CPUS) mk $MKFLAGS $stem
```

`appl/cmd/mk/mk.b` (4190 lines, genuine Limbo-native `mk`, previously
uncredited in the earlier audit) cannot make real Plan 9 mkfiles do
anything useful without a shell that understands this syntax. `sh(1)`
does not, and was never meant to - it's Inferno's own shell, not a
compatibility layer.

**Good news and a real correction, both found trying to build it as an
oracle before writing any translation** (per standing practice: check for
a real build before assuming one). `utils/rcsh/` contains a real,
structurally complete `rc` **core** - `lex.c`, `syn.y`, `glob.c`,
`exec.c`, `simple.c`, `tree.c`, `var.c`, `word.c`, `code.c`, `main.c`,
`io.c`, `here.c`, `pcmd.c`, `pfnc.c`, `trap.c`, `rc.h` - 4,273 lines,
excluding generated parser output (`y.tab.c`/`.h`) and one platform file
(below). Checked directly, not assumed from file names: `syn.y` has
`FOR`/`WHILE`/`TWIDDLE` (the `~` operator) as real grammar tokens;
`exec.c`/`code.c`/`pfnc.c` have a real `Xbackq` opcode implementing
backquote command substitution. This part is genuinely a translation
project, methodologically identical to everything in the closed
`p9/cmd/` backlog - the largest single item attempted so far, at roughly
3.5x `marshal.b`'s size (current largest, ~1620 lines).

**The correction: `utils/rcsh` was never a portable `rc`, and its own
`mkfile` says so once you try to build it.** `cd utils/rcsh && mk` fails
immediately - not with a portability bug of the kind `awk` hit (three
small, fixable things), but with the `mkfile`'s own explicit rule:
`Posix.c Inferno.c:QV: echo rcsh is only built on Windows NT or Windows
95; exit 1`. There is no `Posix.c` in this directory, even though that
exact convention exists for other tools in `utils/` (`utils/mk/Posix.c`,
`utils/cc/Posix.c`, and others) - `rcsh`'s only platform file is
`Nt.c` (549 lines, Win32 `HANDLE`/`CreateProcess`-based). **A Posix/
Inferno platform binding for this `rc` core was never written at all,**
not even natively in C, let alone in Limbo. (A first pass at this
finding also flagged `rc.h`'s `#define INFERNO_KEEPENVIRON` as a
possible sign someone had already scoped a portable build - checked
directly, and it isn't: the same macro guards a Windows-only `#undef
environ` shim in `Nt/386/include/lib9.h`, unrelated to Dis/Limbo
portability, so that claim doesn't hold up.) So the honest split is:
4,273 lines of real, portable, translatable rc-language core, plus an
entirely new platform layer - sized only by what `Nt.c`'s own 18
functions are responsible for (process spawn/wait, pipes, locking,
path/exec resolution, directory reads), not by a line count, since it
has to be designed against Limbo's `spawn`/channel model, not ported.
It isn't starting from zero information, though: `utils/mk/Posix.c`
(334 lines, native C, already in this tree, already used by `mk.b`'s
own real counterpart) implements exactly the same category of
responsibility for a different program - `execsh`/`pipecmd` (real
fork+exec+pipe to run a recipe), `waitfor`/`expunge` (process wait),
`exportenv` (environment plumbing). Not translatable source (it's
built on real `fork()`, the thing Limbo doesn't have), but a concrete
reference for what real Posix behavior this layer needs to reproduce
through Limbo's own primitives - a meaningfully stronger starting point
than none at all.

**This sharpens, rather than replaces, the risk already named below:**
`rc`'s backquote/subshell model (`Xbackq`) calls into exactly this
platform layer to fork a real child process and capture its stdout.
Translating the grammar (`syn.y`) and word/glob handling (`word.c`/
`glob.c`/`var.c`) should be direct, line-for-line work with a real
oracle once a build exists somewhere to compare against (a native Posix
build could be written for exactly this purpose, the same way other
items in the backlog built a native oracle first); designing the
platform layer that `exec.c` calls into is a real, from-scratch problem,
sized only once actually attempted.

### 3. A C compiler/assembler/linker in Limbo - the largest piece, and genuinely just a big translation

**Confirmed missing, no hedge, checked again during this audit:** no
Limbo-native C compiler, assembler, or linker exists anywhere in this
tree. The only C toolchain present is the pre-existing native `kencc`
suite in `utils/` (`0c 5c 6c 8c 9c kc qc vc` and matching linkers/
assemblers) - real, and already used to build the native kernels in
`os/`, but a host binary that never touches Dis or `emu`. It doesn't
count toward this goal any more than the native `awk` build counted
toward the Limbo-`awk` item in the closed backlog (see that doc's own
disambiguation of exactly this distinction).

**Real sizes, for one full architecture's toolchain (amd64: `6c`/`6l`/
`6a`), counted directly, not estimated:**

| component | lines |
|---|---|
| `cc/` shared frontend (lexer, parser, type checker - `.c`+`.h`) | 13,864 |
| `6c` backend (codegen) | 8,337 |
| `6l` linker | 6,166 |
| `6a` assembler | 2,352 |
| **total** | **~30,700** |

(The `8`-family - 386 - is nearly identical in scale: 10,306 + 5,268 +
2,022 against the same 13,864-line shared frontend.) This is roughly
19x `rc`'s size and orders of magnitude past anything in the closed
utility backlog. There is no existing Limbo-oriented precedent to build
on for this one, unlike `rc` (which at least has the translation
methodology proven at scale by now) - this would be the single largest
translation this project has attempted, by a wide margin.

**One point worth being precise about, since it's easy to get backwards:
translating `6c`/`6l`/`6a` does not mean redesigning what they emit.**
The compiler's own *execution environment* changes (it runs as Dis
bytecode inside `emu`, same as everything else here); the *code it emits*
does not - it should still emit real amd64 machine code, exactly like
upstream `6c`/`6l`, because that's what makes the output genuinely
useful (real, runnable Plan 9 binaries) rather than a toy. So this is
direct transliteration in the same spirit as every other item in the
closed backlog, not a "retarget the backend to Dis" redesign - the
backend's actual job doesn't change, only the language and runtime the
compiler-the-program is itself written in and executes under.

**The real risk here isn't the target, it's C's raw-pointer/union-heavy
internals at this scale.** Every item in the closed backlog hit small
versions of this (`big` being a reserved word colliding with a literal
C variable name in `primes.c`; `modf`'s no-equivalent split in
`factor.c`; C's adjacent-string-literal concatenation missing in
Limbo). A ~30,000-line optimizing compiler's symbol tables, in-place
bit-twiddling on machine words, and pointer-comparison-as-identity
idioms will hit this same class of gap far more often and in less
mechanically-fixable ways. Sizing that precisely isn't possible without
starting; it's flagged here so it isn't discovered as a surprise later.

## Dependency graph and order of work

- **(2) rc and (3) the compiler don't block each other.** Both are pure
  translations of independent, already-real C source.
- **(1) protocol verification doesn't block either.** It needs a real
  test target, not engineering time from this tree, and can proceed in
  parallel whenever one becomes available (see the `os/pc64/9front/
  9pc64` note above).
- **(2) meaningfully unblocks value before (3) exists - checked directly,
  not just asserted.** `appl/cmd/mk/mk.b` was built and run (`mk.dis -n
  -f <the real mkfile fetched above> cmds`) against the real 9front
  `sys/src/cmd/mkfile`. Result: mixed, and informative. `mk.b`'s parser
  handled the file's `${TARG:%=$O.%}` substitution-pattern expansion
  without crashing, correctly walked the dependency graph to
  `cmds -> $O.cp -> 8.cp`, and failed cleanly with `mk: don't know how to
  make '8.cp'` - expected, since only the one file was fetched, not
  `cp.c` alongside it. But it also printed `usage: grep [-lnviLs] pattern
  [file...]` before that - not present at all against a plain, rc-free
  sanity-check mkfile (`all:V:\n\techo hello`, confirmed clean via the
  same `-n` invocation) - consistent with one of the file's rc-specific
  backquote expressions (most likely the `DIRS=` line, which combines
  `rc`'s `^` string-concatenation and `(... $NOMK)` list-paren syntax
  inside a piped `grep -v`) being handed to a shell that doesn't
  understand `rc` syntax and misparsing it as bad `grep` arguments. This
  is real, direct evidence for the dependency claim above, not an
  assumption: `mk.b`'s dependency engine already does real, correct work
  against a genuine Plan 9 mkfile, and `rc` is specifically what's
  missing to make the rest of it work, not some other unnamed gap.
  Confirming `mk.b`'s own target-attribute (`:V:`/`:Q:`/`:D:`) and
  `$stem`/`$target`/`$prereq` support against Plan 9's dialect - untested
  beyond this one file - remains open and should be checked early in (2),
  since a mismatch there would be a second blocker independent of `rc`.
- **(3) is the largest and highest-risk piece, and its payoff is gated on
  (2).** A real mkfile's compile recipes (`$CC $CFLAGS $stem.c`) are
  themselves `rc` command lines; a working compiler without a working
  shell to invoke it from a real mkfile is much less useful than the
  reverse.

**Recommended order: (2) first, (1) in parallel as a target becomes
available, (3) last** - both because (3) is gated on (2) for real payoff,
and because attempting the ~30,000-line compiler translation before the
methodology has been proven at `rc`'s ~4,400-line scale (itself 3.5x
anything done so far) would be sizing the biggest, riskiest piece first,
with the least evidence about how well the translation approach holds up
as line count grows.

## Progress on (2), rc in Limbo

Three slices done, all in `p9/cmd/rc.b`/`rctest.b`, each committed
separately with what it verified named in the commit message rather
than "part N of M": word.c's word-list operations plus var.c's
variable/keyword tables (`17b39312`, 26 assertions), glob.c's pure
pattern-matching logic plus word.c's `subwords` (`c220ab3d`, 54
assertions total), then tree.c's node constructors plus the real
`klook` (`65b133a4`, 77 assertions total). All three slices were
chosen the same way - real, directly testable value semantics,
nothing needing a parser or a running thread yet; the third slice
confirmed directly that tree.c is independent of the lexer/grammar
pair (it's called BY grammar actions, not coupled to the lexer the
way the lexer and grammar are coupled to each other).

Things worth carrying forward, found only by building this far:
`copywords`/`subwords`-shaped C code using a manual end-of-list
pointer (`Word**`) has no Limbo equivalent and needs recursion
instead - same result, different mechanism; `match()`'s manual UTF-8
byte decoding (`equtf`/`nextutf`/`unicode`) has no Limbo equivalent
needed at all, since Limbo's `string` type is already a rune
sequence; and real rc's `Treenodes`/`freenodes` bulk-free bookkeeping
has no counterpart at all under a real garbage collector, not just an
omitted `free()` call.

One real methodology finding, from the third slice, worth flagging for
any future cross-file test in this style: a "guard" comparing two
files' independently-declared module-interface constants
(`Rc->Tcount - Rc->Tfor`) is vacuous - module `con`s are resolved at
compile time from each file's own copy, never fetched from the loaded
module at runtime, so such a comparison can only ever check a file
against itself. Caught by the same negative-control discipline used
throughout this backlog (a deliberate drift left the guard passing
anyway) and fixed with a real test-seam function that computes the
value inside the loaded module at runtime instead. A second negative
control then showed even the fixed guard only covers one of two
possible drift shapes (a uniform base-offset shift isn't caught by a
spread comparison) - the other is covered by a different, pre-existing
test's absolute-value assertions. Documented in rctest.b as two
mechanisms working together, not overclaimed as one.

What's left of the *portable core* is the harder-to-verify half: the
lexer, grammar, and `Tree` node machinery are not independent of each
other (confirmed directly, not assumed - `syn.y`'s yacc output is what
`lex.c` returns), so unlike the two slices done so far, this next
piece can't be split into small independently-testable units the same
way - it has to be built and verified together, closer to how
`p9/cmd/hoc.b` (hand-written recursive descent, the established
precedent in this backlog for a yacc-based real source) was built.

## What this plan is not

This document started as pure sizing and sequencing, written because
the honest answer to "did you implement this" was no, and the right
next step was established to be scoping all three pieces properly
before committing engineering time to any one of them. Implementation
of (2) has since begun, per "Progress on (2)" above - this doc is now
also the running log of that work, not only the plan for it. Pieces
(1) and (3) remain unstarted.
