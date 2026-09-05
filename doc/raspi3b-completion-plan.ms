.TL
Finishing the Raspberry Pi 3B port: an ordered plan
.AU
.PP
The board boots arm64 Inferno to a shell with I2C, SPI, GPIO, native SD,
a 100Hz tick, the VideoCore mailbox and a firmware framebuffer the draw
device renders into.  What is left, in the order it should be done, each
step gating the next.  The method is the one that cracked I2C/SPI/GPIO/SD:
read the QEMU device model to pin register semantics, write the driver,
test it against a booted kernel where QEMU models the device, and per
AGENTS.md implement what the real board needs (power domains, cache,
flow control) even where the emulator is lenient -- noting each such gap.
.NH 1
Phase 0: hardware-correctness debt (do first, cheap) -- DONE
.PP
Two known gaps flagged in the source, both no-ops under QEMU but needed
on real silicon, and cheap to close before more drivers pile on.
.IP 0a.
Framebuffer pixel order -- DONE.  The screendump had red and blue
swapped: QEMU's bcm2835 framebuffer defaults to pixel order RGB while
memdraw's XRGB32 byte order (and the real Pi firmware) want BGR.  A
SET_PIXEL_ORDER (0x00048006) tag in mboxfballoc now requests BGR
explicitly, so the emulator and hardware agree.  Verified: three drawn
bands read red, green, blue left to right in the screendump.
.IP 0b.
Cache maintenance -- DONE (by-VA ops; set/way walker deliberately
deferred).  RAM is mapped cacheable but the GPU and any DMA read it
uncached, and the caches are UNKNOWN at reset.  DC CVAC (clean to PoC),
DC IVAC (invalidate), DC CIVAC and IC IALLU are l.s TEXT functions,
reached as the "SYS reg, sysarg" form since 7a has no optab row for the
DC/IC mnemonics; the encodings were checked byte-for-byte with 7l -a
(DC CVAC,X0 == 0xd50b7a20, IC IALLU == 0xd508751f).  cachebcm.c strides
the by-VA ops over a range at the CTR_EL0 minimum line size.  Wired:
mmuenable() invalidates the I-cache (IC IALLU) before setting SCTLR.I;
mboxprop() cleans the request before the write and invalidates the
response after the read; flushmemscreen cleans each pushed scanline.
The L1 D-cache set/way invalidate that mmuenable still wants at reset is
left out on purpose -- its CLIDR/CCSIDR level-walk loop is logic QEMU
cannot exercise (it models no cache), so shipping it unvalidated would
only risk discrediting the ops that ARE validated; the source comment
says so.  Verified: clean boot under QEMU with the same marker line-up
(RASPI3B-OK, SD-OK/WRITE/MULTIBLOCK, DRAW-OK, RASPI3B-SH-OK) and the
screendump still reading red/green/blue.
.NH 1
Phase 1: Synopsys DesignWare (DWC2) USB host -- the keystone -- DONE
.PP
usbdwc.c ports 9front's sys/src/9/bcm/usbdwc.c to Inferno's Hci/Hciimpl
interface.  The controller probes (DWC OTG rev 2.94a at 0x3f980000),
core-inits (8 host channels, DMA mode), brings the root port up, and
runs interrupt-driven control/bulk/interrupt transfers through its host
channels.  usbd enumerates over it: on QEMU with -device usb-kbd the
driver resets the port, issues SET_ADDRESS, and reads the device
descriptor (vid/did/class) end to end, all via the interrupt path,
booting clean to a shell.
.PP
Three donor-vs-Inferno adaptations were load-bearing.  The FIQ/ARM-timer
wakeup hop is gone -- GPU IRQ 9 dispatches at normal level, so one
handler read-and-clears each channel's hcint (which is also what lowers
QEMU's sticky GINTSTS.Hcintr, the BCM interrupt controller having no EOI)
and wakes the sleeper directly.  Both interrupt masks are armed before
the channel is enabled, since QEMU raises the completion interrupt only
at the event, gated by haintmsk as it then stands.  And a reported
Xfercomp ends a zero-length stage even when Pktcnt is unchanged: real
hardware decrements Pktcnt on a ZLP, QEMU does not, and keying the loop
on Pktcnt alone re-enabled the channel against a device whose address
had moved.  DMA is made coherent with cachebcm.c (Phase 0b) through
cache-line-aligned bounce buffers.
.PP
The split-transaction path is exercised and works: QEMU's raspi3b puts
an 8-port hub on the DWC2 root, so -device usb-kbd is a full-speed
device behind a high-speed hub.  usbd walks the hub, enumerates the
keyboard (vid 0627 class 0), and its boot-protocol interrupt endpoint
delivers HID reports through split transactions -- injecting keys at the
QEMU monitor produces the matching usage codes in usbd's reader.  One
usbd fix was needed for the hub topology (which xhci boards never hit,
their keyboards being direct): confighub reads the hub descriptor over
ep0's data file, which an enumerated device leaves open, but the kernel
refuses the "hub" ctl command for a busy endpoint -- so newhub now
closes the data file after confighub and before "hub", reopening it
after.
.NH 1
Phase 2: USB keyboard and mouse -- boot keyboard reports arriving
.PP
With Phase 1 and the hub fix, usbd already detects the boot keyboard and
reads its HID reports over the split interrupt endpoint (verified by
monitor key injection).  What remains is wiring those reports through to
cons (#c) and the mouse reports to the pointer (#m) on this board.
.NH 1
Phase 1 (historical): the DWC2 controller
.PP
The BCM2837 has one USB: a DWC2 OTG host controller at 0x3f980000.  The
onboard LAN9514 hub+ethernet, and any keyboard, mouse or storage, all
hang off it, so this one driver unlocks Phases 2-4.  QEMU -M raspi3b
models the DWC2 (hw/usb/hcd-dwc2.c) and accepts usb-kbd/mouse/net/storage,
so it is fully developable under emulation.
.PP
Inferno already has the host-controller framework:
.CW os/inferno/port/devusb.c
(the #U device and the Hci/Hciimpl interface, addhcitype()) and
.CW usbxhci.c
as a working HCD to model on; the Limbo enumerator
.CW appl/cmd/usb/usbd.b
drives whatever HCD registers.  So the work is a new
.CW usbdwc.c
that maps the DWC2 registers, resets and core-inits the controller,
drives its host channels for control/bulk/interrupt transfers, services
the root hub, and calls addhcitype("dwc", reset).  Pin the register and
channel semantics from hcd-dwc2.c.
.IP (a)
Controller reset + core init + root-hub port up; usbd sees the built-in
hub.
.IP (b)
Control transfers: enumerate a device, read its descriptors.
.IP (c)
Bulk and interrupt transfers.
.PP
Real-hardware note: the DWC2 needs its USB power domain enabled through
the mailbox (SET_POWER_STATE for the USB HCD) before it responds; QEMU
does not require it.  Verify each milestone under QEMU with -device
usb-kbd / usb-net attached.
.NH 1
Phase 2: USB keyboard and mouse -- interactive framebuffer
.PP
Boot-protocol HID keyboard and mouse, wiring the enumerated interrupt-in
endpoints to Inferno's cons keyboard (#c) and pointer (#m).  Depends on
Phase 1's interrupt transfers.  Verify under QEMU with -device usb-kbd
-device usb-mouse (or the input record/replay harness): keys reach the
shell, the cursor moves on the framebuffer.
.NH 1
Phase 3: LAN9514 USB Ethernet -- native networking
.PP
The Pi's onboard 10/100 ethernet is an SMSC LAN9514 (hub + ethernet) on
USB.  A USB-ethernet class driver registers an ether(3) card backed by
two bulk endpoints, into /net/ether0.  Depends on Phase 1 bulk transfers
and hub enumeration.  Verify under QEMU (the LAN9514 sits behind the DWC2
hub): DHCP over SLIRP and an ICMP echo to the gateway, reusing the
sifiveu/virtarm64 dhcpclient test.
.NH 1
Phase 4: USB mass storage
.PP
Bulk-Only Transport mass-storage class -> an sd(3) block device
(/dev/sdU0/data) -> dossrv or kfs.  Depends on Phase 1 bulk.  Verify
under QEMU with -device usb-storage: read/write the block device, mount a
FAT partition through dossrv.
.NH 1
Phase 5: Arasan SDHCI / SDIO -- the second SD controller
.PP
The BCM2837's second SD controller (Arasan SDHCI, 0x3f300000).  SDHOST
already drives the card, which deliberately leaves Arasan free for the
Wi-Fi SDIO.  QEMU routes -sd to the Arasan SDHCI by default (SDHOST needs
the GPIO alt0 we set), and models a generic SDHCI (hw/sd/sdhci.c), so the
controller init and a block read are QEMU-verifiable.  The real point is
the SDIO transport for Phase 6.
.NH 1
Phase 6: BCM43430 Wi-Fi over SDIO
.PP
The onboard Broadcom BCM43430 Wi-Fi hangs off SDIO (via Arasan), the
piece 9front's ether4330 already handles: firmware upload plus the SDIO
transport, presenting an ether(3) card into /net.  Depends on Phase 5's
SDIO transport.  QEMU does not model the Wi-Fi chip, so this is
structured against the donor and validated on real hardware; the SDIO
transport itself can be exercised on QEMU's SDHCI.
.NH 1
Phase 7: watchdog, RNG, PWM -- small BCM283x drivers
.PP
Individually small: the hardware RNG (0x3f104000, modeled by QEMU as
bcm2835_rng.c) feeding /dev/random; the watchdog (PM_WDOG in the
power-management block, which also drives reset) as a control file; PWM
(0x3f20c000) as a device file.  RNG and watchdog are QEMU-verifiable; PWM
is largely real-hardware.
.NH 1
Parallel: the kfs create deadlock
.PP
Independent of USB and not blocking (dossrv, ramfs and 9660srv all run
over the working SD block device).  Worth fixing for a reliable native
writable filesystem.  The lead is the multi-kproc mount handoff on arm64:
pid 1 is not resumed after yielding at error()'s spllo() to the spawned
kfs kproc, which then blocks -- a sleep/wakeup or Dis release()/acquire
token bug (see doc/inferno-driver-plan.ms).  Tackle when a native FS is
wanted.
.NH 1
When this is done
.PP
With Phases 0-4 the Pi 3B is an interactive networked Inferno
workstation: framebuffer display, USB keyboard and mouse, wired ethernet,
and USB storage, over a firmware-loaded kernel8.img on real hardware.
Phases 5-7 add Wi-Fi and the small peripherals.  Left out on purpose,
until the machine is otherwise complete: Bluetooth, the CSI camera, DSI
display, and anything GPU/OpenGL/VideoCore-accelerated.
