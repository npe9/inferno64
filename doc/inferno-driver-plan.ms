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
