# Danby model authoring: a real equation language, and what the "duplicates" actually are

**Status: mixed.** The equation-language piece is DONE and verified (`hoc`
promoted to a real shared library, `appl/lib/hoc.b`/`module/hoc.m` - see "The
design changed" below); connecting it to an actual Danby harness is not yet
built. This documents a survey of `appl/danby/` done to answer two questions
asked directly: come up with something like a Tk-style declarative language
for authoring these models, since hand-writing a full Limbo plugin per model
is "too fiddly" - and check whether commonly repeated modules (starting from
`ballistics`) are hinting at a shared design pattern. Both are answered below
with real code read directly from the tree, not estimated. Two earlier
hypotheses in this same investigation turned out wrong on inspection and are
corrected in place rather than left standing: what the six "duplicate" files
actually are (below), and the first design's own bespoke verb-based language
for `rhs` equations - told directly it was wrong ("make the rhs a parsable
language... right now you make a bunch of hard to understand arrays of
coefficients... the user should be able to write the equation strings in the
command language in both the limbo interface and the shell") - see "The
design changed" for what replaced it.

## How the model families are actually shaped

`module/danby/*.m` declares seven family interfaces, each `implement`ed by a
plugin under `appl/danby/plugin/`, each driven by one shared UI harness under
`appl/temple/`:

| family | plugins | shared harness | shape |
| --- | --- | --- | --- |
| `Mechanism` | 70 | `appl/temple/mechanism.b` | parameter vector with per-parameter min/max; free state; `geometry()`+`links()` for a hand-drawn diagram; exactly 2 `observables()` |
| `Populationmodel` | 40 | `appl/temple/populations.b` | parameter vector with a `range`; separate `initial` vector + `statelabels()` |
| `Trajectory` | 17 | `appl/temple/trajectory.b` | parameter + `range`; state is always exactly 4 values (x,y,vx,vy) |
| `Orbital` | 12 | `appl/temple/orbital.b` | adds a `mass` array (one per body) alongside `parameter`; state is `4*len mass` |
| `Twospecies` | 10 | **none** | parameter + `range`; adds `equilibrium`/`fixedpoint`; **no `initial`, no `statelabels()`** - see below |
| `Flight3d` | 5 | none built | parameter with both `minima` and `ranges` |
| `Profile` | 2 | none built | no `rhs` at all - a static sampled field |

Four families have a real, working shared harness. `Twospecies` does not, and
the reason it doesn't is itself a finding (below). `Flight3d` and `Profile`
are too small (5 and 2 plugins) to have forced the issue yet.

Twelve more `module/danby/*.m` files (`pendulum.m`, `gravity.m`,
`ballistics.m`, `oscillator.m`, ...) are plain function libraries with no
`Model` adt at all - plugins call into them for one physics formula rather
than rewriting it. This matters directly for the language design below.

## Finding 1: a typical Mechanism plugin is about three-quarters boilerplate

Eight `Mechanism` plugins were counted line by line (preamble, blank lines,
brace-only lines, the fixed 13-function interface, the one-line `evaluate()`
trampoline, and local alias lines are all "scaffold"; everything left over is
"content"):

| file | total lines | scaffold | content | content % |
| --- | --- | --- | --- | --- |
| `simplependulum.b` | 80 | 61 | 19 | 23.8% |
| `dampedpendulum.b` | 80 | 61 | 19 | 23.8% |
| `doublependulum.b` | 80 | 62 | 18 | 22.5% |
| `slidingpendulum2.b` | 80 | 61 | 19 | 23.8% |
| `springpendulum.b` | 82 | 59 | 23 | 28.0% |
| `wheelpendulum.b` | 84 | 59 | 25 | 29.8% |
| `atwoodpendulum.b` | 86 | 59 | 27 | 31.4% |
| `magneticpendulum3d.b` | 95 | 60 | 35 | 36.8% |

Scaffold is nearly constant (59-62 lines) across all eight; essentially all
the length variation between models is genuine formula complexity, not
interface overhead. Content itself splits further into pure data (parameter
labels/ranges/defaults, title, `maxtime`, `links`, observable labels - 7 to 10
lines) and actual formula bodies (`rhs`/`geometry`/`observables` - as few as 8
lines, as many as 25 for a model with a real loop over four magnets).

## Finding 2: the Trajectory family is the cleanest case, and it's almost pure data

`appl/danby/plugin/ballistics.b` (55 lines) and `appl/danby/plugin/
basketball.b` (55 lines) were read in full side by side. They differ in
exactly four places: two numeric-literal lines (the constructor, and
`parameterranges()`), the title string, and one constant (the y-offset in
`initialstate()`). Every other line - the `rhs()` body, the call into
`ballistics->acceleration(...)`, `evaluate()`, the includes - is byte-for-byte
identical. All 17 `Trajectory` plugins share this shape: they call the same
one physics function (`ballistics->acceleration`) with different numbers.
This is the strongest single piece of evidence in the whole survey that a
purely data-driven model description - no expression language needed at all -
covers real, current models, not a hypothetical simple case.

## Finding 3: what the six "duplicate" files actually are (a correction)

Six top-level `appl/danby/*.b` files - `boom.b`, `competition.b`, `ecology.b`,
`epidemic.b`, `heartbeat.b`, `vaccination.b` - are 179-238-line hand-rolled UI
programs, even though a conforming plugin implementing a standard interface
already exists for every one of them. The first read of this (from a survey
agent) called the duplication "incidental, not required by anything
model-specific," which would have made deleting all six in favor of the
generic harness a safe, sizeable win. **That was checked by reading all six
files directly, and it does not hold.** Every one of them displays something
the matching generic harness cannot currently produce:

- `epidemic.b` and `vaccination.b` (both `Populationmodel`) show an R0/
  critical-coverage and conservation-law (`S+I+R` sums to 1) text overlay that
  `populations.b` has no equivalent of.
- `boom.b` (`Populationmodel`) shows a phase-space plot (wage-share vs.
  employment) with an equilibrium point, not a time series at all -
  `populations.b` only ever plots state against time.
- `competition.b` and `ecology.b` (both `Twospecies`) show a split
  phase-portrait + time-series view with the equilibrium point marked, and
  `competition.b` additionally classifies the regime ("stable coexistence" vs.
  "competitive exclusion") from a parameter threshold.
- `heartbeat.b` (`Populationmodel`) shows the same split phase-portrait +
  time-series view (muscle vs. drive), with direct-click state-setting across
  the whole phase pane rather than a narrow side strip.

None of these six can be collapsed onto the existing generic harness today
without losing a real, displayed feature. **Do not delete or redirect any of
them as-is.**

But the reason they exist as hand-rolled duplicates *is* a real, common
pattern - just a different one than "accidental copy-paste." `doc/
danby-models.md`, written before this survey and already in the tree,
specifies exactly this as intended, universal behavior and never built:

> `v` — Cycle physical view, time plot, phase portrait, and conserved
> quantities

and its own "Graphics architecture" section calls for a "small
model-independent scene description" whose handles "must not contain
model-specific behavior in the renderer." That vision was written down and
never implemented in the shared harnesses - `mechanism.b` and `populations.b`
support exactly one view (physical-or-bars, plus one time plot), with no
cycling and no phase-portrait or conserved-quantity mode at all. Every one of
these six files is an independent, hand-rolled attempt to add ONE of the two
missing universal views (phase-portrait-with-equilibrium, or
conserved-quantity/R0 overlay) to one specific model, because the shared
infrastructure to do it generically was never built. That is the actual common
design pattern these "duplicates" hint at: **not six accidents, but one
missing feature, independently reinvented six times.**

One structural fact makes this concrete: `Twospecies` (the interface behind
`competition.b`/`ecology.b`) has no `initial` array and no `statelabels()` -
unlike its sibling `Populationmodel`, which has both. That is exactly why no
generic `appl/temple/twospecies.b` harness was ever built: there is currently
no way for an arbitrary `Twospecies` plugin to tell a shared harness what its
state vector's starting values or names even are. `ecology.b` gets around this
by hardcoding `y := array[] of {0.55, 0.22}` and the labels "prey"/
"predators" directly in the harness file - and it already has a working,
argv-driven "load an arbitrary Twospecies plugin and drive it generically"
code path (`appl/danby/ecology.b:49-59`), which is most of a real generic
harness already, just never promoted out of one specific model's file, and
still missing genuine per-model initial-state/labels input.

## What already exists that a declarative language should build on

Two real precedents already live in this codebase, unprompted by this survey:

- **`Plotter.cmd()`, `appl/lib/plot.b`.** A small, line-oriented verb language
  (`table`, `colour`, `view`, `content`, `split`, `scale`, `axis`, `line`,
  `point`) driving every one of the four working harnesses identically,
  e.g. `graph.cmd("content margin 25 38 18 70\nsplit content x
  mechanismview 3 plotview 2 gutter 55\nview quantities plotview")`. This is
  already "something like a Tk language" in daily use in this exact codebase,
  not a new idea.
- **The parameter table is already a table, just not written as one.**
  `parameterlabels()`/`parameterminima()`/`parametermaxima()` are three
  separately-declared, positionally-correlated arrays that the harness then
  length-checks against each other at runtime and raises on mismatch
  (`appl/temple/mechanism.b:67-69`). That's a `(name, min, max)` record table
  wearing three parallel-array costumes, with a runtime assertion standing in
  for what one declaration would guarantee by construction.
- `appl/lib/dialog.b` has a weaker version of the same idea: hard-coded
  arrays of literal Tk command strings (`dialog_config`, `dialog.b:60-68`)
  looped through `tk->cmd`. Tk-specific and per-dialog, not table-driven from
  `(name, type, default, range)` - but the same "array of small command
  strings, dispatched generically" shape.

No generic form/parameter-widget builder exists anywhere in `appl/wm/` (59
files searched, zero matches for anything resembling a field-spec table).

## The design changed: rhs is a real parsable language, not verb syntax

Everything above this point in the doc's own history proposed a bespoke
verb-based mini-language for `rhs`/`geometry`/`observable` formulas - `call
ballistics acceleration state[2] state[3] param[2] ...`, arrays of positional
slots. Told directly that this was wrong: it is exactly the "hard to
understand arrays of coefficients" the request was trying to get away from,
and equations should be real parsable strings, usable identically from Limbo
and from a shell. **That design is superseded.** What replaced it, built and
verified this session, not just sketched:

`p9/cmd/hoc.b` - this tree's own translation of Kernighan and Pike's `hoc6`
desk-calculator language (1950 lines, a real recursive-descent parser and
tree-walking evaluator, oracle-verified against plan9port's own binary,
`hoctest.b`'s 31 cases) - already parses and evaluates exactly the equations
a Danby model's `rhs` needs: named variables, `+ - * / ^`, comparisons,
assignment, and the builtin math functions (`sin cos tan atan asin acos sinh
cosh tanh log log10 exp sqrt int abs`) every physics formula surveyed here
actually uses. It was a complete standalone command, not a library - no
external caller could reach its parser or evaluator directly. Both are now
exposed.

**What moved and what was added.** The whole implementation relocated to
`appl/lib/hoc.b` (`module/hoc.m` is its real interface, including the full
`Sym`/`Expr`/`Stmt` AST - `compile()` returns a `ref Expr` a caller can hold,
rebind, and re-evaluate, so a caller needs the real type shape, not an opaque
handle) - a genuine Inferno library any real userspace program can
`include`/`load` at `/dis/lib/hoc.dis`, not scoped to the `p9/` tree the way
`hoc(1)` the command is (`doc/plan9-port.md`'s "kept out of the regular
userspace" rule is about a *command* shadowing a real userspace tool in
`$dis` - a library shadows nothing). `p9/cmd/hoc.b` is now a 30-line thin
dispatcher over the same library, matching every other thin dispatcher in
this tree (`appl/danby/basketball.b` calling `appl/temple/trajectory.b`) -
`hoc(1)` still runs exactly as before from inside this tree's own bound
namespace.

Six functions added to the library, all reused directly rather than
reimplemented: `compile(src): ref Expr` parses one hoc expression (which may
itself be an assignment, `"dprey = birth*prey - predation*prey*predators"`)
from a string, using `bufio->sopen()` - already there, already used for
hoc's own `-e EXPR` flag, so no new lexer input mode was needed at all.
`eval(e): real` evaluates it. `symbol(name): ref Sym` finds-or-creates a
variable and returns a live handle whose `.val` field can be written
directly - the zero-lookup form for a hot per-step loop. `setvar`/`getvar`
are the occasional-use equivalents. `reset()` starts a fresh symbol table.

**Verified, not assumed**, before any of the design below was written:
`hoctest.b`'s 31 cases pass unchanged both before touching `hoc.b` and after
the full move to `appl/lib` (a real regression control, run at each step,
not just claimed). A standalone probe confirmed the property the whole
design depends on - the *same* compiled `ref Expr` re-evaluates correctly
after rebinding its variables via `symbol().val = ...`, which is what makes
this usable inside a tight per-rk4-step integration loop rather than
reparsing the equation every step - and that a bad `compile()` (a
deliberately malformed string) reports its error and leaves the library
fully usable for the next call, not wedged. A further check answered the
question this doc's own Finding 2 raised: does `ballistics->acceleration`'s
actual formula need a `call` mechanism into Limbo at all, or does hoc's own
`sqrt` builtin already cover it? Compiled and evaluated directly:
`speed = sqrt(vx*vx+vy*vy)` and `ax = -drag*speed*vx-lift*spin*vy` against
bound `vx=3, vy=4, drag=0.005, lift=0, spin=0` produced exactly 5 and
-0.075 - the real formula, unmodified, needs no library call at all. That
retires the `call` verb entirely for every family whose physics is scalar
arithmetic (Trajectory, most of Mechanism, all of Populationmodel and
Twospecies) - there is no "language design" left to do for the formula part;
it's already a real, working, general-purpose parsable language, not a
sketch.

**The one real boundary, confirmed rather than assumed:** hoc has no arrays.
`Sym.val` is a single `real`, and the `Expr` AST (`Num, Var, Assign, Bin, Un,
Not, PreIncDec, PostIncDec, Call, Bltin, ReadE`) has no indexing node at all.
That covers every family surveyed here except one: `moontrip.b`'s
`gravity->derivatives(state, mass, 1.0, softening, derivative)` operates on a
12-element state and a 3-element mass vector at once - not expressible as
named-scalar hoc equations. All 12 `Orbital` plugins are array math of this
shape. For those, "hand-written Limbo plugin, as now" is the honest answer,
not a gap to paper over - stated here plainly rather than left to surface at
plugin 130.

**How a model would actually use this**, once a harness is built to call it
(not done yet - see Recommended order): at load time, parse each of the
model's equation strings once via `compile()`, resolve every state/parameter
name once via `symbol()` and keep the `ref Sym` handles, and on each
integration step write the current values via those handles' `.val` fields
directly and `eval()` each pre-compiled tree - no re-parsing, no string
work, in the hot loop at all. `epidemic.b`'s own `rhs`, for example, is
these three real hoc lines, unmodified:

```
infections = contact*susceptible*infectious
recoveries = recovery*infectious
```

with `dsusceptible = -infections`, `dinfectious = infections - recoveries`,
`drecovered = recoveries` alongside them - five real hoc assignment
statements, parsed once, evaluated every step, exactly as they would be typed
at a `hoc` prompt.

## What still needs a small declarative table - and what doesn't

Equations are now a solved problem (above). Two things remain genuinely
outside hoc's job:

- **Parameter metadata** (name, min, max, default, title) is data, not a
  formula - hoc has nothing to do with it, and it doesn't need a new
  language either; see "What already exists" above (the three-parallel-array
  precedent already in `mechanism.b`). A real `(name, min, max, default)`
  record table, one per model, replaces that.
- **View-cycling metadata** for the six-file gap (Finding 3) - below.

## What closing the six-file gap (Finding 3) would need

Since Finding 3 is the more valuable pattern (a missing universal feature, not
duplicated code), the description language should carry the metadata a
generalized harness needs to offer `doc/danby-models.md`'s own `v`-cycled
views generically, instead of each model hand-rolling its own copy:

- a declared phase pair (which two state indices form the natural
  phase-portrait axes, and their labels) - covers `boom`, `competition`,
  `ecology`, `heartbeat` uniformly;
- a declared conserved-quantity/observable formula and, optionally, an R0-style
  derived value - covers `epidemic`, `vaccination`;
- for `Twospecies` specifically, the two currently-missing pieces
  `Populationmodel` already has: an `initial` array and `statelabels()`.

None of this requires touching `Mechanism`, `Trajectory`, or `Orbital` - it is
squarely a `Populationmodel`/`Twospecies` gap, and the fix is additive (new
optional interface members / verbs), not a breaking change to the 110
plugins in the other three families.

## Recommended order

0. **DONE, not a proposal**: hoc exposed as a real library (`appl/lib/hoc.b`,
   `module/hoc.m`) with `compile`/`eval`/`symbol`/`setvar`/`getvar`/`reset`,
   `p9/cmd/hoc.b` reduced to a thin dispatcher over it, `hoctest.b`'s 31
   cases unchanged before and after the move, a standalone probe confirming
   compile-once/rebind/re-eval and clean recovery from a bad `compile()`, and
   `ballistics->acceleration`'s real formula confirmed reproducible as plain
   hoc arithmetic with no call mechanism needed. This retires the equation-
   language design question entirely for every family except Orbital.
1. **A harness-side hoc adapter**: given a list of equation strings and a
   list of (name, initial-value) pairs, compile each equation once at model
   load, resolve every referenced name via `symbol()` once, and provide a
   `step()` that writes current values through those handles and `eval()`s
   each tree - the piece connecting the now-built library to an actual
   Danby model. Not built yet; the smallest real next step.
2. **Migrate one family through it as proof** - Populationmodel is the best
   first target (Finding 3's `epidemic.b` gives a real, already-understood
   equation set to migrate first), *not* Trajectory - Trajectory's plugins
   are already nearly free (Finding 2), so proving the hoc adapter matters
   more where the current cost (hand-written arithmetic, no shared library)
   is highest.
3. **Twospecies interface fix + generic harness.** Add `initial`/
   `statelabels()` to `module/danby/twospecies.m` (mechanical, touches 10
   plugins), then promote `ecology.b`'s already-working argv-driven dynamic
   load path into a real `appl/temple/twospecies.b`, verified against both
   `ecology.dis` and `competition.dis`. Leaves `ecology.b`/`competition.b`
   untouched (they have real bespoke content, per Finding 3) - this fills the
   missing fifth harness and gives the hoc adapter a second family to prove
   itself against.
4. **View-cycling in the shared harnesses**, driven by the phase/conserved
   metadata above - the real fix for the pattern in Finding 3, done once,
   generically, instead of per-model.
5. **Mechanism and Trajectory migrate onto the same hoc adapter** once 2-4
   have proven it, plus the small `(name, min, max, default)` parameter
   table from "What still needs a small declarative table" above -
   `Orbital`'s 12 array-math plugins are the one family that stays
   hand-written Limbo, stated plainly rather than discovered at plugin 130.

Steps 1-5 are design, not yet built; step 0 is real and verified.

## Does the same hoc library reach `appl/lib/pde.b`'s PDE solvers too?

Raised directly: "the observation is that the hoc parser can be used to feed
the pde solvers." Checked, not designed yet - this is a finding with real
numbers, and a fork for the user to call, not a code change.

**The seam already exists in the code, unbuilt-on.** `module/pde.m`/
`appl/lib/pde.b` has its own layered spec-string language (`mesh ...`,
`equation diffuse|wave|gray ...`, `solver ...`, `time step ...`, parsed by
`newproblem()`), but only 3 hardcoded equation kinds, each a fixed Limbo
function. `gray()` (Gray-Scott reaction-diffusion), specifically, already
separates the two parts of its own inner loop in its own header comment
(`appl/lib/pde.b:502-505`): "The reaction term is nonlinear and per-cell, so
this loop stays in Limbo - but the five-point gather that dominates it does
not have to. Both Laplacians are computed for the whole grid first and read
back here." That per-cell reaction body (lines 511, 520-521) is exactly
hoc-shaped - scalar arithmetic over named per-cell values (`av`, `bv`, `lav`,
`lbv`, `h`, `da`, `db`, `feed`, `kill`) - while the Laplacian gather
(`lapinto`/`lapintob`, backed by `math->lap5`/`lap7`) is whole-array and
stays outside hoc's reach (hoc has no arrays - see step 0 above).

**Measured, not estimated - hoc-per-cell vs. native, same exact workload.**
Compiled Gray-Scott's own reaction formula as two hoc expressions
(`av+h*(da*lav-av*bv*bv+feed*(1.0-av))` and its `b` counterpart), resolved
each variable once via `symbol()`, then timed `eval()` in a loop matching
`gray()`'s real inner-loop shape exactly - one `eval()` per field per cell
per stability substep, no batching (the honest worst case):

| grid | workload (cells x 4 substeps x 2 fields) | hoc-per-cell | native `gray()` |
| --- | --- | --- | --- |
| 128x128 | 131072 evals | 76 ms (1.72 Melem/s) -> ~13 fps-equivalent | 0.93 ms (140.9 Melem/s) -> ~1075 fps-equivalent |
| 64x64 | 32768 evals | 19 ms (1.72 Melem/s) -> ~53 fps-equivalent | scales the same way (Melem/s is grid-size-invariant); ~4300 fps-equivalent by the same ratio |

Native `gray()` is **~82x faster** than hoc-per-cell evaluation of the
identical formula, at any grid size (the Melem/s figure doesn't change with
grid - only the fps-equivalent does, since that's just workload/time). At
128x128, hoc-driven per-cell evaluation cannot keep up with an interactive
redraw loop. At 64x64 it lands around 53 fps-equivalent, which is a real,
usable interactive rate - "smaller grid for custom equations" is a genuine
answer, not just a hopeful one.

**Two design questions this raises, not yet decided:**

- **Which caller is this for?** `pde.m` has both an interactive `step()`
  (called from a redraw loop, where the ~13 fps at 128x128 would be felt
  directly) and a batch `run(p, until)` (where wall-clock time inside one
  call doesn't matter the same way). A hoc-driven equation kind is
  unconditionally viable for `run()` at any grid size, and viable for
  `step()` only at smaller grids or lower substep counts.
- **Does `pde.m` take a dependency on `hoc.m` at all?** A `Problem` able to
  hold a hoc-driven equation needs to carry both the compiled `ref
  Hoc->Expr` trees and the specific loaded `Hoc` module instance they're
  bound to (a compiled tree's `Sym` handles are tied to the instance that
  compiled them - confirmed in the step-0 probe). Today `pde.m` depends on
  nothing but `mesh.m`/`krylov.m`, both pure numerics; adding `hoc.m` would
  be the first time this module depends on a language/evaluator. That's an
  architectural call about `pde.m`'s own shape, not a detail to settle
  implicitly while extending the parser.
- A genuinely general reaction-diffusion equation kind (not just a
  Gray-Scott clone) would also want arbitrary named parameters bound as hoc
  symbols (a `param NAME VALUE` spec line, say) rather than hard-coding
  `feed`/`kill` by name - what makes this reach Turing patterns/
  FitzHugh-Nagumo instead of only reproducing the one equation already
  built. Naming this because it falls out of the same design, not
  proposing the grammar itself yet.

No change has been made to `module/pde.m`/`appl/lib/pde.b` - this section is
the measurement the observation asked for, and the fork it surfaces, for the
user to call before any grammar or `Problem` field gets added.
