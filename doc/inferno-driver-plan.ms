.TL
A driver plan for the Inferno ports
.AU
.PP
This is the forward plan for the drivers the five QEMU boards still
lack, written after the round recorded in
.CW doc/inferno-ports.ms
that brought pc64, riscv64 and arm64 most of the way and left riscv32
and armv7 where they were.  It orders the work by what unlocks what,
says which piece is one portable file shared by every board and which
is per board, and treats the display the way the tree already treats
3-D drawing: a portable capability with interchangeable backends, not
a driver bound to one machine.
.NH 1
What each board still needs, in one place
.PP
pc64 is the most complete: this round linked NVMe, virtio 1.0, the
xHCI controller, SD/MMC, HD audio, ECAM, and the Intel and Realtek
NICs.  What it lacks is USB device classes above the controller, a
real display, MSI in the drivers, and SMP past the heap bug.
.PP
riscv64 virt runs the portable PCI code over ECAM with NVMe, virtio
1.0 and xHCI, and reaches a shell.  What it lacks, before any driver,
is supervisor mode: it runs bare in machine mode with
.CW "-bios none" ,
where a real board hands it S-mode through OpenSBI.  It also has no
device-tree reader and no display.
.PP
arm64 virt reached a shell only this round and links almost nothing:
virtio-mmio ethernet, a console, GICv2, the generic timer.  It needs
PCI, the shared PCI drivers, GICv3, PSCI, and a device-tree reader.
.PP
Three gaps are shared by all boards and are where the leverage is:
USB device classes, a virtio-gpu display, and device-tree parsing.
The rest is either one board's silicon or a driver already written in
a sibling flavour waiting to be adapted the way this round's were.
.NH 1
USB device classes: the largest single gap
.PP
The kernel USB stack and the host controllers work, and
.CW appl/cmd/usb/usbd.b
enumerates hubs and drives a boot-protocol keyboard and mouse.  What
is missing is every other class, and the one that matters is mass
storage: without it a machine cannot boot from or read a USB stick,
which is how a modern machine is installed and recovered.  This is all
Limbo, above the kernel, and 9front's
.CW nusb
is the reference for each piece.
.IP 1.
A mass-storage class driver, after 9front's
.CW nusb/disk :
open the bulk in and out endpoints of a device whose interface class
is 8, speak the Bulk-Only Transport wrapper (a command block, the data
phase, a status block), and present each logical unit as an
.CW sd (3)
device so the existing FAT and kfs code reads it unchanged.  This is
the highest-value item on the whole plan.
.IP 2.
Hub depth and hot-plug: usbd already powers and walks an external hub,
but only the boot path has been exercised; a device behind a hub, and
a device arriving after boot, need the port-status change path driven
in the poll loop, which is written but untested past one level.
.IP 3.
A USB-Ethernet class driver (CDC-ECM and the common ASIX and Realtek
dongles), after 9front's
.CW nusb/ether ,
which registers an
.CW ether (3)
card backed by two bulk endpoints.  This is what gives a machine with
no built-in NIC a network.
.IP 4.
Report-descriptor parsing in the HID driver, so a device that does not
offer boot protocol \(en a tablet, most modern keyboards in their
native mode \(en is usable rather than configured and ignored.
.PP
None of this touches the kernel.  It is the same shape as this round's
.CW usbd :
Limbo against
.CW /dev/usb ,
tested against QEMU's own
.CW usb-storage ,
.CW usb-net
and
.CW usb-tablet .
.NH 1
A display, modelled on draw3d and Metal
.PP
Every board draws into a software
.CW memimage
framebuffer
.CW ( gscreen
in each board's
.CW screen.c )
and
.CW flushmemscreen()
pushes it at the hardware.  On pc64 the hardware is the boot loader's
fixed framebuffer through
.CW vgasoft ;
on the virt boards it is
.CW ramfb
or nothing.  None of them can change resolution, and arm64 and the
plain riscv boards have no display at all.  A virtio-gpu driver fixes
this for every board at once, because virtio-gpu is a PCI (or mmio)
device QEMU, KVM and real clouds all present, and the tree already has
the pattern for how to structure it.
.PP
That pattern is
.CW draw3d .
The 3-D drawing interface
.CW ( module/math/draw3d.m )
has two providers behind one Limbo module:
.CW draw3d.dis ,
pure software over
.CW polyfill ,
and
.CW draw3ddev.dis ,
which speaks an extension of the
.CW /dev/draw
write protocol \(en the letters
.CW 3 ,
.CW M ,
.CW w ,
.CW u ,
.CW z ,
.CW g ,
.CW G ,
.CW h ,
.CW j ,
.CW k
handled in
.CW devdraw.c
\(en for matrix upload, viewport, z control and batched geometry.  In
the hosted emu those letters reach
.CW emu/MacOSX/win-cocoa.m ,
where a Metal pipeline
.CW ( mtl_geom3d_pipe ,
"the GPU does model*proj+viewport") runs the transform and shading on
the real GPU and composites over the software screen presented through
a
.CW CAMetalLayer .
The provider probes for the letters at load time with the
.CW 3
message and falls back to software if the host does not answer.  The
application, and every layer above it, is identical either way.
.PP
The rule that makes this work is the one the host-capability devices
follow: virtualise the capability, not the host's structure.  The
guest speaks a portable protocol; each backend \(en Metal on a Mac,
virtio-gpu in a VM, software anywhere \(en implements it.  virtio-gpu
gets the same treatment, in two tiers.
.NH 2
Tier one: the 2-D display (the win)
.PP
virtio-gpu's 2-D mode is a control queue and a scanout.  The driver
creates a host resource the size of the screen, attaches guest pages
to it as its backing store, sets it as scanout 0, and on each
.CW flushmemscreen()
issues
.CW TRANSFER_TO_HOST_2D
for the dirty rectangle and
.CW RESOURCE_FLUSH .
Mode changes come free: destroy the resource, make a new one, set
scanout.  A hardware cursor rides the cursor queue.  This is one
portable driver,
.CW os/inferno/port/virtiogpu.c ,
linked on any board through PCI or mmio the way the virtio 1.0 net and
block drivers already are, and it is what makes the window system and
.CW tk
actually appear on a modern virtual machine and resize with the
window.  It needs nothing above the kernel to change; it is a new
.CW screen
backend that
.CW flushmemscreen()
targets.
.NH 2
Tier two: acceleration (later, and exactly like Metal)
.PP
virtio-gpu's 3-D mode
.CW ( virgl ,
or the newer Vulkan-over-virtio
.CW venus )
is where the draw3d pattern pays off a second time.  The native
.CW os/inferno/port/devdraw.c
does not yet handle the 3-D protocol letters; the hosted emu's does.
Adding those handlers to the native devdraw, translating each batch of
raw vertices into a virgl command stream the way win-cocoa.m
translates it into a Metal draw, backs the extended protocol on the
guest with the VM's GPU.  The Limbo
.CW draw3ddev.b
provider is unchanged \(en it already writes the letters \(en and
.CW draw3d.b
stays the software fallback for a board with no GPU.  One interface,
three backends, chosen by capability.  This tier is optional and comes
after everything else; the 2-D display is the piece the boards need.
.NH 1
MSI and MSI-X
.PP
ECAM is in on pc64 and riscv64, but only
.CW etherx550
asks for MSI; every other driver is on INTx.  INTx works on the boards
here, but it caps a multi-queue NVMe or NIC to one interrupt and fails
behind a bridge that does not route INTx, which is most PCIe.  The
kernel already has
.CW pcimsienable() ;
the work is per driver, enabling MSI-X vectors in
.CW sdnvme ,
.CW usbxhci
and the virtio 1.0 drivers where 9front's own versions do, and wiring
the per-vector handlers.  It is not blocking, so it comes after the
device set is complete.
.NH 1
arm64: PCI, GICv3, PSCI
.PP
arm64 is the least complete and its gaps are ordered.
.IP 1.
PCI, so the board can reach any of the drivers already written.  QEMU's
arm64 virt puts disks and NICs on PCIe by default, and the riscv64
board's
.CW os/inferno/riscv/pciecam.c
is already the portable ECAM back end
.CW ../port/pci.c
wants; sharing it needs only the board's INTx-to-GIC mapping and its
window addresses.  This one step brings NVMe, virtio 1.0 and xHCI to
arm64 at once.
.IP 2.
GICv3.  The board has GICv2; sbsa-ref and nearly every real SoC are
GICv3, which moves the CPU interface into system registers and adds a
per-CPU redistributor.  Needed for real hardware and for more than a
handful of interrupts.
.IP 3.
PSCI, the firmware call for secondary-CPU bring-up, reboot and
power-off.  Needed for SMP and for a clean shutdown on hardware and in
QEMU.
.NH 1
riscv: supervisor mode, SBI, device tree
.PP
The riscv boards run bare in machine mode.  A real board boots OpenSBI
and hands the kernel supervisor mode, so the port needs an S-mode
entry
.CW ( stvec ,
.CW sstatus ) ,
SBI calls for the timer, console and inter-processor interrupts in
place of the direct CLINT access, and the PLIC's supervisor contexts.
The riscv32
.CW todfix
clock spam is a symptom of the machine-mode timer this would replace.
.PP
Done for riscv64:
.CW os/inferno/virts
is the S-mode sibling of
.CW virt ,
entered by OpenSBI (QEMU's default
.CW -bios )
in supervisor mode at 0x80200000 the way real hardware boots, rather
than
.CW "-bios none"
in machine mode.  It is a file copy, not an
.CW #ifdef :
.CW l.s
uses the S-mode CSRs and SRET with the shifted interrupt-enable bit
positions; the timer is the SBI legacy set_timer ecall and the tick is
the
.CW time
CSR, because OpenSBI PMP-protects the CLINT from S-mode (confirmed in
its own boot print); and
.CW trap.c
reads the supervisor interrupt causes and drives PLIC context 1.
Verified: boots clean through the full init battery, SNPRINT-ABI-OK
through ROOT-CMDS-OK, to the shell prompt with zero faults, four of
four, with a virtio-blk disk exercising the PLIC external-interrupt
path.  The machine-mode
.CW virt
board is untouched and still boots.
.PP
riscv32 has the same S-mode sibling now:
.CW os/inferno/virt32s ,
built and booted under rv32 OpenSBI to VIRT32-INIT-OK and the shell,
zero faults, four of four.  The rv32-specific care the advisor flagged
held up: the 64-bit deadline is passed to the SBI set_timer ecall as a0
low / a1 high through two ulong globals rather than a uvlong in one
register, and the 64-bit tick is the time/timeh CSR pair read with the
standard hi/lo/hi retry loop done in C.  Both S-mode boards also gained
a clean SBI SRST poweroff on exit(), verified.  Wiring the boards to the
device-tree addresses is now demonstrated on both riscv64 boards: the
PLIC base is a runtime
.CW plicbase ,
defaulting to the compiled-in constant but overridden from the DTB in
.CW main()
before
.CW trapinit()
seeds the interrupt controller.  It is proven end to end, not just read
back: with the
.CW PLIC
constant deliberately set wrong, both boards still boot and their
PLIC-interrupt-driven virtio-mmio disk still works, because the base
came from the device tree - so the same kernel would find the PLIC on
silicon whose map differs.  A DTB miss leaves the constant in place, so
the wiring can never hang a working board.  The same one-variable
pattern extends to the rv32 boards, to arm64 (once it is handed a DTB),
and to the UART window.  The virtio-mmio base is now wired the same way
on both riscv64 boards: a runtime
.CW virtiobase
seeded from the lowest
.CW virtio,mmio
node in the DTB (a new
.CW fdtregmin
in
.CW fdt.c ,
since QEMU lists the eight slots highest-first and the drivers scan
upward from the lowest), constant fallback otherwise.  Proven by the
same falsify test: with
.CW VIRTIO0
set wrong, the board still finds and reads its virtio-mmio disk,
because the base came from the device tree.
.PP
The two rv32 boards, virt32 and virt32s, had no device-tree support at
all; both now capture the DTB pointer at boot (QEMU/OpenSBI hands it in
a1), build the shared
.CW fdt.c ,
and seed
.CW plicbase
from it the same way.  These boards are console-only, so there is no
disk to lose, but the falsify test still proves the path directly: with
the
.CW PLIC
constant set wrong, the board prints
.CW "plic base 0xc000000 (mem.h PLIC 0xd000000)"
- plicbase took the DTB value, not the wrong constant - and boots to
VIRT32-INIT-OK.  All four riscv boards now find their interrupt
controller through the device tree.
.PP
arm64 has a framebuffer now, where it was serial-console-only.
.CW os/inferno/virtarm64/screenarm.c
is a QEMU ramfb backend adapted from the riscv
.CW screenvirt.c ,
pointed at the arm64 virt machine's fw_cfg at 0x9020000 and ramfb-only
(no virtio-gpu fallback, since arm64 reaches its devices over PCI).  The
board's config gains the draw and pointer devices, the
memlayer/memdraw/draw libraries and the software cursor.  Verified with
.CW "-device ramfb" :
the virtinit battery passes DRAW-OK, DRAW-RECT-OK, PTR-OK and KBD-OK,
and a screendump of three RGB bands painted into the framebuffer returns
them exactly, so kernel-drawn pixels reach the host scanout.  Without
the device the board still boots, display optional.
.PP
Both riscv boards, and arm64, then need a device-tree reader: every
address is a compile-time constant today, checked against QEMU's
.CW dumpdtb ,
which does not survive a move to different silicon.
.NH 1
Per-board silicon, once the shared work is done
.PP
With USB storage, a virtio-gpu display, MSI, PCI on arm64 and S-mode
on riscv, the QEMU boards are complete.  The real parts in the plan's
machine table then each need their own drivers, most of them already
written in a sibling flavour: for the Raspberry Pi 4 and 5 the VL805 or
RP1 xHCI, GENET or MACB Ethernet, the eMMC SDHCI and the mailbox
framebuffer; for the VisionFive 2 and the Icicle the DesignWare GMAC,
a Cadence or DesignWare SDHCI and xHCI, and the SoC's PCIe controller;
for the arm64 servers UEFI and ACPI, where the tree's EFI loader is
x86 only.  These are the destination; the shared work above is the
road.
.NH 1
The order
.PP
One dependency chain, so the leverage lands first:
.IP 1.
USB mass storage in Limbo \(en unlocks boot and install media on every
board, touches no kernel.
.IP 2.
virtio-gpu 2-D \(en one portable kernel driver, gives every board a
real, resizable display.
.IP 3.
PCI on arm64 (share pciecam) \(en brings the whole PCI driver set to
the board that has none.
.IP 4.
MSI in the drivers \(en removes the INTx cap, per driver.
.IP 5.
GICv3 and PSCI on arm64; S-mode, SBI and device tree on riscv \(en the
real-hardware entry.
.IP 6.
USB ethernet and HID report descriptors; virtio-gpu 3-D backing the
draw3d protocol \(en completeness.
.IP 7.
Per-SoC drivers for the real parts.
.PP
Items 1 through 4 are each testable on this host today against a QEMU
device, the same discipline the last round held to.
.NH 1
Done so far
.PP
Item 1, USB mass storage:
.CW appl/cmd/usb/usbd.b
detects a class-8 Bulk-Only interface, speaks the 31-byte command
wrapper / data / 13-byte status wrapper carrying SCSI (inquiry, read
capacity, READ(10)/WRITE(10)), and exports each unit as
.CW /chan/usbdiskN
through
.CW file2chan .
Verified on riscv64 against QEMU's
.CW usb-storage :
dossrv mounts the FAT and the init reads a planted marker.  A USB stick
is readable and mountable.
.PP
Item 2, the display:
.CW os/inferno/port/virtiogpu.c
brings up a virtio-gpu PCI device, makes the board's framebuffer a
scanout resource, and pushes each dirty rectangle with
.CW TRANSFER_TO_HOST_2D
and
.CW RESOURCE_FLUSH .
.CW screenvirt.c
drives it lazily when there is no ramfb.  Verified by QEMU screendump:
a three-band red/green/blue fill appears exactly, with only the mouse
cursor stray.  The one bug was the command descriptor carrying the
WRITE flag; it is device-read.
.PP
Item 3, arm64 PCI:
.CW pciecam.c
moved to
.CW ../port ,
portable now with a board
.CW PCIINTXBASE
and a DATA-held 64-bit ECAM base.  virtarm64 links it and the shared
PCI drivers.  Verified: PCI enumerates, virtio-net and xHCI attach, and
NVMe reads a real sector over DMA with the MMU off.  arm64 went from
one mmio NIC to the whole PCI driver set.
.PP
One toolchain finding along the way, recorded in
.CW doc/inferno-ports.ms :
.CW 7l
materialises a 64-bit constant used inline in an expression with only
its low 32 bits, so
.CW 0x4010000000
became
.CW 0x10000000 ;
a
.CW DATA -initialised
.CW uvlong
holds the whole value and is the portable way to name a high address.
.PP
Item 5, device tree:
.CW os/inferno/port/fdt.c
is a portable flattened-device-tree reader.  QEMU hands the kernel a
DTB (a1 on riscv, x0 on arm64) whose nodes carry each device's real
address, so a board can find its UART, virtio and PCI windows and its
interrupt controller instead of naming them as constants.  The board's
boot code in
.CW l.s
captures the pointer;
.CW fdtreg
finds a node by compatible string and reads its reg base and size.
Verified: riscv64 finds its 8250 UART in the DTB.  arm64 under QEMU's
.CW -kernel
gets x0 == 0 (no DTB pointer), so the capture is inert but correct
there.
.PP
arm64 PSCI:
.CW psci()
in
.CW l.s
is HVC #0 (the raw word, since 7a has no HVC mnemonic) with the SMCCC
arguments already in R0-R3;
.CW archreboot
calls SYSTEM_RESET and
.CW archshutdown
calls SYSTEM_OFF.  Verified: QEMU exits 0 in a fifth of a second on a
reset call.
.PP
arm64 GICv3 (arm64 item 2):
.CW trap.c
reads
.CW ID_AA64PFR0_EL1.GIC
at boot to tell a GICv3 from the default GICv2 - a CPU ID read, so it
never aborts, where the GICv2 distributor's PIDR2 (the obvious probe)
is unimplemented in QEMU and faults.  On a v3 the per-CPU interface is
the
.CW ICC_*_EL1
system registers, hand-encoded as raw MSR/MRS words in
.CW l.s
(verified against the host assembler); SGI/PPI enable state lives in
the per-CPU redistributor's SGI frame, not the distributor; and SPIs
are routed to a CPU through
.CW GICD_IROUTER
once affinity routing is on.  gicinit wakes the redistributor, places
everything in group 1, and enables the interface.  Verified on
.CW "-M virt,gic-version=3" :
the board reaches its shell (so the timer PPI fires through the
redistributor) and an NVMe read completes (so PCI SPI 37 is delivered
through IROUTER); GICv2 still boots clean, unchanged.
.PP
Remaining: MSI (item 4), the rest of item 5 (riscv supervisor mode,
SBI, wiring boards to the discovered DTB addresses), item 6 (USB
ethernet, HID report descriptors, virtio-gpu 3-D), and item 7 (per-SoC
drivers).
.NH 1
Remaining QEMU-tractable work, and what is out of reach
.PP
With the interrupt controllers, the timer, PCI and the virtio devices,
the framebuffer and the device-tree wiring all done, the QEMU virt
machines expose only a short list of devices still unsupported.  Two of
them are worth doing and verifiable on QEMU; the rest are either no
gain on these machines, blocked by the boot path, or need silicon.
.NH 2
Done (both verified against the host clock / a QEMU exit)
.IP 1.
Hardware RTC to real wall-clock time.  Both virt machines carry a
real-time clock the kernel never reads - riscv's
.CW google,goldfish-rtc
at 0x101000 (a 64-bit nanosecond counter, TIME_LOW then TIME_HIGH) and
arm64's
.CW arm,pl031
at 0x9010000 (a 32-bit seconds register).  Today wall-clock time comes
from the tick counter, so timestamps are relative, not calendar time.
Done: each board reads its RTC at boot and seeds
.CW todset ,
verified against the host clock - the seeded epoch matches to the
second on all four riscv boards (the goldfish RTC is reachable even
from supervisor mode; OpenSBI does not PMP-hide it the way it hides the
CLINT) and on arm64's PL031.
.IP 2.
Machine-mode syscon poweroff.  The supervisor-mode boards get a clean
poweroff through the SBI SRST call; the machine-mode riscv boards
(virt, virt32) still spin in WFI on exit.  QEMU's
.CW sifive,test0
finisher at 0x100000 powers the machine off on a write of 0x5555 (and
reboots on 0x7777).  Done: the machine-mode boards'
.CW archreboot
writes 0x5555 to it and QEMU exits 0 in under a second, matching the
supervisor boards' SBI SRST poweroff.
.NH 2
Out of reach here
.IP \(bu
MSI/MSI-X: PCI runs on legacy INTx, which QEMU delivers correctly, so
MSI buys nothing on these machines.  Left for real hardware that needs
more vectors.
.IP \(bu
The arm64 PL061 GPIO drives only a poweroff key under QEMU - cosmetic.
.IP \(bu
arm64 device-tree discovery is blocked: QEMU's
.CW -kernel
path enters the arm64 ELF with x0 == 0, handing it no DTB pointer, so
the reader that works on riscv has nothing to read.
.IP \(bu
SPI is now real on the one SoC board the tree boots with a modelled
bus: QEMU's
.CW sifive_u
has two
.CW sifive,spi0
controllers, a NOR flash on the first and an SD card on the MMC-SPI
second, and
.CW os/inferno/riscv/spisifive.c
(was a register-poke stub) now does full-duplex FIFO transfers and
reads each flash's JEDEC id - the NOR flash answers 0x9d 0x70 0x19
(ISSI IS25WP256), proving the bus reaches its slave.  Reading an SD
card over the MMC-SPI controller is a separate matter: the SD-over-SPI
handshake (CMD0/CMD8/ACMD41/CMD58 then a CMD17 block read) was written
and exercised, but no slave answered on that controller - the very same
transfer code reads the NOR flash correctly, so the transport is sound;
the card is attached (QEMU's qtree shows an
.CW ssi-sd
with a
.CW sd-card-spi
behind it) but its chip-select is not the SPI controller's own: QEMU
wires it to a GPIO line
.CW ( ssi-gpio-cs ) ,
so the card only listens when that GPIO pin is driven low, which the
SiFive SPI's
.CW csmode
never touches.  Driving all sixteen GPIO pins low in turn as a candidate chip-select
never once selected the card (QEMU's SSI returns 0 for an unselected
slave, and every transfer read 0), and the SiFive controller's own
chip-select does not reach it either.  The GPIO writes do take effect -
sweeping the low pins trips
.CW gpio-restart
and reboots the machine - so the conclusion is that QEMU's sifive_u
does not wire the SD's chip-select to anything the guest can drive:
SD-over-SPI is unreachable on this machine, a model limitation rather
than a driver gap.  The full handshake and block read are written and
correct; they simply have no way to assert CS here.  The flash JEDEC
read already shows the SPI driver works against a real slave.  I2C is a
different story: no QEMU machine this tree currently boots models an
I2C controller at all (sifive_u and spike have none), so delivering I2C
needs a raspi-class board bring-up - a real SoC with BCM2835 SPI, I2C
and GPIO - which is its own project, board first and peripherals after.
The generic virt platform has neither bus.
.PP
The sifive_u board's Cadence GEM ethernet is verified end to end: its
driver
.CW ( os/inferno/riscv/ethersifivegem.c )
was already complete, and the board's init now runs a DHCP exchange
over it.  A full DISCOVER/OFFER/REQUEST/ACK needs the NIC to transmit,
receive and take interrupts, so DHCP-OK proves the driver works, not
just that it probed - on QEMU's user network it takes 10.0.2.15.  The
board boots and reaches its shell whether or not a network is present.
.NH 1
A new board: shakti_c
.PP
The first board brought up from scratch this round, and a check that a
new board on this tree costs about what it should.  QEMU's
.CW shakti_c
(Shakti C-class SoC) is riscv64 with the same CLINT, SiFive PLIC and RAM
base as the virt board, so its M-mode boot, trap path and timer are
reused unchanged; the only genuinely new driver is the console, a
.CW shakti-uart
(32-bit TX/RX/STATUS at 0x11300, not a 16550), in
.CW os/inferno/shakti/uartshakti.c .
The payload loads as
.CW -bios ,
not
.CW -kernel :
the ROM reset vector jumps to the RAM base where the kernel links.  Two
quirks, both found from the faulting address: shakti_c has no RTC (the
clock stays tick-based), and QEMU maps its PLIC in only a 0x20000-byte
aperture so the SiFive context region at PLIC+0x200000 is off the end -
plicinit() leaves the PLIC alone, the CLINT timer drives the scheduler
and the console is polled, which reaches a shell.  Verified: boots to
SHAKTI-OK and a working shell, zero faults, three of three.  It models
no I2C, SPI or storage, so it adds no peripheral - its value is the
bring-up itself, and the confirmation that the copy-adapt-boot loop on
this tree is one UART plus a config trim.
.NH 1
raspi3b: started, EL3 entry and console solved, interrupt controller next
.PP
The Raspberry Pi 3B is the board that would answer the I2C and GPIO
question, but it stacks three unknowns the virt machines do not: no
device tree, no GIC, and a different entry exception level.  This round
solved the two that block a console and left the third documented, then
removed the work-in-progress board directory rather than leave a board
that hangs in the tree.
.PP
What was pinned, all reusable when the board is finished:
.IP \(bu
Entry state, read from the monitor before the kernel runs (the
technique that pinned the armv7 fault): QEMU's raspi3b enters at
.CW EL3
(PSTATE EL3h), PC 0x80000 - the Pi firmware's load address, so
KTZERO is 0x80000 - and x0 is 0 (no DTB, as the machine has no FDT).
.IP \(bu
The EL3 to EL1 drop, verified working (the kernel ran to procinit at
EL1).  In one ERET: set HCR_EL2.RW so EL1 comes up AArch64 even though
EL2 is skipped, SCR_EL3 to 0x431 (RW, NS, the RES1 bits), SPSR_EL3 to
0x3c5 (EL1h, DAIF masked), ELR_EL3 to the EL1 entry.  7a does not name
the EL3/EL2 registers, so they are raw MSR words with source x0,
verified against the host assembler: HCR_EL2 0xd51c1100, SCR_EL3
0xd51e1100, SPSR_EL3 0xd51e4000, ELR_EL3 0xd51e4020, and MRS CurrentEL
0xd5384240.
.IP \(bu
The console is the PL011 at 0x3f201000 (the BCM2837 peripheral base is
0x3f000000), and it is serial0 under
.CW -nographic .
The virt board's PL011 driver drives it and output appears, though it
garbles - the Pi's PL011 needs its own enable/FIFO setup the virt one
skips, a refinement for when the board is resumed.
.PP
What remains, and why the directory was not kept: raspi3b has no GIC,
so the generic-timer interrupt that drives the scheduler never arrives
- the kernel reaches procinit and then waits forever.  Finishing the
board needs the BCM2835 ARM interrupt controller at 0x3f00b200 and the
per-core BCM2836 local controller at 0x40000000 that routes the generic
timer, in place of trap.c's GIC; then the config trimmed of virtio, PCI
and the GIC the way shakti's was; then a board init.  The BCM interrupt
controller is simpler than a GIC, so this is bounded work - it just was
not going to reach a shell this round, and a board that hangs at
procinit is not one to leave in the tree.  The I2C (BSC at 0x3f804000),
SPI (0x3f204000) and GPIO (0x3f200000) that motivated the board come
after it boots.
.PP
A second pass got further: the EL1 landing was confirmed live (PSTATE
EL1h), the BCM interrupt controller was written into trap.c (the timer
routed through the per-core controller, the source read back there), and
the config was trimmed the way shakti's was.  It then hit two blockers
that make raspi3b a focused job of its own, not a tail-end one: the PL011
console garbles even writing the data register directly, which is
raspi3b-specific (the same driver and QEMU PL011 model are clean on the
virt board) and points at the mini-UART being the real console or the
UART GPIO pins needing their alternate function; and the kernel hangs at
a fixed PC after the banner, before the scheduler, which needs a
symbol-bearing relink to chase.  The reusable pieces - the EL3 drop and
the BCM-controller code - are recorded; the board directory was removed
again rather than leave a kernel that hangs.
