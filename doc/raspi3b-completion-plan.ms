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
Stock QEMU models no LAN9514, so this half was written blind and had
never once executed.  It does now:
.CW tools/qemu-patches/0003
adds a
.CW usb-lan9514
device \- vendor requests A0/A1 for register access, the transmit
command words, the receive status word and FCS, burst packing under
MEF and the burst cap, and the internal PHY at address 1 \- taken from
the LAN9512/LAN9514 datasheet and Linux's
.CW smsc95xx ,
not from what
.CW etherusb.b
happens to emit.  With it the SMSC path runs end to end:
.CW "smsc id_rev 0xec000002" ,
both resets, the EEPROM falling through to
.CW /env/ethaddr ,
.CW ETHERBIND-OK ,
.CW "ETHER-DHCP-OK ip=10.0.2.15 gw=10.0.2.2"
and
.CW ETHER-PING-DONE ,
with no complaint from the model.  This is
.B qemu+patch
evidence and still wants a run on the board, but it is no longer
unexecuted code.
.PP
Running it found two bugs, both of which would have bitten on hardware.
A frame crosses the bulk endpoints as a run of 64-byte packets ended by
a short one, in both directions; the model's refusal to accept a
transmit whose command words disagreed with the bytes actually
transferred is what exposed the first, and a 600-byte receive that
would not fit in one packet exposed the second.  And
.CW rxproc
warned "empty read" on every idle poll: with
.CW Hwcfg 's
.CW Bir
set \- which
.CW smscsetup
sets itself \- a zero-length read is the chip's documented answer to an
empty receive FIFO, not the stalled endpoint the code assumed.
.PP
The Pi's LAN9514 carries no
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
mkfile in the tree to build with at all.  All five boots were
re-run from a clean checkout of this commit, in a worktree of its own,
and every result held, so no uncommitted edit is propping any of them
up.  (An earlier note here called the modified
.CW sifiveu.c
and
.CW virtarm64.c
in the first round somebody's in-flight edits.  They are not: portmkfile
generates
.CW $CONF.c
from the board config with
.CW mkdevc ,
the copies committed in the tree are stale against their configs, and a
clean checkout regenerates exactly the same two files the moment you
build.  Like the tracked
.CW .j
objects, they are build output that every build dirties.)
.PP
Left for the real board: the interrupt endpoint (link status), which
neither chip path uses yet and which the model has nothing to report
on, since a host network backend never changes state.
.NH 1
Phase 4: USB mass storage -- DONE under QEMU
.PP
Bulk-Only Transport (class 8, protocol 0x50): two bulk endpoints carry a
31-byte command wrapper holding a SCSI CDB, the data, and a 13-byte
status wrapper.  usbd drives test-unit-ready, inquiry, read capacity and
READ(10)/WRITE(10), and serves the device as a flat file through
.CW file2chan
at
.CW /chan/usbdisk0 ,
turning a byte-range read or write into whole-block SCSI with a
read-modify-write on the unaligned edges.
.CW dossrv
mounts the FAT filesystem on that file at
.CW /n/dos .
.PP
.B "Note a deviation from this plan's own wording:"
what is delivered is that flat file, not an
.CW sd (3)
device at
.CW /dev/sdU0/data .
The goal the phase was written for \- a mountable FAT filesystem off a
USB stick \- is met, and dossrv wants a file rather than an sd device
anyway; but nothing here registers an sd controller, so
.CW kfs
over
.CW sd (3),
and anything else that expects
.CW /dev/sdU0 ,
still has no path.
.PP
.B "The bug that was actually in the way."
The descriptor walk in
.CW attachdev
read each endpoint's
.CW wMaxPacketSize
and passed it to
.CW hidstart ,
but for the mass-storage branch it kept only the endpoint
.I numbers
and dropped the size.  A newly created endpoint starts at devusb's
default of 8
.CW ( devusb.c :
.CW "ep->maxpkt = 8" ),
so the 31-byte command wrapper went out in 8-byte pieces, QEMU's
.CW usb-msd
answered
.CW "Bad CBW size"
on every attempt, and the inquiry came back
.CW "endpoint stalled" .
.CW etherusb
had always set
.CW maxpkt
explicitly and so never hit this; the storage path now carries the two
bulk endpoints' declared sizes and sets them the same way.
.PP
Verified on a booted kernel
.CW ( "-drive if=none,id=d0,file=<img>,format=raw -device usb-storage,drive=d0" ):
usbd finds the device, reports
.CW "disk \(dqQEMU    QEMU HARDDISK   2.5+\(dq 32768 blocks x 512 bytes" ,
reads block 0 and sees the FAT signature (DISK-BLK-OK), and serves
.CW /chan/usbdisk0 ;
dossrv mounts it and the directory lists
.CW hello.txt
and
.CW phase4.txt
(DISK-DOS-OK); the first file's bytes read back correctly
(DISK-READ-OK); and a file created from Inferno, written, closed,
reopened and re-read matches (DISK-WRITE-OK).  The write reached the
medium and not just a cache: after the run the host's FAT image
contains
.CW PI.TXT
holding "written by inferno on the pi", read back with
.CW mtools .
A second boot with
.CW usb-storage
and
.CW usb-net
attached together runs both off the one hub \- disk mounted and written,
DHCP and three ping replies, on to the shell \- which also exercises two
devices contending for the DWC2 split lock Phase 3 had to fix.
.PP
Not done, and not claimed: no partition table is parsed, so the image
must be a bare FAT filesystem rather than an MBR-partitioned disk; only
LUN 0 is addressed; there is no removable-media, medium-change or
error-recovery handling (a stalled endpoint is not cleared and retried);
and no real USB stick has been tried, only QEMU's
.CW usb-msd .
The file created on the FAT filesystem also gets a nonsense timestamp
(2098) \- the board has no RTC and nothing had set the clock, but the
cause was not chased down.  The
.CW "mntwalk waserror()"
line that prints alongside the write is the open arm64 multi-kproc
error-stack bug noted under the kfs item below; it does not stop the
write.
.NH 1
Phase 5: Arasan SDHCI / SDIO -- the second SD controller -- card path DONE, SDIO written and unverified
.PP
.CW sdhcibcm.c
drives the BCM2837's second SD controller (Arasan SDHCI, 0x3f300000), a
standard SD Host Controller rather than the SDHOST block: reset, bus
power, the identification clock, the CMD0/CMD8/ACMD41/CMD2/CMD3/CMD9/
CMD7/CMD16 bring-up, and CMD17/CMD24 single-block PIO through the data
port.  It plugs into devsd as
.CW /dev/sdH0
alongside SDHOST's
.CW /dev/sdM0 .
.PP
.B "One card, two controllers, and the pins decide."
The SoC wires the card slot to whichever block owns GPIO 48-53: alt0 is
SDHOST, alt3 is the Arasan.  Both drivers route the pins in their own
.CW online() ,
so whichever unit is opened first takes the card and the other then
reports no media.  That is the hardware, not an emulator artifact --
there is one card and one set of pins.  On a real Pi 3B you want SDHOST
on the card and this controller left for the Wi-Fi, which sits on its
own pins (GPIO 34-39 alt3), so in the arrangement that matters the two
never contend at all.
.PP
.B "The routing write was doing nothing, and the test still passed."
Stock QEMU 10.1.3 recognises only alt0 on GPIO 48-53; the alt3 write
that hands the card to the Arasan matched nothing in
.CW hw/gpio/bcm2835_gpio.c
and was silently dropped.  The SDHCI path passed anyway, because the
card is parented to SDHCI at reset and devsd probes lazily, so nothing
ever moved it away.  A driver that omitted the routing write entirely
would have passed the same test identically \- which is exactly the
shape of an emulator-only pass.
.PP
.CW tools/qemu-patches/0002
makes alt3 select the Arasan, so the routing is real and can be
falsified.  With it, a round trip \- hand the card to SDHOST, take it
back \- reports
.CW "alt0 released the card, alt3 took it back" ,
.CW SDROUTE-OK ,
and block 0 reads correctly afterwards; without it the same kernel
reports
.CW SDROUTE-FAIL
and the board ends up with no SD card.  This is
.B qemu+patch
evidence.
.PP
Two guest bugs fell out of writing that test, both of which would have
bitten on hardware.  Losing the card raises a card-removal interrupt,
and the controller will not report the new insertion until that status
is acknowledged, so the round trip hung until
.CW sdhcibcm.c
cleared it; and card detect does not settle the instant the pins
switch, so the status has to be waited for rather than read straight
away.  Losing the card also drops the controller's clock and power,
so
.CW sdhcictlrinit()
has to run again before identification.  The round trip lives behind
.CW -DSDROUTETEST ,
since a controller that cannot take the card back leaves the board with
no SD card at all.
.PP
Verified on a booted kernel
.CW ( "-drive if=sd,format=raw,file=<img>" ),
one boot exercising both controllers and the routing in both
directions:
.CW sdhcicheck()
opens
.CW /dev/sdH0
first, so the Arasan takes the card, reads block 0 and gets the FAT
boot sector
.CW ( "block0 eb3c904d sig 55aa" ),
writes block 5 and reads it back byte for byte (SDHCI-WRITE-OK), and
reports
.CW "geometry 32768 512" \-
exactly the 16MB image's 32768 sectors, which is what proves the CSD was
unpacked correctly.  (It had not been at first: SDHCI stores a 136-bit
response as resp[127:8] with only the low 24 bits of RESP3 valid, and
the first cut mis-ordered the words.  A capacity merely large enough to
cover the blocks under test would have hidden it; the geometry line is
there so it cannot.)  The write reached the medium: block 5 of the host
image afterwards holds a0 a1 a2 ... af.  Then
.CW sdcheck()
opens
.CW /dev/sdM0 ,
SDHOST takes the pins back, and its own read, write and 4-block tests
still pass (SD-OK) \- so the card moves between controllers and both
work.
.PP
.B "The SDIO half is written and unverified, and Phase 6 should not assume otherwise."
.CW sdiocmd52()
(IO_RW_DIRECT) and
.CW sdiocmd53()
(IO_RW_EXTENDED, byte and block mode, with the partial-word tail
handled) are the transport
.CW ether4330
will want, written from the SDIO Simplified Specification.  Nothing has
ever run them: an SD memory card rejects both commands, and QEMU models
no SDIO device to answer them.  The SD-card results above say the
register interface, the command engine and the PIO data path are sound;
they say nothing whatever about CMD52 and CMD53.
.PP
Also not done: no interrupt is wired (every wait is a bounded poll, as
in sdhostbcm.c), no DMA -- the controller supports SDMA/ADMA and this
uses the PIO data port -- no multi-block command, no high-speed or
4-bit bus-width switch, so the card runs at the identification divider
throughout, and no real hardware has been near it.
.NH 1
Phase 6: BCM43430 Wi-Fi over SDIO \- transport runs, the chip does not
.PP
The onboard Broadcom BCM43430 Wi-Fi hangs off SDIO (via Arasan), the
piece 9front's ether4330 already handles: firmware upload plus the SDIO
transport, presenting an ether(3) card into /net.
.PP
.B "The transport now runs; the phase is still blocked."
Stock QEMU models no SDIO peripheral of any kind, so
.CW sdiocmd52
and
.CW sdiocmd53
were unrunnable rather than merely untested: an SD memory card rejects
both commands and there was no other device to answer them.
.CW tools/qemu-patches/0004
adds a generic
.CW sd-io
function \- CCCR at function 0, one I/O function behind it, CMD5,
CMD3, CMD7, CMD52 and CMD53, written from the SDIO simplified
specification \- and 0005 teaches the GPIO block to place it on the
Arasan and to keep the card routing away from it.  Against that,
.CW sdiocheck()
reports
.CW "sdio: 1 I/O function(s)" ,
reads the CCCR revision with CMD52, enables function 1 and waits for it
to report ready, then moves data with CMD53 both ways and both ways
round \- 64 bytes in byte mode, and a 512-byte block in block mode,
which is a different path through
.CW sdiocmd53
(the count goes in
.CW Blksizecnt ,
.CW Tmblkcnt
is set, and the transfer waits per block rather than moving one run of
bytes).  Both read back identical:
.CW SDIO-OK .
Block mode is what ether4330 uploads firmware with, so it is the half
worth having covered.
.PP
Deliberately, it is a
.I generic
function and not a BCM43430.  Modelling the Wi-Fi part would put both
halves in this tree with nothing to consume them \- there is no
ether4330 here and no firmware loader \- which proves only that the two
agree with each other.  What the generic function proves is narrower
and real: the transport carries data.
.PP
So this phase is
.B "not done."
What is now true is that Phase 5's
.CW sdiocmd52 / sdiocmd53
have executed and carry data correctly, tier
.B qemu+patch .
Wi-Fi itself still wants ether4330, the firmware upload, and the board.
.PP
.B "One boot, the whole Pi arrangement."
With the function attached the emulated board is wired the way a real
Pi 3B is, and all three paths work at once:
.CW SDIO-OK
on the Arasan,
.CW SD-OK
on SDHOST's
.CW /dev/sdM0 ,
and
.CW SDHCI-NONE
\- which is the correct answer, not a failure, because on that wiring
the Arasan has the Wi-Fi function and not the card.  The memory-card
probe that
.CW sdhcicardinit()
sends is refused by the function
.CW ( "Unknown CMD8" ),
which is the model declining to pretend to be a card.
.PP
Getting there needed a guest change worth naming:
.CW sdhcicardinit()
took GPIO 48-53 unconditionally, which on this wiring would steal the
card from SDHOST.  SDIO bring-up is now a separate entry point,
.CW sdioinit() ,
sharing
.CW sdhcictlrinit()
but running the SDIO identification sequence \- no CMD8, no ACMD41, no
CSD \- and never touching the card pins.
.NH 1
Phase 7: watchdog, RNG, PWM -- RNG and reset DONE, PWM not attempted
.PP
.B "The hardware RNG, and why it mattered."
.CW rngbcm.c
brings up the BCM2835 generator at 0x3f104000 and hands
.CW hwrandbuf
to
.CW randomvirtarm64.c ,
which already preferred it.  Until now this board's
.CW /dev/random
was that file's fallback: a tick-seeded LCG its own comment calls
smoke/dev only.  A deterministic sequence off a boot-time seed is not
entropy, and everything downstream \- keyring, TLS nonces \- was only as
good as that.
.CW rnginit()
refuses to install itself unless two freshly drawn words differ and are
not both zero, so a stuck generator leaves the software fallback in
place rather than silently replacing it with a constant.
.PP
Verified on a booted kernel: the generator comes up (RNG-OK), and
.CW /dev/random
yields sixteen bytes that differ on every boot \- three resets inside one
emulator process gave c40860dd..., 7052c80a... and 6ecf4e49..., same
process, different bytes, which is precisely what the LCG could not do.
What this does not say is anything about the quality of the entropy:
under emulation these bytes come from QEMU's host PRNG.  The plumbing is
proven; the randomness is the silicon's business.
.PP
.B "The watchdog, and a reset that only ever worked on the emulator."
.CW pmbcm.c
drives the power-management block at 0x3f100000.  On this SoC a reset
.I is
a watchdog expiry \- there is no separate reset register \- so
.CW wdogset() ,
.CW wdogstop()
and
.CW pmreset()
are one driver, and every write carries the 0x5a password without which
the block ignores it in silence.
.PP
The reason this is more than a small driver:
.CW archreboot()
called PSCI SYSTEM_RESET, which QEMU answers and a real Pi 3B does not.
The board has no ATF and no secure-monitor firmware behind HVC, so on
the hardware that call reached nothing and the machine never rebooted \-
an emulator-only path sitting in the reset path, exactly the shape
AGENTS.md warns about.  It now uses the PM watchdog, the way Linux's
.CW bcm2835_restart
does.
.PP
A second gap was underneath it:
.CW devcons.c 's
.CW /dev/reboot
handler was a bare
.CW "/* TODO rebootcmd(...) */" ,
so writing "reboot" did nothing at all, on every board in the tree.  It
now calls
.CW exit(0) ,
which shuts the devices down and calls
.CW archreboot() \-
the same thing
.CW main.c 's
own
.CW reboot()
does.  Loading a different kernel image first, which
.CW rebootcmd()
would have added, is still not implemented; a reboot restarts the
machine.
.PP
Verified on a booted kernel, driving the whole chain from Limbo \-
.CW /dev/reboot
to
.CW exit(0)
to
.CW archreboot()
to
.CW pmreset()
to PM_RSTC: three boot banners inside one emulator run, and the
"nothing happened" marker after the write never printed.
.PP
.B "Emulator gap, closed by co-designing the device model."
Stock QEMU 10.1.3 models no watchdog countdown.  Loading PM_WDOG reads
back exactly what was written, and the reset happens the instant
PM_RSTC's WRCFG field is set to full-reset, whatever the counter says.
So on stock QEMU an arm
.I is
a reset: an early
.CW pminit()
that armed the watchdog to watch it count down put the board into a
reboot loop, 167 banners in forty seconds.
.PP
That gap is now closed from the other side.
.CW tools/qemu-patches/0001
gives
.CW hw/misc/bcm2835_powermgt.c
a real counter: it ticks at 65536 Hz, counts only while RSTC selects
full-reset, reads back the time remaining, and freezes where it stopped
\- which is what the SoC does and what Linux's
.CW bcm2835_wdt
driver assumes.  Against that model the full arm, count-down and stop
sequence passes:
.CW ( "loaded 524288 idle 524288 armed 517731 stopped 517730/517730" ),
and the 6557 ticks lost over a 100ms delay come to 100.03ms, so the
rate is right and not merely nonzero.
.PP
This is
.B qemu+patch
evidence, the weakest of the three tiers described in
.CW tools/qemu-patches/README :
both the driver and the device model are ours, so the test proves they
agree, not that either matches silicon.  The register semantics were
taken from Linux's driver rather than from what
.CW pmbcm.c
emits, which is the main thing keeping that agreement honest.  The
watchdog still wants a run on the board.
.PP
.B "The self-test is compiled out."
.CW pminit()
does only what is safe on any hardware: it writes the counter, reads it
back, and checks that it does
.I not
move while disarmed \- which is the required behaviour, not a
deficiency, and passes on stock and patched QEMU alike
.CW ( WDOG-PRESENT ).
The arm-and-stop sequence lives behind
.CW -DWDOGSELFTEST .
A watchdog whose stop does not take reboots the machine 8 seconds later
and keeps doing so, on a real Pi as much as under an emulator, so a
kernel that arms one on every boot just to look at it is a kernel that
can brick its own boot.
.PP
PWM (0x3f20c000) is
.B DONE
under QEMU, model and driver both.
.PP
Nothing on the board wanted it and QEMU mapped nothing there \- not
even an unimplemented stub, so a guest reached unassigned memory.  Both
halves now exist:
.CW tools/qemu-patches/0007
models the block, and
.CW pwmbcm.c
drives it.  The driver is written as the worked example of how to bring
a clock-fed BCM2835 peripheral up, because the order matters and is not
obvious: give the block a clock from the clock manager first (a channel
enabled before that sits there doing nothing), stop the clock before
changing its divisor and wait for BUSY to fall (a divisor written to a
running clock is ignored), carry the 0x5a password on every clock
manager write, and only then route the pin.  It also names the
distinction a PWM driver most often gets wrong: mark/space mode emits
one contiguous pulse per period, which is what a servo measures, while
balanced mode spreads the on-cycles through the period, which is what a
light or a motor wants.  Both produce the same average voltage and
different behaviour.
.PP
.CW pwminit()
exercises the clock manager, both duty modes, the FIFO's full and empty
flags, and both error bits including that they are cleared by writing
one to them:
.CW "PWM-OK clock, mark/space, balanced, FIFO full/empty and errors" .
On stock QEMU it reports
.CW PWM-NONE
and the board carries on, since the block is genuinely absent there.
.PP
.B "It found a real QEMU bug."
The first attempt reported the clock started when it had not: the
driver returned a frequency it had computed itself rather than one the
hardware confirmed.  Checking CM_PWMCTL's BUSY bit instead showed the
clock manager had accepted the programming and done nothing with it.
The cause is in
.CW hw/misc/bcm2835_cprman.c :
.CW update_mux_from_cm()
matches a mux's divisor register at
.CW "cm_offset + 4" ,
but
.CW cm_offset
is a word index and a mux's CTL and DIV are adjacent words, so
.CW "+ 4"
names the CTL register of the mux two slots on.  CM_PWMCTL, at word 40,
is matched by the OTP mux's 36 + 4 \- so programming the PWM clock
updated the OTP mux and returned, and the PWM clock never started.
.CW tools/qemu-patches/0006
matches
.CW "cm_offset + 1" .
This affects every mux, not just PWM.
.PP
With that fixed the two sides agree independently: the driver computes
19.2MHz / 96 = 200kHz from the divisor it wrote, and the model derives
200kHz through the clock manager from the oscillator.  That agreement
is worth more than either number alone.
.PP
What the model does not do is run a serialiser: nothing consumes the
FIFO on its own and no waveform reaches a pin, so the GAPO bits never
come on by themselves and a duty cycle cannot be measured here.  The
registers, the FIFO discipline and the error reporting are what a
driver gets wrong, and those are covered.
.NH 1
Blocks QEMU models that nothing was driving
.PP
Three peripherals the emulator implements properly and this board
simply never touched.  No QEMU work was needed for any of them; the gap
was entirely on this side, and each is now brought up and checked at
boot alongside i2c, spi and the rest.
.PP
.B "The system timer"
.CW ( systmrbcm.c ,
0x3f003000) is a free-running 64-bit counter at a fixed 1MHz.  It is
not the timer the scheduler runs on \- that is the ARM generic timer in
.CW clock.c ,
whose rate is whatever CNTFRQ reports \- and that independence is the
point.  Reading both and comparing catches a wrong frequency, which is
otherwise very hard to see: it shows up only as timeouts that are
mysteriously off by a constant factor.  Over a 50ms
.CW delay()
paced by the generic timer, the system timer measures
.CW "50038 us"
\- agreement to better than a part in a thousand, from two clocks that
share nothing.
.PP
The 64-bit counter sits behind a 32-bit bus, so
.CW systmrread()
reads high, low, high again and retries if the high word moved.
Without that the timestamp jumps backwards by about 71 minutes, roughly
once every 71 minutes.
.PP
.B "The temperature sensor"
.CW ( thermbcm.c ,
0x3f212000) returns a 10-bit ADC reading, not a temperature.  The
conversion has a
.I negative
slope \- degrees C = 412 - 0.538 * adc \- so a larger reading means a
colder die, and getting it backwards yields a driver that reports the
chip cooling as it heats, which only shows up under load.  Done in
millidegrees with integers, since this is a kernel: ADC 719 gives
.CW "25.178 C" ,
matching the fixed 25 degrees the model reports.
.PP
.B "The OTP fuses and board identity"
.CW ( mailbox.c )
come through the firmware mailbox, which is the documented way to reach
them on a Pi \- the block's MMIO register interface is not implemented
in QEMU and is not publicly documented, so driving it would have meant
inventing a protocol.  GET_BOARD_REVISION returns
.CW 0x00a02082 ,
which is the genuine revision code for a Pi 3 Model B, and
GET_CUSTOMER_OTP returns the eight customer rows, all unprogrammed.
The serial reads zero, which is the emulator declining to invent one.
.PP
.B "Read-only, deliberately."
SET_CUSTOMER_OTP sits on the other side of the same interface and does
exactly what one-time-programmable means: a fuse blown on a real Pi is
blown forever, and the rows can be locked against further writing.  A
boot-time self-test that wrote there would quietly consume a board's
fuses the first time it ran on hardware, so this reads and nothing
else.  That is a hardware constraint, not an emulator one.
.PP
.B "The DMA engine"
.CW ( dmabcm.c ,
0x3f007000) is how this SoC moves bulk data without the CPU, and it is
unlike the rest of the board because the engine reads its instructions
from memory: a 32-byte control block giving transfer info, source,
destination, length, stride and the address of the next block.  The
driver hands over an address, not a command, and chaining through
NEXTCONBK is the point \- a whole scatter-gather list runs without the
CPU waking once.
.PP
Two things there are easy to get wrong and both would only bite on the
board.  Every address in a control block, and the block's own address,
is a
.I bus
address: the engine is a bus master and sees RAM through the
0xC0000000 uncached alias, as the VideoCore and the USB core do.  And
the block and its data must be visible to something that is not reading
through the CPU's caches, so
.CW dmacopy()
cleans the control block, the source
.I and
the destination before starting, and invalidates the destination
afterwards.  The emulator is coherent and would forgive all of it.
.CW DMA-OK
copies 256 bytes and compares them byte for byte, with a destination
pre-filled with a value that is neither zero nor the source, so a
transfer that silently does nothing shows as the fill rather than as a
plausible result.
.PP
.B "The AUX mini UART"
.CW ( auxbcm.c ,
0x3f215000) is the Pi's second serial port, and on a Pi 3B usually the
console, the PL011 having been given to the Bluetooth part.  Three of
its habits are worth writing down.  AUX_ENABLES gates the registers and
not merely the function, so until bit 0 is set every mini UART register
reads zero and writes vanish \- including the ones you would use to
find out why.  The line control register's data-length field is
documented as one bit and is two: 8-bit data is 3, not 1, and following
the datasheet gives 7-bit characters, which look like text that is
subtly wrong rather than like a failure.  And the baud divisor derives
from the core clock, not a fixed oscillator, which is why a Pi's mini
UART console garbles when the core clock is scaled.
.PP
This was checked through the pin rather than by reading a status bit:
QEMU wires the AUX block to the second serial port, so with
.CW "-serial mon:stdio -serial file:aux.log"
the string this driver transmits arrives in that file.
.PP
It also found a gap.  The divisor read back as zero, because LCR, MCR,
CNTL, SCRATCH and BAUD were unimplemented in QEMU \- reads returned zero
or a constant, writes were discarded.  On the SoC they hold what a
guest puts in them, and a driver reads the divisor back to confirm the
rate it asked for.
.CW tools/qemu-patches/0008
keeps them; the divisor now reads 270, which is
.CW "250000000 / (8 * 115200) - 1"
exactly.  That patch also reports a guest selecting 7-bit data, since
that is the mistake the erratum invites.
.PP
.CW AUX-OK
appears on stock QEMU as well as on the patched build, and the two are
not equally strong.  On stock the transmit path works and the divisor
reads back zero, so the check passes on the strength of the
transmission alone; on the patched build it passes with the readback
agreeing too.  Both are
.I qemu
tier, but only the second actually confirms the rate.
.NH 1
Blocks QEMU stubbed out, now modelled and driven
.PP
.B "The ARM timer"
.CW ( armtmrbcm.c ,
0x3f00b400, and
.CW tools/qemu-patches/0009 )
was an unimplemented device in QEMU: reads returned zero, writes were
logged, and a guest saw a timer that never counted.  The datasheet
calls it "an SP804, but not fully compatible", and the
incompatibilities are exactly what a stock SP804 driver gets wrong.
The counter is 16-bit unless CONTROL bit 1 selects 23-bit \- not 32,
so a 32-bit period is silently truncated.  There is a pre-divider
between the APB clock and the counter that an SP804 has no equivalent
of, resetting to 0x7d so the counter runs at apb/126 until something
says otherwise.  And there is a second, free-running up-counter with
its own prescaler that an SP804 does not have at all.
.PP
LOAD and RELOAD are not interchangeable either: LOAD reloads the
counter at once and restarts the period in progress, while RELOAD
changes the value taken at the next wrap and leaves the current period
alone.  Changing a running periodic rate through LOAD costs one short
or long tick every time.
.PP
The check runs both counters and measures them against a clock that
shares nothing with either.  The countdown comes out at
.CW "1984126 Hz" ,
which is 250MHz / 126 \- the reset pre-divider, exactly.  The
free-running counter advances 6012500 ticks while the 1MHz system timer
sees 24047 microseconds, and 24047 * 250 is 6011750 \- agreeing to
within a part in eight thousand.  Two counters agreeing that closely is
worth more than either reading alone.
.PP
The first version of both halves passed, and both were wrong.  The
guest read the countdown twice twenty milliseconds apart and passed if
the readings differed, which is far too weak: it passes for a counter
that has stopped anywhere other than where it started.  Sampling the
counter eight times at three milliseconds instead \- long enough in
total to cross a wrap, short enough per interval that the subtraction
across one is unambiguous \- showed it reading
.CW "0 0 7757 1804 15691 9739" ,
correct at the end and parked at zero at the start.
.PP
The model was driving the countdown with a QEMU ptimer and returning
.CW ptimer_get_count()
for VALUE.  That returns a hard zero for any read taken after the
counter has expired but before ptimer's callback has been serviced;
.CW hw/core/ptimer.c
clamps it to "prevent timer underflowing if it should already have
triggered", and no policy flag changes that.  Under TCG a guest in a
calibration loop starves the main loop, so the window is milliseconds
wide.  Real silicon never parks: the counter free-runs and a read lands
wherever it lands.
.PP
.CW tools/qemu-patches/0010
computes both counters on demand from the virtual clock \- which is
what the free-running counter, the one that had always read correctly,
was already doing \- and leaves a plain QEMUTimer to deliver only the
interrupt, so the value and the deadline come from one base and cannot
drift apart however late a callback runs.  The same eight samples then
read
.CW "19647 13639 7684 1732 15618 9633" :
5953 ticks an interval at the programmed rate, wrapping cleanly through
the 19842-tick period.  Run against the old model the new check reports
.CW "ARMTIMER-FAIL countdown fell 1858 in 3003 us, expected 5958" ,
which is how a test earns its keep.
.PP
The APB clock is the core clock, which the firmware scales, so this is
a poor timer for wall-clock work and a good one for periodic
interrupts.  The board keeps the ARM generic timer for scheduling; this
is here because it is part of the SoC and was previously invisible.
.PP
.B "The I2S/PCM serialiser"
.CW ( i2sbcm.c ,
0x3f203000, and
.CW tools/qemu-patches/0011 )
was the last of the stubs, and nothing in the tree wanted it either, so
both halves are new: a model and a driver that is also the worked
example of how to configure the block.  It is the SoC's audio port \-
a frame of programmable length clocked out of a 64-word TX FIFO and in
to a 64-word RX FIFO on GPIO 18-21, which is how a DAC or a MEMS
microphone HAT attaches to a Pi.
.PP
The awkward part is that it has no rate of its own.  The sample rate is
the clock manager's PCM clock divided by the frame length in bits, so
it is set in two registers at once \- CM_PCMDIV and MODE_A's FLEN \-
and getting one right and the other wrong gives audio at the wrong
pitch rather than an error.
.CW i2sconfig()
therefore derives both from a single requested rate and returns what it
actually achieved, so a caller can look.  48kHz needs the clock
manager's fractional divider: a 3.072MHz bit clock is 19.2MHz/6.25, not
an integer, and the 12.12 fixed-point divisor lands it exactly.
.PP
Four other things a driver gets wrong are written into the file.  The
FIFOs must be primed before TXON, because the serialiser starts
clocking at once and an empty TX FIFO underflows on the first frame.
TXCLR and RXCLR are self-clearing and take two PCM clocks, so reading
them back to confirm a clear is a mistake.  The block needs the same
kill/wait/set/enable dance with the 0x5a password that the PWM clock
does.  And CS_A must never be read-modify-written.
.PP
That last one bit this driver before it was written down.  TXERR and
RXERR are write-one-to-clear, so an innocent
.CW "r[Cs] &= ~(Txon|Rxon)"
in
.CW i2sstop()
reads the register with an error bit set, writes it back set, and
clears the error as a side effect \- losing the one piece of
information worth having after an underflow.  It went unnoticed because
the test that should have caught it then wrote its own explicit clear
over dead ground.  The driver now keeps a shadow of the writable bits
and writes CS_A absolutely, and the exercise stops the block with TXERR
deliberately set and checks it survives; against the old code that
reports
.CW "I2S-FAIL stopping the block cleared TXERR" .
This is not an emulator artifact \- it is how the silicon behaves.
.PP
The exercise checks the FIFOs and their flags statically, then the
error and interrupt-status bits \- easy to get backwards, since both
are write-one-to-clear \- and then the frame rate itself, by timing how
long the serialiser takes to drain a full 64-word FIFO against the 1MHz
system timer, and to fill the RX FIFO the same way.  It reports
draining 64 frames in 1341 microseconds against 1333 expected, and
filling in 1341.  The reception half is a separate result rather than a
restatement of the first: with the RXON write removed the RX FIFO never
fills and the check times out, so it is measuring the receive path and
not just the frame clock.
.PP
What the timing establishes, and what it does not, is worth being
plain about, because this is
.I qemu+patch
tier and both halves are ours.  An independent clock catches a wrong
divisor \- which is the failure that gives a working driver and audio
at the wrong pitch, and which no amount of reading registers back would
show.  It cannot catch a misreading of the datasheet's channel position
or width encoding that the model and the driver happen to share; only a
DAC on a real Pi settles that.
.PP
The model has no audio backend: TX data is discarded and RX reads
zeroes, which is what an unconnected DIN pin gives on a board.  One
departure from the datasheet is deliberate and is flagged in the model
as well as here \- its TXTHR and RXTHR description is defective, giving
four settings but identical text for 01 and 10 with the fraction
missing.  The hardware uses quarters, and that is what is implemented.
.PP
.B "The AUX SPI masters"
.CW ( auxspibcm.c ,
0x3f215080 and 0x3f2150c0, and
.CW tools/qemu-patches/0012 )
fell through to "Bad offset" in QEMU, so a guest could not use them at
all.  They are not SPI0 with a different register layout.  The shift
length is a number of
.I bits ,
1 to 32, not a number of bytes, so a 12-bit ADC or a 9-bit display
controller is a single transfer here and an awkward mess on SPI0.  That
is the reason to reach for this block.
.PP
The other difference is a trap.  Transmitted data is taken from the
.I top
of the written word and received data arrives at the
.I bottom :
an 8-bit transfer sends bits 31:24 and answers in bits 7:0.  A driver
that writes a bare byte \- exactly right on SPI0 \- clocks out zeroes,
and a slave receiving zeroes usually answers with zeroes rather than
complaining.
.PP
The third difference only appeared because the test used a peripheral
nobody here wrote.  An
.CW m25p16
flash answered a JEDEC identify with zeroes; a trace showed 0x9f
reaching it, but its command state machine had been left mid-command by
earlier traffic and nothing could resynchronise it, because chip select
never moved.  That is what the two register windows are
.I for :
a write to TXHOLD keeps chip select asserted after the word and a write
to IO drops it, so a multi-word command is one transaction.  With chip
select modelled the same flash answers
.CW "jedec 20 20 15" .
.PP
That result is worth more than the rest of the file.  Everything else
here is
.I qemu+patch
\- both halves ours \- but the flash is QEMU's own model, so the
register layer is checked against something this port did not write.
.PP
Two limits are stated in the driver rather than hidden by it.  The
12-bit shift length is checked into CNTL0 and STAT but not carried
through a peripheral, because QEMU's SSI bus moves whole bytes and the
model says so; the banner says "an 8-bit transaction" for that reason.
And
.CW auxspiword()
waits for RX_EMPTY to clear before reading the answer.  Both this
block's model and SPI0's complete a transfer inside the register write
that starts it, so that wait spins zero times and a driver without it
looks perfect here and reads stale words on a board.  It is written
from what the silicon does.
.NH 1
What stays unmodelled, and why
.PP
The remaining
.CW create_unimp
blocks in QEMU's Pi peripherals are not a to-do list.  Each is left
alone for a reason, and the reason is never that the emulator would be
hard to extend.
.PP
.B "The BSC slave"
(0x3f214000) is blocked on documentation that can be checked.  Linux
6.17 has no driver for it \- it exists only in the Raspberry Pi vendor
tree \- and the datasheet section describing it was not available here.
The register offsets are recoverable; the bit semantics of CR and FR
are not, and a model built on a remembered bit layout is a model a
driver is then written to match.  That is the both-halves-ours failure
the evidence tiers in
.CW tools/qemu-patches/README
exist to prevent, and it is worse than the PWM's missing serialiser,
where the register semantics were solid and only the behaviour was
absent.
.PP
Note what is
.I not
the blocker, since it was recorded as one here and is not: exercising
it needs no external master.  The Pi has three I2C masters of its own,
QEMU models them with real buses, and
.CW i2cbcm.c
already drives BSC0, so attaching the slave to that bus would model the
pin strap a real board uses.  Either the datasheet's section 11 or the
vendor tree's driver would unblock this, and neither is much work once
one is in hand.
.PP
.B "The secondary memory interface"
(0x3f600000) is blocked the same way, and it was checked the same way:
Linux 6.17 has no
.CW bcm2835-smi
either.  Its register semantics are not public in enough detail to
model faithfully, and a model written from guesswork would be inventing
behaviour for a driver to match.
.PP
.B "TXP, DBUS, AVE0, V3D and SDRAMC"
are internal to the SoC.  They are either undocumented, driven only by
the VideoCore firmware, or \- in V3D's case \- a GPU, which is out of
scope for this port by the same decision that leaves out OpenGL below.
.NH 1
Parallel: the kfs create failure -- re-diagnosed, and it is not what the old note said
.PP
Independent of USB and not blocking (dossrv, ramfs and 9660srv all run
over the working SD block device), but worth fixing for a reliable
native writable filesystem.  The reproducer is still
.CW sdfs()
in
.CW raspi3binit.b ,
and it still fails.  What it is doing, however, is not what
.CW doc/inferno-driver-plan.ms
concluded, and that note should not be relied on.
.PP
.B "The old diagnosis was a printing artifact."
It said pid 1 enters
.CW error()
and stalls in its prologue right after
.CW spllo() ,
because a print on
.CW error() 's
first line never appeared "even ungated", and that raspi3b never reaches
.CW mntwalk 's
.CW waserror()
recovery.  Neither holds.  Instrumented with
.CW iprint
instead of
.CW print ,
the unwind is complete and ordinary:
.CW error()
is entered, passes
.CW spllo() ,
reaches
.CW nexterror() ,
and both of
.CW mntwalk 's
.CW waserror()
handlers fire and recover, exactly as they do on the USB/dossrv path.
The reason the earlier prints vanished is that
.CW print()
queues through
.CW serialoq
(devcons.c's
.CW putstrn0 ),
and the kproc that drains that queue is itself blocked by the time the
failure happens, so the output is written and never emerges.
.CW iprint
goes to the uart directly and shows everything.  Any conclusion in that
document drawn from a print that "never fired" is suspect for the same
reason.
.PP
.B "It is not a deadlock, and the Styx conversation succeeds."
Tracing every 9P message across the mount shows the whole exchange
completing: Tattach/Rattach, then Twalk answered with Rerror
("directory entry not found" \- correct Styx, the create's existence
check), then Twalk/Rwalk, then
.B Tcreate answered with Rcreate,
then Tclunk/Rclunk.
.CW kcreate()
returns a valid descriptor \- fd 6 \- so the file is created on the kfs
filesystem and the kernel has an open channel for it.
.PP
The failure is entirely after that success.  The newly created fid is
clunked, the next use of the descriptor raises
.CW "fd out of range or not open" ,
and an empty error string then propagates out of the Init prog, which
.CW vmachine() 's
handler cannot place (an empty
.CW errstr
makes
.CW handler()
return 0), so the prog exits.  The board never reaches its shell because
.I init
died, not because anything is wedged: the proc dump at that point shows
the interpreter idle on
.CW isched.irend
and the remaining procs in
.CW qwait ,
which is what an idle machine looks like once its init has gone.
.PP
.B "One hypothesis tested and rejected."
.CW newfd()
installs the descriptor in
.CW up->fgrp
while
.CW mkfd()
takes its reference from
.CW up->env->fgrp ,
and
.CW Sys_create()
does a
.CW release() / acquire()
between them, so those two Fgrps diverging would explain the symptom
precisely.  They do not: printed either side of the window they are the
same pointer throughout.  Whatever closes the descriptor is elsewhere.
.PP
.PP
.B "A second pass found and fixed a real bug here, which is nonetheless not this one."
.CW mount (2)
consumes its descriptor:
.CW bindmount()
ends its success path with
.CW "fdclose(up->fgrp, fd, 0)" ,
so the number is free again the moment
.CW sys->mount
returns.  The Limbo
.CW FD
handed in still carries that number, though, and
.CW freeFD() \-
its finaliser \- closes it a second time whenever the program drops the
handle.  By then the kernel has very likely reissued the number, so the
second close lands on an unrelated file.  Traced live in the reproducer:
.CW sys->pipe
gives fds 6 and 7,
.CW sys->mount
consumes 6, the create is then handed 6 again
.CW ( "newfd fg 0x390d550 fd 6 maxfd 5" ),
and the stale pipe handle closes it underneath.
.CW Sys_mount()
now marks the handle spent on success, so the second close cannot
happen; a program that goes on using it gets a clean error instead of
somebody else's file.  Verified not to regress anything: the full
board \- SD card, USB stick through dossrv (which mounts a pipe exactly
this way), USB ethernet \- still passes every marker.
.PP
That fix does
.I not
cure the kfs create, so it is not offered as one.  With it in place the
create still fails identically, because the first close is the create's
.I own
FD object, freed at refcount 0 the instant after
.CW "*f->ret = mkfd(fd)"
stores it.
.PP
.B "What the last pass narrowed it to."
Two hypotheses are now dead by measurement, not argument.  The Dis frame
does not move across the call: the
.CW f
and
.CW f->ret
pointers are identical either side of
.CW Sys_create() 's
.CW release() / acquire() .
And nothing is wrong with the mount, the fgrp, the descriptor machinery
or the transport in this program:
.CW sys->open("/tmp")
through the very same mount, in the same prog and the same fgrp, using
the same
.CW release() / acquire() -then- mkfd()
shape, returns a working handle and
.CW fstat
through it succeeds (SD-FS-OPEN-OK, SD-FS-STAT-OK).
.PP
What is left is specific to
.CW create ,
and the one thing create does that open does not is take an
.CW error()
unwind in the middle of the call \- the benign walk-Rerror of its own
existence check, recovered inside
.CW mntwalk .
The create's Styx completes after that (Twalk/Rwalk, Tcreate/Rcreate)
and
.CW kcreate()
returns a valid descriptor; the FD object built from it is then dropped
before the Limbo assignment can take effect, and an empty error string
eventually propagates out of the prog, which
.CW vmachine()
cannot place and so exits.  The next pass should look at what that
mid-call unwind does to the saved Dis state \- the prog is
.CW release() d
and its registers are in
.CW up->iprog
across the whole of
.CW kcreate() \-
rather than at the frame, the fgrp or the transport, all three of which
are now ruled out.
.NH 1
When this is done
.PP
With Phases 0-4 the Pi 3B is an interactive networked Inferno
workstation: framebuffer display, USB keyboard and mouse, wired ethernet,
and USB storage, over a firmware-loaded kernel8.img on real hardware.
Phases 5-7 add Wi-Fi and the small peripherals.  Left out on purpose,
until the machine is otherwise complete: Bluetooth, the CSI camera, DSI
display, and anything GPU/OpenGL/VideoCore-accelerated.
