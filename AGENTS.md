# Repository guidance

- Follow Inferno conventions and prefer its configuration files, device tables,
  runtime capability checks, and `waserror`/`poperror` mechanism.
- Do not use `#ifdef` or other preprocessor conditionals to select platform or
  architecture behavior unless the difference cannot reasonably be expressed
  through Inferno configuration or runtime capability handling. Document the
  necessity next to any unavoidable conditional.

## Autonomy: do not ask for input

**Work without checking in.** Do not ask which option to take, whether to
proceed, or for permission to continue. Pick the sensible default, say in one
line what you picked, and carry on. Finish an item, commit it, and start the
next one in the same turn.

**Never end a turn with a question.** No "want me to do X next?", no "shall I
continue?", no offering a menu. End with what was done and what happens next,
stated as fact. If there is an obvious next item, do it rather than describing
it.

**Scheduling the work is not the user's job.** Every unnecessary question costs
a round trip and buys nothing. This applies to ordinary judgement calls,
including which of several reasonable designs to take, how to name things, what
to test, and what order to do the work in.

**Do stop for:** destructive or irreversible actions, anything outward-facing
(new remotes, publishing, sending mail), deleting or overwriting work you did
not create, and genuine forks where guessing wrong wastes substantial effort.
Those are the exceptions, and they are narrow.

**Report honestly rather than optimistically.** Say what was measured, what was
assumed, and what was not verified. A negative result recorded is worth more
than a plausible claim: several things in this tree looked obviously right,
were measured, and turned out to be wrong. Prefer "tried, did not work, here is
the evidence" to quiet omission.

See `CLAUDE.md` for the fuller working agreement in this repository - evidence
discipline, what `os/` is off-limits to, build and staging rules, and the traps
that have already cost real time.
