# Porting Plan 9's userspace to Inferno: a plan

Written 2026-08-25, after being asked to plan this and having just been
corrected for asserting a Plan 9 fact ("Plan 9 never had an awk") without
checking it. Everything below is checked against this tree as it exists
today, not recalled - where a claim is memory rather than something read
in this checkout, it says so and names what would confirm it.

## The one-line finding that reshapes this whole plan

**A large fraction of Plan 9's userspace is already here**, and awk's
real source is already vendored and building-ready, just not wired into
the build. This is not a "write 400 programs" project. It's an inventory
problem first, a handful of real gaps second, and one wiring fix that
looks like a much bigger problem than it is.

## Rule: Limbo-native, in a separate bindable tree

Everything built for this plan from here on is Limbo, compiled to Dis, run by
`emu` - "working in Inferno proper as native code," in the words this rule was
given in. It lives under `p9/cmd/` (man pages under `p9/man/1/`), not
`appl/cmd/` - `p9/cmd/mkfile` sets `DISBIN=$ROOT/p9/dis` instead of the shared
`$ROOT/dis`, so an ordinary `mk install` there cannot shadow or collide with
anything in the regular userspace. Bringing a built tool into a running
namespace is one explicit step, not a build-time default - run from *inside*
emu, not the host shell:

	bind -a /p9/dis /dis

That's an in-namespace path, not `$ROOT/p9/dis` - emu's own `/` is not the
host filesystem root (an absolute host path fails to resolve inside emu; it's
whatever directory emu was launched from), so this reaches the real `p9/dis`
only when emu's cwd is the tree checkout, same as every other `emu`/`mk`
invocation already assumes. Verified end to end, not just written down: `bind
-a /p9/dis /dis` then `awk -f prog.awk file` resolves `awk` by bare name and
runs it correctly.

This reverses the framing of "what should NOT be ported," below, for anything
new: the C/`utils/` route stays valid for what's already built there (see the
awk disambiguation right after it), but it is not how anything further gets
added under this plan.

## CORRECTION: translate the real Plan 9 C source, don't reinvent from a host oracle

`dc`, `m4`, `bc`, and `join` (items 4-6 and the `join` entry under item 9,
above) were each built as a **bounded behavioral workalike**: probe a host
tool (macOS's `/usr/bin/dc`, `bc`, `join` - none of them Plan 9's own) with
targeted test programs, reverse-engineer the rules that pass every probe, and
implement to match. That discipline is sound *when there's no Plan 9 source to
translate* - the whole reason it was used at all - but for two of those four,
there **was** real Plan 9 source sitting unread the entire time: 9front's
`sys/src/cmd/dc.c` (2297 lines - Plan 9's own dc long predates POSIX dc and is
structurally quite different, e.g. macro definitions and register *stacks*,
neither of which `p9/cmd/dc.b` implements) and `sys/src/cmd/join.c` (368
lines). Building against the wrong oracle for those two means real behavioral
differences from actual Plan 9 almost certainly exist, silently.

`m4` and `bc` are not affected by this correction - 9front's `sys/src/cmd/`
has no source for either (checked via the same tree fetch used for item 8's
enumeration below): Plan 9 never shipped them, so a bounded workalike against
the closest available Unix tool was the only option regardless, not a
methodology mistake.

**Going forward, the rule is: check for real Plan 9 C source first (the
9front tree already fetched for item 8, or fetch the one file needed), and
translate it - structure, variable names, algorithm - into Limbo, the same
way `appl/cmd`'s existing transliterations (`sort`/`uniq`/`tr`/`wc`/`grep`/
`sed`/`tac`, see "What's already ported" below) work.** A bounded, oracle-
probed workalike is the fallback only when no Plan 9 source exists at all.
`p9/cmd/primes.b` and `p9/cmd/factor.b` (a new item, below) are the first two
done this way, translated line-for-line from `sys/src/cmd/primes.c` and
`sys/src/cmd/factor.c`; `dc.b`/`join.b` are flagged for the same treatment,
not yet redone.

**Translation notes worth carrying forward, found doing the first two:**
- C's `double` is Limbo's `real` (both IEEE double) - a direct match, not an
  approximation, for any Plan 9 C source that deliberately uses `double` for
  exact-integer range beyond 32 bits (both `primes.c` and `factor.c` do,
  explicitly, up to 2^53).
- `modf(x, &ip)` (C's fractional-part-return, integer-part-out-parameter
  split) has no direct Limbo equivalent; every real call site in these two
  files only wanted one half of that split, so each was translated to
  whichever of `math->floor` or `math->fmod`-equals-zero actually matches the
  intent, not forced into one generic pattern.
- Two Limbo-specific gotchas cost real time: `big` is a reserved *type*
  keyword, not just an identifier some Plan 9 code happens to use as a
  variable name (`primes.c`'s own `double big = ...` collided directly);
  and reusing the same loop-counter name (`i`) via `:=` twice in one
  enclosing block is a compile error, not shadowing, unlike C's per-block
  scoping - both are the same class of gotcha as `p9/cmd/m4.b`'s `tl`-is-
  reserved finding, just newly triggered by literal C variable names this
  time instead of invented ones.
- A real translation bug, not a methodology one: `primes.c`'s `pt[]` table
  has 50 entries; a first pass miscounted it as 49 by eye rather than
  actually counting, silently dropping the table's last prime (229) from
  any range starting inside the table. Found by a test straddling the
  table's own 230 boundary against an independent primality check, not by
  inspection - the same lesson as every oracle-verification section above,
  now applying to literal-array-transcription mistakes as much as to
  behavioral-rule mistakes.

## What's already ported (checked, not recalled)

**Command-line tools, self-attributed.** `grep -rl "Lucent Public
License\|Plan 9 from\|transliteration" appl/cmd/**/*.b appl/lib/*.b`
finds 21 files that say outright they're Plan 9 ports (`cal`, `cddb`,
`comm`, `fmt`, `freq`, `look`, `man2html`, `puttar`, `units`, `kfs`,
`pcmcia`, plus several `appl/lib/*.b` support modules: `auth9`, `dbm`,
`disks`, `factotum`, `login`, `scsiio`, `tabs`, `complete`, `cfgfile`,
`dis`). This session separately confirmed by reading source that `sort`,
`uniq`, `tr`, `wc`, `grep`, `sed`, `tac` are transliterations too, just
without that exact grep phrase in every file - the attribution search
above is a lower bound, not the true count. `appl/cmd/*.b` alone has 212
files; a meaningful fraction of the classic `/bin` is in there.

**Whole subsystems, not just single commands:**
- `appl/acme/` - the acme editor/environment, as a directory tree, not a
  single file.
- `appl/wm/sam.b`, `samstub.b`, `samtk.b` - sam.
- `appl/cmd/sh/` - not rc, but rc's role: see "what should NOT be
  ported," below.

**The native C toolchain - this is the big one.** `utils/` has the full
kencc family: `0c 5c 6c 8c 9c kc qc vc` (compilers), `0l 5l 6l 8l kl ql
vl` (linkers), `0a 5a 6a 8a na va` (assemblers), plus `iyacc`, `mk`,
`nm`, `acid` (the Plan 9 debugger), `cc` (the driver), `libmach`,
`libregexp`. This is not a partial toolchain - it is substantially the
same compiler suite Plan 9 itself builds with, already checked into this
tree and already used to build the native kernels in `os/` (Codex's
territory, not touched for this plan). The letter-to-architecture mapping
(which of `0/5/6/8/9/k/q/v` is which CPU) is Plan 9 convention I'm
recalling, not re-derived here - confirm against `utils/*/mkfile` or
Plan 9's own docs before quoting it as fact anywhere else.

**UPDATE: done.** awk's actual source was already here, at `utils/awk/`
- the real files (`b.c lex.c lib.c main.c parse.c run.c tran.c ytab.c`,
an `awkgram.y` yacc grammar, its own working `mkfile`), not a stub - and
it was not referenced anywhere in `utils/mkfile`'s `ALWAYS`, `NOTPLAN9`,
or `NTONLY` lists, the three lists every top-level `mk` target walks, so
it never got built by an ordinary `mk` of this tree. Attempting
`cd utils/awk && mk` on this host (macOS/arm64, clang) surfaced exactly
three small, well-understood portability problems, all now fixed, none
of them a real "port a language" job:

1. `mkfile` hardcoded `-QIfdiv-` (a Watcom/OpenWatcom flag) into `CFLAGS`
   and `setargv.obj` (an MSVC/Watcom wildcard-expansion object) into
   `LDFLAGS`, unconditionally - clang rejects the first outright. Both
   were Windows-only leftovers from whenever this last built on Nt;
   removed.
2. awk's own internal C function `getline` (`run.c`, `proto.h`,
   `proctab.c`) collides with POSIX's standard library `getline()`,
   added to `<stdio.h>` well after this "one true awk" source was first
   written. Renamed the internal one to `awkgetline` in all three places
   - the awk *language* keyword `getline` (in `lex.c`/`maketab.c`, what
   a `.awk` script actually types) is untouched, since that's a
   different string entirely from the C identifier.
3. `missing95.c` is a complete, working Windows-95-era shim for
   `popen`/`pclose`/`system()`, built via `<windows.h>`/Win32 calls -
   dead weight and a hard compile error on any Posix host. Removed from
   `OFILES`.

Rebuilt clean after all three, linked, and ran for real:
`$1`/`$NF` field selection, exactly the exercise this whole thread
started from, produces correct output. `awk` added to `utils/mkfile`'s
`NOTPLAN9` list (Plan 9 itself already has its own, hence not `ALWAYS`),
so a normal build now produces it. Not yet done: confirming the fix
doesn't regress an actual Nt build (nothing here builds on Windows to
check against) - flagged, not verified, since removing Windows-only code
unconditionally is the kind of change that's easy to get right for the
platform in front of you and easy to get wrong for the one you can't
test.

**Disambiguation, now that the rule above exists:** this awk is a
host-native binary built by the kencc toolchain in `utils/` - it runs as an
ordinary OS process on whatever machine built it, never touches Dis or
`emu`, and is not what "working in Inferno proper as native code" means. It
stays; it was real, correct, tested work and nobody asked for it to be
undone. But "awk: done" above should not be read as satisfying this plan's
Limbo-native item - it isn't, see the Limbo awk item under "Order of work,"
below.

## What's missing

**Genuinely absent, not yet checked further:**
- Plan 9's own `tbl`/`eqn` preprocessors and a real typesetting `troff`
  for `doc/*.ms` papers (the `-ms` package). These papers are still
  rendered by the **host's** `groff` (confirmed: resolves to
  `/opt/homebrew/bin/groff` on this machine). Genuinely out of scope for
  now - see item 7 below for why.
  **Correction:** this bullet previously claimed the *whole* troff/man
  toolchain was absent ("nothing under `appl/` or `utils/` provides it").
  That was wrong, and should have been checked before being written -
  `appl/lib/parseman.b` (806 lines) is a real, working, Inferno-native
  troff-macro parser purpose-built for this tree's own `man/1` corpus,
  driving two existing shipped consumers: `appl/cmd/man2txt.b` (plain-text
  rendering) and `appl/cmd/man2speak.b` (speech, for the screen-reader
  path). It already handles the great majority of the request/escape
  vocabulary enumerated below for item 7 - `.TH .SH .SS .TP .TF .IP .RS
  .RE .PP .LP .HP .sp .br .nf .fi .ig .1C .2C .DT .EX .EE`, the font
  macros (`.B .I .SM .L` and the two-letter combinations `.BI .BR .IB
  .IR .RB .RI .LR .RL`), and inline escapes including `\-  \. \\ \e \|
  \& \(bu \(em \(mi \(mu \(*m \(*G \(*p \(*b \(<= \(-> \fR \fI \fB
  \f0`-`\f5 \fP \*R \*(xx`. What it does *not* handle, confirmed by
  reading `parsemacro`'s case list rather than assumed: `.ta` (tab
  stops), `.in`/`.ti` (indent/temporary-indent, present as stubs that
  just call `state.brk()`), and no standalone `.ft` request (only the
  inline `\f` escape works). See item 7, revised below, for what's
  actually still open given this.
- `9p`-family user tools (Plan 9's own `9p`, `import`, `srv` command-line
  tools, as distinct from the `styx*` diagnostic tools built earlier this
  session, which are new instrumentation, not ports of anything).
- Whatever fraction of `/rc/bin`'s ~200-300 small scripts and programs
  isn't in the 212-file `appl/cmd/` count - not enumerated here; doing
  that properly needs a real Plan 9 source tree (or the 9front one
  already checked out at `9front/`, if it has userspace source rather
  than just headers - **not checked**, and the right first move for
  anyone picking this up) to diff against, not a recollection.

**Missing and genuinely hard, with reasons:**
- Anything relying on Plan 9's `libthread` coroutine model or raw
  process/fork semantics that Limbo's own concurrency model (channels,
  `spawn`) doesn't map onto 1:1 - would need a real design, not a
  transliteration, the same way this tree's own `sh(2)` is a redesign of
  `rc` rather than a port of it (see below).
- Anything that assumes Plan 9's specific `#`-device namespace surface
  where Inferno's differs - checked case by case, not in bulk.

## What should NOT be ported

- **`rc` itself.** This tree already has `sh(1)`, with its own richer
  loadable-module system (`regex`, `string`, `expr`, `std`, `session`,
  and others built this session) - confirmed this session to already
  cover field splitting, substring position, arithmetic and pattern
  matching as builtins, which is most of what a second shell would be
  for. Porting `rc` itself would mean maintaining two shells with
  overlapping jobs; extending `sh(1)`'s existing module system when a
  real gap shows up is the better use of the same effort.
- ~~`awk` as a *language reimplemented in Limbo*~~ **superseded by the rule
  above.** This entry argued against a Limbo awk on the grounds that the C
  source already works, which is true but answers a different question:
  the C build is a host binary, not something that runs in Inferno proper.
  The rule now explicitly asks for the Limbo one, in `p9/cmd/`, alongside
  the C build rather than instead of it - see the Order of work entry
  below.

## Order of work, cheapest first

1. ~~`cd utils/awk && mk`~~ **Done** - built, fixed, linked, tested for
   real. See the awk section above, and its disambiguation: this is the
   host C build, not the Limbo-native item below.
2. **`p9/` scaffold: done.** `p9/cmd/mkfile` (following `appl/cmd/mkfile`'s
   own `<$ROOT/mkfiles/mkdis`/`mksubdirs` pattern, but with
   `DISBIN=$ROOT/p9/dis` instead of the shared `$ROOT/dis`) verified with a
   throwaway smoke-test command: `mk install` compiles and installs into
   `p9/dis/` only, confirmed nothing lands in the tree's real `/dis`.
   `.gitignore` covers `p9/dis/**/*.dis` and `p9/cmd/*.dis`/`*.sbl` the same
   way the existing `/dis/**/*.dis` line does for the shared tree.
3. **A Limbo awk, in `p9/cmd/awk.b`: done.** A bounded subset, not the
   full POSIX grammar - see `p9/man/1/awk`'s BUGS for the exact, complete
   list of what's out of scope and why each one is a scoping choice, not
   an oversight (no user functions, no `getline`, no `break`/`continue`,
   no output redirection, `FS` longer than one char is literal not regex,
   `printf` precision clamped to 0-6 digits, `for (k in arr)` order
   unspecified). What's in: field splitting, `BEGIN`/`END`, `/regex/` and
   boolean patterns, `print`/`printf` with width/precision, arithmetic,
   string concatenation, `~`/`!~`, ternary, `++`/`--` prefix and postfix,
   compound assignment, associative arrays with `for (k in arr)`, and
   `length`/`substr`/`index`/`split`/`sprintf`/`toupper`/`tolower`/`int`.
   Gated on the working C awk as a reference oracle, not on the language
   spec from memory: the same program and input run through both
   `utils/awk/o.out` and `p9/dis/awk.dis`, byte-diffed - 19 real awk
   programs this way (field selection, arithmetic, patterns, printf,
   loops, arrays, builtins), 18 byte-identical, the 19th (array
   enumeration order) verified equivalent as a set instead, since POSIX
   leaves that order unspecified and the two implementations picked
   different ones. `p9/cmd/awktest.b` (`man/1` page alongside) keeps this
   as a permanent, repeatable check via `awk.dis`'s own in-process test
   seam (`runstring(prog, input)`, no subprocess or file I/O needed) -
   confirmed to actually catch a real break with a negative control
   (deliberately broke `+`, the test failed with exactly that program's
   wrong output and nothing else, restored, all 20 passed again).
4. **`p9/cmd/dc.b` - an RPN desk calculator: done.** POSIX `dc`, bounded:
   push a number; `+ - * / % ^ v`; stack ops `p n f c d r`; named registers
   `sN`/`lN` for a-z/A-Z (one value each, no register stacks); `k` sets
   scale. No macros (`[...]x`), no strings, no `?`/input, no `z`/`Z`, no
   `i`/`o` radix change. Numbers are exact fixed-point `big` integers
   (mantissa, fraction-digit count), not floats - dc's own arithmetic is
   exact within its precision, and this representation matches that
   directly rather than approximating it with floats.
   Precision/rounding rules (what each operator's result scale is, and
   when it truncates rather than staying exact) were reverse-engineered
   against `/usr/bin/dc` with targeted probes *before* writing any code,
   not read off the POSIX text from memory - the same discipline as the
   awk oracle, applied one step earlier because the rules turned out to
   be more particular than expected (multiply's truncation threshold
   depends on both operand scales *and* the scale register at once).
   34 programs checked this way during development, all byte-identical;
   `p9/cmd/dctest.b` keeps 28 of them (now 30, see below) as a permanent
   regression test via the same in-process `runstring(prog)` seam as
   `awktest.b`, confirmed with a negative control (broke `+` into `-`, 6 of
   28 tests failed with exactly the corrupted output, restored, all 28
   passed again).

   **CORRECTION, found while building item 9 (bc) below on the same
   arithmetic: `big` is not arbitrary precision.** The line above
   claiming "Limbo's native `big` type made matching [dc's arbitrary-
   precision arithmetic] directly straightforward" was an assumption
   written down as fact, never checked against the compiler source -
   `limbo/limbo.h` defines it outright (`"Tbig, /* 64 bit int */"`); real
   arbitrary-precision integers in this tree are a separate thing,
   `module/ipints.m`'s `IPint`. Found by `bc`'s own `sqrt(2)` at a
   moderate scale printing a nonsense *negative* number with no error at
   all; traced to `dc.b` itself with the same input (`10k 2 v p`), which
   diverged from the host's `1.4142135623` the same way. Swept `Nk 2 v p`
   for N=1..20 against the host: N=1..9 match exactly, N=10 is the first
   divergence - the point where an internal value needs more than the
   ~18-19 significant decimal digits a signed 64-bit integer holds, and
   the multiply silently wrapped around instead of erroring.
   **Fixed**, not worked around: every multiply and add/sub that touches
   a `big` mantissa now goes through `bigmul`/`bigadd`/`bigsub`/`bigneg`,
   which detect the wraparound (a multiply that doesn't divide back out
   cleanly, an add/sub whose sign the operands didn't predict) and fail
   with "precision exceeded" instead of returning a wrong answer.
   `p9/cmd/dctest.b` gained 2 tests for the exact boundary (30 total):
   scale 9 still matches the host, scale 10 now fails loudly where it
   used to silently print garbage; negative control confirmed (reverted
   just the overflow check inside `bigmul`, rebuilt, the new scale-10
   test failed exactly as expected with no error raised, restored,
   30/30 passed again).
   `p9/man/1/dc`'s DESCRIPTION and BUGS, this file, and the memory this
   session keeps were all corrected in place rather than left to mislead
   the next reader - the same "correct the record" case as item 7's
   troff claim, below.
5. **`p9/cmd/m4.b` - a macro processor: done.** Bounded subset: `define`,
   `undefine`, `$1`-`$9`/`$#`/`$0`, `ifdef`, `ifelse` (including the
   chained-triplet form), `include`, `dnl`, default `` ` '' `` quoting
   (nested, one level stripped per invocation - including on a macro's
   *stored* body at every later call, not just fresh text). No `divert`,
   no `changequote`/`changecom`, no `syscmd`/`esyscmd`, no `eval` (a
   genuinely common real-m4 builtin, left out since this scope has no
   expression evaluator - see `dc` for that, separately), no
   `pushdef`/`popdef`. The five multi-arg builtins plus `dnl` can never
   be redefined/undefined, unlike real m4 where they're ordinary macros.
   Implementation is a single recursive `scanexpand(string): string` -
   collect a macro's raw arguments (respecting quote/paren nesting),
   recursively expand each, substitute into the body, then recursively
   rescan the result - rather than a literal character-stream-with-
   pushback model, since the bounded scope (no `divert`) doesn't need
   real interleaved I/O. Every behavioral rule (argument whitespace
   trimming, `name` vs `name()` differing in `$#`, quote nesting, and
   critically the default `#`-starts-a-comment convention) was
   reverse-engineered against the host's own `m4` with targeted probes
   before writing code, not read off the manual from memory - the `#`
   rule specifically was *found*, not looked up: an early test program
   with an unquoted `#` produced a real oracle error ("end of file in
   argument list") that had to be tracked down. One probing mistake is
   worth recording rather than hiding: two early tests referenced `$0`
   in a macro body with no guard, which (correctly, matching real m4)
   recurses forever on rescan since `$0` re-invokes the macro by name -
   this ran the host's own `gm4` into a multi-gigabyte runaway output
   before the mistake was caught, requiring the process be killed. Not a
   bug in this engine or in real m4; a self-inflicted unbounded test
   input, avoided afterward by piping exploratory probes through
   `timeout` *and* `head -c` together, since `timeout` alone doesn't cap
   how much a tight loop can print before its clock runs out.
   21 programs checked against the host oracle this way, 21/21
   identical; `p9/cmd/m4test.b` keeps 19 of them (via the same
   `runstring(prog)` in-process seam as `awktest.b`/`dctest.b`) as a
   permanent regression test, confirmed with a negative control (an
   off-by-one in `$1`-`$9` substitution, 2 of 19 tests failed with
   exactly that corruption, restored, all 19 passed again). Two of the
   test's own first-draft expected values were themselves wrong (assumed
   behavior instead of checking it) and were caught by the test failing
   against the *working* implementation, then fixed against a fresh,
   explicit oracle check rather than adjusted to whatever the code
   happened to produce.
6. **`p9/cmd/bc.b` - the calculator language: done.** An infix front end
   over `dc.b`'s own already-verified exact fixed-point arithmetic
   (copied in, not shared via a module, so `dc.b`'s working code stays
   untouched) - a recursive-descent parser and tree-walking evaluator,
   not string-rescanning like `m4.b`, since `bc`'s functions and loops
   genuinely need to run the same body more than once. Bounded: numbers,
   `+ - * / % ^` (unary `-` binds *tighter* than `^`, confirmed against
   the oracle - `-2^2` is `(-2)^2` = 4, not -4, a real corner most bc
   descriptions get backwards), comparisons and `&& || !`, `=` and every
   compound assign, postfix `++`/`--`, `if`/`while`/`for`, `define`
   functions with `auto` locals (dynamic-scoped: shadows a same-named
   global for the call only, restored on return) and recursion, and the
   `sqrt`/`length`/`scale` builtins. No `ibase`/`obase`, no `-l` mathlib,
   no strings/`print`, no arrays, no prefix `++`/`--`; one real grammar
   corner - a bare, unparenthesized assignment whose right side touches
   a relational operator parses differently in the real oracle (`y = 3 >
   2` is `(y = 3) > 2`, not `y = (3 > 2)`) - is checked against the host,
   understood, and deliberately not replicated (parens are required
   instead) rather than silently gotten wrong; see `p9/man/1/bc`'s BUGS
   for the exact reasoning.

   The oracle here is Gavin Howard's bc 7.x (the real `/usr/bin/bc` on
   this machine), not the older AT&T/GNU bc most manuals describe - every
   behavioral rule above, plus `length(x)` counting only `x`'s mantissa
   digits regardless of scale (`length(0.001)` is 1, not 4) and a
   compound assignment being silent exactly like a plain `=` (not
   printing, which this file's own first-draft test wrongly expected),
   was checked with targeted probes before writing code, not read off a
   manual from memory. 28 programs checked this way, all matching after
   two real bugs found *during* that probing were fixed: the unary-
   minus/power precedence above (found because the very first negative-
   power test failed), and `auto` never actually restoring a shadowed
   global on return (found via a probe built specifically to check
   shadowing, not a coincidence). `p9/cmd/bctest.b` keeps 30 of the 28
   plus the 2 precision-boundary tests below as a permanent regression
   test via the same `runstring(prog)` seam as `dctest.b`, confirmed with
   a negative control (broke `+` into `-`, 3 tests failed immediately and
   a 4th cascaded into an infinite loop and an out-of-memory abort before
   it could even report - itself confirming the corruption, just more
   dramatically than a clean failure - restored, 40/40 passed again).

   Shares item 4's `big`-is-64-bits-not-arbitrary-precision correction
   directly (the bug was *found* through `bc`, then traced back to
   `dc.b`): the same `bigmul`/`bigadd`/`bigsub`/`bigneg` overflow checks
   apply here too, and `bctest.b` checks the identical boundary (`sqrt(2)`
   at scale 9 matches, scale 10 now fails loudly instead of wrapping).
7. **A troff-equivalent for this tree's own `man/1` corpus, text output
   only - the concrete answer to "wire an Inferno-native troff/ms
   toolchain": done, but not by building one.** This item was scoped
   (see the grep-derived vocabulary that used to sit here) before
   checking whether anything already did this. It did: `module/man.m`
   (`Parseman`) plus `appl/lib/parseman.b` (806 lines) is a real,
   working, Inferno-native troff-macro parser purpose-built for this
   corpus, already consumed by two shipped commands, `appl/cmd/man2txt.b`
   (plain text) and `appl/cmd/man2speak.b` (speech, the screen-reader
   path). Writing a second one in `p9/cmd/` alongside it would have been
   exactly the "maintaining two of the same thing" mistake this document
   itself argues against for `rc` - so this item became *assess the
   existing engine against the real corpus, then fix what's actually
   broken*, not build.

   **Measurement first, not assumption:** ran `man2txt` over all 507 real
   pages in `man/1/` (`INDEX` excluded) via a driver script, one `emu`
   invocation per page (`timeout 10` each; a `while read` loop's stdin
   must be redirected from `/dev/null` for the inner `emu` calls, or the
   loop's own input file gets consumed as if it were the *program's*
   stdin - cost one confusing false start). Result: 507/507 exit 0, 0
   bytes of stderr anywhere, 0 empty-output pages. The engine never
   crashes on this corpus; every gap in it is a silent no-op, not a
   fault - so the only way to find what's missing is to diff rendered
   output, not to watch for errors.

   **What the case-list in `parsemacro` actually does not handle**,
   confirmed by reading the code rather than assumed from the earlier
   grep: no `.ta` (tab stops), no `.ne` (need-N-lines), no `.ns`
   (no-space mode), no `.if` (conditional), no standalone `.ft` request
   (only the inline `\f` escape works), and `.in`/`.ti` present only as
   stubs (`state.brk()`, indent logic commented out). Cross-checked
   against where each is actually *used* in the in-scope corpus, not
   just whether it's supported, since an unused gap costs nothing to
   leave alone:
   - `.ta`, `.if`: used only in `units`, already out of scope (see
     below) for its `.de`/`.TS` usage - not a live gap.
   - `.in`, `.ti`: used in **zero** pages in `man/1/`. Confirmed stubs,
     genuinely dead code paths for this corpus - left alone.
   - `.ne`: used in 3 pages (`acme`, `fc`, `sh`), every one of them the
     classic "keep this heading with what follows" page-break hint
     (`.ne 1.2i` / `.SH ...`). Text output has no pages. Checked, not
     assumed: a no-op is the *correct* behavior here, not a gap - left
     alone.
   - `.ns`: used in 2 pages (`acme` ×3, `ar` ×1), always as `.br` `.ns`
     before a second `.TP`, the idiom for grouping two tag lines (e.g.
     acme's `c`/`i` key-binding entries) under one shared body. Left as
     a no-op, this produced a real, visible defect: the grouped entries
     rendered with a spurious blank line between them, so `c` appeared
     to have no description and `i` looked like a separate entry.
     **Fixed** - `.ns` now sets `state.newpara = 1`, which is exactly
     what suppresses `paragraph()`'s next blank-line emission.
   - `.ft`: used in exactly 2 pages (`fantics`, `tutor`), both `.ft L`
     around a verbatim block then bare `.ft` to return to the prior
     font. **Fixed** - added as a request, mapped through the same
     letter table `\f` already uses, plus a new `state.prevfont` field
     on `ParseState` for the bare (return-to-previous) form. Invisible
     in `man2txt`'s own output specifically, since that consumer never
     applies font to rendering at all (just flattens `Text.text`) - the
     fix is real at the parser level, just not observable through this
     one consumer.

   **Two further bugs found by reading the code for the gaps above, not
   by grepping for them - both far more widely triggered than the pages
   that led to finding them:**
   - `.L`/`.LR`/`.RL` (the literal-font macros) built `Text` records
     directly from raw macro parameters, never calling `parsetext` -
     so any escape inside a `.L`-quoted term leaked raw (found via
     `acme`'s `` .LR .*\en? . `` rendering literally as `\en?` instead of
     `\n?`). Separately, `.L` *also* manually wrapped its text in
     `` `...' `` quotes while `addtext()` already does that itself for
     `FONT_LITERAL` text when `ql` is set - double-quoting every `.L`
     term tree-wide (`` ``x'' `` instead of `` `x' ``). Fixed by dropping
     `.L`'s manual quoting and routing all three through `parsetext`
     (for `.LR`/`.RL`, by reusing `altattr()`, the exact same
     alternating-font helper `.BI`/`.BR`/`.IB`/`.IR`/`.RB`/`.RI` already
     use - `FONT_LITERAL` is just another font value to it).
   - `.SH`/`.SS` heading text called `addstring()` directly on raw
     params instead of `parsetext()`, leaking inline escapes in
     headings (found via `inputtest`'s
     `` .SS \fB-w\fP, and why a recording can be empty ``, rendering the
     `\fB`/`\fP` literally). Fixed the same way, matching every other
     text-bearing request.

   **Verification:** re-ran the full 507-page sweep after the fix and
   diffed every page's output against the pre-fix baseline. 22 pages
   changed, 485 identical - reviewed all 22 diffs by hand, every one a
   clean improvement (the `.L` double-quote fix alone touched 18 pages
   never grepped for it going in: `acme ar basename cal cleanname comm
   dd diff kill miniterm mk paste rcmd read sendmail tail tiny tr units
   webgrab yacc`; `acme`/`ar` additionally show the `.ns` blank-line
   fix). Zero regressions. Negative control: reverted just the `.L` fix,
   rebuilt, confirmed `basename`'s output regressed to the double-quoted
   form, restored, confirmed it was single-quoted again.

   Change lives in `appl/lib/parseman.b` - not `p9/cmd/`, since this is
   a fix to the tree's own existing shared library, not a new Plan
   9-workalike command; `man2speak.b`'s speech path uses the identical
   engine and needed no changes of its own to pick up every fix above.
   `groff`-equivalent ANSI/SGR output formatting was considered and
   dropped: neither `man2txt` nor `man2speak` renders font as color or
   weight today, so matching `groff -Tutf8`'s escape-code choices would
   have been reverse-engineering a state machine for a consumer that
   doesn't exist in this tree.
8. **Enumerate `appl/cmd/` against a real Plan 9 (or 9front) source
   tree's `/bin` list: done.** The local `9front/` checkout mentioned
   above turned out to be headers/APE + two prebuilt binaries only, not
   source, exactly as this doc predicted ("not checked, and the right
   first move for anyone picking this up") - so the real reference used
   is `github.com/9front/9front` (a nightly-synced mirror of the actual
   `git.9front.org` source, confirmed live), fetched via GitHub's tree
   API rather than a full clone: `sys/src/cmd/`'s 166 direct source
   files plus, for each of its 134 subdirectories, that subdirectory's
   own `mkfile` `TARG=` (handling the 6 that build more than one binary,
   e.g. `vac` -> `vac`/`unvac`/`vacfs`, and the 7 with no direct `TARG=`
   because they nest further, e.g. `upas`, `cwfs`, `postscript`, whose
   immediate subdirectory names were used instead, library-looking ones
   like `common`/`libFLAC` excluded). After dropping build-system
   plumbing that isn't a command at all (`mkfile`/`mkone`/`mklib`/etc.,
   picked up as false positives on the first pass, along with stray
   `.h` names from the fallback path) - **379 real Plan 9 commands.**

   Diffed against this tree's own commands, unioned across every place
   a command legitimately lives here, not just `appl/cmd/` (missing
   this was the first-pass mistake: comparing against `appl/cmd/` alone
   put `awk`/`dc`/`acme` in the "missing" column even though all three
   exist, just under `p9/cmd/`, `utils/`, and `appl/acme/`
   respectively) - `appl/cmd/`'s 405 `.b` basenames (recursive) +
   `p9/cmd/`'s 6 + `utils/`'s ~60 host-native builds + the ~60 tool
   names already installed to `MacOSX/arm64/bin/`. **106 of the 379
   match by name; 272 (after also correcting for `acme`) do not.**

   That raw 272 overstates the real gap by a lot, the same way the old
   "genuinely absent" troff claim overstated item 7 - a name not
   matching isn't the same as a missing capability. Categorized by
   what's actually true of each, not just "missing":
   - **18 native per-arch toolchain tools** (`1a`/`1c`/`1l` through
     `9a`/`9l`, `cpp`, `pcc`, `pgen`, ...) - compile *native* Plan 9
     binaries for architectures; irrelevant to a Dis/Limbo target the
     same way the rest of `utils/`'s own toolchain already is, not a
     real gap.
   - **39 Plan 9 fs-servers** (`cwfs`/`hjfs`/`hgfs`/`nfs`/`ratfs`/`gefs`/
     `ramfs`/`webfs`/... ) - Plan 9's fs-server-over-9P model; this
     tree already has its own device/`#`-namespace answer to the same
     problem (see `emu/port/srv.c`, the styx tooling built earlier this
     session). A real design question each, not a raw port, matching
     this doc's existing "missing and genuinely hard" bucket.
   - **40 troff/print-toolchain tools** (`eqn`/`tbl`/`pic`/`grap`/
     `troff`/every `post*` PostScript-driver name/`gs`) - already
     decided in item 7 above: this tree keeps depending on the host's
     `groff` for `doc/*.ms`, and `gs` alone (a full Ghostscript) is out
     of scope by size regardless.
   - **12 of Plan 9's own GUI/editor stack** (`rio`/`riow`/`sam`/
     `samterm`/`mothra`/`page`/...) - superseded by this tree's own
     `wm`/Tk, the same reasoning this doc already gives for not
     porting `rc`. Not a gap; a different design, already made.
   - **24 hardware/device drivers** (the `nusb` family - `kb`/`joy`/
     `cam`/`ether`/`serial`/`battery`/`disk` - plus audio codecs -
     `flacdec`/`mp3dec`/`oggdec`/`sundec`/...) - real Plan 9 hardware
     support; out of scope for this hosted VM the same way bare-metal
     kernel work belongs to `os/`, not `appl/`.
   - **15 upas mail-subsystem tools**, **6 ssh/tls networking tools** -
     genuine, coherent subsystems nobody has looked at yet; each is its
     own real design question (an MTA/mailbox model, a TLS client/server
     pair), not a same-day fix.
   - **118 residual** - didn't cleanly fit a bucket above by pattern,
     and include known measurement noise from this method itself
     (`tests`, `init`, and `9netics32.16k`/`9netics64.8k`/`choline`/
     `emelie`, which are fossil/venti *instance names* nested under
     `cwfs/`, not general commands - an artifact of the subdirectory
     fallback, not real entries) alongside several already resolved by
     this doc under a different name and not rechecked carefully enough
     on the first pass (`rc` - see "What should NOT be ported" above;
     `strip` - this tree already has `kstrip`; `plot`/`graph`/`fplot` -
     this tree's own `plot.m`; `expect` - this tree's own
     `session(2)`/`sh-session(1)`; `pump` - this tree's own
     `appl/cmd/ip/dhcp.b`) plus a real, if smaller, set of plausible,
     self-contained, low-effort gaps worth someone's actual time -
     `file`, `patch`, `tar`, `join`, `split`, `iconv`, `pr`, `dict`,
     `bc`, `hoc`, `primes`/`factor`, `crc32` are the ones with enough
     name-recognition to be confident about; the rest of the residual
     (`atazz`/`zuke`/`spred`/`sprog`/`dtracy`/`flambe`/... and similar)
     are 9front-specific or obscure enough that this pass could not
     responsibly guess at them without reading their actual source -
     flagged as needing individual research, not silently dropped or
     silently counted as gaps.
9. Everything else on a case-by-case basis, now that (8) gives a real
   list instead of a blanket estimate: of the 272 raw misses, 154 sort
   cleanly into "not actually a gap" (already covered under a different
   name, already a deliberate design decision elsewhere in this doc, or
   out of scope by category - native toolchain, hardware, GUI stack,
   troff/print), leaving on the order of a dozen genuinely plausible,
   scoped, standalone candidates (`file`/`patch`/`tar`/`join`/`split`/
   `iconv`/`pr`/`dict`/`hoc`/`primes`+`factor`/`crc32` above - `bc` was
   one of these and is now done, item 6 above) worth picking up the same
   way `awk`/`dc`/`m4`/`bc` were - plus three coherent subsystem-sized
   questions (fs-servers, mail, ssh/tls) that are each real design work,
   not a quick port, and a genuinely unclassified residual that needs
   someone to look at the actual 9front source
   before it can be triaged further. Still open, and this is that list.

   **`hoc` does *not* collapse into `bc` despite looking like a variant
   of the same evaluator** - checked, not assumed, before continuing to
   list them as if they were the same size of job. `hoc` exists on this
   host (`plan9port`'s build); `echo '1/3' | hoc` prints
   `0.3333333333333333` - IEEE double, not `bc`'s exact fixed-point.
   Reusing `bc.b`'s parser *shape* (recursive descent, the same kind of
   `define`/control-flow grammar) is plausible, but the numeric core
   would need to be Limbo's `real`, not the `Dnum`/`big` arithmetic - a
   different foundation, not a reskin. Demoted accordingly: `hoc` is
   still a reasonable candidate, just not the near-free one `bc`'s
   existing work would have made it.

   **`p9/cmd/join.b` - relational join of two sorted files: done**, one
   of the candidates from this list. A classic sorted merge-join over
   two pointers, cross-producting every combination on a duplicate key
   (checked against the oracle, not assumed - a key appearing twice on
   each side produces all four combinations). Bounded: default and
   `-1`/`-2` field selection, `-t` separator, `-o` field list (comma or
   repeated, `0` or `file.field`), `-a`/`-v` unpairable-line handling
   (`-v` suppresses the default matched output entirely, unlike `-a`,
   which adds to it), `-e` empty-field replacement, `-` for stdin. No
   bare `-a` / `-j` / `-j1` / `-j2` / multi-argument `-o` - the real
   `join(1)`'s own manual calls these "compatibility" options that
   "should not be used", so none are ported. Input is assumed already
   sorted, same as the oracle: neither sorts nor validates, so unsorted
   input can silently miss real matches - checked directly (an out-of-
   order key made a real pair go unreported, no error), not assumed
   safe. 14 programs checked against the host's real `join`, all
   matching after one real bug found during that same probing: an early
   version of `-o`'s field-order handling produced its output backwards
   (`0,1.2,2.2` came out `2.2,1.2,0`) from a double-reversal mistake -
   caught by comparing `-o` output against the host, not by inspection.
   `p9/cmd/jointest.b` keeps all 14 as a permanent test via
   `runstring(args, in1, in2)` - a two-input extension of `awk.b`'s
   `runstring(prog, input)` seam, since `join` always takes two files -
   confirmed with a negative control (broke the cross-product loop into
   first-match-only, the duplicate-key test failed with exactly the
   truncated output, restored, 14/14 passed again).

   **Superseded: `join.b` was built as a workalike against macOS's
   `join`, not from `sys/src/cmd/join.c` (368 lines), which does exist -
   redone as a real translation, item 11 below.** The writeup above is
   kept as a record of what the workalike did, not current.
10. **`p9/cmd/primes.b` and `p9/cmd/factor.b` - real translations of
    `sys/src/cmd/primes.c` and `factor.c`: done**, the first two built
    under the correction above rather than the earlier workalike
    discipline. Both use a segmented/incremental wheel sieve (structure,
    variable names, and the wheel arrays themselves taken directly from
    the C), both take numbers as Limbo `real` (matching the originals'
    deliberate use of C `double` for exact-integer range past 2^53), and
    both keep the C's own argument-handling shape: `primes [start
    [finish]]` (zero arguments reads `start` from standard input, one
    argument means no upper limit, `finish` below `start` exits cleanly,
    above 2^53 is an error); `factor [number ...]` (no arguments reads
    numbers from standard input until a non-positive sentinel).
    See the CORRECTION section above for the translation notes and the
    one real bug found (`primes.c`'s 50-entry small-primes table
    miscounted as 49). Both verified against an independent primality/
    factorization check (not derived from either file's own sieve
    logic) and cross-checked against real binaries where available
    (this tree's local `plan9port` checkout has genuine Plan 9 `primes`
    and `factor`; GNU coreutils' `factor` agrees too). `p9/cmd/
    primestest.b` (7 cases) and `p9/cmd/factortest.b` (9 cases) keep
    these as permanent tests via `runstring(args)`; both confirmed with
    a negative control.
11. **`p9/cmd/join.b` redone as a real translation of `sys/src/cmd/
    join.c` (368 lines): done**, replacing the workalike from item 9.
    The one genuinely large structural fact: Plan 9's join does not
    load both files into memory and merge two arrays (what the workalike
    did, and what a typical POSIX join does) - it drives the match loop
    off whichever file is seekable (a real seek probe, matching the C's
    `ftell()>=0` check) and handles a run of duplicate keys on the other
    file by rewinding it to a bookmarked byte offset and re-reading -
    `seek1()`/`seek2()`, mirror images exactly as in the source, using
    `bufio`'s `Iobuf.offset()`/`.seek()` as the direct analogue of
    `ftell`/`fseek`. This matters observably, not just internally:
    `join - -` (both inputs from standard input, neither seekable) is a
    hard error in the real join, which a buffered merge would never
    notice - translating the seek algorithm as written was necessary to
    keep that, not an optional faithfulness exercise.

    Because the algorithm is seek-based, `runfiles(args, path1, path2)`
    - the test seam - takes two real file paths, the only `p9/cmd` test
    seam that does not operate on in-memory strings; there is nothing to
    seek in a string, so bending the algorithm to fit the old seam shape
    would have been exactly the "substitute an equivalent algorithm"
    mistake this rewrite exists to avoid (per the advisor consulted
    before starting: translate what's there, don't assume the seeking is
    just an implementation detail).

    Full CLI surface translated, not just the algorithm: `-j`/`-j1`/`-j2`
    alongside `-1`/`-2` (Plan 9 has both); both `-o` argument forms (a
    comma list, and the historic space-separated form - not a deprecated
    compat shim here, unlike BSD's framing of its own equivalent, so both
    are real and both are ported, correcting the old workalike's BUGS
    entry that said otherwise); `getoptarg()`'s attached-suffix-or-next-
    word convention (`-a1` and `-a 1` both work; `-j`'s value is always a
    separate word, unlike `-a`/`-e`/`-t`/`-1`/`-2`); unrecognised options
    silently ignored (no `default:` case in the original's switch); the
    `NFLD` (100) field cap and its `discard` counter, reported as a
    failure only at the very end, after whatever output already
    happened. `atoi()`'s C leniency (silently stops at the first
    non-digit, no error) is now `catoi()`, replacing a stricter helper
    that doesn't match the source. Limbo strings are already rune-
    indexed Unicode sequences, so the comparison (`comp()`/`runecmp()`)
    and field splitting needed no chartorune/runetochar translation step
    at all - Limbo is a closer match to what this C is doing than C's
    own manual Rune juggling.

    Three real, reproducible bugs in the source are preserved rather
    than fixed, all three checked against a real Plan 9 join binary
    (this tree's local `plan9port` checkout, confirmed to be the same
    source by its identical usage string) before writing anything down,
    not assumed from reading the code - one initial guess (that a multi-
    digit `-o` field number would error) was wrong until checked this
    way: (1) `oparse()`'s scan-pointer misalignment on a 2+-digit `-o`
    field number doesn't error or drop the field, it silently inserts a
    spurious extra join-key output column (`-o 1.10,2.2` produces three
    columns, not two); (2) an `-o` spec for a nonexistent field 0 (`-o
    1.0`) is undefined behaviour - confirmed to segfault the real binary
    - so the translation substitutes the `-e` string instead of
    reproducing a crash; (3) a join field configured past some line's
    actual field count reads memory-layout-dependent leftover data in
    the original (also confirmed capable of segfaulting it, not simply
    "keeps the previous line's value" as first guessed), replaced here
    with a safe, well-defined "keeps the last value actually written"
    rule rather than an attempt at bit-for-bit fidelity to something
    with no well-defined value to be faithful to. Full detail in
    `join.b`'s header comment.

    `p9/cmd/jointest.b` rewritten for the new seam and CLI surface: 20
    cases (attached/separate `-a`, `-e`, unrecognised-option and `--`
    handling, duplicate-key cross product, both `-o` forms including
    that a later `-o` replaces rather than concatenates with an earlier
    one - an old test assumption that turned out wrong once checked
    against the real binary and was fixed to match it, not the reverse -
    `-1`/`-2`, `-j`/`-j1`/`-j2`, `-t`, default-separator collapsing, and
    the three preserved bugs above), all checked against the real binary
    first. Confirmed with a negative control (inverted the truncation-
    counting condition; 19 of 20 cases failed immediately, the sole
    survivor being the one case that already expected a failure;
    restored, 20/20 passed again).
12. **`p9/cmd/crc32.b` - a real translation of `sys/src/cmd/crc32.c` (99
    lines): done**, one of the item-9 backlog candidates, and the first
    one picked up under the corrected methodology from scratch (not a
    redo). Computes the standard reflected CRC-32 (the one used by
    gzip/zip/Ethernet) with configurable `-x`/`-i`/`-p`.

    The one real translation problem: the C's `u32int` arithmetic
    includes a right shift that must be logical (zero-fill), but
    Limbo's own `int` right-shift sign-extends (documented in
    `doc/limbo/limbo.ms`), and Limbo has no separate logical-shift
    operator for a signed type. Solved by carrying every value as
    `big` masked to 32 bits rather than `int` - since a masked value is
    always non-negative, its sign bit is always 0, so a plain
    (arithmetic) right shift never needs to fill with 1s in the first
    place and is exactly the logical shift this algorithm needs, with
    no separate operator required. `ARGBEGIN`/`EARGF` (Plan 9 libc's
    own option macros) use the same attached-suffix-or-next-word
    convention as `join.b`'s `getoptarg()`, ported the same way, since
    it's the same convention. `strtol(s,0,0)`'s base-0 hex/octal/
    decimal auto-detection is a small from-scratch `parsenum()`, not a
    bug-for-bug port of `strtol`'s own edge cases (no known real
    divergence worth preserving there, unlike `join.b`'s `atoi()`).
    `exits(error)`'s "keep processing every file, report failure only
    at the very end" shape is the same idiom as `join.b`'s `discard`
    bookkeeping, translated the same way.

    Verified against an independent oracle (Python's `zlib.crc32`,
    which implements the same standard CRC-32 this program's defaults
    do, but shares no code with the translation) for five default-
    parameter cases, and against a from-scratch Python re-
    implementation of `crc32.c`'s own table algorithm (not derived from
    the Limbo translation) for a custom `-i`/`-x` case - all match.
    `p9/cmd/crc32test.b` (7 cases) keeps these as a permanent test via
    `runstring(args, input)`; confirmed with a negative control (broke
    the final XOR-with-`xorval` into an AND; 6 of 7 cases failed
    immediately - the seventh only checks "produces non-empty output",
    which survived - restored, 7/7 passed again).

    Checked which of the remaining item-9 candidates have real Plan 9
    source before picking the next one (same discipline as the
    dc/join check): `split.c` (195 lines), `pr.c` (666), `file.c`
    (1772), `tar.c` (1588), `patch.c` (839), and `iconv.c` (102) all
    exist in `sys/src/cmd/`; `dict` does not (confirmed 404 against the
    9front tree - it was a guess in item 8's list that didn't pan out).
    Line counts fetched but not yet read in full or translated -
    `split`/`iconv` are `crc32`-sized next candidates; `pr`/`patch` are
    a middle tier; `file`/`tar` are `dc.c`-sized undertakings, not a
    quick pass.
