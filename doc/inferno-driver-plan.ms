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
Done:
.CW usbd
parses the descriptor's global, local and main items, lays out the
input report bit by bit (padding included, which is where a naive
parser loses three bits and reads X wrong), and drives the axes and
buttons it finds.  Verified against QEMU's
.CW usb-tablet
on both Pi configurations that carry USB: the parser derives a 48-bit
report with absolute X at bit 8 and Y at bit 24, and an absolute point
commanded in the tablet's 0..32767 units arrives on
.CW /dev/pointer
as the matching screen coordinate.  A boot mouse is attached at the
same time and still reports, from the same reader.
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
is HVC #0 with the SMCCC arguments already in R0-R3;
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
system registers, reached in
.CW l.s
through the assembler's
.CW SPR()
system-register operand with named defines; SGI/PPI enable state lives in
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
virt32, the riscv32 board, and a compiler bug under it:
.CW ethervirtiommio.c
and the ip stack now link on riscv32 as well, and the board's
.CW virtiobase
is seeded from the DTB the way riscv64/virt's is.  The driver needed no
change \(em it is MMIO registers and fixed-width ring fields \(em but it
did not work, because zc stored every 64-bit integer high word first on
a little-endian machine, so a virtio descriptor's
.CW addr
field sent the device
.CW pa<<32
and QEMU put 618 zero bytes on the wire.  Four places had to be
corrected together:
.CW libkern/vlrt-riscv32.c 's
.CW Vlong ,
zc's constant path in
.CW cgen.c ,
its initialised-data path in
.CW swt.c ,
and the hand-written
.CW _mulv
in
.CW libkern/vlop-riscv32.s .
The same widening goes on
.CW virt32s ,
the supervisor-mode riscv32 board, unchanged but for its PLIC context,
which proves the virtio window is reachable from S-mode under OpenSBI;
it joins the suite as a fourteenth configuration.
Verified: DHCP over the virtio-mmio NIC and three pings answered on
both boards, virt32 from two markers to five, and
.CW tod.c 's
.CW todfix
guard \(em which had been printing on every tick of this board and no
other, because
.CW clock.c
read the CLINT's 64-bit mtime word-swapped \(em silent.  Full account in
.CW doc/inferno-ports.ms .
.PP
riscv supervisor mode, the rest of item 5: both S-mode boards now run
in the suite.
.CW virt32s
is riscv32 under OpenSBI, and
.CW virts
\(em riscv64 under OpenSBI, in the tree but never run \(em comes back
with
.CW virt 's
marker set exactly, the same 42 markers and the same 12 known
.CW -FAIL .
Every driver the board has, from the virtio-mmio disk to NVMe over PCI
to the framebuffer to Styx over TCP, reads the same from supervisor
mode as from machine mode.  Its one missing piece was
.CW /n/styx
in the root file list.
.PP
.CW sifiveu
reads its device tree, the last riscv board that did not.  Its
.CW l.s
destroyed the pointer on the second instruction \(em
.CW a1
held the DTB address at entry and
.CW "MOV $BOOT_HART_ID, R11"
overwrote it before anything looked \(em so the register is now copied
aside first and stored by the boot hart alone, once
.CW SB
is set.
.CW main()
seeds
.CW plicbase
from
.CW riscv,plic0
and the GEM driver's
.CW gembase
from
.CW sifive,fu540-c000-gem
before
.CW trapinit()
and
.CW chandevreset()
respectively, and reports the UART and CLINT against
.CW mem.h
without seeding them: the console is up long before any of this runs
and is the only way a wrong address would be seen at all, so a board
that discovers its own console cannot tell you when it discovers the
wrong one.
.PP
The marker asserts agreement rather than discovery.
.CW SIFIVEU-FDT-OK
is printed only when all four nodes were found and the two seeded
values equal the constants; a tree naming an address the board cannot
use would have satisfied a bare \(lqfound it\(rq.  Two negative builds
say the wiring is live rather than decorative.  With
.CW mem.h 's
.CW PLIC
and
.CW GEM0
deliberately wrong \(em
.CW 0x0d000000
and
.CW 0x10091000
\(em the board still reached
.CW DHCP-OK
and a shell, printing
.CW "SIFIVEU-FDT-FAIL plic 0xc000000 gem 0x10090000" :
the tree's numbers were the ones the PLIC and the driver actually used.
With every
.CW fdtreg
compatible string changed to one no node carries, the constants stood,
and the board reached
.CW DHCP-OK
and a shell just the same \(em which is the claim the source comments
make in two places, that a lookup miss cannot hang a board that boots
today, demonstrated rather than asserted.
.PP
The same board's SD-over-SPI stack runs too.
.CW sifiveu
had printed
.CW SD-NONE
on every suite run since it joined, and the reason was that nothing
handed it a card: the FU540 has no SD host controller, so QEMU's
.CW sifive_u
puts an
.CW ssi-sd
on
.CW spi@10050000
and
.CW "-drive if=sd"
reaches it through
.CW sdspisifive.c
over
.CW spisifive.c ,
a driver stack no other configuration in the suite exercises.  With a
blank card attached, block reads, a write and read-back, a sixteen-block
single-call transfer and a kfs reamed and round-tripped all worked the
first time.
.CW sifiveu
goes from five markers to nine.
.PP
Item 6 is done as far as this machine allows.  Report-descriptor
parsing works and is in the suite; the USB-Ethernet driver works, on
both its ECM and its SMSC paths, and what is blocked is only a second
.CW devip
ethernet beside an existing one; virtio-gpu 3-D has no QEMU here built
against virglrenderer.  All three are written up above.
.PP
Remaining: MSI (item 4), the ASIX and Realtek USB dongles named in the
USB list's item 3 (neither is modelled by any QEMU machine this tree
boots, so they would need a model written first, as
.CW usb-lan9514
was), and item 7 (per-SoC drivers), which needs silicon.
.CW virtarm64
stays blocked for a different reason than the rest: QEMU's
.CW -kernel
path hands an arm64 kernel
.CW "x0 == 0" ,
so there is no pointer to read, and
.CW spike
has no device tree to read at all.
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
virtio-gpu 3-D needs a QEMU built against virglrenderer, and neither
QEMU on this machine has one:
.CW "-device virtio-gpu-gl-pci"
is \(lqDevice not found\(rq on the packaged 10.1.3, and this tree's own
patched build
.CW ( tools/qemu-patches )
is aarch64 only and configured without it.  The 2-D path is done and in
the suite; the 3-D backing for draw3d has nothing here to run against.
.IP \(bu
A second devip ethernet over USB faults the Dis interpreter.  The
controller and the enumeration are real:
.CW virt
links
.CW devusb ,
.CW usbxhci
and
.CW usbxhcipci ,
and with
.CW "-device qemu-xhci -netdev user,id=n1 -device usb-net,netdev=n1"
the board finds the controller
.CW ( "usbxhci: 0x1b36 0xd: port 40000000 size 16384 irq 33" ),
.CW usbd
enumerates the CDC ECM device
.CW ( "vid 0525 did a4a2 class 2" ),
.CW etherusb
serves
.CW /net.alt/ether
over its two bulk endpoints, and
.CW devip
binds it.  The next step faults:
.P1
exception cause 0x5 epc 0x800641ee tval 0x6f
.P2
which resolves against the kernel's own symbols to
.CW movp+0xe
called from
.CW xec+0x2a4 .
Offset 0xe is
.CW OP(movp) 's
own first load,
.CW "sv = P(s)" ,
so what was bad is the source
.I slot
address and not the pointer in it \(em the addressing mode reached
0x6f, which is a nil frame or module pointer plus a field offset.
.CW OP(movp) 's
.CW badptrslot()
guard never fired, because it checks the value it read and this
faulted reading it.  That is the same family as the interpreter crash
hunt written up at length in
.CW doc/inferno-ports.ms ,
and it is in the interpreter rather than in any driver.
.PP
That was wrong, and the
.CW tval
above is what says so.  0x6f is not a random slot: it is the address
.CW OP(movp)
computes for
.CW req
in
.CW dhcpclient.b:522 ,
and
.CW req
is nil there because
.CW setup()
returns
.CW err
where it means
.CW err2
and hands back a nil request with a nil error.  Not timing, not the
interpreter, not a driver: a wrong variable in a return, in a library
every caller of
.CW dhcp()
or
.CW bootp()
goes through.  It reached the interpreter as a fault because a nil
dereference in Limbo does fault a native kernel where it ought to
raise \(em that part stands, and is still worth fixing \(em but it was
never what made this configuration fail.  Item 4 below, and
.CW doc/inferno-ports.ms ,
have the whole of it.
.PP
One more correction belongs to that run, made when the same
controller was put in the board suite on
.CW virtarm64 .
\(lqThe controller and the enumeration are real\(rq is true, but the
enumeration was working on luck on two separate counts, and both were
found by running it a second time on a different board.
.PP
The first is in
.CW usbd
and not in any driver.
.CW newhub()
built its hub with a bare
.CW "ref Hub" ,
which leaves every word of the adt that holds no pointer
uninitialised, and
.CW failed
is the one field nothing in the program ever assigns.  It is read at
the top of
.CW enumhub() ,
and a hub whose
.CW failed
came up non-zero is never scanned at all: the hub is in the list, it
prints with its right port count, and no port is ever asked whether
anything is attached.  There is no message, because the only code that
sets
.CW failed
is the one place that reports it.  On
.CW virtarm64
that word was
.CW 758331446
on every boot, and the symptom was a controller that found its root
hub, said \(lq8 ports (root)\(rq, and then did nothing whatever.  Every
board this had run on before happened to give it zero.  The hub is now
built with all six fields named, the way the
.CW "ref Port(0, nil, nil)"
two lines below it always was.
.PP
The second is in
.CW usbxhci.c ,
and it is a device register read by
.CW memmove() .
The xHCI Supported Protocol capability names its protocol in one
32-bit register \(em \(lqUSB \(rq \(em and the driver copied it with
.CW "memmove(pp->spec, &x[1], 4)" ,
which on this architecture reads it a byte at a time.  A byte read of a
device register is not the same bus transaction as a word read of the
word containing it: on QEMU only offset 0 answers and the other three
come back zero, so the spec read
.CW "U\e0\e0\e0" ,
the
.CW memcmp
against \(lqUSB \(rq never matched, and
.CW hp->superspeed
stayed empty however many USB 3 ports the controller reported.
.PP
\(lqOn this architecture\(rq is load-bearing, and the commit that fixed
this,
.CW 2d307d69 ,
does not say it.  There is no portable
.CW memmove
that reads four bytes one way.
.CW libkern/memmove.c
is a
.CW "*s1++ = *s2++"
byte loop and is what aarch64, riscv64 and riscv32 link, because those
are the architectures with no assembly version.
.CW libkern/memmove-amd64.s
ORs source and destination, tests the low two bits, and when both are
aligned \(em which
.CW &x[1]
and
.CW pp->spec
are \(em issues one
.CW "REP MOVSL" ,
a single 32-bit read.  So amd64 never had this bug, and a
.CW pc64dev
boot of the driver as it stood before the fix proves it: two root hubs
at four ports each, and the stick enumerated
.CW super .
The bug is the portable byte loop meeting a device register, not
.CW memmove
in general, and the boards that had it are the ones with no assembly
.CW memmove .
.CW devusb
makes one root hub per speed out of that mask, so the board saw a
single flat eight-port high-speed hub, and a SuperSpeed device on it
was reset and addressed as a full-speed one.  It worked, which is why
nothing caught it.  The register is now read as a word and unpacked,
and the board makes the two root hubs it should \(em four high-speed
ports and four SuperSpeed \(em with a mass-storage device coming up
.CW super
on the second, through
.CW portattach() 's
.CW isusb3
branch, which had never run.
.PP
So the riscv
.CW virt
run stands as a description of what was seen, and this is what it was
really doing.
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
card over the MMC-SPI controller works too, and this paragraph used to
say the opposite, so the correction belongs here rather than a
footnote.  It read: the SD-over-SPI handshake was written and exercised
but no slave ever answered, QEMU wires the card's chip-select to a GPIO
line
.CW ( ssi-gpio-cs )
the SiFive SPI's
.CW csmode
never touches, sweeping all sixteen GPIO pins never selected it, and so
SD-over-SPI was a model limitation and unreachable here.  That
conclusion was wrong, and the reason it looked right is worth keeping:
QEMU's
.CW sifive_u
creates the
.CW ssi-sd
and its
.CW sd-card-spi
whether or not a card is behind them, and the qtree is character for
character the same either way \(em
.CW "drive = \(dqsd0\(dq\&"
and all, naming a blockdev that does not exist \(em so the qtree that was
read as proof that a card was attached was showing an empty slot.
.CW "info qtree"
with and without
.CW "-drive if=sd"
was compared on 10.1.3 to be sure of that, since it is the whole reason
the earlier conclusion looked well founded.  Handed a real card, the
same handshake completes, and
.CW sdspisifive.c
reads blocks, writes and reads a block back, moves sixteen blocks in
single calls, and carries a reamed kfs with a file round-tripped
through it.  The chip-select was never the problem; the empty slot was.
The flash JEDEC read shows the SPI driver works against a real slave,
and the card now shows it works against two.  I2C is a
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
0x3c5 (EL1h, DAIF masked), ELR_EL3 to the EL1 entry.  The EL3/EL2
registers are written with
.CW MSR
through the assembler's
.CW SPR()
operand and named defines (D_HCR_EL2, D_SCR_EL3, D_SPSR_EL3,
D_ELR_EL3); CurrentEL is a named
.CW MRS
operand.
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
.PP
Round 4 finished raspi3b - it boots arm64 Inferno to a clean shell,
zero faults, three of three.  The two blockers had ONE root cause,
found by investigation rather than guessed: QEMU's raspi3b is a
quad-core Pi and starts all four cores at 0x80000, and this MAXMACH-1
kernel had all four running the boot and writing the console - that was
both the "garbled console" (four cores interleaving) and the "crash
after memory init" (four cores conflicting).  Parking the three
secondaries at the top of l.s (MPIDR affinity, WFE spin) fixed both at
once.  With that, the EL3 drop, the delay-paced PL011, and a generic
timer recognised by its own CNTP_CTL.ISTATUS (QEMU maps no local IRQ
controller - 0x40000000 is RAM) all fell into place.  The board is the
one that reaches the Pi's I2C, SPI and GPIO, which QEMU raspi3b models
and which are the next work.
.NH 1
Round 5: raspi3b serial peripherals - I2C, SPI, GPIO
.PP
Round 5 gave raspi3b its three BCM2835 serial controllers, each with a
driver that runs at boot and proves itself against an attached slave, so
the board now answers the original I2C/SPI/GPIO question concretely and
not by assertion.
.PP
The I2C driver
.CW ( i2cbcm.c )
drives BSC0 at 0x3f205000 - the only BSC QEMU maps in the ARM address
space (i2c-bus.0).  The transfers that stalled in round 4 were pinned by
reading QEMU's
.CW hw/i2c/bcm2835_i2c.c :
the model sends each byte the instant the guest touches the FIFO
register and only while S_TA is set, so the working order is to write C
with I2CEN|ST first (which starts the transfer and sets S_TA) and push
the bytes after - filling the FIFO before ST silently drops the data and
the transfer never completes, which was the whole of the earlier hang.
The at24 EEPROM model itself hangs on a data byte, so verification uses a
ds1338 RTC instead
.CW ( "-device ds1338,bus=i2c-bus.0,address=0x68" ):
write a byte to its NVRAM, read it back, exact match.  With no slave the
address write NAKs and the driver reports an empty bus; the kernel boots
either way.
.PP
The SPI driver
.CW ( spibcm.c )
drives SPI0 at 0x3f204000.  QEMU's bcm2835-spi does one full-duplex byte
per FIFO write while CS_TA is set, storing the MISO byte for the next
FIFO read, and it asserts the slave chip-select implicitly, so an
attached serial flash answers a JEDEC-id read directly
.CW ( "-device m25p16,bus=spi,cs=0,drive=mtd0" gives jedec 20 20 15).
.PP
The GPIO driver
.CW ( gpiobcm.c )
drives the block at 0x3f200000: GPFSELn for direction, GPSETn/GPCLRn to
drive an output, GPLEVn to read it back.  QEMU keeps the level register
faithful to the set/clear writes, so pin 21 configured as an output
drives high then low and reads back 1 then 0 with no external observable.
A single boot with all three slaves attached exercises the I2C round
trip, the SPI JEDEC read and the GPIO pin drive together, then the shell.
.NH 1
Round 6: sifive_u SD-over-SPI - a falsified blocker
.PP
Round 6 read block 0 off an SD card over the sifive_u SPI2 controller
.CW ( sdspisifive.c ),
negative-controlled against two images whose first bytes each read back
exactly.  It also retired a stored conclusion.  The earlier note held
that the SD was blocked because QEMU wired its chip-select to a GPIO pin
the SPI controller could not reach; reading
.CW hw/riscv/sifive_u.c
settled otherwise - the card's CS is
.CW cs_lines[0]
of SPI2 itself (its sysbus irq line 1), wired exactly as the NOR flash's
CS is on SPI0, and driven by the same CSMODE=HOLD the flash already uses.
The macro named in the wiring,
.CW SSI_GPIO_CS ,
is QEMU's name for a peripheral's own input pin, not the GPIO block.
The real cause of the old all-0xff reads was mundane: the flash probe
sent a JEDEC command (0x9f) to the SD, leaving QEMU's ssi-sd state
machine stuck mid-command; the flash probe no longer touches SPI2.
.PP
Three facts from the QEMU models made the handshake work first boot.
The SSI layer gates transfers on CS, so the classic 74-clock wake-up
with CS deasserted is inert - CS is held asserted for the whole session
instead.  A command's CRC byte is ignored but must be present, so a
short frame silently does nothing (the same shape as the BCM I2C bug).
And after CMD0/CMD8/ACMD41 the card sits in ready state while CMD17
demands transfer state, which SPI mode has no CMD2/3/7 to reach - but
.CW sd.c 's
.CW spi_cmd_SEND_CxD
advances the card to transfer state when the CSD is read, so CMD9 (a
normal init step) bridges the gap before CMD17.
.NH 1
Round 7: sifive_u SD as a real block device
.PP
Round 7 promoted the SD read into a proper Inferno storage device.
.CW sdspisifive.c
became an SDifc driver with a block-I/O
.CW bio
callback, and the board's config gained
.CW devsd
(the dev-section entry
.CW sd ),
so devsd exposes the card as
.CW /dev/sdM0/data
spanning the whole disk.
.CW online()
runs the SD-SPI init once and reads the CSD to size the card - CSD v1
(SDSC) is byte-addressed, v2 (SDHC) block-addressed; the 64MB QEMU card
decodes to 131072 byte-addressed sectors -
and
.CW bio()
serves reads with CMD17.  The init program reads block 0 and block 1
back through
.CW /dev/sdM0/data ,
the end-to-end proof through the file interface, negative-controlled
against a second image with block 1 taken from byte offset 512.  One
model quirk surfaced: CMD58 (READ_OCR) before CMD9 is load-bearing -
drop it and CMD9 returns R1 but queues no CSD data.
.NH 1
Round 8: writes, multi-block, and a kfs filesystem on the SD
.PP
Round 8 finished the SD stack.
.CW bio()
gained the write path (CMD24 plus the 0xfe data token, the block, a
dummy CRC and the card's accept byte), so
.CW /dev/sdM0/data
is read/write.  The multi-block path - a filesystem hands
.CW bio
many blocks at once - was verified by writing 16 blocks in one
.CW pwrite
and reading them back in one
.CW pread ,
each block index-tagged so a misalignment names the block; it passes,
so every block leaves the ssi-sd state machine cleanly in CMD state.
Then a real filesystem: the init reams a
.CW kfs
onto
.CW /dev/sdM0/data ,
mounts it at
.CW /tmp
(kfs serves Styx on its fd 0, so it runs on one end of a pipe whose
other end is mounted), and round-trips a file - the content, the
directory entry and the kfs label all persist to the backing image.
The SD-over-SPI stack is complete end to end: controller, block device,
filesystem, file.
.NH 1
Round 9: raspi3b native-SD block device
.PP
Round 9 gave the Pi a storage device.
.CW sdhostbcm.c
drives the BCM2835 SDHOST controller (0x3f202000) in native SD mode and
plugs into devsd as
.CW /dev/sdM0/data .
QEMU routes the -sd card to the generic SDHCI by default; it reaches
SDHOST only with GPIO pins 48-53 in alt0, so
.CW online()
routes them (through the round-5 GPIO driver) and then runs the real
native-SD init - CMD0/8, ACMD41, CMD2 (CID), CMD3 (RCA), CMD9 (CSD,
decoded for the sector count), CMD7, CMD16 - not the SPI-mode protocol
sifive_u uses.
.CW bio()
moves blocks through the SDDATA FIFO a word at a time, CMD17 for reads
and CMD24 for writes.  Verified read, write and multi-block through
.CW /dev/sdM0/data ,
negative-controlled, persisting to the backing image.
.PP
A kfs on top does not run on the Pi yet, and chasing why settled two
things worth keeping and left one hard bug open.
.PP
First, raspi3b has no periodic scheduler tick.  The generic-timer
interrupt is a PPI, and with no GIC it reaches the core only through the
BCM2836 per-core interrupt controller, which QEMU models at 0x40000000
(an earlier note that the address was only RAM was wrong; the control
block shadows the RAM).  Nothing routes it, so the kernel runs
cooperatively.  A one-line write of the Core0 timer-control register
(0x40000040 bit 1, CNTPNSIRQ) turns on a real 100Hz tick.  Second, doing
that flushed out two genuine SD-driver bugs, both fixed and kept:
.CW online()
returned on its re-init path without restoring
.CW unit->sectors
(devsd zeroes them before each call, so a walk could drop the data
partition), and
.CW bio()
drove the controller through a non-atomic register sequence with no
lock; a per-controller
.CW QLock
now serialises it.
.PP
Enabling the tick then exposed what looked like a preemption-safety bug
in the transfer, and chasing it to ground took a long hunt through
several wrong trees (the atomics, a QEMU-TCG residual, a multi-kproc
race) - all ruled out by test.  The real cause was in
.CW vectrap
and had nothing to do with SD: it builds the
.CW Ureg
on the stack at
.CW SP
and calls
.CW trap(&ureg) ,
but Plan 9's arm64 convention homes the callee's first argument at
caller-
.CW SP+8 ,
which is exactly
.CW UR_R1 ,
so trap()'s prologue spilled its argument onto the saved
.CW R1
every interrupt.  Harmless wherever
.CW R1
was dead; catastrophic when a timer IRQ landed in
.CW irestore 's
fixed-size
.CW "R = p->R"
copy, whose loop counter is
.CW R1
- the copy then ran unbounded and walked memory upward from the global
.CW R
(silent with the MMU off, the
.CW "file does not exist"
symptom; a read-only-page-table fault with it on).  The full account is
.CW doc/raspi3b-preempt-plan.ms .
The fix reserves the argument-home area below the Ureg in
.CW vectrap
(l.s, both raspi3b and virtarm64); with it, the one-line timer routing is
committed and the board runs a real 100Hz preemptive tick.  Proven not
guessed: an instrumented qemu showed the saved
.CW x1
slot overwritten on 600 of 600 interrupts before the fix and 0 after,
and the 2000-block stress that faulted about one run in eight passes 24
of 24 with the real preemptive
.CW clockintr .
QEMU was correct throughout; no emulator change was needed.
.NH 1
Immediate next steps (cold-start)
.PP
The board work stands at: all four riscv virt boards, arm64 on both GIC
versions with a display, sifive_u with SPI, GEM ethernet and an SD-over-
SPI stack complete to a kfs filesystem, shakti (riscv64), and the
Raspberry Pi 3B (arm64) with I2C/SPI/GPIO and a native-SD block device
(/dev/sdM0/data, read/write/multi-block) - every board booting to a
clean shell, and raspi3b now runs a real preemptive 100Hz tick (the
SD-under-preemption bug is fixed - the vectrap argument-clobber above).
The prioritized next work: (1) finish a kfs filesystem on the Pi.  With
the tick working, kfs now reams
.CW /dev/sdM0/data ,
mounts over a pipe, and serves Styx (proof the preemptive scheduler
time-slices the kfs server against the init client), and the mount root
is stat-able - but a
.CW create
deterministically hangs, where sifive_u with the identical recipe
succeeds.  The hang is localised: a bio trace shows no SD I/O during it,
so it is not the driver; it is in
.CW devmnt 's
.CW mountrpc
error path, at the
.CW error(ename)
that a benign walk-Rerror (the create's existence check) raises -
sifive_u prints
.CW "mntwalk waserror()"
and recovers, raspi3b never reaches that line.
.CW setlabel / gotolabel
are byte-for-byte the same minimal SP+PC form riscv64 uses and are not
the difference.  Instrumenting the error stack corrects an earlier read
that called this a livelock: it is a
.I deadlock ,
and
.CW up->nerrlab
does not climb - it holds steady at 7.  Only about a dozen Enonexist
unwinds happen in the spawned "dis" kproc (pid 3) - the ordinary
per-union-member misses as kfs resolves
.CW /dev/time
through the three-member
.CW /dev
union - and then both procs block.  The create's existence-check Twalk
gets its benign Rerror (correct Styx: the file does not exist yet), and
.CW pid 1 's
.CW error()
is entered - the
.CW mountrpc
print fires immediately before it - but a print on
.CW error() 's
very first line never appears even ungated, so pid 1 stalls in
.CW error() 's
prologue right after its
.CW spllo() ,
and the kfs kproc, having sent that reply, also blocks.  No
.CW "trap type"
or panic ever prints, so it is not a fault or a stack overflow (KSTACK is
32KB, the same as riscv64); the SD path is sound (kfs reams the whole
filesystem, every
.CW bio()
completing in pid 3); and the nerrlab count and label machinery are
sound.  The remaining lead is the multi-kproc handoff itself: pid 1 is
not resumed after yielding at that
.CW spllo()
to the spawned kproc, which then sleeps - a sleep/wakeup or Dis
.CW release()/acquire
token-handoff bug, not a memory-ordering one (the board is MAXMACH 1 and
.CW _tas / unlock
already carry their DSB barriers).  And the spawn is load-bearing:
forcing single-kproc (removing release()'s kproc("dis",...)) deadlocks
the mount outright - nothing serves kfs while the client blocks.  The
reproducer is committed: uncomment
.CW sdfs()
in raspi3binit.b.  (The SDHOST flow control an earlier draft asked for
here has since been added; see fifospace()/fifodata().)
(2) persistence across reboot on sifive_u - the kfs is reamed every boot;
a mount that reams only a blank device would show a file surviving a
restart.  (3) more boards if wanted - the loop is proven, and the one
rule that matters for any multi-core board is to park the secondary cores
first.  A cross-cutting note from the tick hunt: the arm64
.CW vectrap
frames the Ureg on the interrupted stack, so any C handler it calls needs
its argument-home area reserved below the Ureg; armv7 and riscv64 use a
static Ureg buffer and are not exposed.
.NH 1
Raspberry Pi 3B: the port order beyond kfs
.PP
The board now drives PL011, GPIO, BCM2835 I2C and SPI, the generic timer
with a real 100Hz tick, and native SD through SDHOST, and it boots the
firmware's own flat kernel8.img at EL2.  That is past the unpleasant
bring-up jobs; what remains is user-visible hardware, and 9front's
bcm64/pi3 tree is now a donor rather than just a reference.  The order,
each item roughly gating the next:
.IP 1.
Firmware mailbox / property interface.
.B DONE
(mailbox.c): the ARM<->GPU mailbox 0 property channel, verified against
the model's fixed answers (firmware revision, ARM memory split) and used
to allocate the framebuffer below.  It is the key that unlocks clocks,
board info and the framebuffer.
.IP 2.
Framebuffer plus an Inferno screen driver into devdraw.
.B DONE .
The firmware allocates a 640x480x32 buffer over the mailbox
(mboxfballoc), a screen driver (screenbcm.c) draws into kernel RAM and
flushes dirty rectangles to it, and the Limbo draw device now renders
into it: a monitor screendump shows virtarm64 (ramfb) filled solid red
(correct colour, all 307200 pixels) and raspi3b showing three drawn
colour bands.
.PP
Getting there uncovered a real 7c code-generation bug, since neither
arm64 board had ever exercised memdraw's draw() combine (virtarm64's
draw check only reads the /dev/draw ctl, and its TK path never runs).
The
.I crash
was that on arm64 REGRET==REGARG==R0, and sugen()'s OSTRUCT
side()-branch built a struct-by-value argument's destination address
into the return register, clobbering a pointer first argument still live
in R0 - so replclipr(Image*, int, Rectangle) got its Image* overwritten
by the Rectangle and faulted.  Fixed in utils/7c/cgen.c (take the
address into a general temporary, not regret).  An earlier note here
guessing a Readfn/Buffer struct-\fIreturn\fP ABI mismatch was wrong on
both counts: it was an argument, in replclipr/bufimage, and the
mechanism was regret aliasing REGARG.
.PP
A second symptom - imagedraw()'s drawop(d, IRECT(f->r), ...) arriving
with a corrupt rectangle (a code address in min.x), and lookupimage()'s
eqrect(IRECT(di->clipr), ...) comparing garbage and firing a spurious
replclipr the shared screen rejected - turned out to be one deeper 7c
bug, now root-caused and fixed.  On arm64 REGSP and REGZERO are both
register 31.  lcgen() addressed a stack slot with MOV $off(REGSP),reg;
in the object that operand classifies as a bare constant (7l aclass:
a->reg == REGZERO), so the SP base is dropped and the register gets off,
not SP+off.  A struct-by-value argument built into the outgoing arg area
is thus written through the constant, and the callee reads the slot's
stale value.  Fix in utils/7c/cgen.c: address a REGSP slot with ADD
$off, REGSP, reg - ADD/SUB read register 31 as SP.  Both source
workarounds are gone; the draw device renders with unmodified draw.c.
(This is why it never showed in a -S of imagedraw in isolation: the
symptom depends on the constant/SP classification 7l does at link time.)
The lesson: fix the tool, not the caller (AGENTS.md).
(Do NOT start from the VideoCore GPU; the firmware framebuffer is the
path.)
.IP 3.
Synopsys DesignWare USB host (9front usbdwc).  The highest-value port:
on a Pi 3B the onboard 10/100 Ethernet hangs off USB, so the controller
buys Ethernet, keyboard, mouse, and mass storage at once.
.IP 4.
USB keyboard and mouse - makes the framebuffer interactive.
.IP 5.
LAN9514 / SMSC USB Ethernet into
.CW /net/ether* .
9front detects the Pi's USB Ethernet specially and loads the SMSC driver.
.IP 6.
USB mass storage into devsd - thumb drives as block devices.
.IP 7.
Arasan SDHCI / SDIO, the Pi's second SD controller (SDHOST already drives
the card, which deliberately leaves Arasan free for SDIO).
.IP 8.
BCM43430 Wi-Fi over that SDIO, borrowing 9front's ether4330.
.IP 9.
Watchdog, hardware RNG, PWM - individually small BCM283x drivers.
.PP
Left out on purpose until the machine is otherwise complete: Bluetooth
(a whole HCI/L2CAP stack for little payoff), CSI camera and DSI display
(VideoCore/firmware-bound), and GPU / OpenGL / hardware video (deep and
largely out of scope).  The kfs deadlock above is worth fixing for a
reliable native filesystem, but the port is not blocked on it: dossrv,
ramfs, and 9660srv all run over the same working SD block device.
.NH 1
What is left, and the reason each one is left
.PP
The QEMU-tractable part of this plan is done.  Items 1 through 5 are
finished and in the board suite \(em USB mass storage, virtio-gpu 2-D,
PCI on arm64, S-mode and SBI and the device tree on riscv \(em and item
6 is finished as far as anything on this machine can take it.  Six
things were listed here as remaining; three do \(em items 1, 2 and 4
have since been done, and the count in this sentence had already not
been kept up with item 2 before this round added two more to it.
Item 1 is now done as well, on both an interrupt controller that
routes MSI through a memory-mapped frame and one that routes it
through the local APIC, so what is written below under it is a record
rather than a plan.  None of the rest is
waiting on a decision or on more of the same work.  Each is here with the reason it stops, so that a reader
who has hardware, or a QEMU built differently, knows exactly which one
they have unblocked.  Every reason below is a fact about this host or
about silicon that is not here, and each one names the command that
re-checks it.
.IP 1.
.B "MSI and MSI-X."
.B DONE
for every one of
.CW virtarm64 's
PCI drivers:
.CW sdvirtio10 ,
.CW ethervirtio10 ,
.CW sdnvme
and
.CW usbxhcipci .
Nothing on this board takes
.CW p->intl
any more when a router is present.
.PP
.CW sdnvme
came second and for a different reason.  It was linked into five board
configurations and had never executed an instruction, because no arm
had ever handed one of them an NVMe controller \(em QEMU models the
device fully, so what was missing was not a model but the asking.  The
.CW virtarm64-nvme
arm passes
.CW "-device nvme"
carrying the same FAT image the virtio arms use, and the driver reads
it, dossrv mounts it, and every marker the plain
.CW virtarm64
arm prints comes back over a different controller.
.PP
That last sentence is the trap, and it is why one more thing had to
change first.
.CW virtinit 's
.CW blkcheck()
opened
.CW /dev/sdF0/data
by name; on a board that links both drivers the letter is the only
difference between the two arms, and a run that quietly fell back to
the virtio disk would print the same forty-two markers.  So the init
looks for the first unit under
.CW #S
with a data file rather than naming one \(em which makes the arm
possible and the check weaker in the same stroke, since now either
controller satisfies it.  The name is put back as evidence, per arm:
six arms check
.CW "BLK-OK /dev/sdF0/data"
and this one checks
.CW "BLK-OK /dev/sdN0/data" .
Without that line the NVMe arm proves nothing at all.
.PP
The vector is the base SPI, 80, because this arm leaves the network on
virtio-mmio and
.CW sdnvme
is the only caller of the router \(em so it also checks the allocator
starts where
.CW MSI_TYPER
says, which the two-device arm cannot say.  NVMe needs nothing told to
the device beyond the capability: the admin completion queue is vector
0 by definition and
.CW setupqueues()
leaves CDW11's interrupt-vector field at 0 for the shared io queue, so
one vector covers both.  The
.CW INTMS
and
.CW INTMC
masking in the handler becomes a no-op \(em the spec says those
registers are not to be touched under MSI-X, and QEMU's
.CW nvme_write_bar()
drops the write with a guest-error trace \(em which is harmless, since
MSI-X has its own per-vector mask and nothing depends on the mask
having taken.
.PP
Delivery needed its own proof here for a sharper version of the reason
it did on the virtio disk.
.CW sdvirtio10
polls the used ring after a timed sleep;
.CW sdnvme 's
.CW wcmd()
goes further and calls
.CW nvmeintr()
itself in a loop while it waits, so a controller whose vector never
arrives completes every command and looks perfectly well.  The two
cases are told apart by the argument the handler already had and never
used: the polled call passes a nil
.CW Ureg
and a real interrupt arrives with the trap frame, so the first-interrupt
line counts only the latter.  It is a cleaner discriminator than
.CW sdvirtio10 's,
which has no equivalent.
.PP
.CW usbxhcipci
came third, and its arm found two bugs rather than needing one.  The
board has listed
.CW usbxhcipci
and
.CW usbxhci
since it was written and no configuration had ever given it a device,
which is the
.CW sdnvme
gap again \(em except that
.CW usbxhci
was not a driver that had never run, since the riscv
.CW virt
board had enumerated a CDC ECM device over it.  So the
.CW virtarm64-xhci
arm was expected to cost a root-file-list line and a check.  What it
cost is written up in
.CW doc/inferno-ports.ms :
.CW usbd
built its hub with a bare
.CW "ref Hub" ,
leaving the
.CW failed
field whatever the heap held, and a hub whose
.CW failed
is non-zero is never scanned and never says so; and
.CW usbxhci.c
read the Supported Protocol name string with
.CW memmove() ,
which on the architectures that link the portable
.CW libkern/memmove.c
\(em aarch64, riscv64, riscv32 \(em is a byte loop, and a byte read of a
device register returns the first byte and three zeroes, so
.CW hp->superspeed
stayed empty and every port looked like USB 2.  Both were in code
shared with configurations that were passing.  amd64 links an assembly
.CW memmove
that moves an aligned four bytes as one
.CW MOVSL
and never had the second bug at all.
.PP
The vector itself was the easy half.  xHCI ties interrupter
.I n
to MSI-X vector
.I n ,
this driver uses interrupter 0 only, and so \(em as with NVMe \(em
nothing has to be told to the device beyond enabling the capability.
What is new is which kind of device takes the frame's base SPI:
.P1
usbxhci: 0x1b36 0xd: irq 80 msi-x
usbxhci: first interrupt, irq 80 msi-x
sdF (virtio10): irq 81 msi-x
.P2
.CW usbinit()
runs the host controllers before devsd probes its units, so on this
arm the vector at the bottom of the frame goes to a host controller.
On
.CW virtarm64
the disk has 80 because it is the only caller of the router; on
.CW virtarm64-msi
the network has 80 and the disk 81; here the xHCI has 80 and the disk
81.  Both lines are checked, which is what says one frame handed out
two distinct vectors.
.PP
Delivery needs no separate argument on this arm, which is the one
place in this item where that is true.  Nothing in
.CW usbxhci.c
polls the event ring:
.CW waitrun()
sleeps until
.CW interrupt()
wakes it, and a transfer whose completion never arrives raises
\(lqtimed out\(rq rather than quietly finishing.  So every USB marker
the arm prints is already evidence that the vector arrived, and the
first-interrupt line only says which number it arrived on \(em the
opposite position from
.CW sdvirtio10 's
polled used ring and
.CW sdnvme 's
.CW wcmd() .
.PP
One correction to the
.CW sdnvme
entry above, found while doing this.  The comment added there said the
.CW Ctlr
needed explicit zeroing because it came from
.CW malloc()
rather than
.CW xalloc() .
That is false:
.CW malloc()
in
.CW os/inferno/port/alloc.c
memsets what it returns.  The initialisation is still right, because
.CW msivec
is \-1 for INTx and zero is a vector a device can be given, so it
cannot have zero as its default \(em but the reason given for it was
wrong and is now stated correctly in the source.
And \(em like item 2 \(em the reason this was deferred was wrong rather
than merely optimistic.  What this entry used to say was that PCI runs
on legacy INTx, which QEMU delivers correctly, so MSI buys nothing
here and is for real hardware needing more vectors than INTx has.
Both halves were false.  QEMU models the hardware fully: with the
default
.CW "-M virt"
GIC, which is a v2,
.CW hw/arm/virt.c 's
.CW create_gic()
instantiates an SBSA GICv2m frame at
.CW 0x08020000
with sixty-four SPIs starting at 80, and every virtio-pci function it
builds implements an MSI-X capability.  Nothing in this tree had ever
written to either.  And a GICv2 has no ITS, so the usual answer \(em
that MSI on arm means moving to GICv3 first \(em did not apply: a v2m
frame turns one memory write into one SPI, with no command queue, no
device table and no translation-table memory to allocate.
.PP
The portable half is in
.CW os/inferno/port/pci.c :
.CW pcimsixcount() ,
.CW pcimsixenable()
and
.CW pcimsixintr() .
MSI-X differs from MSI in where the message lives \(em not in config
space but in a table inside one of the function's memory BARs, named
by the low three bits of the capability's table register \(em so
enabling a vector means mapping that BAR, which is why the code takes
the same
.CW "bar & ~0xF"
route
.CW virtiomapregs()
does.  The board's router is a function pointer,
.CW pcimsirouter ,
nil by default: pc64 and the riscv boards link the same file unchanged
and every driver falls back to
.CW p->intl .
.PP
The board half is
.CW os/inferno/virtarm64/gicv2m.c ,
which finds the frame by its
.CW arm,gic-v2m-frame
node.  The node carries no
.CW arm,msi-base-spi ,
so the SPI range comes from the frame's own
.CW MSI_TYPER
register: the tree gives the address and the register gives the range.
.PP
Two things had to be right that were not obvious, and the second cost
the most.  A virtio 1.0 device with MSI-X enabled stops driving its
INTx pin and is not required to set the ISR byte at all (section
4.1.4.5; QEMU's
.CW virtio_pci_isr_read()
returns 0), so enabling MSI-X without also writing
.CW msix_config
and each queue's
.CW queue_msix_vector
is strictly worse than leaving it alone \(em and a handler that still
gates on the ISR byte discards every vector that does arrive.  Both
.CW sdvirtio10.c
and
.CW ethervirtio10.c
now do both halves.
.PP
The other was the trigger mode, and it is the reason the first working
configuration delivered nothing.  A GICv2m frame does not hold an
interrupt line up:
.CW gicv2m_set_irq()
is a
.CW qemu_irq_pulse() ,
up and straight back down.
.CW GICD_ICFGR
resets to level-sensitive, and on a level-configured input the
distributor tracks the level, so the "down" erased the "up" before
anything could observe it \(em the vector never became pending, let
alone late.  Every MSI SPI is now set edge-triggered by
.CW gicedge()
before it is handed out, which is what Linux's own
.CW gicv2m
driver does when it allocates these as
.CW IRQ_TYPE_EDGE_RISING .
Nothing else on this board needed it: a uart or a virtio-mmio device
holds its line.
.PP
That failure is also why
.CW gicv2minit()
proves the frame before trusting it.  It rings the doorbell with a cpu
store \(em which QEMU's
.CW gicv2m_write()
cannot distinguish from a device's \(em and reads the SPI back out of
.CW GICD_ISPENDR ,
and only then sets
.CW pcimsirouter .
.CW MSI-DOORBELL-OK
is that check, not a claim about any device.
.PP
The new
.CW virtarm64-msi
arm puts both the disk and the network on PCI, so each takes its own
vector, 80 and 81.  The network is the half that proves delivery:
.CW sdvirtio10 's
.CW vqio()
polls the used ring after a one-second
.CW tsleep ,
so a disk whose interrupts never arrive still answers every request and
prints
.CW BLK-OK
\(em which is exactly what it did before
.CW gicedge() .
.CW ethervirtio10 's
.CW rxproc
and
.CW txproc
sleep on the queue with no timeout at all, so
.CW DHCP-OK
over
.CW virtio-net-pci
cannot happen unless a vector really arrived.  The disk says so
directly as well, the first time an interrupt reaches its handler.
.PP
What is left is real hardware and pc64.  A GICv3 board would want the
ITS instead of a v2m frame, and
.CW virtarm64
already detects v3 at boot \(em it just has no ITS driver, because
.CW "-M virt"
gives it a v2 by default and an untested ITS path is worth less than a
tested v2m one.  pc64's MSI address is the x86
.CW 0xFEE00000
form and needs no frame at all.
.PP
A correction, and it is the useful part of this item.  Two commits \(em
.CW a1ba83d2 ,
which gave
.CW sdnvme
its vector, and
.CW 2d307d69 ,
which gave
.CW usbxhci
one \(em both say pc64 cannot be linked in this tree because
.CW mkfiles/mkfile-os-amd64
does not exist.  The file does not exist and pc64 does not want it.
.CW os/inferno/pc64/mkfile
sets
.CW SYSTARG=Inferno
in its own configurable-parameters block, so the line that reads a
target mkfile resolves to
.CW mkfiles/mkfile-Inferno-amd64 ,
which has been there all along.
.CW SYSTARG=os
is the arm64 and riscv board convention, passed on the command line
because those mkfiles do not set it themselves, and carrying it to pc64
asks for a file nothing in pc64 ever names.  Plain
.CW mk
in
.CW os/inferno/pc64
links
.CW ipc64 ,
7.3 MB, and it boots: multiboot entry, memory and page tables, ECAM at
.CW 0xb0000000 ,
.CW chandevreset
bringing up
.CW "#l0: i82574"
and
.CW "#S/sdE: ich" ,
the Dis interpreter, and
.CW /dis/sh.dis .
A commit message cannot be rewritten, so the record is set straight
here.
.PP
Two things are true instead.  The first is that nothing on pc64
installed a
.CW pcimsirouter :
.CW os/inferno/virtarm64/gicv2m.c
was the only file in the tree that assigned one, so
.CW pcimsixintr()
returned \-1 on pc64 and all four drivers fell back to INTx there.  That
was a gap in written code, not a build failure, and it was the item.
.B DONE :
.CW os/inferno/pc/mp.c
now has
.CW pcmsixrouter() ,
installed by
.CW mpinit() ,
and pc64 hands out LAPIC vectors:
.DS
.CW
usbxhci: 0x1b36 0xd: irq 65 msi-x
sdF (virtio10): irq 105 msi-x
sdN (nvme): using 1 submit queues, irq 113 msi-x
sdF: first interrupt, irq 105 msi-x
nvme: first interrupt, irq 113 msi-x
usbxhci: first interrupt, irq 65 msi-x
.R
.DE
Three functions, three vectors, each delivering, where before all
three shared two IOAPIC pins.  Both QEMU x86 machines this board
boots \(em
.CW "-M q35"
and
.CW "-M pc"
\(em and the fallback with
.CW *nomsix=1
puts all three back on the pins with everything still working.
.PP
The x86 half is smaller than the GIC half and interesting for the same
reason the arm64 one was.  The message is the one
.CW msiintrenable()
in the same file already sends \(em the
.CW 0xFEE00000
window, the destination CPU in bits 19:12, the vector in the low byte
and the assert bit above it \(em so
.CW pcmsixrouter()
is six lines.  What it costs is that a LAPIC vector is not an IOAPIC
pin, and
.CW intrenable()
on this board is written around pins, so
.CW mpintrassign()
needs one branch that recognises a vector the router already allocated.
It recognises it off
.CW "Pcidev.msixirq" ,
which
.CW pcimsixintr()
records for its own reuse, so no second table is needed.
.PP
The thing that had to be learned by running it is why this is a router
at all rather than a hook inside
.CW intrenable() ,
which is where MSI sits four functions away.  The first version did
put it there: every PCI function with an MSI-X capability got a vector,
no driver asked for anything, and it looked like a strictly better
default.  On the same
.CW pc64dev
boot the virtio disk stopped reporting interrupts entirely and DHCP
over the i82574 failed.  Enabling MSI-X on a function changes how that
function delivers, and for several classes the driver has to say
where: a virtio 1.0 device leaves every queue at
.CW VIRTIO_MSI_NO_VECTOR
until the driver writes
.CW queue_msix_vector ,
and an e1000e leaves its
.CW IVAR
registers unmapped.  Turning the capability on behind such a driver
does not upgrade it, it silences it \(em and the disk said nothing
because it polls its used ring, so it still read sector 0.
.CW pcimsixintr()
is the driver's own request, so a router is opt-in by construction:
.CW sdnvme ,
.CW sdvirtio10
and
.CW usbxhcipci
call it and are written to program whatever else their device needs;
the i82574 and the ICH do not, and keep the plain MSI they already had.
.PP
The second is that a pc64 suite arm is blocked behind something else
entirely: the heap corruption
.CW doc/inferno-ports.ms
has a hunt of its own for, at
.CW markheap+26 ,
.CW destroy+649
and
.CW alloc:D2B .
Two boots taken while writing this landed in the same family \(em a
general protection violation at
.CW indc+0xc2 ,
and a page fault at
.CW destroy+0x273
with
.CW CR2
all ones \(em from one binary and one command line, with an
.CW indl
index of
.CW 0xF0002A74696E692B ,
which is the ASCII of
.CW +init*
and not an index at all.  The panic arrives long after
.CW chandevreset ,
so driver initialisation on pc64 can be shown without touching that
hunt; a marker-counting arm cannot, because the shell never comes up.
.IP 2.
.B "arm64 device-tree discovery."
.B DONE
for
.CW virtarm64 ,
and the reason it was listed as blocked was wrong.  QEMU's
.CW -kernel
path does enter an arm64 ELF with
.CW "x0 == 0" ,
so the pointer the riscv boards read is not passed \(em but
.CW hw/arm/boot.c 's
.CW arm_setup_direct_kernel_boot()
loads the ELF and then, if
.CW "image_low_addr > loader_start || image_high_addr < loader_start" ,
writes the machine's generated tree at
.CW loader_start
anyway.
.CW virtarm64
linked at exactly
.CW 0x40000000 ,
which is
.CW loader_start ,
so that test was false and no tree was written at all.  The gate was
the link address.  The board now links 2MB up, finds the tree at
.CW PHYSDRAM
by its magic, drives its virtio-mmio and PCIe ECAM bases from it, sizes
memory from it \(em
.CW "-m 1G"
was giving the board 256MB \(em and prints every other finding beside
what
.CW mem.h
assumed.
.B DONE
for
.CW spike
too, and the claim that it is handed no tree was wrong the same way.
QEMU's
.CW -M
.CW spike
writes a six-instruction reset ROM at
.CW 0x1000 :
.DS
.CW
	auipc	t0, 0
	addi	a2, t0, 0x28
	csrr	a0, mhartid
	ld	a1, 0x20(t0)
	ld	t0, 0x18(t0)
	jr	t0
.DE
with the kernel entry at
.CW 0x1018
and the tree's address at
.CW 0x1020 ,
so
.CW a1
holds the tree at entry exactly as it does on
.CW virt
and
.CW sifiveu .
The board's
.CW l.s
had simply never saved it.  It does now, and drives its memory size,
its CLINT timebase and its reporting from the tree.
.PP
The tree's placement turns out to be an architecture difference and not
a machine one.  On arm64 the tree goes below the kernel's link address,
under
.CW conf.base0 ,
where nothing will ever reach it.  On riscv every machine goes through
.CW riscv_compute_fdt_addr()
and the tree lands at
.CW dram_end-2MB
\(em
.CW 0x87e00000
at the 128MB default,
.CW 0xffe00000
at
.CW "-m 2G" ,
and OpenSBI passes the same address on rather than relocating it \(em
which is inside the range
.CW confinit()
hands to the allocator.  So this was not a
.CW spike
problem:
.CW virt ,
.CW virts ,
.CW virt32 ,
.CW virt32s ,
.CW sifiveu
and
.CW shakti
were all reading a tree the allocator owned, surviving only because
nothing had allocated that far up yet.  Each of the seven now trims
.CW conf.topofmem
down to the blob, and
.CW spike 's
smoke test checks that the xalloc extent's top is the blob's own
address rather than trusting the print.
.PP
Sizing memory from the tree went to those six as well, and it mattered
most where nobody was looking:
.CW virt ,
.CW virts ,
.CW virt32
and
.CW virt32s
compile
.CW DRAMSIZE
as 256MB while the suite passed no
.CW -m
at all, so QEMU gave them 128MB and the kernels claimed
.CW 0x90000000
as the top of a machine ending at
.CW 0x88000000 .
The suite now names
.CW "-m 256M"
on those arms.
.IP 3.
.B "virtio-gpu 3-D."
Needs a QEMU built against virglrenderer.  The packaged 10.1.3 here
has no
.CW virtio-gpu-gl-pci
at all, and this tree's own patched build is aarch64 only and
configured without it.  The 2-D path is done and in the suite.
.PP
A second blocker was checked and is independent of the first, so a
reader who installs virglrenderer and rebuilds will still hit it.  This
QEMU has no OpenGL at all:
.CW "-display help"
lists
.CW none ,
.CW curses ,
.CW cocoa
and
.CW dbus ,
and every one of them answers
.CW "-display <backend>,gl=on"
with
.DS
.CW
qemu-system-aarch64: OpenGL support was not enabled in this build of QEMU
.R
.DE
.CW dbus
adds
.CW "dbus: GL rendering is not supported"
ahead of it.  So even with the device present there would be nothing
to hand it a context.  Both facts are one command each to re-check.
There is a third, which is this suite's own shape: it drives QEMU with
a serial console and greps markers, and a 3-D result is not something
a marker can carry.  Unblocking item 3 is a QEMU rebuilt on the host
with OpenGL and virglrenderer, and a way for the harness to assert on
a frame.
.IP 4.
.B "A second devip ethernet over USB."
.B DONE ,
and it was neither a crash-hunt item nor a driver one.  Two adapters
enumerated and
.CW usbd
started an
.CW etherusb
for each, but both served a directory named
.CW ether
and mounted it
.CW MREPL
over
.CW /net.alt ,
so the second replaced the first and the board had one interface
whatever was plugged in.
.CW etherusb
takes
.CW -i
now and
.CW usbd
numbers them.
.PP
The fault behind the interpreter panic was in
.CW appl/lib/dhcpclient.b ,
not in a board:
.CW setup()
returned
.CW err
where it meant
.CW err2
when
.CW udpannounce()
failed, and
.CW err
is reliably nil there, so the caller got a nil request together with a
nil error and read a field off it.
.CW dhcp()
and
.CW bootp()
both go through
.CW setup() ,
so every Inferno program that takes an address by DHCP inherits it.
With the right variable returned, the panic becomes
.CW "can't announce dhcp port: ... address in use" .
One
.CW devip
stack holds
.CW udp!*!68
once, and the first interface's lease has it.  The second interface
takes a static address on its own subnet and pings its gateway, which
still crosses the second adapter's bulk endpoints.
.CW raspi3b-2eth
and
.CW raspi4-2eth
run it on both host controllers, DWC2 and xHCI.  See
.CW doc/inferno-ports.ms .
.IP 5.
.B "The ASIX and Realtek USB dongles."
No QEMU machine this tree boots models either chip, so they would need
a model written first \(em the way
.CW usb-lan9514
was, in
.CW tools/qemu-patches
0003.  The difference is that the LAN9514 is the Pi 3B's own onboard
part, soldered to a board this tree boots, and the dongles are chips no
board here has.  The class is covered twice already: CDC ECM and the
SMSC vendor path, one of them exercised by the suite on two
configurations every run.  A model for a third would be nine hundred
lines of QEMU for redundancy.
.IP 6.
.B "Item 7, the per-SoC drivers."
The VisionFive 2's DesignWare GMAC, the Icicle's Cadence controllers,
the Pi 4's GENET and VL805, UEFI and ACPI on the arm64 servers.  These
need the silicon, and the two Pi items in
.CW doc/raspi4-plan.ms
that are blocked off this machine \(em the ARM timer's GIC line against
the BCM2711 datasheet, and the Arasan as the wireless part's SDIO \(em
are the same kind of thing.
.PP
Twenty configurations run on this host, and the fifteen that predate
this round run from a bare checkout inside a container, built there
from source.  What that buys is not the marker
count: it is that every one of these six statements can be checked
against a booted kernel by anyone who runs the suite, and that a change
which breaks one of the finished items says so in the same run.
.NH 1
Real boards worth supporting, and the order to do them in
.PP
Every machine this tree boots is QEMU.  That is the right place to
have written the drivers \(em twenty-one configurations fail in
seconds where a board takes a card swap and a serial cable \(em but it
is not where the work is worth anything.  The question is which real
parts to aim at, and the answer follows from what is already written:
PCIe with CAM and ECAM, NVMe, xHCI, AHCI, the 9front Ethernet set,
.CW libaml
for ACPI,
.CW os/inferno/port/fdt.c
for device trees, and
.CW uartdw.c
for the DesignWare UART that most non-Arm-designed SoCs carry.  A
board that needs only glue around those is close; a board that needs a
new bus controller is not.
.IP 1.
.B "An arm64 SystemReady machine \(em Ampere Altra, SolidRun HoneyComb, Arm's own reference parts."
The nearest of all of them, because the machine looks like the
.CW "-M virt"
board this tree already runs: GICv3, PSCI, PCIe ECAM, NVMe and an
Ethernet the tree has a driver for.  What landed for it is the
Interrupt Translation Service, in
.CW os/inferno/virtarm64/gicv3its.c :
a GICv3 has no v2m frame, so MSI means LPIs, a command queue, a device
table, a collection table and a per-device translation table, all
sized from
.CW GITS_TYPER
and
.CW GITS_BASER
rather than from what QEMU happens to provide.  Verified on
.CW "-M virt,gic-version=3" :
two PCI functions take distinct LPIs 8192 and 8193,
.CW "sdF: first interrupt"
says the second was delivered through the redistributor, and
.CW DHCP-OK
says the first receives.  The
.CW virtarm64-gicv3
suite arm holds it, and is also the only arm that boots the GICv3 SPI
path, which had been written and committed and never run.
.IP
What is
.I not
done is the part that makes it SystemReady.  A real Altra hands the
kernel ACPI, not a device tree: MADT for the GICD, GICR and ITS bases,
IORT for the RID-to-DeviceID map.  This driver finds all of those
through
.CW fdtreg("arm,gic-v3-its")
and the host bridge's
.CW msi-map
property, and neither exists on the hardware.  The order between the
two is forced, and it is the opposite of the order the debt reads in:
ACPI cannot be tested on
.CW "-M virt"
at all without firmware, because QEMU builds the tables and only edk2
installs an RSDP where a guest can find it, so the UEFI entry is not the
second half of the work but the only way to put a table in front of
.CW gicv3itsinit() .
.IP
That entry is done.
.CW os/inferno/boot/efi
builds
.CW bootaa64.efi
from
.CW aa64.s
and the same
.CW efi.c ,
.CW fs.c
and
.CW sub.c
the x86 loaders use, and on
.CW "-M virt"
with edk2 as pflash it reads
.CW plan9.ini
off an ESP, loads the kernel it names, turns the MMU and the caches off,
and hands over: the kernel reaches
.CW ROOT-CMDS-OK .
.CW tools/aout2efi
learned the arm64 machine type, a passed image base, and to read the
entry from the fat header's 64-bit field rather than the 32-bit
.CW PADDR
one;
.CW aa64hello.efi
is kept beside the loader as the test that the toolchain and the header
are right at all.
.IP
And so is the ACPI half.
.CW os/inferno/port/acpi.c
finds tables by signature from the RSDP the loader passes in its
configuration, and
.CW os/inferno/virtarm64/acpiarm.c
reads the MADT for the GIC distributor, redistributor and ITS and the
IORT for the requester-id-to-DeviceID windows.
.CW virtarm64-acpi
in the board suite boots
.CW "-M virt,gic-version=3"
through edk2 with the device-tree scan switched off, so there is no
tree of any kind:
.CW "fdt: no device tree" ,
and then the ITS found from the MADT, two PCI functions on distinct
LPIs, an interrupt delivered, a disk read and DHCP.  46 markers, checked
every run.  Memory is sized from the firmware's map rather than from
.CW DRAMSIZE ,
and the board checks that the tables it read are outside the range it
gave the allocator.
.IP
The IORT's chain through an SMMU is composed rather than reported.  A
root complex mapping that points at an SMMUv3 node is intersected with
that node's own StreamID-to-DeviceID mappings, so a requester behind the
SMMU gets a DeviceID instead of being refused;
.CW virtarm64-smmu
runs it on
.CW "-M virt,gic-version=3,iommu=smmuv3" ,
where every device on bus 0 is behind the SMMU and used to fall back to
INTx.  See
.CW doc/inferno-ports.ms
for the three details in the table that each produce a wrong answer
quietly, and for what the arm proves \(em the coverage and the delivery,
not the values, because QEMU's composed map is the identity.
.IP
The GIC's own three bases are discovered and used, not printed:
.CW gicdiscover()
takes the distributor, the redistributor range and the GICv2 cpu
interface from the MADT, else from the device tree, else from mem.h, and
the board says which source won.  They had been mem.h constants at
twenty-four sites while the discovered values were printed beside them
for comparison, which is a line that cannot fail on a machine where the
two agree.
.IP
What is left is the hardware itself.  An Altra has several root
complexes told apart by PCI segment number, and
.CW acpiridtodevid()
takes a requester id and nothing else because the PCI code carries no
segment; and its MADT describes several redistributor ranges, which
.CW gicdiscover()
takes the first of rather than choosing by the booting cpu's affinity.
That is a list of specific things now, rather than "no ACPI at all", and
none of it can be written against anything but the silicon.
.IP 2.
.B "Raspberry Pi Zero 2 W."
A BCM2710A1 \(em the Pi 3B's die in a smaller package \(em so the
.CW raspi3b
kernel's mailbox, SDHOST, DWC2 and LAN9514 work is the same silicon,
and the board costs fifteen dollars.  What differs is the absence of
the LAN9514: the Zero 2 W has no Ethernet, only the wireless part on
SDIO, which is exactly the Arasan work
.CW doc/raspi4-plan.ms
records as blocked off this machine.  So it boots to a console over
the same serial pinout and stops there until SDIO is real.
.IP 3.
.B "StarFive VisionFive 2 (JH7110)."
The riscv64 board people actually own.  Its UART is the DesignWare
part
.CW uartdw.c
already drives, its Ethernet is a DesignWare GMAC, its storage is a
dw-mmc controller and an NVMe behind the SoC's PCIe.  It boots OpenSBI
and hands the kernel a device tree in a1, which is exactly the entry
.CW os/inferno/virt
takes today.  The new drivers are GMAC, dw-mmc and the JH7110 PCIe
controller; nothing about the entry, the trap path or the SBI calls
changes.
.IP 4.
.B "Rockchip RK3588 or RK3399."
The arm64 single-board machine with the widest availability \(em
Radxa, Orange Pi, Firefly, Pine64 all ship one.  GICv3 (so the ITS
above applies), PCIe with NVMe, a DesignWare UART, a DesignWare GMAC,
and dw-mmc for the eMMC.  It is item 3's driver list on an arm64
entry, which is why the two should be done near each other.
.IP 5.
.B "SiFive HiFive Unmatched (FU740)."
The riscv64 board with real PCIe: an x16 slot, NVMe, and a Marvell
Ethernet the tree already has a driver for in
.CW etheryuk.c .
Expensive and out of production, but it is the riscv machine that most
resembles a PC, and the tree's PCI driver set would light up on it
with the least new code of any riscv part.
.IP 6.
.B "Microchip PolarFire SoC Icicle Kit."
Five cores, a Cadence GEM Ethernet, a Cadence SDHCI, and PCIe on the
FPGA fabric.  The Cadence controllers are the new work.  It is here
rather than higher because it is a development kit rather than a
machine people run, but it is the riscv64 part with the best
documentation of the three.
.PP
Items 1, 3 and 4 share the same shape: an entry the tree already
takes, a bus the tree already drives, and two or three controllers
from the DesignWare family.  Writing the DesignWare GMAC and dw-mmc
once serves three of the six boards, which is the same argument the
shared
.CW fdt.c
made.
.PP
One thing has to be said plainly about this list, because it reads like
a queue and it is not one.  Item 1 was workable here because QEMU has an
arm64 machine with a GICv3, an ITS and UEFI firmware, so every piece of
it could be written against something that boots.  Items 2 through 6
have no such machine.  There is no QEMU model of a BCM2710A1 in a Zero
2 W's package, none of the JH7110, none of the RK3588, none of the FU740
or the PolarFire SoC, and the parts of them this tree would have to
drive are exactly the parts that differ from anything modelled: the
DesignWare GMAC, dw-mmc, the Cadence controllers, each SoC's PCIe.  None
of that is blocked on effort.  It is blocked on having the board on the
desk, and the standard the rest of this tree holds to \(em say what was
checked against a booted kernel \(em cannot be met for any of them from
here.  What can be done from here is to keep correct the shared work
they will all land on.
