# Repository guidance

- Never stub, cheat, or misrepresent.  Do not fake, mock, hard-code, or
  disable a result to make something appear to work.  Do not describe
  cleanup, a partial step, or a demonstration as if it were the finished
  feature.  State plainly what is real, what is only demonstrated, and
  what is still broken, backed by a booted kernel and the actual test
  output -- never a remembered or assumed result.  If a thing does not
  work, say so and keep fixing it.  This rule is absolute and overrides
  any pressure to look finished.
- Fix the tool, not the caller.  When a bug is in a shared tool -- the
  compiler, the assembler, the loader in `utils`, or any shared library --
  fix it there, at the root.  Do not work around a toolchain bug in the
  code that trips over it.  A source-level workaround (materialising a
  value into a local, reordering to dodge a bad code path, avoiding a
  language construct that miscompiles) masks the defect for one call site
  while leaving it live for every other caller in the tree, and it is a
  form of misrepresentation: the tool is still broken and the next bug it
  causes looks unrelated.  Root-cause the miscompilation, reduce it to a
  minimal case (e.g. `7c -S` on a few lines), fix the code generator, and
  rebuild everything the tool touches.  If you must land a workaround to
  unblock, it is temporary: the compiler fix is the deliverable, and the
  workaround comes back out once the tool is correct.
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
  taken drivers used INTx.  MSI, single-vector MSI-X and
  multi-vector MSI-X are all wired now: `pcimsixintrenable` and
  `pcimsixintrdisable` in `os/inferno/port/pci.h` are the portable
  entry points (nil on every board but pc64, so a driver must test),
  `os/inferno/pc/irq.c` provides them through a split-out
  `intrenablev()` and a new `Vctl.msixvec`, and
  `os/inferno/port/sdnvme.c` takes two vectors -- admin on 0, the
  I/O completion queue on 1 -- verified live under QEMU q35 with
  both fallbacks (msix_qsize=1, and riscv64 where the pointers are
  nil).  The console is no longer assumed to be the 16550 at 0x3F8
  either: `acpispcr()` in `os/inferno/pc/archacpi.c` reads ACPI's
  SPCR table and `i8250spcrconsole()` in `os/inferno/pc/uarti8250.c`
  moves the console to the UART it names.  Sections 7 and 8 of
  `doc/inferno-cloud-plan.ms` have both, with what each boot
  printed.  arm64 is further along than the record said: the `init`
  section of `os/inferno/virtarm64/virtarm64` named `virtinit`, the
  RISC-V board's init, so every arm64 boot had been running another
  board's test suite; with `virtarm64init` in its place the board
  enumerates its PCIe host bridge over ECAM and reads an NVMe disk
  (`ARM64-DISK-OK /dev/sdN0/data read 512 bytes`) with xHCI and
  virtio-net found on the same bus.  The riscv64
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
  Item 9 (device trees, PSCI, GICv3, S-mode/SBI, SoC drivers) is no
  longer untouched, and `doc/inferno-platforms.ms` is the survey that
  records how far each got, board by board, against booted kernels:
  `os/inferno/port/fdt.c` is a device-tree reader called by virt,
  virts, virt32, virt32s, shakti and raspi3b (memory, PLIC, ns16550a
  and virtio,mmio bases); PSCI and GICv3 are in virtarm64 and raspi3b;
  virts and virt32s are S-mode boards entered by OpenSBI at
  0x80200000; sifiveu, mangopi, raspi3b and teensy41 are SoC boards.
  What is still missing in each is catalogued there -- no
  interrupt-specifier or `ranges` decoding in the FDT reader, no
  ACPI outside `os/inferno/pc`, `MAXMACH 1` on every board but pc and
  pc64, no IOMMU/SMMU anywhere, no APLIC/IMSIC, no FAT32 in
  `appl/cmd/dossrv.b`, and no display outside virtio-gpu and the
  pc64 loader's framebuffer.
  That document also records that fifteen of the sixteen boards build
  (after adding the missing `Inferno/{aarch64,riscv32,riscv64}`,
  `MacOSX/arm64` and `dis32/...` entries to `lib/emptydirs`, and
  building the `/dis32` tree the 32-bit boards need with
  `mk DISROOT=dis32 DISWORD=4 install` in `appl/lib` and `appl/cmd`);
  the exception is `os/inferno/pc`, which now gets past the `FPU`
  typedef and the `active.machs` array and fails on
  `os/inferno/pc/i8259.c:199 not a member of struct/union: enable`,
  because `os/inferno/pc/io.h` still carries the pre-9front `Vctl`
  while `os/inferno/pc/i8259.c` is the 9front one, with `trap.c`,
  `mmu.c`, `memory.c` and `l.s` behind it.
  armv7 builds but panics in module load.
  The Dis heap fault is found and fixed.  `os/inferno/pc64/l.s`'s
  interrupt entry built `Ureg.ds`/`Ureg.es` with `MOVW ES, AX` /
  `MOVW DS, AX` *before* `PUSHQ AX` saved the interrupted code's `AX`,
  and `MOVW` from a segment register assembles to the 32-bit form,
  which zero-extends -- so every interrupt on every `pc64` boot handed
  the interrupted code back an `AX` holding the `DS` selector, which is
  0.  Compiled code holds a call's return value in `AX` for one or two
  instructions before storing it, so an interrupt in that window turned
  a good pointer into 0: `OP(new)` storing `H2D(nil)` == 0x18,
  `OP(addc)`/`OP(slicec)`/`OP(insc)` storing a nil `String*`, and the
  `movp`, `addstring`, `smalloc` and `D2B` panics downstream.  Proved
  by `os/inferno/pc64/regtorture.s` (twelve registers spun: clean with
  interrupts off, `AX` became 0x0 with them on), fixed by reserving the
  four segment words with `SUBQ $8, SP` and filling them in at
  120..126(SP) after `AX` is saved.  Thirty consecutive boots reach a
  shell with no capture and no panic; before it, 1/24, 9/12, 8/12,
  10/25 and 8/13.  The multicore branch measured the same kernel either
  side at a larger scale, 96 boots each: 82 of 96 panicked before, 2 of
  96 after, every signature gone but two GPFs in `modstatus`, and
  `-smp 2` boots with `cpu1` up.  What made it findable was `libinterp/heap.c`'s
  `freeptrs` calling `trackclear` at frame teardown, closing the
  stale-registration channel the comment above `NTRACK` predicted, so
  the captures that were left all had the corrupted word equal to
  `R.d`.
  `utils/libmach` also had no arm64 executable support at all -- R_MAGIC
  had no exectab entry and there was no `Mach` -- so `crackhdr` answered
  "Can't read header" for every `7l` output.  `utils/libmach/7.c` and
  `ureg7.h` add it; there is no arm64 disassembler, so it is
  deliberately not wired into `setmach.c`'s `machines[]`, since a `Mach`
  is all `crackhdr`/`syminit` need and a `Machdata` would claim a
  disassembler that does not exist.  That is what turned the arm64 EFI
  loader's fault address into a symbol.
  The arm64 EFI loader boots the arm64 kernel.  From the
  removable-media path under stock AAVMF with a fresh variable store,
  `bootaa64.efi` relocates itself into memory it asks the firmware for
  as `EfiLoaderCode`, zeroes its bss, reads `plan9.ini`, reports the
  ACPI RSDP it took from the UEFI system table, loads
  `/aarch64/ivirtarm64` and enters it -- and the kernel reaches an
  interactive shell.  That is the gate `doc/inferno-platforms.ms` 4.3
  puts in front of the arm64 server, because on arm64 the RSDP comes
  from the system table and nowhere else.  Ten defects were fixed to
  get there, listed in `doc/inferno-cloud-plan.ms`: `aa64.s` never set
  `R28`/`SB`; `tools/aout2efi` wrote an invalid PE (0x200 section
  alignment, characteristics with neither `MEM_READ` nor `MEM_EXECUTE`,
  and `AddressOfEntryPoint` computed as `entry-base`); the `-R4096`
  link needed the single section to reproduce the resulting page gap in
  the file; the copy destination had to be claimed as `EfiLoaderCode`
  because ArmVirtQemu marks free memory non-executable; `eficall` kept
  the link register and stack pointer in `R10`/`R11` across a firmware
  call, which AAPCS64 lets the firmware destroy; `reloc` neither
  allocated nor zeroed the bss; `confaddr` was the PC's `CONFADDR`
  (0x1200); `jump` was `B ,-4(PC)`, which branches back four
  instructions rather than to itself; `bootkern` read only Plan 9 a.out
  and now reads ELF64; and its `& 0x0FFFFFFF` entry mask is a PC
  convention that gives 0 for a kernel at 0x40000000.  `memconf`'s 96
  KiB memory-map buffer moved from the stack to bss on the way past.
  Not done and stated in the code: `jump` does not clean the D-cache
  over the loaded kernel before clearing `SCTLR_EL1.C`, because QEMU
  models no cache and the loop could not be exercised.  The loader's configuration reaches the kernel:
  `jump` passes the block in `x1`, which the AArch64 Linux boot
  protocol reserves as zero so QEMU's `-kernel` path is undisturbed;
  `os/inferno/virtarm64/l.s` records it beside `dtbptr`; a new
  `os/inferno/virtarm64/bootargs.c` (the generic half of
  `os/inferno/pc/bootargs.c`, without the multiboot and PVH readers)
  copies it first thing in `main` -- it lives in memory the kernel may
  allocate over -- and parses it; `getconf` was a stub returning nil on
  this board and is real now; `init0` calls `setconfenv`.  So `*acpi`,
  `bootfile`, `console` and the firmware's whole `*e820` map are in the
  configuration environment by the time Dis starts, and
  `virtarm64init.b` prints `ARM64-ACPI-OK` with the RSDP on a UEFI boot
  and `ARM64-ACPI-NONE` on the `-kernel` path.  Note `ksetenv` puts a
  name beginning with `*` only in `#ec`, not `#e`.  `os/inferno/virtarm64/acpi.c` walks the tables: `acpiinit` takes
  `*acpi=` from the configuration, checks the RSDP signature and both
  checksums, walks the XSDT (or RSDT), checksums every table, and reads
  the GIC distributor/redistributor/cpu-interface bases and the enabled
  processor count from the MADT, the PCIe ECAM base from the MCFG and
  the console UART from the SPCR.  Fields are read a byte at a time --
  ACPI tables are byte-packed and several of these are unaligned.  It
  reads and does not act: every value is printed beside the constant
  `mem.h` compiles in, and on `-M virt` (GICv2, 1 cpu) and
  `-M virt,gic-version=3 -smp 2` every one agrees, with `gicr` zero on
  GICv2 and `gicc` zero on GICv3 because each is absent from that
  machine's MADT.  One value is used rather than only printed: the PCIe ECAM window comes
  from the MCFG through a `uvlong (*pciecam)(int*, int*)` in
  `os/inferno/port/pciecam.c`, the same name and shape as
  `os/inferno/pc/pcipc.c`'s, which `archacpi.c` sets from the PC's
  MCFG; a board with no firmware description leaves it nil and keeps
  `mem.h`'s constant, which is every RISC-V board here.  Proved on
  `-M virt,highmem-ecam=off`, where the window is at 0x3f000000 and
  `mem.h` says 0x4010000000: the kernel enumerates all three devices at
  the firmware's base, and the same kernel with that one assignment
  removed -- value still read and printed, not used -- panics in
  configuration space.  Still to do: the processor list from the MADT,
  and the UART from the SPCR, which is harder than it looks because the
  console is up long before `acpiinit` runs.  GTDT and IORT untouched.  `bootx64.efi` under OVMF still boots `ipc64` to a
  prompt.
  Machines can now join and leave the network database while the
  system is running: `appl/cmd/ndb/regndb.b` renders a `registry(4)`
  as an `attrdb(6)` database and `appl/cmd/ndb/register.b` joins one,
  documented in `man/4/regndb` and `doc/inferno-ndb.ms`, verified on
  `os/inferno/virtarm64/virtarm64ndb` over a pipe and over a real TCP
  connection that was then dropped.  Decide, build
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
  host, and they have already been paid for four times: `NVAR` in
  `utils/cc/cc.h` (a variable count in units of `sizeof(long)`), the
  `Ieee` struct in every loader's `datblk` (two 32-bit words cast to
  bytes), `symb` overruns aside, and `struct Exec` in
  `utils/include/a.out.h` together with `hswal` in
  `utils/libmach/executable.c`.  That fourth one silently disabled every
  tool built on `libmach`: `Exec`'s eight fields are 32-bit words in the
  file and were declared `long`, so on a 64-bit host the struct was
  twice the width of the record and `fp->symsz` was read from the top
  half of the 64-bit entry, which is zero -- `inm` printed nothing and
  exited 0, `acid` said "no symbol information", and `srclist` listed no
  sources, which is why `i$CONF.acid` had been one line long.  Fixed by
  giving `Exec` (and `utils/libmach/elf.h`'s 32-bit ELF records)
  fixed-width fields and making `hswal` step and count in `u32`s.  `inm`
  now agrees symbol for symbol with an independent reader on
  `os/inferno/pc64/ipc64` (4675 text symbols) and works for the arm
  boards too.  `libmach` also gained the two things that were keeping
  it from every other board: `utils/libmach/7.c` and `ureg7.h` (arm64
  executables -- R_MAGIC had no exectab entry and there was no `Mach`),
  and `elf64dotout` in `executable.c` (the ELF reader was 32-bit only,
  and every board but pc64 and armv7 links its kernel as ELF64).  One
  thing there had to be measured rather than assumed: the symbol value
  width is a property of the loader, not the ELF class -- `7l` and `6l`
  write eight-byte values only for the Plan 9 a.out header type and
  four for ELF, while `jl` writes eight unconditionally, so `Fhdr`
  carries the width now in the field that was `spare`.  Ten of fifteen
  boards' kernels resolve (`virtarm64` 2436 text symbols, checked
  against the same independent reader); `virt32`/`virt32s` are ELF32
  RISC-V and want an `mriscv32` that does not exist, and `mps2`,
  `nucleof303` and `teensy41` are raw binaries with no header, so
  refusing those is right.  Look here
  first when a number comes out wrong on the host but the sources look
  right.
- A probe that deletes itself when it fires cannot be bisected over.
  `libinterp/heap.c`'s tracker clears a watch (`track[i].addr = nil`)
  on reporting it, so a checkpoint that stayed quiet is ambiguous
  between "nothing had gone wrong yet" and "there was nothing here to
  go wrong on", and no ordering of probes tells those apart afterwards.
  Two rounds were spent on that inference before it was named: five
  checkpoints added inside `newfd()`/`growfd()` here on the strength of
  `kopen:after-newfd` firing while the earlier ones were quiet, and the
  same conclusion about `parsemod()` on the inferno-ports branch.  Any
  bisection over a sequence of probes is only valid if every probe was
  live for the whole sequence.
- A library under `lib*/` builds for the kernel only when the board's
  rule invokes it.  `os/inferno/port/portmkfile`'s `lib%.a` rule runs
  `mk SYSTARG=$SYSTARG OBJTYPE=$OBJTYPE install` in `$ROOT/lib<name>`;
  a plain `mk install` there builds for the host and fails at `u.h file
  not found`, which looks like a broken library rather than a wrong
  invocation.  Checked from clean: removing
  `Inferno/amd64/lib/libaml.a` and rebuilding `pc64` regenerates it and
  the kernel boots, so nothing in that path depends on a stale archive.
- `mk` and `mk install` build different things, and the test scripts
  read the installed one.  `scripts/mkinferno-efi-iso.sh` packages
  `$ROOT/Inferno/amd64/ipc64`, not `os/inferno/pc64/ipc64`, so a `mk`
  in the board directory leaves the ISO carrying whatever was installed
  last -- here, a kernel from before the interrupt fix, which panicked
  on the UEFI path and looked exactly like a regression the change had
  caused.  Before believing a failure from a script, check that what it
  loaded is what was just built: a marker line the new kernel prints
  and the old one does not settles it in one grep.  The same hole is
  open one level down: a generated artifact depends on the tool that
  made it, and `mk` lists only sources, so rebuilding a compiler or
  loader under `utils/` does not rebuild anything it previously
  produced, and reinstalling an older one silently un-fixes every
  artifact made with the new one.  The osprey-port branch lost an hour
  to exactly that while bisecting `6l`.  Where an artifact can be
  checked against its own invariants, check it: that branch's module
  builder now refuses to emit a module whose relocations point outside
  it, which caught the stale linker by name.
- An instrument's own output must not collide with what anything greps
  for.  `regtorture`'s success line read "ticks; control clean", and the
  console prompt in these kernels is `"; "`, so every boot batch matched
  the instrument instead of the prompt and scored thirty clean boots as
  thirty hangs.  It took three builds to notice, and the failure looked
  exactly like a kernel regression.
- In amd64 assembly, `MOVW` from a segment register writes the whole
  64-bit destination, not its low sixteen bits.  `MOVW DS, AX` assembles
  to the 32-bit form, which zero-extends, so it destroys everything that
  was in `RAX`.  Never use a register as the scratch for a segment read
  until that register's own value has been saved.  This is measured, not
  inferred: `os/inferno/pc64/regtorture.s` held `AX` at `0x11111111`
  across interrupts and recorded what came back as `0x0`, where a
  sixteen-bit write would have left `0x11110000`.  It cost this port
  every interrupt returning `AX = 0` since it began, which is the Dis
  heap fault -- see `doc/inferno-cloud-plan.ms` section 6.  The same
  trap is open to anything hand-written in 6a that reaches for `DS`,
  `ES`, `FS` or `GS`.
- kencc passes the first argument in a register and every other on the
  stack.  `utils/7c/7.out.h` sets `REGARG` to 0 and `utils/7c/txt.c`
  uses it only for `curarg == 0`, so an assembly routine written on the
  assumption that a four-argument call arrives in `x0`-`x3` gets one
  right and three wrong; the reserved slot at `0(FP)` is never written,
  which is why the second argument sits at `8(FP)`.
  `os/inferno/virtarm64/l.s`'s `psci` had that bug from the day it was
  written and nothing caught it, because the only PSCI calls this
  kernel made were `SYSTEM_OFF` and `SYSTEM_RESET`, which take no
  arguments, so the wrong registers were never read -- and that is
  measured, not assumed: called deliberately from `main()`, each stops
  QEMU on its own, exit status 0 with the `print` after the call
  absent, against 124 for a no-call control.  `CPU_ON`, which takes
  three, answered `INVALID_PARAMETERS` on the first boot.  An
  assembly entry point whose extra arguments have never been read is
  not evidence that it passes them, and the same trap is open in `5a`,
  `6a` and `ja`.  `os/inferno/boot/efi/aa64.s`'s `eficall` has the
  correct idiom to copy.
- When a bug's consequence is rare, measure the cause, not the effect.
  `os/inferno/port/proc.c`'s `userureg()` returned `Proc.kp` where its
  own comment says to return `!Proc.kp`, so every kernel process's trap
  was classified as coming from user mode and the one process without
  `kp` was classified as a kernel trap.  The multicore branch found the
  consequence -- a general protection fault on the `IRETQ` in
  `_intrr`, twelve times in about 864 boots -- and that rate costs
  ~192 boots per catch.  Confirming it here took one boot: a bounded
  probe in `os/inferno/pc64`'s `trap()` printing `up->pid`, `up->kp`
  and what `userureg()` said, which prints the inversion directly
  ("pid 1 kp 0 userureg 0", "pid 2 kp 1 userureg 1") and prints it
  the right way round after the fix.  A boot batch then measures
  whether anything regressed; it is the wrong instrument for deciding
  whether the classification was wrong, because at a 1.4% failure rate
  zero failures in a hundred boots is not evidence either way.
- A comment that states the intended semantics is a test.  `userureg()`
  had "Hence, return !Proc.kp" directly above a body returning
  `Proc.kp`, and it survived because nothing ever compared the two.
  Where a function's contract is written down beside it, check the body
  against the sentence before trusting either.
- A derived value should be checked against the thing it describes, and
  the check has to be controlled in both directions.
  `utils/libmach/executable.c` derives the symbol-value width from
  which loader wrote the file; `syminit` now checks that derivation two
  ways.  The arithmetic one -- the records must consume `symsz`
  exactly -- catches a width that is too small (`virt` read at four
  bytes overshoots by four) and does *not* catch one that is too large
  (`virtarm64` read at eight lands on `symsz` exactly and returns 563
  records of rubbish, `6d63636f6e647569 t`, with no complaint).  Only
  running the control in both directions showed that; one direction
  would have looked like a working check.  What works is the type byte:
  every record this tree's loaders write has `0x80` set and a type from
  `TtLlDdBbapmzZf`, which is measured -- a survey found zero exceptions
  across all ten readable boards, over `6l`, `7l`, `jl` and `5l` output
  and both header types -- and a wrong width fails at symbol 0 or 2.
- An error return that sets no `errstr` is a defect, not a shortcut.
  `elfdotout`'s machine `default` returned 0 silently, so `ksize`
  printed "Undefined error: 0" on the 32-bit RISC-V boards and no
  reader could tell a corrupt file from a machine `libmach` has no
  table for.  It names the machine number now.  Check every `return 0`
  on a failure path for this; `elf64dotout` had it right and
  `elfdotout` did not, in the same file.
- Do not invoke a tool in the same command that reinstalls it.  The
  `mk install` rule is `rm -f $BIN/inm && cp o.out $BIN/inm`, so a
  pipeline that rebuilds and then immediately runs the tool can catch
  it absent or half-written; that produced "563 symbols" and "1
  symbol" readings that looked like a real regression and were an
  artifact of the test script.  Put a barrier between them and re-read
  the result before believing it.
- Grep a build's output for failure, not for the word "error".  kencc
  reports `acpi.c:352 function not declared: gicenable` and `trap.c:171
  external redeclaration of: timerirq` -- neither contains "error" or
  "warning", so a filter looking for those prints nothing and the build
  looks clean while `mk` exits 1 and leaves the old kernel in place.
  That produced a boot log with none of the new prints in it, which
  reads exactly like a feature that does not work.  Check `mk`'s exit
  status, or check the built artifact for something only the new code
  contains -- `strings ivirtarm64 | grep -c "timer ns-el1"` settled it
  in one line.
- 7c rejects an initialiser on a file-scope definition that a header
  has already declared `extern`: `int timerirq = GicPPITimer;` with
  `extern int timerirq;` in fns.h is "external redeclaration", while
  the same definition without the initialiser is fine.  Define it bare
  and assign it in the initialiser function that already exists.
- A textual patch that matches a function's return type can swallow its
  storage class.  Replacing "void\ngicenable(int irq)" with a comment
  plus the same text turned `static void` into `static /*comment*/ int
  timerirq;` -- the `static` stayed on the line above and bound to the
  next declaration instead.  When inserting before a definition, anchor
  the match on the line before the return type, not on the return type.
- `pkill -f <pattern>` matches the shell that is running it, because the
  pattern appears in that shell's own command line.  Two background
  tasks died of exit 144 that way here, and the killed shell looked
  like a failing command rather than a self-inflicted signal.  Kill by
  pid from a `ps` listing instead, and remember that killing a script
  does not kill the QEMU it spawned: a leftover process holding a
  `-drive` image makes the next run fail with "Failed to get write
  lock", which reads like a broken kernel and is a stale process.
- A boot log is not evidence that a board has a working clock.  On
  `virtarm64`, a kernel whose timer interrupt is enabled on the wrong
  GIC line reaches an interactive shell exactly like a correct one --
  nothing between `main()` and the prompt needs the timer.  Measure
  `m->ticks` across a delay from `init0`, after `spllo()`; `clockpoll()`
  does not advance it, so a count that stays put means no clock.
  Measuring it from `main()` reads zero on a perfectly good kernel,
  because interrupts are masked for the whole of `main()`.
- A file under `os/9front` with the same name as one under `os/inferno`
  is not necessarily what the Inferno one was copied from.
  `os/9front/pc64/fpu.c` has no `fpusave`, no `fpurestore`, no `FPpush`,
  `FPnouser`, `FPkernel` or `fpslot` array at all -- it uses `m->fpsave`
  and `up->kfpsave` -- so the Inferno `pc64` floating-point design came
  from elsewhere and a diff shows a different design rather than a
  drift.  The diff was still worth taking: it showed that `matherror`
  and `simderror`, which *are* recognisably the same two functions, had
  lost their `_clts()` before `fpsave()`, their state guard and their
  kernel-mode early return.  Check whether the two files are the same
  design before treating one as the other's upstream, and take from the
  diff only what the two share.
- `fpsave()` on `pc64` is `_fxsave()` followed by `_stts()`, so calling
  it with `TS` already set faults on its own first instruction and the
  report reads `_fxsave+0x0`.  Every caller must either hold the FPU
  enabled or `_clts()` first.  The window where `TS` is set while
  `up->fpstate` still says active is `fpusave()` to `fpurestore()`,
  which is where `os/inferno/port/dis.c` runs every Dis program -- so
  it is wide, not rare.
- A control that fails to apply its patch reports the experiment's own
  arm, not the control.  A `nospcr()` here still looked for
  `spcrconsole()` in `acpi.c` after the call had moved to `main.c`; its
  `assert` raised, the script's `||` never fired because the failure was
  inside a heredoc python rather than the shell, and the arm built and
  ran the *unmodified* kernel and duly printed the same result as the
  arm it was meant to contradict.  Two identical lines labelled
  differently is the signature.  Make every patch step fail the run, not
  just print a traceback, and treat two arms agreeing exactly as a
  reason to check the patch applied before believing the result.
- A GICv2m frame raises an MSI by *pulsing* the SPI, so the SPI must be
  edge-triggered or the pulse latches nothing.  QEMU's
  `hw/intc/arm_gicv2m.c` calls `qemu_irq_pulse()`, and a
  level-triggered input drops its pending bit as the line falls;
  `GICD_ICFGR` has to say edge (0b10, two bits per interrupt, sixteen
  per register).  `os/inferno/virtarm64`'s `gicenable()` never touched
  `ICFGR`, so every MSI-X vector was allocated, programmed and dead.
- `sdnvme`'s completion wait polls: `while(!wdone(ws)){ nvmeintr(nil,
  ctlr); tsleep(ws->sleep, wdone, ws, 10); }`.  A successful disk read
  therefore proves nothing about interrupt delivery, and
  `ARM64-DISK-OK` appeared identically with MSI-X working and with no
  interrupt arriving at all.  The line that does prove it is the
  driver's own `nvme: msix vector %d delivered`, printed on each
  vector's first interrupt -- check for its presence, not for the read
  succeeding.  This is the same shape as the clock: an outcome that
  survives its mechanism being broken.
- When an interrupt does not arrive, test the controller half on its
  own before suspecting the device.  Writing the SPI number to the v2m
  frame's `SETSPI` register from the kernel and reading `GICD_ISPENDR`
  answers "does the frame reach the distributor" with interrupts still
  masked and no device involved; it read `0x0 -> 0x0` before the edge
  fix and `0x0 -> 0x8000` after, which located the fault in one boot.
  That check is now a permanent silent self-test in `msiinit()`.
- A probe that cannot produce a spurious reading needs no falsification
  arm; one that can, does.  Applying that to this tree's own
  instrumentation found exactly one hole, in a self-test written the
  same hour: `msiselftest()` wrote an SPI to the v2m frame and checked
  `GICD_ISPENDR`, but never checked the bit was clear first, so it
  would have reported a working MSI path off a register that was
  already dirty.  It checks now and says the path is untested rather
  than passing.  The others survive the rule for stateable reasons --
  `startcpus()` counts a match only where the secondary wrote its own
  `MPIDR_EL1` into a slot preloaded with `~0`; `fpinit.b` blocks on a
  channel per worker, so a worker that never ran hangs the boot rather
  than passing it; `regtorture` reports INCONCLUSIVE when its tick
  delta is zero.  Write that reason down beside each probe; if it
  cannot be written, the probe needs a control.
