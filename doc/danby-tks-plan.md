# Danby model authoring: a declarative language, and what the "duplicates" actually are

**Status: design only, not yet built.** This documents a survey of `appl/danby/`
done to answer two questions asked directly: come up with something like a
Tk-style declarative language for authoring these models, since hand-writing a
full Limbo plugin per model is "too fiddly" - and check whether commonly
repeated modules (starting from `ballistics`) are hinting at a shared design
pattern. Both are answered below with real code read directly from the tree,
not estimated. One early hypothesis in this same investigation turned out
wrong on inspection and is corrected in place (see "What the six 'duplicate'
files actually are") rather than left standing.

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

## The design: a small model-description language, verb-based like `plot.cmd`

Given Finding 2 (Trajectory is almost pure data) and the "call one shared
physics function" shape visible in `simplependulum.b` (`pendulum->
acceleration`), `moontrip.b` (`gravity->derivatives`), and all 17 Trajectory
plugins (`ballistics->acceleration`), **the language needs a `call` verb into
an existing physics-library module for the families that already delegate to
one.** (An embedded general-purpose evaluator - this tree's own `hoc`, from
the Plan 9 real-C-translation backlog, is the obvious precedent if one were
ever needed for something more than arithmetic - stays out of scope; see the
correction below for what actually *is* needed alongside `call`.)

A sketch, deliberately in `plot.cmd`'s own idiom (newline-separated verb
lines):

```
title "Ballistics: a plain projectile with drag"
param speed   0.0 40.0 20.0
param angle   0.0  1.57 0.79
param drag    0.0  0.02 0.005
param lift    0.0  0.01 0.0
param spin    0.0 20.0  0.0
param gravity 0.0 20.0  9.81
initial 0.0 0.0 speed*cos(angle) speed*sin(angle)
maxtime 10.0
call ballistics acceleration state[2] state[3] param[2] param[3] param[4] param[5] 0.0 -> derivative[2] derivative[3]
```

with the *implementing* side unchanged: one small, real per-model `.b` file
still has to exist (Limbo modules are `load`ed by path; there is no way
around a real compiled unit per plugin), but it shrinks to a fixed handful of
one-line trampolines plus this table, not 55 lines of repeated control flow.
For the Trajectory family specifically, since every plugin already delegates
its entire `rhs`/`evaluate`/`initialstate` body to the same repeated pattern,
factoring that repeated logic into one shared library module (not just the
data) gets every file down near the interface's own floor - one trampoline
line per exported function (8 for `Trajectory`) plus includes plus the table,
roughly 18-20 lines versus the current 55, without inventing any new syntax
at all.

## Example strings, across families, and a correction they surface

Writing the strings out for real models across families - not just the one
Trajectory example above - surfaces a real gap in the "lead with `call`"
framing, corrected here rather than left standing.

`basketball.b`, same family as `ballistics.b` above, showing Finding 2's
four-line diff as literal text - only `title`, the six `param` lines, and the
`initial` y-offset change:

```
title "Shooting in basketball"
param speed    0 16    8.5
param angle    0 1.45  0.85
param drag     0 0.02  0.001
param lift     0 0.003 0.00015
param backspin 0 100   20
param gravity  0 20    9.81
initial 0 2 speed*cos(angle) speed*sin(angle)
maxtime 3
call ballistics acceleration state[2] state[3] param[2] param[3] param[4] param[5] 0 -> derivative[2] derivative[3]
rhs derivative[0] = state[2]
rhs derivative[1] = state[3]
```

`simplependulum.b` (`Mechanism`), needing the extra `geometry`/`links`/
`observable` verbs for the hand-drawn diagram - and showing `call` can target
a single derivative slot, not just a whole tuple:

```
title "The simple pendulum"
param length         0.1 4.0  1.0
param initialangle  -3.0 3.0  0.7
param initialspeed  -8.0 8.0  0.0
param gravity         0.1 20.0 9.81
param mass            0.1 5.0  1.0
param reference        0.0 1.0  0.0
initial initialangle initialspeed
maxtime 20
call pendulum acceleration state[0] state[1] length gravity 0 0 0 0 0 1 -> derivative[1]
rhs derivative[0] = state[1]
geometry 0 0 length*sin(state[0]) -length*cos(state[0]) -0.7 0 0.7 0
links 0 1 2 3
observable angle state[0]
call pendulum energy state[0] state[1] length gravity -> observable[1]
```

`moontrip.b` (`Orbital`) - `call` here has to take whole arrays (`state`,
`mass`, `derivative`), not scalar slots, since `gravity->derivatives`
operates on the full body set at once, not one body's coordinates:

```
title "A trip to the Moon"
param moonmass      0.001 0.05  0.0123
param launchradius  0.02  0.15  0.06
param launchoffset -0.08  0.08  0.0
param launchspeed   0.5   6.0   3.7
param launchangle  -1.0   1.0   0.18
param softening     0.0002 0.02 0.002
bodies Earth Moon craft
mass 1.0 moonmass 0.000001
call gravity derivatives state mass 1.0 softening -> derivative
```

**`epidemic.b` (`Populationmodel`) is where "lead with `call`" breaks down.**
There is no shared physics library behind SIR - the whole `rhs` is inline
arithmetic over named quantities, with no library call to delegate to at all:

```
title "SIR epidemic"
state susceptible 0.995
state infectious  0.005
state recovered   0.0
param contact  0 5 2.2
param recovery 0 2 0.55
rhs infections   = contact*susceptible*infectious
rhs recoveries   = recovery*infectious
rhs dsusceptible = -infections
rhs dinfectious  = infections - recoveries
rhs drecovered   = recoveries
conserved total = susceptible + infectious + recovered
observable r0 = contact/recovery
```

and `ecology.b`/`competition.b` (`Twospecies`), same shape, plus the
`phase`/`equilibrium` verbs proposed below for the view-cycling gap:

```
title "Predator and prey"
state prey      0.55
state predators 0.22
param birth     0 3 1.5
param predation 0 4 2.0
param death     0 3 0.75
rhs dprey      = birth*prey - predation*prey*predators
rhs dpredators = prey*predators - death*predators
phase prey predators
equilibrium prey = death
equilibrium predators = birth/predation
```

**The correction**: all 40 `Populationmodel` plugins and all 10 `Twospecies`
plugins have this shape - small named-quantity arithmetic with no shared
library behind it, unlike Trajectory and most of Mechanism. That is not a
reason to reach for `hoc` (this tree's own embedded-language precedent,
mentioned above as the fallback) - the actual need is four operators
(`+ - * /`) and parentheses over named state/parameter values, no functions,
no control flow, no user-defined anything. Much smaller than an interpreter,
closer to a four-function calculator than a language. So the language needs
*both* verbs from the start, not `call` first and arithmetic only if later
evidence demands it: `call` for the family that already delegates to a shared
library (Trajectory, most of Mechanism), and a small arithmetic-expression
`rhs`/`observable`/`conserved` form for the family that never had one
(Populationmodel, Twospecies) - each verb earning its place from a real
family already surveyed, not spread across two competing designs.

## What "tks" would need to add to close the six-file gap

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

## Recommended order, not all committed to in one pass

1. **Twospecies interface fix + generic harness.** Add `initial`/
   `statelabels()` to `module/danby/twospecies.m` (mechanical, touches 10
   plugins), then promote `ecology.b`'s already-working argv-driven dynamic
   load path into a real `appl/temple/twospecies.b`, verified against both
   `ecology.dis` and `competition.dis`. Leaves `ecology.b`/`competition.b`
   untouched (they have real bespoke content, per Finding 3) - this only
   fills the missing fifth harness for *future* Twospecies plugins and as a
   base to build the phase-portrait/conserved-quantity view modes into.
2. **View-cycling in the shared harnesses**, driven by the metadata above -
   the real fix for the pattern in Finding 3, done once, generically, instead
   of per-model.
3. **Trajectory-family library factor** (Finding 2) - smallest risk, smallest
   win (~600 lines across the least-fiddly family), good first proof that the
   "shared logic, not just shared data" idea works before trying it on
   `Mechanism`.
4. **The `tks` text format itself** (verbs above), plus a parser supporting
   both `call` (Trajectory, most of Mechanism) and the small named-quantity
   arithmetic form (all of Populationmodel, all of Twospecies - see "Example
   strings" above for why both are needed from the start, not staged), and a
   per-family generic plugin-loader - build against 2-3 real models per shape
   (a `call`-only one from Trajectory, an arithmetic-only one from
   Populationmodel) before touching the other ~140.
5. **Only if a full pass over Mechanism's 70 plugins later shows real need**:
   extend the small arithmetic form with loops or user-defined functions for
   bodies that don't reduce to either a single library call or flat
   arithmetic (`magneticpendulum3d`'s loop over four magnets is the clearest
   such case found so far). This is the only point where `hoc`-style
   generality would even be considered, and only against evidence.

Nothing above has been built yet. This is the design and the evidence behind
it; which step to start on is open.
