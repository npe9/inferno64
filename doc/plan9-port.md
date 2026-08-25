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

**awk's actual source is already here, at `utils/awk/`** - the real
files (`b.c lex.c lib.c main.c parse.c run.c tran.c ytab.c`, an
`awkgram.y` yacc grammar, its own working `mkfile`), not a stub. Checked
directly: it is **not** referenced anywhere in `utils/mkfile`'s `ALWAYS`,
`NOTPLAN9`, or `NTONLY` lists, the three lists every top-level `mk`
target (`all-Posix`, `all-Nt`, `all-Plan9`, `all-9front`) walks. So it
never gets built by an ordinary `mk` of this tree - not because it's
unported, but because nothing asks for it. **This reframes "port awk" as
"add `awk` to the right list in `utils/mkfile` and confirm it links
against this tree's `libbio`," not "implement or port a language."** Not
yet attempted - `utils/` shows unrelated dirty files in `6c`, `6l`, `cc`
(likely the parallel kernel work already noted as off-limits territory)
and running a build there wasn't attempted this session to avoid
stepping on that. **Next concrete step: `cd utils/awk && mk` on a clean
checkout (or after confirming with whoever owns `utils/`'s current dirty
state), see what breaks.**

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
- **`awk` as a *language reimplemented in Limbo*.** Its actual C source
  is already here (see above) - reimplementing it in Limbo would be
  redoing real, working, tested work for no benefit over wiring in the
  C build. If it turns out the C build genuinely can't be made to work
  (untried assumption, not a finding), that changes this entry, but
  start from "wire it in," not "rewrite it."

## Order of work, cheapest first

1. **`cd utils/awk && mk`** - find out whether the vendored source
   actually builds against this tree's current `libbio`/`libregexp` as-is.
   This single check determines whether "port awk" is a one-line
   `mkfile` edit or a real porting job, and nothing else here should be
   estimated until it's done.
2. **Enumerate `appl/cmd/` against a real Plan 9 (or 9front) source
   tree's `/bin` list**, not recollection, to get an actual missing-count
   instead of the "a lot is already here" qualitative claim above.
3. **Wire an Inferno-native troff/ms toolchain**, or explicitly decide
   this tree keeps depending on the host's groff and say so in
   `CLAUDE.md` rather than leaving it an implicit, undocumented
   dependency.
4. Everything else on a case-by-case basis once (2) produces a real list
   - no blanket estimate for "the rest" is offered here, on purpose,
   since a plan that says "37 remain, here are the 6 that need real
   design work" is the only useful shape of an answer to "port
   everything," and this document doesn't yet have that list.
