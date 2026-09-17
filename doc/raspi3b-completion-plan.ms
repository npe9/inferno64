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
Phase 2: USB keyboard -- DONE, end to end
.PP
No new driver was needed: usbd's boot-keyboard reader already translates
HID usage codes to UTF-8 and writes them to /dev/keyboard, which devcons
routes to its graphics keyboard queue (gkbdq) -- the input a wm/tk
console reads, correctly distinct from the uart serial console.
Verified whole: with -device usb-kbd, injecting "hello\\n" at the QEMU
monitor makes raspi3binit's reader print h e l l o and a newline from
/dev/keyboard -- QEMU keyboard, through the root hub, through the DWC2
driver's split interrupt transfers, through usbd's HID translation, to
cons.  The mouse (boot-protocol, to #m/pointer) is the same shape and
follows usbd's existing mouse reader; it is left for a pointer-wiring
pass on this board.
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
Phase 3: USB Ethernet -- native networking -- DONE under QEMU
.PP
The Pi's onboard 10/100 ethernet is an SMSC LAN9514 (hub + ethernet) on
USB.  Unlike the kernel HCD, the ethernet driver is a Limbo program, for
two structural reasons established during the port: devip's "ether"
medium is file-based (ethermedium.c binds an ethernet device purely by
path, via namec/chandial on clone/addr/N/data), so a userspace server
speaking the netif protocol can BE devip's ethernet; and a kernel
devether card cannot, because it is probed at boot -- before usbd has
enumerated any USB NIC -- and has no in-kernel path to the DWC2 bulk
endpoints, which are reached only through the #U file interface.  This is
9front's nusb/ether architecture.
.PP
Prerequisite (done): the board config gained the IP stack and the
ethermedium/loopbackmedium links, which the copied virtarm64 config had
dropped.
.PP
Stage 1 (done): etherusb.b serves the netif file interface -- clone (open
allocates a conversation, the fid becomes its ctl), addr, per-conversation
ctl/data, the connect/promiscuous/nonblocking verbs -- and self-mounts it.
Verified, and this was the design's one real risk: the server binds
itself as an ipifc's ethernet (bind ether succeeds, so chandial's
clone/connect/data dance is satisfiable from a Limbo styx server), and
adding an address provokes an ARP that arrives at the driver's transmit
path.  Two netif-protocol constraints surfaced: the server loop must run
before the self-mount (mount is a synchronous 9P handshake), and the
interface sits one directory below the mount point (chandial rejects a
single-component path).
.PP
.B "Stage 2 (done): the bulk path, the chip init, and an address by DHCP."
usbd recognises a USB ethernet -- a CDC Ethernet Control Model interface
(class 2, subclass 6) in any configuration, or one of the SMSC LAN95xx
ids -- and hands its ep0 to
.CW etherusb ,
which opens the device's bulk in/out endpoints through
.CW #U ,
runs the chip init, and pumps frames between them and the netif files it
serves.  Two chip paths: ECM (set the packet filter, read the MAC from
the string descriptor), which QEMU's
.CW usb-net
exercises end to end; and SMSC LAN95xx, written from 9front's
.CW nusb/ether/smsc.c
\- register read/write over vendor control transfers, EEPROM, MII, PHY
init, and the chip's 4-byte RX header \- for the Pi's onboard LAN9514.
QEMU models no LAN9514, so
.B "the SMSC half is unverified and waits on the real board;"
the ECM half is what the boot below proves.  The Pi's LAN9514 carries no
MAC EEPROM either, so the firmware's GET_BOARD_MAC_ADDRESS
.CW ( mailbox.c 's
.CW mboxgetmac )
is published as
.CW /env/ethaddr
for the driver to fall back on.
.PP
Verified on a booted kernel
.CW ( "qemu-system-aarch64 -M raspi3b -m 1G -nographic -kernel iraspi3b
.CW "-device usb-net,netdev=n0 -netdev user,id=n0" ):
usbd enumerates the hub and the NIC
.CW ( "vid 0525 did a4a2 class 2" ),
starts
.CW etherusb ,
which serves
.CW /net.alt/ether ;
devip binds it as ipifc 0's ethernet (ETHERBIND-OK); DHCP completes over
the USB link \- discover, offer, request and ack all crossing the bulk
endpoints in both directions \- giving
.CW 10.0.2.15
with gateway
.CW 10.0.2.2
(ETHER-DHCP-OK); and
.CW ping
gets replies to all three of its echo requests (ETHER-PING-DONE), after
which the board boots on to its shell (RASPI3B-SH-OK).
.PP
.B "The bug this stage actually turned on: every timed sleep died the moment DHCP succeeded."
Stage 2's code worked before this was found \- DHCP completed and the
first ping was answered \- and then the whole machine went quiet: the
clock kept ticking, but no Limbo process ever ran again.  The cause was
not in the driver.  Each board's soft-timer queue
.CW ( stubs.c )
converted a sleep's nanoseconds to fastticks as
.CW "(tns * hz) / 1000000000LL" ,
a signed 64-bit multiply that overflows once
.CW tns
passes
.CW 2**63/hz
\- about 147 seconds against the Pi's 62.5MHz counter.  The moment its
lease was granted,
.CW dhcpclient 's
.CW thebigsleep()
asked for 32400 seconds (T1 of an 86400-second lease); the product
wrapped, and
.CW twhen
came out negative.  From there the two halves of the queue disagreed
about its sign:
.CW timerinsert()
compares
.CW Tval
against
.CW Tval ,
signed, so the bad timer sorted to the
.I head ;
.CW timercheck()
compared it against an unsigned
.CW now ,
which read that negative deadline as enormous, so the loop stopped at
the head and never reached anything queued behind it.  One overlong
sleep therefore froze every
.CW tsleep
on the machine permanently, while
.CW timersoon()
returned the same huge value and let the HZ tick carry on \- which is
why the console kept printing and nothing else moved.  The fix converts
in whole seconds plus a scaled remainder
.CW ( ns2ticks() ),
which cannot overflow, and makes
.CW now
a
.CW Tval
in both functions so every deadline comparison is signed against signed
and a bad value would fire early instead of wedging the queue.  Twelve
boards carry copies of this timer queue and all twelve are fixed.  What
each claim rests on, exactly: raspi3b, virtarm64, sifiveu and virt32
were booted afterwards and reach an interactive shell (RASPI3B-SH-OK,
SIFIVEU-SH-OK, and a prompt on the two virts); virt was booted and gets
as far as
.CW "sh loaded" ,
which is where its diskless run stops anyway; armv7, mangopi, shakti,
spike, virts and virt32s compile but were not booted; and armv7m has no
mkfile in the tree to build with at all.  The sifiveu and virtarm64
kernels in those boots also carried uncommitted device-table edits
.CW ( sifiveu.c ,
.CW virtarm64.c )
already in the tree from other in-flight board work \- the timer queue
does not depend on them, but the boots were not of a clean checkout.
.PP
Left for the real board: the SMSC init path above, and the interrupt
endpoint (link status) which neither chip path uses yet.
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
.NH 1
Where the port stands on real silicon, 16 September 2026
.PP
Everything below was measured on the board this week, not inferred from
QEMU.  The plan above was written when only the emulator had run the
code; two of its assumptions are now wrong, and they are marked.
.NH 2
Working on the Pi
.PP
Boot and console: the firmware loads kernel8.img, the kernel drops to
EL1, maps memory, enables caches, runs a 100Hz preemptive tick and
reaches an interactive Dis shell over the PL011.  Seven boots out of
seven, one power-on and six reboots through
.CW /dev/sysctl ,
each answering a typed command 30 seconds in.  The fault that made this
unreliable was an SP-alignment one (doc/inferno-ports.ms).
.PP
SD storage: through the Arasan SDHCI, not SDHOST.  The card the board
boots from reads as its real master boot record ending in 55 aa, with
the FAT32 "bootfs" boot sector at sector 16384, and reports 30228480
sectors, exactly what the host says of the same card.  Single reads of
64KB and 512KB return clean.  Writes are verified too, by a ctl command
that restores the sector it wrote and checks the restore.
.PP
Also verified on the board: the VideoCore mailbox (firmware revision,
ARM memory, board MAC, power domains, clock rates, framebuffer
allocation), GPIO, the DWC2 controller's probe, core init and root hub,
and USB control transfers -- usbd enumerates the onboard LAN9514 hub and
its ethernet function by vendor and device id.  Reboot through the PM
watchdog works.
.NH 2
Corrections to the two paragraphs below, 16 September 2026
.PP
Both were written from the board and both were wrong, in ways worth
keeping as a caution.  The console was never wedged by a failing driver:
usbd had been started in the foreground, so the shell was waiting for it,
which looks identical to a hang.  And USB bulk transfers were not the
blocker.  What stopped enumeration was in usbd itself: newhub allocated
its Hub with a bare
.CW "ref Hub" ,
whose fields hold whatever the allocator had there, and on this board the
failed flag came up non-zero (the walk printed -1793850332), so enumhub
abandoned the hub on its first line, silently, for ever.  It worked the
one time the residue happened to be zero, which is what made it look like
a hardware race.  Naming every field fixed it, and opendev in both usbd
and etherusb had the same bug (isusb3 as residue, enough to send
enumeration down the USB3 path).
.PP
With that fixed the Pi enumerates its onboard hub and the LAN9514 behind
it, etherusb starts, the PHY reports the link up, and the mount that this
plan called impossible on the board succeeds: /net.alt/ether with the
board's own MAC.  That mount had been disabled in the source because the
Pi wedged entering the syscall; it was a casualty of the SP-alignment
fault (doc/inferno-ports.ms), not a separate fault.  init now starts usbd
at boot and runs the DHCP and ping check.
.PP
Three bounds were added to usbdwc.c along the way - a bulk IN may wait
for ever because the wait is the read, while a NAK'd control transfer and
the retry loop itself are bounded and report.  They were fixing the wrong
layer, but they stand on their own: a driver written where every transfer
completes will otherwise wait for ever on silicon, saying nothing.
.NH 2
The gap that blocks the most: USB bulk transfers
.PP
Control transfers work on silicon; bulk does not.  Starting usbd by hand
enumerates the hub and NIC, etherusb finds its bulk endpoints and starts,
and then the first bulk IN fails:
.CW "usbdwc: ep3.1 completion timeout channel 0" ,
.CW "usbdwc: ep3.1 error intr 00000082" ,
.CW "etherusb: ep3.0: receive stopped: i/o error" .
So Phase 3 (ethernet) and Phase 4 (USB mass storage) are blocked on the
board although both pass under QEMU, and Phase 2's keyboard, which rides
interrupt transfers, is likewise unproven on silicon.
.PP
Worse than the failure is its blast radius: after etherusb stops, the
console stops responding.  Characters still echo, so the kernel lives,
but no process reads them.  A driver whose transfers fail should not
take the shell with it; containing that is worth doing before chasing
the transfer bug itself, because every future hardware experiment on
this board depends on the shell surviving.
.NH 2
Wi-Fi and the SD card now want the same controller
.PP
The plan above says SDHOST drives the card and deliberately leaves the
Arasan SDHCI free for the Wi-Fi SDIO.  That is no longer true and cannot
easily be made true again.  SDHOST does not hand over whole words to a
polled driver on this silicon: its FIFO fill level reads 0 throughout a
transfer, its data flag is set from the first byte, each read returns the
same word with one more byte shifted in, pausing between reads freezes
it, and reading it a byte per read ends in a FIFO error.  The card
therefore now goes through the Arasan, which is also where the BCM43430
Wi-Fi hangs.  Before Phase 6 the board has to choose: make SDHOST work
(interrupt- or DMA-driven, as Linux drives it), or keep the card on the
Arasan and have no Wi-Fi.  Nothing in the emulator can settle it: QEMU's
SDHOST model completes a transfer inside the register access and hides
the whole difficulty.
.NH 2
Smaller gaps, roughly in the order they matter
.IP 1.
SD transfers are polled and hold the CPU; DMA is not implemented.
Multi-block (CMD18/CMD25) is, and is checked at every boot against the
same block read alone (SD-MULTI-OK), so what is left here is DMA and
the CPU a transfer costs, not correctness.
.IP 2.
I2C and SPI have drivers and their buses come up, but nothing is
attached to this board to talk to: the I2C probe reports a DS1338
mismatch and SPI reports no flash.  They are unverified against real
peripherals.
.IP 3.
The framebuffer is allocated and the draw device renders into it
(DRAW-OK 640x480), but nothing here has ever been seen on a monitor.
Mode setting beyond the firmware's default, and hotplug, are absent.
.IP 4.
No wall-clock time: the Pi has no battery-backed clock, and nothing yet
asks the firmware or a network for the time.
.IP 5.
The kernel is uniprocessor.  MAXMACH is 1 and cores 1-3 sit at WFE;
arm64 SMP lives on another worktree.
.IP 6.
Bluetooth is absent and conflicts with the console: it needs the PL011,
which the console uses.  uartmini.c exists for the mini UART but is
unlinked and has never been shown to work on silicon.
.IP 7.
No audio (PWM or HDMI), no CSI camera, no DSI display, nothing
GPU-accelerated.  These were out of scope in the plan above and remain
so.
.IP 8.
The DMA controller is unused by any driver.
.IP 9.
Nothing here turns the card into the board's own filesystem yet.  The
kfs create deadlock that used to block it was the SP-alignment fault,
and kfs now reams and serves a partition carved from the card's
unallocated gap; what is missing is a boot that mounts it as the root
rather than as a test.
.NH 2
Ethernet on silicon: what was wrong and what fixed it
.PP
.B "The board is on the network."
Twenty pings from another machine, twenty replies, no loss, eighteen
milliseconds average; a connection to a closed port refused rather than
ignored, so its TCP answers; DHCP takes an address from the router; and
its own ping to the gateway is answered.  Two things had to change, and
neither of them was the ethernet driver.
.PP
.B "The Dis heap watchdog was most of it."
Every Dis instruction calls
.CW checktracked() ,
which reads all 1024 tracked slots, and every
.CW initmem()
registers its pointer words into them.  On a board whose ethernet driver
and its file server are Limbo programs, that is charged to every frame
that arrives.  The kernel was coming back for the next frame every 337
milliseconds while frames arrived every 24, so both conversations sat
permanently full, two thirds of everything was dropped, and what was
delivered was seconds stale: the board answered every echo request it
was sent and was still reported unreachable.  With the watchdog off that
gap is 4 milliseconds.  It is not removed - heap.c has
.CW distrack ,
default 1, and only this board clears it.
.PP
.B "Then the receive channel stopped, for ever."
With the interpreter fast, the onboard NIC's bulk IN sat with
.CW Chen
set and
.CW NAK
latched and no completion ever came: 130 seconds later not one further
frame had been received.  A bulk IN was deliberately allowed to wait
without limit, because an idle NIC NAKs and must not be called a fault;
that is right about the waiting and wrong about the for ever.  After two
seconds the channel is now halted and a NAK reported, which the caller
already retries, so the transfer is re-armed.  An idle NIC costs a few
register writes every couple of seconds.
.PP
The measurements that led there are below, and the shape of the failure
is worth keeping: everything pointed at the driver, and the driver was
writing every frame it was given.
.NH 2
How the ethernet failure was measured
.PP
The Pi enumerates its LAN9514, serves
.CW /net.alt/ether ,
binds it as ipifc 0 and receives: unicast ICMP echo requests reach the
protocol (91 in,
.CW InErrors
0,
.CW CsumErrs
0) and are answered (91
.CW EchoReply
out).  Nothing the board sends in reply is ever seen by the machine at
the other end of the cable.
.PP
Where the frames are
.I not
lost: on the way out.
.CW /net.alt/ether/stats
counts what the ethernet server does with each frame the kernel hands
it, and every frame is written \-
.CW "ntx 30, nqueued 30, nwrit 30, nwerr 0" .
The bytes are right too: the dump taken as a frame reaches the bulk
endpoint shows the SMSC transmit header's two length fields agreeing
with each other and with the frame, the board's own mac as source, and
.CW 0x0800
over a well-formed IP header.  The other end also demonstrably hears
some of them: the Mac's ARP entry for the board went from ten seconds
short of expiry to a fresh 1199 immediately after a ping, so ARP
traffic from the board crosses the cable.
.PP
What is broken is resolution.
.CW /net/arp
holds the machine the board is trying to reach in
.CW WAIT
with an all-zero mac, and stays there.  With no mac, every unicast IP
packet is queued against that entry and abandoned, which is exactly the
shape of the failure: ARP answered, ping never, TCP dial never.
.PP
Alongside it, and possibly the cause, the receive side is dropping
most of what arrives: 45942 frames received, 30860 dropped for want of
a reader.  Each conversation holds at most
.CW Nqueue
frames when nobody is reading, and a conversation that is never drained
discards everything that arrives after the sixty-fourth \- including,
if it is the
.CW 0x806
conversation, the ARP reply the board is waiting for.  The three
conversations (IPv4, IPv6, ARP) each now count what was matched to
them, handed to a reader and dropped, and every ARP frame that reaches
the server is dumped as it arrives; that says whether the reply is
absent from the wire or discarded after it lands.
.PP
QEMU says the ceiling is real, and low.  Forwarding a host UDP port
into the guest and filling it puts a measurable load on the same path:
at thirty frames a second nothing is dropped, and at a hundred the
IPv4 conversation sits permanently at its sixty-four-frame limit and
discards two thirds of what arrives.  The two halves of the path were
then timed from inside the ethernet server: frames leave the bulk
endpoint one every forty milliseconds, and the kernel comes back for
the next one every hundred and twenty-five, so the reader is the
binding constraint under load \- though in this test each received
packet also provokes an ICMP reply, which the ambient broadcast
traffic on a real LAN does not.  What QEMU cannot show is the failure
itself: with
.CW "-netdev user"
the guest resolves ARP and pings normally.
.PP
One earlier reading here was wrong and is worth recording as a trap:
.CW "usbdwc: ep3.2 waiting 60 s"
under QEMU is not a wedged transmit.  QEMU's usb-net presents its bulk
in and out on the same endpoint number, which this driver opens as one
read-write endpoint, so the message is the idle receive read waiting
for traffic that is not coming \- exactly what it is meant to say.
.NH 2
Suggested order
.PP
Contain a failing driver so it cannot wedge the console; fix DWC2 bulk
transfers on silicon, which unblocks ethernet, USB storage and input;
then decide the SD/Wi-Fi controller question; then multi-block and DMA
for SD; then the peripherals nothing is currently attached to.
