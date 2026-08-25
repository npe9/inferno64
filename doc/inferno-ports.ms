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
Reaching an interactive shell has not been observed: this test boots
.CW ipc64
directly with no disk or CD attached, and
.CW /dis/init 's
device-probing \-
.CW "mount\ {mntgen}\ /n" ,
the
.CW /dev/sd*
scan in
.CW showlocaldevs \-
throws array-bounds and fd-out-of-range errors that read as this
environment genuinely having no boot medium to find, not a further
kernel bug \- unconfirmed without a real disk image built against this
board's namespace to test against.
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
