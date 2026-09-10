.TL
Inferno on modern hardware: a survey of the platforms
.AU
.PP
This is a survey of the machine classes an operating system can be
asked to run on in 2026, and of what each one would cost this tree to
support
.I natively \c
\(em
.CW os/inferno ,
the kernel with the Dis interpreter inside it, owning the machine,
not
.CW emu
hosted on somebody else's kernel.  It is a companion to
.CW doc/inferno-cloud-plan.ms ,
which covers one class (the rented amd64 machine) in detail, and to
.CW doc/inferno-ports.ms ,
which is the record of how the existing boards were brought up.
.PP
Every statement here about this tree was produced by running the
build or the boot on this host and reading the output; the commands
and what they printed are given.  Every statement about hardware this
host does not have is marked as taken from published documentation
rather than measured.
.NH 1
The first question is not drivers, it is the compiler
.PP
Inferno is compiled by the Plan 9 compiler suite in
.CW utils ,
one letter per architecture, and a board can only exist for an
architecture that has one.  From
.CW mkfiles/mkfile-Inferno-* ,
the tree's targets and their compilers are:
.DS L
.CW
386        8       amd64      6
arm        5       aarch64    7
thumb      t       mips       v
power      q       sparc      k
riscv32    z       riscv64    j
spim       0
.R
.DE
.PP
That table partitions the modern world in two, and the partition
matters more than any driver question, because everything on the
wrong side of it needs a code generator, a linker and an assembler
written before a single line of board code can be compiled.
.IP "\fIHas a compiler\fP" 4
amd64, aarch64, riscv64, riscv32, arm, thumb (Cortex\-M), 386.  That
covers the PC, the server, the cloud instance, the arm64 server, the
single-board computer, the RISC\-V board and the microcontroller \(em
which is to say, nearly every machine anyone would now choose.
.IP "\fIHas no compiler\fP" 4
ppc64/ppc64le, LoongArch, s390x, and any 64-bit MIPS.  Note that
.CW power
is
.I 32
bit POWER: a POWER9 or POWER10 workstation is not a matter of
recompiling
.CW q ,
it is a new back end.  These are the expensive ones, and they are
expensive before the hardware question is even reached.
.PP
Four of the compilers that exist have no board using them:
.CW v
(mips),
.CW k
(sparc),
.CW q
(power32) and
.CW 0
(spim) are toolchain targets with no
.CW os/inferno
directory behind them.  They are not modern platforms and are listed
only so the table is not read as a list of supported machines.
.NH 1
What the tree boots today
.PP
There are nineteen directories under
.CW os/inferno
with an
.CW mkfile ;
.CW boot ,
.CW init
and
.CW port
are not boards, leaving sixteen boards plus
.CW armv7m ,
which is a shared Cortex\-M source directory that
.CW mps2
and
.CW teensy41
compile out of rather than a board of its own.
.PP
Two things had to be fixed before the survey could even be taken, and
both were tree bugs rather than board bugs.
.IP 1. 4
.CW lib/emptydirs ,
the list the root
.CW mkfile 's
.CW mkdirs
target creates, was missing
.CW Inferno/aarch64/{bin,include,lib} ,
.CW Inferno/riscv32/* ,
.CW Inferno/riscv64/* ,
.CW Inferno/spim/include ,
.CW Inferno/thumb/include
and every
.CW MacOSX/arm64
directory.  Without them
.CW iar
fails with
.CW "cannot create ... No such file or directory"
while still reporting each member added, so
.CW mk
stops at a library that looks like it was built.  Every aarch64 and
riscv64 board failed this way.  The entries are now in the file.
.IP 2. 4
A 32-bit board takes its Limbo from
.CW /dis32 ,
a second Dis tree built with
.CW DISROOT=dis32
.CW DISWORD=4
beside the 64-bit
.CW /dis
(see the comment in
.CW mkconfig ).
That tree did not exist in this worktree, so
.CW armv7 ,
.CW virt32 ,
.CW virt32s ,
.CW mps2
and
.CW teensy41
all stopped at
.CW "don't know how to make .../dis32/basename.dis" .
Building it needs its directory structure to exist first \(em the
.CW install
rules copy, they do not
.CW mkdir
\(em and
.CW lib/emptydirs
listed the seventy
.CW dis/ ...
directories but no
.CW dis32
at all.  The
.CW dis32
mirror of those entries is now in the file, so
.CW "mk mkdirs"
makes them; after that,
.DS L
.CW
cd appl/lib  && mk DISROOT=dis32 DISWORD=4 install
cd appl/cmd  && mk DISROOT=dis32 DISWORD=4 install
.R
.DE
produces 173 commands and 162 libraries and all five boards build.
Note that
.CW "mk DISROOT=dis32 DISWORD=4 install"
in
.CW appl
itself still stops at
.CW appl/danby
with
.CW "don't know how to make 'SYSMODULES'" ,
which is a separate and unrelated breakage in that subdirectory;
the two lines above go round it.
.PP
With those two fixed, this is the state of every board, built with
.CW mk
in its own directory and booted under this host's QEMU 9.x with a
25-second timeout:
.TS
allbox;
lb lb lb lb lb
l l l l l.
board	arch	cc	builds	boot result
pc64	amd64	6	yes	interactive shell, 1 boot in 24
pc	386	8	\fBno\fP	\(em
virt	riscv64	j	yes	shell, GC stress passed
virts	riscv64	j	yes	shell, GC stress passed
spike	riscv64	j	yes	shell
sifiveu	riscv64	j	yes	shell, DHCP lease
shakti	riscv64	j	yes	no QEMU machine
mangopi	riscv64	j	yes	no QEMU machine
virtarm64	aarch64	7	yes	prompt, NVMe over PCIe
raspi3b	aarch64	7	yes	shell, USB root hub
virt32	riscv32	z	yes	interactive prompt
virt32s	riscv32	z	yes	interactive prompt
armv7	arm	5	yes	\fBpanic: trap\fP in module load
mps2	thumb	t	yes	interactive prompt
teensy41	thumb	t	yes	no QEMU machine
nucleof303	thumb	t	yes	no QEMU machine
.TE
.PP
The commands, so the table can be reproduced:
.DS L
.CW
qemu-system-riscv64 -M virt -m 256 -nographic -bios none -kernel ivirt
qemu-system-riscv64 -M virt -m 256 -nographic -kernel ivirts
qemu-system-riscv64 -M spike -m 256 -nographic -bios none -kernel ispike
qemu-system-riscv64 -M sifive_u -nographic -bios none -kernel isifiveu
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256 -nographic \e
	-kernel ivirtarm64
qemu-system-aarch64 -M raspi3b -m 1G -nographic -kernel iraspi3b
qemu-system-riscv32 -M virt -m 256 -nographic -bios none -kernel ivirt32
qemu-system-riscv32 -M virt -m 256 -nographic -kernel ivirt32s
qemu-system-arm -M virt -cpu cortex-a15 -m 256 -nographic -kernel iarmv7
qemu-system-arm -M mps2-an500 -nographic -kernel imps2
.R
.DE
.PP
Four results in that table deserve their own sentence.
.IP "\f(CWsifiveu\fP" 4
prints
.CW ip=10.0.2.15
.CW ipmask=255.255.255.0
.CW ipgw=10.0.2.2
and
.CW DHCP-OK
before its shell.  A RISC\-V board with a working network stack is
further along than the survey's readers may expect.
.IP "\f(CWraspi3b\fP" 4
prints
.CW roothub
.CW ports
.CW 1
.CW dwcotg
and lists an enabled control endpoint, so its DesignWare USB host
controller and the Limbo
.CW usbd
in
.CW appl/cmd/usb/usbd.b
are both live under
.CW "-M raspi3b" .
.IP "\f(CWarmv7\fP" 4
builds and starts, allocates its pools, reaches
.CW "Initial Dis: \(fm/osinit.dis\(fm" ,
and then dies:
.CW "trap type 4 psr 0x00000153 pc 0x40070914" ,
.CW "panic: trap" ,
with the heap tracker reporting bad values at
.CW readmod:after-parsemod
before it.  32-bit ARM is the one architecture in the tree with a
compiler, a board and no working boot.
.IP "\f(CWpc\fP" 4
does not build in any of its four configurations
.CW pc , (
.CW pcdisk ,
.CW pc4e ,
.CW pix ),
and all four fail the same way underneath:
.DS L
.CW
\&../port/../port/portdat.h:609 dat.h:151
\&../port/portclock.c:4 syntax error, last name: FPU
.R
.DE
.CW os/inferno/port/portdat.h
gives
.CW Proc
a member
.CW "FPU fpu" ,
and
.CW os/inferno/pc64/dat.h
supplies the type
.CW "typedef struct FPsave FPU" ) (
while
.CW os/inferno/pc/dat.h
declares only
.CW PFPU
and never
.CW FPU ,
so every
.CW ../port
source failed to compile.  Each configuration then has a gap of its
own on top of that \(em
.CW pc
wanted a
.CW bootp.8
from an
.CW ip
source no longer in the tree,
.CW pcdisk
a
.CW $ROOT/chan ,
.CW pc4e
an
.CW ../init/i4e.dis ,
.CW pix
an
.CW ../init/soeinit.dis
\(em but the
.CW FPU
mismatch was under all of them.
.PP
Five of those were fixed this round, and they show what the board
actually is:
.CW os/inferno/pc/dat.h
gained
.CW "typedef union FPsave FPU"
beside its
.CW PFPU ,
the way
.CW os/inferno/pc64/dat.h
has it; its
.CW active.machs
became the
.CW "char [MAXMACH]"
array the portable code now indexes rather than the old
.CW int
bitmap, with
.CW os/inferno/pc/main.c
and
.CW os/inferno/pc/trap.c
following;
.CW os/inferno/pc/fns.h
lost its own copy of
.CW waserror() ,
which
.CW os/inferno/port/portfns.h
defines now; the
.CW ip
and
.CW ether
lines of
.CW os/inferno/pc/pc
stopped naming
.CW bootp ,
.CW iprouter
and
.CW netaux ,
none of which are in the tree; and
.CW os/inferno/pc/mkfile
stopped compiling
.CW i8250.c ,
which the configuration's
.CW uarti8250
supersedes and whose
.CW Uart
collides with the portable one.
.PP
It still does not build.  It now stops at
.CW "i8259.c:199 not a member of struct/union: enable" ,
and the reason is the shape of the directory rather than any one
bug:
.CW os/inferno/pc
is shared between two boards, its drivers were modernised for
.CW pc64 ,
and the 386 board's own core files were not.
.CW os/inferno/pc/io.h 's
.CW Vctl
still has the old
.CW "next, name, isintr, irq, tbdf, isr, eoi, f, a" ,
where
.CW os/inferno/pc64/io.h 's
has
.CW enable ,
.CW disable ,
.CW aux ,
.CW vno ,
.CW cpu
and
.CW local
as well, and
.CW i8259.c
is written to the second.  Behind that sit
.CW trap.c ,
.CW mmu.c ,
.CW memory.c
and
.CW l.s ,
none of which have moved since before the 9front drivers came in.
Reviving the board is bringing those five files up to
.CW pc64 's
shape, not fixing an error.  The 386 target otherwise survives as the
.CW 8
toolchain
.CW os/inferno/boot/pc 's (
.CW mbr
and
.CW pbs
link today) and as
.CW os/inferno/pc ,
the driver directory
.CW pc64
compiles out of \(em not as a runnable board.
.NH 1
The pieces that are missing everywhere
.PP
Before the platforms one at a time, the costs that are not per
platform.  These are what make a second board on a familiar
architecture cheap and a first board on an unfamiliar one dear.
.NH 2
The heap fault
.PP
This section used to say that the bug taxed every entry in the survey
and that no fix for it should ever be believed on a boot count.  Both
halves are now settled, and in opposite directions.
.PP
It was not architecture-independent.  It was four instructions in
.CW os/inferno/pc64/l.s 's
interrupt entry, which built
.CW Ureg.ds
and
.CW Ureg.es
using
.CW AX
as scratch
.I before
.CW "PUSHQ AX"
saved the interrupted code's
.CW AX ;
.CW MOVW
from a segment register assembles to the 32-bit form, which
zero-extends, so every interrupt handed the interrupted code back an
.CW AX
holding the
.CW DS
selector, which is
.CW 0
here.  Section 6 of
.CW doc/inferno-cloud-plan.ms
has the whole account.  No other board in this survey shares that
file.
.PP
And it was not found on a boot count.  It was found by
.CW os/inferno/pc64/regtorture.s ,
which loads twelve registers with distinct values, spins comparing
them, and says which one changes:
.CW AX ,
to
.CW 0 ,
with interrupts on and never with them off.  That is a direct
measurement of the property, and it still holds \(em thirty
consecutive
.CW pc64
boots now reach a shell with no capture and no panic, where the
measurements before the fix were one in twenty-four, nine in twelve,
eight in twelve, ten in twenty-five and eight in thirteen, dying in
eight different ways (page fault, general protection violation, a
failed module load,
.CW piperead ,
invalid opcode,
.CW "failed to make fd" ,
heap exhaustion,
.CW "decref: bad r" ).
The old warning stands for the boot counts alone: they moved when
unrelated code moved, which is why they were never the evidence.
.NH 2
One processor
.PP
Only
.CW pc
.CW MAXMACH=8 ) (
and
.CW pc64
.CW MAXMACH=128 ) (
are configured for more than one processor.  Every other board in the
tree \(em every arm64, riscv64, riscv32, arm and thumb board \(em has
.CW "#define MAXMACH 1"
in its
.CW mem.h
and no code to release a second core.  The arm64 server parts these
platforms are built from are sold with core counts in the tens to
the low hundreds (the vendors' published specifications); a first
port would use one of them.  That is survivable for a bring-up and not survivable for a
claim of support, and it is the same work on every arm64 board (PSCI
.CW CPU_ON )
and the same work again on every RISC\-V board (SBI HSM, or the
spin-table the older ones use).  On
.CW pc64
the AP path exists and
.CW "-smp 2"
brings
.CW cpu1
up; that was blocked on the heap fault of section 3.1, which is now
fixed, and has not been re-measured since.
.NH 2
Device trees, and how far they already go
.PP
.CW os/inferno/port/fdt.c
is a portable flattened-device-tree reader: a header parse, a token
walk over
.CW "BEGINNODE / ENDNODE / PROP" ,
a
.CW reg
decoder that honours
.CW #address-cells
and
.CW #size-cells ,
and two lookups by
.CW compatible
string,
.CW fdtreg()
and
.CW fdtregmin() .
It is not a plan; it is in use.
.CW os/inferno/virt/main.c ,
.CW virts ,
.CW virt32 ,
.CW virt32s
and
.CW shakti
call
.CW fdtinit()
on the DTB the firmware leaves in
.CW a1
and then locate their PLIC, their
.CW ns16550a
UART and their
.CW virtio,mmio
window from it instead of from constants;
.CW os/inferno/raspi3b/main.c
calls
.CW fdtinit()
on the pointer in
.CW x0 .
.PP
What is
.I not
there is the rest of what a real board's DTB carries: no
.CW interrupt-parent
or interrupt-specifier decoding, so an interrupt number still has to
be known; no
.CW ranges
translation for a PCIe host bridge, so an ECAM window cannot yet be
found from the tree; no enumeration that drives driver binding, so a
new SoC still means new code rather than new data; and the entry
points are declared as local
.CW extern s
in each board's
.CW main.c
rather than in
.CW os/inferno/port/portfns.h .
Finishing those four is the single highest-leverage item in this
survey, because every arm64 and RISC\-V platform below wants them and
half the work is done.
.NH 2
PCIe, ECAM, MSI and MSI-X
.PP
.CW os/inferno/port/pci.c
is the portable enumerator and
.CW os/inferno/port/pciecam.c
the portable memory-mapped configuration access;
.CW virt ,
.CW shakti
and
.CW raspi3b
name
.CW pciecam
in their mkfiles, and
.CW pc64
reaches configuration space through the ACPI MCFG window with I/O
ports as the fallback.  Single-vector MSI and MSI-X are wired:
.CW pcimsixenable()
in
.CW os/inferno/port/pci.c ,
.CW msixirqenable()
in
.CW os/inferno/pc/mp.c .
Multi-vector MSI-X \(em a vector per queue, which is what a modern
NIC or NVMe controller is designed around \(em is wired now too, on
.CW pc64 :
.CW pcimsixintrenable
and
.CW pcimsixintrdisable
in
.CW os/inferno/port/pci.h
are the portable entry points, nil on every other board, and
.CW os/inferno/port/sdnvme.c
takes two vectors through them, verified live under QEMU (section 8
of
.CW doc/inferno-cloud-plan.ms ).
There is no IOMMU or SMMU support of any kind in the tree, which
rules out device passthrough and any configuration where the platform
firmware leaves translation enabled.
.NH 2
Storage and networking that travel
.PP
The portable drivers are worth listing because they are what a new
board inherits for free:
.CW sdnvme
(NVMe),
.CW sdvirtio10
and
.CW ethervirtio10
(virtio 1.0),
.CW sdmmc
and
.CW pmmc
(SD/MMC),
.CW usbxhci
and
.CW usbxhcipci
(xHCI),
.CW sdscsi ,
.CW ethermii ,
.CW etheriwl
with
.CW wifi.c ,
.CW virtiogpu .
The
.CW pc
directory adds the x86-attached NICs
.CW ether8169 , (
.CW etherigbe ,
.CW etheri225 ,
.CW ether82563 ,
.CW etherx550 ,
.CW ether82598 ,
.CW etherbcm ,
.CW etheryuk ,
.CW ether8139 )
and the storage controllers
.CW sdiahci , (
.CW sdide )
\(em all PCI, so all reusable on any board that enumerates PCI,
though they have only ever been compiled for x86.
.PP
USB mass storage is done, and further along than its own source
comment says.
.CW appl/cmd/usb/usbd.b
implements Bulk-Only Transport (class 8, protocol 0x50) with a SCSI
CDB, does
.CW INQUIRY ,
.CW "READ CAPACITY" ,
.CW READ(10)
and
.CW WRITE(10) ,
and exports the device as a flat file through
.CW file2chan
at
.CW /chan/usbdiskN
for
.CW dossrv
to mount.  Verified live this round on
.CW os/inferno/virt
under
.CW qemu-system-riscv64
with
.CW "-device qemu-xhci"
and a
.CW usb-storage
drive backed by a 32 MiB
.CW mformat \c
ted image:
.DS L
.CW
usbd: ep1.0: port 1: full ep2.0 vid 46f4 did 0001 class 0
usbd: ep2.0: disk "QEMU    QEMU HARDDISK   2.5+" 65536 blocks x 512 bytes
usbd: ep2.0: DISK-BLK-OK (FAT/MBR signature)
usbd: ep2.0: /chan/usbdisk0 (65536 blocks)
DEVTEST: USB-FS-OK (FAT on USB mass storage)
.R
.DE
That is enumeration, SCSI, the block file, the FAT mount and a file
read back from the host-written image, on a RISC\-V board over PCIe
xHCI.  The one limit found doing it: the same test against a
.I FAT32
image (\c
.CW "mformat -F" )
stops at
.CW USB-FS-FAIL ,
because
.CW appl/cmd/dossrv.b
handles FAT12 and FAT16 and its FAT32 paths are commented out with a
.CW "TO DO: FAT32"
at line 1883.  A USB stick as a vendor ships it is FAT32, so that
comment is now on the critical path for any machine whose removable
storage is the way in.
.PP
The gap that does stand out is the display: there is nothing
beyond two special cases \(em
.CW virtiogpu
on the QEMU boards, and on
.CW pc64
the loader's framebuffer through
.CW vgasoft ,
whose comment records why: the
.CW pc
VGA drivers are written against the 386 board's
.CW screen.h
and
.CW vgavesa
needs a real-mode thunk a 64-bit kernel does not have.
.NH 2
A linker bug worth knowing about
.PP
.CW os/inferno/pc64/pc64dev
leaves
.CW draw ,
.CW tk
and
.CW math
out of its
.CW mod
section because
.CW 6l
crashes in
.CW span()
\(em a write through a nil
.CW Prog.from.sym
in the final
.CW textp
walk, at
.CW utils/6l/span.c
line 104 \(em when
.CW mathmodinit
is in the generated
.CW modinit() .
Nothing between boot and a shell needs those three, so the board
ships without them, but any platform that wants graphics wants this
fixed first.
.NH 1
The platforms
.PP
Each entry says what the machine is, what the tree already has for
it, and what is left.  Hardware details for machines this host does
not have are from the vendors' published documentation and are marked
as such; nothing in this section was measured except where it says
so.
.NH 2
The amd64 PC, workstation and server
.PP
.I "Closest to done."
This is
.CW os/inferno/pc64 ,
and it boots on QEMU today by four routes verified in the previous
round: multiboot
.CW -kernel ), (
the tree's own UEFI loader
.CW os/inferno/boot/efi , (
as an ISO and as a GPT disk), and a PVH ELF produced by
.CW tools/aout2elf .
The driver set above covers NVMe, AHCI, IDE, xHCI, the common Intel
and Realtek and Broadcom NICs, HDA audio, PS/2 and USB keyboard and
mouse, and ACPI through
.CW libaml .
.PP
The console is no longer assumed to be the 16550 at
.CW 0x3F8 :
.CW os/inferno/pc/archacpi.c 's
.CW acpispcr()
reads ACPI's SPCR table and
.CW os/inferno/pc/uarti8250.c 's
.CW i8250spcrconsole()
moves the console to the UART it names, port-mapped or
memory-mapped, verified under QEMU with the table injected by
.CW -acpitable
\(em section 7 of
.CW doc/inferno-cloud-plan.ms
has the four cases and what each printed.
.PP
What is left for a real desktop machine, in order: a display that is
not the loader's framebuffer; SMP past
.CW cpu1 ;
i2c-HID for a laptop touchpad; suspend and any power management
beyond
.CW archacpi 's
present use.  The heap fault used to head that list and is fixed
(section 3.1).  For a headless server the list is much shorter \(em
SMP \(em because a serial console and NVMe and a NIC are all it needs.
.NH 2
The amd64 cloud instance
.PP
Covered in full by
.CW doc/inferno-cloud-plan.ms .
In summary: the Xen HVM device model (PIIX3 IDE plus an emulated NIC)
is complete and verified; KVM/virtio is complete and verified;
AWS Nitro needs an ENA driver and a Xen PV domain needs xenbus,
XenStore, grant tables and event channels before
.CW blkfront
and
.CW netfront ;
Azure needs VMBus.  The boot-chain work \(em UEFI, PVH, and finishing
.CW os/inferno/boot/pc
for the providers that answer legacy BIOS only \(em is described
there.
.NH 2
The arm64 server: Graviton, Ampere, Grace
.PP
.I "The best return on effort in this survey."
The pieces are further along than they look:
.CW virtarm64
reaches an interactive prompt under
.CW "qemu-system-aarch64 -M virt" ,
and both it and
.CW raspi3b
carry GICv3 and PSCI code in their
.CW l.s ,
.CW trap.c ,
.CW io.h
and
.CW archvirtarm64.c .
The portable NVMe, xHCI and PCI drivers are architecture-neutral, and
this round showed they are not merely linked on that board but
working.  Under
.DS L
.CW
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 512 -nographic \e
	-kernel ivirtarm64 \e
	-drive file=nvme.img,format=raw,if=none,id=nv0 \e
	-device nvme,drive=nv0,serial=inf1 -device qemu-xhci
.R
.DE
the board enumerates its PCIe host bridge over ECAM and finds all
three devices:
.DS L
.CW
pci PCI.0.1.0: 1af4/1000 class 020000 irq 36
pci PCI.0.2.0: 1b36/0010 class 010802 irq 37
pci PCI.0.3.0: 1b36/000d class 0c0330 irq 38
usbxhci: 0x1b36 0xd: port 10004000 size 16384 irq 38
sdN (nvme): using 1 submit queues
ARM64-DISK-OK /dev/sdN0/data read 512 bytes
.R
.DE
That took one fix, and it is the kind worth naming: the
.CW init
section of
.CW os/inferno/virtarm64/virtarm64
named
.CW virtinit ,
the RISC\-V board's init, so every arm64 boot had been running the
other board's test suite \(em which is why no arm64 log had ever shown
a disk.  It names
.CW virtarm64init
now, and
.CW os/inferno/init/virtarm64init.b
says why it could not open a disk instead of passing silently.
There is a second
.CW pc64
configuration now,
.CW os/inferno/pc64/pc64fp ,
which differs from
.CW pc64
in one line: its init is
.CW fpinit
rather than
.CW disinit .
.CW os/inferno/init/fpinit.b
is
.CW disinit.b
with a floating-point stress in front of it \(em six Dis threads, three
rounds, each summing 0 to 199999 as reals with a doubling and a halving
per step, checked against the exact closed form, since every
intermediate is a small integer times a power of two.  It exists
because Dis programs run in kernel processes and do their arithmetic
inside the interpreter, so every scheduler slice pushes and pops FPU
state through
.CW os/inferno/port/dis.c ,
and a corrupted register file should be a wrong number rather than a
rare panic.  A boot prints one line,
.CW "FP-STRESS-OK 6 threads 3 rounds 200000 iterations" ,
and then goes on to a shell exactly as
.CW pc64
does.
.PP
MSI-X is available there now, on the GIC version that can do it.
.CW os/inferno/virtarm64/msivirtarm64.c
takes the GICv2m MSI frame out of the MADT and gives one SPI per
vector, so on
.CW "-M virt,gic-version=2"
the NVMe driver takes two vectors and both deliver; on
.CW gic-version=3
the machine has an ITS instead, which is not driven, and the board says
so and the driver falls back to INTx, which is what the log above
shows.  See
.CW doc/inferno-cloud-plan.ms
for why a successful disk read is not evidence that either path works.  Note the trade:
.CW virtarm64init.b
is 64 lines where
.CW virtinit.b
is 252, so the arm64 board now proves its storage and proves less of
everything else \(em no GC stress, no Dis stress, no kprof.  It does
not have the RISC\-V board's coverage; it has the coverage its own
init writes.
.PP
What is left is the difference between QEMU's
.CW virt
and a real server, and published server documentation (the SBBR and
SBSA specifications arm64 server platforms are built against) puts
it at: ACPI rather than device tree as the primary description, the
PCIe host bridge and its ECAM window found from that description,
MSI-X since a server NIC will not be driven by INTx, SMP, and a
serial console that is SBSA/PL011 rather than
.CW ns16550a .
Four of those are now done on this board and are described in
.CW doc/inferno-cloud-plan.ms :
.CW os/inferno/virtarm64/acpi.c
follows the RSDP the UEFI loader passes in and reads the MADT, MCFG,
SPCR and FADT, the ECAM window is taken from the MCFG rather than from
.CW mem.h ,
and
.CW os/inferno/virtarm64/startcpu.c
starts every processor the MADT names through PSCI \(em which is the
first half of SMP, not SMP: the started processors park, and
.CW conf.nmach
is still 1.  The architected timer's interrupt comes from the GTDT and
the console's base from the SPCR, the latter read in
.CW main()
before anything touches the UART, since a console at the wrong address
faults before the kernel has a handler for it.  MSI-X is done for GICv2m and not for the GICv3 ITS; SMP proper is what
else remains.
None of that is a new architecture, a new compiler or a new
interrupt controller.  It is a board directory next to
.CW virtarm64
plus ACPI-on-arm64, and the cloud instance and the Ampere workstation
are the same board.
.NH 2
The arm64 single-board computer: Pi 4 and 5, Rock 5, Orange Pi
.PP
.CW os/inferno/raspi3b
is the beachhead and it is a real one:
.CW README.hardware
documents the whole VideoCore boot chain (the GPU loads a flat
.CW kernel8.img
at 0x80000, so
.CW mkrawimg.py
lays the ELF segments out at their link addresses because
.CW "7l -H6"
packs them contiguously and puts
.CW .data
in the wrong place), and the board boots to a shell with USB working
under
.CW "-M raspi3b" .
.PP
A Pi 4 or 5 or an RK3588 board is then per-SoC driver work on top of
the FDT wiring from section 3.3: the mailbox or firmware interface,
SDHCI for the card, the on-board USB host controller (xHCI on a Pi
4, which the tree has), and the Ethernet MAC \(em GENET on a Pi,
Synopsys DesignWare on most Rockchip and Amlogic parts \(em none of
which exist in the tree.  Interrupt controller and boot method are
GICv2 or GICv3 and PSCI, both of which do.  Each board is a few
drivers, not a port.
.NH 2
Apple Silicon
.PP
.I "Its own class, and the most expensive of the ones that have a compiler."
The
.CW 7
toolchain covers the instruction set and nothing else does.  From the
published reverse-engineering work (the Asahi Linux documentation;
this host has not been used to verify any of it) an M-series machine
needs: the m1n1 boot chain, since the machine will not load a bare
kernel; the Apple Interrupt Controller, which is not a GIC; DART,
Apple's IOMMU, which cannot be avoided because the internal devices
are behind it and the tree has no IOMMU support at all; and Apple's
own non-discoverable internal devices \(em there is no standard PCIe
enumeration path to the storage, the USB controllers or the display.
Nothing this tree already has transfers except the instruction set
and the portable kernel.  Correct to describe as a research project
rather than a port.
.NH 2
The RISC\-V board: VisionFive 2, Milk-V, HiFive
.PP
.I "Better supported than any other non-x86 class here."
Four riscv64 boards boot to a shell in the table above, one of them
.CW sifiveu ) (
modelling real SiFive silicon and getting a DHCP lease;
.CW mangopi
targets the Allwinner D1, which is a real chip.  Both entries to
machine state are done:
.CW virt
enters in M-mode with
.CW "-bios none" ,
and
.CW virts
and
.CW virt32s
are entered by OpenSBI at 0x80200000 and run in S-mode using the
S-mode CSRs, SBI
.CW set_timer ,
.CW rdtime
and PLIC context 1.  FDT discovery of the PLIC, the UART and the
virtio window is live on
.CW virt ,
.CW virts ,
.CW virt32 ,
.CW virt32s
and
.CW shakti ,
but not on
.CW sifiveu
or
.CW mangopi ,
which still take their addresses from
.CW mem.h
constants.  Those two are the boards closest to real silicon, so
wiring them to the DTB is part of what a JH7110 or K1 port costs.
.PP
What a StarFive JH7110 or SpacemiT K1 board adds is per-SoC: its
SDHCI or eMMC controller, its Ethernet MAC (DesignWare again), its
USB, and its clock and pin setup.  One structural gap: the tree
knows PLIC and CLINT only.  A part with APLIC and IMSIC \(em the
newer RISC\-V interrupt architecture, which the 2025-and-later
designs use \(em needs a new interrupt controller driver, and MSI
delivery through IMSIC is a different model from the PLIC's wired
lines.
.NH 2
POWER9 and POWER10
.PP
.I "Needs a compiler first."
.CW q
is 32-bit POWER.  A Talos II or a POWER10 system needs a ppc64
(and in practice ppc64le) code generator, assembler and linker in
.CW utils ,
which is the largest single item in this survey and dwarfs the
driver work behind it.  Only after that do the platform questions
start: OPAL/skiboot rather than UEFI, the XIVE interrupt controller,
and a PCIe topology behind an IOMMU the tree does not model.
.NH 2
LoongArch, s390x, and the rest
.PP
.I "Needs a compiler first, and the platform is stranger."
No back end exists for either.  LoongArch adds its own interrupt
architecture and firmware conventions; on s390x the channel subsystem is the primary
I/O model (zPCI exists alongside it), so most of what
.CW os/inferno/port/pci.c
does would not be the way in.  Both are correct to describe as out of
reach without a deliberate multi-month decision.
.NH 2
The microcontroller
.PP
.I "Already works, within its limits."
.CW mps2
reaches an interactive prompt under
.CW "qemu-system-arm -M mps2-an500" ,
and
.CW teensy41
(i.MX RT1062) and
.CW nucleof303
(STM32F303) build for real parts this host cannot emulate.  The
.CW t
compiler, the
.CW /dis32
tree and the shared
.CW os/inferno/armv7m
sources are all in place.
.PP
The constraint is RAM rather than anything missing: the Dis
interpreter, its heap and a useful module set have to fit, which is
the argument
.CW doc/inferno-ports.ms
already makes about the STM32 parts.  A new Cortex\-M board is a
clock, a UART and a
.CW mem.h ,
which is the cheapest new board in the tree.
.NH 1
Corrections to the record
.PP
This survey contradicts five claims that stand in the tree's own
documents, and the documents should be believed less than the boots
above.
.IP 1. 4
.CW AGENTS.md
said "Item 9 (device trees, PSCI, GICv3, S-mode/SBI, SoC drivers) is
untouched."  All five exist:
.CW os/inferno/port/fdt.c
is called by six boards, PSCI and GICv3 are in
.CW virtarm64
and
.CW raspi3b ,
.CW virts
and
.CW virt32s
are S-mode boards entered by OpenSBI, and
.CW sifiveu ,
.CW mangopi ,
.CW raspi3b
and
.CW teensy41
are SoC boards.  What is untouched is the
.I extent
of each, catalogued in section 3; that sentence in
.CW AGENTS.md
has been corrected in place to say so.
.IP 2. 4
.CW doc/inferno-driver-plan.ms
names "three gaps shared by all boards ... USB device classes, a
virtio-gpu display, and device-tree parsing", and says of riscv64
.CW virt
that it "has no device-tree reader and no display" and of arm64
.CW virt
that it "needs PCI, the shared PCI drivers, GICv3, PSCI, and a
device-tree reader".  All three gaps are now closed:
.CW os/inferno/port/virtiogpu.c
exists and
.CW virt
and
.CW virts
use it through their
.CW screenvirt.c ,
and
.CW os/inferno/port/fdt.c
exists and six boards call it.  arm64
.CW virt
has GICv3 and PSCI.  USB device classes are closed for the two that
matter \(em HID and mass storage, both in
.CW appl/cmd/usb/usbd.b ,
both verified live, the second this round (section 3.5).  The
display gap remains real for hardware that is not virtio, which is
all real hardware.
.IP 3. 4
.CW doc/inferno-cloud-plan.ms
said the legacy-BIOS loader could not be built because there was no
.CW Inferno/386/include .
There is; the first two stages link; that paragraph has been
corrected in place.
.IP 4. 4
The
.CW init
section of
.CW os/inferno/virtarm64/virtarm64
named
.CW virtinit ,
the RISC\-V board's init, while
.CW AGENTS.md
said "virtarm64init.b is its console init".  The two disagreed, so an
arm64 result read out of the record cannot be assumed to be against
the init the record names.  The configuration names
.CW virtarm64init
now, and the arm64 results in section 4.3 are from the corrected
board.  An audit of every board's
.CW init
section found no other mismatch of that kind:
.CW mps2 ,
.CW nucleof303
and
.CW teensy41
share
.CW armv7minit
because they share
.CW os/inferno/armv7m ,
.CW virts
shares
.CW virtinit
with
.CW virt
because they are the same machine in two privilege modes, and
.CW armv7
borrows
.CW virtinit
for want of an
.CW armv7init.b
of its own \(em it dies before init runs, so nothing turns on it.
.IP 5. 4
Any claim anywhere that a board "boots" should be read against
section 3.1.  On the most recent measurement
.CW pc64
reached a prompt once in twenty-four attempts.
.NH 1
The answer, cheapest first
.PP
Ordered by what it costs to get a native Inferno to a shell on the
class, given this tree today.
.IP 1. 4
.B "The heap fault, which is fixed."
Not a platform, and it used to head this list as the reason no entry
in the survey could be called done.  It turned out not to be shared at
all: four instructions in
.CW os/inferno/pc64/l.s ,
described in section 3.1.  Thirty consecutive
.CW pc64
boots reach a shell.  Nothing else on this list is blocked on it any
more.
.IP 2. 4
.B "Finish the amd64 machine."
.CW pc64
plus a display and SMP is a usable workstation; the headless server
needs less.  The cloud instance is
.CW doc/inferno-cloud-plan.ms .
.IP 3. 4
.B "The RISC\-V single-board computer."
Four boards already reach a shell, one with networking.  A real
VisionFive 2 or Milk-V is per-SoC drivers on top of what is there.
.IP 4. 4
.B "The arm64 server."
PCIe ECAM, NVMe and xHCI are working on
.CW virtarm64
now, verified (section 4.3), so what is left is ACPI-on-arm64 to find
the same things on a machine described that way, MSI through the
GICv3 ITS, and SMP.  ACPI is the expensive one and not for the reason
it looks: on arm64 the RSDP comes from the UEFI system table, not
from a scan of low memory, so it wants an AArch64 build of
.CW os/inferno/boot/efi
first, which is three pieces.  The third is done:
.CW tools/aout2efi
now maps the a.out magic to the PE machine type \(em
.CW S_MAGIC
(0x8a97) to
.CW 0x8664
and
.CW R_MAGIC
(0x8c47) to
.CW 0xAA64 ,
with anything else refused rather than silently mislabelled \(em and
.CW bootx64.efi
relinks from scratch with
.CW 0x8664
unchanged.  The other two are written too:
.CW os/inferno/boot/efi/aa64.s
is the
.CW 7a
entry and relocation stub in place of
.CW x64.s ,
with an
.CW eficall
that turns a
.CW 7c
call (first argument in R0, the rest on the stack \(em confirmed with
.CW "7c -S" )
into an AAPCS64 one (X0\-X7 and the ninth onward back on the stack;
eleven is the most any caller passes,
.CW pxe->UdpWrite
in
.CW os/inferno/boot/efi/pxe.c ).
.CW mk
.CW bootaa64.efi
links a 16896-byte PE with machine
.CW 0xAA64 ,
entry
.CW 0x200
and image base
.CW 0x48000000 .
.PP
Getting there took two bugs out of
.CW 7l ,
both real and both general:
.CW addpool()
in
.CW utils/7l/span.c
had no
.CW C_LACON
case, so the address of a local passed to a function
.CW ( &mapsize
to
.CW eficall
in
.CW efi.c )
went into the literal pool as
.CW "DWORD ,$mapsize-8(SP)" ,
which
.CW asmout
rejects \(em it wants the offset, which its case 34 adds SP to; and
.CW asmout 's
cases 20 and 21 in
.CW utils/7l/asmout.c
used the unscaled 9-bit load and store form only for negative offsets,
so a small
.I positive
offset that is not a multiple of the access width
.CW ( iso.c
reading an unaligned field of an ISO9660 directory record at 182)
came out as
.CW "odd offset: 182" .
Both are fixed;
.CW bootx64.efi
relinks byte-compatible.
.PP
It is not finished.  Under
.CW qemu-system-aarch64
.CW "-M virt"
with
.CW edk2-aarch64-code.fd
and a GPT disk whose ESP carries
.CW EFI/BOOT/BOOTAA64.EFI ,
the firmware maps the volume as
.CW FS0: ,
loads the image at its base and runs it \(em the exception dump shows
X2 and X3 both
.CW 0x48000000
(load address and link address agreeing, so the relocation copy
correctly did nothing) and X12 and X13 holding
.CW A64.
and
.CW EFI
as UTF-16, so it is well inside the C code walking the boot path.  It
then takes a data abort writing to address 0 at
.CW 0x48000D18
.CW ( "ESR 0x96000047" ,
EC 0x25, DFSC 7).  And
.CW jump()
is a spin: an AArch64 kernel wants the MMU and caches off and its own
register handover, which is not the state
.CW ExitBootServices
leaves, and
.CW confaddr
is still the amd64 kernel's
.CW CONFADDR .
So: it builds, it loads, it runs, it does not yet boot a kernel.
The firmware to test that against is here and works:
.CW /opt/homebrew/share/qemu/edk2-aarch64-code.fd
as a pflash under
.CW "qemu-system-aarch64 -M virt"
reaches its UEFI shell, and refuses an x64 image in as many words
.CW "Image type X64 can't be loaded on AARCH64 UEFI system" ) (
\(em which is the error the port has to stop producing.  Still the single best return, because Graviton and Ampere and
every arm64 workstation are one board.
.IP 5. 4
.B "The arm64 single-board computer."
.CW raspi3b
plus FDT wiring plus per-SoC mailbox, SDHCI, USB and MAC.  Cheap per
board, but one set of drivers per SoC vendor and they do not share.
.IP 6. 4
.B "The microcontroller."
Cheapest of all in engineering terms and already demonstrated;
limited by RAM, not by missing work.
.IP 7. 4
.B "Repair the two broken boards."
.CW armv7
is the one board that builds a kernel and cannot boot it, and
.CW pc
is the one that cannot be built.  The second is not one fix: the
.CW FPU
typedef, the
.CW active.machs
array, the stale
.CW waserror() ,
the stale configuration lines and the superseded
.CW i8250.c
were all repaired this round and it still stops, now on
.CW io.h 's
.CW Vctl ,
with
.CW trap.c ,
.CW mmu.c ,
.CW memory.c
and
.CW l.s
behind that (section 2).  Whether either is worth the work depends
on whether anything is wanted from 32-bit x86 or 32-bit ARM at all.
.IP 8. 4
.B "Apple Silicon."
Months, and a different kind of month: AIC, DART and a set of
undocumented devices, with nothing to inherit.
.IP 9. 4
.B "POWER, LoongArch, s390x."
A compiler back end before anything else can start.
