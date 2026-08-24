.TL
Inferno on a Cortex-M
.AU
Inferno RIO
24 August 2026
.NH 1
What this is
.PP
Three machine directories under
.CW os/inferno
for ARMv7-M cores, and the repairs to the Thumb toolchain that having
any of them meant:
.IP
.nf
armv7m/     the core: vectors, exceptions, spl, SysTick, no MMU
mps2/       ARM MPS2 with the AN500 image \- a Cortex-M7 in QEMU
teensy41/   Teensy 4.1, an NXP i.MX RT1062
nucleof303/ ST NUCLEO-F303RE, an STM32F303RE
.fi
.PP
.CW armv7m
is the shared family directory, the same idea as
.CW riscv
beside the three RISC-V boards: source and headers, no mkfile, reached
by each board's mkfile.  What a board directory holds is what only that
board has \- its memory map, its clock tree, its console.
.NH 1
What is proved and what is not
.PP
.B mps2
boots.  QEMU models the AN500 image, which is a Cortex-M7, so everything
in
.CW armv7m
is executed there: the vector table the core reads its stack pointer and
reset address out of, the exception path that builds a
.CW Ureg
from the eight words the core pushes and the eight it does not, interrupt
masking on
.CW PRIMASK ,
the exclusive monitor,
.CW coherence ,
SysTick, and the copy of the data segment out of the image into where it
was linked.  It reaches an interactive Inferno shell:
.CW ls
walks the embedded root,
.CW ps
lists itself, and
.CW echo
comes back.
.PP
.B teensy41
does not.  There is no emulator for an i.MX RT1062, and this was written
without one of the boards.  What can be said is that it builds, that the
image
.CW tools/aout2imxrt
wraps it in has the boot headers where chapter 9 of the reference manual
says they go and holds the values that manual gives for a serial NOR part
in quad mode, and that the code in it is the same
.CW armv7m
core that runs under QEMU.  What is only written down is the board:
the ARM PLL and its divider, the FlexRAM split, the pin multiplexing and
the LPUART.  The first things to check on a real board are, in order:
whether the ROM accepts the FlexSPI configuration block at all, whether
anything comes out of pin 1 at 115200, and whether the clock the LPUART
divides really is the 80MHz this assumes.
.PP
.B nucleof303
does not fit.  That is a measurement rather than an opinion: with the
smallest configuration that still links \- no root file system, no Limbo,
no ip \- the text is 259416 bytes, which the 512K of flash holds, and the
data and bss together are 88928, which the 80K of RAM does not, before
any heap at all.  Its floating point is the second wall: a Cortex-M4 has
FPv4-SP and no double precision, and
.CW utils/tl/thumb.c
gives every
.CW F
register a
.CW D
register, so
.CW "tl -M -F"
names every function that would fault.  The board support is here
because it is what a Cortex-M4 with more memory would want and because
the numbers are worth writing down;
.CW os/inferno/nucleof303/NOTE
has them.
.NH 1
The toolchain
.PP
An ARMv7-M core has no ARM state.  Every instruction in a kernel for one
is a Thumb instruction, and this tree's Thumb toolchain \- marked
obsolete in
.CW utils/mkfile ,
and last aimed at a big-endian ARM with an FPA coprocessor \- did not
know that.
.PP
.CW utils/tl
installed itself over
.CW 5l ,
which is why the mkfiles that name it say
.CW LD=5l ;
it installs as
.CW tl
now.  It takes
.CW -M ,
which says the target is an ARMv7-M core.  Under
.CW -M
the two ways it could emit ARM code become diagnostics: the interworking
veneers, and the fall back to ARM that
.CW obj.c:puntfp()
took for any function containing floating point.
.PP
Floating point instead became VFP.
.CW utils/tc
emits the FPA instructions the ARM port used, and the mapping is made in
.CW utils/tl/thumb.c :
every
.CW F
register is a
.CW D
register holding a double, and single precision appears only at the
memory boundary, where
.CW MOVF
widens on the way in and rounds on the way out.  That is what the FPA
did, so arithmetic on a C
.CW float
is done in double there as it was there.
.PP
.CW utils/5a
did not mark an assembled
.CW TEXT
as Thumb, so the linker read every hand-written function as ARM.  And
there was no way to write down an instruction the assembler has no
mnemonic for and that is only two bytes long, which
.CW MRS ,
.CW MSR ,
.CW CPSID ,
the barriers and
.CW LDREX
all are:
.CW HWORD
is a halfword of raw text beside
.CW WORD ,
and
.CW os/inferno/armv7m/armv7m.h
spells the ARMv7-M encodings out in terms of it.
.PP
One older bug turned up on the way.
.CW utils/tc
emitted the two words of a
.CW vlong
constant high word first, which is right only on a big-endian ARM.
.CW utils/5c
has always had the endianness test;
.CW tc
has the same one now.  Without it a
.CW Qid
path in a device table came out with its halves swapped, and the file it
named read thirteen bytes of the wrong thing.
.NH 1
The width of a Dis word
.PP
.CW include/isa.h
makes
.CW IBY2WD
follow the size of a pointer.  That is right for the interpreter, which
is compiled for the machine it will run on, and wrong for everything that
produces what the interpreter reads:
.CW limbo
is a host program, and the tables
.CW libinterp
generates from the module definitions were generated once and used by
every target.  So every
.CW .dis
in the tree, and every builtin frame size and pointer map in
.CW libinterp ,
was eight bytes to the word.
.PP
.CW limbo
takes
.CW -W
now, the generated headers are built one set per width into
.CW libinterp/w4
and
.CW libinterp/w8 ,
and the Limbo userland has a tree per width \-
.CW DISROOT
says which.  A board's configuration names the tree it wants, which the
two-column form of the
.CW root
section already allowed:
.IP
.nf
/dis/sh.dis	/dis32/sh.dis
.fi
.PP
Two kinds of generated header are per-width, not one.
.CW "limbo -t"
writes the frame size and pointer map of each builtin, which is the
obvious one.
.CW "limbo -a"
writes the C shape of a frame, which holds the interpreter's temporaries
at the bottom of it and so is four words narrower at 32 bits; that one is
what made
.CW Sys->print
read its format string from the wrong place.
.NH 1
What a Cortex-M board does not have
.PP
There is no JIT.
.CW libinterp/comp-thumb.c
says it could not compile a module, which is what the loader does with
one the JIT refuses, so the interpreter runs everything.  A compiler here
would also have to find somewhere to put what it generated, and on these
boards that is the scarcest thing there is.
.PP
There is no MMU.  The most an ARMv7-M core has is an MPU, which protects
but does not translate, and Inferno's processes are kernel threads in one
address space, so
.CW os/inferno/armv7m/mmu.c
is empty.
.PP
Floating point state is not saved between processes, and no interrupt
handler may use floating point.
.CW FPCCR.ASPEN
and
.CW FPCCR.LSPEN
are both turned off in
.CW os/inferno/armv7m/fpu.c ,
so the core never pushes a floating point frame on the way into an
exception, which is what lets
.CW l.s
assume the small one.  The reasoning is written out there.
.PP
Soft timers are serviced at the HZ tick.  SysTick is a periodic counter
with no comparator, so unlike the RISC-V boards there is no way to ask
for an interrupt at an arbitrary future time; that puts a floor of one
tick on
.CW tsleep .
