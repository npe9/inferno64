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
What stops it is
.CW libinterp/heap.c ,
which uses the compiler's atomic builtins;
.CW jc
has none.  The LLP64 branch has a version of that file that does not,
and taking it is the next piece of work.
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
