# Repository guidance

- Act as an implementation agent: inspect the tree, make the requested changes,
  build and test them, and leave the working result in the repository. Do not
  stop at an explanation when the requested work can be performed locally.
- Keep progress updates brief; report concrete edits, commands, failures, and
  verified outcomes. Only ask for clarification when an essential choice
  cannot be resolved from the repository or the request.
- Do not ask the user whether to continue while requested work remains. Keep
  implementing, testing, and repairing the result until it is complete or a
  genuine external blocker requires user input.
- After a commit, continue with the next known implementation or verification
  step without asking the user whether to proceed.
- When a build or test still fails, keep investigating and applying fixes;
  report the failure only as progress while continuing toward a working result.
- Do not substitute a status explanation for implementation when the repository
  still contains a repairable failure.
- This rule applies to the current message as well as future messages: after
  documenting or committing a change, continue with the next repair step
  without asking for permission.
- After reporting a milestone, partial success, boot failure, or diagnostic
  address, immediately continue debugging and fixing it; never ask whether to
  continue after such an event.

- Kernels are self-contained.  Each flavor owns a directory under `os/` --
  `os/inferno`, `os/9front`, `os/osprey` -- and nothing else lives beside
  them.  Inside one, the layout is the one Plan 9 and Inferno use: the
  portable kernel in `port`, one directory per machine (`pc`, `pc64`, ...)
  beside it, and `ip`, `boot` and the rest as siblings.  A machine
  directory reads the portable code as `../port`.  Headers that belong to
  a target rather than to a source tree live in the target -- `Osprey/
  amd64/include`, `9front/amd64/include`, `Inferno/amd64/include`.  No file, header, mkfile or build rule under one
  flavor may name another flavor's source directory or target tree: osprey
  builds osprey, inferno builds inferno, 9front builds 9front.  Copy a file
  into the flavor that needs it rather than reaching across.
- What is shared is the host toolchain and the flavor-independent sources:
  the compilers and loaders in `utils`, `libmach`, the top-level `include`,
  and libraries such as `libsec`, `libmp`, `libfis` and `libkern` that are
  built from one source tree for every target.  A flavor may use those; it
  may not use another flavor's kernel code.
- Osprey has two sources: `doc/osprey-plan.ms`, and the author's own
  presentation of the system (`osprey.pdf`, summarised in section 1 of the
  plan).  Work through both without asking whether to continue.  Do not ask
  for input, confirmation or a choice between approaches until everything
  both describe is implemented; decide, build it, test it against a booted
  kernel, and say plainly in the man page and the commit what is real and
  what is only demonstrated.  `doc/osprey-progress.ms` holds the ordered
  plan and what is done; keep it current as each piece lands.
- Follow Inferno conventions and prefer its configuration files, device tables,
  runtime capability checks, and `waserror`/`poperror` mechanism.
- Do not use `#ifdef` or other preprocessor conditionals to select platform or
  architecture behavior unless the difference cannot reasonably be expressed
  through Inferno configuration or runtime capability handling. Document the
  necessity next to any unavoidable conditional.
