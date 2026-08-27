# A Limbo (source) REPL: a plan

**Status: DONE.** Built as `appl/cmd/limborepl.b`, following this plan
directly - see `man/1/limborepl` for the user-facing documentation and
its own BUGS for what was found while building it. In short: the
architecture in this plan carries over exactly as predicted (compiling
real Limbo source at runtime via `/dis/limbo.dis`, invoked as an
ordinary Command the same way `disrepl(1)` invokes `/dis/asm.dis`, was
confirmed end to end with a standalone probe before writing a line of
the real file). The v1 spec below was built essentially as written,
with two things worth recording because they weren't obvious from the
plan alone:

- The declaration/statement classifier needed one refinement past "does
  the line look like `name: adt|module|fn ...`": a `name:` prefix is
  ALSO how Limbo writes a labeled statement (`top: for(;;){...}`, a real
  shape this very backlog's own `marshal.b` uses for `parseloop:`), and
  the two are told apart only by what follows the colon - `for`/`while`/
  `case`/`alt`/`pick`/`do` means it's a label on a statement, not a
  declaration. Missing this would have silently misfiled every labeled
  loop as module-scope garbage.
- Redeclaration option (b) (require `=` yourself after the first `:=`)
  was tried first per the plan's own suggestion and works well in
  practice - confirmed directly: typing `x := 8;` after an earlier
  `x := 6;` fails to compile with a real redeclaration error, is
  rejected cleanly ("not added"), and the session continues unaffected.
  No need was found to build option (a).

An advisor review after the initial build found one real gap in the
classifier, not caught by any test: Limbo's own multi-name declaration
shape (`x, y: int;`) was misfiled as a statement, because the scan
stopped at the first comma and never reached the `:`. That shape is
*also* legal Limbo inside a function body (a local, not the
module-scope global the line asked for), so it silently compiled
instead of failing loudly - the exact "compiles but means something
else" failure that's hardest to notice later. Fixed by scanning past
`name (, name)*` before requiring the colon, confirmed by a negative
control (reverting the scan reproduces the misfiling exactly) - see
`man/1/limborepl`'s own BUGS. The same review asked whether a raising
line leaves the session stuck; confirmed directly that it doesn't:
`.drop` recovers cleanly once enough lines are dropped to remove the
raising line itself, exactly as "kept because it did something real"
implies.

Written 2026-08-25, at the user's request for a plan rather than a build.
Grounded in reading `disrepl(1)`'s actual source and man page and in
checking, rather than assuming, that the pieces this would need actually
exist in this tree - they do, and the finding that they do is most of
what makes this plan tractable.

## What already exists, and why it matters

**`disrepl(1)` already solved the hard structural problem** - keeping a
running program's state across lines typed one at a time - just one level
down, at raw Dis assembly rather than Limbo source. Its mechanism,
read directly from `appl/cmd/disrepl.b` and its man page:

1. Every line typed is kept, not just the latest one.
2. On each new line, the *whole accumulated program* is written out and
   handed to `/dis/asm.dis` (spawned as an ordinary Command, the same way
   any Inferno program launches another), which assembles it into a
   fresh `.dis`.
3. That `.dis` is `load`ed by path and run, under a time limit (a
   `ticker`/`runner` pair) so a bad line can't hang the REPL.
4. The wrapper's frame, type descriptor and link section all come from
   Limbo-compiler-generated code, so the garbage collector is told the
   truth about which words hold pointers without disrepl working out a
   descriptor by hand.

The documented consequence - "a line with an effect outside the virtual
machine happens again on every subsequent line" - is not a bug to fix in
a Limbo REPL. It is inherent to "replay everything, from scratch, on
every line," and any REPL built the same way inherits it and should say
so as plainly as disrepl's own man page does.

**The other load-bearing fact, checked rather than assumed: the Limbo
compiler itself runs as an ordinary Inferno command.** `/dis/limbo.dis`
exists, built from `appl/cmd/limbo/limbo.b` (3107 lines - a real,
complete compiler, not a stub), with the identical CLI this session used
all along via the host `limbo` binary: `limbo file.b` produces
`file.dis`. That means a source-level REPL can reuse disrepl's exact
architecture, one compiler stage further up - swap `/dis/asm.dis` for
`/dis/limbo.dis`, and accumulated **Limbo source** instead of accumulated
assembly text. This was the single biggest open question before writing
this plan, and it resolves in the easy direction: nothing needs to be
built or ported to make the compiler available at runtime, it already is.

## What disrepl did NOT have to solve, and this will

Raw Dis assembly has no declarations, no types, no scoping rules beyond
fixed frame offsets - "replay everything as one flat stream of
instructions" is a complete answer for it. Limbo source has real
grammar, and that grammar splits into things that belong in different
places in a module, which is the actual new problem this plan is about:

- **Declaration placement.** A module's `include`s, ADT/type
  declarations, and function definitions are distinct from the
  imperative statements that live inside a function body. A REPL line
  defining a new type (`Point: adt { x, y: int; };`) has to land in a
  different part of the generated wrapper than a REPL line that's a
  plain statement (`p := Point(1, 2);`). **This needs a real classifier**,
  even a rough one (does the line look like `name: adt|module|fn ...`
  vs. everything else), and it is the piece with no precedent in
  disrepl to build on - flagged here as the hardest unsolved design
  question in this plan, not glossed over.
- **Redeclaration.** Limbo forbids `x := ...` twice for the same name in
  one scope - confirmed repeatedly this session as a real, sharp-edged
  compile error, not just a warning, the second time it happens.
  Replaying the whole accumulated statement list means a REPL user
  re-entering `x := 5` on a later line (an ordinary thing to want to do
  interactively) will not compile as-is. Two honest options, not yet
  chosen between: (a) track declared names across lines and silently
  rewrite a repeated `name := expr` into `name = expr`, or (b) require
  the user to write `=` themselves after the first declaration and
  document why. (a) is more REPL-like; (b) is less code and no
  rewriting-the-user's-input surprises. Worth deciding by trying (b)
  first, since it's nearly free to build and might turn out to be fine.
- **Printing a value.** Limbo has no implicit "print the last
  expression" the way an interactive Python or Scheme does - a bare
  expression typed at a REPL prompt is not by itself a complete Limbo
  statement in most positions. The honest starting point is: don't
  guess. Require the user to write `print(...)` themselves, exactly as
  they would in a real Limbo program, rather than building a fragile
  heuristic for "does this line look like an expression I should wrap
  and print" that will misfire on some fraction of real input. A
  smarter version of this is a plausible v2, not a blocker for v1.
- **Recompile cost grows with the session.** Each line recompiles and
  reruns everything so far, so a long interactive session gets slower
  per line as it goes, the same shape of cost disrepl already has but
  worse in practice since a real `limbo` compile is heavier than
  assembling accumulated instructions. Fine for the tens-of-lines
  sessions this is actually for; not something to solve in v1.
- **Error recovery.** A line that fails to compile should not be kept in
  the accumulated history - only append it once compiling and running
  it has actually succeeded, and report the compiler's own error
  otherwise, leaving the prior working program exactly as it was for the
  next attempt. This one has a clean answer and isn't a hard problem,
  just worth stating so it's built in from the start rather than patched
  in after the first time a bad line corrupts the session.

## What a v1 could reasonably do

- Accept one Limbo statement or declaration per line.
- Classify each line, on the rough heuristic above, into "goes at module
  scope" or "goes inside `init()`'s statement list."
- On each line: write the synthetic module, spawn `/dis/limbo.dis` on it
  (matching disrepl's `runcmd` pattern exactly), and on success `load` and
  run the result under a time limit, matching disrepl's ticker/runner
  safety net line for line where it applies.
- On a compile error, report it and leave the accumulated program
  unchanged.
- No implicit value printing in v1 - the user calls `print()` explicitly,
  as in ordinary Limbo.
- Redeclaration handled by option (b) above (require `=` after the
  first `:=`) unless trying it in practice turns out to be too
  unpleasant to use, at which point option (a) is the fallback.

## What this plan is not

Not an incremental compiler, and not an attempt to preserve live runtime
state (open channels, spawned processes) across a redefinition the way a
genuinely live-patchable system would. It is disrepl's own proven
"replay everything, recompiled" strategy, moved up one level from
assembly to source, with the one genuinely new problem - where a
declaration belongs in a module versus a function body - named plainly
rather than assumed away.
