# Repository guidance

- Never stub, cheat, or misrepresent.  Do not fake, mock, hard-code, or
  disable a result to make something appear to work.  Do not describe
  cleanup, a partial step, or a demonstration as if it were the finished
  feature.  State plainly what is real, what is only demonstrated, and
  what is still broken, backed by a booted kernel and the actual test
  output -- never a remembered or assumed result.  If a thing does not
  work, say so and keep fixing it.  This rule is absolute and overrides
  any pressure to look finished.
- Finish the work before asking.  Do not hand back a characterisation of
  a bug in place of a fix, and do not stop to ask the user anything while
  the requested work can still be advanced locally.  Complete it, verify
  it against a booted kernel, then report.
- The target is real hardware, not the emulator.  QEMU (or any emulator)
  is a temporary test bench; the point is a correct port to the physical
  board, not something that merely runs under emulation.  Where the two
  differ, hardware correctness takes precedence over getting it to pass on
  the emulator: implement what the real device requires -- flow control,
  memory-ordering barriers, errata workarounds, real timing and reset and
  init sequences -- even when the emulator would pass without it, and
  never rely on emulator leniency or on an emulator-only artifact.  When a
  failure turns out to be the emulator's bug, not the port's, treat it as
  a test-bench problem (fix or route around the emulator); do not contort
  the real hardware path to match an emulator quirk.  Note in the code and
  the commit any place the emulator is more forgiving than hardware, so
  the gap is visible before the board is real.
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
- Never ask for input.  This is a standing instruction from the user
  (2 September 2026) and it applies to every kind of question: not
  whether to continue, not which of two approaches to take, not whether
  a scope change is wanted, not for confirmation before a build, a boot,
  a commit or a rewrite of a document.  Decide, do it, verify it against
  a booted kernel, record it, and go on to the next item in
  `doc/osprey-progress.ms` (for Osprey) or `doc/inferno-ports.ms` (for
  the Inferno ports).  A question written at the end of a reply is the
  same as stopping, and stopping is what this rule forbids.  The one
  exception is a genuinely destructive action outside the tree.

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
  obvious bugs.  riscv32 (os/inferno/virt32) now reaches a real,
  interactive shell under qemu-system-riscv32 -- verified live, not just
  a printed prompt: a piped-in command produced the command's actual
  output back over the emulated UART.  Getting there needed real F/D
  floating-point support added to za/zc/zl (it had none at all) and a
  string of real bugs that surfaced once that support existed and boot
  got further each time: a zc register-allocation defect, a zl encoder
  gap, a _tas() porting bug, a zc compiler bug building vlong literal
  constants with their words swapped, mstatus.FS never being enabled,
  a null-pointer robustness gap in shared debug instrumentation, and
  finally the real blocker -- os/inferno/init/ is shared across every
  board, and virt32's board config named the same INIT program riscv64's
  virt board already uses, silently linking in a word-size-mismatched
  .dis built for the wrong DISWORD.  Full history, each bug found live
  and verified, is in doc/inferno-ports.ms; do not re-derive it, read it.
  arm64 (os/inferno/virtarm64) now has a real board, not just a
  compiler, and boots past every stage of main() -- pool init, trap
  init, MMU init, clock init, proc init, screen init, PCI arch init,
  chan dev reset, UART console setup -- into loading /osinit.dis and
  its dependent modules.  Three real toolchain bugs (an empty ObjArm64
  reader in utils/libmach, a swapped STXR operand order in utils/7a,
  missing MOVBU long-displacement rows in utils/7l/optab.c) and three
  real bring-up bugs (a MOV-into-RSP mis-encoding in _main, _tas()
  storing the old lock value back instead of the new one, and a shared
  libinterp/load.c bug indexing m->type[] with garbage) are found and
  fixed, each verified live under QEMU/lldb, not assumed from reading
  the assembly.  Not yet at a shell: past loading a couple of modules
  the board deadlocks on kmesg.lk, root-caused to a genuine data abort
  inside poolfree() (heap metadata corruption) whose report can't print
  because the fault handler needs the same lock the interrupted code
  already held -- the deadlock's mechanism is understood, the abort
  that triggers it is not yet root-caused to who corrupted the pool
  block.  Full history, each bug found live and verified, is in
  doc/inferno-ports.ms; do not re-derive it, read it.  Do not
  stop, and do not ask whether to continue, until all five
  boot clean under QEMU with nothing left that looks like a real bug
  rather than a documented, understood gap.  `doc/inferno-ports.ms` is
  the record of what each architecture does and does not do yet, the
  bugs found and fixed, and what is still open; keep it current as each
  piece lands, the same discipline `doc/osprey-progress.ms` holds Osprey
  to.  Re-checked live on 2 September 2026 (the "Taking stock" section
  there): riscv64/virt had regressed to a deterministic panic right
  after DHCP -- the pc64-only freehist diagnostic in
  `os/inferno/port/alloc.c` dereferencing a Prog whose `R.M` held the
  Dis nil `H`, a read pc64's page tables let through and riscv64's
  machine mode does not -- guarded, and it reaches an interactive shell
  again; pc64 crashed 15 of 15 boots under a 150 s timeout, old and
  rebuilt binary alike; armv7, arm64 and riscv32 are as recorded.  The
  same section lists the drivers a modern machine needs that no board
  has (xHCI USB, NVMe, PCIe ECAM and MSI, virtio 1.0, current NICs and
  Wi-Fi, device-tree parsing, PSCI, GICv3, S-mode with SBI) and where
  source for each already sits in the sibling flavours.  Since then the
  9front drivers that bridge with small shims were taken into
  os/inferno (the section "Taking the drivers 9front already has"):
  sdnvme, sdvirtio10, ethervirtio10, devusb+usbxhci, etherbcm,
  etheryuk, ether82598, etheriwl+wifi, all linked into pc64, the
  first four verified live under QEMU q35 (NVMe and virtio 1.0 disks
  read back a host-written sector, DHCP over the virtio 1.0 NIC, xHCI
  root hubs listed in /dev/usb/ctl) through os/inferno/init/pc64devinit.b
  and the pc64dev configuration.  The same section carries the QEMU
  machine-by-device delta and the ordered plan; the next pieces are a
  Limbo usbd against /dev/usb, virtio 1.0 on the mmio boards, ECAM and
  MSI on pc64, then swapping devsd, ethermii and devaudio for 9front's
  so the drivers that wait on them (sdmmc, etheri225, audiohda) come
  across unchanged.  Items 1 and 3 are done: pc64 links etherigbe and
  ether8139 (e1000 and RTL8139 get DHCP leases), and riscv64/virt now
  runs the portable ../port/pci.c over its ECAM through
  os/inferno/riscv/pciecam.c with NVMe, virtio 1.0 disk and NIC, and
  xHCI verified on its PCIe.  That found three "long is 32 bits" bugs
  on the wide-constant path from jc to jl (every 64-bit constant was
  silently truncated on riscv64; fixed in utils/jc/txt.c, jc/swt.c,
  jl/obj.c, every riscv64 library and kernel rebuilt) and the same
  test in utils/7c/swt.c (fixed), plus an OPEN arm64 one: 7c's
  optimiser narrows a 64-bit constant move to MOVW (correct with -N),
  not yet located.  intrenable()/intrdisable() now take (irq, handler,
  arg, tbdf, name) on every board.  Item 2 is done: appl/cmd/usb/usbd.b
  (Limbo, after 9front's nusb) enumerates hubs and boot-protocol HID
  devices over the kernel stack; a USB keyboard and mouse deliver keys
  and pointer events verified on riscv64 under QEMU.  That fixed three
  general kernel bugs: rwrite()/kseek()/kremove() leaked device errors
  as fatal Limbo exceptions, devusb's "new" turns an unknown type name
  into a control endpoint, and /dev/pointer refused a writer beside its
  reader.  Item 4: pc64 reaches PCIe configuration space through the
  ACPI MCFG window (ECAM) when there is one, ports otherwise; the
  taken drivers use INTx, so MSI stays untransferred.  The riscv64
  smoke test then exposed a dis.c bug: swiprog()'s note to a kproc
  whose released Prog had already left raised Eintr in vmachine's
  idle sleep with no current Prog and faulted in propex(); vmachine
  now ignores that stray interrupt.  riscv64 reaches its interactive
  shell 2 of 2 after it.  The arm64 half of the wide-constant bug is
  fixed too (utils/7c/reg.c typed hoisted constants as long); the
  board rebuilt from scratch still stops at its first module load.
  Items 5 and 6 done: 9front's devsd/sd.h/sdscsi, sdiahci, sdvirtio,
  sdmmc and pmmc (SD cards verified on q35 and riscv64), and 9front's
  ethermii with ether8169/82563/igbe/i225 (e1000 and e1000e get
  leases; igb never sees link, open).  Item 7 done: 9front devaudio and
  audiohda, verified with QEMU intel-hda.  Item 8: -smp 2 brings cpu1
  up and then hits pc64's heap fault; blocked on that bug.  arm64 now
  reaches an interactive shell: three kernel/asm bugs (unsaved trap
  registers, setlabel storing XZR for SP, the 7c peephole deleting a
  32-bit sign-extension MOVW as a self-copy) and a 7l logical-immediate
  N-bit bug, each verified live; virtarm64init.b is its console init.
  Item 9 (device trees, PSCI, GICv3, S-mode/SBI, SoC drivers) is
  untouched.  Decide, build
  it, test it against a booted kernel, and say plainly
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
