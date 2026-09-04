# Working in this tree

Rules for an agent (or a person) working on this branch, written so a
fresh session can pick the work up without asking.

## Autonomy

Work without asking for input. The owner has said so explicitly: do
not end a turn with "do you want me to ..."; finish the item, start
the next one, and batch observations into a closing note. Routine
judgement calls (naming, test cases, which of several equivalent
designs) are yours to make; record them in the docs and in
`doc/ember-modern-plan.md` or `doc/ember-next-plan.md`. Stop only
for something destructive or a genuine change of scope.

## Do not stop until the plan is done

`doc/ember-next-plan.md` is the work list. Do not stop, and do not
hand the work back, until every item it marks as planned is
implemented, tested in both compilers where it is a language
change, documented in `doc/ember-language.md`, and committed; then
mark it done in the plan. Items the plan says are not planned
(integer widths, packages as directories) are out of scope unless
the plan is changed to include them. When the list is empty, find
the next gaps the way the earlier rounds did: translate or write
programs, survey the Limbo tree, and add what the code asks for --
then put those in the plan and continue.

## The Ember work

- Two compilers, always in lockstep: the C bootstrap in `ember/` and
  the self-hosted one in `appl/cmd/ember/`. Every language change
  goes into both, and `mk test` in `ember/` must stay green:
  `discmp.sh` requires byte-identical `.dis` from the two,
  `bootstrap.sh` requires the self-hosted compiler to reproduce
  itself. Tooling (`-i`, `-t`, `-F`) is in both compilers now, and
  `selffmt.sh` and `selftools.sh` compare them.
- Build with `mk install` in `ember/`, then in `appl/cmd/ember/`.
  Never hand-invoke the compilers to install.
- `tests/limbocmp.sh` (part of `mk test`, slow) compares every
  `ember/limbo/NAME.e` with `appl/cmd/NAME.b` under the emulator;
  a `NAME.orig` file names the original for a second translation.
  It builds the Limbo libraries it needs into `dis/`, which is not
  in git.
- The mkfiles track no header dependencies. An object built before a
  header changed stays stale, and `mk` will not notice: a stale
  `libmath/gfltconv.o` made `sys.print("%.2f", x)` drop digits for
  weeks. When output is wrong in a way the source cannot explain,
  remove the library archive and its objects and rebuild, then
  relink `emu` (`mk install CONF=emu-g` in `emu/MacOSX`).
- Never run two `limbocmp.sh` at once: both build into
  `tmp/limbocmp`, so they delete each other's `.dis` files and report
  differences that are not there. One run at a time, and let it
  finish.
- Do not edit a running shell script in place; replace it atomically.
  Do not rebuild `o.out` while a long test run is using it, and do
  not edit `ember/module/*.ei` or `ember/limbo/*.e` either: work in
  a scratch copy of `ember/` and let the run finish. A run that
  reports a dozen "ember compile" failures at once is usually an
  edit that landed underneath it, not a regression.
- Commit each finished item with its tests and its doc paragraph in
  `doc/ember-language.md`. Commit messages end with the
  `Co-Authored-By` and `Claude-Session` trailers used by the earlier
  commits on this branch.

## Docs to read first

`doc/ember-language.md` (the language), `doc/ember-modern-plan.md`
(what was added and how), `doc/ember-next-plan.md` (what is left),
`doc/ember-idioms.md` (Limbo patterns and their Ember forms),
`doc/ember-vs-limbo.md` (the translation study).

## Elsewhere in the tree

`os/` and `mkfiles/mkkernel-*` belong to another effort; leave them.
