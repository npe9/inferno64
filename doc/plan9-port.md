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
- Plan 9's own `troff`/`ms`/`tbl`/`eqn` toolchain. This tree's man pages
  and `doc/*.ms` papers are all troff *source*, rendered by the **host's**
  `groff` (confirmed: `groff` resolves to `/opt/homebrew/bin/groff` on
  this machine, nothing under `appl/` or `utils/` provides it). Every man
  page in this tree depends on a tool that isn't itself part of the
  tree - worth fixing on its own, independent of anything else here.
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
   arbitrary-precision, and Limbo's native `big` type made matching that
   directly straightforward rather than approximating it with floats.
   Precision/rounding rules (what each operator's result scale is, and
   when it truncates rather than staying exact) were reverse-engineered
   against `/usr/bin/dc` with targeted probes *before* writing any code,
   not read off the POSIX text from memory - the same discipline as the
   awk oracle, applied one step earlier because the rules turned out to
   be more particular than expected (multiply's truncation threshold
   depends on both operand scales *and* the scale register at once).
   34 programs checked this way during development, all byte-identical;
   `p9/cmd/dctest.b` keeps 28 of them as a permanent regression test via
   the same in-process `runstring(prog)` seam as `awktest.b`, confirmed
   with a negative control (broke `+` into `-`, 6 of 28 tests failed with
   exactly the corrupted output, restored, all 28 passed again).
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
6. **A troff-equivalent for this tree's own `man/1` corpus, text output
   only (an nroff, not a typesetting troff) - the concrete answer to
   "wire an Inferno-native troff/ms toolchain."** Scoped from evidence, not
   guessed: grepping every request (`^\.XX`) and escape actually used
   across all 507 pages in `man/1/` gives an exact, closed vocabulary -
   `.TH .SH .SS .PP .LP .P .TP .TF .IP .RS .RE .br .sp .ne .fi .nf .ta .PD
   .ns .HP .EX .EE .if`, the font-alternating macro family (`.B .I .R .L
   .CW .SM` and every two-letter combination of `B I R L`, decoded
   generically from the macro name's letters rather than hardcoding each
   pair), and escapes `\- \fP \fI \fR \fB \f1 \f2 \(em \(bu \(mu \(rq \(lq
   \(mi \(en \e \\`. Exactly one page (`units`) uses `.de`/`.TS` (macro
   definition, a table) and is explicitly out of scope for v1 rather than
   forcing the whole engine to support macro definitions and `tbl`
   preprocessing for one file; two pages (`spriteedit`) use undefined
   `.MESH`/`.SPRITE`-family requests that render as a no-op today and stay
   that way. `doc/*.ms` (the `-ms` package, `.TS`/`.TE` tables via `tbl`,
   `eqn`) is explicitly out of scope for v1 - a different, larger macro
   package with a real preprocessor dependency, not something to fold into
   a man-page renderer by accident. Oracle: `groff -man -Tutf8 -k -ww` on
   the same page, byte-diffed against this engine's own `-Tutf8`-equivalent
   output, for as many of the 506 in-scope pages as pass - report the exact
   count and list what doesn't, not a rounded-off "most of them." This is
   the biggest item here; if it eats the rest of the session, that's the
   right call given it's the one gap `CLAUDE.md`/this doc have named
   explicitly and left open the longest. Not yet started.
7. **Enumerate `appl/cmd/` against a real Plan 9 (or 9front) source
   tree's `/bin` list**, not recollection, to get an actual missing-count
   instead of the "a lot is already here" qualitative claim above. Lower
   priority than (4)-(6): needs an actual reference tree to diff against,
   which none of (4)-(6) do (they all have a host oracle already installed
   and checked, above). Still open.
8. Everything else on a case-by-case basis once (7) produces a real list
   - no blanket estimate for "the rest" is offered here, on purpose,
   since a plan that says "37 remain, here are the 6 that need real
   design work" is the only useful shape of an answer to "port
   everything," and this document doesn't yet have that list. Still
   open, and blocked on (7).
