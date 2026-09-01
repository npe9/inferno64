# Working agreement for this repository

## Do not stop to say what is next — just do it

**This is the rule that gets broken most often, so it comes first.** If you know what the next step
is, take it in this turn. Do not end with "Next: ...", "The next thing is ...", or any other
description of work you are about to do — that is asking for permission with extra words, and it
costs a round trip to say "yes, carry on".

Report what happened, not what is about to happen. Say what you did, what it showed, and what was
wrong with it. Then keep going.

The only time a closing plan is right is when the work genuinely stops: the task is finished, or
something outside your control blocks it. Say which one, in a sentence.

`AGENTS.md` carries the repository-wide rules that apply to every agent working
here, including the autonomy rule: **do not ask for input, do not end a turn
with a question.** This file adds the detail specific to working with Claude.

**Picking up cold?** Read `doc/hpc-plan.md` first — current state of the
numerics/GPU work, the remaining plan, open bugs with reproducers, and the
gotchas that have cost real time.

## Autonomy: default to acting, not asking

**Keep working until the work is done.** Finish an item, commit it, and start the next one in the
same turn. Do not stop at a natural boundary to check in.

**Never end a turn with "want me to do X next?"** If there is an obvious next item, do it.

**Do not use AskUserQuestion for anything with a sane default.** Pick the sensible option, name it in
one line, and proceed: *"Doing X, it's the obvious default — say so if you wanted Y."* Reserve the
question tool for forks where the options lead to materially different, hard-to-undo outcomes.

**Batch, don't interrupt.** Non-blocking observations (a stray file, an unrelated dirty tree, a
latent bug found in passing) go in a short closing note. Say them once. Do not re-raise them.

**Do stop for:** destructive or irreversible actions, anything outward-facing (new remotes,
publishing, sending mail), deleting or overwriting things you did not create, and genuine forks where
guessing wrong wastes substantial work.

Scheduling the work is not the user's job. Every unnecessary question costs a round-trip and buys
nothing.

## Evidence: a change is not done until it is shown to work

**Verify with a negative control.** A test that has never been seen to fail has not been shown to test
anything. Before claiming a fix: disable it, confirm the failure returns, restore it, confirm the
failure goes. Several "fixes" here were unattributable until this was done, and one turned out not to
be attributable at all.

**Force the failure path if it does not occur naturally.** Fallback and error paths do not run on
demand; make them run (temporarily return an error, stub a failure) rather than reasoning about them.

**Pick a metric that can distinguish the failure.** Counting lit pixels could not tell 60 thin line
segments from 20 thick ones and reported a broken renderer as "120% of software". Count the thing
that actually differs.

**Prefer in-process evidence to screenshots.** `readpixels` on an image depends on nothing outside
the process. The accessibility API reports 0 windows for this backend whether or not it works, and
screenshots go black with no error when the screen locks.

**Beware diagnostics that move the bug.** Adding a watchdog to the fd stress reproducer made the hang
stop reproducing. If instrumentation makes a failure disappear, that is a data point, not a fix.

## Honesty about what was established

**Distinguish "fixed" from "not reproduced" from "found a real bug next to it."** Say which. If a
symptom was never reproduced, do not let a plausible nearby fix imply it was.

**Read the in-tree spec before calling something a bug.** `doc/dis.ms` defines `newa` as leaving
non-pointer memory undefined; that was documented behaviour, not a defect, and an elaborate
workaround was written before anyone read it.

**Look for an existing mechanism before building one.** `limbo -z` already existed for array zeroing;
`_drawdebug` already existed for libdraw diagnostics; `INFERNO_METAL_STATS` already established the
env-var convention. Check first.

**Correct the record when you are wrong.** Several long-standing notes in this tree were wrong
(`newwindow` "propagates no error" — it does, callers discarded it; the Fgrp "unlocked fd table"
hypothesis — the helpers are all locked). Fix the note, do not leave it to mislead the next person.

## Repository specifics

**`os/` is not ours.** The native kernel tree — `os/` and `mkfiles/mkkernel-*`, `mkfiles/mkfile-Inferno-*`
— is worked on in parallel by someone else. Never stage, commit, revert or tidy anything there, and
do not report its large dirty state as a problem. `emu/` (the hosted VM) is *not* covered by this and
is fair game, as are `appl/`, `module/`, `libinterp/`, `lib*/`, `man/`.

**Stage with explicit pathspecs.** Never `git add -A` or `git add .` — unrelated work-in-progress
lives in this tree and must not be swept into a commit.

**Build with `mk`, not by invoking `limbo` directly**, so the tree's own flags (including `-z`) apply.
`.dis` files are not tracked, so rebuilding produces no repository churn.

**Tests go in `appl/cmd/*test.b`**, matching the existing convention, with a `man/1/` page. Say in
BUGS what the test does *not* cover.

**Man pages**: verify with `groff -man -Tutf8 -k -ww`. `.TQ` does not exist here — use two `.TP`
blocks. Inside `.EX`, write `\en` not a raw newline escape, and never start a line with `'` or `.`.
The section `INDEX` files are hand-curated; do not blindly regenerate them.

**Network clients use this tree's own TLS, never `#C` as a transport.** `bsky(1)`/`masto(1)`
originally shelled out to the host's `curl(1)` through `#C` (man/3/cmd) because `module/ssl3.m` only
speaks SSLv3 and cannot reach a modern HTTPS host. That was a stopgap, not the design, and it must not
be repeated: no network client in this tree may drive a host command as its transport. `#C` itself
stays legitimate for what it was already used for elsewhere — running a real host binary as a test
oracle (`p9/cmd/prtest.b`), or genuinely operating on the host (`appl/cmd/os.b`) — the rule is
specifically about TLS/HTTP transport for a *network client*, not `#C` in general. If the SSL library
still can't reach a real host by the time you get here, fixing that is the actual task, not a reason
to route around it again. As of this rule landing, `bsky(1)`/`masto(1)` themselves are *still* on the
`#C`/curl stopgap — the SSL modernization (see `doc/` for the in-progress plan, if one exists by the
time you read this) hasn't shipped yet. Don't read the rule, read the code, and conclude the rule is
stale; migrating those two commands off `#C` is exactly the outstanding work this rule is naming.

**A Plan 9 userspace workalike is Limbo, in `p9/`, not C in `utils/`.** `utils/` builds
host-native binaries with the kencc toolchain — real work, but not "running in Inferno
proper," since it never touches Dis or `emu`. Anything meant as a native-to-Inferno
workalike for a Plan 9 userspace tool (awk, and whatever else `doc/plan9-port.md` turns
up) is Limbo source compiled to Dis, and lives under `p9/cmd/`, not `appl/cmd/` — kept out
of the regular userspace so it doesn't have to compete with or shadow the real thing.
`p9/cmd/mkfile` sets `DISBIN=$ROOT/p9/dis` (not the shared `$ROOT/dis`), so `mk install`
there is inert until someone deliberately runs, from *inside* a running emu, `bind -a
/p9/dis /dis` — an in-namespace path, not a host one prefixed with `$ROOT`; emu's own `/`
is not the host filesystem root (confirmed: an absolute host path fails to resolve inside
emu), it's whatever directory emu was launched from, so this only reaches the real
`p9/dis` when emu's cwd is the tree checkout, same as every other `mk`/`emu` invocation in
this file already assumes. Verified end to end: `bind -a /p9/dis /dis` then `awk -f
prog.awk file` resolves `awk` by bare name and runs it. `appl/cmd/`'s existing 212-file
`.b` tree is not touched by this rule — it already holds the real ports that took over the
regular userspace, and stays where it is.
