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

- Follow Inferno conventions and prefer its configuration files, device tables,
  runtime capability checks, and `waserror`/`poperror` mechanism.
- Do not use `#ifdef` or other preprocessor conditionals to select platform or
  architecture behavior unless the difference cannot reasonably be expressed
  through Inferno configuration or runtime capability handling. Document the
  necessity next to any unavoidable conditional.
