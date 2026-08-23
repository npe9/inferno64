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
A kernel tree here is
.CW port ,
then an architecture, then a board:
.IP
.nf
port/
  amd64/
    pc          the PC, as it already was
  riscv64/
    virt        QEMU -M virt
    sifiveu     SiFive Unleashed
    spike       the Spike simulator
  arm64/
    bcm2712     Raspberry Pi 5
    jh7110      VisionFive 2
.fi
.PP
rather than a directory per board beside the portable code.  What
differs between two boards of one architecture is mostly a device tree,
not a kernel; the architecture directory holds what they share \- the
UART, the interrupt controller, the timer, the PCI window \- and a board
directory holds what only it has.
.PP
.CW riscv64
is that shape already:
.CW os/inferno/riscv64
holds the SiFive UART, HTIF, the GEM ethernet and the PCI ECAM window,
and
.CW virt ,
.CW sifiveu
and
.CW spike
sit inside it.
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
rather than by what is nearest to hand.  The stars are how much each is
worth having, not how hard it is.
.PP
.TS
box tab(;);
lb lb lb lb
l l l l.
architecture;machine;what it is;worth
_
x86-64;q35;a modern-ish PC;\(**\(**\(**\(**\(**
x86-64;microvm;the minimal paravirtual machine;\(**\(**\(**\(**\(**
x86-64;pc/i440fx;an old PC;\(**\(**
AArch64;virt;the generic virtual ARM computer;\(**\(**\(**\(**\(**
AArch64;sbsa-ref;a standards-based ARM server;\(**\(**\(**\(**\(**
AArch64;raspi4b;Raspberry Pi 4;\(**\(**\(**\(**
AArch64;xlnx-zcu102;Xilinx Zynq UltraScale+;\(**\(**\(**
AArch64;amd-versal-virt;AMD Versal;\(**\(**\(**\(**
RISC-V64;virt;the generic RISC-V computer;\(**\(**\(**\(**\(**
RISC-V64;sifive_u;SiFive Unmatched;\(**\(**\(**\(**
RISC-V64;icicle;the Microchip Icicle family, a real SoC;\(**\(**\(**\(**
.TE
.PP
Every one of them is a machine QEMU emulates, so every one of them can
be brought up and kept up without hardware on a desk; the four that are
also real parts \-
.CW raspi4b ,
.CW xlnx-zcu102 ,
.CW amd-versal-virt
and the Icicle \- are the ones where the emulator is a stepping stone
rather than the destination.  Nothing on this list is built yet beyond
.CW riscv64/virt ;
it is the plan, not the state.
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
