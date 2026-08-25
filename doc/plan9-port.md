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
- Plan 9's own `tbl`/`eqn` preprocessors and a real typesetting `troff`
  for `doc/*.ms` papers (the `-ms` package). These papers are still
  rendered by the **host's** `groff` (confirmed: resolves to
  `/opt/homebrew/bin/groff` on this machine). Genuinely out of scope for
  now - see item 6 below for why.
  **Correction:** this bullet previously claimed the *whole* troff/man
  toolchain was absent ("nothing under `appl/` or `utils/` provides it").
  That was wrong, and should have been checked before being written -
  `appl/lib/parseman.b` (806 lines) is a real, working, Inferno-native
  troff-macro parser purpose-built for this tree's own `man/1` corpus,
  driving two existing shipped consumers: `appl/cmd/man2txt.b` (plain-text
  rendering) and `appl/cmd/man2speak.b` (speech, for the screen-reader
  path). It already handles the great majority of the request/escape
  vocabulary enumerated below for item 6 - `.TH .SH .SS .TP .TF .IP .RS
  .RE .PP .LP .HP .sp .br .nf .fi .ig .1C .2C .DT .EX .EE`, the font
  macros (`.B .I .SM .L` and the two-letter combinations `.BI .BR .IB
  .IR .RB .RI .LR .RL`), and inline escapes including `\-  \. \\ \e \|
  \& \(bu \(em \(mi \(mu \(*m \(*G \(*p \(*b \(<= \(-> \fR \fI \fB
  \f0`-`\f5 \fP \*R \*(xx`. What it does *not* handle, confirmed by
  reading `parsemacro`'s case list rather than assumed: `.ta` (tab
  stops), `.in`/`.ti` (indent/temporary-indent, present as stubs that
  just call `state.brk()`), and no standalone `.ft` request (only the
  inline `\f` escape works). See item 6, revised below, for what's
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
7. **Enumerate `appl/cmd/` against a real Plan 9 (or 9front) source
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
   "genuinely absent" troff claim overstated item 6 - a name not
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
     decided in item 6 above: this tree keeps depending on the host's
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
8. Everything else on a case-by-case basis, now that (7) gives a real
   list instead of a blanket estimate: of the 272 raw misses, 154 sort
   cleanly into "not actually a gap" (already covered under a different
   name, already a deliberate design decision elsewhere in this doc, or
   out of scope by category - native toolchain, hardware, GUI stack,
   troff/print), leaving on the order of a dozen genuinely plausible,
   scoped, standalone candidates (`file`/`patch`/`tar`/`join`/`split`/
   `iconv`/`pr`/`dict`/`bc`/`hoc`/`primes`+`factor`/`crc32` above) worth
   picking up the same way `awk`/`dc`/`m4` were - plus three coherent
   subsystem-sized questions (fs-servers, mail, ssh/tls) that are each
   real design work, not a quick port, and a genuinely unclassified
   residual that needs someone to look at the actual 9front source
   before it can be triaged further. Still open, and this is that list.
