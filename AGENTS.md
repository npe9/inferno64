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
- Inferno has a second standing goal, independent of Osprey: pc64 (amd64),
  riscv64, riscv32, arm64 and armv7 (arm32) all booting to a shell with no
  obvious bugs.  riscv32 (os/inferno/virt32) now boots for real under
  qemu-system-riscv32 -- console banner, memory allocator, version banner,
  a vararg ABI self-test all printing over the emulated UART -- after
  adding real F/D floating-point support to za/zc/zl (it had none) and
  fixing three real bugs that support work surfaced: a zc register-
  allocation defect converting double to int, a zl encoder gap for
  large-offset frame addresses, and a _tas() porting bug (wrong return
  register) that hung the very first spinlock acquisition forever. What's
  left is exact, not vague: libkern/vlrt-riscv32.c's 64-bit unsigned
  divide returns wrong answers for realistic inputs (confirmed with
  hand-computed values printed from the running kernel), which is why
  the proc pool never sizes correctly and userinit() panics.  arm64 still
  has no board, only a compiler.  Building both the rest of the way, not
  just fixing an existing one, is part of the goal.  Do not stop, and do
  not ask whether to continue, until all five
  boot clean under QEMU with nothing left that looks like a real bug
  rather than a documented, understood gap.  `doc/inferno-ports.ms` is
  the record of what each architecture does and does not do yet, the
  bugs found and fixed, and what is still open; keep it current as each
  piece lands, the same discipline `doc/osprey-progress.ms` holds Osprey
  to.  Decide, build it, test it against a booted kernel, and say plainly
  in that document and in the commit what is real and what is only
  demonstrated.
- Write every path so it can be plumbed. A path in a document is absolute from
  the tree root (`os/osprey/port/devosprey.c`, `utils/cc/pgen.c`). A path in a
  source comment is either that, or relative to the file's own directory the
  way an `#include` in the same file would be written (`../adapter/ospreyrt.c`
  from `os/osprey/cmd/`). Never a bare basename for a file that exists more
  than once, and never a directory name standing alone where it looks like a
  path. Where a name refers to a function rather than a file, give the file
  too.
- Follow Inferno conventions and prefer its configuration files, device tables,
  runtime capability checks, and `waserror`/`poperror` mechanism.
- Do not use `#ifdef` or other preprocessor conditionals to select platform or
  architecture behavior unless the difference cannot reasonably be expressed
  through Inferno configuration or runtime capability handling. Document the
  necessity next to any unavoidable conditional.
- `long` is 32 bits.  This is a Plan 9 / Inferno idiom: the compilers,
  loaders and object formats under `utils`, and the kernels they build,
  were written where `sizeof(long) == 4`, and much of the code says
  `long` to mean a 32-bit word or a 32-bit field in an object file.  The
  host these tools are built on has a 64-bit `long`, which silently
  breaks that assumption: a struct of `long` fields laid out as bytes is
  twice the width the file expects, and a count derived from
  `sizeof(long)*8` is twice what the bit set it indexes can hold.  You
  cannot redefine the `long` keyword, so honour the idiom instead: where
  a `long` holds a 32-bit quantity, give it a 32-bit type — `int`, or an
  explicit pair of 32-bit words — rather than assuming the host's width.
  The symptoms are a compiler or loader that miscompiles only on a 64-bit
  host, and they have already been paid for three times: `NVAR` in
  `utils/cc/cc.h` (a variable count in units of `sizeof(long)`), the
  `Ieee` struct in every loader's `datblk` (two 32-bit words cast to
  bytes), and `symb` overruns aside.  Look here first when a number comes
  out wrong on the host but the sources look right.
