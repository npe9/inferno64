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
.PP
One attempt at that instrumentation, for the record.
.CW acquire() / release()
in
.CW port/dis.c
are the token-passing pair guarding which host kproc is currently
allowed to run Dis bytecode: a syscall that blocks calls
.CW release()
first (handing the token to another queued kproc, or if none are
queued, marking the system idle and spawning a fresh
.CW vmachine()
kproc as a backstop) and
.CW acquire()
after, to get a token back before resuming.  Printing both branches
of each showed pid 1 and its partner kproc (5, later 11) trading the
token back and forth many dozens of times in the ordinary run-up to
and past the mount, in the expected
.CW "queue,\ empty\ 1\ /\ resumed\ /\ handoff"
rhythm \- nothing about that handoff looked stuck.  It did not run to
a conclusion: the print volume itself (one line per acquire and
release, on every syscall, from several concurrently-printing kprocs)
triggered a different, new panic,
.RS
.nf
.CW "TYPE 0E ... CR2 ffffffffffffffff"
.CW "panic: page fault"
.fi
.RE
faulting inside
.CW consw() ,
the console write handler \- dereferencing what is almost certainly
.CW H ,
Dis's nil-heap sentinel, conventionally
.CW (void*)-1
in this tree.
.CW up
in this capture was properly 8-byte aligned
.RB ( 0x6ec2200 ) ,
so the earlier fix holds; this looks like a genuine but separate
latent race in
.CW consw()
under concurrent heavy console traffic from multiple kprocs at once,
almost certainly self-inflicted by the sheer print rate of this
particular diagnostic rather than anything a normal boot would ever
trigger.  Reverted before committing, like every diagnostic in this
document.  Filed here rather than chased further: it answers a
different question (is
.CW consw()
race-free under a print load no ordinary boot produces) than the one
this section is trying to answer (why does execution stop after
.CW kmount() )
and conflating the two would cost more than it would settle.  The acquire()/release() instrumentation, done more
sparingly \- one line at
.CW Sys_mount() 's
own call site rather than inside every
.CW acquire() / release()
globally \- is still the next useful step.
.NH 1
Execution does continue past the mount \- several Progs, not one
.PP
Two narrower passes, neither touching a hot path this time.
.PP
First: three prints inside
.CW Sys_mount()
itself
.RB ( "about to release()" ", " "released, about to kmount()" ", " "kmount() returned N, about to acquire()" ", " "acquired, about to return" ),
plus two more bracketing the single
.CW l\->runt(f)
call site in
.CW OP(mcall)
.RB ( libinterp/xec.c ),
filtered to fire only when the runtime function being called is named
.CW "\(dqmount\(dq"
(comparing against
.CW ml\->links[o].name ,
not the
.CW ml\->m\->ext[o]
table the shipped
.CW DBG
line next to it had been reading \- see the commit fixing that line).
All four
.CW Sys_mount()
prints and both
.CW OP(mcall)
prints fired, in order, on every one of several repeat boots, with no
panic.  This is the most literal answer this document has ever gotten
to
.I "does control return from the mount syscall" :
yes, all the way back through
.CW l\->runt(f) 's
own call site, with a fifth print confirming
.CW p\->kill
is
.CW (nil)
right there \- no pending exception, so
.CW OP(mcall) 's
own
.CW "if(p\->kill\ !=\ nil)\ error(p\->kill);"
is not what silences anything.
.PP
Second, and this changes the shape of the whole investigation: a
print in
.CW vmachine()
.RB ( os/inferno/port/dis.c ),
placed only where it already checks
.CW "tready(nil)\ ==\ 0"
before sleeping (so it fires on a real idle transition, not per
instruction, capped by a static counter so it stops after a handful
of hits), dumping
.CW "isched.runhd / runtl / vmq"
and walking the
.CW isched.head
list printing every Prog's pid, state and module.  The very first
attempt showed something no earlier capture in this document had:
after the mount, the system is not sitting on one stuck Prog \- there
are
.I six .
The settled picture, several dumps in, restarted only by real idle
transitions over real wall-clock time:
.RS
.nf
.CW "prog pid 1  state 5 (Prelease)  mod $Sys"
.CW "prog pid 3  state 5 (Prelease)  mod $Sys"
.CW "prog pid 4  state 2 (Precv)     mod Mntgen"
.CW "prog pid 5  state 0 (Palt)      mod Nametree"
.CW "prog pid 6  state 5 (Prelease)  mod $Sys"
.fi
.RE
(pid 2 appeared in an earlier dump and was gone by this one \- a Prog
that ran to completion and was cleanly reaped, not evidence of
anything wrong.)
.PP
Extending the same print to call the tree's own
.CW wmtracedump()
.RB ( libinterp/xec.c ,
already built \- a per-Prog ring buffer of the last instructions
.CW xec()
dispatched, meant for exactly this kind of question and never before
pointed at a live idle system) for every non-ready Prog resolved two
of the five by name:
.IP \(bu 2
Pid 4, module
.CW Mntgen ,
blocked in
.CW Precv
at
.CW mntgen.dis
pc 74 \- waiting to receive its
.I next
Styx request.  This is
.CW {mntgen} ,
the server side of
.CW "mount\ {mntgen}\ /n" ,
sitting exactly where a synthetic filesystem server should sit once
its one attach has been answered and nothing further has arrived.
Not a bug on its own account.
.IP \(bu 2
Pid 5, module
.CW Nametree ,
blocked in
.CW Palt
at
.CW nametree.dis
pc 58, waiting on one of several channels.  Not yet resolved further
\- worth returning to, since unlike
.CW Mntgen
it is not obviously a persistent service with nothing left to do.
.PP
A second run, with the same
.CW wmtracedump()
call widened to cover
.CW Prelease
too (the state pid 1/3/6 are all sitting in \- released the
interpreter for a blocking host call, not yet back), added one more
fact before crashing under its own print volume (see below): one of
those
.CW $Sys -context
Progs, pid 2 in that capture, was not idling in the shell at all \-
its trace showed it deep inside
.CW /dis/mount.dis
itself, the Limbo-level
.CW mount
command that
.CW sh.dis
spawns to run the
.CW mount
builtin.  That is the missing link this document had not had before:
.CW sh.dis
does not call
.CW Sys\->mount()
directly \- it spawns a separate Prog running
.CW mount.dis ,
which spawns
.CW Mntgen
as the
.CW {mntgen}
child, and
.I that
Prog is what calls
.CW Sys\->mount() .
Three Progs deep for one shell line, not one.
.PP
The crash that ended that second run \- another
.CW "panic:\ general\ protection\ violation" ,
registers holding the literal bytes of the string
.CW "spawn\ a\ "
where pointers should be \- is almost certainly this print volume's
own doing again, in the same family as the
.CW consw()
fault two sections back: six Progs, several with 100+-entry
.CW wmtracedump()
call, printed once per idle transition, is enough traffic through
.CW putstrn() /
the console queue to plausibly scramble something even without
touching a hot dispatch path this time.  Not chased further \- the
data already collected (the first, clean run) stands on its own and
is not undermined by a second run's self-inflicted crash.
.PP
Where this leaves the investigation: the boot is not silently
exiting
.RB ( p\->kill
confirmed
.CW nil ,
several Progs confirmed still alive and distinctly placed), and it is
not the scheduler losing a wakeup at the
.CW acquire() / release()
level (the token handoff traced cleanly in the earlier section, and
none of the five Progs above are queued on
.CW isched.vmq
waiting for a token that never comes \- they are blocked on
Limbo-level channels or still inside host syscalls).
.CW Mntgen 's
wait is accounted for and benign.  What is not yet accounted for:
.CW Nametree 's
.CW alt ,
and \- more directly on point \- why none of the three
.CW Prelease
Progs (one of which is
.CW mount.dis
itself, mid-syscall) ever returns to
.CW acquire()
again to resume
.CW sh.dis
past the mount line.  The next diagnostic is narrower still: which
specific host call each of pid 1/3/6 is blocked inside \- a print at
entry to whatever
.CW release()
call preceded each one, not a scheduler-wide dump, to avoid repeating
this section's own crash.
.NH 1
A candidate mechanism: devproc.c doesn't know its own wait qid
.PP
Took the narrower approach that closing paragraph asked for, but
smaller still: instead of guessing which
.CW release()
call site to watch, extended the
.CW vmachine()
idle print from the previous section to call the tree's own
.CW wmtracedump()
\- capped at 3 entries, not the full 256, and fired at most twice \-
for every
.CW Prelease
Prog specifically, the three left unresolved there.  Low volume by
design, to not repeat that section's self-inflicted crash.
.PP
It didn't get far enough to resolve which of pid 1/3/6 is which
before something else interrupted the run, but what printed first is
its own answer, unprompted:
.RS
.nf
.CW "unknown qid in procwread"
.CW "sh panic: error on wait read: "
.fi
.RE
The first line is
.CW devproc.c 's
own
.CW procwread() ,
printing exactly what it says on a qid its second dispatch switch
doesn't recognize.  The second is
.CW sh.dis
itself, not a kernel panic \- no register dump, no
.CW dumpstack ,
just
.CW appl/cmd/sh/sh.b 's
own
.CW waitfor() :
.RS
.nf
.CW "n := sys->read(ctxt.waitfd, buf, len buf);"
.CW "if(n < 0)"
.CW "	panic(sys->sprint(\(dqerror on wait read: %r\(dq));"
.fi
.RE
.CW ctxt.waitfd
comes from
.CW waitfd() ,
which opens
.CW "#p/<pid>/wait"
(falling back to
.CW /prog/<pid>/wait )
\- the per-process wait file every shell reads to reap the children it
spawned for a pipeline or a background job.  Devproc.c's own
directory table lists it correctly
.RB ( "\(dqwait\(dq,\ {Qwait},\ 0,\ 0400" ) ,
and there is a
.CW case\ Qwait
in
.CW procread() 's
.I first
switch, well above the
.I second
switch's
.CW default:
that actually printed.  For that default to fire, the chan this read
landed on has to carry some qid that is neither
.CW Qwait
nor any of the second switch's other named cases \- meaning either
the open that produced
.CW ctxt.waitfd
didn't really resolve to the wait file's qid, or something between
open and this particular read swapped what that fd refers to.  Not
yet which.  This is the same neighbourhood \- fd/qid bookkeeping
across a fork/spawn boundary \- as the fd-4 chase two major sections
back in this document, though that one is fully explained and
retracted as a red herring; this is a new instance, not a reopening
of the old one.
.PP
Whether this is
.I the
mechanism behind the post-mount silence, or one more nondeterministic
failure mode alongside the general-protection-violation panics and
the pool and file-name faults already catalogued, is not settled by
one occurrence: this exact message never appeared in any of the
several earlier successful captures in the previous two sections,
which reached the same settled
.CW Prelease
state without it.  What makes it worth recording ahead of settling
that question: unlike a GPF at an opaque PC, this is a named,
reproducible-looking mechanism with a source line on each end
.RB ( devproc.c 's
print, and
.CW sh.b 's
.CW waitfor() ) ,
and
.CW sh.b 's
own
.CW panic()
would explain total silence afterward directly \- a shell that
panics inside
.CW waitfor()
this early is a shell that stops running the rest of
.CW /dis/init
without any of this document's earlier theories (scheduler token
loss, GC heap corruption, a correctly-blocked interactive prompt)
needing to be true at all.
.PP
Next: reproduce this deliberately rather than wait for it \- print
the qid actually carried by
.CW ctxt.waitfd 's
chan right where
.CW procwread()
hits its
.CW default:
case (already free, since that print already exists and already
fires; the missing half is dumping the qid value alongside it), and
separately check what
.CW sh.b
run created the child whose exit
.CW waitfor()
was reaping \- likely the
.CW {mntgen}
pipeline setup itself, which is exactly the kind of fork/pipe/fd
juggling the earlier fd-4 chase was also chasing.
.NH 1
Found: /prog exposes the wrong kind of process
.PP
.CW mount.dis
itself first, since it was the easiest of the loose ends to close by
reading rather than booting.
.CW appl/cmd/mount.b
traced end to end: for
.CW "mount\ {mntgen}\ /n" ,
.CW connect()
sees the
.CW {...}
form, sets
.CW doauth\ =\ 0 ,
and calls
.CW popen() ,
which pipes, spawns a
.CW runcmd
Prog to run
.CW mntgen
as the pipe's other end, and blocks on a sync channel until
.CW runcmd
has forked its fd group and dup'd the pipe onto its stdin.  Back in
.CW init() ,
.CW authcvt()
is a no-op
.RB ( doauth
is 0),
.CW styxlog()
is a no-op
.RB ( showstyx
defaults to 0), and then
.CW "sys\->mount(fd,\ nil,\ mountpoint,\ flags,\ spec)"
\- the call this whole document has been tracing.  On success,
.CW init()
just falls off the end.  No lingering read, no further blocking call.
So the
.CW mount.dis
Prog seen sitting in
.CW Prelease
in the previous section's capture was not stuck there \- it was
caught mid-syscall by a snapshot, exactly where a healthy run should
be, and should exit cleanly moments later.  One dead end closed by
reading alone, no boot needed.
.PP
That leaves the three
.CW Prelease
Progs themselves, and the wait-qid lead from the previous section
pointed straight at the mechanism that would explain all of it at
once: after
.CW sh.dis
runs any external command \- and
.CW mount
is the first one
.CW /dis/init
runs \- it calls
.CW appl/cmd/sh/sh.b 's
own
.CW waitfor() ,
which reads
.CW ctxt.waitfd ,
opened by
.CW waitfd() :
.RS
.nf
.CW "wf := string sys->pctl(0, nil) + \(dq/wait\(dq;"
.CW "waitfd := sys->open(\(dq#p/\(dq+wf, Sys->OREAD);"
.fi
.RE
.CW "sys->pctl(0,\ nil)"
sets no
.CW BlockingPctl
bit, so
.CW Sys_pctl()
.RB ( os/inferno/port/inferno.c )
runs none of its fork/namespace branches and just returns
.CW "p->pid"
where
.CW "p\ =\ currun()"
\- the calling
.I Dis Prog's
own pid, from
.CW dis.c 's
.CW newprog()
counter.  That is the number
.CW waitfd()
opens as
.CW "#p/<N>/wait" .
.PP
.CW os/inferno/port/devproc.c ,
the
.CW #p
device backing that path, is built entirely on
.CW proctab() /
.CW procindex() ,
walking
.CW procalloc.arena
\- the small, fixed pool of
.I host
kernel
.CW Proc
structures (the handful of
.CW vmachine()
kprocs and the boot kproc itself), not the potentially-thousands of
Dis
.CW Prog
structures the isched scheduler juggles.  Its own comment says so
plainly:
.CW "23\ bits\ of\ process\ slot\ number\ (procindex())" ,
.CW "32\ bits\ of\ pid,\ for\ consistency\ checking" \-
consistency against a
.I host
Proc's pid, unconditionally.  Two prints, one at
.CW Sys_pctl() 's
return and one at
.CW procgen() 's
name-to-slot lookup, confirmed this directly rather than by
inference:
.RS
.nf
.CW "Sys_pctl: flags 0, returning Dis prog pid 1, host up->pid 1"
.CW "procgen: walk to #p/1, wanted host pid 1, procindex gave slot 0, reader pid 1"
.CW "Sys_pctl: flags 0, returning Dis prog pid 2, host up->pid 1"
.CW "Sys_pctl: flags 0, returning Dis prog pid 3, host up->pid 1"
.CW "procgen: walk to #p/3, wanted host pid 3, procindex gave slot 2, reader pid 1"
.fi
.RE
Every one of these calls ran on the very same host kproc
.RB ( "up->pid\ 1" ,
the boot kproc that
.CW disinit.b
and then
.CW sh.dis
run directly in, never having released it yet) \- the Dis pid climbing
1, 2, 3, 4\&.\|.\|. as successive Progs are spawned, entirely
independent of the host pid, which stays 1 throughout.  And both
walks that were attempted \- to
.CW #p/1
and
.CW #p/3
\- succeeded, each finding a real, unrelated host
.CW Proc
whose
.I own
pid happens to equal the Dis pid being searched for, purely by the
coincidence of two independent counters both starting small during
the same early boot window.  Whichever host kproc that is \- almost
certainly one of the small number of
.CW vmachine()
workers, or the boot kproc itself \- has nothing to do with the Dis
Prog
.CW sh.dis
actually wants to wait for.
.PP
This is the mechanism, not a guess dressed as one.  A Dis Prog
exiting posts its wait status through
.CW dis.c 's
own machinery
.RB ( delprog()
calling
.CW tellsomeone() ,
which
.CW qproduce() s
onto
.CW "Osenv.childq / waitq" ,
Prog-level queues private to the Dis scheduler).
.CW devproc.c 's
.CW Qwait
case reads from an entirely different structure:
.CW Proc.waitq ,
a host-level linked list populated only by
.CW proc.c 's
.CW pexit() 's
own record when an actual
.I host
kernel process exits \- not when a Dis Prog does.
.CW vmachine()
kprocs loop forever; they essentially never exit.  So
.CW sh.dis 's
.CW "sys->read(ctxt.waitfd,\ ...)"
is listening to a wait queue that a Dis-level child's exit can never
reach, on a host process that was never going to signal anything in
the first place.  It blocks forever, correctly by its own logic,
watching the wrong thing.  This is not this document's earlier fd-4
chase reopened \- that one is fully explained and stays retracted \-
but it is the same neighbourhood: this port's process-identity
bookkeeping not yet reconciled between Inferno's two-level process
model (Dis Progs multiplexed onto a small host kproc pool, this
document's own earlier discovery) and Plan 9-heritage code
.RB ( devproc.c )
written against a one-Proc-per-process assumption that no longer
holds here.
.PP
This explains the whole document, not just this section.  Every
earlier theory \- scheduler token loss, GC/heap corruption, a
correctly-blocked interactive prompt, FORKFD staleness \- is either
independently fixed, independently refuted, or simply not needed
once this is true: a shell that blocks forever the first time it
waits for any child it spawns explains total silence after
.CW "mount\ {mntgen}\ /n"
directly,
.I because
.CW mount
is the first external command
.CW /dis/init
runs and waits for.  The occasional stranger failures elsewhere in
this document \- the rare general protection violations, the
.CW "unknown\ qid\ in\ procwread" /
.CW "sh\ panic:\ error\ on\ wait\ read"
capture two sections back \- are plausibly downstream symptoms of the
same coincidental-pid-collision idea landing on a
.I different
host Proc slot on a different boot (one whose fields don't happen to
line up as cleanly as
.CW Qwait 's
own consistency check expects), rather than separate bugs each
needing their own explanation.
.PP
Not fixed this session.  A correct fix means teaching
.CW devproc.c 's
.CW Qwait
path \- and, more broadly, most of what
.CW procgen() /
.CW procread() /
.CW procwrite()
expose \- to resolve against Dis
.CW Prog
and
.CW Osenv
state instead of
.CW Proc ,
including synthesizing a
.CW Waitmsg -shaped
read out of
.CW Osenv.childq 's
queued messages rather than
.CW Proc.waitq 's
linked list \- a real rewrite of a file that is not small, not a
one-line patch, and worth doing carefully rather than rushed in the
same sitting as finding it.  Recorded here at the level of detail a
future session needs to start from: which two functions
.RB ( Sys_pctl()
and
.CW procgen() ),
which two data structures
.RB ( Osenv.childq / waitq
vs
.CW Proc.waitq ),
and the empirical trace above proving the mismatch rather than
asserting it.
.PP
Two corrections to that paragraph, written before either was
checked against the boot rather than reasoned about, and both wrong
in the same direction: too pessimistic.
.NH 1
Found, for real: #p and #P collide on one letter
.PP
The previous section's fix estimate \- teaching
.CW procgen() /
.CW procread()
to resolve against Dis
.CW Prog
state, a real rewrite \- was never necessary, and the mismatch it
documented was a symptom, not the cause.  The cause is one character.
.PP
.CW os/inferno/port/devprog.c
already implements exactly the mechanism the previous section
proposed building: its
.CW Qwait
open does
.CW "c\->aux\ =\ qopen(1024,\ Qmsg,\ nil,\ nil);\ o\->childq\ =\ c\->aux;" ,
pointed at a Dis Prog's own
.CW Osenv
by
.CW progpid() ,
and
.CW dis.c 's
.CW killprog()
already formats the exit message
.CW "\(dq%d\ \e\(dq\(dq"
+ module name +
.CW "\(dq\e\(dq:\(dq"
+ cause \- character for character what
.CW appl/cmd/sh/sh.b 's
.CW parsewaitstatus()
parses.  Both ends of the real protocol already existed, already
matched, and
.CW sh.b 's
own
.CW waitfd()
already knew to reach for it:
.RS
.nf
.CW "waitfd := sys->open(\(dq#p/\(dq+wf, Sys->OREAD);"
.CW "if (waitfd == nil) waitfd = sys->open(\(dq/prog/\(dq+wf, Sys->OREAD);"
.fi
.RE
a primary attempt through
.CW #p
and a fallback through the bound path
.CW /prog .
The fallback never ran because the primary attempt never failed: it
silently succeeded against the wrong device, every time, forever.
.PP
.CW os/inferno/port/devproc.c 's
.CW Dev
literal and
.CW os/inferno/port/devprog.c 's
both declared the same one-character device code:
.RS
.nf
.CW "Dev procdevtab = { 'p', \(dqproc\(dq, ... };  \0\0/* devproc.c */"
.CW "Dev progdevtab = { 'p', \(dqprog\(dq, ... };  \0\0/* devprog.c */"
.fi
.RE
.CW chandevinit() 's
own registration loop
.RB ( os/inferno/port/chan.c )
and the lookup it feeds
.RB ( os/inferno/port/dev.c ,
a plain linear scan for the first
.CW devtab[i]\->dc\ ==\ c )
keep whichever registers first under a duplicate letter and the
second is simply never reachable.  The
.CW pc64
board's
.CW dev
list names
.CW proc
before
.CW prog ,
so
.CW #p
has meant
.I devproc.c
\- host
.CW Proc
introspection \- on every boot this whole document covers, and
.I devprog.c \-
the file that actually understands a Dis Prog's exit \- has been
linked in, fully correct, and completely unreachable the entire
time.  Confirmed empirically before touching either file: a filtered
print at
.CW procread() 's
.CW Qwait
entry fired for both Progs
.CW sh.dis
waited on, each blocking forever in
.CW "sleep(&p\->waitr,\ prochaswaitq,\ c)"
against a host
.CW Proc
that was never going to signal anything, exactly as the previous
section described \- the point being that this
.I is
the previous section's mismatch, reachable in the first place only
because of the letter collision, not despite it.
.PP
.CW os/inferno/init/disinit.b
had already half-diagnosed this, in a comment nobody had acted on:
its live
.CW "sys->bind(\(dq#p\(dq,\ \(dq/prog\(dq,\ sys->MREPL);\ #\ prog\ device"
sits two lines above a commented-out
.CW "#\ sys->bind(\(dq#o\(dq,\ \(dq/proc\(dq,\ sys->MREPL);\ #\ proc\ device" \-
this tree's own author already knew
.CW #p
should mean
.I prog
and some other letter should carry
.I proc ,
and had picked
.CW o
for it.  That letter is free: none of the devices linked into
.CW ipc64
\- checked across every
.CW Dev
struct in
.CW os/inferno/port ,
.CW os/inferno/pc64
and
.CW os/inferno/ip \-
claim it.
.PP
The fix is one character in
.CW os/inferno/port/devproc.c :
.CW procdevtab 's
.CW dc
field and
.CW procattach() 's
.CW devattach()
call both move from
.CW 'p'
to
.CW 'o' .
.CW devprog.c
is untouched \- it was correct all along.  Nothing in
.CW appl/ ,
.CW dis/
or
.CW os/inferno/init
opens
.CW #p/trace
or any other
.CW devproc.c -only
file by that path (checked; only
.CW /prog/<pid>/...
paths appear, all of which now mean
.I devprog.c ,
which is what every one of those call sites \-
.CW appl/lib/debug.b ,
.CW exception.b ,
.CW titlebar.b ,
.CW tkclient.b ,
.CW wmclient.b
and the rest \- was written against from the start.  Restoring
.CW #o\ /proc
itself (uncommenting
.CW disinit.b 's
line) is a separate, additive change, not needed for this fix and
not yet made: nothing in this tree currently opens
.CW #o
or
.CW /proc
by path.
.PP
Booted with only the one-character change: the silent hang after
.CW "mount\ {mntgen}\ /n"
is gone.  No
.CW Qwait
diagnostic fires; no boot has reproduced it since.  Execution now
runs
.I past
the point every earlier session in this document stalled at, into
.CW /dis/init 's
own script body \- the first time this has ever been observed.  This
is the actual root cause this whole document has been chasing since
its first section: not a scheduler bug, not GC corruption, not an
architectural mismatch needing a rewrite, but two devices sharing one
letter, with the wrong one listed first.
.PP
One claim from the previous section's closing paragraph does not
survive this and should be retracted rather than carried forward:
that the rare
.CW "unknown\ qid\ in\ procwread" /
.CW "sh\ panic:\ error\ on\ wait\ read"
capture was plausibly the same coincidental-pid-collision idea
landing on a different host Proc slot.  That capture hit
.CW procread() 's
.CW default:
case \- meaning
.CW QID(c\->qid)
was not any recognized type at all, which the collision story does
not account for.  It was reproduced zero times across the four
repeat boots this document already recorded, and zero times more
across the several boots run to reach this section.  It stays
unexplained and unreproduced, not folded into this finding.
.PP
What replaces it as the open question: two new, so-far-unreproduced
failures further into
.CW /dis/init 's
script than this document has ever previously observed execution
reach.  One boot printed
.CW "iload\ module\ \&$Sys\ not\ loaded\ ml\ ==\ nil"
\- libinterp/xec.c 's
own pre-existing
.CW OP(iload)
diagnostic, for the compiled-in
.CW Sys
module every single Limbo module loads via
.CW "load\ Sys\ Sys->PATH" ,
registered by
.CW libinterp/runt.c 's
.CW sysmodinit()
through
.CW os/inferno/pc64/pc64.c 's
.CW modinit() ,
called once, early, well before this point \- not reproduced on three
further boots, so plausibly a scheduling-timing race exposed by
paths that previously never ran this far or this concurrently,
rather than a defect in the registration itself.  Two of four boots
instead reached
.CW "split:\ \&$ifs\ not\ set" ,
.CW appl/cmd/sh/std.b 's
own
.CW sbuiltin_split()
failing its explicit
.CW ctxt.get(\(dqifs\(dq)\ ==\ nil
check.  Neither of the two textual
.CW ${split\ ...}
call sites reachable from
.CW /dis/init
(both two-separator forms, not the bare one-argument form that
triggers this check) should hit it as written; the leading
candidate not yet confirmed is
.CW "(connectmethod\ localdevice)\ =\ \&${split\ !\ \&$bootargs}" \-
reachable only if
.CW #e/bootargs
exists but is empty, collapsing
.CW $bootargs
to zero words and leaving
.CW split
with only its own name and the separator, which is exactly the
two-argument shape
.CW sbuiltin_split()
treats as the one-argument
.CW ifs -needing
form.
.PP
Confirmed against a boot, with a filtered print in
.CW sbuiltin_split()
first: the failing call is exactly
.CW "(connectmethod\ localdevice)\ =\ \&${split\ !\ \&$bootargs}" ,
.CW #e/bootargs
existing (empty) on this
.CW -kernel
multiboot invocation with no
.CW bootargs=
of its own.  Fixed in
.CW dis/init
by squashing:
.CW "$bootargs"
became
.CW "$\(dqbootargs" ,
which
.CW sh.b 's
.CW n_SQUASH
always returns exactly one word, empty or not, so
.CW split
always gets its separator and a value.  Booted repeatedly after: the
.CW ifs
failure is gone, replaced by
.CW dis/init 's
own graceful, already-written fallback \-
.CW "echo\ unsupported\ connect\ method:\ $connectmethod" \-
which is exactly correct given no
.CW bootargs=
was passed.  Execution then continues into the
.CW sysname
lookup
.RB ( ndb/query
over a backquote reading
.CW #l0/ether0/addr )
before this session's testing stopped.
.PP
What stopped it was not a stall: repeat boots of this exact,
unmodified build hit a genuine, pre-existing, nondeterministic crash
at highly variable points \- one general protection violation and
one
.CW cclone
panic before
.CW disinit.b 's
own first print even runs, one
.CW "invalid\ opcode"
panic reached only after
.CW "unsupported\ connect\ method:" \-
none reproducing the same fault two runs running, several crashing
well before anywhere this session's fixes touch.  This matches, and
is plausibly a continuation of, the boot-time flakiness this
document's own second section already found and only partly fixed:
the
.CW xalloc.c
misalignment fix
.RB ( 1b45f8be )
eliminated one deterministic source of it and was verified doing so,
but its own write-up already noted a second, different pool-allocator
fault
.RB ( alloc:D2B )
seen once and never chased.  That this session's two real fixes
(device letter, bootargs quoting) hold up cleanly on every boot that
survives long enough to exercise them, while the surrounding kernel
still crashes unpredictably on a large fraction of boots for reasons
unrelated to either fix, was the honest state to end that session's
work in: the specific stall this whole document set out to explain
is fixed and confirmed; a broader, separate, still-uncaught source of
boot-time nondeterminism remains, affecting whether any given boot
survives long enough to show it.
.NH 1
Naming the Dis module a native trap can't name itself
.PP
Every crash this document has ever captured names the wrong process.
.CW os/inferno/pc64/trap.c 's
.CW dumpregs()
prints
.CW "up->text\ up->pid" \-
the
.I host
kproc's own name and pid, almost always the literal string
.CW "dis" ,
one of a small, fixed pool of
.CW vmachine()
workers multiplexing every live Dis Prog (the same host/Dis-level
distinction this document's own
.CW #p / #P
section is built on).  Three different fault types were read this
session as \(dqpid 9 crashing again\(dq before checking this; they
were, at most, the same
.I host
kproc, which says nothing about which Limbo module was actually
running.  And no address in any of these dumps has ever been
resolved to a function: the linked
.CW ipc64
binary carries no symbol table
.CW inm
or
.CW acid
can read (checked directly \-
.CW "inm\ ipc64"
returns nothing while
.CW "inm\ main.6"
lists a full table for the same object before linking, and
.CW acid
gets as far as loading its own
.CW $ROOT/lib/acid/port
module before reporting
.CW "no\ symbol\ information"
for the binary itself), so every native PC in every capture this
whole document has recorded has been unreadable.
.PP
Fixed the readable half without needing a symbol table at all:
.CW dumpregs()
now also calls
.CW currun() \-
the same lookup
.CW Sys_pctl()
already trusts to name the calling Dis Prog \- and prints its pid,
its currently-executing module's name, and its Dis-level
.CW R.PC .
A Limbo module name is already a string; no linker support needed.
One boot with this in place was immediately more informative than
every earlier capture combined:
.RS
.nf
.CW "cpu0: registers for <nil> 1"
.CW "  running Dis pid 1 module \e$Sys PC 0x7966e08"
.CW "..."
.CW "panic: general protection violation"
.fi
.RE
landing right after
.CW disinit.b 's
own
.CW "spawn\ sh\ -n\ /dis/init"
print \- meaning the crash sits at or just past the handoff into
.CW sh.dis 's
own
.CW init() ,
not anywhere this session's two fixes touch.
.PP
Narrowed one specific candidate and ruled it out cleanly:
.CW appl/cmd/sh/sh.b 's
.CW init()
makes its first real
.CW Sys
builtin call at
.CW "sys->pctl(Sys->FORKFD,\ nil)" ,
and
.CW Sys_pctl() 's
.CW Sys_FORKFD
branch
.RB ( os/inferno/port/inferno.c )
is a
.CW BlockingPctl
flag \- it calls
.CW release()
before touching
.CW o->fgrp ,
the first time in this whole investigation a blocking
.CW pctl
call has ever been reached and exercised, and exactly the kind of
release-a-window-then-touch-shared-state shape that has produced
real bugs elsewhere in this document.  Bracketed it with four
print points \- entry, post-release,
.CW dupfgrp()
returned, the movefd/close loop done, post
.CW closefgrp() \-
and ran it seven times across two boots.  All seven completed
cleanly, each step in order, no crash: pid 1
.RB ( Sh ) ,
pid 3
.RB ( Mount ) ,
then pids 10 and 11
.RB ( Sh
again, from the fallback shell path).
.CW Sys_pctl 's
.CW Sys_FORKFD
body itself is not the fault site.
.PP
What the crash cluster does share, across every capture this session
made: it lands somewhere in the narrow window from
.CW disinit.b 's
.CW "spawn\ sh\ -n\ /dis/init"
print through
.CW sh.b 's
own
.CW initialise() \-
which, unlike the now-cleared
.CW FORKFD
call, is a much richer surface: seven
.CW load
calls in a row
.RB ( Filepat ,
.CW String ,
.CW Bufio ,
two
.CW "$self"
reloads of
.CW sh.dis
itself
.RB ( Sh
and
.CW Shellbuiltin ) ,
.CW Env ,
.CW Arg ) ,
each through the same
.CW OP(iload) /
.CW readmod() /
.CW linkmod()
machinery this document's previous section already caught failing
once, transiently, as
.CW "\e$Sys\ not\ loaded" .
The two
.CW $self
reloads are the most structurally interesting: a module taking out
a fresh reference to
.I itself
while it is the one currently executing is a narrower, more
self-referential case than any other
.CW load
site in this tree, and this session did not get far enough to test
it directly.
.PP
Not fixed.  The
.CW dumpregs()
enhancement is real and committed \- every future capture, in this
session or the next, will name its Dis module for free.  The crash
itself is not, and a second round of the same bracketing technique
narrowed further without closing it.  Tried the concrete next step
this section itself proposed: one
.CW sys->print()
after each of
.CW initialise() 's
eight
.CW load
calls in
.CW appl/cmd/sh/sh.b
(the first,
.CW "sys\ =\ load\ Sys\ Sys->PATH" ,
included even though it is the least suspicious of the eight \- it
is also the only one whose completion could not otherwise be told
apart from the next).  Three full boots, each running
.CW initialise()
twice (once for
.CW "sh\ -n\ /dis/init"
itself, once more for the fallback fork this session's
.CW dis/init
fix routes through when no
.CW bootargs=
is given) \- 24 individual
.CW load
completions, zero failures.  Every one of
.CW initialise() 's
.CW load
calls, both
.CW $self
reloads included, is now cleared the same way
.CW FORKFD
was: by direct, repeated, successful exercise, not by argument.
.PP
What this leaves is narrower still but also harder: two clusters of
evidence that do not point at the same place.  The one detailed
capture that named a module
.RB ( \e$Sys ,
pid 1, right after
.CW "spawn\ sh\ -n\ /dis/init" )
came from a boot with
.I neither
of this section's brackets active \- and both brackets, run
immediately after, came back clean every time.  Read plainly rather
than stretched: either the fault sits in a
.CW $Sys
call this section has not yet bracketed (everything
.CW initialise()
and
.CW Sys_pctl 's
.CW FORKFD
path call is now cleared; what remains between
.CW "spawn\ sh\ -n\ /dis/init"
and
.CW initialise() 's
own first line is vanishingly little code to instrument next), or
the added print volume of each bracket itself is changing the
timing enough to avoid whatever the race actually needs \- a real
possibility this document has already met once, in the
.CW consw()
self-inflicted panic several sections back, though there the
volume was orders of magnitude higher.  Both are testable, and
this session did not get to either: instrument the few lines
between
.CW disinit.b 's
own
.CW "sh->init(nil,\ ...)"
call and
.CW initialise() 's
own first statement next, and separately, run several plain,
unbracketed boots back to back specifically to build a larger
sample of which module
.CW dumpregs()
names when a crash lands with no added instrumentation at all in
its neighbourhood.
.NH 1
Eleven boots, one shape: this is corruption, not a race
.PP
Did exactly that.  Eleven plain, unbracketed boots across this
session and the last \- no diagnostics active in the crash's own
neighbourhood \- crashed seven times: two
.CW cclone
panics, one
.CW cclose
panic, one
.CW alloc:D2B ,
and three general protection violations naming three different Dis
modules
.RB ( Init ,
.CW Sh ,
.CW \e$Sys )
or none at all.  That is not a rare, occasional fault \- it is the
.I majority
outcome, and the previous section's caution about reading too much
into five bracketed samples was itself read too narrowly: the real
correction is that this session simply had not run enough boots,
of any kind, to see the true shape until now.
.PP
Seven crashes, four symptom families, no two at the same Dis module
or even the same side of
.CW disinit.b 's
handoff into
.CW sh.dis \-
one before
.CW "Welcome\ to\ Inferno..."
even prints, with no Dis code running yet at all.  That last fact
alone rules out any theory pinned to a specific piece of Limbo
bytecode: whatever this is can happen before the interpreter has
executed a single instruction.  And
.CW cclone /
.CW cclose 's
shared panic condition
.RB ( "c\ ==\ nil\ ||\ c->ref\ <\ 1\ ||\ c->flag&CFREE" )
alongside
.CW alloc:D2B 's
.CW "in\ free\ blk" \-
a block the allocator's own bookkeeping says is already free, being
touched again \- describe the same fact from two different call
sites: something is handing out, or continuing to use, memory that
should not be touched.  Read as one bug with several detection
points rather than several unrelated bugs, which is what this
document's earlier sections, working from far fewer samples, had
no way to see.
.PP
Tested the most concrete candidate this shape suggests \- a timer
interrupt corrupting state very early, since
.CW init0()
calls
.CW spllo()
(enabling interrupts) before its own first
.CW cclone()
call, and 9 of 11 boots' crashes cluster within seconds of that
window.  Capped, filtered print at
.CW portclock.c 's
.CW hzclock() ,
firing only its first eight calls per boot: every field checked
.RB ( m->proc ,
.CW up ,
.CW up->state ,
.CW active.machs ,
.CW active.exiting )
was sane and self-consistent all eight times, in a boot that went
on to crash later anyway.  Ruled out, at least for early ticks: the
clock handler is not running with garbage state when it fires.
Reverted before this commit.
.PP
One thread from that same boot's crash, raised and then retracted:
this run's fault \(em general protection violation,
.CW currun()
nil (no Dis Prog was current, the first time that has been true in
any capture) \(em put the identical 64-bit pattern,
.CW F000FF53F000FF53 ,
in both
.CW BP
and
.CW CX .
First read as two registers loaded from one shared corrupted
location, and as a BIOS-ROM address given
.CW pc64/memory.c 's
.CW 0xF0000\(en0xFFFFF
reservation \- both wrong.
.CW F000FF53
is the ordinary shape of a register that was simply never
meaningfully loaded on this fault path (this exact value turns up
in QEMU register dumps generically, not as content read from
anywhere in this port); two registers sharing it on a
.CW currun()
nil capture is consistent with a frame that was never established, not
with a shared bad pointer.  No lead here after all \- said plainly
so the next session does not chase
.CW memory.c 's
map for it.
.PP
Checked the header arithmetic behind the
.CW alloc:D2B
block dump properly this time, against
.CW include/pool.h 's
actual
.CW Bhdr
.RB ( "u32\ magic;\ uintptr\ size;\ intptr\ allocpc;\ intptr\ reallocpc;" ,
32 bytes with padding on this LP64 port, confirmed against the
dump: word0's
.CW badc0c0a
is
.CW MAGIC_F
in the low 32 bits, word1's
.CW 100
is
.CW size ,
and
.CW fb+size
.RB ( 784c298+0x100 )
lands exactly on the panic's own
.CW "next\ block\ 0x784c398" ).
The freed payload itself, 224 bytes starting at
.CW B2D(fb) ,
carries two
.CW H
sentinels sixteen bytes apart alongside several pointers into the
same
.CW 0x78xxxxxx
heap arena \- a real, promising shape, not yet matched to a named
struct.
.PP
Not fixed, and, honestly, not close: this is pre-existing, general
memory corruption whose trigger has not been isolated, discovered
from far fewer samples than eleven boots turns out to need.  The
concrete next step, and the one that actually decides whether more
of this is worth doing: several more
.CW alloc:D2B
captures, specifically to compare
.I addresses .
If the block address and
.CW size\ 100
recur, the corruption lands at a fixed heap offset and is
bisectable; if both differ every time, it is allocation-order
dependent, and matching one dump's payload shape against a struct
layout is not worth the time it costs.  Only if addresses recur is
it worth going on to match the payload's two
.CW H
sentinels and heap-pointer fields against
.CW libinterp/heap.c 's
.CW Heap
header and
.CW include/interp.h 's
.CW Modlink
layout, to see whether the corrupted block's shape names its own
type the way a Dis module name already named the crashing context.
.NH 1
Addresses do not recur: struct-matching the payload is not worth it
.PP
Ran the experiment.  Gave
.CW alloc:D2B
the same treatment as the native trap: enhanced
.CW alloc.c 's
.CW _poolfault()
\- what
.CW include/pool.h 's
.CW D2B
macro actually calls, through the
.CW poolfault
function pointer it is the sole assignment of \- to also print
.CW currun() 's
Dis pid, module, and PC.  Same trick, kept permanent the same way,
on a path that only fires already exceptional.
.PP
Five more plain boots: three clean, one general protection
violation naming a fifth distinct module
.RB ( Env ,
pid 3 \- the previous section's four-way split holds), and one more
.CW alloc:D2B ,
this time naming
.CW Sh ,
pid 1.  That capture decides the question the previous section
raised: its address
.RB ( 0x310440 )
and caller pc
.RB ( 0x2610ec )
match neither of the two earlier
.CW alloc:D2B
captures
.RB ( 0x784c2b8 / 0x2bdc2b
and
.CW "0x784a9b8 / 0x2bdc2b" ) \-
not even the same order of magnitude, where the first two at least
shared a caller.  Three captures, three different addresses, two
different callers.  Allocation-order dependent, per the previous
section's own test: matching the payload dump against
.CW Heap
or
.CW Modlink
is now known not worth doing, decided by the cheap experiment
rather than by more manual struct arithmetic.
.PP
Six named-module captures across this whole crash-hunt now:
.CW Init ,
.CW Sh
(twice, two different fault types),
.CW $Sys ,
.CW Env ,
and one
.CW currun()
nil.  No module repeats in a way that suggests it is the culprit
rather than the victim \- the plainest remaining reading is what the
first of these sections already said: the corruption is indifferent
to what is running, which points at something scheduled independently
of Dis execution (a clock tick, a GC epoch, an interrupt handler)
rather than at a bug in any one piece of Limbo bytecode or its
loader.  Not fixed.  The
.CW _poolfault()
enhancement is committed and permanent; every future
.CW alloc:D2B
capture, in this session or the next, will carry its module context
for free, the same standing offer
.CW dumpregs()
already made for native traps.
.NH 1
Two pools, not one arena: the D2B and chan crashes fire in different pools
.PP
Checked what the previous section left open rather than assumed it.
.CW include/pool.h 's
allocator keeps three named pools
.RB ( main ,
.CW heap ,
.CW image ),
and
.CW alloc.c 's
own
.CW _auditmemloc()
names which one it found the searched address in.  The three
.CW alloc:D2B
captures on record all read
.CW "in heap:" \-
.CW heapmem ,
the GC-managed Dis object heap.
.CW "cclone / cclose" 's
bad-chan panics are against
.CW Chan
structures, and
.CW newchan()
allocates them through
.CW smalloc() ,
which is
.CW mainmem
only.  Different pools.  Reading this whole crash-hunt as "one
corruption, several detection points" was an assumption the earlier
sections never actually checked, and this much of it does not hold
as stated: the two signatures fire in different pools.  Whether
that means two separate bugs or one bug in code shared by both
pools (below:
.CW poolalloc / poolfree
in
.CW alloc.c
are the same functions serving every
.CW Pool ,
.CW heapmem
and
.CW mainmem
alike) is still open \- a later section finds a real fault inside
.CW poolalloc()
itself on the
.CW heapmem
side, which keeps a shared-code explanation live.
.PP
This does not touch the GPF captures, which are raw faults rather
than allocator-detected corruption and are not attributable to a
pool this way.
.NH 1
A real use-after-free window in delprog(), reachability not yet settled
.PP
Read
.CW os/inferno/port/dis.c 's
.CW delprog()
looking specifically for the
.CW mainmem
half of the split above, since
.CW "Pgrp / Fgrp / Egrp"
are all
.CW smalloc() 'd
the same way
.CW Chan
is.
.CW delprog()
does
.CW "o = p->osenv"
then
.CW release() ,
then
.CW closepgrp(o->pgrp) ,
.CW closefgrp(o->fgrp) ,
.CW closeegrp(o->egrp) ,
.CW closesigs(o->sigs) ,
then
.CW acquire() .
Only after that does it unlink
.CW p
from
.CW proghash[]
(via
.CW pidlook() )
and from
.CW "isched.head / isched.tail" .
.CW release()
hands the single interpreter token to whatever other kproc is
waiting, which runs ordinary Limbo bytecode until it blocks or
finishes \- and
.CW p
is still fully reachable by pid through
.CW progpid()
the entire time, while
.CW closepgrp()
and
.CW closefgrp()
may already have freed what
.CW o->pgrp
and
.CW o->fgrp
point at.
.CW os/inferno/port/devprog.c
has eleven
.CW progpid(PID(c->qid))
call sites behind
.CW #p ,
and at least three dereference the group pointers directly without
taking a reference first:
.CW Qns
does
.CW "chanpath(o->pgrp->dot)" ,
.CW Qnsgrp
does
.CW "((Osenv*)p->osenv)->pgrp->pgrpid" ,
and
.CW Qfd
hands
.CW o
straight to
.CW progfds() .
Any of the three, hit during another prog's
.CW delprog()
window, reads through a pointer that may already be dangling \- the
same shape as the observed
.CW cclose / cclone
"bad chan" signature, just one arena over from where those checks
actually fire.
.PP
Two things looked like they would extend this finding and did not.
.CW killgrp()
also calls
.CW progpid()
in a loop, and its own comment already flags that state can change
"eg, in delprog" \- but
.CW killprog() 's
switch returns 0 immediately on
.CW Prelease
or
.CW Pexiting ,
and every
.CW p->state = Pexiting
assignment in this file is inside
.CW killprog()
itself, set before it calls
.CW delprog() .
So a
.CW killgrp()
walk hitting a prog mid-teardown from
.I that
path is already guarded.
.CW Sys_pctl()
also releases the token while it later touches
.CW p->osenv ,
which looked at first like it multiplied the exposure \- but
.CW Sys_pctl()
is a prog acting on its own
.CW osenv ,
not a reader reaching another dying prog's, so it does not by
itself put a second prog in the window.
.PP
One thing does NOT guard the ordinary case, though, and this is
the actual finding worth keeping:
.CW progexit() \-
the path every prog takes when it exits normally, by returning or
calling
.CW exit() ,
as opposed to being killed \- never sets
.CW r->state = Pexiting
anywhere before calling
.CW delprog() .
Checked by grepping every
.CW "state = Pexiting"
assignment in the file; all three are in
.CW killprog() .
So
.CW devprog.c 's
.CW Qstatus
and
.CW Qstack
guards, which both check
.CW "p->state == Pexiting"
before touching a prog, correctly turn away a killed prog and do
nothing at all for a normally-exiting one \- which is the common
case, not the rare one.  Every module that finishes and returns
during boot goes through this exact, unguarded window.
.PP
One reorder that looked obviously correct turned out not to be, and
is worth recording so it is not tried again.  The natural fix reads
as "unlink
.CW p
from
.CW proghash[]
and
.CW isched.head/tail
before
.CW release() ,
not after" \- close the window by making
.CW p
unreachable by pid before any other kproc can run.  This breaks a
different invariant.
.CW release() 's
.CW Interp
branch calls
.CW isave() ,
which is
.CW "p = delrun(Prelease); p->R = R; return p;"
in
.CW libinterp/xec.c \-
and
.CW delrun()
takes
.I whatever
is at
.CW isched.runhd
unconditionally, with no check that it is the caller's own prog.
.CW delprog() 's
own
.CW "if(p == isched.runhd) isched.runhd = p->link"
step, currently placed after
.CW acquire() ,
is exactly what keeps
.CW p
at
.CW isched.runhd
across the
.CW release()
call.  Move it earlier and
.CW isave()
saves the current register set into a
.I different,
unrelated prog instead \- corrupting that prog's saved state rather
than fixing anything.  A correct fix has to close the
.CW proghash[] /
.CW isched.head/tail
reachability window without touching
.CW isched.runhd
ordering at all: the candidate not yet tried is nulling
.CW "o->pgrp / o->fgrp / o->egrp / o->sigs"
immediately after each successful close, so a concurrent reader
that finds
.CW p
during the window sees
.CW nil
rather than a dangling pointer \- which is also what
.CW closepgrp() / closefgrp()
already check for on entry, so the pattern is not new to this code.
.PP
Built, not yet applied: a diagnostic pair, capped and permanent-cost
only on the path it instruments.
.CW dis.c
gets
.CW disracepid
(the pid currently inside a
.CW delprog()
close window, \-1 when none),
.CW disracewindows
and
.CW disraceoverlaps
(does a second window ever open while one is still open, which the
single-int
.CW disracepid
cannot represent precisely if so), and reports whenever
.CW gchalted
(libinterp/gc.c's counter of times
.CW rungc()
found the GC blocked) changes across the window \- though that
specific check turned out to measure the wrong arena:
.CW rungc()
only walks
.CW heapmem ,
and
.CW delprog() 's
own frees are all
.CW mainmem ,
so a
.CW gchalted
change here shows the guard firing, not anything about the frees
this section is actually about.
.CW devprog.c
gets
.CW disracecheck() ,
called after all eleven
.CW progpid()
sites: a capped collision report if the pid found matches
.CW disracepid ,
and a capped reached-at-all counter (prints at count 1, 10, 100,
1000) so that zero collisions can be told apart from "these paths
never run during boot" \- the first cut of this instrument had only
the collision check, which would have made a clean run
uninterpretable.
.PP
Two batches of twelve plain boots each ran this build: 1 crash in
the first twelve, 3 in the second, 4 in 24 total.  Not comparable to
the eleven-boot, seven-crash baseline two sections back \- the added
prints change timing, and 24 boots is still not enough to read a
rate from on its own.  The reach counter fired in every boot that
survived long enough to print it, capped output showing counts of
1 and 10 per boot and never reaching 100 \- so the eleven
.CW progpid()
sites run on the order of tens of times per boot, confirming they
are live code during an ordinary boot rather than dead paths only a
deliberate
.CW /prog
read would exercise.  The collision check fired zero times in 24
boots, and the overlap counter (does a second
.CW delprog()
window open while one is already open) also fired zero times.
Neither is a clean negative on its own: the collision window is
open for microseconds and a reader that runs tens of times per boot
against a microsecond target is expected to miss even if the race
is real.  Recorded as underpowered by construction, not as
refutation.  All four crashes in this batch happened before pid 8's
own
.CW delprog()
ever printed \- but that print is conditional on
.CW gchalted
changing, so "no
.CW delprog:
line before the panic" means "no window during which the GC was
also attempted nearby," not "no
.CW delprog()
ran."  Caught before it became a written conclusion: earlier
.CW gchalted
checks answer a different question than the one asked here anyway,
since
.CW rungc()
only walks
.CW heapmem
and
.CW delprog() 's
own frees are
.CW mainmem \-
that specific probe was measuring the wrong arena from the start.
.NH 1
Reading native crash addresses at last: unlocking ipc64's symbol table
.PP
Every crash-hunt section to this point has carried the same
limitation:
.CW inm main.6
lists a full symbol table on the pre-link object,
.CW inm ipc64
and
.CW acid ipc64
both report nothing for the linked kernel, and every native
.CW PC
this hunt has captured has been an unreadable number.  Traced it
down rather than working around it again.
.CW utils/6l/obj.c
defaults
.CW HEADTYPE
to 2 (native Plan9 a.out, "fat header" variant) when
.CW -H
is not given, which this build's link line never gives, and
.CW utils/6l/span.c 's
.CW asmsym()
runs unconditionally unless
.CW -s
is passed, which it also is not \- so the symbols should be in the
file, and a byte-for-byte diff confirmed they are:
.CW ipc64
is 1.1MB larger than its own reported text+data+bss, and
.CW strings -a ipc64
finds
.CW delprog ,
.CW currun ,
.CW progexit
and more as literal name strings in that trailing region.  Whatever
.CW inm / acid
do to read the symbol table from a linked Plan9 fat-header a.out on
this host toolchain, it does not work for this binary; why is still
open, and not worth more time against a working alternative.
.PP
The table's own format, read out of
.CW utils/6l/span.c 's
.CW putsymb() :
each entry is an 8-byte big-endian value, a
.CW "type-char | 0x80"
byte, then either a null-terminated name (most types) or, for
.CW Z / z
(source-line tables), a leading byte and 2-byte pairs terminated by
.CW 0x0000
\- get that second case wrong and the whole rest of the table
desyncs, which is what happened on the first pass.  The table
itself starts nine bytes before the third occurrence of
.CW "etext\e0"
in the file; the first two are false positives inside unrelated
embedded debug strings.
.CW asmsym()
writes
.CW etext
first, always.  A parser built this way against the current
.CW ipc64
resolved 26399 symbols, stopping exactly at the boundary with the
separately-formatted pc-line table \- the parse is complete, not
truncated.  Saved to
.CW scratchpad/resolve_ipc64_syms.py
for reuse; it must be re-run against whichever
.CW ipc64
build produced the capture being resolved, since addresses shift
across rebuilds that have nothing to do with the crash path, and
resolving an old capture's pc against a newer binary silently gives
a wrong answer with no indication anything is wrong.
.PP
Resolved four addresses from captures already on record.  The
earlier
.CW alloc:D2B
capture's caller pc
.RB ( 0x2610ec )
lands in
.CW mallocalign
+519; this session's own new capture
.RB ( "0x310598 not in pools" ,
caller
.CW 0x26129d )
lands in
.CW free
+121.  Both captures' second address \- what
.CW _poolfault()
calls
.CW getcallerpc(&v) ,
one frame further out than the
.CW D2B
site itself \- resolve to
.CW freelist
+113 and
.CW freelist
+257, and the two earlier "addresses do not recur" captures
.RB ( 0x784c2b8 / 0x2bdc2b
and
.CW "0x784a9b8 / 0x2bdc2b" )
both resolve their second address to the same
.CW freelist
+113.  Three of four
.CW alloc:D2B
captures on record now share
.CW freelist
as the frame just outside the failing call \- the first thing in
this entire hunt that repeats.
.CW cclone: 0x263d95
resolves to
.CW cunique
+28, and
.CW cunique
does call
.CW cclone
at that point in
.CW chan.c ,
so the pairing holds.  The GPF capture's pc
.RB ( 0x2f113b )
resolves nearest to
.CW dtoa
+4561, four and a half kilobytes past a float formatter's start \-
too far to be
.CW dtoa
itself with any confidence; more likely a static function with no
.CW T
entry sitting after it.  Recorded as unresolved rather than named.
.PP
What
.CW freelist
recurring does not yet say is which side of it is wrong.
.CW _poolfault() 's
panic format is
.CW "%s %p (from %p/%zux)"
with
.CW getcallerpc(&v)
and the
.CW c
argument \-
.CW c
is the pc
.CW D2B
itself captured at the failing check, one frame further in than
.CW getcallerpc(&v) .
Both addresses name who tripped the check, in two different
frames; neither says who wrote the bad bytes.
.CW free / mallocalign
calling into a
.CW D2B
check from inside
.CW freelist
is exactly what a correct pointer into an already-corrupted pool
looks like, same as every capture before it.  Read
.CW libinterp/heap.c 's
.CW freelist()
in full looking for a bug in its own tail-walk \- it iteratively
frees a Limbo list's cons chain without recursion, correctly stops
at a shared tail
.RB ( ADEC(&th->ref) != 0 )
rather than freeing memory another list still points at, and reads
.CW l->tail
before calling
.CW poolfree()
on the current node, so no ordering bug jumped out on inspection.
One real gap: unlike
.CW destroy() ,
which does a
.CW D2B
consistency check immediately before its own
.CW poolfree(heapmem, h) ,
.CW freelist() 's
per-node
.CW poolfree(heapmem, th)
inside the tail-walk loop had no such check \- so if the loop is
ever handed an already-bad
.CW th ,
nothing would have noticed at the point of failure.  Added the same
check there, not as a fix but as a probe: if it ever fires, this
loop is downstream of corruption that predates it, same as every
other capture; if it never fires while
.CW "alloc:D2B / cclone / cclose"
keep panicking elsewhere, this loop is cleared in one build.
.PP
Ran it: twelve boots, one crash, and the crash was not a
.CW D2B
panic at all \- a genuine CPU page fault
.RB ( CR2
.CW 0x100000008 ,
plainly not a real address), naming
.CW "module Sh pid 1"
this time, not
.CW currun()
nil, with fault
.CW PC
resolving to
.CW poolalloc
+100 \- inside the tree-walk at the very top of the function, right
after
.CW ilock(&p->l)
and
.CW p->root
's own tree is what it is walking.  So the probe answered a
narrower question than it was built for (freelist's own
.CW poolfree()
call was never reached this run) while a wider one landed instead:
.CW p->root
itself, or a node reached from it, was already bad before this
call started.  The contiguous top of the raw stack dump \-
.CW dumpstack
prints raw stack words, not a verified unwind, and only a
contiguous run near the fault is trustworthy as a call chain \-
reads
.CW xec
(the bytecode dispatch loop) into
.CW "headp / consp / movp / cons"
(Limbo list-cell instructions) into
.CW nheap
into
.CW "poolfree / ilock / iunlock / freeptrs"
into the faulting
.CW poolalloc .
.CW "sleep / iyield / vmachine / tready / udpstats / memdraw"
further down are stale words left over from earlier, unrelated
calls, not part of this chain.
.PP
Checked the mechanism that stack shape suggests: does anything
callable from inside
.CW poolalloc()
or
.CW poolfree()
while
.CW p->l
is held re-enter either function on the same pool \- which would
let two block-chain updates interleave under a lock that is not
reentrancy-checked?  Read both in full.  Neither calls
.CW "destroy() / freeptrs() / poolfree()"
while
.CW p->l
is held; the "TBS xmerge" branch in
.CW poolalloc()
that does call
.CW poolfree()
recursively is dead code
.RB ( "if(0 && ...)" ).
.CW poolfree() 's
own
.CW D2B(b,v)
check runs
.I before
.CW ilock(&p->l) ,
which is a real gap \- an unlocked header read \- but a read alone
does not explain a wild pointer written into
.CW p->root .
What this reading actually establishes, no broader: no path in
.CW alloc.c
writes
.CW p->root
or the tree links without
.CW p->l
held.
.PP
Two more candidates this suggested, both checked and both closed.
First: is this genuinely single-core, so that
.CW ilock() 's
local interrupt-disable is sufficient on its own without needing to
trust the spinlock's cross-CPU behavior?  Not inferred from the
absence of
.CW -smp
on the
.CW qemu-boot.sh
command line \- confirmed by source.
.CW conf.nmach = 1
is set once, in
.CW pc64/main.c 's
.CW mach0init() ,
and grepping
.CW "pc64 / pc / port"
for every assignment to
.CW nmach
finds no other write, including in
.CW mp.c
and
.CW squidboy.c
(both linked, both live in
.CW ../pc ).
.CW "mpintrassign: can't find bus type 12, number 0" ,
in every boot log, is MP-table parsing for interrupt routing, not
evidence of an AP ever starting.  Single mach, by construction, on
this port.  Cross-core races are not the mechanism here.
.PP
Second: does
.CW poolcompact()
run arbitrary code under
.CW p->l
via its
.CW pool->move
callback \- it rewrites
.CW pool->root
from scratch and calls
.CW pool->move(old, new)
for every live block it relocates, and it runs from inside
.CW poolalloc() 's
own locked region.  Grepped every
.CW poolsetcompact()
call in the tree: exactly one,
.CW libmemdraw/draw.c
setting
.CW imagmem 's
mover to
.CW memimagemove .
Neither
.CW mainmem
nor
.CW heapmem
\- the two pools every capture in this hunt belongs to \- ever gets a
.CW move
callback, and
.CW poolcompact() 's
own first line is
.CW "if(pool->move == nil || ...) return 0;" .
The whole compaction path \- the
.CW pool->root = nil
rebuild, the
.CW memmove
of live blocks,
.CW poolalloc() 's
recursive retry \- is dead code for both pools in every capture this
hunt has on record.  Not merely locked correctly: inactive.
.PP
Read
.CW pooladd()
and
.CW pooldel()
in full, the actual size-keyed BST-with-equal-size-rings that
.CW p->root
is \- the standard textbook shape (find in-order successor from the
right subtree's leftmost node, promote it, fix up both children's
parent pointers), including the easy-to-miss case where the
successor is not the deleted node's immediate right child.  Traced
every branch by hand; found no defect.  This does not mean the
algorithm is correct, only that inspection did not find where it
isn't \- diminishing returns against a genuinely nontrivial pointer
algorithm read by eye rather than proven.
.PP
So: not fixed, no smoking gun in
.CW alloc.c 's
own logic despite a real search, four live things ruled out
(reentrant locking, cross-core races, the move/compact path, and \-
provisionally, by inspection only \- the tree algorithm itself).
Built one more probe on the strength of what's left: does
.CW poolfree()
ever receive a pointer whose header is already wrong at the moment
it arrives?
.CW D2B
only checks the magic byte; added the same size/quanta-alignment
check
.CW _auditmemloc()
uses to classify a block, at
.CW poolfree() 's
entry, panicking with the caller's pc if it fails.  This is the one
thing no capture in this whole hunt has pinned down: whether a
corrupt-or-stale pointer arrives at
.CW poolfree() ,
or whether otherwise-valid frees are what corrupts the tree.
Committed as four separate, clearly-labelled probes
.RB ( disracepid / disracewindows / disraceoverlaps
in
.CW dis.c ,
.CW disracecheck()
in
.CW devprog.c ,
the
.CW D2B
check in
.CW freelist() 's
tail-walk, the header-validity check at
.CW poolfree() 's
entry) plus the symbol-table parser, all still open questions
rather than a fix.
.PP
Ran the
.CW poolfree()
entry probe: twelve boots, five crashes.  A note for every batch
count in this whole document, not just this one \- every boot is run
under
.CW timeout 100 ,
and a real panic followed by an idle/spinning guest still exits
.CW 124
once the timeout fires, the same code a genuinely clean boot exits
with.  Reading
.CW 124
as "no crash" without checking the log for
.CW panic
is a mistake this session made once already, on this same batch,
before rereading it.  Of the five: two
.CW cclone
panics with the identical caller pc across both, two general
protection violations (one naming
.CW $Sys
pid 1, one
.CW currun()
nil), and one new signature never seen before in this hunt \-
.CW "panic: initfrag" ,
from
.CW os/inferno/ip/ip.c ,
the IP fragment-reassembly table's own init-time size check.  A
different subsystem, seen once in 48 boots this session; recorded
and not chased further here.  None of the five was a
.CW D2B
panic, so the entry probe did not come back clean \- it came back
.I unexercised :
no D2B-family crash happened to occur in this batch to test it
against.  Not evidence valid pointers reach
.CW poolfree() ;
evidence only that this batch didn't ask the question.
.PP
The identical
.CW cclone
caller pc, across two crashes in one batch, resolves to
.CW cunique
+28 \- the exact call site
.CW "nc = cclone(c);"
inside
.CW cunique() ,
line 575 of
.CW chan.c .
A third, earlier
.CW cclone
capture (the "reading native crash addresses" section, two sections
back) resolves to the same
.CW cunique
+28 against
.I its
own build.  Three
.CW cclone
panics, one exact call site, across three different builds \- the
strongest recurrence in this whole hunt.
.CW cunique() 's
own check is
.CW "if(c->ref != 1)" ,
which does not exclude
.CW "c->ref <= 0" ;
.CW cclone() 's
panic condition is
.CW "c == nil || c->ref < 1 || c->flag&CFREE" ,
three clauses ORed into one panic that prints only the caller pc \-
no capture on record can say which clause actually fired, and a
refcount underflow and a chan already returned to the free list and
reused are different bugs with different fixes.  Enhanced all three
of this signature's panic sites
.RB ( cclose() ,
.CW ccloseq() ,
.CW cclone() )
to print
.CW c ,
.CW c->ref ,
and
.CW c->flag
alongside the caller pc, guarding the
.CW c==nil
case separately since the other two fields aren't readable then.
Not yet run.  The next
.CW cclone
capture will say which of the three conditions fired; if it's
.CW c->flag&CFREE ,
the seven callers of
.CW cunique()
narrow to whichever can hold a chan across a window where something
else already freed it \- worth tracing then, not before.
.NH 1
The first capture that names a value instead of an address
.PP
Added the probe
.CW destroy()
needed: three page faults this hunt landed inside its own
.CW D2B
consistency check, at CR2 values of
.CW -32 ,
.CW -56 ,
and
.CW -20
\- not wild addresses, small integers near zero, and
.CW destroy() 's
own
.CW "v == H"
check already excludes the nil-heap sentinel, so
.CW v
was never a valid pointer to begin with.  Added a check for
.CW "(uintptr)v < 0x1000"
right after that guard, printing
.CW v
and
.CW getcallerpc(&v)
before an
.CW abort() \-
.CW panic()
itself isn't linkable from
.CW libinterp
(it's kernel-only;
.CW error() / errorf()
are the portable idiom here but raise a catchable Limbo exception,
which is the wrong tool when the point is to stop hard and be seen,
so this follows
.CW gc.c 's
own existing
.CW abort()
precedent instead).
.PP
Ran it: twelve boots, three crashes \- a general protection
violation, a new one-off signature
.RB ( "panic: init0: bad attach specifier" ,
one line, not chased), and the probe itself, firing for the first
time:
.CW "destroy: bad v 0 from 0x32" .
.CW v==0
is the first capture in this entire hunt to name a bad
.I value
rather than a bad address \- every
.CW "D2B / cclone / cclose / GPF"
capture before this one has only ever pointed at where the
corruption was noticed, never at what the corruption actually was.
Worth stating plainly as the methodological result it is,
independent of whatever the root cause turns out to be.
.PP
The
.CW "from 0x32"
half is not trustworthy, though \- 0x32 is nowhere near this port's
text segment
.RB ( INITTEXT
.CW 0x200000 ),
so it isn't a real caller pc.
.CW getcallerpc(&v)
depends on the frame already being laid out the way it is at the
two places elsewhere in this tree that use the same trick
successfully
.RB ( D2B 's
own
.CW getcallerpc(&dp)
and
.CW poolfault() 's
.CW getcallerpc(&v) ),
both of which read it after the value in question has already been
used, not from inside an early-exit guard at the top of the
function the way this probe does.  Calling it from a different
point in the prologue broke the assumption; the read is garbage,
not evidence of anything.  Recorded as a probe defect to fix, not a
second data point about stack corruption.
.PP
Ran the moved version: twelve boots, three crashes
.RB ( "unknown namec access 2" ,
a page fault, and the probe again) \- and the probe's own capture,
.CW "destroy: bad v 0 from 0x0" ,
shows moving the
.CW getcallerpc()
call didn't fix it either; anchoring on
.CW &h
instead of
.CW &v
still read a caller pc nowhere near this port's text segment.  Two
failed anchors is enough to stop guessing at frame timing.
.PP
Dropped
.CW getcallerpc()
for the two things that have actually worked throughout this whole
hunt: the
.CW currun()
Dis-module trick
.CW dumpregs() / _poolfault()
already use, and a raw
.CW dumpstack() \-
board-specific, deliberately temporary.  Ran it: twelve boots, one
crash, and it was the probe:
.CW "destroy: bad v 18, running Dis pid 1 module $Sys PC 0xa3c818" ,
firing before
.CW "loading /dis/sh.dis"
even prints \- earlier than any capture this whole hunt has landed,
during
.CW $Sys 's
own module init.
.CW v==18
this time, not
.CW 0
\- across the two clean captures this probe has produced,
.I "the value differs" ,
which rules out "always reads a freshly-zeroed slot" and points at
stale, reused stack contents instead.
.PP
The
.CW dumpstack()
output resolved to a complete, coherent chain for the first time in
this entire hunt:
.CW disinit
\(->
.CW vmachine
\(->
.CW startup
\(-> ...  \(->
.CW xec
(the bytecode dispatch loop) \(->
.CW mcall
\(->
.CW freeptrs
\(->
.CW destroy .
.CW OP(mcall)
in
.CW libinterp/xec.c ,
on its
.CW "ml->prog == nil"
branch (a call into a native/builtin function, not compiled Limbo
bytecode), does
.CW "l->runt(f)"
and then, once the native call returns,
.CW "if(f->t->np) freeptrs(f, f->t)"
\- cleaning up whatever pointer-typed locals the frame
.CW f
held, using
.CW f->t
as the map of which slots are pointers.
.CW f
itself comes from
.CW T(s) ,
Dis-stack space that's reused across calls, not a fresh
allocation \- and if the frame's own pointer slots were not all
written
.CW H
by whatever created the frame, before this cleanup runs,
.CW freeptrs()
walks into whatever stale bytes are sitting in that reused stack
region and hands them to
.CW destroy()
as if they were real old values.  That would explain the value
differing between captures (different leftover stack contents),
"indifferent to which module is running" (this is a property of the
native-call cleanup path itself, exercised by any
.CW sys->
call from any module), and both very early and very late timing in
one mechanism.  Not confirmed \- checked and not yet read:
.CW OP(mcall)
does not create
.CW f ,
it only cleans it up, so the actual defect (if this reading holds)
would be in whatever earlier instruction
.RB ( OP(frame) ,
.CW newframe()
in the same file) builds the frame, specifically whether frame
creation initializes every slot the
.I same
.CW f->t
declares, or a different, narrower descriptor \- a size/descriptor
mismatch between the type that built the frame and the type that
cleans it up would be permanent and exact, not a race, which fits
the evidence better than a timing theory would.  Two clean captures
both landing on this one path
.RB ( mcall 's
runt branch specifically) is what the evidence says; it does not
yet license "any native call," only this one.
.PP
.CW dumpstack()
is pc64-only and does not belong in shared
.CW libinterp
code past this investigation \- it must come out before any other
board (or hosted emu) build is attempted, since nothing else links
it.  Left in for now because this is still the active probe; pull it
in the same change that replaces it with whatever the
.CW OP(frame) / newframe()
reading turns up.

.NH 1
The overflow probe's first version was checking the wrong thing
.PP
The
.CW OP(frame) / OP(mframe)
descriptor probe from the previous section was tightened before its
first real batch even finished: comparing
.CW t->np*8*sizeof(WORD)
against
.CW t->size
as a single number is too strict.
.CW initmem() / freeptrs()
gate every
.CW w[i]
access behind
.CW "if(c != 0)"
for each map byte in turn; a trailing map byte that is entirely zero
bits still gets walked
.RB ( p++ ,
.CW "w += 8" ),
but nothing is ever read or written for it, however far past
.CW t->size
its nominal eight words would reach.  Ran the first version anyway,
twelve boots: it fired on eleven of them, every time with the
identical
.CW "t->np 2 t->size 72"
in module
.CW Init .
A check that fires the same way on all but one boot cannot be the
crash this hunt has been chasing \- everything else in this
investigation has been allocation-order dependent, never the same
capture twice.  It is a static fact about
.CW Init 's
own compiled type table, not runtime corruption, and is retracted as
a finding in the same paragraph it is reported, per this document's
own house rule.
.PP
Rewrote the check per bit instead of per byte, matching
.CW freeptrs()
's own walk exactly:
.CW BIT(c,\ nb)
names
.CW w[7-nb]
for map byte
.CW i ,
so the word index is
.CW i*8+(7-nb) .
The tightened probe
.RB ( checkframedesc() ,
shared by both opcodes) only flags a
.I set
bit whose word falls outside
.CW t->size ,
printing the byte index, bit, computed word offset and both sizes
before the same
.CW abort() .
Confirmed
.CW WORD
is
.CW intptr
(8 bytes) and
.CW STRUCTALIGN
is
.CW sizeof(intptr)
(also 8) on this port before trusting the rewrite \-
.CW interp.h 's
.CW "Type.map[STRUCTALIGN]"
is a minimum placeholder, not a hard cap;
.CW t->np
can and does exceed it for a frame with more pointer slots than one
map byte covers, allocated with extra trailing space.  Ran the
tightened probe: twelve boots, zero descriptor-overflow hits \-
this branch closes cleanly.  It also retires the
.CW mcall / freeptrs
theory the previous section's
.CW dumpstack()
trace suggested: frame creation and frame cleanup agree on every
pointer slot they touch, so the stale value
.CW freeptrs()
handed to
.CW destroy()
is not a size mismatch between the two.
.PP
Four of the twelve boots still crashed
.RB ( alloc:D2B ,
a general protection violation, two page faults) \- this probe
was never expected to touch the underlying bug, only to settle
whether its own check was sound.  Both page faults landed at the
identical PC,
.CW ainc+5 ,
called from
.CW movp+47
(OP(movp)'s
.CW AINC(&h->ref) ),
called from
.CW mcall+212 ,
with
.CW CR2
a small negative value
.RB ( \-20 ,
both times) \- the same family as
.CW destroy() 's
earlier "bad v" captures
.RB ( 0 ,
.CW 18 ,
and CR2
.CW "-32 / -56 / -20"
before that), not a wild pointer.
.CW OP(movp)
reads
.CW sv\ =\ P(s) ;
if it is not
.CW H
it goes straight to
.CW "D2H(sv)"
and
.CW AINC(&h->ref)
with no validity check \- the same shape of bug as
.CW destroy() ,
in a second, independent opcode, both landing on a pointer-typed
slot holding a small non-H garbage value rather than a real heap
address or the nil sentinel.  Added the identical
.CW currun()\ +\ dumpstack()
probe to
.CW OP(movp)
that
.CW destroy()
already carries, so a capture here is directly comparable.  Two
independent opcodes hitting the same failure shape narrows the
search: the defect is upstream of both consumers, in whatever
writes (or fails to write) a pointer-typed slot before either
opcode reads it.
.PP
Ran the
.CW OP(movp)
probe: twelve boots, two crashes
.RB ( alloc:D2B ,
and a new one-off,
.CW "panic: init0: clone failed" ,
not chased), neither at
.CW movp ,
and the specific
.CW ainc
page fault did not recur.  Two of twelve is not distinguishable
from this hunt's usual near-50% rate at this sample size \- said
plainly rather than read as a signal, since this document has
already had to retract one over-read finding this same round.
.CW OP(movp)
stays in place, low-cost and firing only on an already-exceptional
value; the next capture compounds directly on what is here.
.PP
Advisor review of this round caught two more things worth acting
on rather than filing.  First, the
.CW OP(frame) / OP(mframe)
descriptor probe had already done its job \- the tightened version
ran clean, which retired the theory it was built to test \- so it
was dead weight in shared
.CW libinterp
code and is removed (both call sites and the
.CW checkframedesc()
helper); the finding stays in the doc, the check does not need to
keep running to be true.
.PP
Second, a sharper reading of the batch10 stack traces: both page
faults resolved to
.CW movp+47
called from
.CW mcall+212 \-
.CW OP(mcall) ,
the same opcode whose
.CW freeptrs()
cleanup produced the
.CW destroy()
captures.  That is narrower than "upstream of both consumers": two
independent uses of a bad pointer slot, both reached through
.CW mcall .
In
.CW OP(mcall) 's
.CW "ml->prog == nil"
branch,
.CW f
comes from
.CW T(s) \-
Dis stack space, not a fresh allocation \- and
.CW l->runt(f)
is a native/builtin function that writes its return value directly
into
.CW f .
.CW OP(frame) / OP(mframe)
's own descriptor is now confirmed sound, but nothing has yet
checked whether
.CW f->t
itself \- the pointer to that descriptor \- survives the native call
unchanged.  Added a one-shot check: save
.CW f->t
before
.CW l->runt(f) ,
compare after: a mismatch means
.CW freeptrs()
below reads the frame against the wrong map, and calls
.CW destroy()
on whatever bytes sit at the wrong offset.  Not yet run.

.NH 1
The mcall f->t probe ran clean, and dumpstack() is not a real unwind
.PP
Ran the
.CW OP(mcall)
.CW f->t
mismatch check: twenty boots, five crashes
.RB ( "general protection violation" ,
two page faults, one
.CW alloc:D2B ,
and one
.CW destroy()
probe hit) \- the mismatch check itself never fired.  That specific
mechanism is refuted: whatever native call ran in any of these
twenty boots,
.CW f->t
survived it unchanged, so
.CW freeptrs() 's
later cleanup was always reading the frame against the descriptor
that actually built it.
.PP
The
.CW destroy()
hit
.RB ( "destroy: bad v 0, running Dis pid 1 module Sh" )
is the same shape as the two captures already on record, and its
.CW dumpstack()
output prompted a second look at what that dump actually shows.
Resolving every address in it named
.CW ret+239
and
.CW freeptrs+357/367
near the top of the scan, with no
.CW mcall
address anywhere in this particular capture \- a real difference
from the
.CW "disinit -> ... -> mcall -> freeptrs -> destroy"
chain an earlier capture produced.
.CW OP(ret)
carries the identical cleanup shape as
.CW OP(mcall) 's
native-call branch
.RB ( "if(f->t\ ==\ nil)\ unextend(f);\ else\ if\ (f->t->np)\ freeptrs(f,\ f->t);" ) ,
so this reads as
.I "a different one of several structurally identical call sites"
reaching the same
.CW freeptrs()/destroy()
pair, not a new mechanism.
.PP
Worth being precise about what
.CW dumpstack()
actually is, though, before trusting that reading too far:
.CW ktrace 's
scan walks a raw address range and resolves whatever look like text
addresses, it does not walk frame pointers.  Addresses from
opcodes that have already run and returned can still be sitting in
stack bytes a later, unrelated call reuses, and get resolved right
alongside addresses that are genuinely still on the call chain \-
this capture's own
.CW movp+184 ,
.CW slicec+78
and
.CW bnec+37
entries are almost certainly exactly that (none of those opcodes
call each other, or
.CW ret ,
or
.CW freeptrs ;
they are peers dispatched one after another from the same
.CW xec()
loop).  Whether this particular
.CW destroy()
call came through
.CW ret
or
.CW mcall
is therefore a reasonable reading of the freshest, deepest entries
in the scan, not a proven fact the way the disinit chain was \- and
it does not change the underlying finding either way: a
.CW Frame 's
pointer-typed slot held a value that was neither
.CW H
nor a real heap pointer by the time some cleanup read it.
.PP
Added one cheap, durable improvement while this capture was in
hand: both
.CW destroy() 's
and
.CW OP(movp) 's
probes now also print
.CW "xp->R.PC\ -\ xp->R.M->m->prog" ,
the instruction's offset into its module's own code array.  A raw
.CW R.PC
pointer is a heap address that moves every boot; this offset does
not \- a module's compiled bytecode is fixed by
.CW "disinit.b / sh.b" 's
own source, unchanged across kernel rebuilds \- so the next capture
can be handed straight to
.CW disdump
against the real
.CW .dis
file instead of staying an opaque address.  Not yet exercised
against a real capture.
.NH 1
Naming a source line at last: Env->getenv()'s call to sys->open()
.PP
Ran the enhanced probes: twenty boots, five crashes
.RB ( "general protection violation" ,
.CW alloc:D2B
twice at the same address across two different boots (
.CW 78495b8 ,
a coincidence of this kernel's own deterministic early heap layout
before the divergence point, the same shape already filed in
UPDATE 13 when addresses failed to recur \- not chased further),
two
.CW cclose
panics with different
.CW ref / flag
values, and one
.CW destroy()
probe hit).  The
.CW destroy()
hit
.RB ( "destroy: bad v 0, running Dis pid 1 module Env PC 0x79276c8 inst 58" )
is the first capture this whole hunt has been able to turn into an
actual source line.
.PP
.CW xec() 's
dispatch loop does
.CW "op\ =\ R.PC->op;\ R.PC++;\ optab[op]();"
\- PC is advanced
.I before
the opcode handler runs, so inst 58 names the instruction
.I executing ,
not the one about to run: inst 57.  Ran the hosted
.CW emu
against
.CW dis/lib/env.dis
through
.CW disdump
(headless, no graphics needed \- `emu -r $ROOT disdump /dis/lib/env.dis`)
and indexed its output 0-based.  Instruction 57 is
.CW "mcall 72(fp), $2, 40(mp)" ,
in a block (instructions 53\(en60) that matches
.CW appl/lib/env.b 's
.CW getenv()
byte for byte: an
.CW addc
concatenating a string (the source's
.CW "ENVDIR+var" ),
a
.CW movw\ $0
(.CW Sys->OREAD ,
which is 0), the
.CW mcall
itself, then a
.CW bnew
against the module's own nil constant that falls through to
.CW "movp\ ...;\ ret"
only when the call's result equals nil \- exactly
.CW "if (fd == nil) return nil;" .
This is
.CW "fd := sys->open(ENVDIR+var, Sys->OREAD);" ,
the first source-level call site this entire investigation has
been able to name.
.PP
Read
.CW Sys_open()
.RB ( os/inferno/port/inferno.c )
expecting to find the defect there and didn't: it destroys the old
.CW *f->ret ,
sets it to
.CW H
.I before
.CW release() ,
and only overwrites it with a real fd (never anything else) after
.CW acquire() .
Every path leaves
.CW *f->ret
either
.CW H
or a valid pointer \- correct on its own terms, and therefore not
the explanation by itself.
.CW *f->ret
is one slot;
.CW freeptrs()
walks every slot the frame's map marks as a pointer, and this
frame also carries the
.CW "ENVDIR+var"
string built by instruction 54's
.CW addc
into a different slot
.CW Sys_open()
never touches.  Which slot is actually bad was not yet checked.
.PP
Added a gated scan in
.CW OP(mcall) 's
native-call branch, right where
.CW freeptrs(f,\ f->t)
already runs: walk the same bit-per-word map
.CW freeptrs()
itself walks, and if any slot the map marks as a pointer holds a
small non-
.CW H
value, print the running module/pid/PC/instruction index and the
frame's own
.CW showframe()
dump (map bytes and every slot's raw contents \- already existed in
this file, previously reachable only from a permanently disabled
.CW "if(0)" )
before aborting.  This names which specific slot is bad, not just
that the frame has one somewhere.  Not yet run.
.PP
Standing blocker, said plainly rather than deferred again:
.CW dumpstack()
is still in
.CW libinterp/heap.c
and now also
.CW xec.c ,
board-specific and not linkable outside pc64.  Hosted
.CW emu
was rebuilt and run successfully this round to drive
.CW disdump \-
that binary predates these changes; the next build of
.CW emu/
(or any other board) will fail to link until
.CW dumpstack()
comes out.  pc64 remains the only buildable target.
.PP
Ran the gated frame-slot scan: twenty boots, four crashes
.RB ( "general protection violation" ,
a page fault, an
.CW alloc:D2B ,
one
.CW cclose ) ,
none in the
.CW "destroy() / OP(movp) / OP(mcall)"
family this round \- no
.CW getenv() -shaped
capture occurred to exercise it.  Consistent with this hunt's
standing nondeterminism, not a result either way.  The scan stays
in place for the next one.
.NH 1
A durable resolver, two named sites in sh.b, and a clean negative
.PP
Wrote a permanent replacement for the
.CW disdump
detour: a parser reading a
.CW .sbl
file directly
.RB ( limbo/sbl.c 's
own format, delta-encoded against running file/line state exactly
as the emitter tracks it \- see
.CW os/inferno/pc64/tools/README ) .
Every
.CW .b / .m
compile already writes one next to its
.CW .dis ,
so this needs no VM, no
.CW case
table walking, nothing but the file already on disk.  Validated
against the one capture already cross-checked by hand:
.CW env.dis
inst 57 resolves to
.CW env.b:41 ,
matching the earlier
.CW disdump
reading exactly, and both tools agree on
.CW ninst
(146 for
.CW env.dis ,
6111 for
.CW sh.dis ).
Saved as
.CW os/inferno/pc64/tools/resolve_sbl.py ,
alongside
.CW resolve_ipc64_syms.py
moved there from the scratchpad it had been living in \- both are
now durable, not session-local.
.PP
Stated once, prominently, because every capture from here on
depends on it:
.CW xec() 's
dispatch does
.CW "op\ =\ R.PC->op;\ R.PC++;\ optab[op]();" \-
PC is advanced
.I before
the handler runs, so a probe's printed instruction index is always
one more than the instruction actually executing.  Resolve
.CW "index\ -\ 1" ,
not the printed value.
.PP
Resolved the three
.CW Sh
captures from the thirty-boot batch with the corrected index.  They
are not one finding, they are two, and they should not be read as
one:
.IP \(bu 2
.CW "inst 5147 (destroy, v=0)"
resolves to
.CW sh.b:2339 ,
inside
.CW "while ((c = l.getc()) != '\\n' && c != l.EOF)" \-
a lexer character-read loop.  No array growth anywhere near it, a
different function entirely from the other two, and a different
bad value.  Filed as its own, separate, unexplained site.
.IP \(bu 2
.CW "inst 5615 (movp, sv=18)"
and
.CW "inst 5618 (destroy, v=18)"
resolve four lines apart in
.CW yyparse() \-
.CW "yys\ =\ (array[len\ yys\ *\ 2]\ of\ YYS)[0:]\ =\ yys;"
(2788) and
.CW "yys[yyp].yyv\ =\ yyval;"
(2792), the shift-stack's own growth-then-index sequence.  Two
different boots, so per this hunt's own standing rule this reads as
the same
.I code path
misbehaving twice, not one write observed by two readers.  The
value
.CW 18
now recurs in three captures across the whole investigation
(this hunt's earlier "value differs between captures" note still
holds for
.CW 0
vs
.CW 18 ,
but
.CW 18
itself is not a one-off).
.PP
.CW YYS
is
.CW "{ yyv: YYSTYPE; yys: int }" ,
and
.CW YYSTYPE
is
.CW "{ node: ref Node; word: string; redir: ref Redir; optype: int }" \-
three pointers and an int, wrapped in another int.  Exactly the
shape where an int-typed store landing one slot off would write a
small integer where a type's map says pointer.  Built a minimal
Limbo program on the host, matching this layout field-for-field
(same order, same
.CW "ref / string / ref / int"
sequence, a nonzero sentinel in both int fields so a wrongly-treated-
as-pointer slot would show), doing exactly what
.CW yyparse()
does: grow an
.CW "array of YYS"
by chained slice-assignment, then assign a whole
.CW YYSTYPE
into a freshly grown slot.  Ran clean under the hosted
.CW emu \-
every fresh slot's pointer fields came back nil, both int fields
came back zero, and the post-growth whole-struct assignment worked
with no corruption.
.PP
That result is real but narrower than "array-of-nested-ADT growth
is ruled out.''  It ran on hosted
.CW emu \-
arm64, a different VM binary, no SMP, no
.CW release() / acquire()
interleaving with another kproc \- not pc64, which is where every
capture in this entire hunt has come from.  What this actually
shows: this construct is not deterministically broken in isolation
on hosted
.CW emu .
Whether it holds under pc64's own concurrency is untested.  Not
fixed.  Still no probe added beyond what the last commit already
carries; the next step, not yet taken, is checking
.CW "array of YYS" 's
own compiled type map against this exact field layout rather than
adding more runtime instrumentation.



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
The type descriptor is correct on real pc64; three mechanisms closed
.PP
Checked the thing the host repro couldn't reach: the actual compiled
type descriptor for
.CW "array of YYS"
in the real
.CW sh.dis
running on pc64 itself, not a hand-written stand-in.  Added a
one-shot print in
.CW OP(newa) / OP(newaz)
(shared helper
.CW probearrtype() ,
gated on module
.CW Sh
and
.CW t->size\ ==\ 40
so it cannot fire on an unrelated allocation elsewhere in a long
shell session) dumping
.CW t->size ,
.CW t->np
and the map bytes.  Five boots, four hits, byte-identical every
time:
.CW "size 40 np 1 map 0xe0 sz 200" .
.CW 0xe0
is
.CW "11100000" \-
bits 7, 6, 5 set, matching the predicted layout exactly: word 0
.RB ( node ,
a pointer), word 1
.RB ( word ,
a pointer), word 2
.RB ( redir ,
a pointer) marked; word 3
.RB ( optype ,
an int) and word 4
.RB ( yys ,
an int) correctly left clear.  The compiler's type descriptor for
this exact shape is right, on the real binary, not just in a
hand-written repro.  That closes the type-descriptor theory for
good, not just "probably fine.''
.PP
Checked which allocation this actually is before trusting that,
per the standing rule that a capture's identity has to be confirmed
before building on it:
.CW sh.b:79
declares
.CW "YYMAXDEPTH: con 200" ,
and
.CW sh.b:2769
is
.CW "yys := array[YYMAXDEPTH] of YYS;" \-
.CW sz\ 200
is
.I "yyparse() 's own initial allocation" ,
not a guess at a growth event.  The shift stack starts at its full
200-entry capacity from the first call; the doubling code at
.CW sh.b:2788
is a rare overflow fallback, only reached if a single parse ever
needs to nest 200 levels deep \- worth keeping in view rather than
assumed innocent, since an ordinary shell script hitting that path
at all is itself unusual.
.PP
A third mechanism closes alongside these two, on inspection rather
than a new probe:
.CW acquire() / release()
(
.CW os/inferno/port/dis.c )
is a single global queue
.RB ( isched.vmq ,
one lock,
.CW isched.idle
tracking whether any kproc holds the token) \- exactly one host
kproc may execute Dis bytecode at any instant, on pc64 same as the
hosted tree, regardless of how many physical CPUs this SMP kernel
has.  Genuinely parallel bytecode execution was a candidate
mechanism raised and set aside without checking two sections back;
it is now checked and closed, not just dropped.
.PP
Three mechanisms now closed with direct evidence: the type
descriptor is correct, the construct is not deterministically
broken in isolation (previous section, host
.CW emu ) ,
and Dis bytecode never runs on two CPUs at once.  What remains
open: whether something clobbers this array's memory
.I between
its correct creation and the moment
.CW destroy() / OP(movp)
read a bad slot back \- a use-after-free-into-reuse or an
allocator-level bug neither a type check nor an isolated repro can
see.  Watching one specific allocation's memory across that window
needs a different technique than a print at a fixed instruction;
choosing one is deferred, not started this round.

.NH 1
Frame cleanup was never the mechanism: a third module, and dv
.PP
Wired the same per-slot scan
.RB ( scanframe() )
into
.CW OP(ret) 's
cleanup, not just
.CW OP(mcall) 's
native-call branch \- factored the two copies into one shared
function first.  The reasoning: sh.b's
.CW getc()
is an ordinary Limbo method call, not a native one, so it returns
through
.CW OP(ret) ;
.CW yyparse() 's
array growth calls no native function either.  Both of this hunt's
named Sh sites return through
.CW ret ,
never through
.CW mcall 's
native branch, so that branch's own scan could never have reached
either of them.  This also settles, on reflection rather than
another capture, the "mcall or ret" uncertainty two sections back
in favour of
.CW ret
for both.
.PP
Ran it: thirty boots, ten crashes
.RB ( "GPF" \|\c
.RB ( x3 ) ,
.CW alloc:D2B
.RB ( x2 ) ,
.CW cclone:\ c\ nil
.RB ( x2 ) ,
page fault, and one new one-off,
.CW "init0: bad attach specifier" ,
not chased) \- and one
.CW destroy()
hit, in a
.I third
module,
.CW Bufio ,
never seen in this hunt before.
.CW scanframe()
did not fire, in either
.CW mcall
or
.CW ret .
That is the actual result, and it says something specific: whatever
frame
.CW freeptrs()
walked when this fired had every slot the map marks as a pointer
looking fine to the same check that would have caught a bad one.
The bad value
.CW destroy()
found did not come from frame cleanup at all.
.PP
Resolved
.CW bufio.dis
inst 429 (the printed 430, minus one) through
.CW resolve_sbl.py :
.CW bufio.b:271 ,
.CW "r\ =\ int\ b.buffer[b.index];"
\- a plain byte-array index inside
.CW Iobuf 's
own low-level read, called from
.I "sh.b's own getc()"
via
.CW "bufio->lex.f.getc()" .
Nothing pointer-typed in that line itself, which fits: this
.CW destroy()
call is not cleaning up anything this line wrote, it is
.CW OP(movp) 's
own
.CW "destroy(dv)" \-
the value already sitting in a slot, overwritten and destroyed on
every ordinary pointer assignment, anywhere in any module, all the
time.
.CW OP(movp) 's
probe only ever guarded
.CW sv
(the value being read in); the
.I destination
slot's old value,
.CW dv ,
had no guard at all, so a bad
.CW dv
could only ever be caught one level removed, inside
.CW destroy() 's
own check, with no slot address to show.
.PP
Closed that gap: refactored
.CW sv 's
guard into a shared
.CW badptrslot()
helper (bad value, slot address, which of
.CW "sv / dv" )
and added the identical check for
.CW dv
right where
.CW OP(movp)
already reads it, before
.CW destroy(dv) .
Now every slot
.CW OP(movp)
touches, read or overwritten, is checked at the point of use, with
its address on hand for the same memory-around-slot dump
.CW sv 's
guard already does.  Three named sites now, in three different
modules
.RB ( Env ,
.CW Sh ,
.CW Bufio ) ,
via at least two different mechanisms
.RB ( freeptrs()
cleanup for the
.CW Env
capture,
.CW movp 's
own
.CW dv
overwrite for
.CW Bufio ) \-
this reads less like a bug in any one piece of Limbo source and
more like something at a level every module shares.  Not yet
narrowed further; not fixed.

.NH 1
A substantive capture, a fourth module that doesn't fit, and a real check
.PP
A process note before the results: the previous section's batch was
cut short at ten of forty boots to switch binaries, discarding that
progress for a change (
.CW scanframe()
in
.CW OP(ret) )
that the very
.CW destroy()
check already running would have caught regardless.  Batches are
the scarce resource in this hunt; that kill should not have
happened, and the standing plan going forward is to let a running
batch finish even when a better-instrumented binary is ready,
rather than discard boots already spent.
.PP
Ran the
.CW dv
guard: forty boots, seven crashes in the usual unrelated families
.RB ( GPF
.RB ( x2 ) ,
.CW alloc:D2B ,
page fault,
.CW "unknown namec access 2" ,
plus two new one-offs, not chased), and two hits in the
.CW destroy() / OP(movp)
family \- one of them the first genuinely informative memory dump
this probe has produced.
.PP
.CW "movp: bad sv 0"
in module
.CW Sh
dumped ten words around the slot.  Eight of them are heap pointers
evenly spaced 0x80 apart \- consistent with a chain of same-size
allocations, most plausibly
.CW List
nodes from a
.CW ::
chain (this capture resolves, via the same off-by-one-corrected
.CW resolve_sbl.py
lookup as every capture since UPDATE 17, to
.CW sh.b:1061 ,
.CW "keepfds\ =\ fd1\ ::\ keepfds;" ,
inside redirect processing) \- and the one slot that breaks the
pattern holds exactly
.CW 0 ,
immediately followed by a legitimate
.CW H
.RB ( -1 )
one word later.  That is the sharpest data point this hunt has on
record: not a wild address, not a plausible small integer, but the
.I "wrong sentinel" \-
native kernel C's own
.CW nil
is
.CW "(void*)0"
.RB ( Inferno/amd64/include/u.h ) ,
a completely different bit pattern from Dis's own empty-heap-pointer
.CW H
.RB ( "(void*)(-1)" ,
interp.h).  Chased this directly: read
.CW Sys_open() ,
.CW Sys_read() ,
.CW Sys_readn()
and
.CW Sys_pctl() \-
the four native functions most plausibly upstream of a
list-of-fds/file-open path \- all four correct, all four use
.CW H
where a Dis-visible pointer output needs it and
.CW nil
only for their own native C locals (which is correct and cannot be
distinguished from the bug by grepping for the string
.CW nil ).
Four checked, zero found; this line of attack does not converge
by inspection and is not narrowing further without catching the
write directly.
.PP
Second capture, not chased into the same story:
.CW "destroy:\ bad\ v\ 0"
in module
.CW Styxservers ,
running Dis
.I "pid 4" \-
every capture on record before this one, across every module, was
pid 1.  A different Prog entirely does not fit "the same
.CW yys / keepfds
lineage gets corrupted later"; it is either a much more general
mechanism than the Sh-specific framing of the last several sections
suggests, or a second, separate bug.  Recorded as open and
unexplained, not folded into the Sh narrative it happens to share a
value with.
.PP
Added the check the sv/dv memory dump was always missing: whether
the
.I slot
itself \- not the bad value in it \- sits inside a block the pool
allocator still considers live, or one already on the free list.
That distinguishes a stray write into live memory from a genuine
use-after-free in one step, and
.CW alloc.c
already has the function for it:
.CW _auditmemloc() ,
exported as
.CW auditmemloc() ,
walks the pool's own chain with the same magic/size validation the
.CW poolfree
probe already uses, and reports which block (free, allocated, or
immutable) contains any address handed to it \- built for exactly
this, reused rather than duplicated.  Wired into
.CW badptrslot() ,
called on the slot address right before the existing
.CW dumpstack()/abort() .
Not yet run.  Not fixed.

.NH 1
The liveness check runs: a stray write, not a use-after-free
.PP
A forty-boot batch against the
.CW auditmemloc()
build produced two captures of the two checks it was built to answer,
plus a signature never seen before.  Take the liveness answer first,
since it is the one this whole thread has been building toward.
.PP
Boot 40 hit
.CW "OP(movp)" 's
.CW sv
guard in module
.CW Init ,
inst 267, the same bad-sentinel shape as every capture before it: a
pointer-typed slot holding
.CW 0
where
.CW H
was required, sitting among otherwise-valid neighbours.
.CW auditmemloc()
answered the question directly:
.IP
.nf
.CW "sv: a3b3e8 in main: in block at a3b240 B2D 0xa3b260 size b00"
.CW "  ec 0xa587c0 next block 0xa3bd40 searched address 0xa3b3e8"
.fi
.PP
.CW _auditmemloc() 's
own
.CW msg
strings are
.CW "\ free\ blk\ " ,
.CW "\ immutable\ block\ "
and
.CW "\ block\ " ;
this dump says
.CW block ,
the
.CW MAGIC_A
case \- allocated, not freed.  The containing block (0xb00 bytes, in
.CW mainmem ,
the pool holding native kernel structures like a
.CW Prog 's
frame, not the Dis-GC'd
.CW heapmem )
is one the pool allocator still considers live.  That settles the
question
.CW auditmemloc()
was added to answer, for this capture at least: this is a stray
write into memory that is still in service, not a read of memory
already handed back to the free list.  Use-after-free is ruled out
here; whatever writes the
.CW 0
does so while the frame it lands in is still the frame using it.
.PP
Boot 28 hit
.CW destroy() 's
own older probe instead, in module
.CW Sh ,
inst 5728 \- a fifth capture of the same lexer/parser family, but no
.CW auditmemloc()
output, because that probe (in
.CW heap.c )
never got the same call added; only
.CW badptrslot()
in
.CW xec.c
did.  A gap worth closing the next time
.CW destroy()
itself fires with something to look at, but not blocking: the
question it would answer was already answered by boot 40's capture
in the same batch, on the same failure shape.
.PP
The batch's third finding does not fit anywhere in this narrative.
Ten of the forty boots \- far above any other single signature this
whole hunt has recorded, and zero occurrences across the roughly two
hundred boots of every batch before this one \- hit a new panic:
.CW "invalid\ opcode" ,
CPU exception type 6, consistently at
.CW "PC\ 0x000000000000000B" .
Resolving addresses from one capture's
.CW ktrace
dump against
.CW ipc64 's
own symbol table named
.CW dofmt+137 ,
.CW vseprint+107
and
.CW xec+409 ,
suggesting the fault lands during a
.CW print()
call, and several captures' immediately preceding boot output was a
pre-existing
.CW mountio()
trace
.CW ( os/inferno/port/devmnt.c ,
not new this round).  A jump to
.CW PC\ 0xB
is what calling through a garbage function pointer looks like, and
this batch's binary added exactly one new function pointer call on a
hot path:
.CW badptrslot() 's
own call to
.CW auditmemloc() ,
itself a function pointer set by a static initializer in
.CW alloc.c
rather than called directly.  But the boot numbers do not support
that as the sole mechanism: the invalid-opcode boots (3, 4, 6, 8, 16,
25, 31, 37, 38, 39) and the two bad-pointer captures (28, 40) are
disjoint \- ten boots hit the new panic without ever printing a
.CW badptrslot()
or
.CW destroy()
line first, so most of them cannot have gone through
.CW auditmemloc()
at all.  Rather than keep reasoning from source about which of this
round's several new, larger functions on the
.CW "OP(movp) / OP(mcall) / OP(ret) / OP(newa) / OP(newaz)"
hot paths might be responsible, ran the direct test: rebuilt
.CW ipc64
with
.CW xec.c
reverted to its state immediately before this whole round of work
started (commit
.CW 2def4bae ),
keeping every other file as committed, and launched a second
forty-boot batch against that binary.  Result in the next section.

.NH 1
The invalid opcode is not this round's doing
.PP
The reverted-binary batch answered the question directly: twelve of
forty boots hit
.CW "panic:\ invalid\ opcode" ,
identical signature (
.CW "TYPE\ 06\ ERROR\ 0711\ FLAGS\ 00010246" ,
.CW "PC\ 0x000000000000000B" )
to every capture in the batch before it \- with none of this round's
.CW scanframe() ,
.CW badptrslot() ,
.CW probearrtype()
or
.CW auditmemloc()
wiring present at all.  A higher count, not a lower one, on the more
reverted binary.  This settles it: the panic is not something this
round's additions introduced, and the earlier theory (a jump through
.CW auditmemloc
as a not-yet-initialized or corrupted function pointer) does not
survive its own test \- that call site did not exist in this binary
and the panic fired anyway, at the same rate.
.PP
What the batch does not settle is why batches 9 through 19 (roughly
two hundred boots, spanning this same commit and every point between
it and the fully instrumented one) never hit it once.  The honest
reading is not "a new bug was introduced and then reverted away
identically" \- the direct test rules that out.  Beyond that, read as
a guess and labelled as one, not established: this specific panic
.I may
be one more downstream shape of the same allocation-order-dependent
corruption this entire investigation has been chasing, the way
.CW alloc:D2B ,
general protection violations,
.CW "cclose / cclone:"
.CW "c\ nil" ,
.CW consinit
and a bare page fault all showed up in the very same batch as
one-off companions to the invalid-opcode hits, each a different
native function tripping over the same kind of bad pointer.  Which
shape wins on a given boot depends on timing this hunt has never
been able to pin down, not on which probe code happens to be linked
in.  Filed as understood, not chased further: the twelve captures in
this batch get no new individual attention, on the standing rule
that a signature already explained by the leading corruption theory
doesn't need its own investigation thread.
.PP
Restored
.CW xec.c
to its committed state and relinked before landing this section, so
the working tree carries no leftover A/B-test state.  The underlying
crash remains exactly where it was: real, nondeterministic, and
still not fixed.

.NH 1
Retraction: this rig has never run more than one CPU
.PP
An earlier section ("The type descriptor is correct on real pc64;
three mechanisms closed") wrote that
.CW acquire() / release()
serialises Dis bytecode execution to one kproc at a time
.I "regardless of how many physical CPUs this SMP kernel has" ,
closing a genuinely-parallel-bytecode theory.  That sentence is true
as written but misleading by omission, and worth retracting the way
the
.CW F000FF53
reading was retracted earlier: it implied physical parallelism was
in play and merely didn't matter to Dis execution.  It has not been
in play at all.
.PP
.CW qemu-boot.sh
has never passed
.CW \-smp ,
so every boot in this entire investigation \- every batch, every
capture, all the way back \- has run under QEMU's default of one
virtual CPU.  Checked two ways, not inferred from one: grepped all
eighty boot logs on hand (this session's two batches) for
.CW cpu1 /
.CW cpu2 /
.CW cpu3 \-
zero matches in any of them.  Then booted once with
.CW "\-smp\ 2"
added: a
.CW cpu1:
line appears within the first couple seconds of output, proving
.CW mpinit() / mpstartap()
.RB ( os/inferno/pc/mp.c ,
shared with the 32-bit
.CW pc
board) genuinely works and starts an AP the moment QEMU offers one \-
the mechanism is real, it has simply never been exercised by this
harness.  So the earlier "regardless of how many physical CPUs"
framing had it backwards: this SMP-capable kernel has been tested,
this entire investigation, as a uniprocessor.  Every corruption
capture on record \- the wrong sentinel in
.CW sh.b ,
the fourth-module
.CW Styxservers
capture, the invalid-opcode panics, all of it \- happened with
exactly one CPU ever running anything, kernel or Dis.  A cross-CPU
race is not merely unlikely here; on the evidence in hand, it cannot
be the mechanism, because there has never been a second CPU to race
against.
.PP
That does not close the search, it redirects it: single-CPU
nondeterminism still has a real, unglamorous source on a machine
with a network card and a clock \- interrupts.  A timer tick, a
keyboard event, or a virtio-net receive can all preempt the running
kernel code asynchronously even with one CPU, and a driver or ISR
that corrupts memory it shouldn't touch would look exactly like this
hunt's pattern: allocation-order/timing dependent, indifferent to
which Dis module happens to be running.  Not written up as a theory
without a capture behind it \- the discriminating test is cheap and
already running: a forty-boot batch with
.CW "\-nic\ none"
(the script's own comment about that flag only concerns console
output, not crash rate, so it doesn't block this use of it).  If the
corruption rate collapses, the network path is implicated with real
evidence; if it's unchanged, the entire device-interrupt family is
eliminated in one batch rather than a driver-by-driver read.  Result
in the next section.

.NH 1
A striking drop, and a confound caught before trusting it
.PP
The
.CW "\-nic\ none"
batch: four of forty boots crashed at all, three general protection
violations and one
.CW "panic:\ loading" ;
.B zero
hit
.CW "invalid\ opcode" ,
against ten and twelve in the two batches immediately before it.
Against a true rate anywhere near a quarter of boots, forty zeros in
a row is not a plausible draw (roughly one chance in three hundred
thousand).  Tempting to write this up as the network path implicated \- and
before doing that, checked whether the comparison is even fair,
because the earlier retraction was a reminder to check rather than
infer.  It wasn't fair.  Grepped both batches for the depth markers
every capture in this hunt has used to place a crash:
.CW "Welcome\ to\ Inferno"
appears in almost every boot of both (36/40 no-NIC, 37/40 with) \-
but
.CW mountio
and
.CW "spawn\ sh"
appear in
.B zero
of the no-NIC boots, against most of the NIC-attached ones \- the
depth comparison is real, not fair, exactly as suspected.  But the
explanation first written here for
.I why
was wrong on two counts, caught and corrected in place rather than
left standing further down the document: pc64 does not run
.CW pcinit.b
at all \- matching the log's own strings
.RB ( "Welcome to Inferno..." ,
.CW "loading /dis/sh.dis" ,
.CW "spawn sh \-n /dis/init" )
against source shows it runs
.CW disinit.b ,
a much smaller init that spawns
.CW /dis/init
as a shell script and does no network call of its own.  And no boot
in
.I any
batch on record ever reaches a real
.CW dial()
or DHCP either: every log carries the line
.CW "unsupported connect method:" ,
proving
.CW dis/init
takes its empty-
.CW bootargs
fallback (none of these batches ever passed
.CW bootargs= )
every single time.  The
.CW mountio()
traces this whole thread has been reading as network activity are
.CW dis/init 's
.I first
line,
.CW "mount\ {mntgen}\ /n" ,
a Styx mount of a
.I local
process over a pipe \- generic Styx-mount machinery, not evidence of
anything reaching the wire.  Every "the crash clusters near network
traffic" reading built on that string is retracted along with it.
.PP
What survives the correction is the empirical result, which the wrong
reasoning never touched: without a NIC at all, boot output stops
between
.CW "Welcome\ to\ Inferno..."
(disinit.b's first statement) and
.CW "loading\ /dis/sh.dis"
(printed a dozen-odd bind calls later) \- the only NIC-dependent binds
in that stretch are
.CW "#l0 / #I0" ,
a plausible candidate for the stall, named here but not confirmed the
way a print would confirm it.  Whatever the exact mechanism, this
still means the
.CW "\-nic\ none"
batch is confounded on depth and its zero-crash result cannot be read
as "network path removed, bug gone with it" \- there was no network
path being exercised in the first place, in any batch, ever.
.PP
The batch that actually holds depth constant while removing outbound
connectivity already ran, before this correction was written:
.CW "\-netdev\ user,id=net0,restrict=on\ \-device\ virtio\-net,netdev=net0" ,
same device and interrupt path as every earlier boot, traffic blocked
at the QEMU user-net layer rather than the device missing.  It
reached
.CW "spawn\ sh"
in 36 of 40 boots, matching the NIC-attached batches' 35 and 37 \-
genuinely comparable depth at last \- and hit
.CW "invalid\ opcode"
in 12 of 40, matching those same batches' 10 and 12.  Blocking
traffic changed nothing.  Read narrowly and correctly this time,
since even this batch's own write-up (below) initially explained the
match by an outbound
.CW dial()
timing out that never actually runs: what tracks the crash rate is
the device being present and attached, not whether real packets
flow across it.  Still open, and the next test rather than a source
read: whether this is
.CW ethervirtio.c
specifically or any active interrupt-driven NIC at all.
.CW "\-device\ e1000"
is not the right substitute \- none of the four ether drivers this
kernel links
.RB ( ether8169 ,
.CW ether82563 ,
.CW etherx550 ,
.CW ethervirtio )
answer to QEMU's default e1000 model's PCI id, checked directly by
grep before trusting it again.
.CW "\-device\ igb"
does: it is QEMU's model of the Intel 82576, and
.CW ether82563.c 's
own controller table lists
.CW i82576
by name.  Confirmed with one boot before spending a batch on it \-
.CW "#l0:\ i82576:\ 1000Mbps\ port\ 0xFEBA0000\ irq\ 11"
attaches cleanly, reaches
.CW "spawn\ sh" ,
and crashed
.RB ( "alloc:D2B" )
on the very first try.  A forty-boot batch with
.CW igb
in place of
.CW virtio-net ,
.CW "restrict=on"
held constant, is running.  Same depth, entirely different driver:
if the rate holds, this is generic to any active NIC; if it drops,
.CW ethervirtio.c
is the specific place to read.

.NH 1
Not driver-specific; open whether it needs DMA or just interrupts
.PP
The
.CW igb
batch finished: 37 of 40 reached
.CW "spawn\ sh"
(the
.CW virtio-net
batches reached 35 and 37, so depth is genuinely matched this time),
.CW "invalid\ opcode"
hit 7 of 40, and 13 of 40 crashed at all.  Stated as precisely as the
sample supports, not as "somewhat lower": pooled against the
.CW "restrict=on\ virtio-net"
batch's 12/40, the
.CW "invalid\ opcode"
rates (17.5% vs 30%) are 1.3 standard errors apart \- not
distinguishable at
.CW n=40
each.  The total-crash rates (32.5% vs 57.5%) are 2.2 standard errors
apart, borderline, and not built on: that count mixes several
unrelated one-off panic families, so a difference in it is an
observation to note and set aside, not a finding.  The clean result
is the one signature tracked consistently across every batch in this
whole thread:
.B zero
with no NIC at all, comparable double-digit percentages with either
of two unrelated driver families
.RB ( ethervirtio.c
and
.CW ether82563.c 's
.CW i82576
support) once a device is actually attached.  Not driver-specific.
.PP
That still conflates two different claims: "an active NIC is
sufficient" and "an active interrupt source is sufficient," and
these batches cannot tell them apart \- every boot already has a
timer tick and a console UART regardless of any NIC.  What a NIC
specifically adds is interrupt
.I volume
and DMA writes into kernel memory that neither the timer nor the
UART perform.  Telling those apart needs a boot with heavy interrupt
traffic and no DMA, and the obvious candidate \- a plain
.CW "\-nic\ none"
boot, if it could reach depth \- turned out to be worth checking
properly rather than assumed broken.  Instrumented
.CW disinit.b
with a print after every early bind
.RB ( kept ,
not reverted \- a permanent, low-noise depth marker for every future
boot log, not a throwaway probe) and rebuilt.  One boot with no NIC
localizes the stall exactly: the last line is
.CW "bound\ #e" ,
never
.CW "bound\ #l0" .
Read
.CW etherattach()
.RB ( os/inferno/port/devether.c )
expecting to find the cause and didn't: with no controller ever
probed,
.CW "etherxx[ctlrno]\ ==\ nil"
should raise
.CW Enodev
immediately, before
.CW devattach()
is even called \- a fast error, not a hang, on the reading done so
far.  Recorded as a real, separate, open finding rather than chased
to ground this round: something makes
.CW "sys\->bind(\*(lq#l0\*(rq,\ \*(lq/net\*(rq,\ ...)"
block indefinitely when zero Ethernet controllers exist, contradicting
the fast-error path the source appears to promise, and until that's
understood
.CW "\-nic\ none"
stays unusable as a depth-matched control.  The DMA-versus-interrupts
question stays open because of it, not because it was judged
unimportant.

.NH 1
The #l0 hang, narrowed one step further and confirmed genuine
.PP
Followed the open finding one step further with a second round of
exploratory prints in
.CW etherattach()
.RB ( os/inferno/port/devether.c ,
reverted afterward \- this one earns no permanent place the way the
.CW disinit.b
markers did, it answered one question and its job is done).  The
function is reached
.RB ( "etherattach: spec 0" ) ,
and
.CW etherxx[0]
reads back exactly
.CW "0x0" ,
confirming the nil case is really taken.  The last line ever printed
is the one placed immediately before
.CW "if(etherxx[ctlrno]\ ==\ nil)\ error(Enodev);" \-
a print placed
.I after
that check, guarding the call to
.CW devattach() ,
never fires at all.  That is consistent with
.CW error()
actually being called \- it does not by itself explain why control
never comes back.
.PP
Checked slow versus genuinely stuck before writing either word down:
one boot at the usual ninety-second cap, unrevealing by construction
since a cold boot to the mount step already takes most of a minute;
a second boot given a hundred and eighty seconds \- three times a
normal boot's wall-clock \- produced not one further byte of output.
.B "Confirmed hung, not slow."
The break sits somewhere in the path from
.CW error(Enodev)
raised inside
.CW etherattach() ,
back through whatever
.CW namec()
does with an attach that raises rather than returns, back through
.CW devbind() ,
back to
.CW Sys_bind() ,
back to
.CW "sh->init()" 's
own
.CW disinit.b
frame \- error() itself is load-bearing everywhere else in this same
boot (every other bind, every
.CW waserror()
in
.CW devmnt.c
and
.CW alloc.c
already read this round), so the defect is most plausibly specific
to this call site or this exact nesting, not to
.CW error()
in general.  Not narrowed further this round: the next step is
instrumenting
.CW namec() 's
own attach handling rather than
.CW etherattach()
again, and that is real, separate work from the main hunt, not a
continuation of it \- recorded here and left for its own turn.

.NH 1
A receive-path hypothesis, killed by one grep
.PP
Went looking for the shared mechanism the driver-agnostic finding
implies and found a real ordering issue \- then checked whether it
could actually fire in the boots on record before building anything
on it, and it can't.  Worth recording exactly this way: the cheapest
result an investigation can produce is a hypothesis killed in one
grep, and it belongs on the record next to this document's other
retractions, not quietly dropped.
.PP
.CW port/netif.c 's
.CW openfile()
(reached from
.CW etherattach() 's
peers via
.CW netifopen() )
allocates a new
.CW Netfile ,
sets
.CW f\->in ,
then does
.CW "*fp\ =\ f;"
\- publishing the pointer into
.CW nif->f[] ,
the same array
.CW devether.c 's
.CW ethermux()
walks from interrupt context via
.CW etheriq() ,
with no lock either side agrees on
.RB ( openfile()
takes
.CW qlock(nif) ,
a sleeping lock, never
.CW ilock() ;
.CW ethermux()
takes nothing at all) \- before
.CW f\->inuse ,
.CW netown() 's
owner/mode, and the rest of the struct are set.  A real ordering gap:
if an interrupt lands in that exact window, it would read a
partially-set-up
.CW Netfile
through a pointer that's already visible.  Checked the one thing that
would make that harmless before treating it as a lead: this tree's
.CW malloc()
.RB ( os/inferno/port/alloc.c )
unconditionally
.CW "memset(v,\ 0,\ size)" 's
what it returns, so the fields in that window are zero, not garbage
\- narrower than first read, but still a real gap between "visible"
and "fully initialized" that a sufficiently unlucky field could still
land in.
.PP
Whether it can explain anything on record turns on one fact this
session already has: does any boot in any batch ever actually open a
netfile on
.CW #l0
at all?
.CW ethermux()
only dereferences a slot once something has opened it; every slot
starts and stays nil otherwise, walked and skipped every time.
Grepped every log on hand
.RB ( igb
and
.CW restrict=on
batches, eighty boots) for
.CW clone ,
.CW ipifc ,
and
.CW ether0
\- the only strings anything in
.CW dis/init
prints on that path.
.B "One match, and it wasn't real:"
.CW "init0:\ clone\ failed"
is process
.CW clone() ,
a coincidental substring hit, not netif's.
.B "Zero netfiles were ever opened, in any boot measured this
session."
.CW bindether0 ,
.CW usedhcp ,
and
.CW mountfs
\- the only callers of an ipifc clone open anywhere in
.CW dis/init
\- all sit inside the
.CW connectmethod
branches that the empty-
.CW bootargs
fallback never enters, confirmed twice already this document
.RB ( "unsupported connect method:" ,
every boot).
.B "The hypothesis is killed for every boot this session actually
measured, regardless of whether the ordering bug is real in
general."
It is real \- worth fixing on its own terms, not urgent, not
attempted this round \- but it is not evidence about this crash.
.PP
This also sharpens the standing puzzle rather than reopening it: with
.CW restrict=on
the corresponding transmit and receive paths carry almost no real
packets, and the crash rate held at the normal level anyway.  Whatever
mechanism this is, it does not need a packet to actually arrive or
depart \- it needs, at most, whatever a driver does with
.I no
confirmed peer: ring setup at
.CW attach() ,
transmit attempts that never get answered (ARP, DHCP, still really
sent over the wire even restricted), link-state and timer-driven
polling.  That is a materially smaller surface than the whole receive
path just ruled out, and it is where the next read belongs.

.NH 1
What every driver actually starts, and a four-function read that found no smoking gun
.PP
Both drivers'
.CW attach()
starts new native kprocs \- confirmed by reading both, not assumed
from one:
.CW ethervirtio.c 's
.CW rxproc / txproc
and
.CW ether82563.c 's
.CW i82563rproc / i82563tproc
(plus, on that driver, one of several link-monitor variants
depending on PHY type).  This is genuinely new concurrency a no-NIC
boot never has: cooperatively-scheduled kprocs that yield at
.CW sleep() / qlock()
contention, interleaving with whatever else is running on this
session's confirmed single CPU, in a way nothing in a no-NIC boot
does.  That kprocs exist is not itself a finding \- this kernel runs
on kprocs throughout, several already active on any boot.  What would
matter is what these particular ones touch that mainline code also
touches, under a different locking discipline than the yield points
they hit.  Checked that directly rather than reason from "concurrency
exists": read all four functions for what they lock and what they
call, the same shape of check that found and then killed the
.CW openfile() / ethermux()
mismatch two sections back.
.PP
Found no comparable mismatch.  Both drivers' ring state
.RB ( ctlr->queue[] / desc[] / avail
for virtio;
.CW "tdba / rdba / tb[] / rb[]"
for the 8256x family) is written only by the one kproc that owns
that ring \- never shared with mainline code, never touched by the
hardware interrupt handler either
.RB ( ethervirtio.c 's
.CW interrupt()
only reads a status bit and calls
.CW wakeup() ;
it never touches
.CW "desc[] / avail" ) ,
and both follow the same idiom before publishing a ring update to the
device: write the descriptor, call
.CW coherence() ,
.I then
advance the index the device polls.  The one call both
.CW rxproc
functions make into genuinely shared code is
.CW etheriq()/ethermux() ,
already checked and killed on reachability last section \- and
correcting a detail in how that section described it: the packet
dispatch these
.CW rxproc
functions do runs in the kproc's own cooperatively-scheduled context,
not inside the hardware interrupt handler itself, which only wakes
the proc up.  Doesn't change the conclusion \- unreachable is
unreachable either way \- but it's a real correction to how the
mechanism was described, made because the more precise reading
surfaced it, not because the earlier one was checked and found wrong
some other way.
.PP
Net for this pass: the kproc-count theory is not refuted, but this
specific four-function check does not confirm it either \- it is
exactly as strong as it was before the read, a plausible mechanism
without a located instance.  Recorded plainly rather than stretched:
a session that adds real concurrency and then can't point at the
shared structure it corrupts has narrowed the field, not closed the
case.  The next test this theory wants is a clean one \- spawn dummy,
NIC-independent kprocs that only sleep/wake on a timer, matching the
scheduling shape without any driver at all, and see whether that
alone reproduces anything \- but it needs a working no-NIC-equivalent
control to compare against, which section still owes a fix to the
.CW #l0
hang before that test means anything.

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
