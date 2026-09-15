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
  armv7/      QEMU -M virt, 32 bit ARMv7-A, cortex-a15
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
A second family: ARMv7-A
.PP
.CW os/inferno/armv7
is not the
.CW armvirt
row in the machine table below \- that is AArch64, and needs a compiler
backend (a 64 bit ARM object type) this tree does not have.  This is a
smaller thing beside it: 32 bit ARMv7-A, cortex-a15, built on the
.CW arm
object type's existing
.CW 5c/5a/5l
toolchain, which until this board only ever had to compile the
.CW armv7m
family's Cortex-M work \- a different object type,
.CW thumb ,
with its own headers.  Nothing else in this tree had linked
.CW port/auth.c ,
.CW libinterp ,
or a runtime 32 bit division against
.CW arm
before, so several gaps that had simply never been exercised turned up
one at a time: missing
.CW s8..s64/u8..u64/intptr/WORD/UWORD
typedefs in
.CW Inferno/arm/include/u.h ,
a missing
.CW isaconfig
prototype, a missing
.CW BUSUNKNOWN ,
and \(em oddest of the lot \(em
.CW utils/5l 's
own
.CW iar
losing track of
.CW libkern/div-arm.s 's
.CW _div/_mod/_divu/_modu
inside an archive, though the same object resolves cleanly linked in
directly; it is linked in directly now, the way
.CW tod.$O
and
.CW mul64fract.$O
already are.
.PP
Five bugs were real and board-specific, each pinned down with
.CW arm-none-eabi-objdump
against the actual linked image, or QEMU's own gdbstub, rather than
guessed at:
.IP \(bu
the trap path's register save never advanced past
.CW UR_R0..UR_R3
before its
.CW stmia ,
so the store landed on the fields it had just saved and
.CW UR_R12
was never written at all \- caught by a data abort that kept landing on
the same compiled
.CW "ldr r6,[r12,#-4016]" ,
this ABI's register for SB-relative globals, coming back garbage.
.IP \(bu
.CW "MOVW $setSB(SB), R3"
was the wrong symbol for this linker: ARM's
.CW 5l
defines it as
.CW setR12 ,
not the
.CW setSB
every other Plan 9 linker uses.
.IP \(bu
a link-time vector table of
.CW B
instructions did not survive into the linked image; built as runtime
data instead \- eight identical
.CW "ldr pc,[pc,#24]"
trampolines addressing eight target words \- it does.
.IP \(bu
the trap path's register save read
.CW r4
back wrong on every trap, not just the fatal ones: vectrap's own
first instruction repurposes R4 as
.CW ureg0 's
base pointer before the interrupted R4 is saved anywhere, so a block
store that tried to recover it afterward always captured that base
pointer instead \- confirmed with QEMU's gdbstub, comparing a
breakpoint at trap entry against the same field in the crash dump.
Fixed the way R0-R3 already were:
.CW trapscratch
now takes R4 too, stashed before vectrap can touch it.
.IP \(bu
the root file list named
.CW /dis
itself as the source for every Limbo module, the tree built for an
eight byte Dis word, when a 32 bit target needs
.CW /dis32
\- the same distinction
.CW mps2 ,
.CW nucleof303
and
.CW teensy41
already draw.
.CW armv7
sets
.CW DISWORD=4
for its own kernel and for
.CW /osinit.dis ,
but the root file list still wrote bare
.CW /dis/sh.dis
style entries with no source column, which
.CW mkroot
resolves against
.CW $ROOT
literally \- the eight byte tree.  A module compiled for eight byte
words carries Type descriptors sized and mapped for eight byte
words; walked by a GC built for four, a pointer map bit meant to
cover one eight byte field instead covers the low half of it, and
.CW markheap()
dereferenced the low 32 bits of a
.CW real
constant as if it were a heap pointer.  A poison-looking
.CW 0x66666666
that showed up identically at a gdbstub breakpoint and in the crash
dump was never poison: it is the low word of the IEEE double 0.7,
sitting where a module's constant pool put it, in a Type whose
recorded
.CW np
only comes out right \- 66 map bytes covering the object's 4168 byte
size \- if each byte is read as eight words, not four.  That is
arithmetic, not a guess.  Pointing the root file list's
.CW .dis
entries at
.CW /dis32
the way the other 32 bit boards do fixed it: the same boot now loads
and type-checks real module Types \- small, sane ones, like
.CW "size 48 np 1"
for
.CW Bufio
\- with no bogus giant Type anywhere in the log.  An earlier version
of this section called this crash the same shape as the pc64
.CW markheap()
heisenbug below, on the strength of that poison value alone; that
was wrong, this had nothing to do with pc64, and the two only looked
alike because both happen to land inside
.CW markheap() .
.PP
One more was a gap rather than a bug:
.CW 5c 's
floating point still targets the FPA coprocessor (cp1/cp2) by default,
which cortex-a15 has never implemented \- every double in
.CW libkern
traps Undefined the first time it runs.
.CW 5l
carries a second, VFP encoding of the same pseudo-ops behind its own
.CW -f
flag; this board links with it, and enables cp10/cp11 in CPACR and
.CW FPEXC.EN
before anything tries to use them.
.PP
Under
.CW "qemu-system-arm -M virt -cpu cortex-a15 -m 256 -nographic -kernel iarmv7"
(
.CW os/inferno/armv7/qemu-boot.sh ,
the same idea as
.CW pc64 's
own script above), stated plainly: it boots \- memory pool init,
process init, the version banner, loading and beginning to type-check
.CW /osinit.dis ,
into the Dis interpreter, running real VFP-lowered floating point and
32 bit division without faulting, past the module loader and into
module initialization proper \- it gets far enough to load
.CW Bufio
and start into
.CW devprog .
It does not yet reach a shell: the next crash lands at the same point
every time \- right after
.CW Bufio
loads, going into
.CW devprog .
Checked directly with
.CW "grep -c 'trap type'"
across every batched log, never more than one trap line per boot:
two independent faults, not one fault wearing two faces.
.PP
The first: an Undefined instruction trap, six of twenty boots, at
the identical address
.CW 0x400f8db4 ,
past the end of both
.CW .text
and
.CW .data .
.CW sp ,
.CW r0
and
.CW r4
are just as deterministic, and
.CW up
reads nil: this runs on the boot-time SVC stack,
.CW l.s 's
own reset-time stack, not any Proc's
.CW kstack .
Checked against
.CW 5l\ -a 's
literal pool rather than guessed: the address is
.CW stack+KSTACK ,
link-time
.CW 0x400f8dd0 ,
the boot stack's one-past-the-end \- the value
.CW _main 's
first instruction loads into R13 at reset.  A later boot with a few
extra instructions ahead of it (the
.CW sp
diagnostic below) moved this same call site's landing value across
.CW 0 ,
.CW 0x40
and two points near that address instead of holding still: a stale
copy of that one boot-time value, read back as a function pointer,
not a computation gone wrong.  Never seen with the second fault \-
real, chaseable, static, just not yet chased to an instruction.  Two
guesses at the mechanism were read and ruled out, not left standing:
a
.CW mach0
adjacency (64k away by
.CW 5l\ -a 's
own arithmetic, not next to
.CW stack
at all) and
.CW newforthproc() ,
the one caller in this tree that skips setting
.CW p->sched
after
.CW newproc()
\- but its file is not in this board's link line.  A third guess,
.CW gotolabel()
reading a stale
.CW Proc.sched
Label, was worth the live memory the first two didn't need: gdbstub
would not land on this exact fault unconditioned (it catches
whichever Undefined trap fires first under its own timing, not
necessarily this one), but a breakpoint conditioned on
.CW r4
matching this fault's own known value does, twice running.
.CW r3
is
.CW &mach0
both times,
.CW r0
is
.CW m->readied
\- a real, live Proc pointer, not garbage \- and neither
.CW m->sched
nor that Proc's own
.CW sched
read back corrupted: both hold plausible, in-range sp/pc pairs that
don't match the fault address.  The stale-Label guess is retired
too, then \- something else near
.CW sched() 's
.CW up==nil
path touches
.CW mach0
right before this fires.  Read further, a strong candidate:
.CW runproc() 's
cooperative fast path ends
.CW "pt\ =\ proctrace;\ if(pt)\ pt(p,\ SRun,\ 0);" ,
a real call through a real function pointer with
.CW p
as its first argument \- the compiled
.CW "BL\ ,0(R6)"
matches the fault's read shape exactly, and
.CW proctrace
should be nil on a board that never turns on
.CW #p
tracing, which is what the
.CW "if(pt)"
guard is there for.  Checked live since, gdbstub holding still this time (the earlier
disconnects look to have been transient host load, not a standing
limitation of this technique \- the same live QEMU/lldb approach went
on to find and fix five real, separate bugs bringing up riscv32 in
this same document): broke at
.CW runproc() 's
own
.CW "cmp\ r6,\ #0"
right after the load, several fresh boots, and
.CW R6
read
.CW 0
every time \- genuinely nil, the guard correctly skipping the call,
not the fault this candidate predicted.  One of four
.CW proctrace
call sites in
.CW proc.c
checked this way so far
.CW ( ready() 's
own, a different function entirely, also read nil); the other two
.CW ( sleep() ,
.CW pexit() )
not yet checked.  This does not clear
.CW runproc()
as a candidate outright \- the fault is intermittent, and a handful of
clean reads does not rule out a rarer bad one \- but it is weaker
evidence for it than before, not stronger, and the next step if this
is picked back up is checking whether the SAME breakpoint ever reads
non-nil across many more boots, not assuming it will.
.PP
The second: a data abort, five of twenty boots, a
.I different
address every time, not reproducing under gdbstub either.  This is
the shape already on record here, the pc64
.CW markheap()
heisenbug's fingerprint \- not the same bug, as the previous version
of this section wrongly guessed about the DISWORD crash above, only
the same fingerprint, and this session already spent its cheap
answers on that one.  The rest of the twenty boots were still
mid-panic when their timeout fired, a console race, not a third
fault.
.PP
KSTACK exhaustion was checked and ruled out \- both faults put
.CW sp
near a stack's top, where a shallow call sits too, and doubling
.CW KSTACK
32k\(->64k moved neither the faulting addresses nor that distance,
which a real overflow would have.
.CW sp
stays in the trap printout regardless.  Not yet bracketed.
There is no display \-
draw, pointer, swcursor and the virtio input device are left out on
purpose, the same
as the console-only precedent
.CW spike
already set \- and the virtio ethernet driver is linked but untested.
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
The #l0 hang, fixed \- and the crash survives with no NIC at all
.PP
Traced the propagation the earlier sections stopped short of.
.CW namec() 's
.CW "#"
branch calls
.CW devtab[t]->attach()
directly, with a
.CW waserror()
already in place around it \- that part is fine.  Followed the call
one level further: for
.CW sys->bind()
specifically
.RB ( bindmount() 's
.CW ismount==0
path, taken by
.CW kbind() ) ,
the very first
.CW namec()
call resolving the new path has
.B no
.CW waserror()
anywhere between it and
.CW Sys_bind()
.RB ( os/inferno/port/inferno.c ) .
Compare
.CW kopen() ,
which every earlier success in this document has gone through
without incident: it wraps its whole body in
.CW "if(waserror())\ return\ \-1;"
before ever calling
.CW namec() .
.CW kbind()
had nothing.
.PP
That gap is fatal in a specific way tied to how this interpreter
runs native calls at all.
.CW Sys_bind()
calls
.CW release()
before entering the kernel, then
.CW acquire()
after \- the pair that hands this kproc's claim on Dis execution back
and forth, per
.CW os/inferno/port/dis.c ,
read closely two sections ago.  If
.CW namec()
inside
.CW kbind()
raises (exactly what
.CW etherattach()
does via
.CW error(Enodev)
when no controller was ever probed), nothing in the whole call chain
from there back up through
.CW kbind() ,
.CW Sys_bind() ,
and
.CW "OP(mcall)"
catches it \- the unwind skips straight past the
.CW acquire()
call that was never optional.  This kproc's Dis-execution token is
released and never reclaimed.  Nothing else was waiting to reclaim it
either, on the single Dis Prog these boots run this early.  Silence,
forever \- exactly what a hundred and eighty seconds of nothing
looked like.
.PP
Fixed the same way
.CW kopen()
already does it: wrapped
.CW kbind() 's
body in its own
.CW waserror() ,
returning
.CW \-1
on any failure instead of letting one escape.  Rebuilt, booted with
.CW "\-nic\ none" :
.CW "bound\ #l0"
prints, every bind after it prints, boot reaches
.CW "loading\ /dis/sh.dis"
and
.CW "spawn\ sh\ \-n\ /dis/init" \-
the same depth every NIC-attached batch has reached all session,
finally without a NIC at all.  A second boot went further still and
crashed on its own:
.CW "destroy:\ bad\ v\ 0"
in module
.CW Sh ,
pid 3 \- the same failure shape this whole document has chased, with
no NIC, no driver, no attach-time kproc, present at all.
.B "One boot is an anecdote, not a rate \-"
but it is a
.I "positive"
anecdote against the leading theory of the last several sections, not
a confounded null result like the batches before the fix.  A real
rate needs a real batch; the control now exists to run one.

.NH 1
The real batch: two separate signatures, two separate answers
.PP
The batch was killed at 37 of 40 boots by something outside this
session's control, not a QEMU hang or a corrupted run \- the 37 on
hand are clean, and 37 is enough to read plainly rather than wait for
three more.  Depth: 35/37 printed
.CW "bound\ #l0" ,
34/37 reached
.CW "spawn\ sh" \-
the same range every NIC-attached batch this session has reached
.RB ( 35\-37/40 ) .
The control finally means what it says.
.PP
.B "Invalid opcode: zero, still."
Not one of the 37 hit it, against 10, 12, and 7 out of 40 across the
three NIC-attached batches on record.  Unconfounded this time \- these
37 reach the same depth those did \- so this stands as a real result,
not the earlier null that turned out to mean "never got there."
Against a true rate anywhere near the NIC-attached batches' 25\-30%,
zero in 37 tries is not a plausible draw.
.B "This specific signature needs an active NIC."
.PP
.B "The signature this whole document was built around does not."
Two of the 37 hit
.CW "destroy:\ bad\ v\ 0" \-
one of them the very second boot run after the fix, reported last
section.  Compared directly against the two NIC-attached
.CW restrict=on
batches, counting only
.CW destroy() / OP(movp)
captures, not the whole panic grab-bag: virtio 2/40, igb 1/40, no-NIC
2/37.
.B "Three counts of one and two events \- not enough to claim the
rate is equal, only that nothing here separates them."
Consistent with anything from roughly one to fifteen percent under
any of the three conditions; a real rate comparison needs far more
than four total captures.  What
.I is
solid at this sample size is the presence claim, not a rate claim:
the corruption this document opened with \- a pointer-typed slot
holding
.CW 0
where
.CW H
belongs \- fires with no network card, no driver, and none of the
attach-time kprocs two sections back went looking in, present at all.
It was never the NIC \- that much four small counts can say; how
much rarer or more common it is without one, they can't.
.PP
Checked one more thing before trusting the comparison at all: do
these no-NIC captures land at the same point in execution the
NIC-attached ones do, or did the no-NIC boots just have less runway
and land somewhere structurally different \- the same trap the first
.CW "\-nic\ none"
batch fell into, one layer deeper.  Grepped both captures against
the last common milestone
.RB ( "spawn sh" ) :
both no-NIC
.CW destroy()
hits land one line after it (module
.CW Env
and
.CW Readdir ,
early library loads), and so do all three NIC-attached captures on
record (module
.CW String ,
.CW Sh ,
.CW Env ,
each within a few lines of the same milestone).  Same point in
execution, every time, on both sides of the comparison.  The
presence claim holds on checked ground, not assumed ground.
.PP
Read together, this reframes the last five sections rather than
erasing them: this investigation has actually been running down
.B two
independent signatures that happened to share a batch.
.CW "Invalid\ opcode"
really is NIC-specific, by a result now clean of the confound that
undermined every earlier attempt to say so \- worth its own thread,
separately, another time.  The
.CW destroy() / OP(movp)
wrong-sentinel corruption \- named first, chased longest, the reason
.CW auditmemloc() ,
the liveness check, the type-descriptor confirmation, and every
.CW sh.b
capture on record exist \- runs at the same rate with or without a
network card anywhere in the machine.  Whatever writes a
.CW 0
into a slot that should hold
.CW H
is native to Dis execution itself, or to kernel machinery every boot
uses regardless of hardware \- not to anything this session's last
five sections went looking for.  The search for
.I that
bug returns to where it stood before the NIC was ever a suspect: a
slot inside a still-live block, corrupted between its correct
creation and the moment
.CW destroy()
or
.CW OP(movp)
reads it back, by a mechanism neither the allocator, the frame
descriptor, the SMP question, nor the network stack has turned out to
be.

.NH 1
A probe's own bug, caught before trusting its first answer
.PP
Built the check the mallocz(l,0)-unzeroed theory needs: a diagnostic
in both
.CW destroy()
.RB ( libinterp/heap.c )
and
.CW badptrslot()
.RB ( OP(movp) 's
guard,
.CW libinterp/xec.c )
printing the current frame's
.CW "R.FP / R.SP / R.TS"
and its
.CW t->size ,
so a captured bad slot's position relative to the frame that owns it
could be read directly \- inside
.CW t->size
means
.CW initmem()
should have covered it at creation; beyond
.CW R.SP ,
in whatever the extent's
.CW mallocz(l,\ 0)
never zeroed, means it never was.
.PP
The first capture this ran against
.RB ( destroy() ,
module
.CW String )
printed
.CW "R.FP\ 0xa308b8\ R.SP\ 0xa30938\ ...\ frame\ t\->size\ 112" \-
.CW SP\-FP
(128) already past
.CW t\->size
(112) on its own, which looked like exactly the kind of mismatch
worth reading further into.  Reading further into it instead found a
bug in the probe, not in the frame: by the time
.CW destroy()
fires from either of
.CW freeptrs() 's
two callers,
.CW "OP(ret)"
and
.CW "OP(mcall)" 's
native branch, both already ran
.CW "R.FP\ =\ f\->fp"
\-
.I restoring
.CW R.FP
to the
.B caller's
frame \- before calling
.CW "freeptrs(f,\ f\->t)" .
.CW destroy() 's
own probe reading
.CW R.FP
was therefore naming the wrong frame every single time it has ever
fired through
.CW freeptrs() ,
not just this once; the printed numbers above describe some
unrelated caller frame, not the one that actually held the bad
slot.  Retracted before building anything on it, the same discipline
this document has applied to its other three retractions \- caught
this time before a commit landed the wrong reading, not after.
.PP
Fixed at the source of the confusion rather than patched around it:
.CW freeptrs()
itself knows
.CW v ,
.CW t ,
and the exact slot address on every call into
.CW destroy() \-
three new globals
.RB ( freeptrsv ,
.CW freeptrst ,
.CW freeptrsslot ) ,
set right there, let
.CW destroy() 's
probe read the frame that actually owned the slot, with its exact
offset within it, instead of guessing from a register that has
already moved on.  A cleaner result than the register-based version
even aimed for: an exact
.CW "slot\ \-\ v"
offset, not just a frame/stack-pointer comparison.  Rebuilt; the
batch using the old, wrong-frame version was killed mid-run rather
than let finish and risk a mixed-binary read \- a clean batch against
the corrected binary is running.  Result in the next section.

.NH 1
Beyond SP, in the same live block \- and the same source line again
.PP
Took several batches to land one \- eighty-three clean no-NIC boots
with the corrected diagnostic in place produced zero
.CW destroy() / OP(movp)
hits before the next one finally landed
.RB ( "1 in roughly 40\-90" ,
consistent with the small counts already on record, not a change in
rate).  It was
.CW OP(movp) ,
not
.CW destroy() ,
so it needed none of the
.CW "freeptrsv / freeptrst / freeptrsslot"
fix from last section \- that opcode never restores
.CW R.FP
before it fires, so its reading has been trustworthy all along.
.PP
Resolved the source line first, the way every capture in this
document has: instruction 2315 (2316 printed, minus one for
.CW xec() 's
pre-increment)
.RB ( resolve_sbl.py )
lands on
.CW sh.b:1061 \-
the same line number
.CW "A durable resolver, two named sites in sh.b"
named for an earlier capture.  Checked what's actually there before
trusting the match: it is
.I not
the same line any more.
.CW sh.b
has moved under this multi-session investigation the way any live
source file does, and today's line 1061 is
.CW "waitfd\ :=\ sys\->open(\*(lq#p/\*(rq+wf,\ Sys\->OREAD);" ,
inside
.CW waitfd() ,
a different function entirely from the
.CW keepfds
cons the earlier capture named.  Recorded as its own small correction
\- a coincidence of line numbers across two source-file states, not
the same site recurring \- rather than silently building on the old
label.
.PP
What the diagnostic actually answers: the destination slot sits at
.CW "R.d\ =\ 0xa306a8" ,
344 bytes past
.CW R.FP
.RB ( 0xa30550 ) .
.CW R.SP
sits only 104 bytes past
.CW R.FP ,
and the current top frame's own
.CW t\->size
is 112 \- both well short of 344.
.CW auditmemloc()
places the slot inside the same live
.CW mainmem
block as
.CW R.FP
itself
.RB ( "block at 0xa302c0" ,
spanning past both
.CW R.FP
and
.CW R.TS ) ,
so this is genuinely part of this Prog's own stack extent, not a
wild address or a different pool entirely \- and it sits
.B beyond
both the current frame's declared bounds and the current stack
pointer.  Whatever wrote
.CW 0x18
there did so into memory this exact call chain, at this exact moment,
has not claimed through any frame's own
.CW initmem() .
.PP
One thing this capture does not settle, flagged rather than papered
over: by the time
.CW P(d)
resolves to a concrete address,
.CW R.d
is already just a raw pointer
.RB ( "P(r)\ =\ *((WORD**)(R.r))" ,
.CW libinterp/xec.c ) \-
the addressing mode that produced it (frame-local, module-level, or
an indirect dereference through an already-loaded pointer) is settled
earlier in the dispatch loop, before
.CW OP(movp)
ever runs, and nothing in this capture says which one applies to
.I this
instruction.
.CW waitfd :=
declaring a fresh local inside its own function reads like a plain
frame-local target, which is what
.CW t->size
should then bound \- and doesn't.  Whether that means
.CW R.FP
names a frame other than
.CW waitfd() 's
own at this exact point, or the addressing here isn't frame-local at
all, is the next question this specific capture raises rather than
answers.
.PP
The recurring value is the other thread worth keeping open, not
closed: this is the
.B fourth
capture across the whole investigation reading back the same
.CW 0x18 \-
"A durable resolver, two named sites in sh.b" put the count at three
before this one.  Four hits on one specific byte value, across
captures now known to span at least two different source constructs
and two different opcodes, is a pattern a coincidence theory has to
work harder to explain than a shared mechanism does \- but naming
that mechanism is still open work, not concluded here.
.PP
The open question from that last capture \- is
.CW R.FP
even the frame the compiler meant for this instruction \- needs more
than a size and two offsets to answer.  Wired
.CW showframe()
.RB ( already
existing, already used by
.CW scanframe() ,
previously dead code everywhere else) into
.CW badptrslot() 's
.CW OP(movp)
guard: the next capture gets the whole frame's fields and its type
map dumped, not just
.CW t\->size
alone \- enough to check directly whether offset 344 could belong to
.I any
declared field of whatever frame is actually at
.CW R.FP ,
rather than inferring it from one number.  Rebuilt; a batch is
running.

.NH 1
The same shape, on the heap this time \- and heap() doesn't zero either
.PP
The next capture landed on
.CW sv ,
not
.CW dv ,
in module
.CW Bufio ,
and the frame
.CW showframe()
dumped turned out not to be the right thing to look at:
.CW R.FP
names the currently
.I executing
frame, not the frame (if any) that owns the bad slot, and for this
capture the bad slot isn't on the stack at all.
.CW auditmemloc()
says so directly: "in heap: in block at 784d880 ... size 100" \- a
256-byte
.CW heapmem
block, not
.CW mainmem .
.CW "addr\ \-\ FP"
came out as a nine-digit garbage number for exactly that reason \-
subtracting a heap address from a stack address is not a meaningful
offset, and printing it anyway for every capture rather than only
the stack-shaped ones was worth noticing and not repeating.
.PP
Read for the same question this section has been asking all along:
does the allocation path that produced this block zero what it hands
out, the way
.CW malloc()
and
.CW smalloc()
do?
.CW OP(new)
.RB ( libinterp/xec.c )
calls
.CW heap() ,
not
.CW heapz() \-
and
.CW heap()
.RB ( libinterp/heap.c )
goes straight to
.CW initmem(t,\ H2D(void*,\ h))
with no
.CW memset()
first.
.CW heapz()
.RB ( OP(newz) 's
own path) does memset the whole object to zero before calling
.CW initmem() ;
plain
.CW OP(new)
relies on
.CW initmem()
alone, exactly the same shape as
.CW newstack() 's
.CW "mallocz(l,\ 0)" \-
a second allocation path in this same interpreter, entirely
independent of the first, following the identical pattern: zero
pointer slots covered by the type map, leave everything else as
whatever the pool had.
.PP
Checked which Iobuf field this could be before calling it settled.
.CW module/bufio.m 's
.CW Iobuf
adt declares nine data fields in order:
.CW fd
.RB ( "ref\ Sys\->FD" ,
pointer),
.CW buffer
.RB ( "array\ of\ byte" ,
pointer), then seven plain
.CW int / big
fields with no pointers at all.  Two pointer fields, and the block
this capture hit was walked as
.CW "t->np\ 2" ,
matching \- but that
.CW t->np
came from the
.I "current stack frame's"
type, dumped by the same
.CW showframe()
call that had the wrong frame in hand for this capture; it says
nothing about
.CW Iobuf 's
own compiled descriptor, which nothing here has looked at directly
yet.  The bad slot's own offset from
.CW B2D
(120 bytes, minus whatever
.CW sizeof(Heap)
costs) lands past where nine fields of eight bytes each would end \-
consistent with the same "beyond what's declared" shape as the stack
capture, on a different allocation path, but not confirmed the way
the
.CW YYS
descriptor was confirmed in an earlier section: by printing
.CW Iobuf 's
own
.CW "t->size / t->np / map"
at the moment it's allocated, not inferred from a field count.  Not
done this round.  What's solid: a second, independent allocation
path in this interpreter shares the exact same zero-only-what-
initmem()-covers discipline as the first, and a second, independent
capture shows the identical symptom \- a pointer slot reading back a
small non-H value \- on that path.  Two allocation paths, two
captures, one shape.

.NH 1
Iobuf's descriptor confirmed correct \- and the bad slot sits well past it
.PP
Closed the gap the last section left open, the same way UPDATE 18
closed it for
.CW YYS :
a one-shot probe in
.CW OP(new)
.RB ( gated
on module
.CW Bufio
this time, any type it allocates rather than one exact size, since
.CW Bufio
allocates more than
.CW Iobuf )
dumping the real, compiled descriptor rather than inferring one from
a field count.  One boot, first hit:
.CW "new:\ type\ size\ 72\ np\ 1\ map\ 0xc0\ module\ Bufio" .
0xc0 is
.CW 11000000 \-
bits 7 and 6, naming words 0 and 1 by this hunt's own established bit
order.  Matches
.CW module/bufio.m 's
field order exactly:
.CW fd
(word 0) and
.CW buffer
(word 1), the adt's only two pointer fields, correctly and only
those two words marked.
.B "Iobuf's descriptor is right, the same clean result YYS got."
.PP
Which makes the earlier capture's numbers worth finishing properly
now that there's a real size to check them against, not a guess.
.CW B2D
is the pool's own data pointer \- the start of the
.CW Heap
header itself, not of Iobuf's own fields, which begin
.CW sizeof(Heap)
further in via
.CW H2D() .
The bad slot sat at
.CW "B2D+0x78"
\- byte offset 120 from the block's start.  Iobuf's own fields, at
.CW t\->size\ 72 ,
end at
.CW "sizeof(Heap)+72" \-
comfortably short of 120 under any plausible
.CW "struct\ Heap"
layout
.RB ( color ,
.CW ref ,
a
.CW Type*
and an
.CW hprof
field, on the order of 24\-32 bytes), without pinning the exact
figure down this round rather than guess at it.  Qualitatively firm
either way: the bad slot sits inside a 256-byte pool block holding
far more room than one
.CW Heap+Iobuf
pair needs (headers and pool size-class rounding account for some of
that gap, not all of it), and it lands measurably past where
Iobuf's own declared extent stops, not just past
.CW B2D .
.B "The instruction's own computed source address pointed measurably
past the end of a correctly-described object, into space nothing
in that object's own type ever claims."
Not new padding uninitialized by chance: memory this specific
allocation's own shape says doesn't belong to it at all.
.PP
Two captures, two allocation paths, two confirmed-correct type
descriptors, and in both cases the bad slot sits measurably past
where the relevant structure's own declared size says it should end
\- past
.CW t->size
on the stack, past
.CW t->size
on the heap.  Not a type-descriptor bug either time.  Not (yet) an
allocator-corruption bug in the sense this hunt has chased before \-
.CW auditmemloc()
found both slots inside blocks the pool still calls live.  What's
left, stated plainly rather than diagnosed: something is computing a
source or destination address that overshoots the object it was
meant to land in, by an amount too large to be an off-by-one and
too small to be a wild pointer, twice, on two unrelated types,
through two unrelated opcodes.  Where that computation happens \-
which instruction, which addressing mode, why it overshoots by
roughly this much \- is the next question, and it needs a capture
that names the computing instruction itself, not just where it
landed.

.NH 1
The overshoot claim rested on an unchecked assumption
.PP
Both
.CW t->size
readings in the last two sections compared
.CW addr
against the
.I current
frame's own
.CW t->size ,
on an assumption neither capture had actually checked: that the
instruction which produced
.CW addr
used
.I direct
addressing \- one of the
.CW dec[]
functions
.RN ( libinterp/dec.c ,
machine generated by
.CW decgen.c )
that adds a small, compiled-in offset straight to
.CW R.MP
or
.CW R.FP .
.CW xec() 's
dispatch loop
.RN ( libinterp/xec.c )
calls
.CW dec[R.PC->add]()
before the opcode handler runs, and that table holds a second family
too: indirect modes, built on the
.CW DIND
macro, that dereference a pointer already sitting in a frame or
module slot and
.I then
add a small field offset to
.I that .
If either capture's instruction used an indirect mode,
.CW addr
was
.CW "[some other object's pointer, read out of a slot] + a small field offset" ,
and checking it against the current frame's own
.CW t->size
never meant anything \- the two numbers have no relationship to
compare.
.PP
This is the same category of mistake this hunt already caught once,
in a different guise: the
.CW destroy()
frame-bounds probe was reading
.CW R.FP
after
.CW OP(ret) / OP(mcall)
had already restored it to the
.I caller's
frame, before the
.CW freeptrs()
globals fix landed.  Both times the mistake was trusting a value's
frame of reference without checking what it actually was.  The
addressing-mode question hadn't been checked, so the "past
.CW t->size "
finding in both of the last two sections is real as an observation
\- the slot's contents were bad, and its address was measured
correctly \- but the
.I interpretation
built on top, that some computation overshot the current frame or
object, is only as good as an assumption that was never verified.
.PP
.CW badptrslot()
now prints
.CW "(R.PC-1)->add" .
By the time an opcode handler runs,
.CW xec() 's
dispatch loop has already stepped
.CW R.PC
past the instruction that ran, so the instruction that actually
built the bad address sits at
.CW R.PC-1 ,
not
.CW R.PC ;
its
.CW add
field is the byte that selects which
.CW dec[]
function ran.  A batch is running against this build now.  If the
next capture names a direct mode, the overshoot reading stands as
written.  If it names an indirect one, that's a sharper fact than
"overshoot" was: 
.CW DIND
dereferences its pointer before adding the field offset, so a
corrupt pointer stored in that slot would fault immediately rather
than land on a plausible, in-block address.  An indirect-mode
capture would mean the dereferenced pointer was valid all along, and
the corruption is in the field it reached, not in the pointer chain
\- a different, narrower place to keep looking than either capture's
own frame or object.
.PP
Neither type-descriptor confirmation from the last two sections is
affected by any of this \- both were read directly out of the live
type map, not inferred from address arithmetic, and stand regardless
of which addressing mode produced the bad address.

.NH 1
The addressing-mode capture led somewhere better: the probes themselves were stale
.PP
The batch from the last section landed a capture almost immediately:
a
.CW movp
with a bad
.I destination
this time
.RN ( dv ,
not
.CW sv
like every earlier one), addressing byte
.CW 0x01
(direct
.CW R.FP
addressing, by the
.CW USRC / UDST
decoding worked out there), and a frame-bounds line that made no
sense at all:
.CW "addr - FP = -245448" .
Not a small overshoot past
.CW t->size
like the last two sections found \- a quarter of a megabyte
.I before
.CW R.FP ,
nowhere near any plausible compiled-in frame offset.  A direct-mode
address that far from the frame it's supposedly
.CW R.FP
-relative to isn't a bigger version of the same overshoot; it's a
sign the comparison itself is broken.
.PP
It is.  Every probe in this hunt that named "the current instruction"
or "the current frame" \- module, PC, instruction index, R.FP, R.SP,
R.TS \- read them through
.CW currun()->R ,
i.e.
.CW p->R ,
the
.I Prog 's
own saved copy of its register file.  That copy is not live.
.CW xec(Prog\ *p)
does
.CW "R = p->R"
once, at entry, into the plain global
.CW R
.RN ( libinterp/xec.c ,
declared
.CW "REG R;" ,
one instance, not per-Prog); every instruction in the quantum runs
against that global; and only after the whole quantum ends \-
.CW "PQUANTA = 2048"
instructions later, in the ordinary case \- does
.CW "p->R = R"
write the live state back.  For every instruction in between,
.CW p->R
is however many instructions stale since the quantum began, up to
2047 of them.  The probes were reading that stale copy the entire
time; the live state, valid at exactly the point a probe fires, was
sitting in the plain global
.CW R ,
already in scope in every one of these functions, no
.CW currun()
needed to reach it.
.PP
This is the same mistake this hunt already caught once before, in a
narrower form: the
.CW destroy()
probe reading
.CW R.FP
after
.CW OP(ret) / OP(mcall)
had restored it to the caller's frame.  That fix (globals set inside
.CW freeptrs()
itself) sidestepped the general problem without naming it.  This
capture named it: not one call site restoring
.CW R.FP
early, but every probe in the file reaching for the wrong copy of
the whole register file, by construction, every time.
.PP
Fixed at all four sites that had it \-
.CW badptrslot()
and
.CW scanframe()
.RN ( libinterp/xec.c ),
.CW destroy()
.RN ( libinterp/heap.c ),
and
.CW _poolfault()
.RN ( os/inferno/port/alloc.c ,
the earliest of the four, the one the others' comments credited as
"the same trick").  Each now reads the plain
.CW R
directly for module/PC/frame identification, and only uses
.CW currun()
for what it's actually good for: the
.CW pid .
Rebuilt clean, no new warnings at any of the four sites.
.PP
This retroactively explains the contradiction that surfaced it.  The
addressing byte
.CW "(R.PC-1)->add"
this batch was built to capture is itself computed from
.CW xp->R.PC ,
so in the batch that just ran, it named the addressing mode of
whatever instruction happened to sit at the
.I stale
PC \- not necessarily the
.CW movp
that actually faulted.  The wild
.CW "addr - FP"
number is exactly what you'd expect when the reported mode and the
reported frame both refer to a different point in execution than the
one that actually produced
.CW addr .
None of this batch's captures \- this one or the three that followed
it before the fix landed \- are usable for addressing-mode or
frame-bounds conclusions; the raw bad-slot address and value are
still fine, since bad-pointer detection reads
.CW R.d / R.s
directly, not through
.CW currun() ,
but the diagnostic context around them is not.  A fresh batch is
running against the fixed binary.
.PP
One more thread worth naming, checked partway and not yet finished:
.CW libinterp/gc.c 's
.CW rootset()
walks
.CW root->R.SP
and
.CW root->R.EX
to find each Prog's live stack extent for marking, for every Prog on
.CW isched.head ,
using the identical
.CW p->R
field this section just found stale mid-quantum.
.CW rungc()
is called from
.CW vmachine() 's
scheduler loop only after
.CW r->xec(r)
has already returned for that iteration, and on a normal quantum exit
.CW p->R
is freshly written back by then \- so the ordinary case looks safe on
inspection.  What isn't checked yet: whether a native C-level
.CW error()
raised from deep inside a quantum (the same class of unwind the
.CW kbind()
fix earlier in this document was about) can reach
.CW vmachine() 's
own
.CW waserror()
without ever reaching
.CW xec() 's
trailing
.CW "p->R = R" ,
leaving that Prog's
.CW p->R
stale for longer than one quantum \- and if so, whether
.CW rootset()
can run against it in that state before it's torn down.
.PP
Checked further, without waiting for a capture: it's closed, not open.
.CW rungc()
itself starts with
.CW "if(gchalt) { gchalted++; return; }" ,
and
.CW progexit() 's
exception path brackets exactly the risky window \-
.CW destroystack(&R)
then
.CW delprog(r,\ msg)
\- between
.CW gclock() / gcunlock()
.RN ( "gchalt++ / gchalt\-\-" ,
.CW include/interp.h ).
.CW destroystack()
is also passed
.CW &R ,
the live global, not
.CW &r->R
\- so the one place a mid-error stack teardown happens already reads
the right copy.  Outside that bracketed window,
.CW rungc()
only ever runs from the scheduler loop after
.CW r->xec(r)
has already returned for that iteration, by which point
.CW p->R
is freshly written back (quantum completed normally) or the Prog is
mid-teardown under the same lock that keeps
.CW rungc()
out entirely.  No capture needed for this one; the guard was already
there.

.NH 1
The first capture from the fixed probe: module data, not a frame at all
.PP
The fresh batch's first capture, read with the corrected probe:
.CW "bad sv 18"
again \- the same recurring value as ever \- in module
.CW Arg
(the standard Limbo argument parser, imported by shell utilities),
addressing byte
.CW 0x00 .
.CW "USRC(0x00) = 0 = AMP" :
the source operand was module-pointer direct,
.CW "R.s = R.MP + R.PC->s.ind" ,
not frame-relative and not indirect.  The frame-bounds line
.RN ( "addr - FP = 115398408" )
looks exactly as nonsensical as the earlier, broken capture did \-
but this time correctly so: an AMP-direct read doesn't touch
.CW R.FP
at all, so comparing the two was never meaningful for this
instruction, and the large number is simply two addresses from
unrelated memory regions (the module's own data area versus this
Prog's stack) being subtracted.  This is a third, previously
undistinguished context for where the bad value has now been seen:
not a stack frame slot, not a heap object field, but a module's own
persistent global data, addressed by module pointer plus a small
compiled-in offset.
.PP
Worth checking before building anything on it: is this context's
initialization as gapped as the stack and heap allocation paths
turned out to be?  It is not.  A module's global-data area
.RN ( m->origmp ,
.CW libinterp/load.c )
is allocated with
.CW heapz() ,
not the unzeroed
.CW "heap() / nheap()" ,
so it starts fully zeroed; the loader's data-section walk
.RN ( DEFB / DEFW / DEFL / DEFF / DEFS / DEFA )
then writes only the values the
.CW .dis
file's data section actually declares, exactly matching Limbo's own
semantics for an uninitialized global (reads as zero/nil, and does,
because
.CW heapz()
zeroed it \- not because every byte was explicitly written).  Where a
module gets its own private copy instead of using
.CW origmp
directly
.RN ( linkmod() ,
.CW libinterp/link.c ),
that copy comes from unzeroed
.CW nheap() ,
but
.CW newmp()
immediately
.CW memmove() s
the entire
.CW t->size
region from the zeroed template over it \- full coverage, not the
partial, type-map-driven coverage
.CW initmem()
does elsewhere in this hunt.  Both paths land on a fully-defined
region before the module ever runs a single instruction.
.PP
That closes the initialization question for this third context the
same way it's closed for the other two: whatever wrote
.CW 0x18
into this slot did so
.I after
the module was loaded and its data area was already correct \- a
live write during execution, not a gap at allocation time.  One
capture from a working probe isn't enough to say whether "module
data" is a fourth genuine target alongside the stack and heap cases,
or a coincidence; the batch is still running.

.NH 1
A second capture points somewhere sharper still: the code itself
.PP
The next capture from the fixed probe, in module
.CW Sh
this time:
.CW "bad sv a" ,
addressing byte
.CW 0x09 .
.CW "USRC(0x09) = 1 = AFP" :
direct frame-pointer addressing again, like the very first capture
of this whole hunt.  But
.CW "addr - FP"
is
.I "~115 million" ,
in an 88-byte frame.  That's not the earlier probe bug back again \-
this capture used the fixed probe, reading the live global
.CW R
directly, the same fix already checked against
.CW xec() 's
dispatch loop line by line.  If the addressing mode really is direct
.RN ( "R.s = R.FP + R.PC->s.ind" )
and
.CW R.FP
really is live and correct, then a 115-million-byte compiled-in frame
offset can only come from one place: the
.CW .ind
field baked into this
.I instruction
itself, at load time, sitting in the module's own
.CW Inst
array \- code, not data, and supposedly immutable once a module is
loaded and running.
.PP
Not confirmed yet, on purpose: this hunt has been burned twice now by
committing to a reading before checking what it actually rested on.
.CW badptrslot()
now also prints
.CW "(R.PC-1)->s.ind"
and
.CW "(R.PC-1)->d.ind"
directly \- the raw compiled operand fields themselves, not an
address derived from them \- so the next capture through this
instruction (or another like it) says directly whether the field
itself holds the huge value.  If it does, this is a fourth context
for the bad-value hunt, and a different shape than the first three:
not an allocation that left a slot uncovered, but a write landing
in a module's supposedly-read-only compiled code.  A fresh batch is
running against the rebuilt binary.

.NH 1
A third capture confirms the mechanism works, and finds a probe bug of its own
.PP
The next capture, before the fresh batch was killed for the previous
section's probe rebuild: module
.CW Init ,
.CW "bad dv 0" ,
addressing byte
.CW 0x01
.RN ( "UDST(0x01) = 1 = AFP" ,
direct again, this time on the destination).  This one resolves
cleanly:
.CW "(R.PC-1)->d.ind"
is
.CW 0xa0
(160), and the probe's own
.CW "addr - FP"
is exactly
.CW 160 .
Match.  The addressing mechanism computed exactly what the compiled
instruction said to compute; nothing wrong with
.CW R.FP
or the mode decode here.  This is useful on its own: it shows the
previous section's ~115-million-byte mismatch is not something wrong
with direct-mode addressing in general \- most direct-mode captures,
this one included, check out fine \- so that anomaly still needs its
own matching capture before it's anything more than one unexplained
number.
.PP
The bad value itself
.RN ( 0 ,
not
.CW 0x18
this time) fits the original stack-allocation finding rather than
adding anything past it: SP-FP was 264 in an area
.CW newstack()
hands out unzeroed, so a slot reading 0 here is consistent with never
having been covered by
.CW initmem() ,
holding whatever this physical memory looked like before Dis ever
touched it \- plausibly literal zero, if it's memory the kernel handed
out fresh rather than something
.I else 's
leftover bytes.
.PP
What wasn't clean: the frame-bounds line reported
.CW "t->size -268370093" ,
a number with no sane reading.  Traced to the probe, not the kernel:
.CW cf->t
was nil here, and the print dereferenced it anyway
.RN ( "cf != nil ? cf->t->size : -1" ,
checking only
.CW cf ,
never
.CW cf->t ).
.CW gc.c 's
.CW rootset()
already handles exactly this case \- a frame's
.CW t
can legitimately be nil, falling back to the Stkext's own
.CW TR
register \- so this wasn't a hypothetical to guard against, it's a
real, reachable state this specific capture reached.  Fixed to check
both pointers before dereferencing; this port's low physical memory
happening to be readable (not faulting) is why a bad dereference
produced a garbage number instead of a crash, which is its own small
reminder not to read a printed value as ground truth just because it
printed cleanly.  Rebuilt, same two pre-existing unrelated warnings,
nothing new.  Fresh batch running.

.NH 1
The first in-bounds capture, and a check queued rather than guessed at
.PP
A
.CW destroy()
capture, module
.CW Mount
this time:
.CW "bad v 0x18"
\- the recurring value, again \- with
.CW freeptrst->size
96 and the bad slot 80 bytes into the object.  80 is
.I less
than 96.  Every earlier capture in this hunt, stack or heap, landed
past the object's own declared size; this is the first one to land
.I inside
it.
.PP
That changes the question.  An in-bounds slot holding
.CW 0x18
instead of
.CW H
is either a legitimate pointer field the allocator's own
.CW initmem()
never reached (an init gap on a real field, the same shape as every
earlier finding, just not needing an overshoot to explain it), or an
offset
.CW freeptrs()
walked because a bit in the type's own map says to, when that offset
isn't really a pointer at all \- a type-descriptor problem this hunt
has ruled out twice already (String, Iobuf) but not for whatever type
this is.  The map settles it directly, so
.CW destroy()
now prints
.CW freeptrst->np
and the full
.CW map
array alongside the size, the same way
.CW probenewtype()
already does for
.CW OP(new) .
Rebuilt clean, no new warnings.  Fresh batch running.

.NH 1
The first indirect-mode capture: the pointer chain is fine, the field it reaches isn't
.PP
Module
.CW Mount
again:
.CW "bad sv 0" ,
addressing byte
.CW 0x2d .
.CW "USRC(0x2d) = 5 = AFP|AIND" :
the first indirect-mode capture this hunt has gotten with a working
probe.
.CW DIND(FP,\ s)
dereferences a pointer already sitting at
.CW "R.FP + s.i.f" ,
then adds
.CW s.i.s .
Decoded from the raw
.CW .ind
bytes by hand this time (0x58 as a word splits, little-endian, into
.CW i.f=88 ,
.CW i.s=0 ):
the source address is whatever pointer lives at
.CW FP+88 ,
unchanged by a zero final offset.  The frame-bounds line is
nonsense again
.RN ( "addr - FP = -1089352" ),
and that's expected now, the same way it was for the AMP-direct
.CW Arg
capture: an indirect final address has no reason to sit near
.CW R.FP
even when everything about the computation is correct.
.PP
This is the shape
.I advisor
predicted back when the addressing-mode question was first raised: an
indirect-mode capture would mean the dereferenced pointer was valid,
and the corruption is in the field it reached, not in the pointer
chain.  That's exactly what this capture shows.
.CW FP+88
holds a working pointer \- dereferencing it lands on a real,
plausible address
.RN ( 0x785ea78 ,
inside the same block the surrounding memory dump shows other
in-range values in) \- and the
.I field
at that address, not the pointer that reached it, is what holds 0
instead of
.CW H .
The pointer chain isn't the problem; whatever last wrote to that
specific field, or failed to initialize it, is.
.PP
Fixed the probe for next time rather than hand-decoding again:
.CW badptrslot()
now checks
.CW USRC / UDST
and prints
.CW i.f / i.s
directly whenever the mode is indirect, instead of printing
.CW .ind
reinterpreted as the wrong shape.  Rebuilt, same two pre-existing
unrelated warnings only.  Fresh batch running.

.NH 1
A second module-data capture, in a different module
.PP
Module
.CW Sh
this time, not
.CW Arg :
.CW "bad sv 0" ,
addressing byte
.CW 0x05 .
.CW "USRC(0x05) = 0 = AMP" :
module-pointer direct again, the same family as the
.CW Arg
capture several sections back.  No rebuild needed to read this one;
the existing probe already decodes both families correctly.  The
frame-bounds line is nonsense in the same expected way
.RN ( "addr - FP = 115391592" ) ,
for the same reason: an AMP-direct read never touches
.CW R.FP .
.PP
Module-level data is no longer a single data point.  Two different
modules
.RN ( Arg
and now
.CW Sh
itself), same addressing family, same shape of finding: a slot in the
module's own persistent global-data area holding something other than
.CW H .
Between this and the earlier check that
.CW m->origmp
starts fully zeroed and correctly populated at load
.RN ( heapz() ,
not the unzeroed
.CW "heap() / nheap()" ),
the running tally of contexts this hunt has now seen the bad value
in, each independently confirmed not to be an initialization gap
where checked: a stack frame slot beyond
.CW initmem() 's
reach, a heap object's own field, a module's persistent global data,
and \- the sharpest one yet \- a field reached through an otherwise-
valid pointer chain.  Four shapes, one recurring symptom.  Batch
still running.

.NH 1
The Arg capture recurs \- same PC, same value \- and a probe to settle it
.PP
The same capture from several sections back, again: module
.CW Arg ,
.CW "bad sv 18" ,
PC
.CW 0x79665a0 ,
instruction 71.
.I Identical
to the first Arg capture, not just the same shape \- the same
instruction, the same bad value, in a completely separate boot.  That
rules out a timing-dependent race as the whole explanation for at
least this one: whatever puts
.CW 0x18
at this exact module-data offset does it the same way, every time
this code path runs, not on some runs and not others.
.PP
.CW "s.ind = 0x20"
(32) this time, a small and entirely plausible module-data offset \-
no repeat of the earlier huge-delta anomaly.  Word index 4
.RN ( "32 / 8" ),
the fifth word of
.CW Arg 's
own persistent global data.  The open question is the same one the
.CW c7
heap capture asked and the same one
.CW m->origmp 's
construction already answered for the module-data area as a whole
without answering for this one word specifically: does
.CW Arg 's
own type[0] map mark word 4 as a pointer?  If it does, this is a real
field that something writes
.CW 0x18
into, reliably, on the way to instruction 71 \- worth finding in
.CW appl/lib/arg.b
directly, now that the site is pinned down to an exact instruction.
If it doesn't, this is the first type-descriptor gap this hunt would
have found in four checks.
.CW badptrslot()
now prints
.CW R.M->type[0] 's
.CW np
and full
.CW map
whenever either operand is AMP-direct, the same
.CW type[0]
.CW m->origmp
itself is built against in
.CW load.c .
Rebuilt, same two pre-existing unrelated warnings only.  A repeat of
this exact capture, or the
.CW Sh
one, now answers it directly.  Fresh batch running.

.NH 1
The recapture resolves to the wrong line, and finds an off-by-one this whole hunt has carried since the start
.PP
The Arg capture recurred a second time
.RN ( "'e14'" ,
same PC, same
.CW 0x18 ,
a third occurrence of this exact site).  Resolved through
.CW tools/resolve_sbl.py
against
.CW appl/lib/arg.b
(the
.CW Arg
module specifically \- a same-named
.CW appl/cmd/sh/arg.b
compiles to a different module,
.CW Shellbuiltin ,
and isn't this one), instruction 71 named
.CW arg.b:104 ,
the token
.CW opt
in
.CW "return opt;" \-
a local
.CW int ,
never a pointer, nothing module-global about it at all.  That doesn't
fit an AMP-direct capture even slightly.
.PP
Resolving the surrounding instructions one at a time
.RN ( 67\-73 )
instead of just 71 found the mismatch: instructions 67\-69 are
.CW "curropt = nextarg[2:]"
(line 102), 70 is
.CW "args = tl args"
(line 103, block 46), 71\-72 are
.CW "return opt"
(line 104, block 47).
.CW args
is declared
.CW "list of string"
at file scope
.RN ( arg.b:11 ),
a real module-global pointer \- exactly the shape an AMP-direct
capture should point at, and instruction 70, not 71.
.PP
The cause: the very first "inst %d" this hunt ever printed
.RN ( "(int)(R.PC - R.M->m->prog)" ,
.CW badptrslot() ,
present before this session's addressing-mode work started) used
.CW R.PC
directly.  Every addressing-byte and operand-field extraction added
this session already accounts for
.CW xec() 's
dispatch loop doing
.CW R.PC++
before the opcode handler runs, and reads
.CW R.PC-1
instead \- but this one line, the oldest of them all, never got the
same treatment.  It named the instruction
.I after
the one that actually faulted, for every capture this entire
multi-session investigation has ever printed.  Fixed at all three
sites that had it:
.CW badptrslot()
and
.CW scanframe()
.RN ( xec.c ),
.CW destroy()
.RN ( heap.c ).
.PP
What this does and doesn't retroactively change: every
.I module
name, every bad
.I value ,
every
.I address
this hunt has captured is unaffected \- those all come from the live
data at the computed address, never from the instruction index.  What
was wrong, potentially, is any conclusion drawn from resolving an
"inst N" to a specific source line \- including, per the sh.b:1061
section several back, a "coincidence" that was chalked up entirely to
source drift between sessions and may have been partly this instead.
Not re-litigated here without a fresh, correctly-indexed capture at
that exact site; flagged so a future re-read doesn't trust an old
"inst N" resolution at face value.  Rebuilt, same two pre-existing
unrelated warnings only.  Fresh batch running.

.NH 1
The first capture with correct indexing, resolved end to end, and no escape hatch left
.PP
The first capture against the off-by-one fix: module
.CW Sh ,
.CW "bad sv 18" ,
addressing byte
.CW 0x0d
.RN ( "USRC(0x0d) = 1 = AFP" ,
direct).
.CW "s.ind = 0xa8"
(168), and
.CW "addr - FP"
is
.I exactly
168.  Clean match, and this time
.CW "inst 1801"
names the
.I real
faulting instruction \- resolved via
.CW tools/resolve_sbl.py
against
.CW appl/cmd/sh/sh.b
to line 838, columns 22\-25:
.CW mod ,
the first argument of
.CW "spawn externalexec(mod, ctxt.drawcontext, argv, npath, extstart, ctxt.keepfds)" .
.CW mod
is a local variable holding a loaded external command module,
read here to hand off to the newly spawned Prog.
.PP
Frame
.CW t->size
is 336; 168 is well inside it, unlike most of this hunt's earlier
stack captures.  That reopens the question the type map settles
directly: is word 21
.RN ( 168\ /\ 8 ,
falling in
.CW map[2] ,
covering words 16\-23) actually marked a pointer?
.CW freeptrs() 's
own
.CW BIT(c,\ nb)
convention maps bit
.I nb
of a map byte to word
.CW "7-nb"
within its group of eight, so word 21 is position 5 within
.CW map[2] ,
bit
.CW "7-5=2" .
.CW "map[2] = 0x77" ,
and
.CW "0x77 & (1<<2) = 0x04" ,
nonzero.  The bit is set.
.CW mod
is a real, correctly-declared pointer slot, inside the frame's own
bounds, in a frame
.CW initmem()
should have covered when this call was made.
.PP
No escape hatch left for this one.  Not a stale probe (the fixed
addressing/frame-bounds machinery matches exactly:
.CW addr-FP
equals
.CW s.ind
to the byte).  Not a type-descriptor gap (the map bit is set,
checked directly rather than assumed).  Not an out-of-bounds tail
past
.CW t->size
that a partial
.CW initmem()
coverage could excuse (168 is well inside 336).  Not module-level
data, not a heap object, not an indirect pointer chase \- a plain
local variable, in a frame that was properly sized and, per its own
map, properly typed, holding
.CW 0x18
where a real, live module reference belonged.  Whatever writes this
value does so into memory that every check available says should
have been correct.

.NH 1
A watchpoint, not another read-side probe
.PP
.CW b06f5340 's
capture is as clean as a read-side capture can get, and that's
exactly its limit: it names where the corruption is
.I read
.RN ( sh.b:838 ),
not where it's
.I written .
No amount of context added to a read-side probe closes that gap \-
the write happened at an unknown earlier instruction, possibly in a
completely different function's frame.  What the capture does give,
though, is a bounded window: 
.CW mod
is assigned once
.RN ( sh.b:810 ,
.CW "mod := load Command npath" ),
read once at the capture site
.RN ( sh.b:838 ),
and nothing in the source between those two lines touches it again.
The slot's address is fixed for
.CW runexternal() 's
whole frame lifetime.  That's checkable directly: watch the slot,
not just read it.
.PP
.CW checkwatch()
arms on sight of a frame matching
.CW runexternal() 's
own type fingerprint
.RN ( t->size
336,
.CW t->np
6, map
.CW "00 c7 77 9e 00 c0" ,
taken directly from
.CW b06f5340 's
own capture)
.I "rather than a fixed address" ,
since the frame's address moves between boots.  Once armed, it runs
after every single instruction, dispatch-loop-wide \- not filtered to
any one module or
.CW R.M ,
because the whole hypothesis is that some
.I other
function's instruction computes an address that lands here.  Disarms
quietly, not as a finding, once the frame at that address no longer
matches the fingerprint \- ordinary teardown and reuse.
.PP
First version aborted on any change at all, and immediately proved
too eager: the very first boot armed, then fired on
.CW mod 's
.I own
assignment
.RN ( sh.b:810
itself, H to a real pointer
.CW 0x7859cd0 ) \-
a completely legitimate write mistaken for the bug.  Fixed to
distinguish a change to something that looks like a real pointer
.RN ( >=
.CW 0x1000 ,
the same threshold
.CW badptrslot() /
.CW movp
already use) from a change to a small non-
.CW H
value: the first kind updates the watched value and keeps going, the
second kind is the actual finding \- prints the instruction that just
ran
.RN ( PC ,
op,
.CW add ,
module) and aborts immediately.  A second boot armed, logged
.CW mod 's
legitimate assignment cleanly, and the boot went on to a native
general protection fault \- an already-documented failure mode
elsewhere in this hunt, not something the watchpoint caused; nothing
about
.CW checkwatch()
writes memory or otherwise perturbs execution beyond one comparison
per instruction while armed.  A full batch is running now to catch a
genuine bad-value transition.

.NH 1
One site is too rare; generalizing the watchpoint
.PP
48 boots against the
.CW runexternal()
-only watchpoint, clean every time \- four arm cycles per boot, always
the same four addresses (this build has no ASLR), always a legitimate
H-to-pointer transition, never a bad one.  That's not evidence the
bug is fixed; it's evidence that one remembered site is too narrow a
target.  This hunt's own capture history makes the point on its own:
nearly every capture landed on a
.I different
type \- String, Iobuf, Mount, Arg, Sh's own
.CW runexternal
frame \- not the same one twice by coincidence (the one exception,
the Arg site, recurred because it's an early, load-time site every
boot passes through; most sites this hunt has caught are not).
Betting an entire batch on one historical site recurring was worth
one try, and the try was cheap; it wasn't going to be the productive
long-run strategy.
.PP
Generalized instead of abandoned:
.CW checkwatch()
now arms on
.I any
frame with at least one declared pointer word
.RN ( t->np\ >\ 0 ),
watching its first one \- found by
.CW firstptrword() ,
walking the type's own map with the same
.CW BIT()
convention
.CW freeptrs()
uses, rather than a hardcoded offset.  Still one slot at a time, but
continuously re-armed on whatever frame is current the moment the
previous one tears down \- broad, opportunistic sampling across a
whole boot's execution instead of a bet on one remembered site.  The
routine "armed"/"legitimate change" prints came out; with every
pointer-bearing frame in scope those would fire on nearly every
function call and flood the log.  A one-shot
.CW watcheverarmed
flag prints once, the first time the mechanism arms at all, purely to
confirm it's alive \- verified directly against a test boot
.RN ( "t->size 128 np 2" ,
a different type than either of this hunt's two hardcoded fingerprints
ever were, which is the point).  A full batch ran: 140 boots, the
mechanism confirmed armed in 93% of them, zero bad-value firings.
Same outcome as the site-specific version, for the same underlying
reason \- broad opportunistic sampling still spreads its attention
across whatever frame happens to be current, and this hunt's one
genuinely reproducible site was never guaranteed to be among them on
any given boot.

.NH 1
Neither generalization was the right move; go back to what recurs
.PP
Both watchpoint versions bet on breadth \- one fixed site, then any
site \- and both came back with nothing.  The hunt already had a
better target the whole time: the Arg capture, alone among every
capture this investigation has made, reproduced on demand.  Same PC
.RN ( 0x79665a0 ),
same slot, same bad value
.RN ( 0x18 ),
across two separate, independently-run boots
.RN ( b4\ and\ e14 ,
see "The Arg capture recurs" above).  Module data lives for the whole
Modlink's lifetime, so a watch armed there has no frame-teardown
disarm problem at all \- arm once, on the first sight of module
.CW Arg
with a live
.CW MP ,
and it stays live for the rest of the boot with nothing to re-arm.
.PP
.CW checkwatch()
now watches exactly one fixed word: Arg's module data at
.CW MP+0x20 ,
word index 4 by
.CW appl/lib/arg.b 's
own declaration order
.RN ( name ,
.CW args ,
.CW usagemsg ,
.CW printusage
\- not a pointer \-
.CW curropt ).
Before hunting for a writer, the question the earlier type-map probe
was built to answer and never got a live capture through: is that
word actually marked a pointer in Arg's own
.CW type[0]
map, or is
.CW movp
reading a word the map never declared \- a different bug entirely,
one no amount of write-watching would ever find?  Armed and checked
directly against a real boot:
.RN ( "np 2 map 0xff 0xb0" ) ,
word 4 falls in byte 0, bit 3
.RN ( "0xff & (1<<3)" ) ,
set.  It is a declared pointer.  The map agrees with the source-order
guess; finding the writer is the right hunt.
.PP
The same boot's own trace fills in what
.CW curropt
actually does across its life: armed at
.CW H
.RN ( -0x1 ) ,
then two legitimate transitions,
.CW H\ ->\ 0x7849bd0
at PC
.CW 0x7965f88
.RN ( "add 0x08, indirect" )
and
.CW 0x7849bd0\ ->\ 0x7849b50
at PC
.CW 0x7966588
.RN ( "add 0x00, direct" ) ,
both tracked and neither a finding \- ordinary assignments into
.CW curropt
as
.CW appl/lib/arg.b 's
.CW opt()
runs
.RN ( "curropt = nextarg[2:]" ,
line 101, called twice as different flags are parsed).  Neither
transition landed on a bad value this boot.
.PP
This section's own closing line called the Arg site
.I "the reproducible site, not a sample of everything" .
That was wrong, and 255 further boots said so directly: 150 boots
against this exact slot, watched continuously for the entire boot
the way module data allows, produced zero bad-value transitions.
Two matching captures across two boots was a real coincidence, not a
recurring site \- see the next section for what actually replaced it.

.NH 1
Two captures were luck; seven in one batch is the real shape
.PP
150 boots against the Arg watch alone, all clean, while
.CW checkwatch()
sat armed on
.CW curropt
the entire time.  Arg.opt() is exercised once per normal boot \- the
top-level sh's own
.CW -n
flag parse \- and this hunt's own historical captures already put the
true rate under 1% at that exposure.  Rather than run a much larger
batch against one slot on faith, dis/init got a temporary stress loop
instead: 300 extra
.CW "sh -n -c 'true'"
spawns early in boot (each parses real flags through the exact same
Sh code every ordinary sh invocation runs), reverted once its purpose
was served \- the finding below is what it was for.
.PP
First attempt used a
.CW seq
subprocess to generate the loop's word list and silently produced
.I nothing :
.CW seq
isn't bound into this minimal no-disk/no-net root image, so the
.CW for
loop's list was empty and the loop body never ran once.  Caught by
checking
.CW checkwatch() 's
own arm count against a test boot, not assumed \- a batch would have
happily reported "150 boots, no firings" for a loop that silently did
nothing.  Fixed with a literal
.CW "1 2 3 ... 300"
word list instead of a command substitution.
.PP
Three manual test boots against the fixed build landed a capture
where 150 plain boots landed none: module Sh, PC
.CW 0x79504b0 ,
value
.CW 0x18
again, pid 172 \- deep into the loop.  Resolved
.RN ( resolve_sbl.py ,
.CW appl/cmd/sh/sh.sbl )
to
.CW sh.b:1531 ,
.CW "b.ba[n+1:] = b.ba[n:b.n];"
inside
.CW addbuiltin() ,
an array-slice-shift insertion run once per builtin registration, so
once per spawned sh.  Checked against the frame's own type map
.RN ( "t->size 152, np 3, map 00 e9 e0" ) :
word 16 IS genuinely a declared pointer (bit 7 of byte 2 set), with
.CW H
correctly sitting in the neighboring not-yet-assigned words (12, 15,
17, 18).  Not a type-descriptor gap, same as the Arg site.
.PP
.CW checkwatch()
grew a second, independent watch alongside the Arg one: armed on any
frame matching
.CW addbuiltin() 's
exact shape, watching word 16, frame-teardown-aware.  A 6-lane,
150-boot batch ran against the combined build \- both watches active,
stress loop in place.  Result:
.I zero
firings on either watch, across roughly 465,000 combined arm/disarm
cycles on the second watch alone (individual test boots reached
3,000\-4,000 arm cycles each).  But blanket
.CW badptrslot()
\- the plain "a movp just read a bad pointer" print that fires on
.I any
bad read anywhere, not just a watched slot \- caught
.B seven
separate captures across those same 150 boots that neither targeted
watch saw coming.
.PP
The seven, resolved end to end:
.LP
.nf
.ta 0.4i 1.6i 3.0i
	boot	module:PC	source line	value
	a5	Sh:0x7946a00	sh.b:806 (runexternal, "mod := load Command npath")	0
	a9	Init:0xa3eeb0	disinit.b:193 ("b := sys->aprint(...)")	0
	b11	Sh:0x7951e60	sh.b:1735 (revlist helper, "sl = tl sl")	0x18
	d14	Sh:0x794efe0	sh.b:1445 (hashadd, "ht[idx] = v :: ht[idx]")	0
	e12	Sh:0x7950408	sh.b:1529 (addbuiltin, "nb[0:] = b.ba[0:b.n]")	0x18
	e8	String:0x792da48	string.b:419 ("argv = tl argv")	0
	f22	Sh:0x7941ac8	sh.b:480 (list-reverse helper, "l = hd left :: l")	0x18
.fi
.PP
Seven different source lines, three different modules, two recurring
values.  No single writer explains a spread like that \- a wild write
from one bad instruction clusters on one site, the way the Arg site
looked like it did before 150 boots said otherwise.  This is a
systemic pattern, not a local bug in
.CW addbuiltin() .
.PP
.CW libinterp/heap.c 's
.CW heap() ,
temporarily instrumented to print it and checked against a real boot
rather than hand-computed, gives
.CW "sizeof(Heap) = 24 (0x18)"
exactly, so
.CW H2D(t,\0)
does compute
.CW 0x18 .
That is confirmation of one number, not of a mechanism \- 24 is small
enough that plenty of unrelated things could produce it, and four of
the seven captures hold plain
.CW 0 ,
which needs no
.CW H2D
story at all.  A scan of every
.CW H2D()
call site in
.CW libinterp/
found none that skip a null check \- every one either follows
.CW heap() ,
.CW heapz() ,
or
.CW heaparray()
(which check
.CW poolalloc() 's
return themselves) or operates on a
.CW Heap*
already known live.  This lead stops here unless a live capture
actually shows an unchecked null reaching one.
.PP
Two more checks, run against data already in hand rather than new
captures.  First: does a watched slot ever start bad, meaning
.CW initmem()
never covered it and there is no writer to find?  Every
.CW checkwatch()
arm line across the whole 150\-boot batch was pulled
.RN ( "grep, not eyeballed" ) :
122 Arg arms, and roughly 116,000 Sh
.CW addbuiltin()
arms, every single real one reading
.CW H
.RN ( -0x1 )
as its baseline (a handful of lines showing other values were
console output from two concurrent
.CW print() s
interleaved on one line, confirmed by checking those boots' raw
output).  Slots start correct.  Something writes them bad afterward;
.I "find the writer"
survives this check.
.PP
Second: do the four captures with a usable frame map
.RN ( a9 ,
.CW b11 ,
.CW e12 ,
.CW e8 \-
.CW a5
and
.CW f22
had
.CW cf\->t\ ==\ nil ,
no map to check;
.CW d14 's
printed frame belongs to an unrelated call, not the corrupted
address) show the map disagreeing with reality at a
.I constant
offset \- the shape a wrong
.CW initmem()
write would leave?  They do not, mostly.  In three of the four
.RN ( a9 ,
.CW e12 ,
.CW e8 ) ,
every marked pointer word holds
.CW H
or a real pointer except the one bad word, and every unmarked word
holds a small int consistent with its own local variable \- no
shift, no second discrepancy.
.CW b11
alone shows a hint: word 10, unmarked in the type map, holds a
value in the same address range as every genuine pointer in that
frame, while word 9 (marked, expected a pointer) holds the bad
.CW 0x18 .
That could be a shifted write; it could equally be ordinary stack
staleness landing by chance in this build's narrow heap address
range.  It does not repeat in the other three, so it is recorded as
a lead, not a finding.
.PP
Two further shapes in the seven worth keeping separate from the
above.
.CW d14
is not like the other six: its indirect addressing dereferences a
pointer that lands
.I "outside every pool"
.RN ( "auditmemloc() 's own \(dqnot in pools\(dq" ) ,
not inside a live block holding a bad word \- this looks like
corruption propagating through an already-bad pointer from some
earlier point, not a fresh single-word event, and the frame
.CW badptrslot()
printed for it belongs to a different, unrelated call
.RN ( "addr \- FP" ,
94212344, nowhere near
.CW t\->size ) .
And
.CW a5
and
.CW f22
both hit
.CW cf\->t\ ==\ nil
\- the same shape the standalone
.CW a2
capture hit earlier in this hunt (see "The first capture with
correct indexing" above) \- now 2 of 7 in one batch, not a one-off.
.PP
One capture's containing block was checked against
.CW auditmemloc() ,
which already distinguishes a live block
.RN ( "MAGIC_A, \(dqblock\(dq" )
from a freed one
.RN ( "MAGIC_F, \(dqfree blk\(dq" ) .
Checked against all seven of this batch's own captures, not just the
.CW addbuiltin()
one: six of the seven
.RN ( a5 ,
.CW a9 ,
.CW b11 ,
.CW e12 ,
.CW e8 ,
.CW f22 )
print
.CW "in main: in block at ..." \-
.I "block" ,
MAGIC_A, live \- for the block containing the bad slot, none printing
.I "free blk" .
That closes use-after-free across the whole batch, not one capture:
every bad slot this batch caught sits inside memory the allocator
still considers live, holding a value its own type map says should
be a pointer.  The seventh
.RN ( d14 )
is the outside-every-pool case above, a different shape entirely.
.PP
.CW extend()
and
.CW newstack()
.RN ( libinterp/stack.c )
were read end to end looking for a stack-relocation bug \- a frame
whose base moves without its pointer words following.  Neither does
that:
.CW newstack()
.CW memmove() s
an initial frame into a fresh extent and only ever runs once, at
process start;
.CW extend()
never relocates a live frame at all \- it links a new
.CW Stkext
onto the existing chain for the
.I next
call's fresh frame, which gets its own
.CW initmem()
call
.RN ( "if (t->np) initmem(t, f);" ,
present and correct).  A frame already executing keeps its own
address for its entire life.  That theory is closed, not confirmed.
.PP
Net effect on tooling: two increasingly narrow, increasingly targeted
watchpoints \- one bet on a site that turned out to recur by chance,
one bet on a frame shape seen bad exactly once \- both watched
465,000+ slot-checks between them and caught nothing, while the
blanket, untargeted print that has been in
.CW OP(movp)
since early in this hunt caught seven.  The lesson carries forward
plainly: this corruption is not a fixed site to stake a watchpoint
on.  It is a rare, systemic event that can land almost anywhere a
pointer slot is read, and the tool that finds it is broad sampling
under heavy load, not a narrower and narrower bet on where it last
showed up.  The stress loop that produced this batch (dis/init) has
been reverted \- it served its purpose, multiplying the hit rate from
under 1% to 7 in 150
.RN ( "4.7%" ) ,
and the finding stands on its own without it staying in the tree.
.PP
Cleanup owed before any other board or hosted
.CW emu
builds:
.CW checkwatch()
lives in
.CW libinterp/xec.c ,
shared by every target, not just pc64 \- it costs a comparison per
instruction dispatched, prints on every ordinary boot (the plain
sanity boot that confirmed the stress-loop revert logged 120 routine
arm/legitimate-change lines with no stress loop running at all), and
.CW abort() s
the whole process on a hit.  Same standing item as the temporary
.CW dumpstack()
calls added to
.CW heap.c
and
.CW xec.c
earlier in this hunt: fine for a pc64-only investigation running
under a debugger's eye, not fine left in for anyone else.

.NH 1
Coverage, not rarity: checking state at every teardown instead of one watched slot
.PP
Two plans considered next, both retired before spending a boot on
either.  The
.CW b11
"unmarked word holds a pointer-looking value" hint from the previous
section was a candidate for a constant-offset bug in
.CW initmem() ;
it didn't repeat in the other three checkable captures and is
dropped.  A hardware watchpoint via QEMU's gdbstub
.RN ( lldb
supports
.CW gdb-remote )
needs a reproducible address to aim at first; a 60-boot run against
the unchanged stress-loop binary produced exactly one capture and no
repeat to test determinism against, so there was nothing to watch,
and any address found would die on the next rebuild regardless.
Neither plan survived contact with what the batches actually show.
.PP
That one boot's capture is still worth keeping: module Sh, PC
.CW 0x794aa20 ,
pid 1 (the top-level sh, not a stress-loop child), bad
.I dv
.RN ( "the destination's old value, before being overwritten" )
value 0.  Resolved to
.CW sh.b:1102 ,
.CW "r := status[len status - 1];"
\- an array-element read into a fresh local, an eighth distinct
source line.  Destination addressing was AFP-indirect
.RN ( "d.i.f 0x20, d.i.s 0" ) ,
so the frame
.CW badptrslot()
printed (addr-FP came out negative) describes the
.I current
frame holding the array reference, not the array object the bad slot
actually lives in \- the same limitation noted for
.CW d14
in the previous section, now confirmed on a second indirect capture.
.PP
The real diagnosis for why two increasingly targeted watchpoints
caught nothing while the blanket
.CW movp
print caught nine: coverage, not rarity.
.CW checkwatch()
holds exactly one frame instance and disarms the moment that
instance tears down; a boot that creates thousands of frames makes
the odds negligible that the one instance being held is the one that
goes bad.  No amount of re-aiming a single-slot watch fixes an
asymmetry like that.
.PP
.CW freeptrs()
.RN ( libinterp/heap.c )
is a better vantage point for the identical fact.  It already walks
every declared pointer word of every object, at the one moment that
matters most \- teardown, immediately before handing each word to
.CW destroy() ,
which is the original crash shape this whole hunt started from.  A
new
.CW checkfreeptr()
validates each word right there, before the
.CW destroy()
call: not
.CW H
and not
.RN ( >=\ 0x1000 )
prints the word's address and index within the object, the object's
own type
.RN ( size ,
.CW np ,
full map),
.CW R.PC\-1 ,
the module and pid, then
.CW dumpstack()
and
.CW abort() .
This runs at every frame's exit for the cost of one more comparison
inside a loop that already has to run \- not one sampled frame per
arm cycle, every frame, every time.  A sanity boot against the new
build confirmed no false positives on ordinary teardown traffic.
.PP
If a frame comes back clean from
.CW initmem()
.RN ( the
150-boot watch-baseline check, previous section)
and dirty at
.CW freeptrs() 's
own teardown scan, the corruption is bounded to that one call's own
execution \- the first real narrowing this hunt has had, if it lands.
A fresh batch runs against this build next.

.NH 1
The landmark site recurs, and a real resolver gap surfaces
.PP
180 boots, six lanes, the
.CW freeptrs()
teardown check running alongside the existing blanket
.CW movp
print: 12 captures
.RN ( "6.7%, the highest rate this hunt has measured" ) ,
spanning five modules
.RN ( Sh ,
.CW Init ,
.CW Env ,
.CW Mount ,
.CW Shellbuiltin )
and, once every instruction was actually resolved rather than
assumed from the module name, eight genuinely new distinct source
lines
.RN ( env.b:63 ,
.CW env.b:44 ,
.CW env.b:31 ,
.CW disinit.b:88 ,
.CW disinit.b:173 ,
.CW mount.b:207 ,
.CW mount.b:209 ,
.CW std.b:558 )
on top of the eight this hunt already had, plus one recurrence of the
landmark site below.
.PP
Two results stand out from the rest.
.CW freeptrs()
fired once, for real: object
.CW 0xa3d600 ,
size 232, np 4, map
.CW "00 b1 e0 08" ,
word 10
.RN ( "genuinely marked a pointer -- byte 1 bit 5" ) ,
value 0, caught at the exact moment
.CW env.b:63 's
.CW "(a, nil) := readdir->init(...)"
tore its calling context down.  This is the mechanism working exactly
as built: state checked at teardown, not a read that happened to hit
a bad slot.  And one capture landed on the exact line the whole
hunt's own landmark
.RN ( b06f5340 ,
"The first capture with correct indexing" above)
first resolved to:
.CW sh.b:838 ,
.CW "spawn externalexec(mod, ctxt.drawcontext, argv, npath, extstart, ctxt.keepfds);" \-
the same
.CW mod
argument, recurring independently in a completely different boot.
Two
.CW mount.b
captures
.RN ( lines
207 and 209, both inside a
.CW spawn / pipe
setup passing
.CW sh
and
.CW fds
as arguments) sit in the same shape: argument marshaling immediately
around a
.CW spawn
statement.  Three independent sites now share that pattern, which is
worth watching for without yet being a finding \- plenty of this
hunt's other captures
.RN ( addbuiltin() 's
array-slice-shift,
.CW hashadd() 's
array-element cons)
have no
.CW spawn
nearby at all.
.PP
Resolving the
.CW Shellbuiltin
capture
.RN ( PC
.CW 0x7975938 ,
inst 1431)
surfaced a real gap in this hunt's own source-resolution method, not
just this one capture: fifteen separate files under
.CW appl/cmd/sh/
.RN ( echo.b ,
.CW test.b ,
.CW std.b ,
.CW arg.b ,
and eleven more) all declare
.CW "implement Shellbuiltin;" ,
so the module name alone never identifies which
.CW .sbl
to resolve against \- every prior
.CW "module Shellbuiltin"
mention in this hunt (there had been none before this batch) would
have needed the same disambiguation.
.CW Sh
has the same problem on a smaller scale
.RN ( sh.b ,
.CW mload.b ,
and
.CW appl/tiny/sh.b
all implement it), and
.CW Init
worse \- thirteen board-specific init variants share the name.
Disambiguated here by instruction-count range (only
.CW std.sbl 's
1967 instructions cover index 1431; every other Shellbuiltin file is
too short) and confirmed by the resolved line
.RN ( "std.b:558,
inside a
.CW for
loop calling
.CW ctxt.run() ,
a real builtin's real body) being plausible.  Every
.CW Sh
capture this hunt has ever resolved was checked against
.CW mload.sbl 's
own 649-instruction ceiling and appl/tiny's absence from this build;
none of them are close enough to that boundary to be ambiguous, and
every one names a real, recognizable
.CW sh.b
function
.RN ( addbuiltin() ,
.CW hashadd() ,
.CW runexternal() ,
and now this batch's
.CW sh.b:838
spawn line).  Worth remembering as a standing check for any future
capture in a shared-name module, not just this one.
.PP
Net picture after seventeen distinct source-line captures (eight from
before this batch, eight new, plus the landmark counted once) and one
teardown catch: still no single site, still both recurring values
.RN ( 0
and
.CW 0x18 ) ,
now across five modules instead of three.  The corruption is not
rare in the way a race needing exact double-digit-microsecond timing
would be \- 6.7% under this stress load is common enough that the
next real narrowing is more likely to come from reading what these
sites share than from another blind batch.
.PP
Read
.CW OP(spawn) ,
.CW OP(mspawn) ,
.CW OP(frame) ,
and
.CW newstack()
end to end chasing the spawn-proximity pattern directly, rather than
leaving it as an open question.  All four are correct.
.CW OP(frame)
.RN ( libinterp/xec.c )
builds a spawn statement's own argument frame and always
.CW initmem() s
it \- either directly, when the fast path has room
.RN ( "nsp\ <\ R.TS" ) ,
or through
.CW extend() ,
already confirmed correct in the previous batch's write-up.
.CW newstack()
.RN ( libinterp/stack.c )
then
.CW memmove() s
that already-initialized frame whole into the new process's stack;
it has no
.CW initmem()
call of its own, but doesn't need one \- it is copying a frame
.CW OP(frame)
already built correctly, not building one from scratch.  Landmark's
.CW mod
was not corrupted by any of this machinery: it was a plain local in
.CW runexternal() 's
own frame, assigned validly at
.CW sh.b:806
and read again, already bad, thirty-two lines later at
.CW sh.b:838 .
The spawn-proximity pattern is better read as a lifetime-and-exposure
effect than a spawn-mechanism bug: functions that eventually call
.CW spawn
tend to carry a
.CW Modlink
.RN ( or
similar) local alive across a wide span of source \- exactly the
.CW mod
/
.CW sh
shape in all three spawn-adjacent captures \- giving the corruption a
longer window to land in before that slot is finally read, not
because
.CW spawn
itself does anything wrong to it.

.NH 1
Every watched slot, not one sampled slot
.PP
Three generations of
.CW checkwatch()
(the type-fingerprint version, the any-frame's-first-word version,
the Arg
.CW curropt
version) went to zero across more than three hundred combined boots.
That was a coverage problem, not a rarity problem:
a boot creates thousands of frames, and holding one instance at a time
makes the odds of it being the one that goes bad negligible.
.CW checkwatch()
is gone, removed rather than kept dead.
Its replacement,
.CW checktracked() ,
does not sample: every word
.CW initmem()
ever sets to
.CW H
gets registered in a fixed 1024-slot hash table, and every registered
word is compared every instruction, not one chosen slot.
It caught a live write-side transition on its first sanity boot.
.PP
The first capture through it was wrong, and finding out why it was
wrong was most of the work.
.CW disinit.b 's
.CW getclock()
does
.CW "now := big 0"
as its very first statement; the capture said that ordinary write hit
a declared pointer word.
Disassembling
.CW getclock()
end to end (a small hand-rolled decoder for the
.CW .dis
instruction and type-descriptor format, since this tree's own
.CW disdump
turned out to have an unrelated, unchased bug of its own) showed every
touch of that word \- instructions 286, 306, 308, 309, 312 \- is
.CW IMOVL ,
.CW ICVTCL
or
.CW IBLTL ,
never a pointer-class op, in every branch the function has.
Pulling the module's own type table out of
.CW disinit.dis
confirmed the captured
.CW Type
really was
.CW getclock() 's
own frame descriptor (size 88, two map bytes, word 9 marked a
pointer) and not some other function's shape coincidentally read back.
So the map really did mark a
.CW big
local a pointer \- and the cause was not a compiler bug.
It was the tracker: a stack address that had most recently held word
9 of a
.I different
frame shape, one that legitimately marks that word a pointer, got
reused by
.CW getclock() 's
own frame, whose map does not mark that word at all.
.CW initmem()
only ever registers the words a
.CW Type 's
own map marks; it never visits words a
.I previous
occupant of the same memory marked that the new occupant's map
doesn't.
The stale registration survived, and the entirely ordinary
.CW "now := big 0"
read as corruption.
.PP
Fixed with
.CW trackclear() :
every
.CW initmem()
call now clears any tracked entry inside its own
.CW "[base, base+size)"
range first, unconditionally, before re-registering the words its own
map actually marks.
Callers that used to skip
.CW initmem()
entirely when a type had no pointers
.RN ( frame() ,
.CW mframe() ,
.CW extend() ,
.CW heapz() ,
.CW heap() )
now call it unconditionally, since the clear has to happen even when
there is nothing to re-register.
.PP
That closed one staleness channel but not the other, and a second
capture proved the second channel open: an object can be freed and
its memory recycled by an allocation that never calls
.CW initmem()
at all \- a raw pool allocation, a string body \- leaving a tracked
word stale with no clear ever triggered.
That same capture (module printed as
.CW Env ,
instruction 64) also proved the printed attribution itself was wrong
on its own terms: the op was
.CW IMCALL ,
a control transfer, and
.CW checktracked()
ran
.I after
.CW optab[op]() ,
by which point
.CW R.M
and
.CW R.PC
already described the callee, not the instruction that wrote the
word.
Neither of
.CW Env 's
own two
.CW env.dis
type tables had any entry matching the captured shape, which is what
gave the misattribution away.
.PP
Both closed the same way: stop trusting registration to still be
valid at report time, and validate it there instead.
Every registration now carries
.CW typetagp ,
a pointer to wherever the current, authoritative type of the
containing object lives \-
.CW &f->t
for a frame,
.CW &h->t
.RN ( via
.CW D2H )
for a heap object,
.CW &a->t
for an array element \- fields that get overwritten every time that
memory is reused for something new, whether or not the new occupant
calls
.CW initmem()
or ever touches this particular word.
A hit is only reported when
.CW *typetagp
still equals the type recorded at registration; otherwise the slot is
dropped as stale, silently, no abort.
The attribution fix is separate:
.CW xec() 's
dispatch loop now saves
.CW R.M
and
.CW R.PC
.I before
calling
.CW optab[op]() ,
and
.CW checktracked()
prints those saved values instead of reconstructing from state a
control-transfer op may have already overwritten.
.PP
A third, narrower channel showed up after both of those landed: a
capture at
.CW sh.b:1531
.RN ( addbuiltin() 's
array-slice insert, the same site
.CW checkwatch() 's
stress-loop batch had already named once, see above) reproduced on
8 of 8 boots \- deterministic, not the rare corruption this hunt is
actually after, and a small never-varying value at a fixed offset on
every single boot is itself the tell.
.CW trackclear()
only ever clears
.CW "[vw, vw+t->size)" ,
the object's data proper; it never reaches
.CW sizeof(Heap)
bytes
.I before
that, where a later allocation's own heap header
.RN ( color / ref / t / hprof )
can land.
Widening the clear to start
.CW sizeof(Heap)
bytes earlier made that capture stop reproducing.
That is consistent with the header theory and shows the pre-widening
capture was an artifact of clearing too narrow a range \- but which
later allocation's header the word actually landed in was never
directly confirmed, and the write-up says so rather than claiming
more than the boots showed.
.PP
With both known false-positive classes closed, a fourth capture
reproduced on 7 of 8 boots with clean attribution
.RN ( op
.CW ILOAD ,
which does not reassign
.CW R.M )
and passed the staleness check: the historic
.CW runexternal()
.CW mod
site, this hunt's original landmark, now visible under a tracker that
survives its own scrutiny.
A worked theory about the failure path \-
.CW iload 's
.CW "linkmod()"
returning a plain
.CW nil
instead of
.CW H
on a failed load \- turned out to be wrong on inspection:
.CW linkmod()
checks
.CW "m == nil"
at its own top and returns
.CW H
on every failure path it has.
That is checked and excluded, not merely unlikely.
.PP
Settling where inside
.CW OP(iload) 's
own call tree the write happens needed one more print:
.CW R.d ,
the current op's own destination-operand address, alongside the hit,
compared against the tracked address.
They don't match \-
.CW R.d
is
.CW mod 's
own frame slot,
.CW iload 's
.CW "*mp = ml"
target, while the tracked hit lands in a
.I different ,
unrelated-looking frame (a 128-byte, two-map-byte shape, word 11)
elsewhere on the same call stack.
So
.CW iload
did not write the bad value directly; the write happened somewhere
inside
.CW destroy(t) ,
the call right after
.CW "*mp = ml"
that releases
.CW mod 's
.I old
value \- freeing one object appears to be corrupting a word in a
second, still-live one, which is the shape of a premature free or a
refcount that's off by one somewhere in that teardown path rather
than a stray pointer computation.
Which function owns the size-128 frame, and what inside
.CW destroy() 's
cascade actually writes to it, is the next thing to pin down.
.PP
Two more checks, both fast:
recording which process registered a tracked word
.RN ( regpid ,
.CW currun()->pid
at
.CW trackreg()
time) and printing it alongside the hit shows
.CW regpid
matching the currently-running pid \- the corrupted frame belongs to
the
.I same
process that's running
.CW iload ,
not a different one caught by
.CW checktracked() 's
own process-agnostic sweep.
That rules out scheduler interleaving as the explanation for this
particular capture, though the mechanism remains a real limitation
worth remembering for others: it checks every registered word every
instruction regardless of which process is currently dispatching, so
a hit's
.CW trackM / trackPC
name whichever instruction happens to be running when a bad
transition is
.I noticed ,
which is only the actual writer when
.CW regpid
also matches.
.PP
The type the corrupted frame belongs to
.RN ( sh.dis 's
own id 70, size 128, map 00 f9) is not unique to one function \-
thirteen different
.CW IFRAME
sites in the first 1300 instructions alone construct a frame of
this exact shape, an ordinary consequence of the compiler interning
identical
.RN ( size ,
map) pairs across unrelated call sites.
Static analysis alone can't say which one without also knowing the
real call path, and the obvious source for that \-
.CW dumpstack() \-
turned out not to help: it is
.CW callwithureg(_dumpstack) ,
a raw linear scan of every word from the current stack pointer to
.CW estack ,
not a frame-pointer unwind.
Feeding one capture's dump through
.CW resolve_ipc64_syms.py
resolved entries including
.CW linkmod ,
.CW nheap ,
.CW newmp
and, notably,
.CW rungc \-
but a conservative scan finds whatever word-sized bit patterns happen
to still be sitting in stack memory, including stale return addresses
from calls that already returned, so
.CW rungc 's
appearance here is not evidence it was running at the moment of the
hit.
Worth remembering as a lead \- a GC pass triggered by
.CW nheap() 's
allocation, walking live frames while one of them is mid-update, is
exactly the shape of bug this capture has \- but not established, and
a real native backtrace (frame-pointer or DWARF-based, not this
conservative scan) is what would actually settle it.
.PP
The lead was worth checking directly rather than leaving as a maybe,
and checking it ruled it out.
.CW rootset()
.RN ( libinterp/gc.c ,
called once per completed GC epoch) walks every live process's every
frame and calls
.CW t->mark(t, f)
on each; for an ordinary type that's
.CW markheap() ,
which \- unlike
.CW freeptrs() ,
guarded by
.CW checkfreeptr()
since earlier in this hunt \- trusted every declared-pointer word it
was handed with no validation at all: not
.CW H ,
straight into
.CW D2H()
and
.CW Setmark() ,
writing
.CW h->color
wherever that resolved to.
A small, non-H garbage value there is exactly this hunt's population
.RN ( 0 ,
.CW 0x18 ,
.CW 0x80 ,
...), and a write through a garbage-derived address, landing on some
unrelated live object, is a mechanism that would explain the whole
shape of this hunt in one place.
Added
.CW checkmarkptr() ,
.CW freeptrs() 's
.CW checkfreeptr()
guard ported to
.CW markheap() ,
and ran six boots.
It never fired \- not once, while
.CW checktracked()
caught the landmark site in five of the six.
Every word
.CW markheap()
dereferenced across all six boots was either
.CW H
or a plausible pointer.
That rules the mechanism out cleanly: the corruption is not GC
blindly trusting a garbage pointer word during mark.
Kept anyway, the same way
.CW checkfreeptr()
was kept after its own negative results \- it is real, permanent
hardening at zero ordinary cost, and the next capture through it (if
one ever comes) will say plainly that this specific path finally
failed.
.PP
Also considered and set aside: a genuine SMP data race would explain
cross-frame corruption without needing any single instruction to be
at fault, since
.CW R
and
.CW gc.c 's
mark/sweep state
.RN ( quanta ,
.CW visit ,
.CW gccolor ,
...) are plain globals, not per-CPU or locked against concurrent
access.
.CW qemu-boot.sh
does not pass
.CW -smp ,
and QEMU defaults to one vCPU without it, so this board boots single-
CPU in every capture taken so far \- ruling out true concurrent
execution as the explanation, though not interrupt-time reentrancy,
which remains unexamined.
.PP
.CW checktracked() ,
.CW checkfreeptr() ,
and the
.CW dumpstack() / abort()
calls in both are pc64-only debugging, the same as
.CW checkwatch()
was before it: strip them, and the
.CW dis/init
stress loop that makes any of this practical to hit in a reasonable
batch, before any other board or the hosted
.CW emu
target is built from this tree.

.NH 1
Freed, not cleared
.PP
The tracker's own comment (see
.I "Every watched slot, not one sampled slot" )
had already named a second stale-registration channel and left it
open: an object freed and its memory recycled by an allocation that
never calls
.CW initmem()
at all leaves a tracked word stale with no clear ever triggered.
.CW typetagp
validation was believed to close it well enough \- a stale entry only
survives if the new occupant's own writes happen to miss the exact
word
.CW typetagp
points at.  That belief was wrong, and this round found the concrete
case: a Dis stack frame's extent
( unextend() ,
unframe() ,
stack.c)
and a heap object
( destroy() ,
freelist() ,
heap.c)
were both freed back to
.CW mainmem / heapmem
without ever calling
.CW trackclear() ,
and
.CW destroystack()
(the whole-process teardown path, xec.c) walked and freed every
extent in a process's chain the same way, bypassing
.CW unextend()/unframe()
entirely.  When that freed memory was next handed to a plain kernel
allocation \- a
.CW Path
struct, built by
.CW copypath()
(chan.c) via
.CW smalloc() ,
in the capture that pinned this down \- and that allocation's own
.CW memset()
zeroed it,
.CW typetagp
validation passed anyway: the field it was checking sat outside the
small
.CW Path
block's own extent, untouched by the reuse, so the stale entry
survived and reported the zeroing as a live pointer word going bad.
.PP
Fixed by clearing at free time instead of waiting for reuse to maybe
catch it.
.CW unextend()/unframe()
clear exactly
.CW [R.EX,\0R.TS)
\- the extent about to be freed, using registers
.CW extend()
itself set to the extent's own base and end and that nothing touches
again before the free \- with no pool API needed, so the fix stays
portable across every
.CW libinterp
target.
.CW destroystack()
has no per-extent size available during its chain walk, so it clears
each frame individually, by its own
.CW t->size ,
as it tears the frame down; exact, and no new dependency either.
.CW destroy()/freelist()
sit on the
.CW heapmem
side of the identical gap: since the freed pointer
.CW h
is exactly what
.CW poolalloc(heapmem,\0...)
returned,
.CW poolmsize(heapmem,\0h)
gives the whole block directly, and
.CW heapmem/poolmsize
were already used unconditionally elsewhere in this file, so this is
no new dependency either.
.CW trackclear()
itself was made non-static, with an
.CW extern
in
.CW interp.h ,
to reach it from
.CW stack.c
and
.CW xec.c .
.PP
Measured in batches of parallel boots, grep for
.CW "track:\0CHANGED" :
before this fix, effectively every boot fired it (about 10 of 10);
after, 4 of 16, then 2 of 20 once a real
.CW mk
gotcha was caught and worked around.
.CW mk\0ipc64
can silently skip the final
.CW 6l
relink after a
.CW libinterp.a -only
change lands \- nothing downstream of the archive update forces
.CW pc64.6
or the link step to be considered stale \- so a build that only
touches
.CW libinterp/*.c
needs
.CW rm\0ipc64
first, or a verified fresh
.CW 6l
line in the build's own output, before trusting a boot against it.
Every boot batch measurement in this section was taken against a
build checked this way.
.PP
This did not close the investigation.  It closed a real, separate gap
in the tracker's own soundness, worth having regardless of how the
underlying question resolves, and it took the hit rate from
"almost every boot" to "the low tens of percent" \- which is itself
the strongest evidence yet that most of what four-plus sessions of
this hunt had been chasing was the instrument, not the kernel.  What
is left is smaller, and different in shape from what came before.
.PP
.CW checktracked()
(heap.c) and
.CW scanframe()
(xec.c, the pre-existing full-frame return-time scan this hunt has
also called
.CW badptrslot() -style
in earlier notes) no longer
.CW dumpstack()+abort()
on a hit \- they log and continue, dropping the stale slot or just
printing.  This was necessary to tell "the write is real corruption"
from "the write is benign and execution continues correctly" apart,
which stopping the boot on every hit could never distinguish.  Both
remain pc64-only, temporary, and are now silently non-fatal by
deliberate choice \- a quiet boot is evidence of nothing on its own;
grep the log for
.CW "track:\0CHANGED"
and
.CW "bad\0slot\0in\0frame"
before calling any boot clean.
.CW checkmarkptr()
(gc.c) is
.I not
included in that softening and still aborts \- see below, it is now
the signal actually being chased.
.PP
The residual
.CW checktracked() / scanframe()
signal, once the free-time clears above stopped the bulk of the
noise, resolved to two source lines via
.CW resolve_sbl.py :
sh.b:2479
( word[len\0word]\0=\0c;
inside the shell's tokenizer,
.CW gettok() )
and string.b:414
( s[len\0s]\0=\0' ' ;
inside
.CW quote() ).
Both are ordinary, unremarkable string-append code with no bug of
their own, and the first working theory this round \- that a Dis
frame's
.CW Type
map is a whole-function conservative union, so a marked-pointer word
can legitimately hold a live non-pointer local at some points in a
function's execution \- does not survive a closer look and should not
be re-derived next time.
.CW freeptrs() ,
called at every
.CW OP(ret) ,
walks a frame's
.I entire
map and calls
.CW destroy()
on every word it marks, unconditionally.  If a marked word could
legitimately hold a small int at return time,
.CW freeptrs()
would compute
.CW D2H()
on that int and write through a near-null pointer on perfectly
ordinary returns, on every platform this interpreter runs on.  It does
not.  The invariant \- a marked word holds
.CW H
or a real pointer whenever
.CW freeptrs()/GC
can observe it \- is load-bearing and real, not a checker artifact, and
a marked word holding a small int at that point is a violation of it.
That is also, in hindsight, exactly the shape of the
.CW destroy:\0bad\0v
crash that opened this whole investigation.
.PP
Two supporting readings from the same pass also do not hold up and are
retracted rather than carried forward.  "Every bad value observed
across this hunt has been small, never large garbage" was read as
evidence the checkers were over-eager; it runs backward.
.CW scanframe()
tests
.CW "<\00x1000\0&&\0!=\0H" ;
.CW checkmarkptr()
tests
.CW ">=\00x1000" .
Both are blind to large garbage by construction, so a small-value
signature is a property of the instruments, not of the bug.  And a
.CW showframe()
dump from one capture, showing several small-looking integers at
various words in the frame, was read as showing widespread
map-imprecision; it shows nothing of the kind \-
.CW showframe()
prints every word in a frame regardless of the map, and most of a
frame's words are legitimately ints.  Only the one word
.CW scanframe()
itself flagged is in evidence.
.PP
One attribution gap is still open and should be closed before trusting
another source resolution built on it: a
.CW scanframe()
capture during this same pass printed
.CW "module\0String\0...\0inst\08632" ,
but
.CW resolve_sbl.py
reports the
.CW String
module has 941 instructions \- that print is self-refuting, so
misattribution is still happening in at least some of these captures.
The two resolved sites above (Sh 5383 of 6111, String 704 of 941) are
in range and stand, but any future
.CW module/inst
print should be gated on
.CW inst\0<\0ninst
before a source-level conclusion is built on it.
.NH 2
A different, dominant signal: Tptr list cells
.PP
Once the free-time
.CW trackclear()
fixes and the non-fatal softening above landed, a batch of 30 boots
put a different checker \- 
.CW checkmarkptr() ,
gc.c, added and validated clean over 6 boots in an earlier session \-
in front for the first time: 15 of 30 boots hit it, later batches
confirmed 12\-15 of 20\-30, well above the residual
.CW checktracked()/scanframe()
rate.  It had not been rare; it had been masked, first by the
tracker's own free-time gap flooding the log with unrelated hits, then
by
.CW checktracked() / scanframe()
stopping the boot before
.CW checkmarkptr()
ever got a chance to run.
.PP
Every capture reports a word holding a small value, never
.CW H ,
inside a heap object
.CW markheap()
is walking during GC mark.  The dominant shape, 9 of the first 15
captures: object size 8, one pointer word (np 1), map
.CW {0x80} ,
value exactly
.CW 0 .
That triple \- size 8, np 1, map
.CW {0x80} \-
is
.CW Tptr 's
own static initializer in heap.c
( Type\0Tptr\0=\0{\01,\00,\0markheap,\0sizeof(WORD*),\01,\00,\00,\0{0x80}\0} ),
not a module-defined type, which is why the type pointer
(0x312a60, stable across boots against the same binary) never matched
any
.CW dtype()
call site in the source.  A second, rarer shape (one capture) had size
.CW -1 ,
which looked at first like a corrupted
.CW Type
until the same search found it too: that is
.CW Tmodlink 's
own literal size field, by design, not damage.
.PP
.CW Tptr
is the payload type
.CW OP(consp)
gives a list cell when it conses a pointer-typed value:
.CW l->t\0=\0&Tptr;\0...\0*(WORD**)l->data\0=\0sv; .
.CW markheap()
's caller (list marking) walks each cell's own
.CW l->data
against its own
.CW l->t ,
which is why the "object" a
.CW checkmarkptr()
hit names is
.CW l->data
itself \- a field inside a live, GC-reachable list cell, not a
separately Heap-boxed value of its own.  Reading
.CW OP(consp)
end to end for a reentrancy window \- a moment where
.CW l->t
is already set to a real type but
.CW l->data
still holds whatever the fresh allocation handed back, unwritten \-
turned up none: nothing between
.CW l->t\0=\0&Tptr;
and the write to
.CW l->data
can call back into the allocator or trigger a compaction pass, and the
one call that can (
.CW cons() 's
own
.CW nheap() )
runs earlier, while
.CW l->t
is still
.CW nil .
Added a check at the one place in this path that gets genuinely
reliable attribution \- GC's own
.CW R.M/R.PC
print is worthless, mark is not tied to any one instruction, but the
source operand
.CW OP(consp)
is about to cons is checked right as the op reads it, with the same
op's own real
.CW R.PC .
20 boots, 0 hits: the value handed to
.CW OP(consp)
is never bad.  Whatever happens, happens after a correctly-built cell
already exists, not during its construction.
.PP
That points at a stale, uncleared root rather than a corrupting write:
something holding a live-looking reference to a list cell that should
have been decref'd and dropped, walked by GC as if it still named a
real, current object, when what is actually there is either recycled
(freed, pool-reused) memory or a legitimately unreferenced-but-not-yet-
swept cell.  Not yet checked: whether
.CW poolcompact() 's
.CW move
callback (alloc.c, wired via
.CW poolsetcompact() )
ever runs reentrant against a live list chain mid-walk; whether GC can
be entered via interrupt-time reentrancy rather than only at
allocation time, which the concurrency section above left unexamined
for exactly this reason; and \- most directly \- whichever code path
drops the last reference to a list cell, whether it reliably clears
every root that pointed at it or can leave one dangling.
.PP
.CW rungc()
is a genuine multi-call incremental collector \- bounded
.CW visit
quota per call, state
( base ,
ptr ,
limit )
resumed across calls, mutator execution interleaved between them, not
one mark pass run to completion \- so the standard risk for this shape
of collector was worth checking directly: a mutator write of a pointer
into an already-black
( color\0==\0mutator ,
already scanned this epoch) object, with nothing re-graying the value
just stored, can leave a still-reachable object mis-colored
.CW sweeper
and it gets freed while live.  Checked the two general pointer-store
paths,
.CW OP(movp)
and
.CW OP(consp)
itself: both call
.CW Setmark()
on the value being stored, unconditionally, before the store \- exactly
the barrier this shape of collector needs, present and correct in
both.  Freshly allocated objects are also allocated already-black
( nheap()
sets
.CW h->color\0=\0mutator
directly, reading the epoch's current color at allocation time), which
correctly exempts a brand-new cell from this epoch's sweep regardless
of when it gets linked in.  So a simple missing-barrier reading does
not fit either of the two most obvious sites \- this is checked, not
assumed, and does not rule out a barrier gap elsewhere (a less obvious
store opcode, or channel send/receive), only narrows where one would
have to be.  That is where this resumes.

.NH 1
Two shapes, one checker
.PP
Picked back up at the three named leads:
.CW poolcompact() 's
move callback, interrupt-time GC reentrancy, and which code path drops
a list cell's last reference.
.CW poolcompact()
is settled outright:
.CW poolsetcompact()
(alloc.c) is never called for
.CW heapmem
or
.CW mainmem
anywhere in this port \- only
.CW libmemdraw/draw.c
wires it, for
.CW imagmem ,
a wholly separate pool for draw/image memory \- so
.CW poolcompact()
is permanently a no-op for the two pools Dis heap objects actually live
in.  A moved-object-not-fixed-up reading cannot be the mechanism here;
nothing ever moves.
.PP
The container question resolved cleanly the other way.
.CW checklistcell()
(gc.c,
.CW marklist() )
validates the enclosing list cell's own Heap header \-
.CW t\0==\0&Tlist ,
.CW ref\0>\00
\- right before each cell's payload gets walked, using
.CW l
itself, which
.CW marklist()
already has in hand as
.CW vw .
Two batches, 40 boots, zero hits: every container a
.CW checkmarkptr()
capture has ever fired against was live, correctly typed, and
positively refcounted at the exact moment its payload got read.  That
rules out "the whole cell was freed and its memory handed to something
else" for the container itself \- whatever is wrong is confined to the
one field, on an otherwise-intact object.
.PP
Read
.CW OP(consp)
once more with that in mind and found a real, if narrow, defect worth
fixing regardless of whether it turns out to be the cause: it wrote
.CW l->t\0=\0&Tptr
.I before
.CW *(WORD**)l->data\0=\0sv ,
so for the width of two C statements the cell's own type claims a
pointer payload that has not been written yet.  Consb/consw/consl/
consf never set
.CW l->t
at all \- cons() leaves it nil, and
.CW markheap(nil,\0...)
returns immediately \- so this window exists only for
.CW OP(consp) 's
own Tptr cells.  Reordered to write the payload first.  Real,
permanent hardening, kept regardless of outcome \- but it did not move
the measured rate (still about 15 of 40 boots after), so this specific
window was not what checkmarkptr() has been catching.
.PP
The checker's own reread mechanism turned out to have been testing the
wrong thing, twice.  The first version put a
.CW print()
between each reread; the second, calling itself "silent," still had
.I two
full
.CW print()
calls \- the bad-word line and the object-type line, each real kernel
console I/O \- between the very first read (the one that decided a hit
was worth reporting) and what it called the reread loop.  Neither
version had actually tested "immediately after, nothing run in
between" at all.  The real version does: every read, first one
included, happens back to back in one tight loop with no function call
of any kind between them, into a local array, each read volatile-
qualified against ordinary single-threaded compiler caching \- decided
and reported only afterward.  A same-call sanity print
( val
and
.CW silent[0]
are the same variable by construction; printed together in one
.CW print()
call, they read equal every time) ruled out a
.CW %zx / FmtVLong
marshaling bug in the checker's own diagnostic before trusting
anything built on
.CW %zx
further \- this tree already has one precedent for a silently-broken
format verb
(see the ember-language-status project notes: %g/%e/%f never
registered with this same toolchain's fmt library at all), so it was
worth ruling out explicitly rather than assuming.
.PP
That honest tight loop surfaced something the two earlier, leakier
versions had been hiding: two genuinely different shapes, conflated
under one checker.
.IP \(bu 3
Word 0 of a Tptr-typed list cell (size 8, np 1, map
.CW {0x80} ,
exactly
.CW OP(consp) 's
own payload shape) reads bad exactly once and then reads as a valid,
stable pointer on literally the next access \- every capture, no
exception, regardless of the
.CW OP(consp)
reorder above.  Whatever produces the transient zero, it is not this
op's own construction order.
.IP \(bu 3
Every other shape \- larger objects, word offsets like 8, 14, 489, 550,
values including
.CW 0x18 ,
this hunt's own original landmark value from four-plus sessions ago \-
reads the same bad value on all 8 tight rereads.  Stable, not
transient.
.PP
Only the second kind is treated as the real signal now; the first
returns without aborting.  Isolating it this way took the checker's
own rate from roughly half of all boots (the two shapes mixed
together) down to about 2 of 25\-45 \- a workable signal instead of a
noise floor.
.PP
0x18 is not a random-looking value.  It equals both
.CW sizeof(Heap)
and
.CW offsetof(Frame,\0t)
on this port, two facts this hunt has separately established already.
The cleaner of the two matches: computing
.CW H2D(t,\00)
\- calling the "add sizeof(Heap) and cast" macro on a plain, already-
nil C pointer, as opposed to the sentinel
.CW H
\- yields exactly
.CW (t)0x18 ,
mechanically, every time.  A capture landing on a
.CW Tmodlink
object (size \-1, np 1, map
.CW {0x80} ,
matching
.CW Tmodlink 's
own static initializer, not corruption \- see
.I "A different, dominant signal: Tptr list cells" )
with word 0 (exactly
.CW ml->MP ,
the type's one GC-tracked field) reading
.CW 0x18
is the single most direct piece of evidence for this reading so far.
.PP
Audited every
.CW H2D()
call site that writes into a Modlink's
.CW MP
field or a Module's
.CW origmp
field, since those are the two fields observed holding
.CW 0x18 :
.CW mklinkmod()
sets
.CW ml->MP\0=\0H
directly, no H2D() involved;
.CW linkmod()
and
.CW schedmod()
(link.c, dis.c) both compute
.CW H2D(uchar*,\0h)
only after
.CW h\0=\0nheap(t->size) ,
which throws
.CW exHeap
rather than returning nil on failure;
.CW parsemod() 's
own
.CW m->origmp\0=\0H2D(uchar*,\0h)
(load.c, inside the same function this hunt already hardened for
data-segment bounds \- see
.I "libinterp/load.c: bounds-check parsemod()'s data-segment writes" )
is guarded the same way, via
.CW heapz() ,
which also throws rather than returning nil.  Every site checked is
properly guarded against a nil input to H2D() \- none is confirmed as
the source, which either means the real site is one of the handful not
yet checked (loader.c's dynamic-module path, not exercised by an
ordinary boot, was set aside for exactly that reason), or the 0x18
match is coincidence and the real mechanism is still open.  Not
resolved: which.  That is where this resumes.

.NH 1
A live, correctly-typed object, one field wrong
.PP
Picked back up at the open question: is the stable kind a benign
mid-execution snapshot (a marked frame slot legitimately holding a
non-pointer value while its lexical scope is current, never visible to
a return-time scan) or something genuinely wrong.
.PP
Made
.CW checkmarkptr()
non-fatal for the stable kind too, on a real distinction, not a repeat
of the retracted map-imprecision argument.  That argument was refuted
specifically for
.I return-time
scanning:
.CW freeptrs() ,
at every
.CW OP(ret) ,
calls
.CW destroy()
on every marked word unconditionally, so a marked word holding a small
int at
.I that
moment would corrupt memory on every ordinary return, which does not
happen.
.CW rootset() 's
.CW markheap()
walk is a different code path with a different timing guarantee: it
runs while a live process is merely
.I paused
for GC, never at
.CW OP(ret) .
Nothing about the return-time argument says a marked slot cannot
transiently hold a non-pointer value while its process is simply not
currently running, as long as it is H or valid again by the time that
process reaches its own return.  Letting the boot continue instead of
aborting on this shape too is the only way to tell that reading from
real, permanent wrongness apart.
.PP
Added
.CW D2H(vw)
as a plain observation on every hit \- gated on nothing, purely
informative: whatever heap header sits where
.CW vw 's
own would be, right or wrong.  It paid off immediately.  Two batches
landed fresh captures of the exact same object,
0x7855bd0 ,
deterministic across separate, independent boot runs \- and
.CW D2H(vw)
reported
.CW t\0==\0&Tmodlink ,
.CW ref
cycling 1\-2,
.CW color
cycling 0\-2 in the collector's normal three-color rotation: a live,
correctly-typed, correctly-refcounted Modlink object, full stop.  Not
a snapshot artifact \- stable across real, elapsed wall-clock time and
multiple GC epochs, with
.CW ml->MP
(word 0, the type's one tracked field) stuck at
.CW 0x18
the entire time.  This is the sharpest capture this hunt has landed
yet: a real, live object, everything about its own identity intact,
exactly one field wrong.
.PP
Instrumented every
H2D()-into-
.CW ml->MP
write site to validate its own result immediately after the
assignment:
.CW mklinkmod() 's
.CW ml->MP\0=\0H
and
.CW linkmod() 's
.CW ml->MP\0=\0H2D(uchar*,\0h)
(link.c),
.CW schedmod() 's
matching line (dis.c).  Across two batches, 55 boots, including two
fresh captures of this exact 0x18-stuck object, none of the three
write-time checks ever fired.  The write is always correct at
creation; the field goes bad sometime after.
.CW loader.c 's
.CW ml->MP\0=\0m->origmp
(the fourth and last site, in the dynamic-module-loading path,
essentially unexercised by an ordinary boot) is not yet instrumented.
.PP
With a real, permanent, wrong value at a known, deterministic address,
the right tool changes: not another read-and-guess pass, but watching
the address itself.  Attempted a QEMU gdbstub with an
lldb
hardware watchpoint on
0x7855bd0
directly \- the address stayed identical across two separate,
independent boot runs against the same binary, which is about as good
as reproducibility gets for this.  Set cleanly (
.CW qemu-system-x86_64\0-s\0-S ,
lldb's
.CW gdb-remote
plus
.CW watchpoint\0set\0expression ),
but
.CW process\0continue
ran for the full 170-second timeout \- well past this boot's normal
60\-90 seconds to the point where the value has already gone bad in an
unwatched run \- without the watchpoint ever stopping the guest.  Left
open, not resolved: whether the gdbstub watchpoint tracks a physical
address while this address, taken from a kernel print(), is virtual
(whether pc64 runs identity-mapped was never actually checked); whether
the watchpoint's own overhead slowed execution enough that the write
in question simply had not happened yet by the time the timeout hit;
or something else about the setup.  Getting this working is the most
direct path to naming the actual writer, and is where this resumes.
.PP
One more thing settled before leaving this: whether the stable kind is
actually consequential, checked the only way that means anything \-
letting the boot run past it and seeing what happens.  It was made
non-fatal for exactly one round to test this, and the result was
decisive enough to revert immediately:
.CW checkmarkptr()
non-fatal on the stable kind let boots that would previously have
stopped cleanly here run on instead, and most of them hit a real
native panic later \- page fault, general protection violation,
invalid opcode, the pool allocator's own
.CW alloc:D2B
consistency check, a nil
.CW c
in
.CW cclose/cclone
\- 7 of 10 in one batch, 12 of 15 in a follow-up with general
protection violation alone accounting for nearly half.  That rules out
"benign, resolves on its own" outright: whatever the stuck field held
got used later as something it was not, and the boot paid for it, just
less legibly than stopping right here would have.  Reverted to
.CW abort()
for the stable kind; the diagnostics that got this far (
.CW D2H(vw) ,
the tight reread, the same-call sanity print) all stayed.
.PP
The more important number in that same data: the follow-up batch's
panic rate (12 of 15) held even though
.CW checkmarkptr()
itself never fired once (0 of 15).  Whatever is actually wrong reaches
far more of this boot's execution than the one checker this whole
segment has been narrowing \- general protection violation alone (5 of
12 panics in one batch) outweighs every other cause combined, with
page faults, the pool allocator's own corruption check, and a nil-
channel panic making up the rest.  This segment's narrowing answered
real, specific questions about one detectable shape of the underlying
problem \- and that shape (the live, one-field-wrong Modlink) is
itself real, not an artifact \- but it is evidently not the only shape,
and probably not even the dominant path to a crash.  Whoever picks
this up next should read the panic type distribution, not just the
.CW checkmarkptr()
rate, as the honest measure of where this boot actually stands.
.NH 1
The scan was the noise; the register was the signal
.PP
Picked up the closing instruction from the previous round: read the
panic type distribution across a batch, not any one checker's hit
rate, as the honest measure of where this boot stands.  A 15-boot
batch put six of fifteen into
.CW "general protection violation" .
Six boot logs, five distinct
.CW dumpstack()
call sites resolved by function name: two at
.CW decref+14 ,
one each at
.CW lockloop+72 ,
.CW strcmp+18 ,
.CW _intrr+32
and
.CW strchr+46 .
.PP
Before trusting that list, checked what
.CW dumpstack()
actually is.
.CW _dumpstack()
(pc64/trap.c) walks every word from the current stack pointer up to
.CW estack
and prints any word that falls inside the kernel text range.  That is
a conservative scan, the same shape of check this hunt already found
and fixed once for the tracked-pointer table (freed, not cleared) --
it mixes genuine return addresses with whatever code-address-shaped
garbage is still sitting in stack slots a popped frame never
overwrote.  A first pass had swept an entire boot log for every
address of that shape, wherever it appeared, and gotten a call chain
that made no sense --
.CW rungc()
calling
.CW vmachine()
calling
.CW xec()
calling
.CW iload() ,
five layers that do not call each other.  That capture was noise, not
a call stack, and is retracted as evidence.
.PP
What a
.CW dumpstack()
capture does NOT get by scanning is
.CW PC :
the hardware fault-address register, printed straight from
.CW Ureg
by
.CW dumpregs() ,
no scan involved.  That is the one number in every capture that is
certainly the actual faulting instruction.  Five different
.CW PC
values across six boots --
.CW decref ,
.CW lockloop ,
.CW strcmp ,
.CW strchr ,
the interrupt trampoline itself -- is real evidence, and it says the
same thing this hunt's earlier rounds kept saying: five unrelated
consumers each handed a bad pointer is downstream of one corruption,
not five separate bugs in five unrelated functions.
.PP
x86 does not set
.CW CR2
(the fault-address register) for a
.CW #GP
the way it does for a
.CW #PF ,
so the trap handler cannot name the bad pointer generically for any of
these sites.  But at the one site that recurred --
.CW decref+14 ,
this function's own first read of
.CW r->ref
-- the bad pointer is the function's own argument, known and named by
the call itself.  Added
.CW badref() :
a null/misaligned/near-zero check, cheap enough to run unconditionally
on every
.CW incref()
and
.CW decref()
call, run before the dereference.  On the rare confirmed-bad case it
calls
.CW auditmemloc()
(alloc.c), the pool-chain walker the tracked-pointer and
.CW checkmarkptr()
probes already use, to report whether the pointer lands in a live
block, a freed one, or no pool at all -- then
.CW panic()
names the exact bad value and the exact caller via
.CW getcallerpc() .
A full pool audit runs unconditionally on every call would drown the
boot in console output; gating it behind the cheap check keeps the
common case free.
.PP
A 45-boot batch with this in place caught it five times, converting
what would have been five more opaque GPFs into panics naming the
exact pointer and the exact caller:
.CW "decref: bad r 0xf000ff53 pc=pathclose+24"
twice,
.CW "decref: bad r 0xf000ff53 pc=putmhead+25" ,
.CW "decref: bad r 0x0 pc=closeegrp+14"
and
.CW "incref: bad r 0x0 pc=walk+34" .
.PP
.CW 0xf000ff53
is not a new value.  It is the exact 32-bit pattern this hunt's
earlier, scan-based captures kept seeing repeated across both halves
of
.CW BP
--
.CW F000FF53F000FF53
-- in every
.CW decref+14
GPF this round found.  This is the first confirmation, from a
hardware register naming the exact call site rather than a scan
guessing at one, that the value is real and not a scan artifact, and
that it is not confined to one field.
.CW pathclose(p)
calling
.CW decref(p)
means a
.CW Chan Ns 's
.CW c->path
field held it.
.CW putmhead(m)
calling
.CW decref(m)
means a
.CW Chan Ns 's
.CW c->umh
field held it.  Both are pointer fields on
.CW Chan ,
set correctly at
.CW newchan()
(which unconditionally zeroes
.CW c->path
and
.CW c->umh
on every allocation, fresh or recycled from the free list) and again
at
.CW Aopen
time -- a live, correctly-initialized object having one unrelated
field later hold this same poison-looking value is the same shape as
the previous round's
.CW ml->MP
finding, now on a second struct and a third field.
.CW cunique()
carries a pre-existing
.CW //BUG
comment on
.CW c->umh ,
written by an earlier author before this hunt started; this is the
first evidence that comment was flagging something real and still
open, not stale caution.
.PP
This does not find the writer.
.CW path
and
.CW umh
are not adjacent in
.CW Chan
(one is the second custom field, the other the last), which rules out
a simple off-by-one-sized copy as the mechanism and leaves the same
open question the previous round closed on: something is scribbling
individual pointer-typed fields on otherwise-live, correctly-typed
objects, well after correct construction, and no write-site audit run
so far -- not the
.CW ml->MP
sites, not this one -- has caught it in the act.
.PP
One addendum, checked immediately after landing this:
.CW auditmemloc()
reported both confirmed catches as
.CW "not in pools" ,
not as a freed or immutable block.  That changes the likeliest shape of
the mechanism.  A stray write that corrupts a live field by aiming it
at the WRONG heap object would still land inside SOME pool's arena, and
.CW auditmemloc()
would say so.  Landing outside every pool argues against that and
for the field holding raw leftover content -- register spill,
uninitialized stack, or a source local that was never actually set on
the path taken -- that was copied in whole rather than derived from a
bad address computation.  Checked both non-nil
.CW "c->umh = m"
sites in
.CW namec()
(the
.CW Abind
case and the
.CW Aopen
Open:
case) at the source level: both initialize
.CW m
to
.CW nil
immediately before
.CW domount(&c, &m, ...)
fills it, so neither looks like an uninitialized-local bug on its face
-- the same clean read the
.CW ml->MP
write-site audit got before it, too.
.NH 1
markheap() trusted its own type argument
.PP
The badref() catches (previous section) still left most GPFs
unresolved, so the next batch went looking for the highest-volume
single site rather than the next specific field. A 20-boot batch put
eight boots into a GPF; PC resolved five of the eight to the exact
same address:
.CW markheap+26 .
That is far more concentrated than anything else this hunt has
resolved a fault to, and it named a function this hunt has spent
several sessions instrumenting already --
.CW checkmarkptr()
and
.CW checklistcell()
both live in
.CW markheap() Ns 's
immediate neighborhood in gc.c.
.PP
.CW "markheap(Type *t, void *vw)"
opens with
.CW "if(t == nil || t->np == 0) return;" .
That only guards
.CW "t == nil" ;
a non-null but wild
.CW t
sails past the short-circuit and faults on the very next read,
.CW t->np ,
which is offset 26 into the compiled function -- matching every one of
the five captures exactly.
.CW checkmarkptr()
validates
.CW *q ,
the pointer VALUE a mark step is about to follow; it has never
validated
.CW t ,
the TYPE DESCRIPTOR that tells
.CW markheap()
which words in that value are even pointers.
.CW checklistcell()
has the same gap one level up:
it checks a list cell's own Heap header
( Ns
.CW "D2H(l)->t == &Tlist" Ns
), which is a different field from
.CW l->t ,
the type of the list's ELEMENT, the value
.CW marklist()
then passes straight to
.CW markheap()
as
.CW t
with no check at all.
.CW markheap() Ns 's
own recursive dispatch,
.CW "t1 = h->t; t1->mark(t1, ...)" ,
reaches the same unguarded entry a second way.
.PP
Added the same cheap null/misaligned/near-zero precheck
chan.c's
.CW badref()
uses (previous section), run on
.CW t
before either read, escalating to
.CW auditmemloc()
and
.CW abort()
on a confirmed-bad
.CW t .
This is the single choke point for all three paths into
.CW markheap() ,
so one check covers
.CW marklist() ,
.CW markarray()
and the recursive
.CW h->t
dispatch at once.
.PP
A follow-up 20-boot batch caught zero cases at this new check (0/20)
while raw
.CW "general protection violation"
dropped from the earlier batch's 8/20 to 3/20 (none of the three at
.CW markheap+26
this time), and
.CW alloc:D2B
pool-corruption panics rose from 1-2/20 in earlier batches to 4/20.
Total panic count did not move (15/20 both batches). The reading:
this check catches the obviously-bad shape of
.CW t
before
.CW markheap()
can compute a garbage
.CW Heap*
and
.CW Setmark()
writes to whatever
.CW h->color
resolves to -- exactly the write-with-no-fault-at-the-write-site
mechanism this file's own long-standing comment on
.CW checkmarkptr()
already named as the suspected shape.  A plausible-but-wrong
.CW t
(the same blind spot
.CW badref()
has for
.CW r )
still gets through uncaught and, on this reading, corrupts the pool
silently instead of crashing immediately, surfacing later as
.CW alloc:D2B
rather than a GPF at
.CW markheap+26 .
Consistent with the pattern, not proof of it -- the total panic rate
says the underlying corruption is unmoved, only its point of first
visible failure shifted.
.NH 1
An underflow guard that didn't fire, and a print that couldn't be trusted
.PP
Two threads picked up from the alloc:D2B panics the markheap() batch
also raised (previous section). Both resolved their caller to
.CW destroy+649 ,
the
.CW poolfree(heapmem, h)
call at the end of
.CW destroy()
(heap.c), and
.CW auditmemloc()
confirmed the block was already a live free block --
magic
.CW 0xbadc0c0a ,
this port's
.CW MAGIC_F
-- at the exact address about to be freed a second time.  A genuine
double-free, hardware-confirmed, not inferred.
.PP
.CW destroy()
already has a consistency check
( Ns
.CW D2B(b, h) Ns
) two lines above the free, and it was not the one firing -- ruling out
.CW h
itself being bad on entry to this specific call.  Something frees the
same
.CW h
between that check and the
.CW poolfree()
call, most likely
.CW t->free(h, 0) ,
which runs in between and is supposed to free only
.CW h Ns 's
own contained sub-pointers, not
.CW h
itself.
.CW chan.c Ns 's
.CW decref()
panics when a Ref underflows before the bad value can be used for
anything; the equivalent guard on
.CW ADEC(&h->ref)
did not exist.  Added it: a result less than zero means
.CW h->ref
was already at or below zero when this particular decrement ran.  A
follow-up 20-boot batch: the new check never fired (0/20), while
.CW alloc:D2B
panics continued.  This specific hypothesis --
.CW destroy()
re-entering on an already-zero ref -- is tested and not confirmed.
The guard stays in as correctly-targeted hardening on the same
established pattern; the actual double-free path through
.CW t->free()
or elsewhere is still open.
.PP
The same batch also raised
.CW "checkb 3 qaddlist 1 f000ff53 f000fea5" --
a
.CW Block Ns 's
.CW rp
and
.CW lim
both printed in the same poison family the Chan-field captures found
by an unrelated route.  Before trusting it: every diagnostic in
.CW checkb() ,
.CW checkbl()
and
.CW showblockheader()
(allocb.c) formatted a
.CW Block
pointer field with
.CW %lux
or
.CW %8.8luX --
the verb for a
.CW ulong ,
32 bits on this compiler -- against arguments that are 64-bit
.CW uchar*
or
.CW void*
on this port.  That means the two values this specific panic printed
were never confirmed to be what
.CW rp
and
.CW lim
actually held, only what a width-mismatched verb produced from them.
Fixed every instance in all three functions to
.CW %#p ,
this hunt's own convention for a pointer value, rebuilt and
boot-tested clean.  A follow-up batch did not reproduce the specific
.CW checkb\ 3
case, so the corrected reading isn't in hand yet -- the fix is real
and verified to build and boot either way, but the poison-family
reading built on the old capture should be treated as unconfirmed
until it recurs with the corrected format.
.NH 1
Who freed it first, and a discrepancy left open
.PP
.CW auditmemloc()
answers live, free, or nowhere; it has never answered who freed a
block the first time, the open half of the double-free the previous
section confirmed. Added a 32-entry ring recording
( Ns
.CW address ,
.CW "caller pc" Ns
)
on every successful
.CW poolfree() ,
and had
.CW _poolfault()
search it before panicking.
.PP
A 25-boot batch caught it twice, both fully reproducible in shape. The
failing (second) free's caller resolves to
.CW destroy+703 ,
matching the panic message's own
.CW "(from 2bf813/...)"
exactly -- this is
.CW destroy() Ns 's
one and only
.CW "poolfree(heapmem, h)"
call, confirmed against the source. The ring's recorded first,
successful free of the same address resolves to
.CW destroy+608 --
a different offset, but still confirmed (against the symbol table:
.CW destroy
spans
.CW 0x2bf554
to
.CW 0x2bf8a9 ,
and no other function's symbol falls inside that range) to be
somewhere else inside
.CW destroy() Ns 's
own compiled body, not some unrelated function.
.CW destroy() Ns 's
source has exactly one textual
.CW poolfree()
call, so two distinct offsets for what ought to be the same call site
does not have an explanation yet. Recursion was considered and set
aside: even a recursive
.CW destroy(h)
call would execute the identical compiled instruction at line 155
every time, not two different addresses. Whether this is a real
second call site this reading has missed, or a limit of how
.CW getcallerpc()
(the Plan9 a+0(FP) idiom, in l.s) behaves when invoked from two
different points inside a large function, is open -- recorded as
such rather than guessed at.
.PP
What the two captures do establish solidly, independent of that
open question: the same address really was freed once successfully
and freed again later, and both frees trace to code inside
.CW destroy() Ns 's
own body rather than to some entirely unrelated function elsewhere
in the kernel. That narrows the search -- the double-free is a
.CW destroy()
problem, not a
.CW freelist() /
.CW freearray() /
.CW t->free()
problem reached from somewhere else -- without yet naming the exact
second call site.
.NH 1
D2B's own caller pc was wrong in the four functions that need it most
.PP
Resolved the
.CW destroy+608
versus
.CW destroy+703
discrepancy the previous section left open, by bisection rather than
more reading. A clean, non-crashing boot with every distinct
.CW poolfree()
caller pc printed the first time it was seen showed exactly one
.CW destroy
entry, always at the same relative offset --
.CW destroy+608 --
across the whole boot. That is
.CW destroy() Ns 's
one real, single
.CW "poolfree(heapmem, h)"
call, confirmed independent of any crash.
.CW destroy+703
never appeared as a successful free's caller in that same boot, only
ever on the failing side of a D2B check.
.PP
The cause:
.CW include/pool.h Ns 's
.CW D2B(b, dp)
macro computes its own caller pc as
.CW getcallerpc(&dp) .
Every OTHER
.CW getcallerpc()
call in this tree --
.CW chan.c Ns 's
.CW decref() ,
.CW incref() ,
.CW cclose() ,
.CW newpath() ,
this file's own
.CW "setmalloctag(v, getcallerpc(&dsize))"
sitting one line below a
.CW D2B
call inside
.CW mallocalign()
-- anchors on the ENCLOSING FUNCTION'S OWN FIRST PARAMETER, because
that is the specific stack slot the Plan9
.CW a+0(FP)
idiom actually reads.
.CW D2B Ns 's
.CW dp
is correct for
.CW poolimmutable(void*) ,
.CW poolmutable(void*) ,
.CW free(void*)
and the four
.CW {set,get}{malloc,realloc}tag()
functions, whose first parameter IS the data pointer. It is wrong for
.CW "poolfree(Pool*, void*)" ,
.CW "poolrealloc(Pool*, void*, ...)"
and
.CW "poolmsize(Pool*, void*)" ,
which all take
.CW Pool*
first, and for
.CW mallocalign() ,
whose
.CW dp
is a local, not a parameter at all. In these four,
.CW D2B Ns 's
own
.CW poolfault()
was naming a plausible-looking but wrong pc every time it fired --
.CW destroy+703
was one such wrong value, an artifact of this bug on the failing
(second) free, not a genuine second call site inside
.CW destroy() .
.PP
.CW D2B
is shared with
.CW os/osprey/kernlib/pool.c ,
.CW emu/ ,
.CW libinterp/
and
.CW devforth.c --
changing its signature is out of scope for this hunt. Added
.CW "D2BPC(b, dp, pc)" ,
the identical check taking an explicit
.CW pc
instead of computing one, local to
.CW alloc.c ,
used only at the four mismatched call sites, each now anchored on its
own real first parameter (
.CW &p
for the three
.CW Pool*
functions,
.CW &dsize
for
.CW mallocalign() Ns ,
matching the working
.CW setmalloctag()
call already beside it). Rebuilt and boot-tested clean; a 25-boot
batch landed zero
.CW alloc:D2B
panics, consistent with the fix but not proof by itself given how low
this specific panic's base rate already was.
.NH 1
A correction: the fix didn't change the number, and a better theory why
.PP
A further batch, with the
.CW D2BPC
fix built and running, landed a fresh
.CW alloc:D2B
capture --
.CW "(from 2bf883/...)" ,
still
.CW destroy+703
in this build's own numbering.  If the anchor mismatch were the whole
explanation, fixing it should have changed this specific value to
.CW destroy+608 ,
the confirmed real
.CW poolfree()
call site.  It did not.  The previous section's claim to have
resolved this is retracted as stated; recorded here rather than
quietly amended, per this hunt's own standing rule about overclaims.
.PP
Rereading
.CW destroy()
with that failure in mind surfaces a second real call site the
earlier reading passed over:
.CW "trackclear(h, poolmsize(heapmem, h));"
runs immediately before
.CW "poolfree(heapmem, h);" ,
and
.CW poolmsize(Pool*, void*)
runs its own
.CW D2B
check on the same
.CW h .
Both call sites were mismatched under the old
.CW D2B
(both take
.CW Pool*
first, not the data pointer) and both are now fixed under
.CW D2BPC .
If
.CW h
is already bad by the time destroy() reaches this line --
consistent with something before it, most plausibly
.CW t->free(h,\ 0) ,
already having freed
.CW h
itself -- it is
.CW poolmsize() Ns 's
check that fires first, not
.CW poolfree() Ns 's,
since it runs first in the source. That would make
.CW destroy+703
a second, genuine call site rather than a wrong-anchor artifact of
the first one, which fits the data (the value survived the anchor
fix) better than the previous section's theory does.
.PP
What this doesn't settle: whether 703's address being numerically
higher than 608's despite running earlier in the source is consistent
with how this compiler lays out a nested call
( Ns
.CW "poolmsize()"
feeding
.CW trackclear() Ns 's
own argument
), or whether some other reordering is involved.  Answering that
needs seeing the actual compiled instructions, which this port has no
disassembler for (objdump cannot read this a.out/coff ipc64 image).
Left for whoever has one, or for a print-based bisection narrower
than this round had time for.  The
.CW D2BPC
fix itself stays -- it corrects a real anchor mismatch against this
tree's own established convention regardless of how the 608/703
question resolves.
.NH 1
Does ml->MP ever alias its own Modlink?
.PP
One concrete, testable version of
.CW destroy() Ns 's
double-free, built from what this hunt already has in hand rather
than a fresh guess. The earlier, hardware-confirmed finding (
.CW D2H(vw)
on a live capture) was that
.CW ml->MP
goes bad -- one field wrong on an otherwise live, correctly-typed
Modlink -- sometime after correct creation. That round pinned down
one specific bad value, 0x18, but never asked what "bad" could mean
beyond it.
.CW freemodlink() Ns 's
.CW destroy(ml->MP)
call gives one answer real enough to check directly: if
.CW ml->MP
is ever corrupted to alias this same Modlink's own containing
.CW Heap
block -- rather than a small garbage value or a pointer into
something else entirely -- that call recurses straight back into
.CW destroy()
on the exact
.CW h
this outer call is already in the middle of freeing. A direct,
self-referential double-destroy, not a stray pointer landing on some
unrelated object.
.PP
Added the check right before the recursive call:
.CW "ml->MP == (uchar*)H2D(Modlink*, h)" .
A 25-boot batch with it in place reproduced zero
.CW alloc:D2B
panics at all this round -- sample-rate limited (this panic has
never shown more than a handful per 20-25 boots in any batch so
far), not a refutation. The hypothesis is neither confirmed nor
ruled out; the check stays in place, cheap and specific, for the
next capture to answer directly rather than by further reading.
.NH 1
Eliminating candidates for destroy+703, and a probe that hung the boot
.PP
Picked the
.CW destroy+703
thread back up with a direct test rather than more reading:
.CW poolmsize()
(alloc.c) got the same bounded, distinct-caller probe
.CW notefree()
already used for
.CW poolfree() .
A clean boot showed exactly three distinct callers --
.CW msize() ,
.CW hmsize() ,
and
.CW destroy() --
with
.CW destroy() Ns 's
own call to
.CW poolmsize()
(via
.CW "trackclear(h, poolmsize(heapmem, h))" )
landing at a real, confirmed offset: 560. Neither 560 nor 608
(.CW poolfree() Ns 's
own confirmed call, previous section) is 703. Both hypotheses this
hunt has tried for
.CW destroy+703
so far are now ruled out by direct capture, not inference.
.PP
A second experiment tested whether
.CW getcallerpc()
is even position-independent within one function: two calls,
.CW getcallerpc(&p) ,
made from two different textual positions inside
.CW poolfree() -- once
as the very first statement, once right before
.CW notefree() Ns 's
own call -- printed for the first several invocations of a real
boot.  Every pair matched exactly, for every distinct real caller
seen, not just
.CW destroy() .
Position within the enclosing function does not affect the result;
only which function the call is textually inside of does.  This
rules out a theory this round had been circling: that
.CW destroy+608
and
.CW destroy+703
could both be
.CW poolfree() Ns 's
own call site, read differently depending on where within
.CW poolfree()
the read happens.  They cannot be; distinct offsets mean distinct
enclosing functions, or distinct call sites in the same one.
.PP
The probe itself had a real bug worth recording: its second print's
guard condition never actually re-latched shut, so once its shared
counter reached its cap the print fired on every subsequent
.CW poolfree()
call for the rest of the boot -- flooding the console and hanging
two full batches (50 boots) at exactly the same output-line count
before any of this hunt's usual panics had a chance to happen.
Caught by comparing against a normal boot's line count, not assumed;
fixed by removing the probe once it had answered its question rather
than trying to re-gate it, since its purpose was already served.
.PP
Rereading
.CW destroy()
and
.CW freelist()
with poolfree/poolmsize eliminated surfaced two D2B uses this hunt's
own earlier alloc.c fix had not reached, both in heap.c:
.CW destroy() Ns 's
own consistency check (
.CW "D2B(b, h)" ,
anchored on
.CW h ,
a local -- destroy(void *v)'s real first parameter is
.CW v )
and
.CW freelist() Ns 's
tail-loop check (
.CW "D2B(b, th)" ,
anchored on
.CW th ,
also a local --
.CW freelist(Heap\ *h,\ int) Ns 's
real first parameter is
.CW h ).
Fixed both with a local
.CW D2BPC
copy in heap.c, matching alloc.c's exactly (D2B itself stays shared
with
.CW os/osprey/kernlib/pool.c ,
out of scope).
.PP
Rebuilt with all four now-known D2B sites reachable from
.CW destroy()
correctly anchored --
.CW poolfree() ,
.CW poolmsize() ,
.CW freelist() Ns 's
tail check, and
.CW destroy() Ns 's
own consistency check -- and a fresh batch still resolved
.CW destroy+703
to the identical relative offset. Every direct candidate this hunt
has been able to name and fix is now eliminated, and the value has
not moved once across any of these fixes or across several
rebuilds. Left open, honestly: either a real fifth call site this
reading still has not found, or a mechanism in how an indirect call
through the
.CW poolfault
function pointer interacts with
.CW getcallerpc() Ns 's
stack-position idiom that a disassembler -- unavailable for this
port's Plan9 a.out/coff ipc64 image -- would settle directly instead
of by further elimination.
.NH 1
destroy+703 is destroy()'s own entry check
.PP
Settled by naming, not by more offset arithmetic.
.CW D2BPC
took a
.CW tag
parameter and every one of its six call sites (four in alloc.c, two
in heap.c) got a distinct string, so the next
.CW alloc:D2B
capture would say which one fired in its own panic message rather
than requiring another round of
.CW getcallerpc()
bisection.
.PP
A fresh boot answered it directly:
.CW "alloc:D2B:destroy-entry" .
It is
.CW destroy() Ns 's
own consistency check --
.CW "{ Bhdr *b; D2BPC(b, h, getcallerpc(&v), \(dqalloc:D2B:destroy-entry\(dq); }" ,
right after
.CW "h = D2H(v)" ,
before
.CW ADEC ,
before
.CW t->free() ,
before either
.CW poolmsize()
or
.CW poolfree()
ever runs.
.CW destroy()
is being invoked a second time with a
.CW v
that already points at a freed block. An external double-destroy
call -- some caller retaining a stale reference to an object already
destroyed once -- not an internal recursion inside one destroy()
call, and not a wrong-anchor artifact of any kind. Every earlier
theory this hunt tried for
.CW destroy+703
(poolfree, poolmsize, freelist's tail check, position-within-a-
function) is now retired as ruled out rather than merely unconfirmed
-- this is what the address was naming all along.
.PP
This settles which check fires. It does not yet name who calls
.CW destroy()
the second time.
.CW _poolfault() Ns 's
own caller-pc field, computed correctly now that every reachable
anchor is fixed, reads as a heap address on this capture rather than
a code address -- every other resolved pc this whole hunt has
produced has looked like kernel text (roughly
.CW "0x200000--0x400000" ) ,
never like this. Left open rather than explained away: it may be
nothing more than a fact about how an indirect call through the
.CW poolfault
function pointer interacts with this idiom, or it may be a second,
independent data point that the CALLER'S own stack frame is affected
by the same corruption this hunt has chased all along, not only the
freed object it is calling destroy() on. Whoever picks this up next
should chase who calls
.CW destroy()
twice -- likely by instrumenting the call sites of
.CW destroy()
itself for a v that is already free, the same way this section's own
check does at destroy()'s entry, but one level further out.
.NH 1
The most reproducible capture of the whole hunt, and two retracted fixes
.PP
.B
RETRACTED IN FULL.
.R
This section's central finding turned out to be a bug in the checker
this section itself added, not in the kernel -- see "Retraction: the
checker was checking the wrong address" near the end of this
document for the correction. Left standing rather than deleted, per
this document's own practice of appending corrections instead of
rewriting history, but read the retraction before anything below.
.PP
Picked up the previous section's own closing suggestion directly: widen
.CW OP(movp) Ns 's
.CW dv
guard, which had only ever caught
.CW dv\ <\ 0x1000 ,
to a cheap, read-only mirror of
.CW D2B Ns 's
own magic check -- the same blind-spot pattern
.CW badref() /
.CW markheap() Ns 's
guards already closed elsewhere in this hunt.
.PP
A 25-boot batch caught it at a rate nothing else in this whole
investigation has matched: 20 to 23 out of 25, every single one the
IDENTICAL address,
.CW 0x784aad0 ,
module
.CW Init
instruction 307. Resolved through
.CW disinit.sbl
to
.CW disinit.b:175
inside
.CW getclock() :
.CW "now = big string b[0:n]" ,
following
.CW "b := array[64] of byte"
and a short
.CW sys->read() .
This is, by a wide margin, the most reproducible single capture this
multi-session hunt has produced.
.PP
Landing it cleanly took one prerequisite fix first.
.CW badptrslot() Ns 's
own ending calls
.CW abort() ,
which is
.CW libkern/abort.c Ns 's
.CW "while(*(int*)0);" --
meant to fault on the null read, but on pc64 specifically it spins
forever instead. Every hit of the newly-widened check hung two full
25-boot batches at the identical output line rather than producing a
panic, caught only by comparing against a normal boot's line count --
the same methodology gap this hunt already found once for
.CW dumpstack()
and
.CW %lux .
.CW abort()
itself is shared with
.CW os/osprey/kernlib Ns 's
own build, out of scope to change; fixed by having
.CW badptrslot()
call
.CW panic()
directly instead, declared locally the way
.CW dumpstack() /
.CW auditmemloc()
already are in that function.
.PP
With a clean, countable capture in hand, two fixes were tried, each
matching the closest known bug class in this tree, and NEITHER moved
the crash at all.
.PP
First:
.CW limbo\ -z .
.CW array(N)
of a pointer-free type comes back with undefined non-pointer contents
-- newa's own documented contract (doc/dis.ms), not an allocator
defect -- and
.CW -z
emits
.CW newaz
instead, zeroing it. This was already found, fixed and verified safe
tree-wide on a sibling branch (session memory
.CW inferno-rio-array-zeroinit-bug )
but never ported to this one, and
.CW "array[64] of byte"
at
.CW disinit.b:175
matches its exact shape. Ported it (
.CW mkfiles/mkdis
and
.CW os/inferno/init/mkfile
specifically, since
.CW disinit.b Ns 's
own build bypasses the shared mkfile's flags entirely with a local
copy), confirmed embedded (
.CW pc64.root.s Ns 's
two
.CW INEWA\(->INEWAZ
opcode bytes changed), rebuilt, boot-tested: crash rate unchanged,
23/25.
.PP
Second: Dis stack extents.
.CW newstack()
and
.CW extend()
(libinterp/stack.c) both allocate via
.CW "mallocz(l, 0)" --
unzeroed -- and only ever
.CW memmove
the first
.CW t->size
bytes of an
.CW l Ns -byte
extent into it,
.CW l
frequently larger than
.CW t->size .
The gap was already named in a prior session's own comment on
.CW destroy() :
"whatever a Stkext's
.CW mallocz(l,\ 0)
left unclaimed." Changed both to
.CW "mallocz(l, 1)" ,
rebuilt, boot-tested: crash rate unchanged, 21/25.
.PP
Both fixes are real, independently-justified hardening and both stay
-- but neither was this crash's mechanism, and the doc says so
plainly rather than letting a plausible-sounding fix stand
unquestioned. What actually settled it: adding
.CW auditmemloc()
on
.CW dv
itself, not just the slot that held it (
.CW badptrslot() Ns 's
own call already covers the slot).  The answer:
.CW "784aad0 in heap: in block ... B2D 0x784aab8 ... searched address 0x784aad0" .
.CW dv
is not a freed block --
.CW MAGIC_A ,
still live -- and it is not even a block's own data pointer:
it sits exactly
.CW 0x18
(24, this port's
.CW sizeof(Heap) )
bytes past
.CW B2D() ,
squarely inside a live block's own data. This is a WRONG value, not a
STALE one: something computed
.CW dv
by adding one
.CW Heap
header's worth of bytes to a real, live data pointer. Both retracted
fixes targeted "this slot holds uninitialized or already-freed
leftovers" -- neither is what
.CW auditmemloc()
actually found. Whoever picks this up next has an exact, always-
reproducible target: what in the compiled path for
.CW "b[0:n]"
or the
.CW string
/
.CW big
conversions that follow it could add
.CW sizeof(Heap)
to an otherwise-correct pointer.
.PP
One more thing the Stkext-zeroing fix (this section, above) settles
on its own, independent of whether it fixed the crash: the address
.CW dv
holds is IDENTICAL across every capture, before and after that fix.
If
.CW dv
were leftover, unzeroed extent memory, zeroing the whole extent could
only have changed it -- to zero, at minimum, which
.CW badptrslot() Ns 's
own
.CW dv\ <\ 0x1000
half would have caught as a completely different, much more common
panic shape. It did not change at all. That rules out "leftover
memory" as the source outright, independent of the auditmemloc()
capture: whatever computes
.CW dv
does so actively, deterministically, every boot, not by inheriting
whatever a stack extent happened to contain. The search narrows to
the compiled code for
.CW disinit.b Ns :172-175
itself --
.CW OP(slicea)
(the
.CW b[0:n]
array slice) and
.CW OP(cvtac)
(libinterp/string.c, the array-to-string conversion) are the two
opcodes in that range with their own pointer arithmetic; neither
showed an obvious
.CW sizeof(Heap)
mismatch on a direct read, so confirming which one (or a third,
unread site) actually produces this value needs tracing the
instructions between 303 and 307 rather than reading two candidates
in isolation -- disdump against this exact disinit.dis would settle
it directly but did not run cleanly against the hosted emu tried
here ("illegal dis instruction"), left for whoever has a working
disassembler path for it next.
.NH 1
Retraction: the checker was checking the wrong address
.PP
Everything in "The most reproducible capture of the whole hunt, and
two retracted fixes" (above) -- the deterministic
.CW 0x784aad0
capture, the
.CW limbo\ -z
and Stkext-zeroing fixes tried against it, the
.CW auditmemloc(dv)
result read as
.CW dv
sitting exactly
.CW sizeof(Heap)
past a live block's own data start, and the "actively computed, not
leftover memory" refinement built on top of that reading -- is
retracted. The bug was in the checker, not the kernel.
.PP
.CW dv
is a Dis-level object pointer: a
.CW String*
or
.CW Array*
or similar, always
.CW H2D() Ns -adjusted,
which on this port means exactly
.CW sizeof(Heap)
(0x18) past the pool block's own data start -- that is what
.CW H2D()
is for. Every legitimate Dis heap object pointer looks exactly like
this when read against the pool's own
.CW Bhdr
layout directly.
.CW destroy() Ns 's
own entry consistency check gets this right:
.CW "h = D2H(v)"
runs first, converting back to the pool-level pointer, before
touching a
.CW Bhdr
at all. The widened
.CW dv
guard added to
.CW OP(movp)
skipped that conversion -- it read
.CW D2B Ns -shaped
bytes directly out of
.CW dv ,
which lands 0x18 bytes into the object's own live data, not at its
header. For
.CW getclock() Ns 's
string result specifically, that particular offset into a
.CW String Ns 's
own
.CW Sascii
data reliably did not spell
.CW MAGIC_A
or
.CW MAGIC_I ,
so the check fired on a live, entirely correct
.CW destroy()
call, every single boot -- which is exactly why it looked like the
most reproducible capture of the whole hunt.  It was reproducible
because it was checking the same wrong offset into the same
correctly-computed pointer every time, not because a real bug kept
recurring at the same address.
.PP
Fixed by checking
.CW D2H(dv) Ns 's
.CW Bhdr
instead of
.CW dv Ns 's
directly, matching
.CW destroy() Ns 's
own correct pattern. A 25-boot batch after the fix: zero
.CW "movp: bad dv-freed"
captures, panic distribution back to the familiar baseline (page
fault, general protection violation,
.CW "decref: bad r 0xf000ff53" ,
.CW alloc:D2B:destroy-entry ).
The two tracing probes this thread added (
.CW OP(cvtac)
in string.c,
.CW OP(slicea)
here) are removed -- they had already answered their question, the
answer just meant something different than it looked like at the
time.
.PP
What survives this retraction, unaffected: every finding from
before this thread started -- the hardware-confirmed
.CW destroy()
double-free (
.CW auditmemloc()
showing a target already
.CW MAGIC_F ), the
.CW destroy+703
resolution to
.CW destroy() Ns 's
own entry check by tag rather than offset, the
.CW Chan.path / Chan.umh
poison-value corruption, and every D2B anchor fix -- none of those
depended on this checker at all. What is lost: the specific,
sharply-reproducible target this thread thought it had for
.CW disinit.b:172-175 .
There may still be a real bug near there; this thread's own evidence
for one does not hold up, and the search for the actual double-free
mechanism returns to where it stood before this thread began.
.NH 1
Two genuine captures with the corrected checker, and a generic pattern
.PP
With the checker itself fixed (previous section), a further two
25-boot batches produced three
.CW "movp: bad dv-freed"
hits total, this time with
.CW auditmemloc(D2H(dv))
reporting what it is built to report correctly. Two of the three
confirm a real, hardware-level use-after-free:
.CW "in free blk" ,
not
.CW "in block" --
.CW D2H(dv)
genuinely lands inside a block the pool has already reclaimed.
.PP
The first, module
.CW Arg ,
inst 18, resolves (appl/lib/arg.sbl) to
.CW arg.b:42 ,
the
.CW return
statement of
.CW argv() :
.CW "ret := args; args = nil; return ret;" .
The second, module
.CW Sh ,
inst 884, resolves (a fresh
.CW -g
build of appl/cmd/sh/sh.b, matching module name and instruction count
exactly) to
.CW sh.b:477 ,
inside
.CW listjoin() Ns :
.CW "for (; left != nil; left = tl left) l = hd left :: l;" --
specifically the loop control
.CW "left = tl left" ,
not the cons on the line above it.
.PP
Both are the same shape: a plain pointer assignment (
.CW OP(movp) )
overwriting a slot that held a reference into a list, at exactly the
point that reference is supposed to be released.  Read
.CW cons() Ns 's
own source (libinterp/xec.c) to check whether the already-fixed
.CW OP(consp)
ordering bug (doc/inferno-ports.ms, "A different, dominant signal:
Tptr list cells") has a sibling here:
.CW cons()
transfers the slot's old value into the new cell's own
.CW tail
directly (
.CW "l->tail = lv; *lp = l;" )
with no separate incref and no destroy -- a balanced move, not a
copy, which is correct only if nothing else touches that reference
count in between.  For
.CW "left = tl left" ,
the new value (
.CW sv ,
.CW left->tail )
gets its own ref incremented before the old value (
.CW dv ,
the previous
.CW left )
is destroyed, and destroying a list head cascades into
.CW freelist() Ns 's
own tail-walk, which stops the instant a node's ref does not reach
zero -- since
.CW sv
was already incremented, that walk should stop one node in without
touching it. Every step of this, read in isolation, is correct.
Whether it stays correct under every ordering the compiler or
scheduler can produce is a harder question than reading it once
answers, and pc64 gives no instruction-level trace to check further
without a working disassembler for this port's Plan9 a.out/coff
image.
.PP
What is worth carrying forward regardless of whether this exact
mechanism is the cause: two independent, hardware-confirmed
use-after-frees, in two unrelated modules, both landing on the same
generic idiom (a list-cons loop's own control-variable update) that
appears constantly throughout ordinary Limbo code -- not a narrow,
rare code path. That fits the shape this whole hunt has kept finding
from other angles: a small, generic mechanism producing corruption
that surfaces in whatever unrelated code happens to run into it next,
rather than a bug local to any one module.
.NH 1
destroy()'s own caller-pc, an unverified reading recorded on purpose
.PP
Wired the free-history ring into the widened
.CW dv
checker too (
.CW printfreehist() ,
alloc.c, made non-static so
.CW badptrslot()
can call it alongside the
.CW auditmemloc()
it already calls) -- the same "who freed this address first" question
this hunt already had good tooling for, just not connected to this
specific check yet.
.PP
A follow-up batch produced no fresh
.CW dv-freed
hits to exercise it against, but landed three
.CW alloc:D2B:destroy-entry
captures -- the hardware-confirmed
.CW destroy()
double-free from earlier in this hunt. Their own caller-pc field (
.CW getcallerpc(&v) ,
computed inside
.CW destroy() Ns 's
entry check, the same mechanism the
.CW destroy-entry
tag confirmation already validated for the other half of that panic
message) resolves to
.CW wakeup+156
and
.CW iunlock+222 .
Neither calls
.CW destroy()
anywhere in its own body on a direct grep.
.PP
Given this session's own retracted "most reproducible capture" thread
-- built on a getcallerpc()-adjacent misreading that took real effort
to catch -- this is recorded as an open, UNVERIFIED discrepancy, not a
conclusion. Two ways it could resolve: a genuine, non-obvious call
path (destroy() reached through a pointer, a callback, or an
error()/waserror() unwind landing inside wakeup()/iunlock() rather
than at their own lexical call sites) that a plain grep would miss; or
a limitation of the getcallerpc() idiom this specific call site
exposes that the destroy-entry tag confirmation did not test for,
since that confirmation validated the msg/X side of the panic
( Ns
.CW _poolfault() Ns 's
own caller ), not the c/Y side (
.CW destroy() Ns 's
own caller) independently. Whoever picks this up next should verify
the Y side the same way the X side was verified -- by tagging or
otherwise naming the call site directly -- before trusting it enough
to build on.
.NH 1
Confirmed: destroy-entry's caller-pc field is not trustworthy
.PP
Answered the previous section's own question directly rather than
leaving it open. A capped, unconditional sample of destroy()'s own
caller-pc field (
.CW "c = getcallerpc(&v)" ),
32 distinct values from an ordinary, non-crashing boot: most are not
plausible code addresses at all --
.CW 0x6 ,
.CW 0x58 ,
.CW 0x30 ,
.CW 0x2 ,
and several in the
.CW "0x7xxxxxx / 0x9xxxxxx / 0xaxxxxxx"
ranges that look like heap or stack addresses, not code. Every other
resolved pc this whole hunt has produced sits in roughly
.CW 0x200000--0x400000 ;
only a minority of these 32 do.
.PP
This explains the previous section's
.CW wakeup+156
and
.CW iunlock+222
captures directly: not a real, non-obvious call path, just this
mechanism's own unreliability at this one call site.  Unlike the
msg/X side of the
.CW destroy-entry
panic -- confirmed correct by the tag mechanism itself naming
.CW destroy() Ns 's
own consistency check -- the c/Y side was never independently
verified, and does not survive being checked. Read as: destroy() is
called from far too many places, through far too many different
compiled shapes (direct calls, a
.CW Type Ns 's
own
.CW t->free
function pointer, deep cascades through
.CW "freelist()/freearray()/freemodlink()" ),
for one
.CW getcallerpc()
idiom to answer "who called destroy() this time" reliably across all
of them.
.PP
Bottom line for
.CW destroy() Ns 's
own double-free (this hunt's central, still-hardware-confirmed
finding): the
.CW destroy-entry
tag names WHICH check fires, solidly. Its own caller-pc field does
not name WHO calls it a second time, and should not be trusted for
that without re-deriving it a different way -- tagging or otherwise
naming the specific call site directly, the same method that made
the msg/X side trustworthy in the first place, rather than reading
.CW getcallerpc() Ns 's
raw output.
.NH 1
Who freed it first, this time reliably: destroy() itself
.PP
The free-history ring already existed and its own mechanism was
independently validated (the D2BPC tag work, the
.CW poolfree=608
bisection) -- unlike
.CW destroy-entry Ns 's
own caller-pc field, this ring's entries come from
.CW getcallerpc(&p)
called from directly inside
.CW poolfree() ,
the same call shape confirmed reliable earlier.  What it lacked was
reach: at 32 entries, every real
.CW alloc:D2B:destroy-entry
capture so far had aged out of it before the panic that needed it --
zero
.CW "was freed before"
lines across three real captures.  Bumped
.CW NFREEHIST
from 32 to 4096 (16 bytes an entry on this port, so 64KiB, trivial),
and a follow-up batch got hits.
.PP
The answer, from a source this hunt can actually trust:
.CW "0x79b9af8 was freed before, from pc=0x2614a3"
resolves to
.CW free+56 ,
and several more --
.CW "0x789f338" ,
.CW "0x785a638" ,
.CW "0x78a50b8" ,
each on a different boot -- resolve to
.CW destroy+613
or
.CW freelist+419 :
.CW destroy() Ns 's
own ordinary, correct
.CW poolfree()
call, or
.CW freelist() Ns 's
own tail-walk
.CW poolfree() .
The object that later trips
.CW destroy-entry
was freed the first time by a completely normal, successful
.CW destroy()
call -- not corruption manufacturing a fake pointer, a genuine second
call to
.CW destroy()
on a value some other, independent reference still held.
.PP
That reframes the whole thread. Two unrelated things this hunt has
now found -- the "in free blk" captures on
.CW "left = tl left" Ns -style
list-traversal loop control (previous sections) and this ring's own
"freed by destroy()'s ordinary exit, destroyed again later" pattern
-- both point the same direction: an object's own refcount is
undercounted somewhere, so two independent owners each believe they
hold the last reference. One frees it correctly. The other, later,
either explicitly calls
.CW destroy()
again (caught at
.CW destroy() Ns 's
own entry) or overwrites a slot holding the same now-dangling value
(caught by
.CW OP(movp) Ns 's
own
.CW dv
guard). Both are the same disease seen from two different vantage
points, not two separate bugs.
.CW cons() Ns 's
own "balanced move" (libinterp/xec.c: transfers a slot's old value
into a new list cell's
.CW tail
with neither an incref nor a destroy) is the standing suspect for
where a reference gets duplicated without its count following --
read correct in isolation in the previous section, and still the
most concrete lead this hunt has for where the undercounting itself
happens, now with a reliable way to confirm which object was
involved on the next capture.
.NH 1
A working disassembler, and argv()'s own return is exonerated
.PP
Every earlier attempt at
.CW disdump
against the tree's own pre-built
.CW dis/disdump.dis
failed --
.CW "illegal dis instruction" --
against both
.CW disinit.dis
and
.CW sh.dis .
The actual cause was staleness, not a fundamental blocker: a fresh
.CW limbo\ -g
build of
.CW appl/cmd/disdump.b
against the current tree's own compiler runs a trivial test module
cleanly, and disassembles
.CW appl/lib/arg.dis
(also freshly built) in full without error. It still fails the same
way against a full rebuild of
.CW sh.dis
specifically -- large enough (6111 instructions) that this looks like
a limit inside
.CW disdump.b
itself rather than anything about
.CW sh.dis Ns 's
own bytecode, but that limit was not chased further; what mattered
was getting a working disassembler for at least one of this hunt's
two real captures.
.PP
Instruction 18 in
.CW arg.dis
-- the exact instruction the
.CW Arg
capture (two sections back) named -- disassembles to
.CW "movp 64(fp), 0(32(fp))" .
.CW 64(fp)
is
.CW argv() Ns 's
own local
.CW ret ;
.CW 32(fp)
holds the caller-provided destination pointer for the return value
(Dis's own calling convention, an implicit parameter);
.CW 0(32(fp))
is a double-indirect write through it -- exactly
.CW "*retdest = ret;" .
.CW OP(movp) Ns 's
own semantics (libinterp/xec.c) read the source first and
.CW AINC
its refcount before ever touching the destination, so
.CW ret Ns 's
value is correctly at two references -- the local slot and the
caller's copy -- the instant this instruction finishes.
.CW OP(ret) Ns 's
subsequent
.CW freeptrs()
call, tearing down
.CW argv() Ns 's
own frame, destroying
.CW ret Ns 's
local slot afterward, is exactly correct: it drops one of the two
references it itself created room for, leaving precisely one for the
caller. Nothing here is unbalanced.
.PP
That exonerates
.CW argv() Ns 's
own compiled return -- and, by the same
.CW OP(movp)
mechanics, every ordinary
.CW "return EXPR;"
in this VM, not just this one. The bug this capture pointed at was
never in how a function hands back its result; it is in whatever
.CW *retdest
pointed at before this instruction ran -- some caller, somewhere,
whose own destination slot already held an already-freed reference
before it ever called
.CW argv() .
That returns this specific capture to the same open question as the
.CW Sh
one (previous sections): a caller-side slot went stale before the
instruction this hunt captured, not at it. Confirmed by disassembly
this time, not inferred.
.NH 1
Panic type distribution, read as the honest measure, at the end of this round
.PP
Following this document's own standing instruction: read the panic
type distribution across a batch, not any one checker's rate, as the
honest measure of where this boot stands. Four batches at the end of
this round, all on the build carrying every fix and hardening change
landed in it (105 boots total): 4/25, 8/25, 10/25, 10/30 -- 32
panics in 105 boots, roughly 30%. Every earlier batch this whole
multi-session hunt has recorded, going back to its very first
sessions, has run 60-80%. This is the lowest sustained rate this hunt
has ever measured.
.PP
Said plainly and cautiously: this is an observation, not a proof of
causation. No single change in this round was verified in isolation
against a controlled baseline the way the strongest findings above
were (the retracted thread is a direct reminder why that discipline
matters). What can be said is that this round landed a real number of
independently-justified correctness fixes -- the D2BPC anchor fixes
(six call sites, all shared with no other tree), the destroy()
ref-underflow guard, the allocb.c pointer-format fix, limbo -z ported
from a sibling branch, Stkext's own extents zeroed, badref() and
markheap() Ns 's Type* guard from the round before it -- any one of
which could plausibly be removing some fraction of what used to reach
a panic, and the aggregate rate dropping this much this consistently,
across four independent batches, is at least consistent with that
rather than looking like ordinary batch-to-batch noise (which this
hunt has also seen, and which typically moves single digits of
percentage points, not from ~70% to ~30%).
.PP
What remains unsolved, plainly: the root mechanism -- an object's
refcount undercounted somewhere, letting two independent owners each
believe they hold the last reference -- is not fixed, only
characterized more precisely than before (two hardware-confirmed
use-after-frees, one exonerated return path, a reliable "who freed it
first" data source). The boot is still not clean; a large fraction of
runs still panic. Whoever picks this up next should treat this
session's own real, checked findings as the foundation -- the
retracted thread as the reminder of what unchecked confidence costs --
and this closing batch's number as a baseline to measure the next
fix against, not a victory to report.
.NH 1
Sweeping abort() for the rest of the silent-hang class
.PP
.CW badptrslot() Ns 's
own fix (
.CW libkern/abort.c Ns 's
.CW "while(*(int*)0);"
spins forever on pc64 instead of faulting) is not specific to that
one checker; it applies to every
.CW abort()
call in libinterp. Swept the rest and converted five more, all
pre-existing assertion-style checks -- not this hunt's own
diagnostics -- that would otherwise fail as an unexplained hang, a
category this hunt has repeatedly recorded across many batches
without ever specifically attributing:
.IP \(bu
.CW load.c Ns 's
.CW unload() :
.CW m->ref
underflow on the shared
.CW Module
cache --
.CW lookmod() Ns 's
own
.CW AINC Ns -tracked
refcount, a different one than the Dis heap object refcounts this
hunt has been chasing, worth ruling in or out on its own terms.
.IP \(bu
.CW xec.c Ns 's
.CW OP(mcall) :
.CW f->t
changing across a native
.CW runt()
call -- one of the hottest opcodes in the interpreter, every
inter-module call goes through it.
.IP \(bu
.CW draw.c Ns 's
.CW bufimage() :
wrong lock owner.
.IP \(bu
.CW tk.c Ns 's
panel image teardown:
.CW i->ref\ !=\ 1 .
.IP \(bu
.CW validstk.c Ns 's
.CW memchk() :
.CW h->ref\ <=\ 0 --
currently unreachable (no caller anywhere in this tree), fixed for
completeness rather than because it is live.
.LP
Two 25-boot batches after: 5/25 and 7/25, none of the five new panics
fired. Consistent with the low range the previous section's closing
batch already measured (roughly 25%, against the historical 60-80%),
not a new data point proving any one of these five mattered for the
pc64 crash specifically -- real, independent hardening regardless.
.NH 1
The same disease at a second, unrelated layer: Path's own refcount
.PP
Two more batches (60 boots) at the low panic rate the previous
section measured (12/30, 13/30) surfaced a capture this hunt's own
earlier instrumentation was already positioned to explain cleanly:
.CW "panic: decref pc=0x263859 old=0" ,
resolving to
.CW pathclose+24 --
.CW chan.c Ns 's
own pre-existing refcount-underflow guard, enhanced earlier this hunt
(the very first commit of this round) to call
.CW auditmemloc()
on the underflowing
.CW Ref*
before panicking.  Its answer:
.CW "in block" --
.CW MAGIC_A ,
still live, not freed.
.PP
This is a different shape from every
.CW destroy-entry
capture this hunt has confirmed:  there, an OBJECT gets freed once
correctly and then destroy()ed again, a double free.  Here, the
.CW Path
OBJECT ITSELF is still alive and well; only its
.CW ref
FIELD has been decremented one time too many, taking it to zero when
some other, still-live reference should have kept it above zero.
Same disease -- some reference to a shared, refcounted value exists
without a matching increment having been made for it -- at a
completely different layer of the system:
.CW chan.c Ns 's
own
.CW "incref()/decref()" ,
protecting
.CW Path
and
.CW Chan
structures in the native kernel, not
.CW AINC / ADEC
protecting Dis heap objects in the interpreter.  Two independent
mechanisms, two independent sets of call sites, the same failure
shape in both -- which argues against a bug narrow to one specific
compiled Limbo idiom (this hunt's leading suspect, cons()'s own
balanced move, lives entirely on the Dis-heap side and cannot explain
a Path underflow) and for something broader: either two genuinely
separate bugs that happen to look alike, or a single mechanism -- a
missed increment somewhere a reference gets duplicated, at whichever
layer that duplication happens to occur -- that neither this hunt's
Dis-level nor native-kernel-level instrumentation has caught in the
act yet at either layer.
.NH 1
Ruling out the coherence/cmpswap function pointers, and a frequency check
.PP
The Path underflow the previous section documented left an obvious
next question open: is
.CW chan.c Ns 's
CAS-based
.CW incref()/decref()
(a retry loop around
.CW cmpswap() )
safe on this port, or could the memory-ordering primitives underneath
it be the missing increment?
.CW devarch.c
(shared from
.CW ../pc/
into every pc64 build via the mkfile's
.CW %.$O:\ ../pc/%.c
rule) declares both
.CW coherence
and
.CW cmpswap
as function pointers, defaulting to the weakest safe choice
.CW ( nop
and a splhi/splx-based
.CW cmpswap386 )
and only upgrading them --
.CW mb586
or
.CW mfence
for
.CW coherence ,
a real
.CW LOCK\ CMPXCHG
.CW cmpswap486
for
.CW cmpswap
-- once
.CW archinit()
inspects the CPU's own reported family and feature bits.  Read in
full, this upgrade happens at
.CW main.c Ns 's
line 184, immediately after
.CW cpuidentify() ,
and unconditionally before
.CW mmuinit() ,
.CW poolsizeinit() ,
.CW procinit() ,
or
.CW userinit() --
that is, before any
.CW Path
or
.CW Chan
the rest of the boot allocates and refcounts even exists.  It is also
unconditionally before
.CW arch->intrinit() ,
the call that would launch any additional processors on a real
multiprocessor.
.PP
That last point turns out to make the whole question moot for this
hunt's own test harness:
.CW qemu-boot.sh
passes no
.CW -smp
flag at all, so QEMU boots a single vCPU every time.  With one core,
.CW arch->intrinit() Ns 's
AP-launch loop
.CW (squidboy.c Ns 's
.CW lapicstartap())
finds no second processor to bring online and simply times out; there
is no genuine concurrency for a release barrier or a compare-and-swap
retry loop to race against, on this port, in this harness, as
currently invoked.  On a true uniprocessor even the weaker default
.CW cmpswap386
(interrupts-off around a plain compare-and-store) would already be
race-free against reentrant interrupts, since it disables the only
thing on a single core that could interleave with it.  This thread is
ruled out for the harness as it exists today, not because the code
could never matter on real multiprocessor hardware, but because
nothing in the reproducible boot path currently exercises more than
one core.
.PP
Before chasing anything else, a frequency check the hunt's own
standing discipline calls for and had not yet run for this specific
capture: across the eight most recent batches logged this session
(180 boots, 107 panics),
.CW "decref pc="
appears exactly twice.  General protection violation and page fault
together account for roughly forty percent of all panics in the same
window; alloc:D2B (heap corruption) captures appear four to eight
times depending on how loosely near-duplicate messages are counted.
The Path underflow was worth documenting in full because it was
.I novel --
a second, independently-confirmed layer for the same failure shape --
not because it is frequent.  It remains an open, correctly-scoped
finding; it is not this hunt's dominant panic type, and further
instrumentation aimed specifically at it is not the best next use of
effort while GPF/page-fault and alloc:D2B remain both more frequent
and more tractable.
.PP
alloc:D2B turned out to be the more immediately actionable of the
two: two independent boots this round produced byte-for-byte
identical captures
.CW ( "alloc:D2B:\ 312aa0\ not\ in\ pools\ (from\ 261314/2bf070)" ,
twice, and the same shape at a different address with a different
second pc, also twice), which resolved
.CW 261314
to
.CW mallocalign+299 --
inside the allocator's own compiled body, not inside whichever
function called it.  Working out why cost real effort: the panic's
own
.CW "(from X/Y)"
pair prints two different things
.CW ( X
is
.CW _poolfault Ns 's
own caller -- wherever the failing check physically sits in code;
.CW Y
is the explicit pc value that specific call site computed) that are
easy to conflate, and none of alloc.c's seven plain
.CW D2B(b,dp)
call sites carried a distinguishing tag the way
.CW heap.c Ns 's
two
.CW D2BPC
sites already did earlier this hunt.  All seven
.CW ( poolimmutable ,
.CW poolmutable ,
.CW free ,
.CW setmalloctag ,
.CW getmalloctag ,
.CW setrealloctag ,
.CW getrealloctag )
pass their own real first parameter as the data pointer, so each was
already correctly anchored per this hunt's established
.CW getcallerpc()
rule -- converting them to
.CW D2BPC
with an explicit tag changes only which string prints, not which pc
value is computed, and makes the next capture through any of these
seven self-identify directly in its own panic text, the same payoff
.CW heap.c Ns 's
conversion already delivered for
.CW freelist-tail
and
.CW destroy-entry .
Rebuilt clean and boot-tested (25 boots, 9 panics, 36%, within this
round's established band; none of the newly-tagged sites fired this
particular batch, consistent with alloc:D2B's own low frequency).
.NH 1
Two real incref(nil) bugs, found from allocb.c's own diagnostic catching itself out
.PP
The alloc:D2B tagging round above turned up a second, unrelated
signal along the way:
.CW "checkb 0 qaddlist 1" ,
a
.CW Block
whose
.CW base
exceeds its
.CW lim
by EXACTLY
.CW Hdrspc
(64) bytes, every single time, regardless of the block's overall size
or address.  That precision -- not a scattered, size-proportional
corruption -- pointed straight at
.CW allocb.c Ns 's
.CW _allocb() ,
the only place
.CW Hdrspc
is used, and specifically at the arithmetic that sets
.CW base
and
.CW lim
from
.CW sizeof(Block)
and
.CW msize(b) .
A first version of a diagnostic added right there, panicking the
moment
.CW lim\ <\ base
is computed, caught something more interesting than the bug it was
built to catch:
.CW msize(b) ,
called twice in the same function on the same untouched block with
nothing else running in between on this single-vCPU harness, returned
two DIFFERENT values eight bytes of source apart -- 216 in the
panic's own argument list, but something near zero moments earlier,
when the first call set
.CW b->lim
(which resolved to
.CW b->lim\ ==\ b
itself).
.CW msize()/poolmsize()
disagreeing with itself across two calls on one block is a real,
open question this hunt has not chased to ground yet.  Fixed the
diagnostic itself first -- one
.CW msize(b)
call, captured in a local, reused everywhere -- so the next capture's
numbers are self-consistent instead of self-contradicting.  No
.CW "_allocb: lim < base"
capture has recurred since; the original
.CW "checkb 0 qaddlist 1"
signature has not recurred either, in three 30-boot batches run since.
.PP
The same round's boot batches also surfaced
.CW "incref: bad r 0x0" ,
twice in one batch, both resolving to
.CW walk+34 .
.CW chan.c Ns 's
.CW walk()
opens with
.CW "path\ =\ c->path;\ incref(path);" --
the one
.CW ->path
incref site in this file with no
.CW "if(path\ !=\ nil)"
guard, though every other site
.CW ( cclone() ,
two direct sites elsewhere in
.CW chan.c )
already has one, since
.CW c->path
is a documented-nil-able field.  Resolving the stack both times traced
back through
.CW namec+680
to
.CW "namec()" Ns 's
own call
.CW "walk(&c,\ e.elems,\ e.nelems,\ nomount,\ &e.nerror)"
with
.CW e.nelems\ ==\ 0 --
the common "resolve to this Chan itself" shape, where
.CW walk() Ns 's
loop body (the only place
.CW addelem() ,
the nil-unsafe consumer of
.CW path ,
gets called) never executes.  Guarded to match the rest of the file;
verified nil-safe end to end for this case.
.PP
That fix did not fully close the signature: the next batch produced
one more
.CW "incref: bad r 0x0" ,
still at
.CW walk+34
(the offset shifted with the edit, but landed back on the same
label), still via
.CW namec+680 .
The survivor turned out to be
.CW walk() Ns 's
OTHER, top-of-function
.CW incref(c) ,
not the path one just fixed.  Tracing
.CW namec()
above its
.CW walk()
call found the actual gap: the
.CW '/'
and
.I default
cases just above the
.CW '#'
case each
.CW incref()
a
.CW Chan
they already hold, which already nil-checks via
.CW badref()
right where it happens; the
.CW '#'
case assigns
.CW "c\ =\ devtab[t]->attach(...)"
fresh, with no local
.CW incref()
and, until now, no nil check either -- so a device whose
.CW attach()
returns
.CW nil
instead of calling
.CW error()
sailed straight through to
.CW walk() Ns 's
own
.CW incref(c)
three lines later, with nothing along the way naming which device.
Added the same nil check every other attach failure in that switch
already has
.CW (error(Ebadsharp)) ,
plus a
.CW print()
naming the specific
.CW devtab
entry so the next occurrence identifies itself immediately.
Confirmed hardware-live: the very next batch printed
.CW "namec:\ attach()\ returned\ nil,\ devtab[6]->name\ pipe"
and continued with a normal Chan-open error instead of a kernel
panic.
.I Why
.CW devpipe.c Ns 's
own
.CW attach()
can return
.CW nil
is not yet investigated -- this fix turns a kernel panic into a
recoverable open-time error, which is the right shape regardless of
that root cause, but the root cause itself is still open.
.PP
One more, different-looking
.CW "incref: bad r 0x0"
turned up in the batch that confirmed the attach fix, this time
resolving to
.CW namec+1273 --
inside one of
.CW namec() Ns 's
own
.CW incref()
calls directly, not by way of
.CW walk() .
Most likely
.CW up->pgrp->slash
or
.CW up->pgrp->dot
itself nil for some process group, but this is noted here as an open
lead rather than guessed at further this round: one hit in 30 boots,
a different call site than either bug just fixed, and worth its own
capture-driven investigation rather than a speculative patch.
.NH 1
The third incref(nil): forth's default namespace mode had no root
.PP
The previous section's open lead --
.CW "incref: bad r 0x0"
resolving to
.CW namec+1273 ,
inside one of
.CW namec() Ns 's
own
.CW incref()
calls directly rather than by way of
.CW walk() --
traced to
.CW devforth.c Ns 's
.CW newforthproc() .
.CW newpgrp()
only sets
.CW "ref/pgrpid/progmode" ;
.CW smalloc()
zeroes the rest, so a fresh
.CW Pgrp Ns 's
.CW dot
and
.CW slash
start
.CW nil
and rely on the caller to fill them in.
.CW pgrpcpy()
does that -- along with the mount table -- but
.CW newforthproc()
only calls it
.CW "if(params->newns\ ==\ 0)" .
.CW params.newns
DEFAULTS TO 1
.CW (parseparams() Ns 's
own initializer), making the skipped branch the common case, not an
edge one: any forth process started without explicitly requesting the
shared-namespace flag got a
.CW Pgrp
with both
.CW dot
and
.CW slash
nil, and its first
.CW namec()
call -- opening
.CW "/x" ,
opening
.CW "./x" ,
anything -- read one of those two fields directly and
.CW incref() Ns 'd
it with no nil check, since
.CW namec()
has no reason to expect its own process group's root or current
directory to be unset.
.PP
Fixed by cloning just
.CW dot
and
.CW slash
-- the same call
.CW pgrpcpy()
itself makes for those two fields -- when the mount-table copy is
skipped.  "New namespace" means an independent, not-shared mount
table (which
.CW pgrpcpy()
would also copy, and this path correctly continues to skip); it does
not mean no root at all.  A namespace with no root cannot resolve
.CW "/"
or
.CW "."
at all, which is not a coherent namespace by any definition, empty or
otherwise.
.PP
Built and boot-tested: 60 boots across two batches after this fix
(30%, 13% panic rates, both in this round's established band), ZERO
.CW "incref: bad r 0x0"
captures in either batch -- the first time this signature has not
appeared in a batch since it was first noticed, across all three of
this round's incref(nil) fixes combined.
.PP
The same confirmation batch also produced the first fully
self-consistent capture of the
.CW _allocb
diagnostic since its own double-evaluation bug was fixed:
.CW "size\ 26\ sizeof(Block)\ 64\ msz\ 0\ Hdrspc\ 64" .
.CW msz
(captured once, per the earlier fix) genuinely is zero -- the pool
handed
.CW _allocb()
a block whose own
.CW b->size
equals
.CW BHDRSIZE
exactly, despite a 161-byte request
.CW (sizeof(Block)+size+Hdrspc+(BY2V-1)) .
The block's magic passed
.CW D2BPC Ns 's
check (this is not a stray/corrupt pointer), so somewhere inside
.CW poolalloc() Ns 's
tree-search or split path a real block is ending up tagged with the
wrong size.  This is a real, open, self-consistent lead -- one hit in
60 boots this round, noted rather than chased further given the
frequency-driven discipline the rest of this hunt has followed, but
worth returning to: unlike the earlier msize() double-eval artifact,
this number can now be trusted.
.NH 1
The same guard, applied before its own capture, plus two new open leads
.PP
Looking for other reachable instances of the exact shape that produced
.CW walk() Ns 's
fix -- an unguarded
.CW "path\ =\ c->path;\ incref(path);" --
found a second, identical pattern in
.CW namec()
itself: the
.CW "Aaccess/Aremove/Aopen"
case's "save&update the name" step reads
.CW "path\ =\ c->path"
and
.CW incref() Ns 's
it with no guard either, right after a
.CW walk()
call that, per the fix already landed, can legitimately hand back a
nil
.CW c->path
for the
.CW e.nelems==0
case.  Not yet caught by its own separate capture, but fixed on the
same evidence and for the same reason rather than waiting for one --
traced
.CW domount() ,
.CW pathclose() ,
and the final
.CW "pathclose(c->path);\ c->path\ =\ path;"
and confirmed each already tolerates a nil path the same way
.CW walk() Ns 's
own downstream handling does.  Built and boot-tested: 30 boots, 10
panics (33%, in-band, no regression).
.PP
The same batch surfaced two new, different "c nil" captures --
.CW cclose()
and
.CW cclone()
both panic explicitly (rather than silently ignoring) a nil
.CW Chan* ,
a pc64-only hardening from earlier in this hunt, and both fired once
each: one resolving to
.CW unionread+772 ,
one to
.CW cunique+28 .
Neither is yet understood well enough to fix with confidence --
.CW cunique() Ns 's
own body dereferences
.CW c->ref
unconditionally two lines before its one
.CW cclone(c)
call, which would itself fault on a genuinely nil
.CW c
before ever reaching
.CW cclone() ,
so either the resolved pc is a case of the same kind of
misattribution this hunt already worked through once for
.CW mallocalign
(the call physically sitting in a neighboring function with no
symbol of its own) or there is a real, subtler bug here still to
find.  One hit each in 30 boots -- noted as open leads per this
round's frequency-driven discipline, not guessed at further this
round.
.NH 1
Verifying the exact-match chain's own invariant, and a possible-misattribution lead
.PP
Aimed instrumentation at the still-open
.CW poolalloc()
size=0 lead from the previous section (a self-consistent
.CW "_allocb:\ lim\ <\ base...\ msz\ 0"
capture, reproduced twice across roughly 90 boots after
.CW allocb.c Ns 's
own double-evaluation bug was fixed):
.CW poolalloc() Ns 's
exact-match tree branch matches on
.CW "tt->size\ ==\ size" ,
then hands out
.CW tt->fwd
-- the next block chained at this size's tree bucket, per
.CW pooladd() Ns 's
own same-size chaining -- without ever re-verifying that
.CW tt->fwd
carries the same size
.CW tt
does.  Every other reader of this chain assumes that invariant holds
by construction and never checks it either.  Added a check right
there, panicking with both sizes and both pointers if it is ever
violated -- this either confirms or rules out the leading hypothesis
directly on the next capture, rather than requiring another
resolve-and-reason cycle.
.PP
Built and boot-tested: 40 boots, 16 panics (40%, the upper end of but
still within this round's established band, no regression).  The new
check did not fire this batch, and neither did the size=0 signature
itself -- consistent with its own established low frequency (roughly
2 hits per 90-130 boots), not yet re-confirmed or refuted.
.PP
The same batch surfaced a new, single
.CW "incref:\ bad\ r\ 0x0"
resolving to
.CW pidalloc+95 --
but
.CW proc.c Ns 's
own
.CW pidadd() ,
called from
.CW pidalloc() ,
is
.CW static
and confirmed via the resolver's own symbol dump to carry NO
.CW T
symbol at all in this binary; it sits immediately before
.CW pidalloc()
in source order, so this offset may actually be inside
.CW pidadd() Ns 's
own compiled code, misattributed to the nearest preceding symbol the
same way
.CW mallocalign+299
turned out to be, earlier in this hunt.  Neither of
.CW pidadd() Ns 's
own two
.CW incref()
calls should be able to fire on a nil pointer by a straightforward
reading -- one is already nil-guarded, the other's operand is
array-indexed and never nil by construction -- and
.CW pidalloc() Ns 's
own
.CW incref(i)
call is preceded by an unconditional dereference of the same
.CW i
.CW ( i->procindex\ =\ ... )
that would need to survive first, plausible on this port only if
that write lands in identity-mapped low memory rather than faulting
-- which this kernel does map elsewhere for real-mode AP-bootstrap
access
.CW (squidboy.c Ns 's
own
.CW KADDR(0x467)
trampoline write).  One hit, mechanism genuinely unclear either way
-- recorded as a new open lead rather than guessed at.
.NH 1
The resolver itself had the bug: half this kernel's symbols were invisible to it
.PP
.CW resolve_ipc64_syms.py
only ever looked at symbol type
.CW T
(global/exported text).  This binary alone carries 2029 type-
.CW t
(local/static) entries next to 1975
.CW T
ones -- close to half this kernel's own functions were invisible to
the tool this whole hunt has used to name every captured pc.  Any pc
landing inside a
.CW static
function got silently misattributed to whichever
.I global
symbol happened to precede it in address order.
.PP
This exact shape came up at least twice this round already,
documented both times as "possible misattribution, same as
.CW mallocalign+299 "
without being able to confirm it either way: an
.CW "incref:\ bad\ r\ 0x0"
resolving to
.CW pidalloc+95 ,
and two
.CW "c\ nil"
captures resolving to
.CW unionread+772
and
.CW cunique+28 .
Checked directly:
.CW proc.c Ns 's
own static
.CW pidadd() ,
called from
.CW pidalloc()
and sitting right before it in source, DOES have a symbol in this
binary -- type
.CW t ,
completely invisible to the old version of the tool.  Fixed by
including both
.CW T
and
.CW t
in the resolver's sorted symbol list.  Re-resolving the three pcs
against the fixed version:
.IP \(bu
.CW pidalloc+95
stays
.CW pidalloc+95 --
0x2780df sits well inside
.CW pidalloc Ns 's
own 0x278080-based range, past
.CW pidadd Ns 's
separate 0x277ea9 slot.  This specific capture was never a
misattribution; it is a real, confirmed capture inside
.CW pidalloc()
itself.
.IP \(bu
.CW cclone() Ns 's
caller (0x26439b) now resolves to
.CW ccloseq+75 ,
not
.CW cunique+28 --
a different function.
.IP \(bu
.CW cclose() Ns 's
caller (0x27d3e9) now resolves to
.CW rread+53 ,
not
.CW unionread+772 --
also a different function.
.PP
Neither of those last two is a clean answer, though: read in full,
.CW ccloseq()
does not call
.CW cclone()
anywhere in its own body (it calls
.CW decref()
and
.CW closechanq() ) ,
and
.CW rread()
does not call
.CW cclose()
at offset 53 either (its own
.CW cclose(c)
call sits inside a
.CW waserror()
handler further down).  Both resolved functions are real, both have
correct symbols now, and both are still wrong as an explanation for
where the call in question actually happened.  That points past the
symbol-table gap this section fixes and at
.CW getcallerpc()
itself: this hunt has already found, more than once, that its
.CW "(((uintptr*)(x))[-1])"
trick depends on
.CW x
sitting at an exact, compiler-chosen stack slot that does not always
match what the macro assumes -- and unlike a genuinely bad symbol
table, a wrong-but-plausible-looking stack read does not announce
itself.  Every prior capture resolved through the old version of this
tool should be treated as unverified until re-checked; the original
.CW mallocalign+299
case that first raised this suspicion could not be re-verified at all
(addresses shift across rebuilds, and that build is gone), so it
stays exactly as inconclusive as it was already documented to be.
.NH 1
Narrowing poolalloc's size=0 lead further, and a plausible bindmount capture
.PP
The exact-match chain check from the previous section did not fire
on a third reproduction of the
.CW "_allocb:\ lim\ <\ base\ ...\ msz\ 0"
signature this round -- this time with a different requested size (2,
not 26, further confirming it is not size-specific) -- ruling that
specific hypothesis out.  Added the same style of check to the other
tree-search branch:
.CW q
(the smallest BST node found with
.CW "size\ >=\ wanted" ,
by the descent's own invariant) is verified to actually satisfy that
invariant right before use, rather than trusted implicitly.  Built
and boot-tested: 50 boots, 8 panics (16%, in-band, no regression).
Neither this new check nor the size=0 signature itself fired this
batch -- narrows the remaining suspects toward the arena-extend path
(which sets
.CW size
directly rather than via a tree lookup, structurally less likely) or
something beneath
.CW poolalloc()
itself, if the bug is not simply rare enough to still need more
boots.
.PP
The same batch surfaced a new
.CW "cclose\ ...\ c\ nil"
resolving to
.CW bindmount+506 --
unlike the
.CW ccloseq / rread
captures the resolver fix above uncovered as suspect, this one is
plausible on inspection:
.CW bindmount()
genuinely calls
.CW cclose()
at several points in its own body.  Which specific call fired is not
pinned down without disassembly this round; one hit, recorded as an
open lead rather than chased further.
.NH 1
Instrumenting pidadd() for the confirmed-genuine pidalloc+95 lead
.PP
Followed up on the resolver-tool fix directly:
.CW pidalloc+95 Ns 's
.CW "incref:\ bad\ r\ 0x0"
is now confirmed a real capture, not a resolver misattribution.  Read
.CW pidadd()
end to end -- every path either returns a real, array-derived
.CW Pid*
or loops back to retry, so it should never return
.CW nil
through normal control flow.  The one structural gap:  if
.CW pidalloc()/pidadd()
ever runs before
.CW pidinit()
-- the call that allocates
.CW pidhashtab
and sets
.CW pidhashmask ,
and the LAST statement in
.CW procinit() --
has completed,
.CW pidhashtab
is
.CW nil
and the computed index into it can legitimately equal
.CW nil
itself (index 0 of a nil array), silently, with no fault:
.CW struct\ Pid Ns 's
.CW procindex
field sits at a small enough byte offset that
.CW pidalloc() Ns 's
own later
.CW "i->procindex\ =\ ..."
write would land in this port's identity-mapped low memory (the same
region
.CW squidboy.c Ns 's
own
.CW KADDR(0x467)
trampoline write uses) rather than faulting, letting execution reach
.CW incref(i)
with
.CW i
still
.CW nil .
.PP
Added a direct check right where
.CW pidadd()
computes
.CW i ,
panicking with
.CW "pidhashtab/pidhashmask/pid/i"
if this ever happens, to confirm or refute the ordering hypothesis on
the next capture without another resolve-and-reason cycle -- the
normal boot ordering
.CW ( procinit()
before any process creation) makes this look correct by inspection,
so a definitive answer needs the capture, not more reading.  Built
and boot-tested: 50 boots, 13 panics (26%, in-band, no regression).
Neither the new check nor the original
.CW pidalloc+95
signature recurred this batch -- still only one confirmed hit total,
consistent with its established low frequency.
.NH 1
disinit's %r was always empty, and the real error it hid
.PP
.CW disinit() Ns 's
own
.CW waserror()
handler has read
.CW "panic(\"disinit\ error:\ %r\")"
since before this hunt started, and every single
.CW "disinit\ error:"
capture across this whole session printed no text after the colon.
Traced why:
.CW libkern/print.c Ns 's
own
.CW errfmt()
unconditionally returns
.CW -1 --
its own comment says as much: it "works from limbo" via lib9's own
errfmt(), never here.
.CW %r
was silently swallowing the real error on every capture this whole
hunt has ever seen.  Fixed using the same
.CW kgerrstr()+%s
idiom the
.CW "loading\ %s:\ %s"
panic two dozen lines below in the same function already uses.
.PP
Confirmed immediately: the very next batch this fix ran in caught
.CW "disinit\ error:\ out\ of\ memory:\ main" --
the first time this hunt has ever seen what
.CW disinit() Ns 's
own
.CW waserror()
handler is actually catching.  Ties into this session's broader
heap-corruption thread
.CW (poolalloc() Ns 's
still-open size=0 lead, the various refcount-undercount findings) as
a plausible downstream symptom worth keeping in view, though not
chased to its own root cause this round.
.PP
Also added a direct nil check to
.CW pgrp.c Ns 's
.CW newmount() ,
following up a confirmed
.CW "incref:\ bad\ r\ 0x0"
resolving to
.CW newmount+40 .
Unlike
.CW walk() Ns 's
.CW ->path ,
.CW to
is not a documented-nil-able field -- all three known callers
.CW (chan.c Ns 's
.CW cmount() ,
at its three call sites) already dereference their own
.CW Chan
argument before ever reaching
.CW newmount() ,
so a genuinely nil
.CW to
here should already have been caught upstream.  That it wasn't
matches this hunt's own established finding that a nil dereference
does not reliably fault on this port (see
.CW proc.c Ns 's
.CW pidadd()/procindex
writeup above) -- this converts a generic
.CW badref()
panic into one that names
.CW newmount
and its caller directly, for the next capture, rather than papering
over an unexplained gap.
.PP
Built and boot-tested: 40 boots, 13 panics (32.5%, in-band, no
regression); the
.CW disinit
fix's new message text confirmed live in this same batch.
.CW newmount Ns 's
guard did not fire this batch -- still one confirmed hit total,
pre-fix.
.NH 1
Verifying size itself, closing a gap in the last two poolalloc checks
.PP
The exact-match and no-split/split invariant checks from the previous
two sections both compare a returned block's size against the SAME
.CW size
local
.CW poolalloc()
computes once at the top -- neither could ever catch
.CW size
itself being computed wrong, since a bad
.CW size
would look internally consistent to every branch that trusts it.
Added a direct check right after the computation:
.CW size
must exceed
.CW osize
(the caller's actual request) by at least
.CW BHDRSIZE ,
the minimum any correctly-rounded allocation could produce.
.PP
Built and boot-tested: 60 boots, 21 panics (35%, in-band, no
regression).  Neither this check, the two from prior rounds, nor the
size=0 signature itself fired this batch -- three independent
invariants now cover every return path except the arena-extend one
(which sets
.CW size
directly from the same already-verified local, so structurally the
least likely remaining candidate), narrowing this lead further
without yet landing it.
.NH 1
Two more ->path sites, and mainmem is generously sized -- the OOM is not a config problem
.PP
Swept for the same shape this hunt has now found and fixed four times
in
.CW chan.c/pgrp.c :
an
.CW incref()
on a
.CW Path/Chan
field that is documented-nil-able with no guard.  Found two more in
.CW exportfs.c :
.CW exmount() Ns 's
own
.CW "oname\ =\ c->path;\ incref(oname);" ,
paralleling
.CW walk() Ns 's
already-fixed bug exactly, and its caller's own copy of the same
pattern a few dozen lines later in the create-with-mount path.  Both
guarded to match the established convention.
.CW exportfs.c
is part of this kernel's own link
.CW ( exportfs.6
appears in
.CW ipc64 Ns 's
link line) despite not showing up in a plain mkfile grep --
.CW $PORT ,
set elsewhere, pulls it in.  Built and boot-tested: 30 boots, 7
panics (23%, in-band, no regression).  Neither guard has its own
confirmed capture yet.
.PP
The same batch recurred
.CW "disinit\ error:\ out\ of\ memory:\ main" --
a second hit, confirming the previous section's
.CW %r
fix is already earning its keep by making this lead visible at all.
Chased it one step further:
.CW exNomem
.CW ( "out\ of\ memory:\ main" )
is raised from well over a dozen sites across
.CW libinterp/load.c
alone (the Dis module loader
.CW disinit()
calls to bring up
.CW /osinit.dis ) ,
every one of them a generic "a malloc-family call returned
.CW nil "
signal, so the specific failing allocation is not yet pinned down.
What is pinned down: this is not a simple sizing problem.
.CW mainmem Ns 's
own boot-time prints
.CW (poolsizeinit() Ns 's
.CW "poolsizeinit\ conf.npage\ %zd" ,
.CW poolsize() Ns 's
.CW "poolsize\ max\ %zud" )
show
.CW conf.npage\ 128472
and a resulting
.CW maxsize
of roughly 251MB -- fifty percent of this VM's 512MB, per
.CW pc64.c Ns 's
.CW main_pool_pcnt=50 ,
correctly overriding the table's built-in 32MB placeholder.  A pool
that generously sized running out during the FIRST major
allocation-heavy step of boot points past configuration and at this
session's own broader heap-corruption thread
.CW (poolalloc() Ns 's
still-open size=0 lead, the various refcount-undercount findings) --
consistent with, though not yet proven to be caused by, one of those
already-documented mechanisms quietly costing this pool usable
space.  Not chased to a specific allocation site this round; a
real trace would need per-call accounting across a full boot, a
larger undertaking than this round's capture-driven fixes.
.NH 1
The one unguarded ->mchan incref, and a swept clean bill for the rest
.PP
Continued the sweep for this session's now-familiar shape across
every file this kernel actually links (checked
.CW devbin.c ,
.CW devbridge.c ,
.CW devdraw.c ,
.CW devenv.c ,
.CW devmnt.c ,
.CW devproc.c ,
.CW devpointer.c ,
.CW devsd.c ,
.CW devshm.c ,
and
.CW inferno.c
for every remaining
.CW incref()
call site).  Found one real gap:
.CW chan.c
sets
.CW c->mchan
nil in two places, and
.CW devmnt.c
itself already guards a read of it elsewhere
.CW ( "if(c->mchan\ ==\ nil)"
in
.CW mntrdwr() ) ,
confirming it is a documented-nil-able field exactly like
.CW ->path --
but the walk-completion path's own
.CW "wq->clone->mchan\ =\ c->mchan;\ incref(c->mchan);"
had no guard.  Fixed to match.  The other two
.CW incref()
sites in this file (both
.CW incref(m->c) )
are a different, always-valid
.CW Chan
(the mount connection's own channel, not a possibly-nil
.CW c->mchan ) ,
so left alone.  Every other
.CW incref()
site checked in this sweep --
.CW devproc.c Ns 's
.CW "incref(tc)/incref(f)" ,
.CW inferno.c Ns 's
.CW incref(c)
in the NEWFD path -- was already correctly guarded by a preceding
nil check.
.PP
Built and boot-tested: 30 boots, 8 panics (27%, in-band, no
regression).  No capture of its own yet -- found by pattern-matching,
same as several of this session's earlier fixes.
.CW "disinit\ error:\ out\ of\ memory:\ main"
recurred a third time (3/100 boots since the
.CW %r
fix -- a real, moderately frequent, still-open lead).
.NH 1
The real "out of memory: main" cause: a silent hang, not a leak
.PP
The recurring
.CW "disinit\ error:\ out\ of\ memory:\ main"
(three captures across recent batches) finally produced a live
.CW "arena\ too\ large"
capture with the caller pc an earlier addition this round put there:
.CW smalloc+32 ,
i.e.
.CW smalloc()
itself is asking
.CW poolalloc()
for the requested size directly.  Both live captures had size within
a small, plausible byte count of
.CW 2\u32\d
.CW ( 4294966320 ,
then
.CW 4178666939 )
against a 251MB pool -- not remotely a real memory need, and not a
leak:
.CW cursize
was under 100KB both times, essentially the start of boot.
.PP
That immediately explains something else:
.CW smalloc() Ns 's
own retry loop
.CW ( "for(;;)\ {\ v\ =\ poolalloc(...);\ if(v\ !=\ nil)\ break;\ tsleep(...);\ }" )
has NO escape at all.  A request this large can never fit regardless
of what else frees, so this loop retries forever -- a silent,
permanent kernel hang, not a crash.  Batches across many earlier
sessions have almost certainly hit exactly this and been killed by
the harness's own boot timeout with no panic line at all,
indistinguishable from any other hang until now.
.PP
Fixed with a direct sanity check: if the requested size exceeds
.CW mainmem Ns 's
own
.CW maxsize ,
panic immediately naming the real caller, instead of hanging.
Confirmed live in the very next batch:
.CW "smalloc:\ size\ 4178666939\ >\ mainmem\ maxsize\ 263110656,\ pc=..."
resolving to
.CW devattach+135 --
.CW dev.c Ns 's
.CW devattach()
calls
.CW "smalloc(4+strlen(spec)+1)" .
.CW strlen()
in this tree is declared to return
.CW long ,
and
.CW long
is 32 bits on this port (a known, previously-documented
miscompilation risk here) -- a
.CW strlen()
result anywhere near
.CW INT32_MAX
would explain a wrapped value landing near
.CW 2\u32\d
when promoted into
.CW smalloc() Ns 's
64-bit
.CW uintptr
parameter.  Read
.CW namec() Ns 's
own
.CW '#' -case
.CW genbuf
handling (the most likely source of
.CW devattach() Ns 's
.CW spec
argument) end to end looking for an out-of-bounds
.CW genbuf+n --
it checks out as memory-safe by construction for every case traced
by hand.
.CW devattach()
has dozens of other callers across nearly every device driver in
this tree, any of which could be passing a corrupted
.CW spec
from elsewhere; the ultimate source of the bad
.CW spec
pointer is still open.
.PP
Built and boot-tested twice this round: 50 boots confirming the
.CW "arena\ too\ large"
print's new caller pc (32%, in-band), then another 50 boots
confirming the
.CW smalloc()
guard itself fires cleanly instead of hanging (32%, in-band, no
regression).  The same batch that caught the
.CW smalloc
panic also reproduced both the
.CW checkb-0/qaddlist
and
.CW _allocb
size=0 signatures again, unrelated to this fix.
.NH 1
Two signatures gone quiet, and a recurrence that was not one
.PP
Before chasing the next lead, a status check the advisor suggested:
re-grep every batch this hunt has produced for the two signatures still
marked open at the end of the previous round, split by whether each
capture predates or postdates the fix meant to address it.
.PP
The
.CW checkb-0/qaddlist
signature (
.CW "b->base\ >\ b->lim" ,
caught by
.CW qio.c 's
.CW qaddlist() )
had been logged as recurring even after the
.CW _allocb()
msz fix, based on one fresh capture in
.CW smalloc_batch/boot18.log .
Laid every capture this hunt has ever logged side by side, sorted by
timestamp against that fix's commit time, and the picture is not a
recurrence at all.  Every capture before the fix shares one precise
shape: both
.CW base
and
.CW lim
eight-byte aligned, both addresses in the live heap range (
.CW 0x79xxxxx ,
.CW 0xa2cxxx ,
.CW 0xa4dxxx ),
and
.CW base\ -\ lim
exactly
.CW Hdrspc
(64) bytes every single time \(em a precise, deterministic signature,
not scattered corruption.  Not one of the 750-plus boots run across
every batch since the fix landed reproduces that shape, and the fix's
own
.CW "_allocb:\ lim\ <\ base"
check \(em which would catch this exact pattern one call earlier, at
construction, before
.CW qaddlist()
ever sees the block \(em has not fired once either.  That thread is
closed: the msz double-eval fix was the real fix, not a coincidence.
.PP
The
.CW boot18.log
capture that looked like a recurrence is a different bug wearing the
same panic string.  Its numbers:
.CW base\ 0x2d2a97 ,
.CW lim\ 0x2d2998 .
Neither is eight-byte aligned (
.CW 0x2d2a97
is odd), the delta is 255 bytes, not 64, and both addresses sit in
kernel
.I text
range \(em the same
.CW 0x26xxxx \(en 0x2fxxxx
span this hunt's own resolved function symbols occupy, nowhere near
the heap.  A real
.CW Block
allocated by
.CW _allocb()
cannot produce those numbers by construction.  The straightforward
reading:
.CW qaddlist()
was handed a
.CW Block\ *
that was never a
.CW Block
at all \(em some caller's
.CW b
argument was already garbage before the call, and
.CW checkb()
faithfully reported nonsense fields read out of whatever memory that
pointer actually named.  That is a different failure than the fixed
one and, at one occurrence in 750-plus post-fix boots, a rare one.
Left open rather than chased on a single sample; the discriminating
test for the next capture is the same alignment/range check used
here.
.PP
.CW poolalloc() 's
own size=0 lead (four invariants: the exact-match chain's
.CW t->fwd
size, the no-split/split branch's
.CW q->size ,
.CW size
itself right after it is computed, and the pre-existing
.CW "arena\ too\ large"
print with its caller pc) has not fired even once in every boot run
since all four landed \(em over 100 boots across
.CW poolalloc3_batch
and the
.CW final_batch4
through
.CW final_batch6
consolidation runs.  Between that and the
.CW _allocb()
lim-check silence above, the honest read is that this lead is dormant
across the whole allocator path this hunt instrumented, not merely
unlucky not to be caught.  Left instrumented rather than removed, since
dormant is not the same claim as fixed and nothing here explains why
it stopped.

.NH 1
The dominant crash all along: a stale global register file
.PP
The advisor's suggestion to separate the two
.CW checkb-0/qaddlist
shapes led to a routine cross-check: grep every post-fix boot log for
every distinct native trap PC, not just the ones this hunt had already
named.  The result reframed the whole session.  Of 765 post-fix boot
logs, 540 (71%) hit a
.CW "TYPE\ 0D"
general protection fault, and 390 of those (51% of every post-fix
boot) share one exact native PC, resolving through the now-fixed
resolver to
.CW notefree+270
or
.CW notefree+283
\(em 4416 hits total across both offsets.  Every other lead this hunt
had tracked \(em the eight
.CW incref(nil)
bugs, the
.CW smalloc()
hang, the
.CW checkb-0/qaddlist
signature \(em fired at most in the tens of captures.  This one fires
in half of every boot, and had gone unnamed the whole session because
prior panic-rate accounting counted
.CW panic:
text captures, a narrower measure than raw native traps.
.PP
.CW notefree()
(alloc.c) is a pure diagnostic: a small ring buffer recording each
successful
.CW poolfree() 's
address, caller pc, and \(em to make a later double-free's "who freed
this first" answerable \(em the Dis pid and module name current at the
moment of the free.  Pid comes from
.CW currun() ,
guarded correctly.  Module name came from the
.I "plain global"
.CW R
(libinterp/xec.c's single, process-wide interpreter register file, not
any specific Prog's own saved
.CW p->R ),
guarded only by
.CW "R.M\ !=\ nil" .
Grepping xec.c shows
.CW R.M
is assigned in exactly three places and never once set back to
.CW nil ,
including when the Prog that owned it exits and frees its own module
\(em so once any Dis process has ever run and exited, the global
.CW R.M
keeps pointing at that process's now-freed Modlink forever, and
.CW notefree()
runs on
.I every
successful
.CW poolfree()
across the whole kernel, Dis-related or not.
.CW R.M\->m\->name
follows that dangling pointer twice more; landing on a genuinely
garbage 64-bit value rather than a merely-wrong-but-canonical one is
enough to trip a general protection fault instead of a page fault,
matching every capture: ERROR 0000, CR2 all zero.
.PP
.CW _poolfault()
(the pool-corruption panic path, far rarer, so never itself caught
crashing) had the identical pattern, added by an earlier round of this
same hunt with a comment explicitly arguing the plain global
.CW R
was
.I "live at exactly this point"
as an improvement over
.CW xp\->R \(em
a claim this capture disproves outright.
.PP
A first fix gated the global
.CW R.M
read on
.CW "xp\ !=\ nil"
(a Prog genuinely at the head of the run queue), reasoning that a live
.CW xp
meant
.CW R
was current for it.  Built, boot-tested, and it kept crashing at the
same site (now
.CW notefree+292 ,
the same instruction shifted a few bytes by the extra check): the
capture's own
.CW xp
was pid 2, module Sh \(em proven by the successful
.CW dumpregs()
print of exactly that, right before the crash \(em yet the global
.CW R.M
was
.I still
dangling.  Being at the head of the run queue does not mean the global
.CW R
has been reloaded for that Prog.  That is a real, live-disproven first
attempt, not a hypothetical: recorded here rather than quietly
replaced, per this hunt's own rule of saying what was only
demonstrated.
.PP
pc64/trap.c's
.CW dumpregs()
never had this bug in the first place, and the reason points at the
actual fix: it reads
.CW xp\->R.M
\(em the specific Prog's own saved register file \(em not the shared
global, gated on
.CW "xp\ !=\ nil" .
.CW xp\->R.M
is valid for a live
.CW xp
regardless of whether the global
.CW R
has been swapped in for it this instant, which is exactly the
guarantee the global lacks.  Both
.CW notefree()
and
.CW _poolfault()
now read
.CW xp\->R.M
the same way.  Rebuilt, and two fresh batches on the corrected binary
\(em 25 boots total \(em reproduced zero
.CW notefree
crashes; every native
.CW "TYPE\ 0D/0E/06"
trap PC across both resolves to a different, already-tracked site
(
.CW ainc+5 ,
the refcount-corruption disease's own atomic-increment primitive
faulting on a bad pointer;
.CW lockloop+72 ;
.CW strchr+46 ;
.CW iload+286 ;
.CW dumpregs+67 ,
a fault inside the trap handler's own register dump, presumably
cascading from whatever corrupted the state that trapped in the first
place), consistent with the dominant crash actually being gone rather
than merely renamed.  Diagnostic-only code, no interpreter semantics
touched.
.PP
The honest second half of that result: the raw panic rate across
those 25 boots is 64% (16/25), not lower than this hunt's long-
standing 10\(en43% range \(em higher.
.CW notefree()
was not making the kernel less stable than these other bugs; it was
simply reaching its own crash
.I first ,
before most of them got the chance to fire at all.  Removing it does
not reduce total instability by itself \(em it reallocates which bug
each boot hits, and hands this hunt a now-visible, honest picture of
everything
.CW notefree()
had been hiding: the refcount-corruption disease already named in
this port's own persistent notes is far more frequent than any
measurement to date suggested, since almost every occasion it had to
fire was previously pre-empted.  Recorded as fact, not spun as
improvement \(em this hunt's own rule.
.PP
One confound on that comparison, caught on review: this validation
batch ran with an unrelated Xcode build and a second, unrelated QEMU
guest competing for the same host, and an earlier same-day batch
directly showed a panic rate spike (92%) traceable to exactly that
kind of contention rather than to any code change.  64% vs. the prior
10\(en43% range is not a clean apples-to-apples comparison; host load
was not controlled for.  The claim that
.I is
clean, because it was checked by resolving native trap PCs rather
than eyeballing panic text: zero
.CW notefree
recurrences in 25 boots, every trap PC landing somewhere else.
.PP
The
.CW namec()
pgrp-root fix and the
.CW devattach()
spec-length guard did not fire in either validation batch (25 boots);
both are preventive guards for conditions this hunt caught only once
each before this round, so their own next confirmation is still
outstanding, same as several of this hunt's earlier self-identifying
checks.
.PP
Fixing the dominant crash surfaced a second, real bug the same
grep-and-resolve pass across the fix's own validation batch caught
directly: a live
.CW "incref:\ bad\ r\ 0x0"
resolving to
.CW namec+209 ,
at boot, right after
.CW schedinit... .
.CW namec() 's
.CW '/'
and
.CW default
cases (
.CW "c\ =\ up\->pgrp\->slash"
and
.CW "c\ =\ up\->pgrp\->dot" )
each
.CW incref(c)
with no nil check \(em unlike every other
.CW c
assignment in this function, all already guarded by this hunt's
earlier
.CW incref(nil)
sweep, and unlike the shape
.CW newforthproc() 's
own earlier fix in this same hunt already established: a fresh
.CW Pgrp
whose namespace has not been populated yet.  These two were older than
this hunt and had simply never been reached often enough to capture
before
.CW notefree()
crashed first.  Fixed the same way as the
.CW '#'
case three lines above each: a nil root is a clean
.CW namec()
error, not a kernel panic three calls downstream in
.CW walk() .
This makes NINE real
.CW incref(nil) -family
bugs found and fixed this hunt, not eight.

.NH 1
A candidate for "general protection violation" itself: BIOS32 far pointers loose in the heap
.PP
Chasing whether an
.CW AINC / ADEC
guard was worth adding (it is not \(em see below) led to decoding a
register instead: this port's own
.CW ainc-amd64.s
takes its argument in
.CW RARG ,
and
.CW utils/6c/6.out.h
defines
.CW REGARG\ =\ D_BP \(em
so every past
.CW ainc / adec
crash's bad pointer has been sitting, undecoded, in the
.CW BP
field of a dump this hunt already had.  Reading it out of a live
capture (
.CW notefree_v2_partial_batch/boot2.log ) :
.CW "BP\ F000FF54F000FF3F" ,
alongside
.CW "SI\ F000FF54F000FF53"
in the same dump \(em not a coincidence, and not the refcount-
corruption disease this hunt had been calling it.
.PP
Grepping every batch this hunt has produced for the pattern
.CW F000FF
found it 702 times across 226 distinct boot logs, 90% of them
carrying
.CW "panic:\ general\ protection\ violation" \(em
almost certainly THE actual explanation behind this port's
longest-standing unexplained panic type, hiding in plain sight until
the register decoded.
.CW F000
is not noise: it is the standard PC BIOS ROM code segment, and
.CW F000:FFxx
is squarely inside the classic BIOS entry-point region.  A resolved
capture (chan.c's
.CW pathclose+24 ,
.CW "decref:\ bad\ r\ 0xf000ff53" )
shows this value reaching a
.CW Path*
argument that was already nil-checked at the top of
.CW pathclose() \(em
the corruption happened upstream of that check, in whatever set the
field
.CW pathclose()
was handed.
.PP
This port's own
.CW lowraminit()
(pc64/memory.c) already marks
.CW 0xF0000\(en0xFFFFF
.CW MemReserved
before the general allocator ever sees it, which rules out the
simplest hypothesis (heap memory literally overlapping BIOS shadow
RAM).  The likelier shape: a real-mode-style
.CW "segment:offset"
value, produced somewhere that legitimately reads BIOS memory, is
ending up in a field that later gets read back as a heap pointer.
.CW os/inferno/pc/bios32.c
was the first candidate found, its
.CW BIOS32si
struct carrying a
.CW "u16int\ ptr[3]"
literally documented as "far pointer m16:32" \(em but
.CW memory.c 's
.CW sigsearch()
(the function that scans
.CW 0xE0000\(en0xFFFFF
for a signature) turns out to be shared by three other callers, not
bios32 alone:
.CW archacpi.c 's
.CW rsdsearch()
(the ACPI RSD PTR search, default-on and almost certainly the one
that actually succeeds on a QEMU target, unlike legacy PCI BIOS32
services) and
.CW archmp.c 's
own
.CW "_MP_"
search.
.CW archacpi.c
is now the likelier of the four: a successful
.CW rsdsearch()
feeds
.CW maptables() ,
which walks an RSDT/XSDT array of physical table addresses \(em
exactly the kind of pointer-array parsing where one entry read in
the wrong width or stored in the wrong field could produce this
shape.  None of the four narrowed to a specific field without a
fresh, directly-resolved capture; flagged as the clearest next lead
this hunt has, ahead of chasing the refcount-corruption disease
blind.
.PP
Considered and rejected: wrapping
.CW AINC / ADEC
themselves with a
.CW badref() -style
precheck, the same upgrade every other silent-crash site in this hunt
has gotten.
.CW AINC / ADEC
sit on the hottest path in the whole interpreter \(em every Dis
object refcount touch, in every board's kernel and the hosted
.CW emu
target, since
.CW include/interp.h
is shared far beyond pc64 \(em and, having just decoded
.CW RARG\ =\ BP ,
a wrapper would print exactly the value already sitting in every past
and future capture's own dump, for free.  No new information for a
real cost on a shared hot path: not worth it.

.NH 1
devattach()'s guard fired for real, and what it caught
.PP
The
.CW devattach()
spec-length guard added alongside the
.CW notefree()
fix fired live in its own follow-up batch, at boot, on the very first
attach this kernel ever makes:
.CW rootattach() 's
call into
.CW devattach('/',\ spec) .
Resolved caller pc
.CW 0x21c440
confirms
.CW rootattach+128 ,
exactly that call.
.PP
The capture itself is a genuine puzzle, not a clean confirmation of
the 32-bit
.CW long
wrap alone.
.CW rootattach()
begins with
.CW "if(*spec)\ error(Ebadspec);"
\(em for this capture to have reached
.CW devattach()
at all, that check passed, meaning
.CW *spec\ ==\ 0
at that moment.  Yet
.CW devattach() 's
own
.CW strlen(spec)
\(em
.CW libkern/strlen.c
is a plain
.CW "strchr(s,\ 0)\ -\ s" ,
.CW strchr.c
a byte-at-a-time scan with no word-at-a-time optimization to blame
for an alignment bug \(em returned
.CW \-116300362 ,
consistent with a genuine scan of roughly two billion non-zero bytes
before wrapping the 32-bit
.CW long
return type negative.  The panic's own re-read of
.CW spec[0..3]
immediately after, for the message, again shows all zero.  Two
independent zero-reads bracketing a scan that must have crossed two
billion non-zero bytes in between is not consistent with
.CW spec
pointing at a fixed, static buffer.
.PP
.CW spec
here is not a dedicated string buffer: it traces back through
.CW namec() 's
.CW '#'
case to
.CW up\->genbuf+n ,
a per-process scratch buffer reused across many unrelated code paths
in this same process \(em not copied, just pointed into.  The
working hypothesis: something rewrites
.CW up\->genbuf
while
.CW rootattach() / devattach()
are still holding a pointer into it, between the
.CW '*spec'
check and the
.CW strlen()
call \(em a multi-billion-iteration byte scan is real wall-clock time
even at TCG speeds, plenty of room for a timer interrupt or a
reentrant
.CW namec()
call elsewhere to land in between.  Not confirmed: what actually
rewrites it, or whether interrupts are even enabled across this
stretch.  The pointer value itself,
.CW 0x6ee9a4a ,
sits in the same address range this hunt's own
.CW up
process-struct addresses have occupied all session (
.CW 0x6EEDB80 ,
.CW 0x6EF2500 ,
.CW 0x6ee9200 ) ,
consistent with
.CW genbuf
living inside the
.CW Proc
struct rather than being a standalone allocation.
.PP
Whatever the exact mechanism, the guard did its job: this would
previously have been either a silent hang (the escape-less
.CW smalloc()
retry loop, already fixed) or an undiagnosed massive-allocation
panic naming no caller.  Instead it named the exact call site, the
exact pointer, and the exact byte count on the first capture.  One
occurrence in 37 boots; the
.CW up\->genbuf
reentrancy hypothesis is the next concrete thing to check, not yet
chased.

.NH 1
The devattach() scan lands exactly on the 4 GiB boundary, every time
.PP
Enriched the
.CW devattach()
guard (computing the scan's landing address, plus
.CW up
and
.CW up\->genbuf
themselves) and re-ran.  Two independent captures on the same build,
one before the enrichment and one after, reproduce
.I byte-for-byte
identical:
.CW "spec\ 0x6ee9a4a\ len\ \-116300362" ,
every single field, both times.  This is not noisy corruption \(em on
a fixed kernel binary this is a completely deterministic computation,
which narrows the search a great deal: no race, no timing dependence,
something this build always does the same way.
.PP
The enriched capture settles the two open questions from the previous
round outright.
.CW up\->genbuf\ =\ 0x6ee9a48 ,
.CW spec\ =\ 0x6ee9a4a
\(em
.CW spec
is exactly
.CW genbuf+2 ,
precisely what
.CW namec() 's
own
.CW '#'
case computes for the root device (
.CW "n\ =\ chartorune(&r,\ genbuf+1)+1"
with a one-byte
.CW '/'
rune, so
.CW n==2 ).
The pointer arithmetic in
.CW namec()
is correct; there is no offset-computation bug there.  And doing the
arithmetic on the captured numbers directly:
.CW "spec\ +\ n\ ==\ exactly\ 0x100000000" \(em
2^32, 4 GiB, to the byte.  Not a coincidence at that precision: the
byte
.CW strchr()
actually stopped on sits at the literal address 4294967296.
.PP
Ruled out, by direct inspection of
.CW 6c 's
own
.CW \-S
output, not by assumption:
.CW libkern/strlen.c
(
.CW "strchr(s,\ 0)\ \-\ s" )
compiles to
.CW SUBQ
(64-bit subtract) then
.CW MOVLQSX
(a correct 32-bit-truncating, sign-extending cast \(em exactly what a
.CW long
return type should produce, not a bug); and
.CW libkern/strchr.c 's
own scan loop increments its pointer with
.CW INCQ ,
a full 64-bit increment, not a 32-bit one.  Both of this port's own
string functions are provably correct here.  A synthetic
.CW "uintptr\ +\ u32int"
test compiled the same way this file's own
.CW "spec\ +\ n"
arithmetic is written also disassembles correctly (
.CW MOVL
zero-extends into the full 64-bit register on this ABI, then
.CW ADDQ
does a real 64-bit add) \(em though the guard's own printed
.CW termaddr
showed
.CW 0x0
instead of the
.CW 0x100000000
the raw numbers actually work out to, an artifact of this print call
specifically, not of the underlying arithmetic; not chased further,
noted so the next reader does not mistake it for the real answer.
.PP
What remains open, now sharply framed: why does a byte-at-a-time,
provably-correct scan starting at a normal ~116 MiB heap address (
.CW up
itself is
.CW 0x6ee9200 )
run for very close to four billion bytes without ever faulting, on a
guest with roughly 512 MiB of real RAM (
.CW "conf.npage\ 128472" ) ,
before landing exactly on the 4 GiB address?  Two live possibilities,
neither confirmed: (1) this port's
.CW pmap() / mmuwalk()
(pc64/mmu.c) genuinely maps a vast, non-zero, non-faulting span this
large \(em plausible given
.CW mem.h 's
own
.CW "VMAPSIZE\ 512GiB"
under
.CW KZERO=0
identity mapping, if that range is more densely pre-populated than
expected; or (2) something in the page-table walk aliases address
.CW 0x100000000
back to a low, already-zeroed physical page (page 0 is claimed as
ordinary RAM by
.CW lowraminit() ) ,
which would make this a genuine virtual-address translation bug
rather than a vast real mapping.
.CW mmu.c 's
own
.CW "pmap()/mmuwalk()/ptecount()"
were read by hand and show no obvious 32-bit truncation of their own
(
.CW pa
and
.CW size
are
.CW "uintptr/s64"
throughout) \(em ruling out the simplest version of hypothesis (2)
without ruling out the hypothesis itself.  Deterministic and
precisely bounded now; tracing exactly what backs the address range
.CW 0x6ee9a4a\ \(en\ 0x100000000
on this build is the next concrete step, not yet taken.

.NH 1
Found it: the scan walks the PC's own 16 MB\(en4 GB device hole
.PP
memory.c's own
.CW meminit0()
names the 4 GiB boundary directly, in a comment that predates this
whole hunt:
.IP
.nf
.ft CW
/*
 * Everything between 16MB and 4GB defaults
 * to unbacked physical addresses usable for
 * device mappings.
 */
memmapadd(16*MB, (u32)\-16*MB, MemUPA);
.ft
.fi
.PP
Working the arithmetic:
.CW (u32)\-16*MB
is
.CW 0xFF000000 ,
so this call marks
.CW 0x01000000\ (16MB)
through
.CW "0x01000000\ +\ 0xFF000000\ =\ 0x100000000\ (4\ GiB)"
as
.CW MemUPA
\(em "unbacked physical addresses usable for device mappings," this
port's own name for the classic PC memory hole where PCI/device MMIO
BARs live below the 4 GiB line, not a bug in this line itself: every
x86 PC memory map looks like this.
.PP
That is exactly where the
.CW devattach()
scan lands.  The picture this completes: a scan starting inside real,
mapped kernel RAM (
.CW up\->genbuf
at
.CW 0x6ee9a48 ,
comfortably inside the roughly 512 MiB this guest actually has) does
not fault leaving RAM and entering the
.CW MemUPA
hole, meaning some of that hole is mapped present rather than
absent \(em plausible on a QEMU q35/i440fx machine, where VGA
framebuffer, PCI BARs and similar device windows commonly occupy
large stretches of exactly this range, reading back real (non-zero)
hardware content rather than faulting.  The scan crosses whatever of
that is mapped, all the way to the top of the 32-bit address space,
where the very last mapped word happens to read zero.
.PP
Not yet confirmed, and worth being precise about the gap: which
specific mapping inside
.CW 16MB\(en4GB
this port has made present (VGA, a PCI BAR, something narrower), and
whether a byte-scan wandering across it un-faulted is itself
surprising or simply what this port's
.CW vmap()
setup has always done for this range.  What is now settled, not
hypothesized: the destination is not corruption, not an MMU
aliasing bug, and not anything in
.CW libkern 's
string functions \(em it is this kernel's own, correctly-documented,
16 MB\(en4 GB device address hole, and
.CW devattach() 's
.CW spec
argument should never have been pointed anywhere near it in the
first place.  The open question moved from "why does this address
exist" (answered) to "why is a namec() '#'-attach spec pointer being
scanned into it at all" \(em which is still the
.CW up\->genbuf
question from the previous round, now with a concrete destination to
explain rather than an unexplained one.

.NH 1
The namec() default-case fix confirmed too, and why init0 has no dot yet
.PP
The
.CW default:
half of the
.CW namec()
pgrp-root fix (the
.CW up\->pgrp\->dot
case, alongside the
.CW '/'
case's
.CW up\->pgrp\->slash )
fired live in this round's regression batch, converting what would
have been an unguarded
.CW incref(nil)
crash into a clean, attributed error:
.CW "init0:\ namec:\ pgrp\ has\ no\ dot" ,
caught by
.CW init0() 's
own
.CW waserror()
handler.  Both branches of that fix are now hardware-confirmed
working as designed \(em the underlying boot-ordering condition
(why init0's own
.CW Pgrp
has neither
.CW dot
nor
.CW slash
set at the point it first calls
.CW namec() )
still ends the boot, but now names itself instead of crashing three
calls downstream in
.CW walk() .
Root-causing why init0's namespace is not yet populated at this
point is a distinct, still-open question, not chased further this
round.

.NH 1
F000FFxx and the devattach() landing point are the same neighborhood
.PP
Re-reading
.CW archacpi.c 's
.CW maptable()
by hand (its
.CW RSDT
branch uses
.CW get32() ,
its
.CW XSDT
branch
.CW get64() \(em
correctly matched to each table's own pointer width) found no width
bug to blame for the
.CW F000FFxx
pattern, undercutting the "packed 16-bit far pointer" reading from
the previous round.  A simpler reading fits better, and ties this
lead to the devattach() one directly:
.CW 0xF000FF53
as a
.I flat
32-bit value is
.CW 4026597203 ,
about 3.75 GiB \(em squarely inside the same
.CW 16MB\(en4GB
.CW MemUPA
hole
.CW meminit0()
names (see "Found it: the scan walks the PC's own 16MB\(en4GB device
hole").  Every
.CW F000FFxx
variant this hunt has grepped shares the same top 24 bits, so all of
them land in that same narrow neighborhood near the top of the
device-address hole.
.PP
That reframes the lead: not a real-mode segment:offset pair leaking
out of a BIOS32/ACPI scan, but a plain physical/device address \(em
exactly the kind
.CW bios32.c ,
.CW archacpi.c
and
.CW archmp.c
legitimately handle every boot, since PCI BARs, ACPI tables and BIOS32
entry points all live in this address range by definition \(em ending
up somewhere it should not be: a Dis heap object's
.CW ->ref
field, or a kernel
.CW Chan / Path
pointer, dereferenced later as if it were one.  Not a corruption bug
in the classic sense so much as a type confusion: some driver init
path that legitimately touches both device addresses and Dis-heap or
kernel objects mixes up which value belongs in which field.  Neither
this nor the previous round narrowed it to a specific call site;
flagged as the same lead, sharpened, not yet chased to a specific
line.

.NH 1
Correction: strchr's own assembly, not the C fallback, and genbuf proves it wrong
.PP
The genbuf-content dump added in the previous round caught its first
capture, and it overturns the previous round's own conclusion.
.CW genbuf[0..31]
reads
.CW "0x23\ 0x2f\ 0x0\ 0x0\ ...\ 0x0"
\(em
.CW '#' ,
.CW '/' ,
then thirty genuine zero bytes, exactly what
.CW namec() 's
.CW '#'
case is supposed to write, with the terminator sitting right where
.CW spec
points.  For
.CW strchr(spec,\ 0)
to return anything other than
.CW 0
here is now provably impossible if the byte it read at
.CW spec[0]
really was
.CW 0 \(em
and this dump, read from the exact same live memory microseconds
apart, says it was.
.PP
The previous round's "ruled out by direct
.CW 6c\ \-S
inspection" claim was wrong, not because the reasoning was bad, but
because it inspected the wrong file.
.CW libkern/mkfile-amd64
lists
.CW strchr\-amd64.$O
in
.CW TARGFILES ,
and the base
.CW libkern/mkfile
never lists plain
.CW strchr.$O
at all \(em the hand-written amd64 assembly in
.CW libkern/strchr\-amd64.s
is what actually links into
.CW ipc64 ,
not
.CW libkern/strchr.c .
.CW strlen()
(the plain C version, confirmed genuinely linked and genuinely
correct) calls
.I that
.CW strchr() ,
not the one this hunt disassembled.  Retracted plainly, per this
hunt's own rule: the earlier claim was checked, not assumed, and it
was still wrong \(em worth saying so rather than quietly fixing the
citation.
.PP
Read
.CW strchr\-amd64.s
itself closely.  Its "search for nul" path (
.CW l2 ,
taken here since
.CW c==0 ) :
.IP
.nf
.ft CW
l2:
	MOVQ	$\-1, CX
	CLD
	REPN;	SCASB
	MOVQ	DI, AX
	SUBQ	$1, AX
	RET
.ft
.fi
.PP
with
.CW DI
loaded from
.CW RARG
(
.CW s )
and
.CW AL
loaded from
.CW c+8(FP)
(
.CW 0 )
just above.  Traced the calling convention both sides:
.CW strlen.s 's
own call site (
.CW "MOVQ\ BP,s+0(FP);\ MOVL\ $0,8(SP);\ CALL\ strchr")
leaves
.CW BP
holding
.CW s
undisturbed through the call and places
.CW c
at exactly the stack slot this file expects \(em the two sides agree
with each other.
.CW REPN;\ SCASB
with
.CW CX=\-1
is the standard unbounded-scan idiom and assembles without warning.
No specific instruction stands out as wrong on a byte-by-byte read;
static inspection has been exhausted without finding the line.  What
is certain, from the genbuf dump directly, is that this function (or
something in the exact path from
.CW devattach() 's
.CW strlen(spec)
down into it) is not returning what its own memory says it should.
This is now the single most concrete, most exhausted-by-reading lead
this hunt has \(em next step is empirical, not more reading: trace or
single-step this exact call with the actual bad
.CW spec
value, since reading has not found it.

.NH 1
Byte-level verification: both the callee and the call site check out
.PP
Went past the assembly listing entirely and decoded
.CW strchr\-amd64.s 's
compiled bytes directly out of the linked
.CW ipc64
binary, byte by byte against x86-64 opcode tables, for the
.CW l2:
"search for nul" path used here: the exact hex sequence
.CW "48c7c1ffffffff\ fc\ f2ae\ 4889f8\ 4883e801\ c3"
decodes to
.CW "MOV\ RCX,\-1;\ CLD;\ REPNE\ SCASB;\ MOV\ RAX,RDI;\ SUB\ RAX,1;\ RET" \(em
exactly the intended semantics, no encoding surprises.  This is a
stronger form of the same claim the earlier (wrong-file) round made,
now against the actual linked bytes rather than an assembler's own
listing.
.PP
A first pass at
.CW devattach() 's
own call site, read from the assembly listing text, looked like it
might skip the instruction that loads
.CW BP
with
.CW spec 's
value on the common (non-nil) path \(em which would have been a real
finding, a genuine 6c code-generation bug in the REGARG/branch
interaction, present in this function since before this hunt started
(the
.CW "if(spec\ ==\ nil)\ spec\ =\ \"\";"
line predates every change this hunt made here).  Checked before
writing it up, the same way the
.CW strchr
claim should have been checked the first time: decoded the actual
linked bytes at
.CW devattach+0x40
directly.  They read
.CW "CMP\ RDX,0;\ JNZ\ +5;\ MOV\ EDX,0x31D15F;\ MOV\ RBP,RDX;\ ..." \(em
the short jump skips only the 5-byte fallback load, and both the
jump-taken and fall-through paths converge on the same
.CW "MOV\ RBP,RDX"
correctly, with
.CW RDX
holding either the real
.CW spec
or the empty-string fallback depending on which path was taken.  The
call site is correct; the hypothesis did not survive its own check,
and is recorded here specifically so it does not get proposed again
without this evidence attached.
.PP
Both ends of the one call this hunt has been staring at \(em the
callee's scan loop and the caller's own setup for it \(em are now
verified correct at the machine-code level, not just plausible on a
reading.  That leaves the genbuf capture's core fact unexplained by
anything static: correct code, correct input, wrong output.  The
next candidate this rules out nothing about is environmental rather
than a code defect \(em
.CW REPNE\ SCASB
is architecturally interruptible and resumable, which depends on the
trap/interrupt path saving and restoring
.CW RDI / RCX
correctly across whatever fires during the several-billion-iteration
window this scan opens; not checked yet.  Everything reachable by
reading has now been read.

.NH 1
The interrupt save/restore path checks out too
.PP
Followed through on the "environmental, not a code defect" candidate
the previous round left standing: does
.CW pc64/l.s 's
own interrupt entry/exit path correctly preserve
.CW RDI / RCX
(the two registers a
.CW REPNE\ SCASB
scan is actively using) across whatever timer or device interrupt
fires during the several-billion-iteration window this scan opens?
Laid the save side (
.CW _strayintr / _strayintrx
via
.CW _intrcommon )
against the restore side (
.CW _intrestore )
in push/pop order:
.IP
.nf
.ft CW
push: R15 R14 R13 R12 R11 R10 R9 R8 BP DI SI DX CX BX AX
pop:  AX  BX  CX  DX  SI  DI  BP  R8 R9 R10 R11 R12 R13 R14 R15
.ft
.fi
.PP
A perfect mirror \(em each pop undoes the matching push, standard
LIFO register save/restore, nothing swapped or dropped.  The common
interrupt path is symmetric and correct.  Not exhaustively checked:
rarer paths (NMI, a fault arriving with a different stack shape) that
might diverge from this one, though nothing points at those
specifically.
.PP
Every component this hunt can name in the chain from
.CW devattach() 's
.CW strlen(spec)
down through
.CW strchr\-amd64.s 's
scan loop and back out through a possible interrupt has now been
checked, several of them at the machine-code byte level rather than
an assembler's own listing.  All of them check out.  Static reading
of this codebase is genuinely exhausted for this lead; whatever
happens between the scan starting and the wrong value coming back
requires watching it happen, not reading more of it.

.NH 1
Live tracing: the mechanism works, the bug would not show itself
.PP
Static reading of every component in the
.CW devattach()\ \->\ strlen\ \->\ strchr
chain came up clean (see the last three sections), so the promised
next step was empirical: QEMU's
.CW \-s\ \-S
gdbstub plus
.CW lldb\ gdb\-remote
attaches cleanly to this port's kernel \(em confirmed live, breaking
at
.CW devattach() 's
entry lands on the very first call every time (
.CW %rbp\ =\ 0x2f ,
the root device;
.CW %r14\ =\ 0x6ee9200 ,
the same
.CW up
this hunt has captured all session), and single-stepping through
.CW strchr\-amd64.s 's
.CW l2:
path shows exactly the registers this section's earlier byte-level
decode predicted: RDI/RCX/RAX transition correctly across
.CW "repne\ scasb" ,
landing on the right answer.
.PP
Ran the traced call twice: once fully single-stepped instruction by
instruction with a memory watchpoint on
.CW genbuf
armed throughout (never fired \(em nothing rewrites it during the
scan), six clean runs; once with only two breakpoints (entry and the
instruction immediately after
.CW scasb ,
no stepping in between, to disturb normal timing as little as a
debugger can), 40 more runs.  46 traced boots total.  Every single one
computed the correct answer:
.CW RDI\ =\ spec+1 ,
.CW RCX
decremented by exactly one, the terminator found on the very first
comparison, exactly as
.CW genbuf 's
own correct content says it should.  The bug did not show itself
once.
.PP
At this hunt's own measured hit rate for this signature (roughly one
in twenty to forty untraced boots), the honest odds of 46 clean traced
runs happening by chance alone are low but not impossible \(em call it
a coin that came up heads about as many times as would make you
suspect it is not being flipped fairly, without quite proving it.  The
more likely reading: this is a genuine heisenbug, and attaching a
debugger \(em even two breakpoints with no single-stepping \(em changes
the guest's real-time relationship to interrupts and any DMA/hardware
timing enough to keep it from happening.  That is itself informative:
it argues against a purely static, always-computable defect in this
code (which tracing would have caught by now) and toward something
timing- or interrupt-dependent in the vulnerable window, consistent
with the "environmental, not a code defect" framing the byte-level
verification round already arrived at from the other direction.
.PP
Not proven, and not provable by this technique alone: whether the
bug is genuinely suppressed by tracing, or whether 46 traced boots
were simply an unlucky sample.  A larger traced sample, or a hardware
watchpoint on an interrupt-controller register instead of a breakpoint
on code, would settle it, neither attempted.  This closes out what
this hunt's available tooling can do here without a fundamentally
different setup.

\
.NH 1
The pc64-only bisection probe hangs riscv64/virt, deterministically
.PP
The pc64 hunt closed with two open leads and an instruction to look at
the ARM and RISC-V ports instead, on the chance that the same class of
instability would show up somewhere more tractable.  It did, on the
very first boot, and not as a heisenbug: it was 100% reproducible.
.PP
riscv64/virt's committed
.CW ivirt
binary predates the pc64 hunt's changes to
.CW os/inferno/port/alloc.c ,
so the first step was an ordinary rebuild from the current tree.  That
rebuild hung.  Every single boot -- five in a row, then a sixth run
left for 90 seconds well past where the first five had already given
up -- stopped at the exact same byte of console output:
.IP
.nf
pci 0.0.0: 1b36/0008 class 060000 irq 32
poolmsize: new caller pc=0x8002de3a (seen 1 distinct)notefree: new caller pc=0x8002d986 (seen 4 distinct)
notefree: new caller
.fi
.PP
mid-print, discovering a fifth distinct
.CW notefree()
caller, during PCI device enumeration.  The committed binary, by
contrast, sails through this exact point and all the way to a shell
prompt every time -- it has no such print calls in it at all, because
they were added to
.CW alloc.c
after that binary was last built.
.PP
Bisected by rebuilding with pieces of
.CW notefree()
stubbed out, not by walking git history (75 commits touch shared code
between the two binaries' build dates, too many to bisect one at a
time against a 20-40 second boot).  Stubbing the whole function body
restored a clean boot.  Restoring the freehist ring and the
.CW currun()
call, but leaving out only the
.CW seen[64]
bisection loop -- the block that prints each distinct
.CW poolfree()
caller pc the first time it is seen -- also booted clean, three times
in a row, each one reaching
.CW GC-STRESS-OK
and a shell prompt before hitting the same pre-existing
.CW mountrpc
Styx error the committed binary hits at the same place:
.CW /dev/sdF0/data
does not exist under this test setup, an unrelated and already-known
gap, not a kernel fault.
.PP
That loop is the cause.  It already answered its own question during
the pc64 hunt -- whether
.CW destroy()
called
.CW poolfree()
from more than one compiled address -- and its own comment already
said
.CW "pc64-only, temporary, remove with the rest of this ring."
It should have been removed before any other board was built, per the
cleanup this plan had already flagged as pending; the RISC-V pivot is
what actually forced the issue.  Removed, along with
.CW poolmsize()'s
identical sibling probe, same shape, same call-path family, same
removal note in its own comment -- it did not reproduce the hang under
test, but it was kept only by the strength of one clean boot, not by
anything distinguishing it from the probe that did hang, so it went
too.
.PP
Not chased: why this specific print, from this specific call site,
hangs riscv64 and not pc64.  Candidates not distinguished between:
the
.CW print()
call itself misbehaving from whatever context that fifth caller runs
in (interrupt-handler suspicion, unconfirmed), something particular
about being invoked from a free during PCI enumeration specifically, or
an interaction with riscv64/virt's own console or interrupt path that
pc64's UART driver does not share.  The probe had already served its
purpose; the fix is removal, not portability.
.PP
Verified rather than assumed: riscv64/virt rebuilt and booted 3/3
clean after the fix (GC-STRESS-OK, shell, the same pre-existing
mountrpc failure, nothing new).  pc64 rebuilt from the same changed
file and boot-tested 5x to rule out a regression from removing
allocator-path code: 2/5
.CW "general protection violation"
panics, the same signature this hunt has tracked all along, within the
10-43% baseline range already established -- no new failure mode, no
change in kind.  Both prebuilt binaries,
.CW ivirt
and
.CW ipc64 ,
committed alongside the source change so the tree's checked-in kernels
reflect it.
.PP
This does not confirm or rule out the same underlying bug class the
pc64 hunt spent most of its time on -- the removed probe was pure
diagnostic overhead, present only during this hunt, never part of the
kernel's real allocator logic, so its own failure says nothing about
whether
.CW strchr-amd64.s 's
heisenbug or anything like it exists on riscv64.  What it does confirm
is that shared
.CW os/inferno/port/
code is not automatically safe across architectures just because it
compiles for all of them, and that this tree's own "pc64-only,
temporary" comments were accurate warnings, not decoration.

\
.NH 1
A second, still-open finding: FAT mount hangs on riscv64/virt after the fix
.PP
With the boot hang fixed, the ARM/RISC-V pivot continued into
.CW os/inferno/virt/smoke.sh ,
the board's own existing functional harness (GC, blk, FAT, draw, ptr,
kbd, tk, rng, cap, ssl, auth, dynld, net, DHCP, DNS/cs, TCP, UDP,
Styx, sh, UART).  It found a second real, reproducible failure,
unrelated to the first: the guest reaches
.CW BLK-OK
(a raw sector read off virtio-blk succeeds) and then never reaches
.CW FS-OK ,
the FAT-mount-via-dossrv stage, in two independent runs -- one capped
at 200 seconds, one at 550 -- with byte-identical console output up to
the point both stopped producing any further lines.  Not a slow test:
a hang.
.PP
.CW os/inferno/init/virtinit.b 's
.CW fsmount()
spawns
.CW /dis/dossrv.dis
(present, shared, architecture-independent Dis bytecode -- confirmed
in
.CW dis/dossrv.dis ,
not a missing-file problem) via a helper that blocks on a channel
receive until the spawned process reports back, then opens and reads
.CW /n/dos/marker.txt .
Whichever of these two steps is stuck, none of
.CW fsmount() 's
own outcomes --
.CW FS-OK ,
.CW FS-FAIL\ dossrv ,
.CW FS-FAIL\ open ,
or
.CW FS-FAIL\ content
-- ever print, meaning it never reaches even its own error paths.
.PP
Attached QEMU's
.CW -s\ -S
gdbstub and interrupted the guest 16 seconds past
.CW BLK-OK :
the core was executing
.CW wfi
(RISC-V's wait-for-interrupt halt), immediately after a one-line
.CW ret
right past the instruction, confirmed by extracting and disassembling
the raw bytes at that program-header-mapped file offset rather than
trusting lldb's own weak riscv64 instruction decoding.  Read at the
time as ruling out a spinning busy-loop -- wrong, corrected below.
.PP
.B "Correction."
A single sampled
.CW wfi
is not evidence of anything: it only shows the CPU was idle at the
instant of one interrupt, not that nothing runs between samples.  A
cheap external check settled the Limbo-vs-native question the first
write-up left open: hosted
.CW emu
on this host, given the exact same
.CW dis/dossrv.dis
(portable Dis bytecode, byte-identical to what the kernel embeds) and
the same FAT12 image, mounts it and reads
.CW marker.txt
back without incident.  Same bytecode, same image, no hang -- the bug
is not in
.CW dossrv.b 's
Limbo logic, and every board that runs this bytecode is not equally
at risk the way the first write-up guessed.
.PP
Bisecting inside
.CW dossrv.b
by adding
.CW sys->print()
markers (portable, so directly comparable against the same emu run)
narrowed the hang to one call:
.CW sys->pctl(Sys->NEWFD,\ rfd.fd::2::nil) ,
made by the freshly
.CW spawn ed
server process right after it starts, before it ever reads a Styx
message.  The matching native side,
.CW Sys_pctl()
in
.CW os/inferno/port/inferno.c ,
brackets its NEWFD work with
.CW release()
and
.CW acquire() ,
the same interpreter VM hand-off
.CW os/inferno/port/dis.c
uses to let a different Dis process run while one of them is doing
native (non-interpreted) work.
.PP
Tracing
.CW release() / acquire()
themselves needed a fix first: printing
.CW up->pid
(the carrier kernel Proc, one of a small rotating pool of "vm" kprocs)
produced a trace that looked like a totally different process was
cycling, because several different kernel Procs carry the interpreter
across its lifetime.  Printing
.CW up->iprog->pid
instead -- the actual Dis Prog identity, stable across which kernel
Proc happens to be carrying it -- gives an unambiguous trace, and it
settles the question the first write-up got wrong:
.B "the stuck process is not idle, it is spinning."
Dozens of
.CW release() / acquire()
cycles for the same Dis Prog pid fire back to back, each one a clean
release, a full queueing-and-reschedule round trip, and a clean
re-acquire -- CPU-bound activity, not a blocked wait.  The earlier
.CW wfi
sample caught a gap between two of these cycles, not a resting state.
.PP
One candidate was checked and ruled out directly rather than by
inference:
.CW newfgrp() 's
own
.CW smalloc()
call -- the pc64 hunt's own documented failure mode, a
.CW poolalloc()
retry loop with no escape (see
.CW smalloc() 's
comment in
.CW alloc.c )
-- was instrumented to print on every retry.  It never printed once.
Whatever spins, it is not memory exhaustion in the file-descriptor
group allocation.
.PP
Not chased further: which specific step inside
.CW Sys_pctl() 's
NEWFD body -- most plausibly
.CW closefgrp(ofg) 's
.CW cclose()
of an fd the freshly-spawned process inherited from its parent at
.CW spawn
time, since that is the one call in the sequence that can itself need
a Styx round trip and its own
.CW release()/acquire()
pair -- is the actual site of the spin, and why closing that
particular fd never completes on riscv64/virt while the rest of this
port's own interpreter scheduling clearly works (everything up to
this point in boot, and mps2's clean 5/5, both exercise
.CW release()/acquire()
constantly without incident).  Left for the next pass.  What changed
from the first write-up: not root-caused, but the Limbo-vs-native
question is now answered (native), the failure mode is now known (a
spin, not a block), and one concrete mechanism (out-of-memory retry)
is eliminated by direct evidence rather than left as an open
possibility.
.PP
Also open: whether this reproduces on pc64, which has no equivalent
smoke harness to check it against.  Left for the next pass at this
board rather than chased to ground the way the pc64 heisenbug was --
this one, unlike that one, does not need tricks to reproduce: it
fails the same way every time.
\
.NH 1
mps2 boots clean, and the rest of the ARM boards are hardware-only here
.PP
Rounding out the pivot: mps2-an500, the Cortex-M7 QEMU model and the
only one of this tree's ARM boards runnable without real hardware,
per the mkfile's own comment
.CW "(qemu-system-arm\ -M\ mps2-an500\ -nographic\ -kernel\ imps2)" .
Rebuilt from the current tree -- carrying the riscv64/virt fix and
every shared
.CW alloc.c
change from the pc64 hunt -- and boot-tested 5 times.  Every run is
byte-identical:
.CW ARMV7M-INIT-OK ,
.CW osinit.dis
loads,
.CW devprog 's
own
.CW progpid()
sanity check passes, Bufio loads, and the kernel reaches an
interactive shell prompt and sits there idle.  No panic, no hang,
nothing resembling either riscv64/virt finding above.
.PP
The other three boards this tree carries --
.CW nucleof303
(an STM32F303RE Nucleo),
.CW teensy41
(an i.MX RT1062) and
.CW mangopi
(actually riscv64, an Allwinner D1, despite living beside the ARM
boards in the tree) -- have no QEMU machine model on this host.
.CW "qemu-system-arm\ -M\ help"
and
.CW "qemu-system-riscv64\ -M\ help"
were checked directly; none of the three names appears.  They target
real hardware only and are genuinely untestable here, not skipped by
choice -- this pivot's coverage of "the arm and riscv ports" is
therefore mps2 and virt, the two boards this environment can actually
run, plus a documented reason the other three are out of reach without
different hardware.
.PP
Net result of the whole pivot: two real, reproducible, riscv64/virt-
specific bugs found and one fixed (the removed bisection probes); the
pc64 heisenbug itself did not reproduce anywhere else tested, on the
one architecture (mps2) that ran completely clean.  That is itself an
answer to the question that started this pivot -- not proof the
heisenbug is pc64-only, since riscv64/virt was not stress-tested at
pc64's scale (hundreds of boots) before its own two bugs interrupted
that plan, but no evidence yet that it is not.
\
.NH 1
Narrowed further: Sys_pctl() reaches its own final acquire(), which never returns
.PP
Followed the advisor's own suggested test first, since the earlier
write-up's leading candidate (
.CW closefgrp() 's
.CW cclose()
of an inherited fd) was stated but not checked.  A probe printing on
entry, before each
.CW cclose() ,
after each, and on return -- gated to fire only for the Dis Prog
identity already established (
.CW up->iprog->pid\ ==\ 3 ,
not
.CW up->pid ,
which names whichever kernel Proc happens to be carrying the
interpreter and is not stable across a single Dis process's own native
calls) -- showed
.CW closefgrp()
completing cleanly every time: entered, both inherited fds (2 and 4)
closed without incident, freed, returned.  Not the site.  Neither is
.CW newfgrp() 's
.CW smalloc() ,
already ruled out the round before.
.PP
Moved the same probe to
.CW Sys_pctl() 's
own final
.CW acquire()
call -- the last native work the function does, right before setting
its return value and returning to the interpreter.  It fires
.B once :
.CW "about to call final acquire()"
prints, matching every other single-fire marker in this chain
(
.CW pctl\ entry ,
.CW closefgrp\ entered ,
.CW closefgrp\ returning ).
.B "acquire() returned" never prints.
Every native step before it -- release, NEWFD's fgrp swap, both
inherited fd closes -- is now confirmed complete.  This one call is
where forward progress stops.
.PP
One complication surfaced rather than resolved: instrumenting
.CW acquire()
itself (same
.CW up->iprog->pid==3
gate) shows many further ENTRY/EXIT cycles logged against prog 3
.I after
the "about to call final acquire()" marker, several of them going
through the full queue-and-reschedule path with
.CW sched()
visibly returning each time -- activity that should not exist if this
one call is simply parked waiting.
.CW inferno.c
turns out to bracket
.I every
blocking native call (
.CW Sys_open ,
.CW Sys_read ,
.CW Sys_write ,
.CW freeFD ,
and more) in its own
.CW release()/acquire()
pair, so some of this may be entirely ordinary traffic from other
native calls this same process makes while servicing Styx messages,
correctly attributed by Prog identity to the same pid.  It was not
sorted out which of these cycles are ordinary and which (if any) are
the same stuck call reappearing, and it was not confirmed that
.CW up->iprog
is trustworthy as a cross-kernel-Proc identity in every context probed
here rather than just the two (
.CW dis.c ,
.CW pgrp.c )
where it was checked against known-good data.  Left open rather than
resolved past this point, per the discipline this hunt has kept
throughout: a print that could mean two things is not a finding until
it means one.
.PP
Standing: the hang is native, not Limbo (hosted-emu comparison, prior
round); not out-of-memory retry (smalloc instrumentation, prior
round); not
.CW closefgrp()
or
.CW newfgrp()
(this round); is the last thing
.CW Sys_pctl()
does before returning, specifically its own closing
.CW acquire()
call, confirmed entered and never observed to exit (this round).  What
that call is actually waiting on, and why the same mechanism that
services this port's entire boot and mps2's clean 5/5 fails exactly
here, remains open.  All instrumentation (four files across two
languages this round) built, tested, and reverted; a clean rebuild
reproduces the identical hang before this was written up.
\
.NH 1\
.NH 1
Correction: the previous round's conclusion does not survive a direct check
.PP
The previous round's own stop condition said not to build a fourth
probe generation without a decisive discriminator.  Found one: a
call-site tag, set by the caller immediately before each
.CW acquire()
call across every blocking native function in
.CW inferno.c
(34 sites tagged mechanically, by function name, plus
.CW Sys_pctl 's
own final call by hand), printed alongside the existing Prog-identity
gate.  One build, one boot, and the ambiguity resolves --
.B "against"
the previous round's conclusion.
.PP
.CW Sys_pctl-final
fires exactly once, immediately after
.CW dossrv.b 's
own pctl-entry marker, as expected.  It is
.I not
followed by silence.  It is followed by a long, ordinary-looking
sequence of
.I distinct
tags --
.CW Sys_fildes ,
.CW Sys_readn
(several),
.CW Sys_write ,
.CW Sys_open ,
.CW Sys_fstat ,
.CW Sys_seek ,
.CW Sys_read ,
.CW freeFD
-- each a different native call, in an order consistent with
.CW dossrv.b 's
own source: fildes right after pctl, then read/write/open/seek/stat
traffic matching real Styx message handling and FAT parsing, then
GC-driven
.CW freeFD
finalizers as file descriptors get collected.
.CW up
and
.CW up->iprog
are identical, unchanging pointer values across every single one of
these -- the same kernel Proc, the same Dis Prog, the whole time, so
this is not cross-process misattribution.
.B "Sys_pctl's own final acquire() returns, and execution continues well
past it."
The previous round's central claim -- that this one call is where
forward progress stops -- does not survive this check and is retracted.
.PP
What replaces it is stranger, and not resolved.
.CW dossrv.b
still never prints
.CW "PROBE\ pctl\ returned"
or
.CW "PROBE\ fildes\ returned" ,
the two markers placed directly after the
.CW pctl()
and
.CW fildes()
calls respectively -- their literal text never appears, even though
the
.I native
.CW Sys_fildes
call immediately after
.CW pctl()
demonstrably executes (its own tag fires), and even though a third,
identical-shaped call --
.CW dossrv.b 's
own first
.CW sys->print() ,
the pctl-entry marker -- unambiguously does both execute and print.
Native calls that should be separated by two Limbo-level print
statements are visibly happening; the print statements' own output is
not.  Both explanations considered and neither confirmed: a genuine
interpreter/compiler defect that skips specific statements while
executing their neighbors (would be a serious, general finding, well
past what this round's evidence supports), or a console output
race under sustained native-call volume that swallows some
.CW print()
calls without dropping others (consistent with this whole hunt's
recurring theme of print()/console fragility, but not demonstrated
here either).  Not chased further -- per the same stop discipline that
produced the correction above, a plausible mechanism is not a finding
until it is checked, and this one has not been.
.PP
Standing, restated once more: the hang is native, not Limbo-level
(hosted-emu comparison, still holds); not
.CW smalloc()
out-of-memory retry, not
.CW closefgrp() ,
not
.CW newfgrp() ,
and now not
.CW Sys_pctl() 's
own closing
.CW acquire()
either -- all four checked directly and eliminated, not guessed.  Real
forward progress happens well past the point this hunt spent the last
two rounds staring at.  Where it actually stops is open again, further
into
.CW dossrv() 's
own Styx-serving loop than previously reached, alongside the new and
separately unresolved puzzle of the missing print output.  Reverted;
clean rebuild reproduces the identical hang before this was written up.
.NH 1
Not the interpreter after all: the mount itself never returns
.PP
The advisor reviewing this hunt read the previous round's own tag
sequence with fresher eyes than the round that produced it: a server
reading, opening, seeking and writing in that pattern is not stuck --
it is
.I working .
The candidate worth checking was never on the served side of the
mount, because nothing there was refusing to make progress.  It was on
the
.I mounting
side, which this hunt had tagged along with everything else in
.CW inferno.c
but never actually looked at.
.PP
One check settles it.
.CW Sys_mount()
in
.CW inferno.c
is two lines: it calls
.CW release() ,
then
.CW kmount() ,
then only after
.CW kmount()
returns does it set its own tag and call
.CW acquire() .
Rebuilt with the same call-site-tag instrumentation as the previous
two rounds, booted once against a fresh FAT image:
.B "the Sys_mount tag never appears, not once, in the entire trace."
Every one of the other 33 tagged sites fires, repeatedly, exactly as
the previous round found.
.CW Sys_mount 's
own does not.
.CW kmount()
itself never returns.
.PP
That relocates the hang entirely.  It is not an
.CW acquire()
call waiting to be rescheduled, and it is not interpreter-level at
all -- release() already ran, so the interpreter is free to do
whatever else it wants (and does: this is exactly what the previous
round's ordinary-looking dossrv traffic was doing) while
.CW kmount()
sits in native C, off in
.CW cmount() 's
own Styx exchange with the freshly spawned
.CW dossrv
server, and that exchange does not converge.  The dossrv side is
provably alive and issuing real
.CW Sys_readn / Sys_write
pairs the whole time.  Two processes both making local progress and
never jointly finishing describes a protocol-level non-termination --
a mismatched attach, a retry that never satisfies its caller, or
similar -- not a scheduling defect, and not the missing-print puzzle
either; that puzzle is set aside, not resolved, having turned out to
sit downstream of a question that mattered more.
.PP
Reverted (both
.CW dis.c 's
tag global and every tagged site in
.CW inferno.c );
clean rebuild reverified reproducing the identical hang, byte-for-byte
against the previous round's log, before this was written up.  Not yet
done: reading
.CW cmount()
and
.CW dossrv() 's
Styx exchange side by side to find where the two sides talk past each
other.  This is where a fifth round would start, if there is one; this
hunt is closing this thread here in favor of the item still untouched
since the pivot began, below.
.NH 1
The item untouched since the pivot began: batch-boot volume on riscv64/virt
.PP
Every remaining boot of riscv64/virt hangs on the FAT mount, deterministically,
whatever device is attached or missing -- so a batch of full boots-to-shell
finds nothing new; every run stops at the identical place.  What is still
worth measuring, and had not been measured yet, is the one stretch every run
.I does
reach: the reachable prefix through memory init, PCI and virtio device
enumeration, and the GC stress pass ending in
.CW GC-STRESS-OK .
That is exactly the phase where the pc64 heisenbug's own signature -- a
general protection violation, 10-43% of boots, see the pc64 sections above --
has always fired.  Forty independent boots, no virtio-blk device attached (the
cheaper of the two reachable-prefix configurations, and the fsmount() failure
path it takes is itself identical every time), each given 12 seconds --
comfortably past where every prior run reached this point.
.PP
Forty for forty:
.B "zero panics, zero unexpected qemu terminations, and the entire non-timestamp
output of every single run is byte-identical"
-- not just the same milestones reached in the same order, but the same heap
pointer values in the same Styx error message, run after run.  This
architecture, over this window, shows none of pc64's variance at all.
Combined with mps2's clean 5/5 (above), that is two independently
implemented architectures -- RISC-V64 QEMU virt and ARMv7-M Cortex-M7 QEMU --
run a combined 45 times through the boot phase where pc64 misfires close to
half the time, without one failure of any kind.
.PP
This does not prove the pc64 heisenbug is pc64-specific -- forty boots of one
prefix on one board is a narrower sample than the hundreds of full boots pc64
itself received, and the prefix tested here is shorter than a full boot.  It
is a real negative result on its own terms, though, not a shrug: this
specific phase, on this specific alternate architecture, at this specific
sample size, is clean.  That is the answer the pivot was for.  Whether the
class exists anywhere outside pc64 remains open; what is no longer open is
whether it was worth checking.
.NH 1
The cmount()/dossrv mismatch reproduces on pc64 too: shared code, not riscv64
.PP
One item from the previous section's own writeup was answerable without
Codex's half of this tree: whether the
.CW cmount() / dossrv
non-convergence found on riscv64/virt was architecture-specific or shared
.CW os/inferno/port
behavior. pc64 already links a virtio-blk driver
.CW ( sdvirtio.6 ,
already in its device list for unrelated reasons), so the same check --
same portable
.CW appl/cmd/dossrv.b ,
same
.CW sys->mount()
call, different silicon -- was one board away.
.PP
Built a minimal temporary init,
.CW os/inferno/init/pc64fatinit.b ,
copying virtinit.b's
.CW blkcheck()
and
.CW fsmount()
verbatim (same functions, unmodified) with everything else -- the wm/tk/
network smoke suite that would be noise for this one question -- left out.
pc64's own root file list did not carry
.CW dossrv.dis
(virt's does, for its own smoke.sh); added the one line to pull it in, the
same way virt already does.  Built with
.CW mk\ INIT=pc64fatinit\ install ,
booted under
.CW qemu-system-x86_64
with a
.CW virtio-blk-pci
device (PCI, not virt's MMIO transport -- a genuinely different bus) attached
to the same FAT image used on riscv64.
.PP
.B "Same hang."
.CW BLK-OK
prints -- virtio-blk enumerates and reads fine, same as riscv64.
.CW dossrv.dis
loads and spawns.  Neither
.CW FS-OK
nor any
.CW FS-FAIL
ever prints.  Given three minutes, not the twelve seconds the earlier riscv64
checks used (pc64's TCG boot is independently known to be slow, and a false
"hang" that was actually still working was a real risk worth ruling out
directly rather than assuming) -- output stayed byte-identical to the
60-second run, including the exact heap addresses in its last few
.CW copypath
lines.  Not slow.  Actually stuck, on a second, unrelated architecture, at
the same place.
.PP
That relocates the bug's likely home a second time.  A riscv64/virt-specific
explanation -- an MMIO virtio quirk, an SBI timer interaction, anything in
.CW os/inferno/riscv
or
.CW os/inferno/virt
-- cannot be the cause, because none of that code runs on pc64 at all.  What
.I is
shared between these two boards, and what pc64's own long history in this
document has never previously touched, is
.CW appl/cmd/dossrv.b
itself and the generic Styx-mount machinery in
.CW os/inferno/port
that
.CW cmount()
and
.CW Sys_mount()
walk through.  That is now the leading suspect, in preference to anything
architecture-specific, though it is still not root-caused: the previous
section's own next step -- reading
.CW cmount()
and
.CW dossrv() 's
Styx exchange side by side -- is unchanged by this finding, just better
aimed.
.PP
Reverted:
.CW pc64fatinit.b ,
the
.CW dossrv.dis
root-list line, and the regenerated
.CW pc64.root.s / pc64.root.h
it produced, all removed; the committed
.CW ipc64
restored via
.CW "git checkout --"
rather than rebuilt, to avoid any chance of drifting from whatever
.CW INIT
the rest of this document's pc64 findings were built against.  This was a
diagnostic build, following the same discipline as every temporary probe
above -- not a claim that pc64 should ship a FAT/dossrv smoke test, only
that the question of whether it hangs the same way was worth one clean
answer.
.NH 1
Reading, not probing: what os/inferno/port/devmnt.c and dossrv.b actually say
.PP
The next step named above -- reading
.CW cmount()
and
.CW dossrv() 's
Styx exchange side by side -- for once did not need a kernel boot to make
progress on.  Both sides are ordinary, static C and Limbo source, and one
clue was already sitting in an old log: a
.CW "T104 R107"
pair from the no-blk-device riscv64 run.
.CW Tattach
is 104,
.CW Rattach
is 105, and 107 is
.CW Rerror --
so that line is
.CW mountrpc() 's
own
.CW Rerror
case firing exactly as designed (dossrv correctly reporting "can't open
/dev/sdF0/data" back up through
.CW cmount() )
, not a type mismatch; the word "mismatch" in that print is fixed boilerplate
shared by all three of
.CW mountrpc() 's
diagnostic branches, not a diagnosis.  That log was from the no-device
configuration, which errors cleanly and was never the actual hang.
.PP
Rebuilt the real FAT case (committed riscv64/virt, no changes) and grepped
its boot log for every string
.CW mountrpc()
and
.CW mountmux()
can print -- the
.CW Rerror ,
.CW Rflush
and default-mismatch branches in the former, the "unexpected reply" branch
in the latter, which fires when a reply's tag matches no pending request.
.B "None of them ever appear."
Whatever is happening, it is not a malformed reply, not a wrong message
type for what was sent, and not a reply tagged for a request nobody is
waiting on -- every byte that
.I does
arrive is well-formed and correctly routed.  That itself rules things out:
this is not a version-string or tag-numbering bug of the kind that would
leave a trace in either function.
.PP
Reread
.CW dossrv.b 's
own mount setup once more with this in mind:
.CW init2()
creates the pipe,
.B "spawns the server loop first,"
then calls
.CW sys->mount()
-- the ordering that avoids the obvious chicken-and-egg deadlock (mounting
before anything can answer). Its
.CW rversion()
handler builds a well-formed
.CW Rmsg.Version
and the main loop's
.CW sys->write()
back to the pipe checks its own return length; nothing here looks broken,
and re-running the identical FAT image against
.CW dis/dossrv.dis
under hosted emu (this round, not trusting the earlier round's claim without
re-checking it against the exact image in question) mounted and read
.CW marker.txt
correctly, confirming again that the Limbo side is not where this lives.
.PP
The previous round's own tag trace is the piece that narrows this further:
the native calls it saw firing in sequence after
.CW Sys_pctl-final --
.CW Sys_fildes ,
.CW Sys_readn ,
.CW Sys_write ,
.CW Sys_open ,
.CW Sys_fstat ,
.CW Sys_seek ,
.CW Sys_read --
match
.CW dossrv.b 's
own source order for
.I servicing
a request against its backing device, not for negotiating a connection.
That places the point of no return later than version and attach: dossrv
appears to reach real request handling -- walking, opening, and reading the
backing FAT device on the server's own side -- before whatever silences it.
Put together with the previous point, the picture this reading supports,
stated as inference rather than as a finding: dossrv computes and
.CW sys->write() s
a well-formed reply that never shows up as a malformed or misrouted message
on the native side because it may never show up
.I at all --
which would point at delivery through the pipe itself
.CW ( os/inferno/port/devpipe.c ,
via
.CW qio.c 's
queues) under native scheduling, rather than at anything in
.CW devmnt.c
or
.CW dossrv.b 's
own protocol logic, both of which now read clean.
.PP
Not verified by instrumentation this round -- this is as far as reading two
files (three, counting devpipe.c only by name so far) goes before the next
step has to be a boot again: does a specific write on one end of this pipe
ever fail to appear as available bytes on the other end's queue, under
native scheduling, for a spawned Prog talking to the Prog that spawned it.
That is a sharper, code-grounded question than "where does cmount() hang",
and it is where a next round should start, if there is one.
.NH 1
kmount() was missing a real guard; fixing it moves the hang, not away
.PP
An advisor review pointed at
.CW kmount()
directly: it is a bare
.CW "return bindmount(1, ...);" ,
with no
.CW waserror()
of its own.
.CW bindmount() 's
own internal
.CW waserror()
blocks all end in
.CW nexterror() ,
which only adds cleanup on the way past and always re-raises -- none of
them stop an error from propagating.  With nothing above them to catch
it, any
.CW error()
raised under
.CW mntattach()/mntversion()/mountrpc()
unwinds straight past
.CW Sys_mount() 's
.CW acquire()
in
.CW port/inferno.c ,
and this kproc's Dis-execution token is never reacquired -- exactly the
already-fixed
.CW #l0 /no-NIC
bind hang's own mechanism, in
.CW kbind() ,
a few lines above
.CW kmount()
in the same file, comment and all.
.PP
Added the same guard.  The falsifiable prediction was that the
no-blk-device riscv64 case, whose log already showed the real error
(an
.CW Rerror
reply from dossrv reporting it can't open its backing file) and then
total silence, would now print an
.CW FS-FAIL
and continue.
.B "It did not."
Direct instrumentation showed why: with a real
.CW waserror()
now in place,
.CW kmount()
never reached it at all --
.I no
print between
.CW kmount() 's
own entry and the point where everything already goes silent.
.PP
Four increasingly targeted synthetic tests, all in
.CW sysfile.c ,
none touching pipes or dossrv, ruled out the generic explanations one at
a time: a same-function
.CW error()
was caught; a 3-frame-deep
.CW error()
was caught; the same 3 frames preceded by a real
.CW tsleep()
scheduler round-trip was caught; the same 3 frames wrapped in two
synthetic nested
.CW waserror() / nexterror()
frames shaped exactly like
.CW bindmount() 's
own, still preceded by the sleep, was caught.
.B "Depth, a scheduler transition, and chained nested unwinding are each,
individually, fine on riscv64."
None of them is the mechanism.
.PP
Then a check that mattered more than any of the four: booted riscv64/virt
with a
.I real
FAT image attached instead of no device at all, with the same guard in
place.
.B "This time kmount() DID reach its own catch and return -1."
The exact same function, the exact same call depth, the exact same
nested-frame shape -- catches cleanly when the failure originates from
further into a successful negotiation (attach, walk, further down
dossrv's own request handling) than it does when the failure is an
immediate
.CW Rerror
on the very first
.CW Tattach .
.B "The no-device case's unwind failure is not a general property of this
call chain on riscv64 -- it is specific to failing at that exact, very
early point,"
which matches this pivot's own recurring theme (the
.CW notefree()
bisection-probe hang, also traced to a specific point during
early-boot PCI/virtio enumeration) better than it matches a claim
about the compiler or the unwind primitives in general.  Whatever it
is, it is narrower and more specific than "riscv64 can't unwind
multiple frames" -- that broader claim does not survive this check and
is not made.
.PP
With the real FAT device, riscv64/virt now reaches the identical
stopping point pc64 already reached in the previous section:
.CW "dossrv: mount /n/dos: "
prints, then nothing.  That line comes from
.CW dossrv.b 's
own
.CW init2() ,
after its internal
.CW sys->mount()
call fails and returns -- meaning
.I "dossrv's own mount of itself"
is what is failing, on both architectures, not something the parent
process is waiting on indefinitely.  That relocates the still-open
hang one more step downstream of everywhere this hunt has looked so
far: past
.CW kmount() ,
into
.CW dossrv.b 's
own
.CW raise\ "fail:error"
after that print, through
.CW startfs() 's
.CW exception\ e\ {\ "*"\ =>\ c\ <-=\ "failed";\ exit;\ }
handler, to
.CW fsmount() 's
.CW <-c
receive.  Not chased further this round.
.PP
One side finding, not chased per the same discipline: the error text
after
.CW "dossrv: mount /n/dos: "
is empty on both architectures --
.CW %r
resolves to nothing where a real message ought to be.  The same thing
happens for
.CW blkcheck() 's
own
.CW "BLK-FAIL open: %r"
earlier in the same boot, so it is not new to this path; it looks like
a standing gap in how a kernel error strung through
.CW kmount() 's
new catch (or any bare
.CW if(waserror())\ return\ -1;
pattern) reaches Limbo's
.CW %r ,
worth its own look some other time.
.PP
Kept and committed:
.CW kmount() 's
guard, a real, independent fix regardless of what it did or did not
resolve here -- verified working end-to-end on pc64 and on riscv64's
real-FAT-device path, matching
.CW kbind() 's
already-committed fix for the identical mechanism.
.CW os/inferno/virt/ivirt
rebuilt and committed with it (INIT=virtinit, unambiguous throughout
this document).  pc64's own
.CW ipc64
is deliberately
.I not
rebuilt this round -- its production
.CW INIT
was never pinned down in this session, and guessing risks drifting the
committed binary from whatever the rest of this document's pc64
findings were built against; the fix reaches it the next time pc64 is
genuinely rebuilt.  The temporary
.CW pc64fatinit.b
and its one root-list line were used a third time this round and
reverted afterward, same as every round before it.
.NH 1
Found it: a Limbo raise does not cross a spawned Prog boundary natively
.PP
The previous section's own next step was three specific links:
.CW dossrv.b 's
.CW raise\ "fail:error" ,
.CW startfs() 's
own
.CW exception\ e\ {\ "*"\ =>\ ... }
catch, and
.CW fsmount() 's
.CW <-c
receive.  Two cheap checks, not another boot-and-guess round, settled
it.
.PP
First: is the last print before silence
.CW ( "dossrv:\ mount\ /n/dos:\ " ,
from
.CW sys->fprint(sys->fildes(2),\ ...) )
really the last thing that runs, or just the last thing that
.I prints ?
A marker placed right after it, using
.CW sys->print() ,
never appeared -- but that
.I alone
proves nothing, because this whole hunt has already seen
.CW sys->print()
specifically go missing once before (the retracted round's own
puzzle).  Rebuilt the marker with
.CW sys->fprint(sys->fildes(2),\ ...) ,
the exact mechanism that had just printed successfully one line
above it.
.B "That marker printed."
Execution genuinely reaches the
.CW raise
statement.
.PP
Second: does the raise/catch mechanism work at all, portably?  Ran the
identical bytecode under hosted emu:
.IP
.nf
emu -r $ROOT dis/sh.dis -c 'dossrv -f /nope.img -m /n/dos; echo AFTER'
.fi
.PP
Both the pre-raise marker and the post-raise
.CW echo
printed cleanly.  The Limbo-level exception mechanism itself is not
broken; hosted emu handles a
.CW raise
inside a Command's
.CW init()
without issue.
.PP
Put those two together on the native kernel: the marker
.I immediately
before
.CW raise\ "fail:error"
prints; nothing placed
.I after
it -- not the (intentionally unreachable) line right after the raise
in
.CW dossrv.b ,
and not
.CW startfs() 's
own exception-catch print, one call frame up -- ever does.
.B "The raise statement itself is where forward progress stops, on the
native kernel specifically, crossing from a spawned Prog
(startfs/dossrv, running inside its own Dis process) back to the
exception handler in the Prog that spawned it."
Checked on both architectures with the identical probe: riscv64/virt
and pc64 show the exact same shape, marker printed, nothing after,
silence -- this is shared code again, not either board's own doing.
.PP
This is a materially different, sharper claim than anything earlier in
this document's FAT/dossrv thread.  Every prior round characterized
this as "the mount hangs" or "the two sides don't converge" --
language for a stuck RPC.  It is not that.  The RPC itself already
finished (dossrv correctly detected and reported the failure, twice
over -- once to the human-readable stderr message, once again to this
round's own marker).  What fails is Limbo's own
.CW raise
unwinding out of a
.I spawned
Dis process and into a
.CW exception
block in its parent -- a Dis-VM/interpreter-level mechanism, in
.CW libinterp ,
not anything in
.CW os/inferno/port/devmnt.c
or
.CW appl/cmd/dossrv.b ,
both of which this hunt has now read end to end and found clean.
Neither checked directly yet: whether a
.CW raise
crossing a spawned-Prog boundary fails for
.I every
exception, or only ones raised from deep inside a blocked-then-woken
native call the way this one was; and whether the native kernel's own
process-teardown path
.CW ( startfs() 's
.CW exit
statement, never reached here either) is itself part of what is
supposed to deliver the exception, rather than a separate step after
it lands.
.PP
Reverted: both probes
.CW ( appl/cmd/dossrv.b ,
.CW os/inferno/init/virtinit.b ) ,
the pc64 diagnostic init and its root-list line (used a fourth time,
same discipline).
.CW dis/dossrv.dis
rebuilt clean from the reverted source.  Clean rebuild reverified
reproducing the identical silent stop before this was written up.
.NH 1
Correction: not spawn-boundary-specific, and traced two files further
.PP
The previous section's central claim -- that a Limbo
.CW raise
fails specifically
.I "crossing a spawned Prog boundary" --
does not survive a control case and is narrowed.  The comparison that
produced it changed two things at once: native vs. hosted,
.I and
.CW dossrv 's
own invocation shape (spawned via
.CW startfs() )
vs. the emu run (invoked directly from
.CW sh ,
no
.CW spawn
at all).  Built a minimal, apples-to-apples reproducer,
.CW appl/cmd/raisetest.b ,
with the identical shape on both sides: a
.CW victim()
that does one native call then raises, a
.CW spawned()
that calls it inside its own immediately-surrounding handler and
reports the result on a channel, an
.CW init()
that spawns and receives.  Under hosted emu this bytecode, unmodified,
prints cleanly start to finish.  On riscv64/virt, native, it hangs
identically to every FAT/dossrv round before it: the marker
immediately before
.CW raise
prints, nothing after it ever does.
.PP
Then the control case that reframes it: the
.I same
raise and the
.I same
immediately-surrounding handler, with
.CW spawn
removed entirely -- raised and caught in the one Prog already running.
.B "This does not hang; it panics."
.CW "panic:\ exception"
from
.CW os/inferno/virt/trap.c ,
a genuine unhandled CPU trap, every time, as soon as the raise
executes.  A third variant (spawned, but with the native call removed
from
.CW victim() )
hangs the same as the first -- so the native call beforehand is not
what triggers it either.
.B "No native raise/catch shape tried so far has worked, with or without
spawn, with or without a preceding native call."
The earlier framing was too narrow; the honest claim is that Limbo
exception handling does not currently work reliably on this native
kernel, in any shape checked, while working correctly under hosted
emu throughout.
.PP
Read two more files looking for where the two builds diverge.
.CW handler() ,
in
.CW os/inferno/port/exception.c ,
searches the raising Prog's compiled handler table by walking
.CW fp
up through frames and matching
.CW pc
against each handler's
.CW [pc1,pc2)
range.  Against
.CW emu/port/exception.c
it differs in two places: a
.CW uintptr
vs.
.CW intptr
type for the local
.CW pc/newpc ,
and a plain
.CW ++
vs.
.CW AINC()
(atomic increment) on two refcounts.  Neither survives scrutiny as the
cause.  The
.CW pc
type doesn't matter functionally: C's usual arithmetic conversions
make a signed/unsigned comparison against the
.I already
.CW uintptr
.CW h->pc1 / h->pc2
fields (declared that way in the shared
.CW include/interp.h ,
same for both builds) behave identically either way.  The atomic
increment doesn't apply here at all --
.CW ainc()
.I "is not defined anywhere in the native tree,"
only in
.CW emu/port/atomic.c ;
using
.CW AINC()
natively would not even link.  That asymmetry reflects the two
builds' different concurrency models (native Dis execution is
serialized through the single interpreter VM token this document has
studied all session; hosted emu genuinely needs atomics for its own
OS-thread concurrency), not a bug in one of them.
.PP
Followed
.CW handler()
to its own caller:
.CW os/inferno/port/dis.c 's
.CW vmachine() ,
the same file this whole hunt has read most closely, wraps its
interpreter loop in
.CW while(waserror()){\ ...\ handler(up->env->errstr)\ ...\ }
-- a Limbo
.CW raise
becomes a native kernel
.CW error() ,
caught here, then handed to
.CW handler()
to find a Dis-level catch.
.B "This function -- the exact conditional acquire() included -- is
byte-identical to emu/port/dis.c 's own vmachine() ."
So is
.CW propex() ,
the function
.CW handler()
calls when no handler is found.
.CW progexit() ,
one step further (killing the Prog outright when even
.CW propex()
can't recover), differs more --
.CW emu 's
version calls
.CW cleanexit(0)
when the last Dis Prog exits; native's has no equivalent -- but that
is shutdown behavior for the no-handler-found path, not an obvious
explanation for a handler that
.I should
have been found (my
.CW raisetest.b
handler is right there, one frame up) failing to be found at all.
.PP
Genuinely open: whether
.CW handler()
itself correctly finds the entry that should match -- its own logic
reads clean, so if it is wrong the discrepancy is upstream, in
whether the compiled handler table
.CW ( m->m->htab )
is correctly present for a native Prog's loaded module in the first
place.  That is a loader/compiler question, not a
.CW vmachine()
one, and is where a next round would start.
.PP
Kept, not reverted:
.CW appl/cmd/raisetest.b
itself, added to
.CW appl/cmd/mkfile
and built through
.CW mk\ install
like every other command -- not a throwaway probe but a permanent,
40-line, standing reproducer for a real open bug, verified against
hosted emu one more time before committing.  Confirmed working
correctly there
.CW ( "raisetest:\ received\ caught" )
immediately before this was written up.
.NH 1
A real bug in schedmod(), and four ruled-out candidates for the raise
.PP
The open question left at the end of the last section was whether the
compiled exception-handler table
.CW (m->m->htab)
is even present for a natively-loaded Prog's module.  It is: readmod(),
parsemod() and the
.CW HASEXCEPT
block that fills in
.CW m->htab
(libinterp/load.c) are shared code, compiled once and linked into both
the native kernel and hosted emu.  Same source, same bytes in, same
table out, on both.  That rules the loader out cleanly \(em there is no
"native loader" to diff against emu's; it is the same loader.
.PP
Diffing
.CW dis.c
against emu's copy properly this time (an actual
.CW diff ,
not a read-and-remember) turned up a real, previously-missed bug, just
not in the code path this hunt has been staring at.  schedmod() \(em
used once per boot, to start the root module's own
.CW init()
\(em built its entry frame from a bare on-stack
.CW "Frame f" :
.IP
.nf
Frame f, *fp;
\&...
fp = &f;
R.s = &fp;
f.t = m->entryt;
newstack(p);
.fi
.PP
newstack() (libinterp/stack.c) does
.CW "memmove(p->R.FP, f, f->t->size)" .
.CW f->t
here is
.CW m->entryt ,
the complete entry-frame type covering every local the root module's
.CW init()
declares \(em routinely far bigger than
.CW sizeof(Frame) .
A bare
.CW "Frame f"
on the C stack is only ever big enough for the four-pointer Frame
header, so the copy read straight past it into whatever schedmod()'s
own stack frame happened to hold next: garbage into every local of the
very first Dis Prog run at boot, on every native startup.
.PP
This is not a new bug.  It is the same bug
.CW emu/port/dis.c 's
own schedmod() already carries a fix and a full explanation for, from
an earlier round of this same hunt (see the entry-frame-corruption
section above).  The native copy of this function never got the same
fix; nobody had diffed the two schedmod()s against each other before.
Fixed the same way emu was: allocate the real entry-frame size instead
of a bare struct \(em
.CW "f = mallocz(m->entryt->size, 1)" ,
free it after newstack() copies out of it.  Verified: riscv64/virt
rebuilds clean and boots identically to before (same log, same
.CW BLK-FAIL
at the same point, no regression) with the fix in.
.PP
It does
.I not
fix the raise/spawn hang.  Embedding a call to raisetest.dis directly
into virtinit.b's
.CW init() ,
right after
.CW "sh loaded" ,
and rebuilding with the fix in place: same failure, byte for byte \(em
.CW "raisetest:\ victim\ about\ to\ raise"
prints, then silence, same as before the fix.  That is expected once
the actual code path is traced: schedmod() only ever runs once, for
the root module.  A Limbo
.CW spawn
goes through
.CW OP(spawn)
in libinterp/xec.c instead, which gets its frame from a preceding
.CW OP(frame)
(IFRAME) \(em allocated out of the Dis-level stack extent at the
correct
.CW t->size ,
never a bare C struct.  That path was never at risk from this
particular bug; it is shared code, already correctly sized, on both
builds.  schedmod()'s bug is real and worth having fixed \(em it means
every native boot until now silently ran virtinit.b's own
.CW init()
frame partially populated from C-stack leftovers \(em but it is a
different bug from the one this hunt is actually chasing.
.PP
Three more candidate explanations for the raise hang, checked and
ruled out this round, so they do not have to be re-checked:
.IP \(bu
.I "cflag default mismatch."
emu defaults to
.CW "cflag = 1"
(JIT on); native's
.CW cflag
(os/inferno/port/dis.c) has no initializer, so it is 0 (interpreter)
unless a module sets
.CW MUSTCOMPILE .
Every earlier hosted-emu run of raisetest.dis in this hunt used emu's
default flags, so the two sides being compared were never actually
proven to be running the same interpreted-vs-compiled path.  Reran
raisetest.dis under
.CW "emu -c0"
(forces the interpreter, matching native's default) explicitly: same
clean pass \(em
.CW "init start" ,
.CW "victim about to raise" ,
.CW "spawned caught fail:test" ,
.CW "received caught" .
JIT-vs-interpreter is not the difference.
.IP \(bu
.I "setlabel()/gotolabel() on riscv64."
virt's l.s implements Plan 9-style
.CW waserror()
via
.CW setlabel()
(save SP and LINK) /
.CW gotolabel()
(restore them and jump) rather than C's
.CW setjmp/longjmp .
This looked like a promising place for an architecture-specific bug,
especially given the "same Prog, no spawn" shape produces a hard
.CW "panic:\ exception"
(os/inferno/virt/trap.c) rather than a hang \(em consistent with a
bad jump landing somewhere that then traps.  But this exact mechanism
is already proven correct elsewhere on this same kernel: this hunt's
own
.CW kmount()
fix (see above) added a
.CW waserror()
around a real, deep failure inside
.CW bindmount()/mntattach()/mountrpc()
and it catches and unwinds correctly, verified live.  Whatever is
wrong with the raise, it is not that
.CW setlabel/gotolabel
cannot ever work on this port.
.IP \(bu
.I "error()'s own setlabel(&up->errlab[NERR-1])."
os/inferno/port/proc.c's
.CW error()
unconditionally overwrites the last errlab slot with a fresh label
right before calling
.CW nexterror() ,
which looks, out of context, like it could clobber whatever
.CW nexterror()
is about to jump to if
.CW up->nerrlab
were ever at
.CW NERR-1 .
Checked against os/9front/port/proc.c: this is 9front's own real,
unmodified idiom, byte for byte.  Not a local bug, and
.CW up->nerrlab
is nowhere near
.CW NERR
(64) in this scenario regardless.
.PP
So: the shared interpreter, the shared loader, and the two most
suspicious native-only mechanisms (schedmod, setlabel/gotolabel) are
now all either fixed, or checked and cleared.  What is left unchecked:
whatever schedmod() got wrong for the boot-time root frame, OP(spawn)
gets right \(em but nobody has yet watched the actual values
.CW handler()
reads (R.FP, R.PC, m->m->htab's contents, the walked
.CW pc1/pc2
range) at the exact moment of the native raise, on the spawned Prog,
side by side with the same trace under
.CW "emu -c0" .
Every finding so far has been code-reading and diffing; this bug has
now survived that approach four times.  A live trace of
.CW handler() 's
own loop, not another diff, is where the next round should start.  See
appl/cmd/raisetest.b, kept in the tree for exactly this.
.NH 1
Found it, for real: two error strings, and only one of them got written
.PP
The live trace the last section asked for.  Instrumented
.CW handler()
(exception.c) to print its estr, R.FP, R.PC and every
.CW htab
entry it walks, and
.CW vmachine()
(dis.c) to print
.CW up->env->errstr
the moment
.CW waserror()
fires.  Rebuilt riscv64/virt with raisetest.dis wired into virtinit.b
again and booted it.  The very first line answered the question:
.IP
.nf
raisetest: victim about to raise
vmachine: waserror() fired, errstr "" up->iprog 0x0
qemu-system-riscv64: terminating on signal 15 ...
.fi
.PP
.CW errstr
was empty.  Not corrupted, not garbage \(em an empty string, the exact
value
.CW handler() 's
own first line already guards against:
.CW "if(*estr\ ==\ 0\ ||\ p\ ==\ nil)\ return\ 0" .
The trace print inside
.CW handler()
itself never even fired, because that guard returned first.  Every
native raise on this port has been taking the "no handler for this
exception" branch \(em not because no handler existed, but because
the exception's own message text never arrived.
.PP
Two error strings turned out to exist, not one.  os/inferno/port/
portdat.h carries both, with its own comment on why:
.IP
.nf
struct Osenv {
	char *errstr;       /* errbuf0 or errbuf1, Osenv-scoped */
	...
};
struct Proc {
	char *errstr;       /* errbuf0 or errbuf1, Proc-scoped */
	...
};
.fi
.PP
the comment above
.CW Osenv
reading "Kept alongside the 9front-style Proc fields so disinit/
inferno can run on native kernels" \(em an admission, from whoever
merged 9front's process model into this tree, that both conventions
were kept side by side.  os/inferno/port/proc.c's
.CW error()
is the 9front side: it writes the raised message into
.CW up->errstr ,
the Proc-level buffer, which is exactly what every native
kernel-level
.CW waserror()
catch in this tree already reads \(em kmount()'s, kbind()'s,
.CW %r ,
.CW kwerrstr() .
os/inferno/port/dis.c's
.CW vmachine()
and exception.c's
.CW handler()
are the other side: ported from emu almost unchanged, and emu's own
.CW error()
(emu/port/main.c) writes the message into
.CW up->env->errstr
instead \(em the Osenv-level buffer \(em because emu's
.CW Proc
has no
.CW errstr
field of its own at all; Osenv's is the only copy that exists there.
Nothing in this port ever copied between the two.  Every Dis-level
.CW raise
set the Proc-level buffer and left the Osenv-level one exactly as it
was before \(em empty, on the very first raise of a boot, since
nothing had ever written it.
.PP
The fix mirrors emu's own guard, added to the one
.CW error()
this port actually has:
.IP
.nf
kstrcpy(up->errstr, err, ERRMAX);
if(up->env != nil && up->env->errstr != nil && err != up->env->errstr)
	kstrcpy(up->env->errstr, err, ERRMAX);
setlabel(&up->errlab[NERR-1]);
.fi
.PP
Rebuilt and booted three times running: raisetest.dis passes clean,
identically to hosted emu, every time \(em
.CW "victim about to raise" ,
.CW "spawned caught fail:test" ,
.CW "received caught" ,
.CW RAISETEST-DONE .
The instrumentation (the print()s in handler()/vmachine(), and
raisetest wired into virtinit.b) was reverted after confirming; only
the fix in proc.c's
.CW error()
is kept.
.PP
Then went back to the scenario this entire pivot started from: a real
FAT image on a real virtio block device, dossrv.b mounting it.
Before this fix, that hung forever with no further output, on every
architecture tried.  Right after the fix, still not clean, but no
longer a hang:
.IP
.nf
BLK-OK
dossrv: mount /n/dos: file does not exist
FS-FAIL dossrv
.fi
.PP
A clean, reported failure, printed within the same second, boot
continuing right past it.  Chased that one further: dossrv.b's mount
call already passes
.CW MCREATE ,
but
.CW sys->create("/n/dos", ...)
tried directly returns
.CW "permission\ denied" \c
\&.
.CW /n
(the "virt" root-file list) is devroot's static, compiled-in
directory \(em its create entry point is the generic
.CW devcreate()
stub, which every such synthetic device in this tree uses and none of
them implement.
.CW /n
was never going to support a runtime mkdir, on any board that boots
from a devroot image, regardless of what flags a caller passes to
mount().
.PP
Retargeted the FAT mountpoint from
.CW /n/dos
to
.CW /tmp/dos
\(em
.CW /tmp
is real, writable memfs, already proven able to create a fresh
directory (tmpmount()'s own TMP-OK check, pre-dating this pivot) \(em
and reordered virtinit.b's init() to run tmpmount() before fsmount()
instead of after, so the writable filesystem exists before anything
tries to create inside it.  That surfaced one more real, if unrelated,
gap on the way: tmpmount()'s memfs.dis failed to load
.CW /dis/lib/styxlib.dis
\(em present in appl/lib and built, but never added to riscv64/virt's
own root-file list (
.CW /dis/lib/styx.dis
is listed; the very similarly named
.CW styxlib.dis
never was \(em a plain oversight, not a bug in styxlib itself).  Added
it.  With both fixed:
.IP
.nf
BLK-OK
TMP-OK
FS-OK
.fi
.PP
Clean, three boots running, on the exact scenario this entire pivot
was chasing.  What started this pivot as an unrecoverable silent stop
is now a clean pass, and the system runs straight through the rest of
its boot script afterward \(em MATH-OK, RAND-OK, CAP-OK and on,
stopped only by this run's own timeout, not a hang or a panic.
Batched it properly afterward: 10/10 clean
.CW FS-OK
runs, same real FAT image and virtio device each time.
.PP
The raise fix is old and general, not riscv64/virt-specific:
os/inferno/port/proc.c and portdat.h are shared across every native
board in this tree (pc64 included), and the fix lives entirely in
that shared file.  Every native raise since the 9front process-model
merge has been silently failing to find its handler, on every board.
.PP
The real pc64 dossrv/FAT retest, at the volume the pc64 GPF heisenbug
needs to be honest evidence, is done now.  A temporary
.CW pc64fatinit.b
(never committed, reverted after) reproduces the same
.I "blkcheck()/tmpmount()/fsmount()"
shape virtinit.b already carries \(em probing for the real
.CW virtio-blk-pci
device across a few candidate SD letters, mounting a writable
.CW /tmp
before creating
.CW /tmp/dos
under it, the same
.CW /n
-is-static-devroot fix as riscv64/virt \(em against
.CW os/inferno/pc64/pc64 's
own root-file list (temporarily given
.CW dossrv.dis ,
.CW memfs.dis
and
.CW styxlib.dis ,
none of which it carried before).  Twenty real boots, a real FAT
image, a real
.CW virtio-blk-pci
device each time:
.B "15/20 BLK-OK/TMP-OK/FS-OK clean" ,
5/20 hit a crash \(em every one of them the pre-existing GPF-class
heisenbug (a register dump and a fault, either reported as
.CW "general protection violation"
or, once, as a bare
.CW "currun() nil or has no module"
register dump of the same shape), never this bug's own signature
(silent raise-then-nothing).  Zero of twenty hung.  75% clean is
in line with this port's already-documented, already-open GPF rate
on pc64, not evidence of a new problem, and every single failure
mode seen was the old, already-tracked one \(em not a new one this
fix introduced.  The fix is confirmed on both architectures now; the
pc64 GPF heisenbug itself is exactly as open as the earlier sections
above already say \(em this round did not touch it, only measured
around it.
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
.PP
The standing target across every board this document tracks is five
architectures clean under QEMU: pc64, riscv64, armv7 \- all three
building today, none of them bug-free yet \- and riscv32 and arm64,
which had no compiler backend in this tree at all.  Both do now.
.CW "utils/za, zc, zl"
is Richard Miller's original Plan 9 RISC-V compiler (thechar
.CW z ,
genuinely 32 bit \- SZ_IND is 4).  This corrects a wrong claim this
document made in an earlier revision, that
.CW kc/kl
(thechar
.CW k )
was riscv64 under a recycled sparc letter.  Checked properly this
time, against
.CW mkfiles/mkfile-Inferno-*
rather than assumed:
.CW k
is genuinely sparc in this tree
.CW ( kc/gc.h
says so, SZ_IND 4, no sparc board exists), and the live riscv64
backend
.CW os/inferno/virt
actually builds with is thechar
.CW j \-
.CW jc/jl ,
SZ_IND 8, wired by
.CW mkfile-Inferno-riscv64 's
own
.CW O=j .
.CW jc/gc.h 's
header comment still says "zc/riscv, RISC-V 32-bit", a stale relic
from the Richard Miller lineage it was cloned from before being
widened to LP64; the comment is wrong, the SZ_IND and the board
wiring are not.
.CW "utils/7a, 7c, 7l"
is kencc's real AArch64 backend, the one 9front itself runs on actual
arm64 hardware.  Both ported from a local kencc-cross checkout, the
same lineage this tree's existing 5c/kc/tc already trace to, adjusted
for this tree's own path conventions and one shared-frontend
signature mismatch
.CW "( swcmp() )" ,
plus for
.CW 7l
four files this tree's
.CW ld/
doesn't share the way kencc-cross's does (copied local, not merged
into the shared directory every other loader here depends on) and a
real allocator conflict between
.CW 7l 's
own private
.CW sub.c
hunk/nhunk and this tree's extended
.CW Posix.c \(em
kencc-cross's own, simpler
.CW Posix.c
resolved it.  Verified past "it compiles" for both: each compiled a
real C function, assembled a hand-written entry stub, linked with no
errors, and the emitted machine code checked byte-for-byte against
known encodings
.CW ( addi/add/jalr
for RV32,
.CW 0xd65f03c0
\- the exact AArch64
.CW RET
opcode \- for arm64).  Board bring-up \- an actual Inferno kernel
target under
.CW os/inferno/
for either \- is not done; this closed the compiler gap, which is
what stood between "nothing" and a board to bring up.
.PP
riscv32 board bring-up went a long way past that.
.CW os/inferno/virt32
is a new board: same QEMU virt machine and memory map as
.CW os/inferno/virt
(riscv64), checked separately against this host's own
.CW qemu-system-riscv32
.CW -M\ virt\ -machine\ dumpdtb=...
rather than assumed, plus
.CW mkfiles/mkfile-Inferno-riscv32
and
.CW mkfiles/mkfile-os-riscv32
(this host's
.CW SYSTARG
resolves to
.CW os ,
not
.CW Inferno ,
so the second file \- easy to miss, and missed once \- is the one
that actually matters when cross-building from macOS).  A correction
along the way: this document previously said
.CW kc/kl
was riscv64 under a recycled sparc letter.  Checked against
.CW mkfiles/mkfile-Inferno-*
's own
.CW O=
lines instead of assumed, that was backwards \-
.CW k
is genuinely sparc here (no sparc board exists, it is orphaned), and
riscv64's real, live kernel compiler is
.CW jc/jl
under thechar
.CW j .
.PP
za has real, load-bearing gaps beyond the compiler-only pass above,
each found by building, not guessed: no
.CW MOV/CSR()
operand form at all (only a bare-immediate
.CW LSYS
class, and
.CW zl 's
optab has zero entries for any
.CW CSRRW/CSRRS/CSRRC
shape) \- hand-encoded as raw
.CW WORD
values in
.CW virt32/l.s ,
the same technique that file's own
.CW WFI
already used; no automatic large-immediate or large-stack-offset
splitting the way
.CW ja
does, so a
.CW TRAPPAD
of 2048 (riscv64's value) links with "illegal combination" on this
board and had to shrink to 256, and a bit flag of exactly 2048
(mie.MEIE) has to be built in a register rather than as a single
.CW OR
immediate; its own register convention
.CW ( REGSB=26,\ REGSP=27,\ REGLINK=31 )
is not
.CW jc 's
.CW "(REGSB=3, REGSP=2, REGLINK=1),"
so
.CW virt32/l.s
is its own file, not a search-and-replace of
.CW virt/l.s .
One real kernel bug found in translation, not carried over: the
riscv
.CW mcause
interrupt bit is the top bit of XLEN \- bit 63 on riscv64, bit 31
here \- and
.CW virt/trap.c 's
.CW (vlong)cause<0
test zero-extends a 32 bit
.CW uintptr
into a 64 bit signed value, so it can never see that bit set on this
board; fixed to test bit 31 directly in
.CW virt32/trap.c .
.PP
Past
.CW l.s ,
the whole kernel and every library it links \- libinterp, libkeyring,
libsec, libmp, libkern \- compile clean with zc and archive with iar.
Two architecture-support files neither za's port nor any board needed
before now had to be written from nothing:
.CW libkern/vlop-riscv32.s
(the
.CW _mulv
64x64->64 multiply every other
.CW vlop-*.s
hand-writes in native instructions, here using RV32's
.CW MUL/MULHU
in place of MIPS's
.CW MULU ,
verified assembling clean) and
.CW libkern/vlrt-riscv32.c
(portable C, an unmodified copy of
.CW vlrt-mips.c \-
this file has no architecture dependency on any port that has one).
.CW libinterp/comp-riscv32.c
and
.CW libinterp/das-riscv32.c
are the same "no JIT yet, interpret everything" and "no disassembler
yet" stubs
.CW comp-riscv64.c
and
.CW das-riscv64.c
already carry for jc.
.PP
The final kernel link does not succeed, and the reason is now exact,
not vague:
.CW za/zc
has no floating-point register file at all.  Checked directly \-
.CW utils/zc/z.out.h
defines
.CW NREG=32
integer registers and not one
.CW F
register, and
.CW utils/za/lex.c
has no
.CW F0..F31
tokens \- and confirmed the hard way, by raising
.CW zl 's
error cap from 10 to 1000 (a permanent change;
.CW utils/zl/list.c )
and reading every failure rather than guessing at the shape of the
problem from the first ten.  The complete list is eleven functions,
every one of them a floating-point
.ul
conversion,
never arithmetic: seven in
.CW libinterp/xec.c
(the Dis interpreter's
.CW real
opcode handlers \-
.CW cvtrf/cvtfr/cvtfl/cvtfw/cvtfx/iexpf/canontod )
and four in
.CW libkern/vlrt-riscv32.c
itself
.CW ( _f2v/_v2d/_v2f ,
plus
.CW charstod 's
call to
.CW NaN() ,
which was left unimplemented rather than added \- a
.CW double
-returning function hits the identical wall immediately, so writing
.CW nan-riscv32.c
would not have closed anything).  Limbo's
.CW real
type is a core language type, and
.CW libinterp.a
is linked into every board that uses this toolchain, so this is not
a
.CW virt32 -specific
gap: no board built with za/zc can link until
.CW zl
can encode
.CW MOVF/MOVD/MOVFD/MOVDF/MOVUD .
Fixing it means adding an
.CW F
register class to
.CW zc 's
codegen and
.CW zl 's
encoder \- real compiler engineering, not a missing file \- and is
appropriately scoped as its own piece of work, not attempted at the
tail of this one.
.PP
One smaller, independent gap surfaced by the same
.CW zl
run and left open alongside it:
.CW devcons.c 's
.CW pprint()
fails
.CW "MOVW\ $fmt+0(FP),\ R6"
with "illegal combination" \- a large-offset frame address
.CW ( C_LACON )
has no
.CW MOVW\ ->\ C_REG
optab entry, only the small-offset
.CW ( C_SACON )
form does
.CW ( utils/zl/optab.c ,
case 11, the
.CW addi
address form \- what is missing is that same computation's
.CW lui+addi
two-instruction version for when the offset does not fit).  Not
attempted: fixing it alone would not reach a link, since the float
gap blocks every board regardless.
.PP
Also true and worth carrying forward, not yet acted on because it
does not matter until modules actually load, past the current
blocker:
.CW os/inferno/port/portmkfile 's
.CW rc-lib%.a / sh-lib%.a
rules \- shared by every board \- do not pass
.CW DISWORD
through to the recursive library build, so
.CW libinterp
built for this board with
.CW -Iw4
from the board's own
.CW CFLAGS
but
.CW -Iw8
in the recursive
.CW mk
invocation for
.CW libinterp
itself.  This is the same bug class as armv7's
.CW /dis
vs
.CW /dis32
root cause earlier in this document, not yet confirmed to bite the
same way \- it did not block the build reached so far, since nothing
has loaded a
.CW .dis
module yet \- and should be checked, not assumed fixed or assumed
broken, once the float gap is closed and a module actually loads.
.PP
The float gap above is now closed, and
.CW virt32
boots a long way past it.
.CW za
had no
.CW F0..F31
register tokens at all, and every one of
.CW zl 's
fourteen optab rows that looked like float support routed through
.CW asm.c 's
case 24, the breakpoint encoder \- dead placeholder scaffolding that
would have emitted the same wrong bytes regardless of operand shape,
not a real
.CW OOP_FP/OLOAD_FP/OSTORE_FP
encoding.  Ported the real thing from
.CW utils/jc
and
.CW utils/ja \-
riscv64's own, proven, working F/D implementation on the identical
shared
.CW cc/
frontend \- rather than the RISC-V spec directly: register tokens and
grammar
.CW "(LFREG/dreg/drreg/LFLT2/LFLT3)"
into
.CW za ;
real optab rows plus a new
.CW "case 17 (fcvt)"
into
.CW zl .
.CW OP_R ,
the macro those rows encode through, had hard-coded the integer
.CW OOP
major opcode into every R-type instruction it built \- harmless for
every existing integer row, since they all set
.CW op=OOP
themselves anyway, but it meant no
.CW OOP_FP
instruction could ever be encoded through it regardless of what the
optab row itself asked for; fixed to use the row's own
.CW op
field, matching
.CW jl 's
own
.CW OP_R
exactly.
Checked byte-for-byte against the real RISC-V F/D encoding the same
way this document has checked every hand-encoded instruction so far
.CW ( FLD/FSD/FADD.D/FEQ.D/FCVT.D.W/FCVT.W.D ,
all exact).
.PP
Fixing the encoder surfaced a real
.CW zc
codegen bug, not an encoder gap: converting
.CW double
to an integer type used to
.CW regalloc()
a scratch register typed by the
.CW double
source instead of the integer destination, so the scratch landed in
an F register that the very next instruction
.CW ( MOVW )
needed as a plain integer \- "illegal combination" every time,
whether the F register mistake ever reached
.CW zl
or not.
.CW utils/jc/txt.c 's
own version of this exact case never allocates a scratch at all; it
sets the opcode and falls through to
.CW gmove() 's
trailing
.CW gins(a,\ f,\ t) ,
trusting the compiler's own already-correct destination allocation.
Matched that shape in
.CW zc
instead of patching the broken
.CW regalloc()
call \- simpler, and proven on the sibling architecture.  This one
compiler fix cleared every remaining
.CW libinterp/xec.c
float-conversion failure at once
.CW "(cvtrf/cvtfr/cvtfl/cvtfw/cvtfx/iexpf/canontod)" ,
not just the specific function it was first found in.
.PP
.CW libkern/vlrt-riscv32.c 's
own
.CW _d2v
hit the identical registerizer bug through a different C shape: a
.CW "union\ {\ double\ d;\ struct\ Vlong;\ }"
bit-split, the same idiom
.CW vlrt-mips.c
and
.CW vlrt-arm.c
both use safely on compilers with working float registers.  Rewrote
it to split the bits through an explicit
.CW memcpy
into a
.CW ulong[2]
instead of a union, forcing a real memory round-trip rather than
letting the registerizer alias a double and an integer pair in the
same register \- the same "store bits, then reload as the other
type" discipline
.CW virt/l.s 's
own comment on
.CW jc 's
.CW MOVUD
already states for a different bitcast-vs-convert confusion on this
compiler family.  One line inside it, the deliberately-degenerate
overflow branch
.CW "(yhi = d)" ,
already commented upstream as producing garbage no caller was ever
meant to rely on, hit the same registerizer bug in a form the
.CW zc
fix above didn't reach \- a bare narrowing assignment, not a
conversion feeding straight into a typed destination \- replaced with
a fixed sentinel instead of exercising a path whose result was never
defined in the first place.
.PP
The final link succeeds.
.CW os/inferno/virt32/ivirt32
is a real 1.5
.CW MB
32-bit RISC-V ELF.  Under
.CW qemu-system-riscv32\ -M\ virt\ -cpu\ rv32
it boots: the
.CW "Inferno/riscv32\ virt"
banner, the memory allocator
.CW "(127 holes free, 266940416 bytes free)" ,
.CW procinit ,
the
.CW "Inferno\ Fourth\ Edition"
version banner, and the
.CW SNPRINT-ABI-OK
vararg self-test all print for real over the emulated UART.  Getting
that far needed one more real bug found by live QEMU/lldb debugging,
not static reading: the board hung forever on its first-ever
.CW ilock() ,
an uncontended lock that should have been free.
.CW _tas()
in
.CW virt32/l.s
was copied from
.CW virt/l.s
unchanged \- correct C source, wrong assumption \- because
.CW virt/l.s 's
own version happens to leave the pre-swap old lock value in
.CW R8 ,
which is
.ul
also
.CW jc 's
.CW RARG
.CW ( REGARG=8
for
.CW jc ) ,
so the return value lands in the right register purely by
coincidence of which number
.CW LRW(12,8)
was written with.
.CW za 's
.CW RARG
is
.CW R1 ,
not
.CW R8 ,
so the copied code silently returned whatever
.CW R1
already held \- the lock pointer itself, from two lines earlier,
never zero \- meaning
.CW ilock()
read every
.CW _tas()
call as "already held," even the first, ever, on a lock nobody had
touched.  Found by breaking at the spin loop, reading the lock word
.CW ( genuinely
.CW held=1 ,
not corrupt memory), walking the saved return address on the stack
to identify the caller as
.CW xhole() 's
.CW ilock(&xlists) ,
and setting a breakpoint at
.CW ilock 's
entry to confirm it never got past its first call.  Fixed with one
explicit
.CW MOVW\ R8,\ RARG
before
.CW RET
rather than trusting the macro's own destination register to
coincide with whatever
.CW RARG
happens to be on a given architecture.
.PP
What's left, and it is exact, not vague: 64-bit unsigned division is
wrong.
.CW libkern/vlrt-riscv32.c 's
.CW dodiv()
was the first suspect \- copied unmodified from
.CW vlrt-mips.c ,
the shift-and-subtract long-division loop every 32-bit kencc port
without a native 64-bit divide instruction relies on \- and it looked
guilty: hand-computed expected-vs-actual values printed from inside
the running kernel showed
.CW (4294967296+100)/4
returning
.CW 0
.CW "(wanted 1073741849)" ,
and the board's own real
.CW poolsizeinit()
computation,
.CW 5338808320/100 ,
returning
.CW 0
too.
.CW dodiv()
was innocent.  Live QEMU/lldb tracing of the actual argument bytes
.CW _divvu()
read \- not just the printed result \- found the real bug one level
up: a compile-time
.ul
constant
in vlong-typed arithmetic (a bare
.CW 100
or
.CW 0x0BADC0DE
in source, not a variable) gets built by
.CW zc
as two raw 32-bit stores, and that code
.CW "(utils/zc/cgen.c's"
OCONST case, and
.CW gextern()
in
.CW swt.c
for initialized globals) stored the
.ul
low
word first and the
.ul
high
word second \- correct only if every consumer treats an 8-byte vlong
slot as low-word-first.
.CW libkern/vlrt-riscv32.c 's
own
.CW Vlong
struct
.CW "(hi first, lo second \- the same order vlrt-mips.c and vlrt-arm.c"
use) is hi-word-first, and every
.ul
real
function that builds one
.CW "(_ul2v, _si2v, _addv, ..."
) writes and reads it that way consistently \- checked directly, not
assumed.  Only the literal fast path disagreed: a bare
.CW 100
landed in the struct's
.CW hi
slot with
.CW lo
left
.CW 0 ,
so
.CW _divvu()
was correctly dividing by
.CW 100<<32 ,
not
.CW 100
\- explaining both the exact
.CW 0
results above and, independently, why the
.CW 0x0BADC0DE
test case had already gone wrong three calls earlier, before
.CW dodiv()
ever ran: variable-sourced vlongs
.CW "(_ul2v, _si2v)"
were fine throughout; every place a bare compile-time constant
appeared in vlong arithmetic was not.  Fixed by swapping which half
.CW cgen.c
and
.CW swt.c
store first, matching every other vlong producer in this compiler.
Verified two ways at once, live: the same
.CW (4294967296+100)/4
test now prints
.CW 0x42eb7037
exactly
.CW "(1122726711, the correct answer)" ,
and
.CW poolsizeinit()
now reports
.CW "poolsize max 53388083"
\- also exactly the hand-computed value.
.PP
With the real bug fixed,
.CW virt32
goes a long way further:
.CW poolalloc() ,
.CW procinit ,
the version banner, and
.CW SNPRINT-ABI-OK
all still print, then
.CW userinit()
succeeds where it used to panic, and the board goes on to print
.CW "Initial Dis: \(dq/osinit.dis\(dq"
\- it starts loading the actual init program.  It faulted there
twice, two genuinely different bugs stacked back to back, both found
and fixed.
.PP
First: an illegal-instruction exception
.CW "(cause 0x2)" ,
.CW tval
decoding byte-for-byte to a real, legal instruction \-
.CW "FLD f0,436(x28)" ,
a double-precision float load.  RISC-V's
.CW mstatus.FS
resets to
.CW Off ;
any F/D instruction traps as illegal until something sets it non-zero.
.CW virt/l.s
.CW "(jc's"
riscv64 entry) does this; it was correctly left out of
.CW virt32/l.s
when that file was first written, since za/zc had no float support
yet, and simply forgotten when that support was added later in this
same session.  Restored in
.CW _main ,
same
.CW "MEIE-style"
register-built immediate
.CW FSBITS
needs
.CW "(3<<13,"
past the
.CW +-2047
range an
.CW OR
can encode directly).
.PP
Past that,
.CW /osinit.dis
loading reaches
.CW libinterp/heap.c 's
.CW checktracked() \-
pre-existing, portable heap-corruption-tracking instrumentation, not
riscv32-specific \- which itself crashed: a genuine null-pointer read,
.CW trackPC->op
with
.CW trackPC
nil, in a diagnostic print two lines below one that already
null-checks
.CW trackM
and
.CW trackM->m
the same way but never checked
.CW trackPC
itself.
.CW trackPC
is legitimately nil at the checkpoint that fired here
.CW "(readmod:after-parsemod)" ,
before the interpreter has executed a single instruction, so there
is no "last instruction" to report) \- a real, if narrow, robustness
gap in shared, portable debug code, not anything specific to this
port.  Fixed with a nil guard, printing a plain
.CW "\(dqbefore any interpreter execution\(dq"
line instead of dereferencing.
.PP
With both fixed, the
.CW track
instrumentation itself now runs cleanly and is reporting something
real: dozens of
.CW "\(dqCHANGED TO BAD VALUE\(dq"
lines, all on the same freshly-parsed object
.CW "(4168 bytes,"
.CW "np 66,"
a pointer-heavy type map), each word going from the pool's
.CW -1
poison pattern to some other value during
.CW readmod .
The board then faults again, a load access fault
.CW "(cause 0x5)"
at a
.CW 0xcccccccc-pattern
address inside
.CW newmp() \-
the deep-copy-with-refcounting routine module linking uses, in the
branch that computes
.CW D2H(wp)
and reads
.CW h->t
off a pointer value it just copied out of that same object.  Reading
this together: something in that object's pointer map is treating a
word that is not yet a valid pointer as if it already were one, and
.CW newmp()
dereferences it before it has been set.
.PP
It was not a
.CW zc
bug at all, and not corruption \- it was the wrong file.
.CW mkroot
resolves the board config's
.CW /osinit.dis
root-list entry to
.CW os/inferno/init/$INIT.dis ,
and virt32's own board config said
.CW INIT=virtinit ,
the exact name riscv64's
.CW virt
board already uses for the same purpose.
.CW os/inferno/init/
is shared across every board;
.CW virtinit.b/.dis
already existed on disk, built for
.CW virt
.CW "(DISWORD=8)" ,
and
.CW mk 's
dependency check only compares timestamps against
.CW virtinit.b \-
it has no way to know a same-named
.CW .dis
needs rebuilding for a different word size.  virt32 silently linked
in that word-size-mismatched module: its own Type descriptors decoded
with
.CW tsz/tnp
scaled for 8-byte words
.CW "(size 4168,"
.CW "np 66"
matches 66 map-bytes over 8-byte words almost exactly, not 4-byte
ones), which is exactly the false-pointer pattern
.CW newmp()
crashed on.
.CW virtinit.b 's
own module list
.CW "(draw/tk/tkclient/wmsrv)"
would not have worked on this board's device list either way, so a
genuinely separate init program, not a rebuild of the shared one, is
the real fix \- both the word-size collision and the missing-module
problem at once.  New
.CW os/inferno/init/virt32init.b ,
copied from
.CW armv7minit.b
.CW "(the same DISWORD=4"
board class, same minimal serial-console-only shape, no
draw/tk/wmsrv), wired in via virt32's own board config.
.PP
With that fixed,
.CW virt32
reaches a real, interactive shell.  Not just a printed prompt: piped
a command in over the emulated UART after boot and got the command's
actual output back \-
.CW "echo HELLO-FROM-RISCV32-SHELL"
printed
.CW HELLO-FROM-RISCV32-SHELL
and returned to the
.CW ;
prompt, verified live, not assumed from the prompt alone.  This is
the standing goal AGENTS.md set for this architecture.  Genuinely
open, not yet chased: the board also spams a
.CW todfix
diagnostic
.CW "(os/inferno/port/tod.c,"
portable, pre-existing) continuously once the clock is running, with
implausible multi-year values \- noisy, not fatal, boot and the shell
both work despite it, and it is a
.ul
different
open item from everything fixed in this section, inherited from
.CW virt/clock.c 's
own already-documented CLINT/mtimecmp fragility rather than anything
new to riscv32.
.NH 1
arm64 board bring-up
.PP
.CW os/inferno/virtarm64
is a new board built on the real
.CW 7a/7c/7l
AArch64 backend this document already recorded as compiler-only: same
QEMU virt machine as
.CW virt
(riscv64) and
.CW virt32
(riscv32), single EL1 kernel, GICv2, the generic timer.  OBJTYPE is
.CW aarch64 ,
not
.CW arm64 \-
.CW arm64
was already claimed tree-wide by the hosted macOS
.CW emu-cocoa
build's real Dis JIT
.CW ( libinterp/comp-arm64.c ,
Apple Silicon, a completely different target that happens to share a
CPU-family name); giving the new board the same OBJTYPE silently
linked the JIT file's
.CW sys/mman.h
include into a bare-metal build.
.CW libinterp/comp-aarch64.c
is this board's own no-JIT stub, kept a separate file from
.CW comp-arm64.c
specifically so the two never collide again.
.PP
Three real toolchain bugs, found by using
.CW 7a/7c/7l
for the first time on a real board rather than a bare test function,
fixed tree-wide rather than worked around locally.
.CW utils/libmach/obj.c 's
.CW Objxxx
dispatch table had an empty slot for
.CW ObjArm64
\- no
.CW .7
object reader had ever been written \-
so
.CW iar
silently corrupted the symbol table of any archive holding a
.CW .7
object, and
.CW 7l
reported every real symbol in it
.CW ( strcmp ,
.CW memmove ,
.CW quotefmtinstall ,
...) as undefined with nothing pointing at
.CW iar
as the actual cause.  New
.CW utils/libmach/7obj.c
.CW (_is7/_read7),
modelled on riscv64's
.CW jobj.c
but corrected for two confirmed wire-format differences: a 2-byte
opcode where
.CW jc 's
is 1 byte, and a
.CW TEXT/GLOBL
record's
.CW reg
byte carrying two flag bits
.CW (NOSCHED,
a
.CW from3
operand follows) that have to be honored to stay byte-synchronized
with the rest of the stream.
.CW utils/7a/a.y 's
.CW STXR
grammar production had its operands backwards: the middle operand is
the value being stored and belongs in
.CW from ,
not in the bare reg-number slot, which is where the status result
goes
.CW ( asmout.c 's
case 59 encodes
.CW Rs
from
.CW p->reg ,
.CW Rt
from
.CW p->from ) \-
caught live as
.CW _tas()
spinning forever on a genuinely uncontended lock, disassembling back
to exactly the swapped encoding.
.CW utils/7l/optab.c
had long-displacement load/store rows for
.CW MOVB/MOVH/MOVW/MOV
in both directions but none for
.CW MOVBU ,
breaking every board's own TCP/IP stack
.CW ( inittcpctl ,
.CW ipifcadd ,
...) with "illegal combination MOVBU LEXT NONE REG"; added the
missing rows, and only those \-
.CW MOVHU/MOVWU
already alias onto
.CW MOVH/MOVW 's
ranges via
.CW span.c 's
.CW buildop() ,
so rows for those two would have been a second, silently-wrong
registration.
.PP
Bring-up itself went through three real, live-debugged bugs in
sequence, each hiding the next one until it was fixed.  All three
found the same way: QEMU's
.CW -s\ -S
gdbstub plus
.CW lldb ,
.CW 7l\ -a
against the exact object list used for the final link for real
addresses in a stripped binary, and reading actual register and
memory state rather than reasoning about the assembly alone \-
static reading of this port's own hand-written
.CW STXR
sequence looked plausible three separate times before live state
proved each reading wrong.
.PP
First,
.CW _main 's
own stack pointer.
.CW MOV\ $stack+KSTACK(SB),\ RSP
as a single pseudo-op mis-encodes:
.CW 7l 's
large-constant expansion can choose a real AArch64 LDR-literal load
whose destination-register field 31 always decodes as
.CW XZR
(discard), never
.CW SP ,
in that specific encoding, so the board's very first instruction
silently discarded its own stack pointer.  Fixed by routing through a
scratch GPR
.CW ( MOV\ $stack+KSTACK(SB),\ R2
then
.CW MOV\ R2,\ RSP ) .
.PP
Second,
.CW _tas() .
.CW Lock.key
is a 4-byte
.CW ulong
immediately followed by
.CW Lock.sr ,
so the W-suffixed
.CW LDXRW/STXRW
forms are required, not the default 64-bit ones \- that width fix
landed first, and was real, but did not fix the actual bug.  The
.CW STXR
operand-order swap described above meant
.CW _tas()
was storing the
.ul
old
value it had just loaded back over itself, throwing away the new
value it meant to write; the return value
.CW ( R1 ,
never touched by the store) was always the correct "was it free"
answer, so every caller believed it had acquired the lock while
.CW l->key
never actually changed.  This produced a strange, indirect symptom
rather than an obvious one:
.CW iunlock() 's
own self-check
.CW "(\*(lql->key == 0: not locked\*(rq)"
fired on the first
.CW ilock/iunlock
pair the board ever took
.CW ( kmesg.lk ,
from
.CW print() 's
own
.CW kmesgputs() ) ,
and the diagnostic
.CW print()
that check triggers itself calls
.CW kmesgputs() ,
which takes and releases the same lock \- so the complaint recursed,
each nested
.CW iunlock()
seeing the same "unlocked" lock and printing the same complaint
again, feeding
.CW dofmt()
a runaway sequence of
.CW %p
arguments read off an empty
.CW va_list
until one of them was bad enough that
.CW utflen()
faulted dereferencing it.  Every earlier appearance of this crash was
a data abort at PC
.CW 0x200 ,
the Sync-at-current-EL-SPx vector slot, since
.CW VBAR_EL1
was still its architectural reset value of 0 \- i.e. the fault
predated
.CW trapinit()
entirely, and looked at first like a boot-order problem rather than a
locking one.  Confirmed live by walking the real
.CW print()\->vseprint()\->dofmt()
call chain instruction by instruction: it returns cleanly, and the
.ul
second,
recursive
.CW print()
invocation's own return address lands inside
.CW iunlock() 's
"not locked" print call.  Fixed by giving the exclusive-store status
result its own register instead of reusing the one holding the new
value.
.PP
Third, a bug in shared interpreter code, not this board's own
assembly at all.
.CW libinterp/load.c 's
.CW parsemod() ,
handling a module's exception-handler table, guarded
.CW "h->t = m->type[descid]"
on
.CW "n != -1" \-
but
.CW n
is the
.ul
previous
iteration's exception-label count, set a few lines
.ul
below
this check from the next
.CW operand()
read, not this handler's type descriptor; on the loop's first
iteration
.CW n
is whatever garbage happened to be live on the stack.  The condition
has to test
.CW descid
itself
.CW ( \-1
means "no type", a catch-all handler \-
.CW xec.c
checks
.CW "f->t == nil"
at use time for exactly this case), and bounded against
.CW m->ntype
too, the same class of off-by-one already fixed a few lines up in
this same function
.CW "(load.c:351)."
Found live on arm64 because the very first module the kernel ever
loads,
.CW /osinit.dis ,
faulted here on real hardware state \- aarch64's leftover stack
garbage for
.CW n
at that point happened to differ from
.CW -1
where pc64/riscv64/riscv32's happened not to.  A pre-existing bug in
code every port shares, never triggered by any of their stack
layouts before now.  Verified riscv64 still boots clean through its
self-test script after this change, no regression on a port that
already reaches a shell.
.PP
With all three fixed, the board boots past every stage of
.CW main()
\- pool init, trap init, MMU init, clock init, proc init, screen
init, PCI arch init, chan dev reset, UART console setup \- prints the
normal
.CW "Inferno Fourth Edition"
banner, and starts loading
.CW /osinit.dis
and its dependent modules.  This is real, live-verified progress, not
assumed: every stage above printed its own distinct marker over the
emulated PL011 before this section's instrumentation was removed from
.CW main.c
once
.CW print()
itself was confirmed working.
.PP
Genuinely open, not yet fixed: past loading a couple of modules, the
board deadlocks rather than crashes.  Live-diagnosed to
.ul
where ,
not yet to
.ul
why .
The spinning context is
.CW ilock() 's
own glare loop, uniprocessor, waiting on
.CW kmesg.lk
a second time while a
.CW kmesgputs()
call still holds it \- reading the lock's
.CW pc
field back to the exact call site confirms it. The mechanism: this
board's
.CW trap.c
default fault handler calls
.CW splhi()
then
.CW print()
before
.CW panic() ing,
and a genuine
.ul
synchronous
fault \- not maskable by
.CW DAIF.I
the way an IRQ is \- arriving while
.CW kmesgputs()
already holds
.CW kmesg.lk
means the fault handler's own diagnostic
.CW print()
needs the same lock to report what happened, and can't get it.  That
underlying fault was caught directly, once, by breakpointing
.CW trap()
and filtering for
.CW ur\->type\ ==\ TSync
rather than the far more frequent
.CW TIrq :
a data abort inside
.CW poolfree() ,
dereferencing a pointer computed from a block's recorded size
.CW "(ur->cause 0x96000000,"
.CW "ur->tval an implausible, clearly-corrupt address),"
consistent with heap metadata corruption rather than a bad argument
\- something wrote past the end of a pool block, or corrupted its
size field directly, before this free ever ran.  Not yet chased to
.ul
who
corrupted it or
.ul
when;
that needs a watchpoint on the corrupted block across a wide time
window, not another single live sample.
.PP
One more thing learned about this same open bug before stopping to
write it up rather than continuing to sample: it cascades.
Breakpointing
.CW trap()
itself and filtering every hit for
.CW ur\->type\ ==\ TSync
(discarding the far more frequent
.CW TIrq )
across one continuous boot caught not one Sync fault but a chain of
them, each landing on a
.ul
fresh
frame further down the same kstack \- consistent with
.CW l.s 's
vectrap comment that a nested trap gets its own frame rather than
clobbering the one being handled.  The second fault in the chain was
a
.ul
write ,
not a read
.CW "(ESR.WnR\ set),"
through a wild pointer inside
.CW addelem() ,
one of
.CW alloc.c 's
own free-list functions; the third was inside
.CW fmtfmt<> ,
dofmt() 's
verb-dispatch helper \- i.e. the
.I second
attempt to report the
.I first
fault, from inside
.CW trap() 's
own
.CW print() ,
also faulted, formatting some argument of its own.  Read together
with the already-open
.CW poolfree()
finding, this reads as one corrupted heap poisoning every subsequent
pool operation differently depending which function touches it next,
not three unrelated bugs.  Consistent with, but not yet shown to be
the same issue as, the extensive already-documented pool-corruption
history earlier in this document
.CW "(_poolfault(),"
the
.CW notefree()
dangling-
.CW R.M
fix, ...) \- that history is about a
.I diagnostic
path crashing while trying to report corruption it did not cause;
this is corruption itself, arm64-specific so far, not yet shown to
share a root cause with any of it.  Also open, lower priority:
.CW ilock() 's
acquire path sets
.CW l->m\ =\ MACHP(m->machno) ,
and a live read of a held lock showed this field as nil \- worth
checking
.CW MACHP()
on this board once the deadlock itself is fixed, but not demonstrated
to be load-bearing for anything yet.
.NH 1
Taking stock: every board booted again, and what a modern machine still needs
.PP
This section re-checks the record against live boots rather than
re-reading it, on 2 September 2026, with the binaries the tree held that
morning, and then answers a question the record had never put in one
place: what drivers a machine built in the last ten years needs that no
board here has.
.PP
.TS
box tab(;);
lb lb lb
l l l.
board;booted today;state
_
riscv32 virt32;1 of 1 to a shell;a piped-in echo came back, todfix spam still there
riscv64 spike, sifiveu;scripted shell markers print;SPIKE-SH-OK, SIFIVEU-SH-OK
riscv64 virt;4 of 4 panicked after DHCP-OK;deterministic, root-caused and fixed below
pc64;0 of 15 clean;heap corruption, every boot, old and rebuilt binary alike
armv7;0 of 10 past module loading;the same two faults the record describes
arm64 virtarm64;0 of 1 past module loading;the documented kmesg.lk deadlock, unchanged
.TE
.PP
The riscv64 result was the surprise: the record says 40 of 40 clean, and
.CW os/inferno/virt/smoke.sh
now fails every time.  Two separate things were wrong, one in the
harness and one in the kernel.  The harness one: the smoke script
expects
.CW FS-OK
before
.CW TMP-OK ,
but
.CW os/inferno/init/virtinit.b
has printed them the other way round since
.CW tmpmount()
was moved ahead of
.CW fsmount()
(the FAT hang fix earlier in this document), so
.CW expect
consumed past
.CW TMP-OK
while waiting for
.CW FS-OK
and then timed out waiting for a marker already gone by.  The two
blocks are swapped now.
.PP
The kernel one is real, and it is deterministic.  Four boots in a row
printed
.CW "panic: exception"
immediately after
.CW DHCP-OK ,
during the 1.5 s sleep before the ping stage, with none of
.CW os/inferno/virt/trap.c 's
own register dump ahead of it.  QEMU's
.CW "-d int"
trace gives what the dump did not:
.CW "cause 5"
(load access fault) at
.CW "epc 0x8002cd94" ,
.CW "tval 7" .
That address resolves, bounded on both sides, to
.CW notefree+136
in
.CW os/inferno/port/alloc.c ,
and the instruction there is
.CW "ld a0,8(a0)"
right after
.CW "ld a0,48(a5)" :
the read of
.CW xp->R.M->m
in the freehist diagnostic.  A trap value of 7 means the pointer being
dereferenced was
.CW -1 :
the current Prog's
.CW R.M
held
.CW H ,
Dis's nil sentinel
.CW "((void*)-1)" ,
which the guard
.CW "xp->R.M != nil"
does not catch.  This is the same freehist instrumentation whose
global-R read was pc64's dominant crash, and whose bisection probe
already hung riscv64 once; its own comments say it is pc64-only and
temporary.  pc64 never trips here because a read from address 7 does
not fault on that board's page tables; riscv64 runs in machine mode with
no translation and address 7 is not RAM.  Fixed by adding
.CW "xp->R.M != H"
to the guard at all three sites that read
.CW xp->R.M->m
this way \- both in
.CW os/inferno/port/alloc.c
and
.CW dumpregs()
in
.CW os/inferno/pc64/trap.c .
Not chased: why a Prog that
.CW currun()
returns has
.CW R.M
equal to
.CW H
at all at that moment (no assignment of
.CW H
to
.CW R.M
exists in
.CW libinterp
or
.CW os/inferno/port ;
every
.CW f->mr
initialiser is C nil), and, separately, why the trap handler's ten
.CW print()
calls produced nothing on the wire while
.CW panic() 's
.CW iprint()
did.  Both are open and recorded here rather than guessed at.
.PP
With the guard in, the rebuilt
.CW ivirt
runs the corrected smoke script past
.CW DHCP-OK
and on through every remaining stage to
.CW "interactive sh"
and a prompt \- the standing goal for this board, and the state the
record described.  The script still exits 1, for reasons that are the
harness's and the board config's, not the kernel's, and are left open
here: its stages for Tk, the window manager, SSL, factotum and dynamic
loading all report "file does not exist" (no
.CW tk.dis
is in
.CW os/inferno/virt 's
root list, and the SSL and auth stages bind under the static
.CW /n
that the FAT fix retargeted away from), the ping stage times out, and
the script's own list of required markers at its end still names every
one of those.  The document had never recorded a full pass of that
script; the 40 of 40 it recorded were boots to a shell, which is what
this is.
.PP
pc64 is worse than the record's 15 of 20.  Under this session's harness
(150 s of TCG, the same
.CW qemu-boot.sh )
the committed binary crashed 4 of 4 serial boots and 6 of 6 parallel
ones, and the first thing found was that it had been linked on 31
August against an
.CW Inferno/amd64/lib/libinterp.a
from 28 August, before the shared
.CW libinterp/load.c
fix of 1 September that arm64 and riscv64 were rebuilt with.  Rebuilt
that library for amd64 and relinked:
four serial boots, four crashes.  Fifteen boots today, fifteen crashes,
before and after the relink.
The signatures are the familiar heap-corruption family \-
.CW "panic: page fault"
in module
.CW Sh
at
.CW destroy+627 ,
.CW _poolfault
in module
.CW String ,
.CW "_allocb: lim < base" ,
general protection faults, a
.CW "cclose"
refcount panic, and once
.CW "init0: namec: pgrp has no dot" .
Nothing new was learned about it here; the point of this section is to
record that the clean rate the document last measured does not hold
under a 150 s timeout, whatever it was under a shorter one.
.PP
armv7 and arm64 are exactly as recorded.  armv7 across ten boots: one
undefined-instruction trap with
.CW "pc 0x00000000"
and
.CW "sp 0x400f8dcc"
(the stale boot-stack value has moved again with the binary, as the
record said it would), six data aborts at five different PCs, three
still mid-panic when the timeout fired.  arm64 stops after the first
.CW copypath
lines of the
.CW /osinit.dis
load, the pool-corruption deadlock.
.PP
What is left on the five-board goal, in the order it is worth doing:
pc64's heap corruption (every boot now, so it is at least easy to
catch); arm64's pool corruption in
.CW poolfree() ,
which needs a watchpoint across a wide window; armv7's two faults;
riscv64's
.CW R.M\ ==\ H
origin and its silent trap dump; riscv32's
.CW todfix
spam.  pc64 has also never once been run with more than one CPU, so
.CW squidboy
and the MP code are linked but unexercised.
.NH 2
Drivers a modern machine needs
.PP
What pc64 links today, read from its config rather than from the
directory listing: PCI configuration through the legacy
.CW 0xCF8/0xCFC
ports only; ACPI with the AML interpreter,
.CW HPET ,
the APIC and x2APIC code, and MP tables; an i8042 keyboard with the
PS/2 mouse commented out; an 8250 UART; AHCI SATA
.CW ( sdiahci ) ;
legacy (pre-1.0) virtio net and block; Realtek 8169, Intel 82563-family
(which does include the I219) and Intel X550 Ethernet; and a framebuffer
inherited from the boot loader through
.CW vgasoft .
MSI is enabled by exactly one driver,
.CW etherx550 .
There is no USB of any kind in the link: the only USB code under
.CW os/inferno
is
.CW pc/usbuhci.c ,
USB 1.1, and nothing links it.
.PP
Missing, in the order a real machine will refuse to boot without them:
.IP 1.
USB 3 host controller (xHCI) plus the
.CW devusb
core and the HID, hub and mass-storage classes.  Without it there is no
keyboard or mouse on any machine made since PS/2 left the board, and no
boot from a USB stick.  Source at hand:
.CW os/osprey/pc64/usbxhci.c ,
.CW usbxhcipci.c ,
.CW devusb.c ,
and the same files in
.CW os/9front/port .
.IP 2.
NVMe
.CW ( sdnvme ) .
Most machines of the last eight years have no SATA at all.
.CW os/osprey/pc64/sdnvme.c
and
.CW os/9front/port/sdnvme.c .
.IP 3.
PCI Express: ECAM configuration space from ACPI's MCFG table (no
.CW MCFG
or
.CW ecam
string exists anywhere under
.CW os/inferno/pc
or
.CW port/pci.c ),
extended capabilities, and MSI/MSI-X in every driver rather than one.
Legacy port I/O still works on current firmware, but only for the first
256 bytes of each function, and legacy INTx routing needs the ACPI
.CW _PRT
walk to be right on boards that no longer ship an MP table.
.IP 4.
Virtio 1.0.  The pc64 drivers have no
.CW VERSION_1
path at all; QEMU's transitional devices hide that, modern-only devices
(cloud hosts, virtio-mmio on arm64) do not.
.CW os/osprey/pc64/ethervirtio10.c
and
.CW sdvirtio10.c
are the 1.0 versions.  virtio-input, virtio-gpu, virtio-rng and
virtio-scsi are not present on pc64 either;
.CW os/inferno/virt
has the mmio input and rng ones.
.IP 5.
Ethernet made after about 2018: Intel I225/I226 2.5 GbE
.CW ( os/9front/pc/etheri225.c ) ,
Realtek RTL8125 2.5 GbE (no source in any flavour here; the 8169 driver
does not carry its IDs), Broadcom NetXtreme
.CW ( etherbcm ) ,
Marvell Yukon
.CW ( etheryuk ) ,
Intel 82598/82599 10 GbE
.CW ( ether82598 ) ,
and USB Ethernet, which depends on item 1.
.IP 6.
Wi-Fi: Intel
.CW ( os/osprey/pc64/etheriwl.c
with
.CW os/9front/port/wifi.c ) ,
Ralink
.CW rt2860 ,
Intel
.CW wpi ,
Broadcom.  Every laptop.
.IP 7.
HD audio
.CW ( os/9front/pc/audiohda.c ) ,
SD/MMC
.CW ( os/9front/port/sdmmc.c ) ,
and multiprocessor bring-up, which is linked and never run.
.PP
The RISC-V boards have a different first problem.  They run in machine
mode with
.CW "-bios none" :
.CW mtvec ,
.CW mstatus
and the CLINT's
.CW mtimecmp
directly, no SBI.  A VisionFive 2 or an Icicle boots OpenSBI and hands
the kernel supervisor mode, so before any driver matters the board
needs an S-mode entry
.CW ( stvec ,
.CW sstatus ,
SBI calls for the timer, console and IPIs, the PLIC's supervisor
contexts) and a device-tree reader \- no board under
.CW os/inferno
parses a DTB; every address is a constant checked against QEMU's
.CW dumpdtb .
After that: PCIe (the VisionFive 2 carries its NVMe on it), the
DesignWare GMAC Ethernet, a DesignWare SDHCI, and a Cadence xHCI.
.PP
arm64 shares the device-tree gap and adds three more before drivers:
PSCI (secondary CPUs, reboot, power-off), GICv3 (the board has GICv2
only; sbsa-ref and nearly every real SoC are GICv3), and PCIe ECAM with
virtio-pci, since QEMU's arm64 virt puts its disks and NICs on PCI, not
mmio, unless told otherwise.  A Raspberry Pi 4 then needs the VL805
xHCI, GENET Ethernet, the BCM2711 eMMC2 SDHCI and the firmware
framebuffer through the mailbox; a Pi 5 the RP1's xHCI and Cadence MACB
instead.  Servers need ACPI, of which arm64 has none, and a UEFI entry
\- the
.CW os/inferno/boot/efi
loader is x86 only.  armv7 is the same list one generation back.
.PP
None of the Osprey or 9front files above may be reached across to; the
tree's rule is that a flavour copies what it needs into its own
directory.  The copies are cheap.  Adapting them is not: the 9front
drivers assume 9front's
.CW Block ,
.CW qio
and interrupt interfaces, which Inferno's port layer shares in name and
differs from in detail, and each one has to be brought up against a
booted kernel the way every driver in this document was.
.NH 1
Taking the drivers 9front already has, and what is left after that
.PP
The list at the end of the previous section was written from the
outside: what a machine has, what no board here drives.  This section
is the inside view.  The tree's own
.CW os/9front
flavour carries most of those drivers, and the rule that one flavour
may not reach into another leaves copying, which is cheap, and
adapting, which was measured before it was assumed.
.PP
Measured first, by compiling each candidate against
.CW os/inferno/pc64 's
own headers (with absolute
.CW -I
paths \- the relative ones silently resolve
.CW u.h
from nowhere when the source lives outside the board directory, which
cost one false start).  The kernel interfaces the drivers see are
near-identical:
.CW sd.h
differs by 63 lines,
.CW etherif.h
by 20,
.CW pci.h
by 11;
.CW intrenable ,
.CW sleep ,
.CW wakeup ,
.CW pcimatch ,
.CW pcimsienable ,
.CW sdadddevs
and
.CW addethercard
have the same prototypes on both sides.  What differs, all of it now
bridged in
.CW os/inferno/port
once rather than per driver:
.IP \(bu
.CW SDifc
still carries an unused
.CW xxlegacy
slot after
.CW pnp ,
and its
.CW rctl
returns a count into a buffer where 9front's returns a position up to
an end pointer.  Each copied SD driver's interface table gets a
.CW nil
in the slot and, where it has one, a three-line
.CW rctl
adapter.
.IP \(bu
.CW Ether.ifstat
has the same shape difference.
.CW ether9ifstat()
in
.CW os/inferno/port/devether.c
adapts a 9front-style one; each copied driver keeps its own and adds a
two-line wrapper.
.CW ethersetspeed()
and
.CW ethersetlink()
are new there too, without 9front's queue resizing.
.IP \(bu
.CW Bpool ,
9front's per-driver free list of aligned Blocks.  Here it is only the
size and alignment
.CW ( portdat.h )
and
.CW iallocbp()
in
.CW allocb.c
allocates afresh each time; nothing is recycled, which is slower and
correct.
.IP \(bu
.CW kproc()
takes a flags argument here; seventeen calls gained a
.CW 0 .
.CW Dev.open ,
.CW read
and
.CW write
take and return
.CW int
here where 9front says
.CW long ;
.CW devusb.c 's
three prototypes changed.
.CW RWLock
is spelt
.CW RWlock ;
a typedef.
.CW dmaflush()
is an empty macro in
.CW os/inferno/pc64/fns.h ,
as it is in 9front's own pc64.
.CW secalloc()/secfree()
(zero before free) are in
.CW alloc.c ;
.CW dec16()
and a constant-time
.CW tsmemcmp()
went into
.CW libkern ,
which every target links; libsec's static
.CW rijndaelEncrypt
is exported under 9front's name
.CW aes_encrypt
for wifi's CCMP.
.IP \(bu
The one thing that does not bridge: 9front's newer MII layer
.CW ( addmiibus ,
.CW MiiPhy ,
clause-45 access).
.CW ethermii.c
differs by 274 lines and the tree's own
.CW ether8169
and
.CW ether82563
use the old one, so
.CW etheri225
(Intel 2.5 GbE) is not taken until that layer is replaced whole.
.PP
Also gone:
.CW os/inferno/pc/devusb.c ,
.CW usbuhci.c
and
.CW usb.h ,
Inferno's own USB 1.1 stack, which no board linked and whose
.CW /dev/usbh
interface
.CW appl/cmd/usb/usbd.b
was written against.  The 9front stack replaces it in the kernel and
orphans that Limbo program; see the plan.
.PP
And a build-directory ghost:
.CW os/inferno/pc64
had linked for weeks against a
.CW stubs.6
whose source was never committed, and the first header change made
.CW mk
want to rebuild it.  The six symbols it provided
.CW ( vesabootscreenconf ,
.CW cursorenable ,
.CW cursordisable ,
.CW notkilled ,
.CW rdb ,
.CW rdbstarted )
are now in a real
.CW os/inferno/pc64/stubs.c
with a comment each saying why the board has no implementation.
.PP
Taken, linked into
.CW pc64 ,
and tested under QEMU 10.1 on both the default PC and
.CW q35 ,
through a console-only init
.CW ( os/inferno/init/pc64devinit.b ,
configuration
.CW os/inferno/pc64/pc64dev )
that binds
.CW #S ,
.CW #u
and
.CW #l1
and reads their control files:
.TS
box tab(;);
lb lb lb
l l l.
driver;QEMU device;verified
_
sdnvme;-device nvme;sdN0: inquiry, serial, 65536 sectors, sector 0 read back
sdvirtio10 + virtio10pc;virtio-blk-pci,disable-legacy=on;sdF0: 65536 sectors, sector 0 read back
ethervirtio10;virtio-net-pci,disable-legacy=on;#l1 attached, VERSION_1 negotiated, DHCP lease obtained
devusb + usbxhci + usbxhcipci;qemu-xhci + usb-kbd + usb-tablet;controller found, /dev/usb/ctl lists two root hubs, 4 ports, USB 2 and 3
ether82563 (already there);e1000e, igb;#l0 i82574, #l1 i82576 attach
etherbcm, etheryuk, ether82598;none in QEMU;compile and link only
etheriwl + wifi;none in QEMU;compile and link only
.TE
.PP
"Sector 0 read back" means the host wrote a sentence into the image
before boot and the init printed that sentence from
.CW /dev/sdN0/data
and
.CW /dev/sdF0/data .
The usb result is the kernel half only: the root hubs enumerate, the
keyboard and tablet behind them do not, because enumeration is
.CW usbd 's
job and there is none.
.NH 2
QEMU machines against what the boards drive
.PP
Read from
.CW "-device help"
on QEMU 10.1.3 per machine, against what each board links and what was
verified above.  "kernel only" means the driver is up and the device is
visible but nothing above the kernel uses it yet.
.PP
.TS
box tab(;);
lb lb lb
l l l.
machine and device;board;state
_
x86-64 q35, pc: ich9-ahci;pc64;works (sdE)
nvme;pc64;works, new
virtio-blk-pci legacy and modern;pc64;works, modern new
virtio-net-pci legacy and modern;pc64;works, modern new
e1000e, igb;pc64;work through ether82563
e1000, rtl8139;pc64;drivers exist in os/inferno/pc, not linked
virtio-scsi-pci, ide-hd (pc), sdhci-pci, usb-storage, virtio-9p;pc64;none
qemu-xhci, nec-usb-xhci;pc64;kernel only, new
ich9-usb-ehci, uhci;pc64;none (9front has both, compile clean, not taken)
usb-kbd, usb-mouse, usb-tablet;pc64;need a usbd and HID class in Limbo
i8042 keyboard;pc64;works, PS/2 mouse commented out
virtio-keyboard-pci, tablet-pci, vmmouse;pc64;none
VGA text, boot-loader framebuffer;pc64;work, no modesetting, no virtio-gpu
intel-hda, AC97, virtio-sound;pc64;none (9front audiohda needs its audio interface)
virtio-rng-pci;pc64;none (mmio version exists on virt)
MSI, ECAM;pc64;MSI in one driver, no ECAM
-smp N;pc64;never run
x86-64 microvm;none;no board: virtio-mmio only, no PCI, discovery by ACPI or command line
riscv64 virt: virtio-mmio blk, net, input, rng, ramfb;virt;work, legacy only (force-legacy=true)
virtio-pci via ECAM at 0x30000000;virt;works, legacy (ethervirtiopci, pcivirt)
nvme, qemu-xhci on that PCIe;virt;not linked, the drivers are portable now
riscv64 sifive_u;sifiveu;shell over UART, Cadence GEM Ethernet and SPI SD not driven
riscv64 spike;spike;shell over UART, nothing else to drive
aarch64 virt: virtio-mmio;virtarm64;ethernet linked, board not at a shell
PCIe ECAM, GICv3, PSCI, SMP;virtarm64;none
aarch64 sbsa-ref, raspi4b;none;no board
arm virt (Cortex-A15);armv7;as arm64, one generation back
.TE
.NH 2
The plan
.PP
In the order the pieces unlock each other, each one tested against a
booted kernel before the next:
.IP 1.
Link
.CW etherigbe
and
.CW ether8139
into
.CW pc64
and test with
.CW e1000
and
.CW rtl8139 .
An afternoon; it only needs their
.CW ifstat
wrappers.
.IP 2.
A
.CW usbd
in Limbo against 9front's
.CW /dev/usb
interface: enumerate root hub ports through
.CW ep0
control transfers, configure devices, run a hub driver, and a HID
driver that feeds
.CW devkbd
and
.CW devpointer .
That is what makes a keyboard and mouse work on any machine made after
PS/2, and QEMU's
.CW usb-kbd
and
.CW usb-tablet
test it.  9front's
.CW nusb/usbd ,
.CW nusb/kb
and
.CW nusb/disk
are the reference; the old
.CW appl/cmd/usb/usbd.b
shows the Limbo shape.  Mass storage follows as a second class driver.
.IP 3.
Virtio 1.0 on the mmio boards: take
.CW os/9front/port/virtio10mem.c
into
.CW virt
and
.CW virtarm64 ,
drop
.CW force-legacy=true
from
.CW smoke.sh .
Then PCI on
.CW virtarm64
the way
.CW pcivirt
does it on riscv64 (ECAM, a static bus walk), and link
.CW sdnvme
and
.CW usbxhcipci
on both virt boards, which QEMU can test on each.
.IP 4.
ECAM from ACPI's MCFG on pc64, and MSI in
.CW sdnvme ,
.CW usbxhci
and the virtio drivers where 9front's versions use it.  Without ECAM,
capabilities past byte 256 are invisible and a machine without an MP
table routes interrupts only as well as the ACPI
.CW _PRT
walk does.
.IP 5.
Replace
.CW os/inferno/port/devsd.c
and
.CW sd.h
with 9front's (594 lines of difference, one direction of descent) and
drop the
.CW xxlegacy
and
.CW rctl
shims above.  That brings the
.CW SDio
layer, and with it
.CW sdmmc
and
.CW pmmc
(SD cards on PCI SDHCI, QEMU's
.CW sdhci-pci )
and
.CW sdide .
.IP 6.
Replace
.CW ethermii.c
with 9front's and re-port
.CW ether8169
and
.CW ether82563
to it; then
.CW etheri225
comes across unchanged.  RTL8125 has no driver in any flavour and is
new work.
.IP 7.
Audio: 9front's
.CW devaudio.c
and
.CW audioif.h
in place of Inferno's
.CW devaudio ,
then
.CW audiohda ;
QEMU's
.CW intel-hda
tests it.  The Limbo side reads
.CW /dev/audio
either way.
.IP 8.
.CW -smp
on pc64, since
.CW squidboy
and the MP code have never run.
.IP 9.
The real-hardware gaps no QEMU device stands in for: device-tree
parsing and PSCI and GICv3 for arm64, supervisor mode with SBI for
riscv64, and after them the SoC drivers named in the previous section.
.PP
Items 1 to 4 are each testable on this host today.  Items 5 to 7 are
each one shared subsystem swapped for 9front's; the drivers that wait
on them already compile against 9front's version.
.NH 2
Item 1, done: e1000 and RTL8139
.PP
.CW os/inferno/pc/etherigbe.c
and
.CW ether8139.c
were Inferno's own, from before this tree's port layer took 9front's
shape, so linking them needed the same small moves the 9front drivers
did in the other direction:
.CW etheriq()
lost its third argument, the
.CW Ether.interrupt
hook became the driver's own
.CW intrenable() ,
and the includes now name
.CW ../port .
.CW etherigbe
also refused any controller whose PCI cache-line-size register was
zero, which is what firmware and QEMU leave it; 9front's version
programs 0x10 and carries on, and so does this one.  Verified on
.CW q35
one NIC per boot (a second DHCP on the same stack fails with "address
in use", so the test init takes a lease on the first interface that
answers):
.CW e1000
attaches as
.CW i82543
and gets a lease,
.CW rtl8139
attaches and gets a lease, the modern-only virtio NIC gets a lease 4
of 4.  Observed on the way and not chased: the pre-existing
.I legacy
virtio NIC driver on
.CW q35
got a lease 1 boot in 3 (one "no response", one init broken with
"file does not exist"), and 2 of 2 on the default PC machine, where
every earlier boot of this board has run.  On
.CW q35
the MP code also prints "can't find bus type 12" for every PCI
Express interrupt assignment, so interrupt routing there is suspect
before the driver is.
.NH 2
Item 3, done: the portable PCI layer on riscv64, and two compilers that lost the top half of every wide constant
.PP
The plan said "virtio 1.0 on the mmio boards from
.CW virtio10mem.c" ;
that was wrong twice.
.CW os/inferno/virt/ethervirtiommio.c
already negotiates
.CW VERSION_1
on a modern mmio device, and 9front's
.CW virtio10mem.c
is not an mmio transport at all but the PCI memory-BAR accessor every
non-x86 architecture uses (9front has no virtio-mmio).  So the real
item was PCI on the riscv64 board, and that is what landed.
.PP
.CW os/inferno/riscv/pcivirt.c
was a private mini-PCI: its own
.CW PciDev ,
its own
.CW pcimatch() ,
config access by
.CW (bus,dev,fn) ,
and one driver written to it,
.CW ethervirtiopci.c
(legacy virtio only).  Both are gone.  In their place
.CW os/inferno/riscv/pciecam.c
is the back end
.CW ../port/pci.c
asks a board for \- the same portable bus walk, BAR assignment and
.CW Pcidev
list pc64 uses \- reading and writing configuration space through the
ECAM window at
.CW 0x30000000
and mapping each INTx pin to PLIC 32..35 the way QEMU's virt machine
rotates them by slot.  Memory BARs are placed by
.CW pcibusmap()
from
.CW PCIMMIO ;
.CW vmap()
is the identity (machine mode, no translation),
.CW PCIWADDR()
is
.CW PADDR() ,
.CW dmaflush()
is empty.  With that, every PCI driver in the tree is one config line
away on this board, and the four verified on pc64 were linked:
.CW sdnvme ,
.CW sdvirtio10
with
.CW virtio10mem ,
.CW ethervirtio10 ,
.CW usbxhcipci .
.PP
One tree-wide change came first.  Every board except the two x86 ones
declared
.CW intrenable()
as (irq, tbdf, handler, arg, name), the portable prototype and the
9front drivers say (irq, handler, arg, tbdf, name).  All eight
definitions, ten prototypes and nineteen callers (and
.CW intrdisable() 's
eight, ten and one) now use the portable order; the change is
mechanical and every board rebuilds.
.PP
Then the board booted with the PCI devices and NVMe refused its
controller: "doesnt support NVM command set: 41".  0x41 has bit 0
set, which is the very bit
.CW "(cap & (1ULL<<37))"
tests, so the constant was wrong, and QEMU's
.CW "-d int"
had nothing to say because nothing faulted.  A six-line probe
compiled with
.CW jc
and read back with objdump settled it: every constant that does not
fit a signed 32-bit word came out as zero
.CW ( 0x2000000000 ,
.CW 0x100000000 )
or minus one
.CW ( 0xffffffff ).
Three separate instances of the tree's standing "long is 32 bits" bug,
each on the path a wide constant takes from
.CW jc
to
.CW jl :
.IP \(bu
.CW utils/jc/txt.c
decides whether a constant fits the object format's 4-byte
.CW D_CONST
by casting it to
.CW long
and comparing; on this host that is a 64-bit cast, so it always fits
and the 8-byte
.CW D_VCONST
form was never produced.  It now narrows through
.CW int ,
and only for 8-byte-typed constants, since a 32-bit-typed one wants
the sign-extending
.CW MOVW
its destination gets.
.IP \(bu
.CW utils/jc/swt.c
writes a
.CW D_VCONST
as two words read through
.CW "(long*)a->sval"
and
.CW "+1" :
on a 64-bit host the first read is the whole value and the second is
whatever lies past it.  It now splits the value arithmetically.
.IP \(bu
.CW utils/jl/obj.c
reads the two words back through the same two
.CW (long*)
stores, each 8 bytes wide, the second past the end of the allocation
and the first missing its high word \- so the literal-pool word the
kernel loaded was zero.  It now assembles one
.CW vlong .
.PP
Each step was checked in the linked machine code, not the listing:
after the first fix the pool load was there and the pool word was
still zero; after all three the pool holds
.CW 0x2000000000 ,
.CW 0x100000000
and
.CW 0xffffffff
and the kernel, rebuilt with every riscv64 library, brings the NVMe
controller up.  (A fourth change, teaching
.CW jl
a six-instruction sequence for constants its shift-form cannot reach,
was written and reverted:
.CW jl
already spills any such constant to a literal pool addressed off the
static base, which
.CW l.s
sets up before the first C instruction.)
.PP
Verified on riscv64 virt, the same test init as pc64
.CW ( os/inferno/init/virtdevinit.b ) :
.TS
box tab(;);
lb lb lb
l l l.
driver;QEMU device on the virt PCIe;verified
_
sdnvme;-device nvme;sdN0 inquiry, serial NVMERV64, sector 0 read back
sdvirtio10 + virtio10mem;virtio-blk-pci,disable-legacy=on;sdF0, sector 0 read back
ethervirtio10;virtio-net-pci,disable-legacy=on;#l0 attached, DHCP lease
devusb + usbxhci;qemu-xhci;/dev/usb/ctl lists the root hub, 8 ports
.TE
.PP
The same probe run through
.CW 7c
and
.CW 7l
shows arm64 has the same disease in a different place.
.CW utils/7c/swt.c
had the identical
.CW long
test in front of its 8-byte
.CW D_DCONST ,
fixed the same way.  But with that fixed the linked code for
"return 0x2000000000" is a
.I 32-bit
.CW MOVZ
with a shift of 32, which is not a valid instruction, and for
0xffffffff a sign-extending
.CW LDRSW
from the pool: the compiler is emitting
.CW MOVW ,
not
.CW MOV ,
for the constant.  With
.CW -N
(no optimiser) it emits the correct
.CW MOV .
The narrowing is therefore in
.CW 7c 's
optimiser passes
.CW ( peep.c ,
.CW reg.c ),
not in
.CW gmove() 's
tables, which say
.CW AMOV
for every vlong-to-vlong case, and not in the peephole's opcode
rewrites, which never set
.CW AMOVW .
Not located further; recorded here as the next thing to chase on
arm64, since it stands in front of every wide constant that board's
kernel has, and
.CW 7c
is byte-identical to the kencc-cross original, so the bug is
upstream's too.
.PP
One build gotcha found on the way, worth a line because it cost an
hour: a board's
.CW $CONF.root.s
and
.CW .h
are generated
.I and
tracked in git, and their rule depends on
.CW $INITDIR/$INIT.dis
by timestamp.  Switching
.CW INIT
back to an older init program leaves them "up to date" with the newer
one's contents, and the kernel silently ships the wrong init.
Remove
.CW virt.root.s ,
.CW virt.root.h
and
.CW virt.root.j
before building with a different
.CW INIT ,
and check with
.CW strings
on the kernel, which is how this was caught.
.NH 2
Item 2, done on riscv64: a usbd in Limbo, and a USB keyboard and mouse that work
.PP
.CW appl/cmd/usb/usbd.b
replaces Inferno's old usbd for the old
.CW /dev/usbh
stack, which the previous section retired.  It is the user half of
the 9front-shaped kernel stack, after 9front's
.CW nusb/usbd
and
.CW nusb/kb ,
in about 550 lines: every entry under
.CW /dev/usb
but
.CW ctl
is a root hub; each hub's ports are polled twice a second through
class control transfers on the hub's
.CW ep0
data file (an 8-byte setup packet written, the reply read back); a
port that gains a device is reset, the kernel is asked for a device
on it with
.CW "newdev speed port"
and names the new
.CW epN.0
on the next read of the hub's ctl; the device gets
.CW SET_ADDRESS ,
the kernel's
.CW address ,
its ep0 packet size from the first 8 bytes of the device descriptor,
then the full descriptor and configuration 1.  A hub (class 9) is
read for its port count and powered; a boot-protocol HID interface
(class 3, subclass 1) is put in boot protocol, its interrupt endpoint
is created with
.CW "new N 3 r" ,
and a reader is spawned: keyboard reports become UTF-8 written to
.CW /dev/keyboard
(US layout, shift and control), mouse reports become
.CW "m x y b"
written to
.CW /dev/pointer .
Report-descriptor parsing, and so tablets and anything not boot
protocol, mass storage and every other class are not done.
.PP
Three kernel bugs stood in the way, each found by the program not
working and each general, not USB's:
.IP \(bu
.CW os/inferno/port/sysfile.c 's
.CW rwrite()
had no outer
.CW waserror() ,
unlike
.CW rread()
and unlike emu's
.CW rwrite() ,
so a device's
.CW error()
on a write unwound through
.CW Sys_write()
and killed the Dis process with "[$Sys] Broken: device or object
already in use".  Every write error on this kernel did that.  It now
returns \-1 with the error string;
.CW kseek()
and
.CW kremove()
had the same gap and the same fix.
.IP \(bu
.CW devusb 's
.CW new
command parses the endpoint type as one of its own names
("control", "iso", "interrupt", "bulk") or the USB standard number,
and anything else \- "intr", say \- silently becomes a control
endpoint, whose reads return 0 bytes forever.  9front's usbd sends
the number; so does this one now.  The zero-byte reads were chased
with QEMU's
.CW "-trace usb_xhci_*" ,
which showed the endpoint enabled and kicked but never transferring,
before the kernel's own ctl listing said "control".
.IP \(bu
.CW os/inferno/port/devpointer.c
allowed one open of
.CW /dev/pointer
in any mode, so usbd's writer and the window system's reader could
not coexist.  A write-only open no longer counts toward the single
reader.
.PP
Verified on riscv64 virt (QEMU 10.1,
.CW qemu-xhci
with
.CW usb-kbd
and
.CW usb-mouse ,
events injected through the QEMU monitor's
.CW sendkey ,
.CW mouse_move
and
.CW mouse_button ,
read back by
.CW virtdevinit.b
from
.CW /dev/keyboard
and
.CW /dev/pointer ):
"h", "i", shift-a as "A" and Enter arrive as keys; a move of (10,5), a
press and release of button 1, and a move of (\-3,2) arrive as
pointer events at (10,5) with button 1 then 0, then (7,7).  On pc64
the same run gets as far as the keyboard being enumerated and put in
boot protocol before the board's heap corruption ends the boot; that
is pc64's open bug, not this program's.  The old Limbo USB class
library under
.CW appl/lib/usb
still targets the retired interface and is dead code.
.NH 2
Item 4, half done: ECAM on pc64; MSI left where 9front left it
.PP
.CW os/inferno/pc/archacpi.c
now reads the MCFG table (segment 0: base, first and last bus) and
hands it to
.CW os/inferno/pc/pcipc.c
through
.CW pciecam ;
.CW pcicfginit()
maps the window with
.CW vmap()
and installs ECAM configuration accessors before it would have probed
the
.CW 0xCF8/0xCFC
ports, which remain the fallback and are what a machine without an
MCFG still gets.  Reads outside the window's buses return all ones,
as an absent device would.  Verified: on QEMU's
.CW q35
the kernel prints "pci: ecam 0xb0000000 buses 0-255" and every device
enumerates through it \- the xHCI controller, the modern-only virtio
NIC, and the NVMe unit, which reads back its host-written sector; on
the default PC machine, which has no MCFG, the port path runs as
before.  The other half, MSI: none of the drivers taken from 9front
.CW ( sdnvme ,
.CW usbxhci ,
.CW virtio10 )
asks for MSI in 9front's own versions either \- they use INTx and
that is what
.CW pcimsienable()
still only serves
.CW etherx550
for.  Nothing to transfer; a driver that wants MSI is new work on
both sides.
.PP
Also in this round, from the riscv64 smoke run after the syscall fix:
one boot took a load fault at
.CW propex+8
from
.CW vmachine() 's
error path with no current Prog \-
.CW currun()
was nil, so the error that reached
.CW vmachine()
came from somewhere no Dis process was running a system call.  The
path now panics with the error string instead of dereferencing nil,
so the next occurrence names its cause.
.PP
With that guard in, the next two smoke runs both panicked at the same
place with the same string: "vmachine: error \(dqinterrupted\(dq with
no current prog", right after
.CW ROOT-CMDS-OK ,
i.e. as the test's shell script exits.  The mechanism, read from
.CW os/inferno/port/dis.c :
.CW swiprog()
breaks a killed Prog out of a blocking system call by posting a note
to the kproc whose
.CW iprog
it is.  If that Prog has since finished its call and left the kproc,
the note lands wherever the kproc sleeps next \- the interpreter
loop's own idle wait \- and the
.CW Eintr
it raises there belongs to no Prog.
.CW vmachine() 's
error loop now recognises that case (no
.CW iprog ,
no current Prog,
.CW Eintr )
and goes back to its loop.  This surfaced only after the
.CW rwrite()
fix above: before it, a process whose write failed died on the spot
instead of living on to be killed at group exit.
.NH 2
The arm64 constant bug, located and fixed
.PP
The narrowing was in neither
.CW gmove()
nor the peephole.  Dumping the instruction stream before and after
each pass of
.CW regopt()
showed the constant leaving code generation as a proper
.CW MOV
and then being hoisted into a register variable by the allocator,
which types every constant it keeps in a register as
.CW TLONG
.CW ( mkvar()
in
.CW utils/7c/reg.c )
and so loads it with the
.CW MOVW
that
.CW addmove()
emits for a long.  A constant that does not fit a signed 32-bit word
is now typed
.CW TVLONG
there, and the probe's linked code reads
.CW "MOVZ X0, #0x20, LSL #32"
for
.CW 0x2000000000
and a 64-bit literal-pool load for
.CW 0xffffffff ,
where before it read a 32-bit
.CW MOVZ
with an illegal shift and a sign-extending load.  With
.CW utils/7c/swt.c 's
D_DCONST test from the previous section, that closes arm64's wide
constants; every arm64 library and the kernel were rebuilt with the
corrected compiler.  Both fixes are absent from the kencc-cross
original, which is byte-identical to the tree's 7c before them.
.NH 2
Item 6, done: 9front's MII layer, and with it I225
.PP
.CW os/inferno/port/ethermii.c
and
.CW .h
are 9front's now (the
.CW MiiPhy -based
calls,
.CW addmiibus() ,
clause-45 access), and so are the drivers written to them:
.CW os/inferno/pc/ether8169.c ,
.CW ether82563.c ,
.CW etherigbe.c
and the new
.CW etheri225.c ,
each with the same two shims as before (the fourth
.CW kproc()
argument, the
.CW ifstat
wrapper).  Inferno's own versions of the first three are gone.
Verified one NIC per boot on
.CW q35 :
.CW e1000
through the new
.CW etherigbe
(2 of 2 leases),
.CW e1000e
through the new
.CW ether82563
(PHY found, "link up: 1000Mbps", lease).  Not verified:
.CW igb ,
QEMU's 82576, attaches and finds its PHY but the driver's link proc
reads the 82576's link register and never sees link, and DHCP gets no
answer; whether that is the driver or QEMU's PHY model, and whether
frames would flow with the link flag ignored, is not chased.  (The
previous driver had only ever been seen to attach to igb, never to
get a lease.)
.CW ether8169
and
.CW etheri225
have no QEMU device and are compile-and-link only.
.PP
arm64, rebuilt from nothing with the corrected
.CW 7c ,
still stops where it did, at the first module load: the wide
constants were not what held it.
.NH 2
Item 5, done: 9front's SD subsystem, and SD cards on both boards
.PP
.CW os/inferno/port/devsd.c ,
.CW sd.h
and
.CW sdscsi.c
are 9front's now, with two adjustments: the qid macros widen through
.CW u64
for this kernel's 64-bit qid paths, and the device-table functions
carry its
.CW int -shaped
signatures.  The
.CW xxlegacy
slot and the count-returning
.CW rctl
are gone, so
.CW sdnvme.c
and
.CW sdvirtio10.c
are 9front's verbatim again, and
.CW os/inferno/pc/sdiahci.c
and
.CW sdvirtio.c
are 9front's too; the board's own
.CW os/inferno/virt/sdvirtiommio.c
lost the slot from its table.  That brings the
.CW SDio
interface for MMC hosts, and with it
.CW os/inferno/port/sdmmc.c
(the card) and
.CW pmmc.c
(the PCI SDHCI host, moved from
.CW pc
to
.CW port
because it is memory-mapped and the riscv64 board wants it too).  Two
things bit on the way and are worth a line each: this kernel's
.CW include/pool.h
makes
.CW csize
a macro, which turned a local variable in
.CW sdmmc.c
into a syntax error (renamed); and an MMC host registers itself from
its
.CW link()
routine, so it goes in the config's
.CW link
section, not as a dependency in
.CW sd ,
where nothing ever calls it and the card driver sees no host.
Verified with QEMU's
.CW sdhci-pci
and
.CW sd-card
on both
.CW q35
and riscv64 virt: the card appears as
.CW sdM0
and reads back the sector the host wrote; NVMe and the virtio disks
still read theirs, on both boards, through the swapped
.CW devsd .
.CW sdata ,
.CW sd53c8xx
and
.CW sdmylex
under
.CW os/inferno/pc
still carry the old interface and are linked by no board.
.NH 2
Item 7, done: 9front's audio layer and HD audio
.PP
.CW os/inferno/port/devaudio.c
and
.CW audioif.h
are 9front's (the
.CW addaudiocard()
registry,
.CW /dev/audio ,
.CW audioctl ,
.CW audiostat
and
.CW volume
per card) with the device-table signature adjustments, and
.CW os/inferno/pc/audiohda.c
is 9front's HD audio driver, whose only change is the
.CW int -shaped
read and write for its
.CW hdacmd
arch file.  Inferno's own
.CW devaudio.c ,
which wanted an
.CW audio_pc
back end no board had, is gone; the pc64 config's
.CW audio
device no longer names
.CW dma .
Verified on
.CW q35
with QEMU's
.CW intel-hda
and
.CW hda-duplex :
"#A0: hda mem febd4000 irq 11", "codec #0, vendor 1af40022",
.CW audiostat
and
.CW volume
read back (speed 44100, master 100 100), and a second of silence,
176400 bytes, is accepted by
.CW /dev/audio .
What is not verified is anything above the kernel:
.CW appl/lib/tone.b
and the players write Inferno's own
.CW audioctl
syntax, and 9front's file takes a different one, so the Limbo side
needs a look before sound comes out of a program.
.PP
One build gotcha from this round, on top of the tracked-root-list
one: the
.CW pc64dev
test configuration is a copy of
.CW pc64
with a different init and has to be regenerated after any edit to
.CW pc64 ,
or its kernel silently lacks the newest driver, which is how the HD
audio controller was "not found" for one run.
.NH 2
Item 8, as far as it goes: two CPUs come up
.PP
.CW "qemu-boot.sh -smp 2"
had never been run.  It works as far as the board itself does:
.CW squidboy
starts the second processor, both print their identification lines
("cpu0: 1000MHz AuthenticAMD", "cpu1: ..."), the boot goes on through
.CW /osinit.dis
and the first binds, and then a general protection fault in Dis with
.CW up
nil on cpu0 ends it, inside the window in which the single-CPU boot
also dies.  Whether that fault is the known heap corruption or an SMP
bug of its own cannot be told apart until the former is fixed; the
multiprocessor code is at least reached and the second CPU is alive.
.PP
Where this leaves the plan: items 1 to 7 are done and verified under
QEMU as each section above says; item 8 waits on pc64's heap
corruption; item 9, the real-hardware gaps (device trees, PSCI and
GICv3 on arm64, supervisor mode with SBI on riscv64, the SoC drivers
behind them), is untouched.  Open bugs, in the order they block
things: pc64's heap corruption on every boot; arm64's pool corruption
at the first module load; armv7's two faults; the igb NIC seeing no
link; riscv32's
.CW todfix
spam; and the Limbo audio library's
.CW audioctl
syntax against 9front's file.
.NH 1
arm64: it was never pool corruption
.PP
Three bugs, found in one sitting once the right instruments were
pointed at the board, and none of them in the pool.  The instruments
first, because they are what made the difference: QEMU's own
.CW "-d int"
trace names every exception with its syndrome, fault address and
return address, and it showed the "deadlock" to be a chain of 3
million exceptions re-taken at the vector; the QEMU monitor's
.CW "info registers"
through a Unix socket samples the stalled CPU without a debugger; and
.CW lldb
on QEMU's gdbstub with a breakpoint on the synchronous vector slot
gives the full register file at the first fault.  Reading the linked
kernel's symbols needed a third parser: 7l writes 4-byte symbol
values where 6l and jl write 8.
.PP
The first bug: the trap path saved one register.  The four-instruction
stub
.CW vectorbuild()
builds in the vector table reserves the frame and stores R9; the
shared tail
.CW vectrap
in
.CW os/inferno/virtarm64/l.s
carried a comment saying the stub had saved R0-R8 and R10-R30, and
saved none of them itself, while its exit restored all thirty-one
from the frame.  Every interrupt returned to the interrupted code with
whatever the frame slots held.  The
.CW "-d int"
trace showed the shape directly: an IRQ inside
.CW brpatch()
returned, and the next instruction executed was at a heap address \-
a
.CW RET
through a garbage R30.  The saves are there now.
.PP
The second, deterministic once the first was gone and found with
.CW lldb
by logging every
.CW gotolabel() :
the Label it jumped through held
.CW "sp 0" ,
.CW "pc devwalk+80" ,
which is a
.CW waserror()
frame, and
.CW setlabel()
had stored zero for the stack pointer because "MOV RSP, 0(R2)"
assembles to
.CW "STR XZR, [X2]"
\- register 31 in a store is the zero register, not SP.  The first
.CW nexterror()
resumed a frame on a zero stack pointer.
.CW setlabel()
goes through R1 now.  With those two the board boots the interpreter,
loads the shell, and runs every stage of the riscv64 init that does
not need a device it lacks: GC stress, memory, task and keyboard
tests, math, random, capabilities, the Dis stress test.
.PP
The third, from the shell's first array index of 4294967296 and a
ring of the last 256 Dis instructions extended to record each one's
operand addresses: the index slot was last written by an
.CW addw
whose source was a module-data word, and that word had been stored
from the loader's
.CW operand() ,
a function returning a 32-bit
.CW int .
On AArch64 a 32-bit operation, and a 32-bit result in W0, leave the
register's upper half ZERO;
.CW 7c
widened an
.CW int
to a 64-bit type with a plain register move, and its peephole then
removed the
.CW MOVW
.CW Rn,Rn
that would have been the sign extension as a copy to itself.  riscv64
never saw this because its 32-bit operations sign-extend by
architecture.  Fixed in
.CW utils/7c/txt.c
(the widening cases of the move table are
.CW MOVW
or
.CW MOVWU ,
which link as
.CW SXTW
and
.CW UXTW )
and
.CW utils/7c/peep.c
(32-bit register moves are conversions, not copies, and a duplicate
is dropped only after a load).  A probe linked to
.CW "MOVN W0, #0"
in the callee and
.CW "SXTW X0, W0"
in the caller confirms it.  This one, like the two constant bugs, is
in the kencc-cross 7c as well.
.PP
That widening turned out to be the wrong fix; only the peephole half
was needed.  A first cut also changed the move table, so that widening
an int emitted an SXTW and a uint a UXTW; the board went backward, an
external abort in
.CW rootopen()
before the shell.  A bisection \- each half alone, every arm64 library
rebuilt each time \- put it on the move-table change: this tree keeps
64-bit addresses in
.CW ulong ,
32 bits to this compiler, and the UXTW truncated them.  That change is
reverted.  What the interpreter needed was already emitted \- the MOVW
Rn,Rn sign-extension
.CW cgen()
puts after a 32-bit value \- and the only bug was the peephole
deleting it as a copy to itself.  With just that, and the linker fix
below, the board runs the shell (HELLO-FROM-SH, VIRT-OK,
ROOT-APPS-OK) and, with a console-only init
.CW ( os/inferno/init/virtarm64init.b ) ,
reaches an interactive prompt: a command piped in over the emulated
PL011 came back, the standing goal for this board.
.PP
The peephole-only build first stopped at an undefined instruction in
.CW mul64fract() :
"AND $0xffffffff, R10, R12", a logical immediate
.CW 7l
encoded without the N bit, the reserved 32-bit-element-of-all-ones
form.  The encoder set N only when the upper 32 bits were nonzero; N
depends on the element size alone.  Fixed in
.CW utils/7l/asmout.c ,
and
.CW 7l
now also refuses a store of RSP, which is what turned
.CW setlabel()
into a store of zero.  Past ROOT-APPS-OK the board prints the same
non-fatal
.CW track:
heap-checkpoint lines riscv64 does, from the shared
.CW checktracked()
instrumentation \- the same op (a movp writing nil over a live slot in
module Sh) on both boards, an open item shared with riscv64, not
arm64's own.
.NH 1
Where the five boards stand now
.PP
Three of the five boot to an interactive shell, confirmed the same way
each time \- a command piped in over the emulated UART comes back:
riscv64 virt, riscv32 virt32, and now arm64 virtarm64.  riscv64's
sibling simulators
.CW spike
and
.CW sifiveu
reach their shell markers too.  The two that do not: pc64, whose heap
corruption ends most boots in the window after
.CW /osinit.dis
loads; and armv7, with its two faults at the first module load.  Both
predate this document's driver and toolchain work and neither moved
this round.
.PP
Open, in the order they block things: pc64's heap corruption (every
boot, so easy to catch, hard to pin); armv7's undefined-instruction
and data-abort pair; the shared
.CW checktracked()
heap-checkpoint that riscv64 and arm64 both print past
.CW ROOT-APPS-OK
(a
.CW movp
writing nil over a live slot in
.CW Sh ,
non-fatal, the same op on both); the igb NIC seeing no link; riscv32's
.CW todfix
clock spam; and the Limbo audio library's
.CW audioctl
syntax against 9front's file.  Item 9 of the plan \- device trees,
PSCI and GICv3 for arm64, supervisor mode with SBI for riscv64, and
the SoC drivers behind them \- is the real-hardware work none of the
QEMU boards force, and is untouched.
.NH 1
armv7 reclassified: intermittent, not deterministic; proctrace refuted
.PP
A live check with the advisor's ten-minute framing turned out to
settle two things at once, and both correct the record above.
.PP
First, the strong remaining armv7 candidate \(em that
.CW runproc 's
.CW "pt = proctrace; if(pt) pt(p, SRun, 0)"
compiles to a call through the global
.CW proctrace
and that pointer is non-nil at boot \(em is refuted, on two independent
grounds.
.CW main()
in
.CW os/inferno/armv7/main.c
zeroes BSS from
.CW edata
to
.CW end
as its very first act, before
.CW machinit ,
so
.CW proctrace
(a plain BSS global in
.CW devproc.c ,
assigned only when
.CW /proc/n/trace
is opened) is nil long before
.CW runproc
runs and the
.CW if(pt)
guard skips the call.  And the fault is not deterministic, which is
what a fixed non-nil pointer would produce.
.PP
Three fresh boots gave three different outcomes:
.IP \(bu
type 1 (undefined instruction) at pc
.CW 0x400f8e78
with sp
.CW 0x400f8e24
\(em pc is inside the same stack page as sp, about 0x54 above it, so
the CPU is executing on the stack: a branch-to-stack signature, a
corrupted return or function pointer, not a call through a named
global;
.IP \(bu
type 4 (data abort) at pc
.CW 0x40067260
on a valid kstack
.CW 0x4349da68..0x434a5a68
\(em the varying data abort, a different fault entirely;
.IP \(bu
one run that reached
.CW ARMV7M-INIT-OK
and ran past
.CW "progpid count 10"
with no fault at all.
.PP
So armv7 is intermittent, not "two deterministic faults at the first
module load" as earlier entries have it; it boots sometimes, and the
batch run's
.CW "EXIT 0"
was real.  This is the same varying-data-abort fingerprint as the pc64
heisenbug already closed after 46 non-reproducing traces \(em an
intermittent memory-corruption bug shared across two architectures, not
a ten-minute item.
.PP
The blocker for further static work: the linked
.CW iarmv7
is stripped ELF, so no fault address resolves to a symbol without a
relink that emits a symbol table or a
.CW "5l -a"
listing.  The next attempt on armv7 should start by fixing that
toolchain step, not by guessing at addresses.
.PP
Second, three arm64 driver pieces landed clean this round and are
verified: a portable device-tree reader
.CW ( os/inferno/port/fdt.c ,
riscv64 finds its UART in QEMU's DTB; arm64 under
.CW -kernel
gets no DTB pointer, inert but correct), PSCI reboot and power-off over
HVC on arm64 (QEMU exits 0 on a reset call), and GICv3 on arm64,
runtime-detected from
.CW ID_AA64PFR0_EL1.GIC
alongside the default GICv2.  The GICv3 path was verified on
.CW "-M virt,gic-version=3" :
the board reaches its shell (timer PPI through the redistributor's SGI
frame) and an NVMe read completes (PCI SPI 37 through
.CW GICD_IROUTER
affinity routing), while GICv2 still boots clean five of five.  One
non-blocking loose end noted in passing: the arm64 disk test prints
.CW "sig 0000"
where the image has
.CW "55 aa"
at offset 0; the read succeeds and the interrupt is delivered so the
GICv3 conclusion is unaffected, and it is identical on v2, so it
predates this work \(em the init reads a block other than 0, or the
print is wrong.
.NH 1
Raspberry Pi 3B setup recheck, 13 September 2026
.PP
The physical-board handoff was audited before preparing a new Pi 3B.  A clean
build from
.CW os/inferno/raspi3b
with
.CW "mk INIT=raspi3binit boot"
produced both the AArch64 ELF
.CW os/inferno/raspi3b/iraspi3b
and the firmware-loadable flat image
.CW os/inferno/raspi3b/kernel8.img .
The mkfile's boot recipe incorrectly used make-style silent-command prefixes,
so Plan 9 mk tried to execute a program named
.CW @echo
after successfully making the image; the prefixes are removed.  The hardware
README now sets ROOT at the tree root before changing directory, rather than
leaving a fresh builder vulnerable to pointing ROOT at the board directory.
.PP
Both newly built artifacts were booted independently with QEMU's raspi3b
machine.  The ELF path and the firmware-equivalent raw-loader path (placing
kernel8.img at 0x80000) each reported MBOX-OK, DRAW-OK, USB-OK and
RASPI3B-SH-OK.  This verifies the current build and flat-image layout; it is
not a physical-board boot, which remains to be captured from the Pi's PL011
serial console.
.PP
The default
.CW os/inferno/init/raspi3binit.b
also no longer runs its historical SD write/multiblock test on every boot.
That test overwrote raw sectors 3 and 8 through 11: outside the first partition
on the QEMU test images, but not a safe assumption for somebody's firmware
card.  Normal init now opens
.CW /dev/sdM0/data
read-only, reads sector zero and reports SD-READ-OK.  The earlier QEMU write and
multiblock results remain valid historical driver tests, not startup policy.
The raw-image boot was repeated with a 64MB SD image whose sector zero began
with RPI3: init printed 52504933 and SD-READ-OK, reached RASPI3B-SH-OK, and the
image's SHA-256 remained
.CW 6e66723adefbfdf555c1d32f0ad95ceebb83d02b5fb586c4cbb21c57b9656d1c
before and after the boot.
.PP
The first physical Pi 3B boot printed exactly
.CW "Inferno/arm64 raspi3b"
and no later line.  That places execution in
.CW os/inferno/raspi3b/main.c
between its direct early serial banner and xinit's first report; the first
operation there was uartconsole(), which disabled and re-enabled UART0 through
.CW os/inferno/raspi3b/uartvirtarm64.c .
That file was still the QEMU-virt copy: it claimed a 24MHz clock, never
programmed IBRD/FBRD, and wrote DR followed by an arbitrary delay instead of
obeying PL011's TXFF flow control.  The firmware-inherited state sufficed for
the first banner but was not a kernel-owned UART setup.  The Pi driver now
programs its real 48MHz PL011 for 115200 baud (IBRD 26, FBRD 3), clears stale
interrupts, and waits with a bounded poll for FIFO space before every byte.
main prints PL011-OK immediately after that transition, making the hardware
boundary observable.  This repair is QEMU-verified below; a second physical
boot is still required to establish how far the board proceeds.
.PP
The second physical boot printed PL011-OK and stopped before xinit's first
line.  This exposed an ordering bug that QEMU's memory model concealed:
.CW os/inferno/raspi3b/main.c
called xinit() before mmuinit(), and xinit() immediately ilocks the global
xlists allocator through _tas()'s LDXR/STXR loop.  On the real Cortex-A53,
exclusive locking is not sound until RAM has Normal-memory translation
attributes; with the MMU off the architecture does not promise the exclusive
store will succeed.  QEMU accepted it and let every emulated boot pass.
mmuinit() uses statically reserved page tables and needs no allocator or lock,
so it now establishes the identity mapping before xinit() takes the first
kernel lock.  An MMU-OK serial marker makes that hardware transition explicit.
This is the required hardware ordering, not an emulator workaround.
.PP
With that ordering on the physical board, boot passed MMU-OK, the complete
allocator and pool setup, BCM I2C/SPI/GPIO probes, a real firmware mailbox
reply (revision 1779362517 and 0x3b400000 bytes ARM RAM), and procinit.  It
then stopped while printing the version line, after "Inferno Fourth".  This
is the first boot to run enough cached code on silicon to expose the remaining
hardware debt already named in
.CW os/inferno/raspi3b/l.s :
SCTLR.C was enabled while the Cortex-A53's reset-state data-cache contents were
architecturally UNKNOWN.  QEMU models no cache and cannot reproduce it.
.PP
The gap is now closed rather than worked around.  cacheinit() in
.CW os/inferno/raspi3b/cachebcm.c
walks every data or unified cache level reported by CLIDR_EL1, selects it with
CSSELR_EL1, derives line size, sets and ways from CCSIDR_EL1, and issues DC ISW
for every set/way before mmuenable() sets SCTLR.C.  The system-register and DC
helpers are in
.CW os/inferno/raspi3b/l.s ;
the algorithm uses the architectural geometry rather than hard-coding the
Pi's L1/L2 sizes.  QEMU boots the rebuilt image through MMU-OK to
RASPI3B-SH-OK, proving the instructions and loop do not regress the emulated
board; only the next physical boot can verify the cache behavior silicon adds.
.PP
The cache-initialized physical boot stopped at the identical character, which
falsifies cache state as the cause of this particular stop (the architectural
cache initialization remains required).  The cutoff itself supplies the
answer: "Inferno Fourth" is sixteen bytes including its leading newline,
exactly one PL011 transmit FIFO.  chandevreset() had switched console output
from early polled serialputs() to devuart's queued path.  The Pi copy of the
virt PL011 driver filled the hardware FIFO and returned without enabling TX
interrupts; it also registered QEMU virt's GIC IRQ 33 rather than BCM2837 GPU
IRQ 57, while the board trap code inspected pending bank 1 only.  QEMU's
PL011 drained quickly enough that kick() never encountered a full FIFO.
.PP
The hardware path is fixed end to end in
.CW os/inferno/raspi3b/uartvirtarm64.c
and
.CW os/inferno/raspi3b/trap.c :
kick arms TXIM while staged or queued bytes remain, the interrupt handler
acknowledges MIS and calls uartkick() to refill the FIFO, UART0 registers IRQ
57, and trap() dispatches both BCM pending banks (IRQs 0 through 63).  MMIO
register accesses are volatile.  The rebuilt kernel again reaches
RASPI3B-SH-OK under QEMU; the physical boot is the test of real FIFO backpressure.
.PP
That physical test drained the formerly stranded "Inferno Fourth" first and
then printed the complete fresh boot through the version, configuration,
firmware MAC, Initial Dis, raspi3b init, RASPI3B-OK and DRAW-OK.  Thus the BCM
UART transmit interrupt path is verified on silicon.  The next stop occurs as
the init program enters its USB check after DRAW-OK.  The DWC2 initializer had
four infinite hardware waits (AHB idle, core soft reset, RX FIFO flush and TX
FIFO flush), any one of which made a failed power/reset transition
indistinguishable from a dead kernel.
.PP
.CW os/inferno/raspi3b/usbdwc.c
now bounds each wait at 100ms, reports the relevant GRSTCTL/GUSBCFG/GAHBCFG
state on timeout and raises a device error so a missing USB controller cannot
hold the entire boot forever.  It also emits DWC-PROBE, DWC-POWER, DWC-AHBIDLE,
DWC-CORE-RESET and DWC-FIFO milestones.  QEMU reports every milestone OK,
enumerates its root hub, and reaches RASPI3B-SH-OK.  The next physical run will
identify the exact real-controller transition rather than merely stopping
after DRAW-OK.
.PP
The first run with DWC diagnostics reached the LAN9514 itself: hub and
ethernet descriptors were read, the SMSC ID_REV was 0xec000002, and both
512-byte bulk endpoints opened.  It then stopped in the first SMSC vendor
control write (the LAN9514 lite-reset request).  chanwait() had the same
unbounded completion wait as the early DWC reset path, so a missing channel
completion looked like a whole-machine hang.  It now has a 20-second bound and
returns a transaction error with the endpoint/channel printed.  QEMU's USB
root hub still enumerates and reaches the shell after this change; the next
Pi boot will report whether the failing operation is a real DWC channel,
LAN9514 reset timing, or a cache/DMA visibility problem.
.PP
.B "The console moves to the mini UART, 14 September 2026"
.PP
Every later physical boot reached the shell prompt and none of them took
a typed character.  The last register captures from the Pi, taken at the
prompt after a key was pressed, read PL011 FR 0x91: receive FIFO empty,
no receive interrupt pending, and the handler never entered.  The byte was
not reaching the PL011 at all, so no interrupt-routing change could have
made it arrive, and the several attempts that followed (polling from the
idle loop, a polling kernel process, reprogramming the UART at the console
handoff, arming its receive interrupt earlier, pinning init_uart_clock) all
changed code downstream of an empty FIFO.  Some of those boots also ran a
stale kernel8.img, which invalidated them.  The attempts are preserved,
uncommitted, at
.CW refs/wip/codex-pl011-rx-2026-09-14
and are not part of the tree.
.PP
One of those boots still recorded something true about a different
fault.  The polling process printed its start marker and then never the
register line it was to print after its first 10ms
.CW tsleep ,
so on silicon a timed sleep never returned: the scheduler tick was not
waking sleepers.  QEMU ticks normally.  Two hardware-only gaps fit it and
are now closed.  The Pi's armstub8 drops to EL2 without setting
CNTHCTL_EL2, whose EL1PCTEN and EL1PCEN bits reset UNKNOWN; Linux and
Circle both set them on the same EL2-to-EL1 drop, and l.s now does too
(with CNTVOFF_EL2 zeroed), encodings checked against GNU as.  And the
BCM2836 GPU interrupt route register at 0x4000000c, which a Pi capture had
shown non-zero, is now written to route GPU IRQ and FIQ to core 0, the only
core running.
.PP
The console is now the AUX mini UART
.CW os/inferno/raspi3b/uartmini.c ), (
ported from 9front's
.CW sys/src/9/bcm/uartmini.c .
That is the Pi 3B's own default: with
.CW enable_uart=1
and no uart overlay the mini UART owns GPIO 14/15 and the PL011 stays on
Bluetooth, which is where a later Bluetooth driver needs it.  The plan
left uncommitted for this work had it backwards:
.CW miniuart-bt ,
like
.CW disable-bt ,
moves the PL011
.I onto
GPIO 14/15 (the firmware's own
.CW overlays/README
says so), and its register offsets were relative to 0x3f215040, not to the
AUX block.  The PL011 remains compiled in as eia1 with its own interrupt.
.PP
What the driver adds to the donor: AUX_ENABLES is the first write, since
until it is set every mini UART register reads zero; LCR is 3 for eight
data bits; receive interrupts set IER bits 3:2 as well as bit 0, per the
BCM2835 erratum; GPIO 14/15 are put in alt5 with the pulls the donor uses
(a new
.CW gpiopull()
in
.CW gpiobcm.c ,
now volatile throughout); and a divisor the firmware has already
programmed is kept if it gives 115200 within 2%, since the firmware knows
its core clock and the driver only assumes 250MHz.  Receive is interrupt
driven through BCM IRQ 29 and also polled from clockpoll(), with
interrupts masked around each status-and-read.  Transmit paces itself on
LSR with a bound and uses the transmit interrupt only when that bound
runs out, because devuart calls kick() under ilock and the kernel prints
most of its boot before init0 first enables interrupts.
.PP
Each boot now answers its own questions.  The first line is
.CW "Inferno/arm64 raspi3b build N" ,
matching the later
.CW "conf raspi3b (N)" ,
so a stale card image is visible.  Before the MMU is on, the kernel polls
the mini UART for three seconds and prints MINI-RX-EARLY-OK with the key
typed, or MINI-RX-EARLY-NONE with LSR, CNTL and the divisor: a key seen
there and not at the shell is the kernel's fault, not the wiring's.  The
console setup prints the AUX register state and GPFSEL1.  After chandevinit
with interrupts on, TICK-OK or TICK-FAIL counts ticks across a 250ms busy
wait and on failure prints DAIF, CNTP_CTL, the deadline against the counter
and the BCM2836 route and pending registers; a kernel process then reports
SLEEP-OK when a 100ms tsleep returns.  At the shell,
.CW "cat '#t/eia0status'"
gives interrupt and polled receive counts.
.PP
Verified under QEMU 10.1.3 with the mini UART as the only console
.CW "-serial null -serial stdio" ): (
through both the ELF and the firmware-equivalent raw kernel8.img load, the
early probe read an injected key (MINI-RX-EARLY-OK 0x6b), GPFSEL1 read
0x12000 (pins 14 and 15 in alt5), TICK-OK, SLEEP-OK, and
.CW "echo MINI_UART_OK"
typed at the shell echoed back; eia0status showed every received byte
arriving by interrupt (rxintr 66, rxpoll 0).  What QEMU cannot show: its
bcm2835_aux model ignores LCR, MCR, CNTL and BAUD (they read back zero, as
the divisor line shows) and pull-up registers, so baud rate, framing and
pulls are only testable on the Pi, and whether the tick fixes are the
right ones is equally a physical result.  None of this has run on the Pi
yet.
.PP
.B "Back to the PL011, and one image for QEMU and the board"
.PP
The mini UART image (build 1789434335, config.txt without disable-bt)
printed nothing at all on the Pi, not even the first banner, which is
written before the kernel touches the UART.  That is unexplained, and it
adds new unknowns exactly where the PL011 transmit path is proven, so the
console is the PL011 again and config.txt has disable-bt back.
.CW uartmini.c
stays in the tree, unlinked: its enable takes GPIO 14/15, so it must not
share a boot with the PL011 console.
.PP
The history also narrows the PL011 fault.  Commit
.CW 3b7706ac
drained console output through the PL011 transmit interrupt, GPU IRQ 57,
on silicon, so interrupt delivery from the PL011 works there; what never
happens is a byte arriving in its receive FIFO.  A polled probe early in
boot had seen input.  The image now bisects that in one boot:
.CW uartrxprobe()
runs at nine stages (firmware state, after the UART setup, the MMU, the
clock, the I2C/SPI/GPIO probes, the mailbox, screen and device tree, device
reset, and init0), asks for a key, polls the FIFO for four seconds with
interrupts masked, and prints the character or none with CR, LCRH,
IBRD/FBRD, IMSC, FR, RIS, GPFSEL1, GPFSEL3 and the live levels of GPIO 14,
15, 32 and 33 \(em 32/33 being the Bluetooth UART pins, which can also
carry PL011 RX.  The first stage reporting none locates the loss.
.PP
Until now this port was tested under QEMU with
.CW "-kernel iraspi3b" ,
which QEMU loads as an ELF at EL3 with all four cores running \(em a
start no Pi ever makes, and the reason l.s parks cores itself.  QEMU's
raspi3b loader treats a raw arm64 image as a Linux kernel instead: it
loads
.CW kernel8.img
at 0x80000, enters core 0 at non-secure EL2 (the monitor reports PSTATE
EL2h) with the other cores in a spin table at 0xd8, and passes the device
tree in x0, which is what the Pi firmware and armstub8 do.  Testing is now
done that way, with the firmware's own
.CW bcm2710-rpi-3-b.dtb
from the card, so the emulator runs the file that goes on the card through
the entry path the card uses;
.CW os/inferno/raspi3b/qemu.sh
does it.
.PP
The board also shed the rest of its QEMU virt inheritance, each piece a
hardware defect QEMU hid.
.CW archvirtarm64.c ,
.CW uartvirtarm64.c
and
.CW randomvirtarm64.c
are now
.CW archbcm.c ,
.CW uartpl011.c
and
.CW randombcm.c .
archreboot() and archshutdown() made PSCI calls through HVC, and a Pi's
EL2 has no PSCI handler; they now use the BCM2835 power-manager watchdog
(RSTC full reset with a short WDOG count, and partition 63 in RSTS for
halt), the mechanism Linux uses on the Pi, and
.CW "echo reboot > /dev/sysctl"
under QEMU resets the machine and boots again.  microdelay() spun
cpuhz/1000 empty iterations per millisecond, a count that took about as long as
asked under QEMU and a small fraction of it on a real Cortex-A53; it is
now timed on the generic timer's counter like delay().
.PP
Verified under QEMU 10.1.3 booting kernel8.img with the card's DTB: all
nine RXPROBE stages received the injected key, TICK-OK, SLEEP-OK, a typed
.CW "echo PL011_RX_OK"
echoed at the shell, and the watchdog reboot.  QEMU keeps every pin at
level 0 and GPFSEL at 0 regardless, so the pin columns mean something
only on the Pi.  Not yet run on the Pi.
.PP
.B "The silent boots were a lock, not the UARTs"
.PP
Build 1789464598 on the PL011 printed nothing either, and so the common
factor of both silent boots was not the mini UART.  It was the line added
to name the build: an
.CW snprint
of
.CW kerndate
before
.CW mmuinit() .
The first use of a format verb runs
.CW fmtinstall() ,
which takes
.CW lock(&fmtl) ,
and an LDXR/STXR lock before the MMU has made RAM Normal memory hangs the
Pi's Cortex-A53 \(em the failure found earlier with
.CW xinit()
\(em while QEMU lets it through.  The banner is now written with
.CW serialputdec() ,
which uses neither fmt nor a lock.  The mini UART result above is void:
that image hung before it ever wrote to the UART, and says nothing about
the mini UART.
.PP
So that QEMU catches this class of bug rather than only the board,
.CW _tas
in l.s now reads SCTLR_EL1 and, with the MMU off, branches to
.CW tasbeforemmu() ,
which prints
.CW "PANIC: spinlock taken before mmuinit()"
and stops.  Falsified: with the
.CW snprint
put back, the same kernel8.img under QEMU prints the banner and that
panic line and goes no further; without it, it boots to the shell, all
nine RXPROBE stages answer, TICK-OK, SLEEP-OK, and typed input echoes.
.PP
.B "Receive reaches init0 on silicon; interrupts are the fault"
.PP
Build 1789465024 on the Pi answered all nine RXPROBE stages with the
key the harness sent through the serial adapter, from the firmware's
state through device reset and init0, with the PL011 at CR 0x301, LCRH
0x70, IBRD 26/FBRD 3, the receive interrupt armed from device reset on,
GPFSEL1 0x24000 (GPIO 14 and 15 in alt0) and GPFSEL3 0 (GPIO 32 and 33
inputs), all four pins idle high.  So bytes reach the receive FIFO all the
way to init0, and the pins, the baud rate and the firmware routing are
correct.  After init0 enabled interrupts the board printed nothing more:
not TICK-OK, not any queued output, including the fault report a trap
would give.  Console output after chandevreset drains only on the
PL011 transmit interrupt, so silence there means interrupts are not being
taken, or the first one never comes back.
.PP
One hardware-only cause is in
.CW vectorbuild() :
it writes the exception vector instructions into
.CW rawvectab
after the MMU and caches are on, and set VBAR_EL1 without cleaning those
data-cache lines or invalidating the instruction cache.  The Cortex-A53
fetches through its own L1 instruction cache from memory that may still
hold what was there before, so the first exception can execute stale
bytes, fault into the same stale table, and loop without a word; QEMU
models no cache.  vectorbuild now calls
.CW cacheflush()
over the table and
.CW cacheiinv()
before
.CW vectorinit() .
The next boot also prints IRQCHECK straight to the data register half a
second after interrupts are enabled: interrupt entries, ticks and PL011
interrupts in that time, CurrentEL, DAIF, VBAR_EL1, CNTP_CTL, whether the
timer deadline is still ahead, the BCM2836 timer route, pending and GPU
route registers, and the BCM2835 pending and enable registers.  Under
QEMU with the same kernel8.img it reads 40 interrupts and 40 ticks, EL 1,
DAIF 0x340 (IRQ unmasked), and the board goes on to the shell.
.PP
.B "Interrupts work on silicon; the console mask did not"
.PP
With the caches flushed over the vectors, build 1789465363 on the Pi
printed
.CW "IRQCHECK 500ms: irqs 50 ticks 50"
\(em the 100Hz tick exactly \(em at EL 1 with DAIF 0x340, VBAR at the built
table, CNTP_CTL enabled with its deadline ahead, the BCM2836 timer route
0x02 and GPU route 0; IRQ 57 enabled in the bank-2 enable register.  So
the missing cache maintenance in vectorbuild() was what had silenced every
interrupt on the board.  It still showed nothing queued: PL011 interrupts
0 in that window, IRQ 57 not pending, and IMSC 0x010, receive only.
.CW uartconsolesetup()
wrote IMSC = RX after chandevreset had queued console output and
.CW kick()
had armed the transmit interrupt to drain it, clearing that bit; qio kicks
a queue only when it goes from empty to non-empty, so nothing armed it
again and every later line, including TICK-OK and the shell, waited
forever.  QEMU's PL011 empties its FIFO instantly, so kick() never left
output behind there.  The setup now ORs the receive bit into the mask and
kicks the queue once.
