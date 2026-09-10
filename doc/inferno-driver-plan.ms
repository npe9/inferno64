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
and it is in the interpreter rather than in any driver.  It is timing-dependent: the same kernel
booted by hand without the disk and the host rig did not get as far as
serving
.CW /net.alt/ether
at all.  Chasing it means either bisecting Limbo across
.CW dhcpclient ,
.CW etherusb
and
.CW styxservers ,
or fixing the larger thing underneath \(em that a nil dereference in
Limbo faults a native kernel where it ought to raise an exception.  The
driver itself is not what is blocked here: the ECM path works, and the
SMSC path takes a DHCP lease on two Pi configurations every run.  What
is blocked is a second
.CW devip
ethernet on a board that already has one.
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
things remain, and none of them is waiting on a decision or on more of
the same work.  Each is here with the reason it stops, so that a reader
who has hardware, or a QEMU built differently, knows exactly which one
they have unblocked.
.IP 1.
.B "MSI and MSI-X."
PCI on both virt machines runs on legacy INTx, which QEMU delivers
correctly, so MSI buys nothing here.  It is for real hardware that
needs more vectors than INTx has.
.IP 2.
.B "arm64 device-tree discovery."
QEMU's
.CW -kernel
path enters an arm64 ELF with
.CW "x0 == 0" ,
so the DTB pointer the riscv boards read is simply not passed.  Every
riscv board in the tree now reads its tree;
.CW virtarm64
cannot, and neither can
.CW spike ,
which is handed no tree at all.  Booting arm64 through a loader that
does pass one \(em UEFI, or
.CW -bios \(em
would unblock it.
.IP 3.
.B "virtio-gpu 3-D."
Needs a QEMU built against virglrenderer.  The packaged 10.1.3 here
has no
.CW virtio-gpu-gl-pci
at all, and this tree's own patched build is aarch64 only and
configured without it.  The 2-D path is done and in the suite.
.IP 4.
.B "A second devip ethernet over USB."
The controller and the enumeration are real \(em xHCI is found, the CDC
ECM device enumerates,
.CW etherusb
serves it, and
.CW devip
binds it \(em and the step after that faults the Dis interpreter at
.CW OP(movp) 's
own first load.  It is in the crash-hunt family described in
.CW doc/inferno-ports.ms ,
not in a driver, and the USB-Ethernet driver itself works on both its
paths.
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
Fifteen configurations run on this host and thirteen of them run from a
bare checkout inside a container.  What that buys is not the marker
count: it is that every one of these six statements can be checked
against a booted kernel by anyone who runs the suite, and that a change
which breaks one of the finished items says so in the same run.
