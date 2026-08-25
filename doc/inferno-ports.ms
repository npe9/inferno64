.TL
Where Inferno Runs
.AU
Inferno RIO
23 August 2026
.NH 1
What was here
.PP
.CW os
carried fifteen machine directories for hardware from the early 2000s:
StrongARM handhelds and evaluation boards, PXA boards, PowerPC 405 and
860 boards, and a scattering of others.  Nothing emulates any of them,
none had been built in years, and between them they held six hundred
files of drivers for parts that are not made.  They are gone.
.PP
What is left is what can be run: the portable kernel, the PC machines,
the IP stack, the boot programs and the init programs.
.NH 1
The shape
.PP
Plan 9 and Inferno organise a kernel by board, not by architecture:
one directory per machine, flat, beside the portable code.
.CW sys/src/9
has
.CW pc ,
.CW bcm ,
.CW kw ,
.CW omap ,
.CW teg2 ,
.CW zynq
and the rest as siblings of
.CW port ;
Inferno's
.CW os
had
.CW pc ,
.CW js ,
.CW bitsy ,
.CW mpc
the same way.  This tree does the same:
.IP
.nf
os/inferno/
  port/       the portable kernel
  ip/         the ip stack
  init/       the init programs
  boot/       the boot programs
  pc/         shared PC code
  pc64/       the 64 bit PC
  riscv/      shared RISC-V drivers
  virt/       QEMU -M virt, riscv64
  sifiveu/    SiFive Unleashed
  spike/      the Spike simulator
  mangopi/    MangoPi MQ-Pro, an Allwinner D1
  armv7m/     shared Cortex-M code
  mps2/       ARM MPS2 AN500, a Cortex-M7 in QEMU
  teensy41/   Teensy 4.1, an NXP i.MX RT1062
  nucleof303/ ST NUCLEO-F303RE, an STM32F303RE
.fi
.PP
A directory of shared code for a family of boards is part of that
shape rather than a departure from it.
.CW pc
is the older example: in 9front and in Osprey,
.CW pc64
takes its drivers out of it by naming it
.CW PCDIR ,
and the mkfile it carries is the upstream one for a 32 bit PC kernel
that is not built here.  In Inferno,
.CW pc
is a 386 board that does build.
.CW riscv
is the simpler kind: source and nothing else, no mkfile at all, reached
by the board mkfiles as
.CW -I../riscv
and by a rule for each file.  It holds the SiFive UART, PWM and SPI,
HTIF, the GEM ethernet and the PCI ECAM window that
.CW virt ,
.CW sifiveu
and
.CW spike
share.  What a board directory holds is what only that board has.
.CW armv7m
is the same kind: the vector table, the exception path and SysTick that
every Cortex-M has, with
.CW mps2
and
.CW teensy41
beside it.  See
.I armv7m-ports (6).
.PP
The
.CW NOTE
that came with the RISC-V work said this from the start \-
.CW "os/virt ,"
.CW "os/sifiveu ,"
.CW os/spike ,
with
.RB "\(lq" "shared drivers live in os/riscv/" "\(rq"
\- and the tree now matches it.
.PP
x86 is the exception, and is already right:
.CW q35 ,
.CW microvm
and
.CW i440fx
are not different boards, they are different configurations of the same
one, and
.CW pc
and
.CW pc64
take them by config file.  RISC-V and ARM are not settled enough for
that; each board there gets a directory.
.NH 1
What is built
.PP
The toolchain is:
.CW ja ,
.CW jc
and
.CW jl ,
a Ken C assembler, compiler and loader for riscv64, cherry-picked from
.CW pr/kenc-riscv64 .
All three build on this host.
.PP
The boards came from
.CW pr/riscv-native-boards ,
which carries the
.I generated
configuration and not the configuration it was generated from.  The
.CW virt
configuration has been reconstructed from what the generated file names:
its eighteen devices, its six links, its storage interface, its five
protocols, its eight modules and the portable objects it takes.  It
parses, and from it the whole kernel compiles for riscv64 \- fifty-seven
objects, every device, the IP stack, the virtio drivers, the board's own
code and its assembly.
.PP
Getting that far took a handful of small things that only show up when
somebody builds for a target nobody has built for:
.IP \(bu
.CW libsec
named
.CW chacha.c
and
.CW chachablock.c
in its mkfile and did not have them; they were restored from the commit
that added them, and four of their signatures made to match
.CW libsec.h ,
which only matters where
.CW ulong
and
.CW u32
are different types.
.IP \(bu
.CW iar
could not write a symbol table for riscv64 archives until it was rebuilt
against the libmach the new toolchain brought, so every library linked
as if it were empty.
.IP \(bu
.CW libkern
had no
.CW mkfile-riscv64 ,
so the architecture's own files \- memmove, memset, strchr \- were
silently not built.  It has one now, naming the portable C rather than
assembly that does not exist yet.
.IP \(bu
.CW libmemdraw 's
default
.CW hwdraw
shared a file with two variables
.CW draw.c
needs, so a board with its own
.CW hwdraw
pulled the default in behind them and collided.  They are separate files
now.
.PP
It boots.  Under
.CW "qemu-system-riscv64 -M virt -bios none -kernel ivirt" :
.IP
.nf
Inferno/riscv64 virt
267403264 bytes free
procinit conf.nproc 200
pci ecam 0x30000000 size 0x10000000 mmio 0x40000000
pci 0.0.0: 1b36/0008 class 060000 irq 32

Inferno Fourth Edition (20151010)
conf virt jit 0

Initial Dis: "/osinit.dis"
** Inferno/riscv64 virt **
starting sh...
load sh:
.fi
.PP
\- the kernel comes up, sizes memory, starts its processes, walks the
PCI bus, loads its first Dis module and asks for a shell.  There is no
shell because this tree does not build a Limbo userland; that is the
next thing, and it is a different piece of work from a kernel port.
.NH 1
Atomics, and instructions a compiler has no word for
.PP
.CW AINC
and
.CW ADEC ,
the reference counting the Dis heap turns on, were macros over the
C compiler's atomic builtins.
.CW jc
has no such builtins, and neither did any of the Ken compilers.
.PP
They are functions now, one line of assembly each, in the way this tree
has always reached an instruction its compiler cannot say:
.CW getcallerpc
is a function,
.CW _tas
is a function, and the load-reserved and store-conditional it needs are
built out of a
.CW WORD
macro because the assembler has no mnemonic for them.
.CW ainc
and
.CW adec
are the same thing with
.CW amoadd.w :
.IP
.nf
#define AMOADDW(rs2, rs1, rd) \\
	WORD $((0<<27)|AQ|RL|((rs2)<<20)|((rs1)<<15)|(2<<12)|((rd)<<7)|057)

TEXT	ainc(SB), 1, $-4
	MOV	RARG, R12
	MOV	$1, R10
	AMOADDW(10, 12, 8)
	ADD	$1, R8
	RET
.fi
.PP
with a
.CW "LOCK; XADDL"
version beside it for amd64 and 386, and a C one in
.CW emu/port/atomic.c
for the hosted build, where the host compiler does have the word and
emits the same instruction.  The floating-point control word went the
same way:
.CW getfcr
and
.CW setfcr
read and write the
.CW fcsr
control register, which is likewise not something a compiler can say.
.PP
One thing had to move for a single function to serve both callers: the
Dis heap's reference count was a
.CW ulong
where every other reference count in the same header was an
.CW int .
It is an
.CW int
now.
.NH 1
The machines to support
.PP
One list, so that a board argument is settled by what a machine is worth
rather than by what is nearest to hand, and so that the directory each
one gets is decided once.  The stars are how much each is worth having,
not how hard it is.
.PP
.TS
box tab(;);
lb lb lb lb lb
l l l l l.
architecture;qemu machine;directory;what it is;worth
_
x86-64;q35;pc64;a modern-ish PC;\(**\(**\(**\(**\(**
x86-64;microvm;pc64;the minimal paravirtual machine;\(**\(**\(**\(**\(**
x86-64;pc/i440fx;pc64;an old PC;\(**\(**
AArch64;virt;armvirt;the generic virtual ARM computer;\(**\(**\(**\(**\(**
AArch64;sbsa-ref;sbsa;a standards-based ARM server;\(**\(**\(**\(**\(**
AArch64;raspi4b;raspi4;Raspberry Pi 4;\(**\(**\(**\(**
AArch64;xlnx-zcu102;zcu102;Xilinx Zynq UltraScale+;\(**\(**\(**
AArch64;amd-versal-virt;versal;AMD Versal;\(**\(**\(**\(**
RISC-V64;virt;virt;the generic RISC-V computer;\(**\(**\(**\(**\(**
RISC-V64;sifive_u;sifiveu;SiFive Unleashed;\(**\(**\(**\(**
RISC-V64;spike;spike;the Spike simulator;\(**\(**\(**
RISC-V64;icicle-kit;icicle;the Microchip Icicle, a real SoC;\(**\(**\(**\(**
ARM (M);stm32vldiscovery;stm32;an STM32 microcontroller;\(**
.TE
.PP
The three x86 rows are one directory because they are one board with
three configurations; that is what a config file is for.  Every other
row is a directory of its own beside
.CW port ,
with
.CW riscv
already there for what the RISC-V boards share and an
.CW arm64
beside it for what the ARM ones will.
.PP
.CW virt
is the RISC-V one and
.CW armvirt
the ARM one rather than the pair being
.CW rvvirt
and
.CW armvirt :
the RISC-V one is the directory that exists, is built and is named that
in the
.CW NOTE
the work came with, and renaming a working board for symmetry is not
worth it.
.CW pc
and
.CW pc64
are asymmetric in the same tree for the same reason.
.PP
Every machine here but the Icicle is one QEMU emulates, so every one can
be brought up and kept up without hardware on a desk; the four that are
also real parts \-
.CW raspi4b ,
.CW xlnx-zcu102 ,
.CW amd-versal-virt
and the Icicle \- are the ones where the emulator is a stepping stone
rather than the destination.
.PP
.CW stm32
is not one of the others with a different config, and should not be
started as though it were.  Cortex-M has no MMU, and every board here
builds
.CW mmu.$O ;
the QEMU STM32 machines have on the order of a hundred kilobytes of
RAM, which will not hold the Dis interpreter and a Limbo root.  It is a
different kind of port \- native code, no paging, a root in flash \-
and it is on this list to be argued about rather than to be next.
.PP
Of all of it, the three RISC-V boards that have code are built and run
a shell:
.CW virt ,
.CW sifiveu
and
.CW spike .
The rest is the plan, not the state.
.NH 1
The userland
.PP
There is no RISC-V Limbo userland to find, and there was never going to
be one: Dis is bytecode and has no architecture.  What was missing was
a Limbo userland at all.
.CW dis
in this tree held the shell scripts and none of the compiled modules,
and every native kernel that lists them in its
.CW root
section \- the three RISC-V boards and
.CW pc64
\- stopped at
.CW "init: load sh:" .
.PP
It builds here, with the
.CW limbo
that is already in
.CW MacOSX/arm64/bin :
.IP
.nf
mk mkdirs
(cd appl/cmd; mk install)
(cd appl/lib; mk install)
.fi
.PP
.CW mkdirs
first, from
.CW lib/emptydirs ,
or the compiler has nowhere to install to and says so one directory at
a time.  That gives 169 commands in
.CW dis
and 162 modules in
.CW dis/lib ,
and
.CW dis
is in
.CW .gitignore ,
so it is built and not carried.
.PP
The three boards then take the same
.CW root
list
.CW os/inferno/pc64/pc64
carries, less the Forth entries that are that board's: 55 named files,
632 kilobytes, embedded in the kernel image.  A bare name whose
.CW $ROOT
counterpart is a directory makes an empty directory in the embedded
root rather than copying the tree, which is what
.CW os/inferno/port/mkroot
does with it.
.PP
All three then reach a shell:
.IP
.nf
spike     spike init / SPIKE-OK / HELLO-FROM-SH / SPIKE-SH-OK
sifiveu   sifiveu init / SIFIVEU-OK / HELLO-FROM-SH
virt      starting sh... / sh loaded / GC-STRESS-OK
.fi
.PP
.CW spike
and
.CW sifiveu
had those tests written in their init programs already, against a
userland that did not exist.
.CW virt
goes on through its memory, draw, pointer and keyboard tests; what it
still fails is its disk test, which wants a
.CW -drive
this invocation does not give it.
.PP
.CW os/inferno/pc64
was asking for the same userland and stopping in the same place, and
gets much further now.  Two more things were in its way and are fixed:
its mkfile named
.CW ../../include/memdraw.h ,
one directory too few since the kernels were laid out one flavour per
directory, and its config asks for
.CW auth
in the portable section while no portable
.CW auth.c
existed anywhere \- the three RISC-V boards each carried an identical
copy of one.  That copy is
.CW os/inferno/port/auth.c
now, which is where portable code goes, and the boards take it through
.CW portmkfile 's
rule for a portable source rather than each holding their own.  All
three still run a shell with it there.
.PP
.CW pc64
now compiles, links and installs.  Getting it to run at all found a
real
.CW 6l
bug, not a
.CW pc64
one:
.CW follow()
threads the whole program into one fall-through order with a single
top level call to
.CW xfol() ,
which returns the instant it reaches an unconditional jump or a return
with no outstanding recursive branch target queued to resume it \-
ordinarily safe, because some conditional branch nearly always sits
between there and the next function to keep a recursive call alive.
.CW os/inferno/pc64/l.s 's
multiboot entry trampoline, the very first code
.CW 6l
threads for this kernel, is nothing but a straight-line copy loop
ending in an indirect
.CW JMP ,
with no conditional branch anywhere before it: the single top level
call returned there, and the other 130 object files in the link \-
every function in the kernel \- were never marked, appended, or given
a
.CW pc .
The kernel still linked, still installed, and still looked entered
under QEMU; what it actually ran was 128 bytes of assembler before
falling into whatever came after it in memory by chance, which
depended on the exact link.
.CW 6l
now records where every function starts before the first
.CW xfol()
call, and resumes it from whichever of them are still unmarked once
that call returns, until all of them are: the same one-block-at-a-time
algorithm, just not abandoned after the first block that has no branch
of its own.
.PP
With that fixed
.CW pc64
runs real 64-bit kernel code: it takes the 32-to-64-bit transition in
.CW l.s ,
loads its page tables, enables long mode, and reaches
.CW main.c ,
where it took a page fault immediately after printing
.CW userinit... .
That one was
.CW pc64
's own:
.CW userinit()
built the kernel's first process with
.CW newforthproc() ,
a call meant for an already-running process to spawn another Forth
kernel process, which reads
.CW up->user
and calls
.CW waserror() \-
both need a live
.CW up ,
and there is no process at all yet at the point
.CW userinit()
runs.
.CW up->nerrlab
read a 32 bit count from physical address
.CW 0x330 ,
real BIOS data rather than a struct field, and the garbage address
.CW waserror()
built from it faulted on its first store.  Every other board's
.CW userinit()
uses plain
.CW newproc() ,
which touches no per-process state, for exactly this reason; so does
.CW pc64
now.
.PP
Past that,
.CW pc64
reaches
.CW schedinit()
and runs
.CW init0
as a real scheduled process.  That
.CW init0
was 9ferno's own: it called
.CW goforth() ,
interpreting
.CW init.f ,
a Forth script at the root of the tree, in place of the Dis boot
every other board here takes \- the config carries the same 55 file
Dis root, but nothing in
.CW init0
called
.CW disinit
to load it.  It got there: init.f built a namespace, did arithmetic,
defined and called a word, and printed
.CW "end of init.f" ,
this board's entire init script.  That is no longer this board's
path.  This tree wants an Inferno native kernel, not 9ferno's Forth
one, so
.CW init0
now calls
.CW disinit("/osinit.dis")
instead \-
.CW os/inferno/init/disinit.b ,
the same initial program every other board runs.  Doing that needed
.CW userinit()
to populate
.CW up->env ,
the
.CW Osenv
.CW disinit()
and
.CW schedmod()
read the namespace through, alongside the flat
.CW "p->pgrp / fgrp / egrp"
fields
.CW devproc.c
and the rest of the portable device layer read directly \-
.CW portdat.h
already carries both, with a comment recording that exact reason, and
every other board's
.CW userinit()
keeps them pointed at the same objects; pc64's now does too.  One more
Forth era leftover was in the way:
.CW init0
had its own
.CW kopen("#c/cons")
sequence opening fd 0\-2 on the process's shared
.CW Fgrp
before
.CW disinit()
got a chance to, and
.CW disinit()
opens those same three fds itself for the newly scheduled interp
process sharing that
.CW Fgrp \-
opened twice, its own
.CW kopen()
found 0\-2 taken, got fd 3, and panicked on its
.CW "!= 0"
check.  Removed;
.CW disinit()
is now the only place that opens the console.
.CW newforthproc()
also linked its process into the
.CW "fhead / ftail"
list
.CW devforth.c
walks to build
.CW #f 's
directory; building the first process with
.CW newproc()
instead means process 1 does not appear there, which has not come up
as mattering.
.PP
With both fixed,
.CW pc64
reaches
.CW "Initial Dis: \(dq/osinit.dis\(dq" ,
genuinely loading and scheduling it, and that is where the port now
stands: nothing has been observed to print past that line yet, though
QEMU's own trace shows real execution happening, not a stall at one
instruction.  Traced as far as
.CW port/random.c 's
.CW randomseed() ,
a kproc whose entropy-gathering loop only ends once a periodic
.CW Timer 's
callback has filled a 64 byte buffer a few bits at a time, and whose
caller,
.CW randominit() ,
holds a qlock until it does \- so whatever reads random state next,
plausibly something in module loading, blocks behind it indefinitely.
.PP
The clock interrupt itself is not the gap: QEMU's own state settled
that.
.CW -d\ int
during the hang shows a vector landing about 140 times a second, and
QEMU monitor's
.CW "info lapic"
names it \- the local APIC timer, in periodic mode, targeting vector
50, exactly the vector in the trace.
.CW "info pic"
shows why it is not the legacy 8253 instead: IRQ0 is masked in both
the PIC's own IMR and the IOAPIC's pin 0 redirection entry.  So
.CW hzclock()
is being driven, on schedule, straight off the local APIC.
.PP
.CW os/inferno/pc64
carries no local
.CW i8253.c
of its own to check \- an earlier version of this section wrongly
took that for files lost to another session sharing this worktree.
They were never local: pc64's own mkfile compiles
.CW %.$O:\ ../pc/%.c
for anything it has no rule of its own for, so
.CW i8253.c ,
.CW apic.c
and the rest of the PC-hardware layer it shares with
.CW os/inferno/pc
build straight from there, every time, which
.CW mk\ i8253.6
after removing the stale object confirms.
.CW os/inferno/pc/apic.c 's
.CW lapicclock() ,
the local APIC's own ISR, does call
.CW timerintr(u,\0)
correctly \- so the mechanism that walks
.CW Timers[]
and fires
.CW randomseed() 's
periodic callback is wired right.  This board's arch selection is also
already right, on a second look: the
.CW "mpintrassign: can't find bus type 12"
line every boot prints reads like
.CW archmp
lost arbitration to
.CW archacpi \-
it has not.
.CW archacpi.intrassign
is
.CW mpintrassign
too, the same shared legacy PCI-IRQ-routing helper, called regardless
of which arch does system identification; a print added to
.CW identify()
(checked, then removed) confirmed
.CW archacpi
finds a valid RSDP, passes its checksum, finds the MADT, and wins.  So
.CW pc64
already runs a defensible modern stack: ACPI MADT for identification,
HPET as the calibration source, TSC as the fast clock, the local APIC
for the interrupt-driven tick.
.PP
What was missing was TSC-deadline mode, the one step further real
hardware from the last several years takes: write a future TSC value
straight into
.CW IA32_TSC_DEADLINE
and get one one-shot interrupt exactly there, instead of the periodic
reload
.CW lapictimerset()
did \- rewriting
.CW LapicTICR
to hit the next software deadline, then letting the counter free-run
at that period until the next rewrite.
.CW os/inferno/pc/apic.c
now takes that path whenever
.CW CPUID.1H:ECX[24]
says the CPU has it: no oscillator calibration, no periodic reload,
one
.CW wrmsr
per deadline, gated on
.CW arch->fastclock\ ==\ tscticks
so the value handed to it is already a raw TSC reading.  It could not
be verified fixing anything here: this session's QEMU is pure TCG, no
KVM or HVF, and does not expose the deadline CPUID bit under any
.CW -cpu
model tried, including
.CW max
and
.CW Icelake-Server
\- the latter reporting back as
.CW "GenuineIntel P6 family 6 model 14" ,
a CPU that does not exist, which is TCG's own ceiling and not this
kernel's bug.  The code degrades to the previous periodic path exactly
as before when the bit is absent, verified unchanged.
.PP
A print added to
.CW randomsample()
(in
.CW port/random.c ,
genuinely portable and never in question) showed the periodic path
running correctly, not racing: nbuf climbs cleanly, four samples per
byte, all the way to 64, and
.CW randomseed()
's own loop exits, calls
.CW timerdel() ,
runs
.CW sha512() ,
.CW setupChachastate() ,
.CW qunlock(rs)
and returns \- every step confirmed printing in turn.  The earlier
theory that
.CW timerintr() 's
.CW tadd()
races
.CW randomseed() 's
.CW timerdel()
right at completion does not survive this: nothing hangs there at all.
.PP
It hangs one level up, in the kproc's own exit path, and adding the
diagnostic print changed the symptom from silence to a real fault:
.CW pexit()
prints and runs to its own
.CW sched() ,
and QEMU's
.CW -d\ int
trace of that run shows why nothing comes back \- a
.B "general protection fault on IRETQ" ,
the shared trap dispatcher's own return instruction
.RI ( os/inferno/pc/apic.c 's
neighbour
.CW trap.c ,
compiled for pc64 the same shared way), triggered by a UART interrupt
landing while
.CW up
is a heap-allocated interpreter process \- one
.CW disinit() 's
.CW schedmod()
created, not one built through
.CW newproc()
/
.CW kproc() .
That is a stack or context corruption on return from a nested
interrupt during a process switch, most likely something about how
the Dis interpreter's process differs from a plain kproc's that this
board's shared trap assembly does not account for \- not the Timer
subsystem, which is exonerated.  The diagnostic prints are not kept;
this is what they showed, and it is a sharper, truer place to resume
than where this section previously pointed.
.PP
That IRETQ fault has not reproduced since, across many more runs with
a lighter diagnostic, and the
.CW up
it named was narrower than described: not a
.CW schedmod()
interpreter process at all, but
.CW pid=1 ,
.CW kp=0 \-
init0 itself, still running
.CW vmachine() .
.CW schedmod()
was never the right suspect; it does not build a kernel
.CW Proc
in the first place, only a Dis-level
.CW Prog
.CW vmachine() 's
own loop interleaves within whichever kernel process called it.  Real
diagnosis turned out to need less machinery, not more: printing on
every interrupt entry, unconditionally, from inside the interrupt path
itself, is pathological with a polled UART console \- each character
the print writes completes with its own THRE interrupt, which the
same unconditional print then reports on, without bound.  That
explains both the earlier fault and the earlier silences: how much
was printed changed what ran long enough to observe, which is not
evidence of a race, only of a diagnostic that competed with what it
was trying to watch.  A print gated to fire only when the vector or
pid actually changes avoids the feedback and was the one used for
everything below.
.PP
Chasing why nothing gets past
.CW "Initial Dis:"
found the actual, reproducible fault, and it was neither of the above:
.B "panic: loading \(dq/osinit.dis\(dq: out of memory: main" .
.CW os/inferno/pc64/main.c 's
.CW poolsizeinit()
had the image pool's
.CW poolsize()
call commented out \-
.RI ( "TODO causes a double fault now. needs to be fixed" ) \-
leaving
.CW imagmem
at whatever tiny size it starts with while
.CW mainmem
and
.CW heapmem
got their full, correctly computed shares.  Loading a Dis module
allocates image memory; an unsized image pool is exactly what running
out of it loading the very first one looks like.  Re-enabling it does
not reproduce the double fault the TODO describes \- a full \~100MB
contiguous allocate-then-free completes cleanly, unchanged since
whatever caused it, most likely fixed as a side effect of one of this
session's earlier corrections elsewhere in the boot path.
.PP
Getting far enough to hit that panic reliably needed the slow path
gone, which turned into a second real fix.
.CW randomseed() 's
entropy loop was never a Timer bug \- established above \- but it
still spends four \~7ms local-APIC ticks per byte, sixty-plus seconds
for the 64 byte buffer it wants, entirely because nothing on this
board supplies
.CW random.c 's
.CW hwrandbuf
hook.  The hardware to do it instantly was already written and never
connected:
.CW "rdrand32 / rdrand64 / rdrandbuf"
are complete in
.CW pc64/l.s ,
raw-byte encoded since kencc's assembler predates the RDRAND mnemonic,
but
.CW os/inferno/pc/devarch.c
gated setting
.CW hwrandbuf
to them behind
.CW "strcmp(m->cpuidid,\ \(dqGenuineIntel\(dq)"
as well as the RDRAND CPUID bit \- RDRAND is a plain ISA feature, not
Intel-specific, AMD has carried it since Zen, and this excluded every
AMD chip that reports the bit correctly, unlike the vendor-neutral Pat
and Mtrr checks right beside it.  Fixed to test the bit alone.  Even
wired up, though, it would have done nothing:
.CW randomseed()
calls
.CW hwrandbuf
to fill
.CW s->buf
directly, then enters a loop watching
.CW s->nbuf ,
which only the slow timing-jitter callback ever advances \- sourcing
entropy from real hardware and then waiting on a counter that fill
never touches.  Now sets
.CW nbuf\ =\ sizeof(s->buf)
right after a successful
.CW hwrandbuf
call, which is what the loop was actually waiting to learn.
.CW -cpu\ max
under this session's QEMU (pure TCG, no KVM or HVF; the default
.CW -cpu
model here predates RDRAND in real silicon and correctly reports it
absent, which is why this needed a non-default model to verify at
all) confirms all three pieces together: identify() finds a valid
RSDP and MADT and stays on
.CW archacpi
as before,
.CW hwrandbuf
gets set to
.CW rdrandbuf ,
and
.CW randomseed() 's
kproc completes too fast to ever be caught mid-execution by an
interrupt \- in a trap() trace that, before this fix, showed it as the
only thing running for the entire sampled window.
.PP
With all three landed, pc64 reaches
.CW "Initial Dis:"
and stays there, silent, indefinitely \- an 8-minute background run
never produced another line.  A busy
.CW -d\ exec
trace right after that point was read, in an earlier draft of this
section, as evidence the interpreter was doing real work; it wasn't
evidence of anything of the kind.  A QEMU monitor's
.CW "info registers" ,
sampled five times over several seconds, showed
.CW HLT=1
at the same fixed address every time: the kernel scheduler had
.CW nrdy==0
and was parked in
.CW l.s 's
.CW halt() ,
not running anything.  That is the second time this section reported
"still executing, just slow" from an instruction trace and the second
time that was wrong; the lesson worth keeping is the method, not the
correction \- a busy trace does not distinguish a working interpreter
from an idle one sampled between two of its very last instructions,
and asking the scheduler directly does.
.PP
What actually starved the scheduler was
.CW modinit() .
.CW os/inferno/pc64/pc64 's
.CW mod
section \- the list that becomes
.CW sysmodinit() ,
.CW drawmodinit() ,
and so on, in the
.CW mkdevc \-generated
.CW pc64.c \-
had every entry commented out, so
.CW modinit()
generated empty.  No Dis program on this board could ever load
.CW Sys :
.CW schedmod() 's
very first
.CW Prog ,
running
.CW disinit.b 's
.CW init() ,
hit
.CW "sys\ =\ load\ Sys\ Sys->PATH"
before its first statement, got
.CW nil
back, and the next call through it \-
.CW "stderr\ =\ sys->fildes(2)"
\- raised
.CW "mframe:\ module\ not\ loaded"
with an empty
.CW error()
unwind straight through
.CW vmachine() 's
outer
.CW waserror() :
.CW progexit()
with a blank
.CW estr ,
no console output, ever.  This is why nothing followed
.CW "Initial\ Dis:" ,
on every configuration this board has run since the switch away from
Forth, and it explains the entire silence this section spent three
revisions trying to attribute to a race, a GPF, and finally an
interpreter that was merely slow.
.PP
Uncommenting
.CW sys
alone was enough to reach
.CW "Welcome\ to\ Inferno..." \-
.CW disinit.b 's
own first line.
.CW keyring
and
.CW crypt
link and boot clean alongside it;
.CW draw ,
.CW tk
and
.CW math
are still commented out, because
.CW math
(specifically
.CW mathmodinit )
reproducibly crashes
.CW 6l
on this host and toolchain \-
.CW span()
writes through a nil
.CW Prog.from.sym
in its final
.CW textp
walk,
.CW span.c:104 \-
independent of anything above and not yet root-caused.  Nothing
between here and a shell needs
.CW Draw ,
.CW Tk
or
.CW Math ,
so that bug is parked, not blocking, and documented in the config
file itself.
.PP
Past
.CW Sys ,
.CW disinit.b
got one statement further before erroring silently again:
.CW "now\ :=\ getclock(\(dq#r/rtc\(dq);\ now\ *=\ big\ 1000000;\ setclock(\(dq#c/time\(dq,\ now)" .
.CW #r/rtc
returns plain seconds; the
.CW *1000000
turned that into a write about a million times too large,
overrunning
.CW port/devcons.c 's
.CW writetime() \-
a 12-byte buffer expecting the same plain-seconds unit
.CW #r/rtc
already returns \-
.CW "bad\ time\ control" ,
unconditionally, on the only boot in this tree's history that ever
reached this line: this is 9ferno's original disinit.b, carried
verbatim, and with
.CW mod
empty Sys never loaded, so this call never ran, so this bug was never
seen, until today.  The
.CW *1000000
served no purpose against this port's actual write contract; removed.
.PP
With both fixed, pc64 reaches
.CW "Welcome to Inferno...\(rq ,
.CW "loading /dis/sh.dis" ,
.CW "spawn sh -n /dis/init" \-
a real Inferno init spawning a real shell against a real script,
further than this board has ever gotten.  One run of this hit a
genuine general protection fault during that spawn.  Tracking it down
found a second real bug, in the fault path itself:
.CW trap.c 's
.CW dumpregs()
mixed 9ferno Forth VM register aliases
.RI ( "BX TOP, DX PSP, R8 RSP, R9 IP, R10 W, R11 UP, R12 UPE" )
into what is now an ordinary x86 register dump, and
.CW trap()
additionally called
.CW "dumpforthregs() / dumprstack() / dumppstack()"
behind an
.CW "if(up->fmem\ !=\ nil)"
guard on a
.CW Proc
field nothing on this board's actual boot path \-
.CW newproc() ,
not
.CW newforthproc() \-
has set since the switch off Forth.  The guard was reading whatever
garbage sat in that word, and on a garbage-nonzero read,
.CW dumprstack() / dumppstack()
walk memory computed from it.  That is the likeliest source of the
GPF itself, not just of a confusing report of one: after removing the
dead path, the same test has run clean, twice, where it faulted
before.
.CW dumpforthregs() ,
.CW dumprstack()
and
.CW dumppstack()
are unchanged and still correct for 9ferno's own board; pc64's
.CW trap()
just no longer reaches them off an uninitialised field, and
.CW dumpregs()
now prints plain register names.
.PP
The array-bounds error that followed
.CW "spawn\ sh\ -n\ /dis/init"
turned out not to be about a missing boot medium at all \- that was
this section's own guess, and it was wrong.  A temporary print inside
.CW OP(indc)
(the string-index bytecode instruction) plus
.CW "limbo\ -S" 's
instruction-numbered assembly listing traced it to a real bug in
.CW appl/cmd/sh/sh.b ,
line 1114,
.CW parsewaitstatus() :
.EX
	for (i := 0; i < len status; i++)
		if (status[i] == ' ')
			break;
	if (i == len status - 1 || status[i+1] != '"')
.EE
The guard only catches the space landing on the last byte of
.CW status .
An empty
.CW status
leaves the loop untouched at
.CW i==0 ,
and
.CW "len\ status-1"
is
.CW \-1 \-
.CW 0==\-1
is false, so
.CW status[i+1]
reads one past an empty string, an array bounds error nothing here
catches (the graceful
.CW ctxt.fail()
two lines down is never reached).
.CW >=
closes both the original case and the empty one.
.CW sh.b
is shared across every Inferno target this tree builds, not
board-specific: reachable by any board's shell hitting an empty wait
read, just never exercised by one until pc64 got far enough to try.
.PP
Fixed, this turns a silent interpreter-level crash into
.CW "sh:\ bad\ exit\ status\ ''" \-
a clean, readable diagnostic \- and lets execution proceed past it.
That message asks its own question: why did the wait read come back
empty at all?  It was not a race.
.CW port/devproc.c 's
.CW procread() ,
the file server behind
.CW #p/PID/wait ,
had its
.CW Qwait
case body entirely commented out, falling straight through to
.CW "return\ 0" .
Every read of a wait file returned zero bytes immediately, unconditionally,
never blocking, no matter what \-
.CW sh.b 's
.CW waitfor()
only checks
.CW "n\ <\ 0"
as an error; a same-turn empty read looks like nothing happened, gets
handed to
.CW parsewaitstatus()
as an empty string, and that is the
.CW ''
in every occurrence of this message this section has recorded.
.CW prochaswaitq() ,
the wake condition
.CW sleep()
uses while genuinely waiting, was separately stubbed the same way \-
.CW "return\ 0"
unconditionally \- so restoring
.CW Qwait
alone would have swapped an instant wrong answer for an eternal
hang.  Both go back to the single commit that introduced this
.CW devproc.c
(9ferno, November 2021) \- five weeks before this board's
.CW mod
list was emptied for Forth, meaning no Dis process ever got far
enough to load
.CW Sys ,
spawn a child, and call
.CW wait()
on it until this session.  Unfinished work waiting five years for a
caller, not a regression.  The state these two stubs needed to read
was never in question:
.CW port/proc.c 's
.CW pexit()
already correctly populates
.CW p->waitq / p->nwait
and wakes
.CW p->waitr
on every child exit \- proven by this same kernel's separate, working,
.I native
wait path
.RI ( proc.c 's
.CW haswaitq() ,
used by
.CW waitfor() 's
non-file-based sibling) \- so uncommenting both stubs was sufficient.
With both restored,
.CW "sh:\ bad\ exit\ status\ ''"
has not reproduced in any run since.
.PP
Past it, a new failure appears in its place, reliably: mounting
.CW mntgen
via
.CW /dis/init 's
.CW "mount\ {mntgen}\ /n"
loads
.CW Mount ,
.CW Nametree ,
.CW Styxservers
and
.CW mntgen
itself \- all confirmed, by a temporary
.CW lookmod()
trace, to resolve
.CW $Sys
correctly, so this is not a repeat of the modinit finding \- and then
.CW Mount
hits
.CW "fd\ out\ of\ range\ or\ not\ open"
on file descriptor 4, reproducibly, in the large majority of runs.
.CW appl/cmd/mount.b 's
.CW popen()
opens exactly that pipe
.RI ( sys->pipe(fds) ,
which a kernel-level trace confirms allocates fds 3 and 4 successfully)
to connect
.CW mntgen
as a child process, then
.CW spawn s
a helper thread that calls
.CW "sys->pctl(Sys->FORKFD,\ nil)"
to give
.I itself
a private copy of the file-descriptor group before running
.CW mntgen \-
by Limbo's own semantics that fork should not touch
.CW Mount 's
own, separate copy of the same group, and reading every layer
involved \-
.CW newprog() 's
osenv copy on
.CW spawn ,
.CW dupfgrp() ,
.CW pctl() 's
.CW Sys_FORKFD
case \- confirms each one behaves as documented in isolation.
.PP
One concrete, tested lead came out of this: the kernel process that
picks up a released Dis program when the original blocks is spun up
via
.CW "kproc(\(dqdis\(dq,\ vmachine,\ nil,\ 0)"
in
.CW port/dis.c 's
.CW release() ,
with
.CW flags=0 \-
meaning it inherits none of pgrp/fgrp/egrp from its recycled
.CW Proc
slot, unlike
.CW proc.c 's
.CW rptproc() ,
which uses this identical acquire/release pattern and passes
.CW KPDUP
for exactly that reason.  Fixed to match.  A/B tested with and
without the flag, same failure both times: this kproc's own
per-iteration loop already resyncs
.CW up->fgrp
from the current Prog's
.CW osenv
before every instruction dispatch, which is enough to mask flags=0
for any Prog that actually reaches that loop.  Kept anyway \- a kproc
about to run arbitrary user Dis code has no business starting from a
stale group left by an unrelated prior occupant of its
.CW Proc
slot \- but it is not this bug.
.CW Fgrp
pointer values traced across the failure (a temporary print in
.CW newfd2()
and in
.CW fdtochan() )
show the
.I same
live
.CW Fgrp
object, correctly shared, at both the successful allocation and the
failed lookup: not a stale pointer, not a wrong group, not the kproc
handoff.  Something between
.CW popen() 's
.CW sys->pipe()
and
.CW Mount 's
next use of the returned
.CW ref\ Sys->FD
clears slot 4 specifically out of a group that is genuinely still the
right one.
.PP
It is a GC finalizer, caught directly.
.CW port/inferno.c 's
.CW freeFD()
runs when a Limbo
.CW ref\ Sys->FD
object's last reference drops; if the wrapped fd is still open it
calls
.CW kfgrpclose() ,
closing the real kernel fd.  A print there, across several runs,
shows fd 4 in
.CW Mount 's
own group closed under
.CW Mount 's
own kernel process \- sometimes while
.CW Sys_mount()
is still using it (the failure this section has been chasing), and,
in other runs, cleanly
.I after
.CW kmount()
has already returned success: bracketing
.CW Sys_mount()
with entry/exit prints, one run showed
.CW "kmount\ returned\ 16" \-
success \- followed by
.CW freeFD 's
close of that same fd, in that order, no failure at all.  So the
mechanism is not broken; it is racing something, and which side wins
varies by run.
.PP
Tried and ruled out:
.CW popen()
returning
.CW fds[1]
straight out of its local array, on the theory that the array's own
scope-exit cleanup might race the return-value transfer.  Rewritten
to copy the element into a plain local first, held across the
.CW spawn ,
and returned from there instead \- rebuilt, reinstalled, reboot-tested
against the same
.CW freeFD
trace: fd 4 in
.CW Mount 's
group still closes early on some runs, identically.  Not the array
return.
.PP
What the successful run's silence afterward turned out to hold: past
a clean mount,
.CW /dis/init
reaches its last line,
.CW "sh\ -n\ -l\ -i" \-
a real interactive shell, whose default prompt
.RI ( sh.b ,
.CW "\(dq;\ \(dq" )
is two characters, easy to miss in a boot log and never yet
distinguished from silence by any run in this section.  Testing it
needed a live pipe into the emulator's stdin rather than a captured
log, and that test surfaced a third, deeper failure mode past both
the modinit and the fd questions: a genuine Styx-protocol fault in
the mount\(midmntgen exchange itself.  One run logged
.CW "mountio:\ proc\ dis\ pid\ 9:\ convS2M\ returned\ 0\ for\ tag\ 1\ fid\ 32\ T104"
from
.CW port/devmnt.c \-
a Styx reply the kernel's mount-maintenance process could not
decode \- immediately followed by the same
.CW freeFD
close of fd 4, consistent with
.CW kmount()
giving up on a connection that stopped making sense.  A later run
under the same live-pipe test hit
.CW OP(indx) 's
existing, un-gated bounds print with an index of
.CW \-1152874825133430486
against a length-10 array \- not an off-by-one, a garbage 64-bit
value \- inside whatever message-dispatch table on the mntgen side
that number was supposed to select from, and the emulator then sat
silent, alive but unresponsive, for the rest of that run: kmount()
left waiting on a mntgen that had just taken a fatal, uncaught
exception on the other end of the pipe.
.PP
Put together, this is no longer one bug: mount sometimes succeeds
outright: sometimes the shared fd goes missing under
.CW Mount
mid-call: and sometimes the two sides of the Styx conversation
mntgen speaks over that pipe \- built from
.CW nametree ,
.CW styxservers
and the new-format
.CW styx
library, none of which this board's native kernel had ever run before
this session \- desynchronize into garbage.  All three read as facets
of one source: the pipe both sides of this handshake share, and
whatever about its timing or its message framing this native kernel
does differently from whatever kernel last exercised
.CW mntgen 's
Styx server code successfully.  That is the frontier now, characterized
precisely enough that resuming it does not mean repeating this trace:
a real Inferno init running a real interactive shell command, three
structural fixes deep (modinit, the wait file, and the shell crash
each of those two exposed), into a Styx-over-pipe correctness problem
in shared, board-independent kernel and library code \- ordinary
enough that any board exercising
.CW mntgen
this way would meet it too, and specific enough now that the next
session's first move should be a message-level trace of that one
pipe, not another boot log.
.PP
Two candidate causes were checked directly and ruled out before that
message-level trace was attempted.
.CW port/devmnt.c 's
.CW mntattach()
sets
.CW "r->request.uname\ =\ up->user" \-
a live pointer into the kernel process's own field, not a copy \- and
.CW Sys_mount() 's
.CW release()
runs before this, so a stale-pointer race if that kernel process were
recycled mid-call was a real possibility.  Printed at both
.CW sizeS2M()
and the later
.CW convS2M()
across five runs: identical pointer, identical seven-byte
.CW \(dqinferno\(dq
content, every time, with no
.CW convS2M
failure in any of the five \- consistent with the earlier pattern of
this specific failure not showing up once instrumentation lands near
it, but the pointer itself is not moving.  Separately,
.CW mntrpcread() 's
.CW doread()
accumulates short reads in a loop against
.CW qlen(m->q)
before ever parsing a length prefix, and
.CW mntversion() 's
own reply loop does the same against
.CW GBIT32(msg) \-
both read the length-prefixed, streamed way a byte-oriented pipe
requires, not by assuming one
.CW read()
returns one whole message.  Neither looks like the source.
.PP
The
.CW OP(indx)
family's un-gated bounds print, already in this source from before
this session, was extended with the module name and Dis-level PC of
whichever program hit it, hoping to catch the garbage-index crash
with enough context to read its Limbo source line the way
.CW sh.b 's
bug was found.  Six more runs, none of them hit it \- rarer than the
fd race, not reproduced again this session.  That diagnostic is
reverted along with everything else tried this round; nothing in this
paragraph changed the tree.  What
.I would
catch it without perturbing the timing the way every print-based probe
in this section has: a QEMU-GDB-stub watchpoint on the specific
memory this pipe's data passes through, set once and left alone,
rather than another instrumented rebuild.
.PP
Tried, next session, and half right.
.CW lldb 's
.CW gdb-remote
against QEMU's
.CW \-s
does connect and does read live guest memory without disturbing
anything \- confirmed by polling
.CW Fgrp.fd
every half second while the guest ran normally underneath, address
stable across the whole run, matching every prior print-based
observation.  A hardware watchpoint on
.CW fd[4] 's
own memory, armed the same way, did not work: once set, the guest's
apparent progress stopped almost entirely \- QEMU's software MMU has
to check every memory access against an armed watchpoint's range when
there is no hardware acceleration for it, and this environment has
neither KVM nor HVF, so the guest that normally reaches
.CW "spawn\ sh\ -n\ /dis/init"
in a couple of seconds sat there for minutes without visibly
advancing further.  Killed, not fixed \- this is an environment
limit, not a bug to chase.
.PP
A breakpoint, not a watchpoint, is what actually worked: cheap for
TCG the way an ordinary PC compare is cheap, unlike a checked memory
range.  A breakpoint on
.CW fdclose()
itself, synchronous
.CW Continue() ,
its
.CW (Fgrp*,\ fd,\ flag)
arguments read straight off the stack at kencc's own calling
convention (arguments above the return address, not in registers)
each time it fired, ran at normal speed and produced a clean trace of
every fd this boot closed, tagged by which
.CW Fgrp
each one belonged to.
.PP
It surfaced something upstream of everything this section had been
chasing.  Before any fd in
.CW Mount 's
own group closed at all, the guest printed
.CW "sh:\ badmodule()\ cannot\ load\ /dis/lib/styx.dis:" \-
on a different run, the identical message for
.CW string.dis
instead.  Both files exist, both are correctly listed in
.CW pc64 's
.CW root
section, and this load is
.CW mntgen.b 's
own \- loading
.I its
copy of
.CW Styx
so it can serve one, at the very top of its
.CW init() ,
before mntgen has done anything else \- not the kernel's own load of
.CW osinit.dis
or
.CW sh.dis ,
which this section has never once seen fail.  Traced into
.CW libinterp/readmod.c :
every other failure exit sets an error string before returning nil;
the branch where
.CW kread()
returns something other than the requested length didn't, leaving
whatever
.CW up->errstr
last held \- often nothing \- for
.CW badmodule() 's
.CW %r
to print.  Fixed for the short-positive-read case, which is this
function's own finding and had nothing upstream to set a message for
it.  The negative-count case, a real
.CW kread()/error()
failure that should already carry its own message, was left alone on
the assumption that message survives back to the caller \- except the
.CW string.dis
run's empty
.CW %r
on what reads as this same call site says that assumption isn't
verified, so it is recorded open, not closed.
.PP
One more thing the same breakpoint trace turned up, not yet chased:
.CW mntgen.b
declares
.CW "refcounts\ :=\ array[10]\ of\ Entry;"
very near the top of the same file whose
.CW load\ Styx
call is failing \- a length-10 array, the exact length the earlier
un-gated
.CW OP(indx)
bounds print reported for the garbage-index crash two sessions ago.
Not confirmed as the same array; tried, and the attempt itself is
the finding.  Four addresses (the failure-path call site inside each
of
.CW "indx / indw / indf / indl" ,
found by disassembling the binary directly rather than connecting
first \- no live process needed for that, only the file's own bytes
at
.CW KTZERO
plus its header size) got breakpoints instead of one, on the theory
that four rarely-hit sites cost nothing extra.  They didn't hit: the
guest sat at 6% of normal CPU time over more than a minute of wall
clock, past the point every unwatched run reaches a crash, a bad
load, or a shell attempt within one or two seconds.  That retracts
part of the previous entry, not just extends it \- watchpoints are
not uniquely expensive here after all;
.I any
armed stop point seems to cost this pure-TCG guest a great deal, and
.CW fdclose() 's
apparent speed earlier was probably favorable timing (an early,
frequent call site caught before the cost compounded) rather than
evidence breakpoints are free.  Killed without a hit.  The
.CW array[10]
coincidence stands exactly where it stood before this attempt \-
plausible, unconfirmed \- and what would actually test it without
this overhead is a single, disposable
.CW kwerrstr()
or bare
.CW print()
added at the two ind* sites directly in source, one boot, revert
after: a method already used successfully elsewhere in this file,
set aside here only because the same information looked reachable
without a rebuild.  It wasn't, this time.
.PP
Done immediately after, for exactly this reason: all four
.CW ind*
prints extended with the same module-name lookup the debugger attempt
was trying to get to, eight plain boots, no debugger anywhere in the
loop.  None of the eight hit it either \- six sat silent at
.CW "spawn\ sh\ -n\ /dis/init" ,
two hit unrelated crashes already on record.  This closes the
question of
.I method
\- direct instrumentation remains the right tool and was not the
obstacle \- while leaving the
.CW array[10]
question exactly where it was: plausible, specific, and still
unconfirmed after roughly twenty boots across both attempts.  Whatever
triggers it is rare enough that catching it wants either many more
tries than one sitting affords or the specific condition the one run
that did hit it had \- a live interactive pipe into the emulator's
stdin, not a captured log \- reproduced deliberately rather than
hoped for.
.PP
Both halves of that conclusion needed correcting, in the next
sitting, without a live pipe anywhere.  A capture from a plain
captured boot, no interactive stdin involved, already showed the
real fault, and it had been sitting in the tree the whole time:
.IP
.nf
readmod: builtin lookup $Sys -> a26ca0 modules head /dis/mntgen.dis
readmod: builtin lookup $Sys -> a26ca0 modules head /dis/lib/styx.dis
readmod: builtin lookup $Sys -> a26ca0 modules head /dis/lib/styxservers.dis
readmod: builtin lookup $Sys -> a26ca0 modules head /dis/lib/nametree.dis
fdtochan: bad fd 4 maxfd 5 up->pid 9 up->text dis mod Mount
error err fd out of range or not open caller 0x27a5b3 up->pid 9
error nil error err  caller 0x2b67db up->pid 9
.fi
.PP
So the live-pipe precondition from the previous entry does not hold;
retracted here rather than left standing.  The four
.CW ind*
prints had been reapplied a third time, unchanged, before this was
noticed \- caught and reverted before a rebuild, since repeating an
already-negative result without changing anything about the attempt
would have added nothing.
.PP
.CW fdtochan()
itself reads
.CW "fd<0\ ||\ f\->maxfd<fd\ ||\ f\->fd[fd]==nil" .
fd 4 against maxfd 5 passes the range half of that test outright \-
the failure is the third clause, a nil slot, not an out-of-range
index.  The message
.CW "fd\ out\ of\ range\ or\ not\ open"
had been read as a range bug through every earlier pass at this;
it is a lifetime bug \- something closed slot 4 out from under a
process still holding it \- and every earlier hypothesis aimed at
the wrong class of cause.
.PP
.CW mount.b 's
.CW popen()
opens a pipe, spawns
.CW runcmd
sharing its fd group, and
.CW runcmd
does
.CW "sys\->pctl(Sys\->FORKFD,\ nil)" ,
dups its stdin fd to 0, then drops the
.CW stdin
variable.  Limbo has no explicit
.CW close ;
dropping the last reference is the only way to close a
.CW ref\ Sys\->FD ,
via the
.CW freeFD()
finalizer.
.CW mkfd()
captures
.CW up\->env\->fgrp
into the handle at creation time, before the fork; FORKFD then
rebinds
.CW o\->fgrp
to a fresh, duplicated group for whatever runs afterward, but every
.CW Sys_FD
value created earlier keeps pointing at the group it was actually
made in.  A
.CW stdin\ =\ nil
after FORKFD therefore closes fd 4 in the
.I pre-fork
group \- shared with whichever other process still holds that
group \- not in the fork's own private copy.  Whether that pre-fork
group is the parent Mount process itself, or another sibling spawned
off the same group before the fork, is exactly what the next boot's
instrumentation is built to answer; reasoned from the source, not
yet confirmed against a running kernel.
.PP
Also settled this sitting, at real cost and after one wrong turn: the
QEMU invocation itself, lost across a context boundary.
.CW ipc64
carries a multiboot header (magic
.CW 0x1BADB002
at file offset 72), so QEMU's own
.CW \-kernel
loader hands it straight to the guest \- but SeaBIOS still runs first
and still prints its own banner, and iPXE's too when a NIC is present;
that part is normal, and the first pass at this misread it as evidence
.CW \-kernel
was silently falling back to a full BIOS/PXE boot.  It wasn't.  The
multiboot jump happens right after, with no further BIOS or PXE
activity \- confirmed by checking the header's own address fields and
checksum, which were valid and matched the kernel's own printed memory
map exactly, ruling out a malformed header as the cause of the seven
runs in a row that produced no kernel output at all.
.PP
The actual cause: no boot argument can reach the kernel under
.CW \-kernel
except through the multiboot command line \-
.CW \-append
\- since there is no disk and so no
.CW plan9.ini .
Without one,
.CW getconf(\*(lqconsole\*(rq)
returns nil everywhere, and pc64 links both a VGA console
.RB ( screen.6 ,
.CW vgasoft.6 ,
.CW cga.6 )
and a serial one
.RB ( uarti8250.6 ).
With no
.CW console=
argument the guest picked one silently and wrote everything to it;
.CW \-nographic
mirrors COM1, not VGA text, so when the guest chose VGA every line of
kernel output went somewhere QEMU's console flags were never reading
from.  The guest sat at very close to 100% CPU the whole time \-
genuinely running, not hung \- which is what made this take a session
to tell apart from a wrong boot chain or a silent crash: a stopped
guest, a hung one and a live one writing to the wrong device all look
identical from the invoking end.
.CW "\-append\ 'console=0'"
is the fix, confirmed against the historical capture's own printed
.CW "Boot\ configuration"
dump, which carries exactly that
.CW console=0
entry.
.PP
.CW \-boot\ n
forces iPXE's own DHCP/TFTP path instead of the multiboot jump, which
also works but is a different, far noisier and slower chain; comparing
logs across the two is comparing different boots.  And
.CW "\-serial mon:stdio \-display none"
emits nothing for this kernel at all, regardless of
.CW \-append
\- only
.CW \-nographic
shows any boot output.  Recorded this time as
.CW os/inferno/pc64/qemu-boot.sh
rather than left to be lost again, with the wrong turn left in its own
comment rather than edited away: the fastest way to lose this a third
time is to remember only the answer and not the diagnostic that got
there.
.PP
With the console fixed, a plain unmodified boot (the tree as it
stands, no diagnostic prints anywhere) reaches
.CW "spawn\ sh\ -n\ /dis/init"
and then goes quiet \- CPU usage drops to near zero and stays there,
confirmed idle rather than crashed for over a minute of wall clock \-
exactly the shape the earlier eight-boot
.CW ind*
attempt already recorded for six of its eight runs.  That establishes
a hang, on the plain tree, with nothing added; it does not by itself
establish which fault causes it \- an overstatement in an earlier
draft of this entry, corrected here rather than left standing.
.PP
Instrumented to find out: prints in
.CW freeFD() ,
in
.CW fdtochan() 's
failure branch, and in
.CW Sys_pctl() 's
FORKFD case, each carrying the running Prog's id and module name where
the type made that visible.
.CW fdclose()
itself was instrumented once and the print then removed \- it fires on
every fd close system-wide, which is exactly the kind of broad,
hot-path perturbation this section had already been warned about, and
a narrower print in
.CW freeFD()
answers the same question with less of it.
.PP
The trace this produced refutes the previous entry's leading
hypothesis rather than confirming it.  At the point mount.b's
.CW popen()
forks
.CW runcmd 's
file-descriptor group
.RB ( "FORKFD:\ ofg\ 7967c08\ nfg\ 7989888" ),
fd 4 later fails with
.CW "f\ 7967c08" \-
the
.I pre-fork
group, exactly as guessed.  But the Prog reporting the failure is not
a sibling holding a stale reference to that group; it is the same Prog
that owns 7967c08 in the first place, reported under the same kernel
process id both times.  Cross-process FORKFD staleness needed a
different Prog on one side of the close and the use; there wasn't
one, so that mechanism is not what is happening here, and the
.CW mkfd() /
.CW handle\->grp
reasoning built on it in the previous entry does not hold up.
.PP
Worse for that entry: the
.CW fdtochan
failure line came from
.I inside
.CW freeFD() 's
own call to
.CW kfgrpclose() ,
whose only two statements are exactly
.CW fdtochan()
followed by
.CW fdclose() ,
and whose comment says outright that this check exists because
.CW "fdclose\ takes\ care\ of\ processes\ racing\ through\ here" .
.CW kfgrpclose()
wraps the whole thing in
.CW waserror()
and returns
\-1
on exactly this failure, silently.  So the message this section spent
a full sitting chasing is not a crash and not the hang's cause; it is
a closer finding a slot already empty, on a path the original authors
built to tolerate that outcome without complaint.  It surfaced at all
only because this section put an unconditional print on
.CW fdtochan() 's
failure branch \- useful for finding it, misleading about what finding
it meant.
.PP
What is still true and still useful:
.CW fdclose()
does get called twice in a row on the same
.RB ( grp ", " fd )
pair at several points in this trace, including the one at fd 4 in
7967c08, which is consistent with
.CW popen() 's
own local
.CW fds[0]
and
.CW runcmd 's
.CW stdin
parameter aliasing the same pipe end and each independently dropping
their reference to it \- ordinary, and handled.
.PP
Four more things settled this sitting, each correcting something the
previous entry got wrong rather than just adding to it.
.PP
First: the
.CW error("")
at
.CW "R.FP\ ==\ nil"
in
.CW xec.c
(around line 771) is not a fault at all.  It is commented in the
source as the designed mechanism by which a Dis Prog's last frame
unwinds \- "clear error, if any, goto vmachine()'s waserror() and call
progexit() there."  So the
.CW "error nil error err"
line this section has been chasing since the very first capture is a
Prog terminating, full stop; it carries no information about success
or failure on its own.
.PP
Second: a discriminator print placed between
.CW closefgrp()
and
.CW acquire()
inside
.CW freeFD()
showed both completing even on the fd-4-in-7967c08 path that returns
.CW "r\ \-1" .
The guest is not stuck inside
.CW freeFD() .
.PP
Third, and this is the one that overturns the previous entry's closing
paragraph: a print placed directly on
.CW Sys_mount() 's
return value, needing no Limbo rebuild and unreachable by any namespace
question, shows
.RS
.nf
.CW "Sys_mount: fd 4 on /n ret 16 errstr  pid 1"
.fi
.RE
\-
.CW ret
is 16, not negative, and
.CW errstr
is empty.
.CW mount.b 's
own
.CW "if(ok\ <\ 0)"
never fires,
.CW fail()
is never called, nothing is raised.  The mount succeeds.  So the
.CW error("")
Prog-exit noted above is
.CW mount.b 's
.CW init()
returning normally after a successful mount, not an uncaught
exception unwinding the whole script \- the theory that
.CW "sh\ -n" 's
no-namespace-fork semantics let a mount failure kill the entire boot
script is not what is happening, and is retracted here.
.PP
The fd-4 double close itself is now fully explained, and it is
ordinary.
.CW bindmount()
in
.CW sysfile.c
(the C function behind
.CW kmount() ),
after
.CW cmount()
has installed the new mount in the namespace, does this itself:
.RS
.nf
.CW "if(ismount){"
.CW "	fdclose(up\->fgrp, fd, 0);"
.CW "	..."
.CW "}"
.fi
.RE
The kernel closes the fd it was handed as the deliberate last step of
a successful mount \- the fd was only ever needed to reach
.CW mntattach() ,
and once
.CW cmount()
has taken the connection into the namespace the fd table entry is
surplus.  This happens
.I inside
the
.CW Sys_mount()
call, before it returns.  Later, when mount.b's own Limbo-level
.CW ref\ Sys\->FD
value for that same fd is dropped (function return, reassignment,
whatever triggers its GC finalizer), its
.CW freeFD()
tries the same
.RB ( grp ", " fd )
pair a second time and finds it already empty \- exactly the shape
this section spent so long on, and exactly what
.CW kfgrpclose() 's
own comment already said it was built to tolerate.  No cross-process
race, no stale
.CW handle\->grp ,
no torn-down mount channel: one kernel-mandated close followed by one
harmless Limbo-level echo of it.
.PP
What is not yet explained: across every capture, plain or
instrumented, nothing has ever been observed after
.CW Sys_mount 's
return \- not
.CW "sysname=$sys" 's
effects, not the unconditional
.CW "echo\ $bootargs" ,
nothing \- across four runs on this build ranging from about 40 seconds
to 4 minutes 15 seconds of wall clock before each was killed, all
staying at near-zero CPU throughout.  With the mount confirmed to
succeed and the fd story now fully accounted for, this stall has no
remaining explanation in hand.  The next instrumentation is a print in
.CW devmnt.c 's
.CW mountio()
on send and on reply, by tag, to see whether the shell's next steps
after
.CW mount
ever touch
.CW /n
at all, and if so whether anything answers.  Not yet done.
.PP
Fourth, a harness limit rather than a kernel finding, but one that
forecloses a whole class of future test and so belongs here: this
sitting tried to settle the open question above by feeding a live
command through a held-open fifo into a
.CW \-nographic
boot and watching for its echo.  None came, across a boot given nearly
four minutes to reach whatever state it was going to reach.  That
result turned out to be uninterpretable rather than negative:
.CW "console=0"
wires the console uart's
.I output
queue to
.CW serialoq
(the kernel
.CW print()
target) in
.CW devuart.c 's
.CW uartinit ,
but assigns no matching input queue anywhere; keyboard input on this
board still comes only from
.CW devkbd ,
which this invocation never wires to anything QEMU's console
multiplexes stdin into.  So no echo was ever possible here regardless
of whether the guest was alive and waiting \- the test measured the
harness, not the kernel.  Recorded in
.CW qemu-boot.sh
itself so this is not attempted cold again.
.NH 1
The mount stall was never a stall
.PP
The planned next instrumentation \- a print in
.CW devmnt.c 's
.CW mountio()
on send and on reply, by tag \- was added and built.  None of its
three prints (entry, sent, reply) ever fired.  In their place, twice
in one capture, the boot hit
.RS
.nf
.CW "panic: general protection violation"
.fi
.RE
with the Mount proc, pid 9, as context.  That is a different symptom
from the near-zero-CPU idle sit the previous section describes, and
the instrumentation was new, so the obvious question came first:
does this reproduce on the plain tree, or did adding three prints to
.CW mountio()
introduce it?
.PP
.CW devmnt.c
was reverted, and
.CW ipc64
rebuilt clean \- byte-identical in size to the pre-instrumentation
baseline.  One clean boot is not a control; a single quiet run and a
single crashing run both happen under a genuine race either way.  Four
clean boots were taken instead, and all four failed, no two of them
alike:
.IP \(bu 2
.CW "panic: loading \(dq/osinit.dis\(dq: file does not exist" ,
before
.CW "Welcome to Inferno..."
ever prints \- the earliest possible failure point, on a file that
every other boot in this whole document finds without trouble.
.IP \(bu 2
general protection violation, proc
.CW "<nil>\ 1" ,
immediately after
.CW "Welcome to Inferno..." ,
before
.CW sh.dis
even loads.
.IP \(bu 2
general protection violation, proc
.CW "dis\ 9" ,
after
.CW "spawn\ sh\ -n\ /dis/init" \-
the same shape as the instrumented run above, on the same pid.
.IP \(bu 2
no panic within the observation window, idle at low CPU shortly after
.CW "spawn\ sh\ -n\ /dis/init" \-
indistinguishable, this far in, from the earlier section's stall.
.PP
So the panic is real and reproduces on the untouched tree; the
.CW mountio()
prints did not cause it, and are not yet a useful diagnostic because
the boot dies before they would fire on at least two of these four
paths.  It is also not one deterministic failure with cosmetic
variation \- it is a genuine race that lands at different points on
different runs, which four of the previous section's own idle-stall
observations are now better read as: the same race simply not
tripping within the observation window, not a fifth distinct
behaviour.
.PP
The first pass at reading the panic's fault PC against
.CW ipc64 's
own symbol table (the same hand-written a.out parser used earlier in
this document, no
.CW nm / inm
needed) took the nearest preceding
.CW T
symbol without checking the following one, and landed on
.CW adec+0x3c \-
suggestive, since
.CW adec()
is the function behind the
.CW ADEC()
GC refcount-decrement macro, but wrong: the gap to the next captured
symbol was almost 4 KB, far bigger than
.CW adec()
itself, so the attribution was unproven.  Resolving both bounding
symbols and checking the gap width fixes this.  The two crashing PCs
captured from the clean-tree runs above resolve to
.RS
.nf
.CW "newstack+0x45  (gap to next symbol: 295 bytes)"
.CW "destroy+0xeb   (gap to next symbol: 316 bytes)"
.fi
.RE
both small enough to trust.
.CW newstack()
.RB ( libinterp/stack.c )
and
.CW destroy()
.RB ( libinterp/heap.c )
are both Dis heap/frame management, not one function twice \- and
.CW destroy() 's
own body calls
.CW ADEC(&h\->ref)
a few lines in, so the original
.CW adec+0x3c
misread was not baseless: the compiler most likely inlined
.CW adec()
into
.CW destroy() ,
which is why no separate
.CW adec
frame appears on the corrected walk.  The refcount-decrement theory
survives the correction; only its attribution needed fixing.
.PP
One register is worth recording on its own.
.CW R14
carries
.CW up
on this port (see the boards-and-registers section above), and both
captured crash dumps show it holding a value ending in hex
.CW 4
\-
.CW 0x6EC2054
and
.CW 0x6ECB354 \-
neither an 8-byte-aligned address.  Every
.CW Proc*
this kernel hands out comes from
.CW &procalloc.arena[i] ,
plain C array indexing on a struct that (containing pointers) is at
least pointer-aligned, so a legitimate
.CW up
can never end in anything but
.CW 0 .
Both crashes show the same wrong low nibble, which is a corruption
signature, not noise: consistent with an index computed in 4-byte
units somewhere upstream landing in a slot meant to hold an 8-byte
pointer, in the shape of this tree's own recurring 32-bit-.CW long
assumption (see the Osprey doc's note on the idiom, carried into this
document's memory as a standing suspect).  No such site has been
found yet \- every direct assignment to
.CW up
was checked
.RB ( "proc.c:281's\ up\ =\ p;" ,
plus
.CW main.c 's
two boot-time
.CW "up\ =\ nil" \(dq s),
and the interrupt entry/exit in
.CW pc64/l.s
saves and restores
.CW R14
with matched
.CW "PUSHQ / POPQ" ,
not narrower \- so the corruption is not at any of the places a
register-variable port would obviously get this wrong, and remains
open.
.PP
State of play: a real, reproducible, nondeterministic fault exists
inside Dis heap/frame management, independent of any diagnostic
added this session, with a corrupted
.CW up
present at at least two of its manifestations.  Not yet fixed.  The
next diagnostic is not another print in
.CW mountio() \-
the boot rarely reaches it \- but tracing backward from
.CW newstack()
and
.CW destroy()
to find where
.CW p->R.M
(consumed by
.CW newstack() )
or the heap pointer passed to
.CW destroy()
first goes bad, and separately, instrumenting
.CW sched()
itself to catch the first moment
.CW up
stops being 8-byte aligned.
.NH 1
Found: the misalignment, real and deterministic, not a race
.PP
The instrumentation was added.  It fired on every single boot, before
any panic, with the same two numbers every time:
.RS
.nf
.CW "sched: up misaligned 0x6ec2054 index 0 runproc-caller 0x111fd8"
.CW "sched: up misaligned 0x6ec32b4 index 1 runproc-caller 0x111fd8"
.fi
.RE
.CW index
here is
.CW "p - procalloc.arena" ,
plain C pointer subtraction \- and it is exactly
.CW 0
and
.CW 1 .
.CW p
genuinely is
.CW &procalloc.arena[0]
and
.CW &procalloc.arena[1] ;
the array indexing is not the problem.  The base of the array itself
is misaligned, on every boot, identically.  That is not a race
signature \- that is a deterministic bug that a race had been
mistaken for, because it only produces a fault when whatever reads
the misaligned pointer later happens to care.
.PP
.CW procalloc.arena
comes from
.CW xalloc()
in
.CW port/xalloc.c ,
which carves blocks out of a hole list and returns a pointer to a
private
.CW Xhdr 's
.CW data
member:
.RS
.nf
.CW "struct Xhdr {"
.CW "	u64	size;"
.CW "	u32	magix;"
.CW "	char	data[1];"
.CW "};"
.fi
.RE
.CW size
is 8 bytes,
.CW magix
is 4:
.CW data
begins at byte offset 12 from the header.  The header itself sits on
an address that
.CW xallocz()
keeps rounded to
.CW BY2V
(the machine's word size) by rounding the total request
.RB ( "size\ +=\ BY2V\ +\ sizeof(Xhdr);\ size\ &=\ ~(BY2V-1);" )
before carving it off the hole \- so the header is always
.CW BY2V
\-aligned.  On a 32-bit port,
.CW BY2V
is 4, and 12 is already a multiple of 4:
.CW data
comes out aligned by construction, and this code has apparently been
fine on every board this tree has run on until now.  On
.CW pc64 ,
.CW BY2V
is 8, and 12 is not a multiple of 8:
.CW data
always comes out 4 bytes short of 8-byte alignment, unconditionally,
for
.I every
.CW xalloc()
call on this board \- procs, and anything else that goes through it.
This is the 32-to-64-bit assumption this tree keeps tripping over,
just in a header layout instead of a
.CW long .
.PP
The fix pads the header:
.RS
.nf
.CW "struct Xhdr {"
.CW "	u64	size;"
.CW "	u32	magix;"
.CW "	u32	pad;"
.CW "	char	data[1];"
.CW "};"
.fi
.RE
16 bytes, a multiple of 8 on this board and still a multiple of 4 on
every 32-bit one, so nothing there regresses.
.CW port/xalloc.c
is shared code, not board-specific, and no other caller assumes
.CW sizeof(Xhdr)
is 12 anywhere in this tree.
.PP
Rebuilt clean (the diagnostic print removed, only the header padding
kept) and run ten times.  Zero of ten hit the misalignment print;
zero hit the GC/heap general protection violation that this whole
investigation started from \- a real change, since the pre-fix
sessions immediately above this one hit that panic on roughly half
of every batch that reached this far.  One of ten hit a new,
different panic:
.RS
.nf
.CW "alloc:D2B: 784c2b8 in heap: in free blk at 784c298 ..."
.CW "panic: alloc:D2B 784c2b8 (from 2bdbb4/319af8)"
.fi
.RE
this is the
.I pool
allocator's own consistency check
.RB ( os/inferno/port/alloc.c ,
.CW "heapmem / mainmem" ,
a wholly separate header family from
.CW xalloc() 's
.CW Xhdr ) ,
correctly catching a pointer into a block already marked free \- a
real, still-open bug, but a different and better-behaved one: it is
caught by name at a checked boundary instead of silently corrupting
memory until something faults at random.  Whether it predates this
fix and was simply never reached, or is newly exposed by it, is not
yet known.  One of ten got further than any capture in this entire
document: past
.CW "spawn\ sh\ -n\ /dis/init"
to
.RS
.nf
.CW "mount: can't load /dis/lib/dial.dis:"
.fi
.RE
with an empty exception string \- new territory, not yet chased.  The
remaining eight of ten sat idle at
.CW "spawn\ sh\ -n\ /dis/init"
through the observation window, the same point every boot in this
document reaches before whatever happens next \- so the original
stall this document opened with is
.B not
resolved by this fix; what changed is that the wild-pointer panic
that had been competing with it for which failure showed up first is
now gone, or nearly so, in ten runs.
.PP
Not committing the
.CW sched()
diagnostic print itself \- it did its job.  The
.CW Xhdr
padding is the fix, and is what is committed.
.NH 1
The mount round-trip, finally observed
.PP
With the misalignment fixed, the
.CW mountio()
send/reply tracing this document has been planning to add since two
sections ago was put back \- entry, sent, and reply prints, and one
more on
.CW Sys_mount() 's
own return value, the same shape used earlier in this document.  One
boot produced, for the first time anywhere in this investigation,
a complete and clean round trip:
.RS
.nf
.CW "mountio: entry tag 1 fid 32 T104 pid 1"
.CW "mountio: sent tag 1 fid 32 T104 pid 1"
.CW "mountio: reply tag 1 T104 R105 pid 1"
.CW "Sys_mount: fd ... on /n ret 16 errstr ... pid 1"
.fi
.RE
T104 is
.CW Tattach ,
R105 is
.CW Rattach :
.CW mntgen
answered its attach, the reply was muxed back to the waiting rpc, and
.CW kmount()
returned a real, positive mount id, all inside one print-visible
sequence for the first time.  (The
.CW fd
and
.CW errstr
fields on that last line are not trustworthy as printed \- the print
sits after
.CW acquire() ,
reading
.CW f
and
.CW up->errstr
again from outside the window
.CW release() / acquire()
actually protects, and
.CW errstr
in particular is a leftover per-process buffer that is never
guaranteed clear on success; the
.CW ret
value alone, 16, is the one field this print can be trusted for, and
it agrees with every earlier capture that also saw a successful
mount.)
.PP
And then, again, nothing.  No second
.CW mountio()
entry, no further console output at all \- not even
.CW /dis/init 's
own unconditional
.CW "echo\ $bootargs" ,
the very next non-comment line after
.CW "mount\ {mntgen}\ /n"
in the script, which needs no I/O and no
.CW mountio()
traffic to run.  Reading
.CW /dis/init
end to end: after the mount, execution should fall through
.CW "sysname=$sys" ,
print
.CW bootargs ,
skip the whole
.CW "and\ {ftest\ -e\ '#e/bootargs'}"
block (nothing set
.CW bootargs=
on this invocation's command line), and reach the script's last
line,
.RS
.nf
.CW "sh -n -l -i #-l # to run the /lib/sh/profile"
.fi
.RE
an
.I interactive
shell, meant to block reading the console for a command \- which,
given this document's own earlier finding that
.CW console=0
wires console output only, with keyboard input coming solely from
.CW devkbd
and nothing in
.CW qemu-boot.sh
connecting anything to it, would be indistinguishable from exactly
this: total silence, near-zero CPU, forever.  If that is what is
happening, the boot is not stuck at all \- it has reached the
interactive prompt this whole document has been aiming at, and is
correctly waiting for a keystroke the harness cannot deliver.
.PP
That is not yet established, though, and the more literal reading of
what was captured argues against it: zero console output appeared
between the successful
.CW Sys_mount
return and the process going quiet, and
.CW echo
should be visible immediately, well before any namespace work or a
shell prompt.  If execution really did reach
.CW "echo\ $bootargs" ,
that line is missing.  The gap this leaves is narrow \- between
.CW kmount()
returning inside
.CW Sys_mount()
and the calling proc, pid 1, executing its next few bytecode
instructions \- and points at the syscall-return/scheduling path
rather than at mount, namespace, or heap corruption, all three of
which are now independently accounted for.  Not yet instrumented.
.PP
It was, immediately after: a print at the top of
.CW consread() 's
.CW Qcons
case, the one place a
.CW sh\ -n\ -l\ -i
prompt would block reading the console.  Three minutes and six
seconds, and it never fired once.  That rules out the interactive-
prompt theory from the previous section outright \- the calling proc
never reaches a console read at all, so the silence is not this
document's own
.CW console=0 -is-output-only
finding manifesting as a correctly-blocked shell.  Whatever
.CW /dis/init
does between the mount returning and going quiet, it does not get
as far as
.CW consread() .
Reverted before committing, as the diagnostic before it was.
.PP
So: kernel-level mount confirmed complete and correct
.RB ( T104 / R105 ,
.CW ret\ 16 ) ,
GC/heap misalignment fixed and independently verified over ten
boots, and the interactive-shell-prompt theory now excluded by a
three-minute negative result on the one call that theory predicted
would fire.  What is left is exactly the gap named at the end of the
previous section \- between
.CW kmount()
returning and pid 1's next bytecode \- narrower now than at any
earlier point in this document, but still open.
.NH 1
How a native kernel provides networking
.PP
The stack is in the kernel and it is reached as files.  There is no
socket call anywhere.
.IP \(bu 2
.CW os/inferno/ip
holds it: the protocols
.RB ( tcp.c ,
.CW udp.c ,
.CW icmp.c ,
.CW icmp6.c ,
.CW il.c ,
.CW rudp.c ,
.CW esp.c ,
.CW gre.c ,
.CW igmp.c ),
the core
.RB ( ip.c ,
.CW ipv6.c ,
.CW ipifc.c ,
.CW iproute.c ,
.CW arp.c ,
.CW ipmux.c ,
.CW nat.c ,
.CW netlog.c )
and the helpers beside them.
.IP \(bu 2
.CW os/inferno/ip/devip.c
is
.CW #I ,
and a program binds it on
.CW /net .
Everything after that is
.CW open ,
.CW read
and
.CW write
on
.CW /net/ipifc/clone ,
.CW /net/tcp ,
.CW /net/udp ,
.CW /net/arp ,
.CW /net/iproute
and
.CW /net/log .
.IP \(bu 2
Which protocols a kernel has is a line in its config file.  The
.CW ip
section becomes
.CW ipprotoinit[]
in the generated
.CW <conf>.c ,
and
.CW devip.c 's
attach walks it calling each
.CW <proto>init(Fs*) ,
so a board with no use for a protocol does not carry it.
.IP \(bu 2
Cards are a separate thing joined to it by a
.CW Medium .
.CW os/inferno/port/devether.c
is
.CW #l ;
a driver registers with
.CW addethercard("virtio",\ reset)
from a
.CW <name>link()
function, and the config's
.CW link
section becomes the
.CW links()
the kernel calls at boot.
.CW os/inferno/ip/ethermedium.c
is the join, and it is worth reading: its
.CW bind
opens
.CW "#l0/addr"
through
.CW namec
and reads the mac, so the ip stack reaches a card the way any program
would \- by name, through the name space.
.CW loopbackmedium.c ,
.CW pktmedium.c ,
.CW nullmedium.c
and
.CW netdevmedium.c
are the others.
.IP \(bu 2
Addresses are userland's business.
.CW os/inferno/init/virtinit.b
binds
.CW #I
on
.CW /net ,
opens
.CW /net/ipifc/clone ,
and hands it to
.CW dhcpclient ;
a static setup writes
.CW "bind ether /net/ether0"
and
.CW "add <ip> <mask>"
to the same file.
.PP
So a board brings up networking by naming three things in its config
\- the protocols in the
.CW ip
section, the card driver and its medium in the
.CW link
section, and
.CW ether
and
.CW ip
in the
.CW dev
section \- and by binding
.CW #I
at boot.  Nothing in that path is a library the kernel links.
.NH 1
How a native kernel gets its ip helpers
.PP
The RISC-V boards listed
.CW ip
in their config's
.CW lib
section, which
.CW os/inferno/port/portmkfile
resolves to
.CW $ROOT/libip
\- the
.I hosted
helper library, whose
.CW readipifc.c
opens and reads
.CW /net/ipifc .
That cannot compile against a kernel's
.CW libc.h ,
and it never did: the
.CW libip.a
those kernels were linking was an artifact left in
.CW Inferno/riscv64/lib
from before that header existed.  Compile it today, for either native
target, and it fails the same way.
.PP
Nothing else does it that way.
.IP \(bu 2
Upstream Inferno's native configs link no ip library at all.
.CW os/pc/pc
asks for
.CW "interp keyring draw memlayer memdraw tk sec mp math kern"
and nothing more; the byte order helpers come from
.CW os/port/netaux.c ,
named on the
.CW ether
line as
.CW "ether netif netaux ethermedium" ,
and the address helpers from the kernel's own
.CW os/ip/ipaux.c .
.IP \(bu 2
9front here keeps a kernel library,
.CW os/9front/lib ,
built as
.CW lib9front.a :
.CW bo.c ,
.CW eipfmt.c ,
.CW ipaux.c ,
.CW parseip.c ,
.CW ptclbsum.c ,
.CW classmask.c ,
.CW equivip.c ,
.CW parseether.c
\- the same content as libip, compiled for a kernel.
.IP \(bu 2
Osprey here does the same in
.CW os/osprey/kernlib ,
built as
.CW libospreykern.a .
.PP
Inferno had neither, so it reached for the hosted library.  It has them
now, as kernel source rather than as a library, which is upstream
Inferno's arrangement:
.CW os/inferno/port/bo.c
under the
.CW port
section, and
.CW parseip.c ,
.CW eipfmt.c ,
.CW ptclbsum.c ,
.CW classmask.c ,
.CW equivip.c
and
.CW parseether.c
in
.CW os/inferno/ip
under the
.CW ip
section, with
.CW isv4 ,
.CW v4tov6 ,
.CW v6tov4
and the v4 well known addresses added to
.CW os/inferno/ip/ipaux.c
where upstream keeps them.  The files are 9front's rather than upstream
Inferno's because this tree's
.CW os/inferno/ip/ip.h
is 9front's: its
.CW parseip
returns a
.CW vlong
and its
.CW parseipmask
takes a third argument, which upstream's do not.
.PP
Three small things came with them.
.CW parseip.c
wanted
.CW isxdigit
and
.CW isalnum
from
.CW <ctype.h> ,
which a kernel has not got, so it has two predicates of its own; it
wanted
.CW CLASS ,
which is in the shared
.CW include/ip.h
that a kernel does not include; and
.CW bo.c 's
.CW ulong ,
.CW vlong
and
.CW ushort
became
.CW u32 ,
.CW u64
and
.CW u16 ,
which is what
.CW os/inferno/port/portfns.h
declares and what a network field is on a target whose long is eight
bytes.
.PP
All three boards still run a shell with no ip library linked.
.NH 1
Then
.PP
QEMU virt first, because it is the cleanest new instruction set and the
best thing to bring up against: S-mode, SBI, Sv39, PLIC, CLINT, a UART
and virtio.  Then the same kernel on a VisionFive 2 and on a Raspberry
Pi 5, which are two inexpensive machines rather than two simulators.
.PP
.I virtio
deserves to be a platform of its own rather than a driver in one board:
net, block, GPU, input, entropy and serial, one small family covering
QEMU, KVM and most of what a cloud runs.  A native Inferno that speaks
it is a very small appliance.
.PP
And PCI belongs in a namespace rather than under a driver model:
.IP
.nf
/dev/pci/1.0.0/ctl config bar0 irq
.fi
.PP
with a driver attaching to the resource rather than being registered
against a table.  That is the move Inferno already made for networking
and for graphics, and it is the one worth making for accelerators too:
a
.CW /dev/compute
that says
.CW ctl ,
.CW mem ,
.CW submit
and
.CW sync ,
with a CPU, a GPU or an NPU behind it, rather than a Vulkan or a Metal
interface handed up to Limbo.
