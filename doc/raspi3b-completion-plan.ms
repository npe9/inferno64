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
.B "What the core says about itself, and what was done with it."
A DWC2 driver is meant to configure from the core's own description:
the GHWCFG registers give the channel count, the FIFO RAM size, the
queue depths and the PHY types, because the same core is built with
different parameters in different SoCs.  This driver reads two of them.
It takes the host channel count from GHWCFG2 and gets 8, which is
right.  It read the FIFO depth out of GHWCFG3 and then threw it away
\- the line was
.CW "USED(n, ptx)" ,
which is the compiler being told to stop complaining about a variable
nothing looks at \- while carving three FIFOs out of that RAM to a
fixed plan of 774, 256 and 512 words.
.PP
Asking a device how big it is and then not reading the answer is worse
than not asking, because the code reads as though the layout had been
checked.  It is checked now, and refuses rather than laying the
periodic FIFO partly outside the block, which on hardware is corrupted
transfers and not an error.  The check was verified the way the others
here were, by building a QEMU that reports 1024 words instead of 4096:
.CW "panic: usbdwc: fifo layout 774+256+512 words needs 1542, the core reports 1024" .
The model was restored afterwards and no patch ships for it.
.PP
The numbers are printed on every boot rather than under
.CW dprint ,
because they are what every sizing decision rests on and a log without
them cannot be used to check any of those decisions later:
.CW "usbdwc: 8 chan, fifo 4096 words, layout 774+256+512, hport0 0x21001" .
.PP
Reading GHWCFG2 properly also turned up a QEMU bug, patch 0020.  Its
two transmit queue depths are two-bit fields and both were written as a
raw 4, which needs three bits, so each set a bit in the field above it:
a guest read back a non-periodic depth of 0, a periodic depth of 1 and
9 device tokens where the source says 4, 4 and 8.  Three fields wrong,
two of them wrong because of a neighbour.  Nothing in the model reads
these registers back \- they are written once at reset and exist only
to be read by a guest \- so no behaviour depended on them and no test
could have caught it.  It is the fifth category once more, and this
time the wrong self-description was an arithmetic accident rather than
a stale constant.  The fields now go through a macro that fails the
build when a value does not fit the field it names.
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
Phase 2: USB keyboard and mouse -- DONE, end to end
.PP
No new driver was needed: usbd's boot-keyboard reader already translates
HID usage codes to UTF-8 and writes them to /dev/keyboard, which devcons
routes to its graphics keyboard queue (gkbdq) -- the input a wm/tk
console reads, correctly distinct from the uart serial console.
Verified whole: with -device usb-kbd, injecting "hello\\n" at the QEMU
monitor makes raspi3binit's reader print h e l l o and a newline from
/dev/keyboard -- QEMU keyboard, through the root hub, through the DWC2
driver's split interrupt transfers, through usbd's HID translation, to
cons.  .PP
.B "The mouse, and how little was actually missing."
Everything but one line was already there.
.CW usbd.b
enumerates the boot mouse, decodes its HID reports and writes
.CW "m x y b"
to
.CW /dev/pointer ;
.CW devpointer.c
is in the board's device list and its
.CW #m
is built into the kernel.  What was missing is that
.CW raspi3binit.b
never bound
.CW #m
into
.CW /dev ,
so the file the reader opens did not exist.  The symptom was one line
in a boot log that had been there all along:
.CW "usbd: ep3.0: boot mouse on ep3.1"
immediately followed by
.CW "usbd: /dev/pointer: file does not exist" .
The enumeration, the HID decode and the pointer device were all
working and unreachable from each other.
.PP
With the bind,
.CW USB-MOUSE-OK :
motion and buttons arrive through usbd's decode to
.CW #m/pointer ,
identically on stock QEMU and the patched build, since none of this is
a model change.
.PP
.B "What the check asserts, and why the button half matters."
Motion only proves the path carries data.  The buttons prove usbd's
HID-to-devpointer remap, which had never once executed \- there was no
.CW /dev/pointer
for the reader to open, so the line sat there being read and never
run.  HID puts left in bit 0, right in bit 1 and middle in bit 2;
devpointer wants 1, 4 and 2.  Right and middle are transposed, and a
motion-only test cannot see a transposition.  Both are injected and
both are checked \- right must arrive as 4 and middle as 2 \- so
dropping or reversing the shuffle fails.  It reports
.CW "buttons 6" ,
which is 4 and 2 together.
.PP
Two things about the harness are worth writing down, because both
produced a wrong answer first.
.IP \(bu
QEMU's monitor help for
.CW mouse_button
says "1=L, 2=M, 4=R".  It is wrong.  The values are
.CW MOUSE_EVENT_LBUTTON
1,
.CW MOUSE_EVENT_RBUTTON
2 and
.CW MOUSE_EVENT_MBUTTON
4
.CW ( include/ui/console.h ),
so 4 is middle and 2 is right.  Injecting 4 and expecting a right-click
made a correct remap look transposed.
.IP \(bu
The first event any fresh reader of
.CW /dev/pointer
gets is the cursor's own starting position \- 320 240, the middle of
the screen \- delivered whether or not a mouse exists.  Taking it as
the motion baseline hides the real deltas, which start again from 0,
and counting it as an event made a board with no mouse attached report
.CW USB-MOUSE-FAIL
on the strength of something the pointer device produces by itself.
It is the baseline and it is not counted.
.PP
.CW USB-MOUSE-NONE
means no events arrived in the window, which is what an invocation
without
.CW "-device usb-mouse"
says and is not a failure.  It cannot distinguish that from a mouse
that enumerated and then said nothing; a mouse that speaks and is
decoded wrongly gives
.CW USB-MOUSE-FAIL .
The check is spawned rather than called, so a boot with no mouse does
not stall for the window.
.NH 1
Phase 1 (historical): the DWC2 controller
.PP
.I "The chapters marked historical are the original plan text, kept for"
.I "what it expected rather than for what happened; the chapter of the"
.I "same number above each carries the result.  They sit here rather than"
.I "at the end because that is where they were written."
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
Phase 2 (historical): USB keyboard and mouse
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
Phase 5: Arasan SDHCI / SDIO -- the second SD controller -- DONE
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
One caution added later, from the same cross-check that settled the
DMA question.  The whole round trip is read through
.CW Cardinserted ,
and Linux carries
.CW SDHCI_QUIRK_BROKEN_CARD_DETECTION
for
.CW brcm,bcm2835-sdhci :
card detection on this part is not to be trusted.  Under QEMU the bit
behaves, and the two guest bugs above are real bugs found through it.
But the test's own mechanism is one the reference implementation says
does not work on the board, so a failure of this diagnostic on real
hardware would say nothing about the routing.  It stays compiled out,
and now for two reasons rather than one.
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
Also not done: no real hardware has been near it.
.PP
.B "The four-bit bus, and what an emulator can and cannot say about it."
The card and the host are now moved to the four-bit data bus after
SELECT, which is the first half of what that list used to say was
missing.  Only one order is safe, and it is worth writing down because
the wrong one does not fail: the card accepts the width by ACMD6
first, and the host's
.CW Control0
bit is set second.  A host reading four lines from a card still
driving one reads whatever the three idle lines are sitting at.  That
is corruption, not an error, and nothing reports it.
.PP
It is checked by reading it back rather than by assuming the command
took.  ACMD13
.CW ( SD_STATUS )
returns 64 bytes, most significant first, and
.CW DAT_BUS_WIDTH
is bits 7:6 of the first: 0 is one bit, 2 is four.  The card reports 2,
and the existing
.CW SDHCI-WRITE-OK
and
.CW SDHCI-OK
block transfers run afterwards and still read back what they wrote --
the card saying it accepted, and the host half agreeing.  Asking for
one bit instead makes the check report
.CW "SDHCI-4BIT-FAIL card reports DAT_BUS_WIDTH 0" ,
so the assertion is not vacuous.
.PP
The marker was
.CW SDHCI-4BIT-ACCEPTED
and is now
.CW -OK ,
and the difference is a patch rather than a change of mind.
.PP
.B "Codesign: making the emulator able to fail this."
QEMU's SD model recorded the width in
.CW sd_status[0]
and read it nowhere afterwards, and the host's side never reached the
card at all \-
.CW sdhci
wrote
.CW hostctl1
and nothing was told.  So every sequence passed, including the wrong
ones, and the marker could only honestly say ACCEPTED.
.PP
.CW tools/qemu-patches/0017
closes it.
.CW sdbus_set_bus_width() ,
mirroring the
.CW sdbus_set_voltage()
that was already there, carries the host's width to the card;
.CW sd.c
compares it against ACMD6's value at both entries to a data transfer
and refuses, with a guest error naming both widths.  Refusing rather
than garbling is deliberate: real hardware returns whatever the
undriven lines are sitting at and the corruption surfaces later with
nothing pointing at it, and a model that reproduced that faithfully
would reproduce only the part that makes the bug hard to find.
.PP
Two things that patch had to get right, neither of which any test in
the tree would have caught.  The hook belongs on
.CW sd_class_init
and not the common class, because eMMC carries bus width in EXT_CSD and
never issues ACMD6 \- on the common class its card-side width would
read one line forever and every eMMC transfer would be refused.  And
.CW sdhci_reset()
must push the width too: it clears
.CW hostctl1 ,
and a card left believing the host is still four-bit refuses
everything after a reset.
.PP
.B "What it buys, and what it still does not."
Deleting the ACMD6 while still setting
.CW Control0
now gives
.CW "SDHCI-4BIT-FAIL SD_STATUS did not arrive"
and fails every later block read.  The sequence is falsifiable, which
is what makes the marker OK.
.PP
Inverting the order instead \- host bit first, ACMD6 immediately
after \- still passes, and that is correct rather than a gap.  No data
transfer falls in the window between the two writes, so the two ends
never disagree while it matters.  The invariant the hardware actually
has is "at every data transfer the two ends agree", not "the writes
happened in this order", and that is the invariant modelled.
.PP
Still not shown, and not showable: that four lines are electrically
driven.  The model has no wire to narrow.  What 0017 buys is the
sequence and the agreement, which is the half a driver can get wrong.
.PP
.B "And off the identification divider."
The clock followed the bus width.  Identification runs at 400kHz or
less and the card has been in transfer state since SELECT, so there
was no reason to stay there; the capabilities register reports a 52MHz
base, and the divider now comes from it rather than being pinned at
0x80.  Under QEMU that lands on 13MHz, not 25: the divided-clock form
gives base over 2N, 52/2 is 26 and default speed tops out at 25, so N
is 2 and the choice is deliberately the conservative side of the
limit.  It is still 64 times the identification rate.
.PP
The 13 is an artifact of the base QEMU reports, not the board's answer.
On a Pi the Arasan's base comes from a firmware-configurable clock, so
real hardware reporting anything other than 52 lands on a different
divider.  The arithmetic is the deliverable; the number this run
produced is not.
.PP
The sequence is the part worth having.  SDCLK must be stopped before
the divider changes and restarted once it is stable, and changing a
divider under a running clock is what the specification forbids.
Unusually for this document, the emulator does check the important
half:
.CW sdhci_can_issue_command()
refuses every command while
.CW SDHC_CLOCK_IS_ON
is false, so leaving the clock stopped does not pass quietly.
Deleting the restart turns
.CW SDHCI-WRITE-OK
and
.CW SDHCI-OK
into
.CW SDHCI-FAIL ,
which is how that was confirmed rather than assumed.
.PP
The rate itself is still unobservable -- nothing in the model times a
transfer against SDCLK, so a card given four clocks where it needs
forty reads identically -- which is why this marker is
.CW SDHCI-SPEED-ACCEPTED
too.
.PP
.B "Where the base clock comes from, which is not one place."
The divider is relative to a base clock, and the driver used to take
that from the capabilities register, bits 8-15, in MHz.  QEMU puts 52
there \-
.CW capareg
0x52134b4 in
.CW bcm2835_peripherals.c
\- and a real BCM2835 puts nothing usable there at all.  Linux marks
.CW brcm,bcm2835-sdhci
with
.CW missing_caps
in
.CW drivers/mmc/host/sdhci-iproc.c
and substitutes a table of its own, and that table sets no base-clock
field either.  On the board the number has to come from the firmware,
exactly as UARTCLK does.
.PP
So the driver asks capabilities first and the firmware second, through
the same
.CW mboxgetclock()
the console uses, clock id 1.  The marker names which answered, and it
has to: the two disagree, and with a 50MHz ceiling that is the whole
result.  From capabilities,
.CW "base 52MHz from capabilities / 2 = about 26MHz" ,
because 52 undivided exceeds the ceiling.  From the firmware,
.CW "base 50MHz from firmware clock 1 undivided" .
Same driver, same ceiling, roughly double the clock depending on which
source answered.  A log that did not name the source would be
unreadable a month later.
.PP
Both paths are exercised, and only one of them is the board's.  Under
stock QEMU capabilities answer and the firmware path never runs; on
hardware it is the reverse.  The fallback was verified by zeroing bits
8-15 of
.CW capareg
in a local QEMU \- 0x52134b4 becomes 0x52100b4, which is what the part
reports \- booting, and reading the marker back.  That is
.B qemu+patch
evidence for a path that
.B hardware
will be the only real user of, and the honest statement is that the
capabilities path is tested by every boot and the firmware path is
tested only by a model deliberately made to lie in the direction the
silicon lies.
.PP
That path also carries an ordering requirement, and it is worth saying
that the requirement holds by construction rather than by luck.  Unlike
the console, which asks for UARTCLK early enough that
.CW virtarm64_enable()
needs a fallback for a mailbox that is not up yet, this has no fallback:
if the mailbox could not answer, the driver would take
.CW SDHCI-SPEED-NONE
and leave the card at the 400kHz identification clock for the whole
boot.  It cannot happen here.
.CW mailboxinit()
is called from
.CW main()
at line 149 and
.CW chandevreset()
at line 207, and the Arasan controller is an
.CW sdifc
entry brought up by
.CW devsd
at or after that.  Fifty-eight lines and one subsystem apart, in one
function, in the fixed order the file is written in.
.PP
The 50-against-52 disagreement is itself a divergence, recorded in
.CW tools/qemu-patches/README
and deliberately not patched.  Nothing in the model is paced by either
number \- QEMU's SDHCI times no transfer \- so there is no behaviour to
falsify and a patch would be moving a constant to please a reader.
.PP
.B "The capacity, which was printed and not tested."
The card reports its size in the CSD, a 136-bit response both
controllers unpack for themselves, and the boot already printed what
.CW devsd
made of it \-
.CW "geometry 32768 512" .
Printing a number is not testing it.  A CSD unpacked wrongly, or a
model whose CSD disagrees with the image behind it, gives a capacity
that looks entirely plausible until something writes near the end of
the card and the data goes nowhere, which is silent.
.PP
So the claim is now checked at its only observable edge: the last
sector the card says it has must read, and the sector after it must
not.  Both halves are needed.  A capacity too large passes the first
only if the backing store really is that big; a capacity too small, or
a
.CW devsd
that does not range-check at all, fails the second.
.CW "SDHCI-CAP-OK sector 32767 reads and 32768 does not" .
.PP
Both controllers get the check, and that is the other half of its
value.
.CW sdhostbcm.c
and
.CW sdhcibcm.c
unpack the same card's CSD independently, so a boot where they report
different capacities for one card says that one of them is wrong \-
which is precisely the failure a single printed number cannot show.
They agree.
.PP
And the numbers track the card rather than being incidental.  Three
sizes were run, chosen to cover both decodes rather than to vary the
number:
.IP \(bu
8MB \-
.CW "csd v1, 16384 sectors" ,
geometry 16384, boundary at 16383/16384.
.IP \(bu
16MB \-
.CW "csd v1, 32768 sectors" ,
geometry 32768, boundary at 32767/32768.
.IP \(bu
4GB \-
.CW "csd v2, 8388608 sectors" ,
geometry 8388608, boundary at 8388607/8388608.
.PP
The third one is there because the first two were not enough, and it
took printing the CSD version to see that.  There are two decodes in
.CW sdhcicardinit() :
the SDSC form,
.CW "(cap+1) << (cmult+2+rbl-9)" ,
which reads three separate fields and shifts by their sum, and the SDHC
form,
.CW "(cap+1) << 10" ,
which reads one.  Both small images take the first \- QEMU emits CSD v1
for a card under 2GB \- so a suite of 8MB and 16MB exercises the harder
decode twice and the easy one never, while looking like coverage.  A
4GB card, sparse and therefore free, crosses into v2.  The driver now
prints which version it decoded on every boot, because a log that does
not say cannot be read as evidence for either branch.
.PP
The enclosing marker was also masking this.
.CW SDHCI-OK
was printed unconditionally two lines after the capacity check, so a
.CW -CAP-NONE
\- which is what a ctl file that cannot be read or parsed produces \-
sat inside a pass.  The check now gates the marker: an unconfirmed
capacity means no
.CW SDHCI-OK ,
the same way every other failure in that function returns before it.
.PP
Ordinary
.B qemu
evidence throughout, no patched model needed.  The card's
self-description is one of the few things this model gets exactly
right, and there is now a boot that would notice if it stopped.
.PP
.B "High speed, which is what lifts the ceiling."
CMD6 is two commands wearing one number: bit 31 of the argument clear
means "check", which reports what the card can do and changes nothing,
and set means "switch", which selects.  The other 24 bits are six
four-bit function groups with 0xf meaning "leave this one alone", so
0x00fffff1 asks for group 1 function 1 and 0x80fffff1 sets it.
.PP
Both forms answer over the data lines with the same 64-byte block, and
reading it is the point.  A card that cannot do high speed answers the
switch without an error and simply reports function 0 back: nothing
fails, you merely do not get what you asked for, and then raise the
host clock past what the card agreed to.  So the support bitmap is
read first \- group 1 support is bytes 12 and 13, big-endian, bit 1
being high speed \- and the selection is read back afterwards from the
low nibble of byte 16.  The card reports support
.CW 0x8003
and selects function 1:
.CW SDHCI-HISPEED-ACCEPTED .
.PP
Only then does the clock move, and this is the ordering that matters
on hardware.  Raising the clock before the card has agreed runs it
outside its own timing, which is corruption rather than an error.  With
high speed agreed the ceiling is 50MHz, so 52/2 is now legal and the
divider is 1 rather than 2, which the register field calls 26MHz where
the previous piece called it 13.  That is arithmetic on a register,
not observed throughput: as with
.CW SDHCI-SPEED-ACCEPTED
above, nothing in the model times a transfer against SDCLK, so the
doubling is a number this driver computed and not a rate anything
measured.
.PP
The fallback is the half worth testing, and it is testable.  Asking for
a function this card does not offer gives
.CW "SDHCI-HISPEED-NONE card supports group 1 0x8003, no high speed" ,
and the clock then stops at the 25MHz ceiling and 13MHz, exactly as
before.  A card that will not go fast never gets a fast clock.
.PP
.B "The line this driver deliberately does not write."
The standard sequence pairs CMD6 with the host's own High Speed
Enable, Control0 bit 2.  This part is one where that bit does not
work: Linux carries
.CW SDHCI_QUIRK_NO_HISPD_BIT
for
.CW brcm,bcm2835-sdhci
.CW ( drivers/mmc/host/sdhci-iproc.c ).
So the card is told through CMD6 and the host follows through the
divider alone, and nothing here touches
.CW Control0 .
That was true by accident before it was checked; it is now written
down in the driver, because adding the "missing" bit is exactly the
tidy-looking change a later reader would make.
.NH 1
Why the SDHCI DMA engine is not driven, which is not the same as not
yet driven
.PP
This document listed "no DMA \- the controller supports SDMA/ADMA and
this uses the PIO data port" among Phase 5's gaps, as though it were
work not yet done.  It is not work at all, and the reason is worth
recording so nobody spends a week on it.
.PP
QEMU models SDMA and ADMA fully
.CW ( sdhci_sdma_transfer ,
.CW get_adma_description
in
.CW hw/sd/sdhci.c ),
so a DMA data path would have been straightforward to write and would
have passed every check in this document.  Linux does not use either
on this part.
.CW brcm,bcm2835-sdhci
maps to
.CW bcm2835_data ,
which sets
.CW "missing_caps = true" ;
.CW sdhci_iproc_probe
then calls
.CW __sdhci_read_caps
with the driver's own capability words in place of the register's, and
those words are
.CW MAX_BLOCK ,
.CW CAN_VDD_330
and
.CW CAN_DO_HISPD
\- with
.CW SDHCI_CAN_DO_SDMA
and
.CW SDHCI_CAN_DO_ADMA2
present in the generic iproc entry immediately above and deliberately
absent here.  The capability register on this part is not to be
believed, and what replaces it says PIO.
.PP
So an SDMA path would work under the emulator and would be driving the
controller in a mode the reference implementation refuses to use on
this silicon.  There is a second reason to distrust it: the address.
QEMU's model reads and writes ARM physical addresses, while the
BCM2835's other bus master, the DMA engine in
.CW dmabcm.c ,
must be given the 0xC0000000 bus alias instead.  Which of the two the
Arasan wants on real hardware is not something an emulator that
accepts either can settle.
.PP
Two emulator-only paths, then, and no way to test either without the
board.  The PIO data path stays, and this is recorded as a decision
rather than as an omission.
.PP
.B "The interrupt is the same shape of answer."
This chapter also listed "no interrupt is wired (every wait is a
bounded poll, as in sdhostbcm.c)".  Nothing forbids it \- Linux carries
no quirk against interrupts on this part, the controller's IRQ is GPU
62, QEMU raises it, and
.CW trap()
has dispatched that bank since the console work.  It is still not
worth doing.
.PP
Half the driver cannot use it at all.  Identification runs from
.CW sdhcicardinit() ,
which like every device init on this board runs before
.CW init0()
calls
.CW spllo() ,
where a counter in
.CW trap()
reads zero entries \- the same wall the ARM timer's check ran into.
So identification polls whatever else changes.
.PP
That leaves the transfer path, and there the wait being replaced is
not observable.  QEMU completes a command inside the register write,
so every
.CW awaitbit
falls straight through; the interrupt would save a spin that measures
zero here and cannot be measured at all without the board.  Rewriting
the data path that carries
.CW SDHCI-OK ,
.CW SDHCI-MULTIBLOCK-OK ,
.CW SD-FS-CREATE-OK
and kfs, to replace a mechanism that works with one whose benefit is
untestable, is the same trade refused above for DMA.
.PP
The two halves are at least consistent with each other, which was
worth checking after the console.
.CW Irptmask
is
.CW ~0
so the status bits set and the polls can read them;
.CW Irpten ,
which is what would actually assert IRQ 62, is 0; and nothing calls
.CW intrenable(62) .
An interrupt armed at the controller with no handler to dispatch it is
exactly the quiet fault that cost this port its console output, and
this is not one.
.PP
So Phase 5's remaining list closes as three decisions rather than three
omissions: no DMA, no interrupt, and no real hardware yet \- and only
the last of those is something a future session can change without a
board.
.PP
.B "Four blocks, one command."
A request for more than one block was four commands, four responses
and four turnarounds; it is now a single CMD18 or CMD25 with the count
in the top half of
.CW Blksizecnt
and
.CW Tmautocmd12
set, so the controller sends the STOP_TRANSMISSION itself.  That last
part is not decoration: an open-ended multiple read that nothing stops
leaves the card still sending, and the next command collides with it.
The single-block path is kept rather than folded in, since a one-block
CMD18 is legal but pointless and CMD17 is what identification and every
existing check already exercise.
.PP
The check stamps each of the four blocks with its own index, so a
transfer that streams the right bytes to the wrong offsets \- which is
how a wrong block count or a missing auto-stop actually fails \- reads
back as a misalignment rather than as plausible data.
.CW SDHCI-MULTIBLOCK-OK ,
matching the one
.CW sdhostbcm.c
has had all along.  Dropping
.CW Tmmultiblock
and
.CW Tmautocmd12
makes the write fail outright, which is how the new path was confirmed
to be the one being taken.
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
Phase 7: watchdog, RNG, PWM -- DONE
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
.B "Which channel, and why it is not channel 0."
This drove channel 0, on the reasoning that channel 0 always exists.
It does exist and it is not ours.  The sixteen channels are shared with
the VideoCore, which keeps some of them, and which ones is a firmware
decision rather than a property of the SoC; the only way to know is to
ask, tag 0x00060001.  The firmware's answer on this machine is
.CW 0x3c
\- channels 2 to 5 \- and channel 0 is not in it.
.PP
QEMU runs every channel regardless, so channel 0 worked here and would
have shared an engine with the firmware on the board, where the loser
gets a corrupted transfer and nothing reports an error.  This is the
same shape as the SDHCI base clock and the UART clock before it: the
model is more permissive than the part, the firmware is telling the
truth, and the driver was not listening.  It listens now, taking the
lowest offered channel below 7 \- 7 and up are cut-down engines on this
SoC \- and declining outright if the firmware will not say, because
falling back means picking somebody else's channel, which is the bug.
.PP
Unlike the SD base clock this one needed no patched model to test.  The
firmware already answers 0x3c, so the change is visible on an ordinary
boot:
.CW "dma: channel 2 at 0x3f007200 copied 256 bytes by control block (firmware offers 0x3c)" .
.B qemu
evidence, not
.B qemu+patch ,
and the marker now says what it means \-
.CW "DMA-OK control block fetched on a channel the firmware gave us" .
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
.B "And then the check broke a third time, on its own assumptions."
Once the console ran at a real 115200 the sampling loop stopped being
prompt: an interval meant to be 3ms stretched to 14.8ms, crossed the
10ms countdown period, and
.CW "(v[i-1] + period - v[i]) % period"
folded the whole extra period away.  A healthy timer was reported as
having fallen 9580 where 29418 was expected \- a third of its rate \-
and only sometimes, which is worse than always.
.PP
The fault was one sampling scheme being asked two questions.  Covering
more than one period is what exercises a wrap; keeping every interval
under a period is what makes the subtraction mean anything; and those
two pull against each other with only a few milliseconds between them.
The balance held exactly as long as nothing delayed the loop.
.PP
They are separate measurements now, each at a rate that makes its own
answer unambiguous.  The rate check runs the countdown at 4Hz, a 250ms
period, so the entire 25ms sampling window fits inside one period and
no interval can span a wrap at all \- and it asserts that rather than
assuming it, reporting
.CW ARMTIMER-NONE ,
"nothing was measured", for an interval that reaches a period.  A
measurement that could not be made and a timer that failed are
different claims, and only one of them is about the hardware.
.PP
The wrap check runs at 50Hz and counts reloads over 400ms.  The first
attempt at it read the counter just after the value rose and required
the reading to be near LOAD, which was flaky for exactly the same
reason as the bug it was added beside: an interrupt landed between the
reload and the read in one run of three, and the counter had already
fallen to 11478 of 19841.  A count over a window assumes nothing about
its own scheduling, and tests more than the single reading did \- a
parked counter gives zero and a wrong rate gives the wrong number, so
one measurement answers both.  Five consecutive boots:
.CW "reloaded 20 times in 400000 us, 20 expected" ,
every time.
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
.B "And its interrupt, which is the third bank."
Saying a timer is "a good one for periodic interrupts" and then never
delivering one is the kind of claim this document is supposed not to
make, so
.CW armtmrintrcheck()
now programs it at 100Hz with
.CW Cinten
set and counts what arrives.
.PP
Nothing arrived at first, and the registers said why:
.CW RAWIRQ
and
.CW MSKIRQ
both 1, so the timer was asserting;
.CW IRQ_PENDING_BASIC
bit 0 set and
.CW IRQ_ENABLE_BASIC
bit 0 set, so the controller had it pending and enabled.  Pending,
enabled, and dispatched by nobody \- the same shape as the PL011 fault
in the console chapter, one bank over.  The BCM2835 controller has
three pending registers, not two: the ARM basic bank at offset 0, and
the two GPU banks at 4 and 8.
.CW trap()
now reads all three, and the ARM timer's interrupt is IRQ 64.
.PP
The basic bank needs a mask the GPU banks do not.  Only bits 0..7 of
.CW IRQ_PENDING_BASIC
are sources; bits 8 and 9 say merely "something is pending in bank 1 /
bank 2", and bits 10..20 are duplicate copies of eleven selected GPU
IRQs \- 57, the PL011, among them.  Dispatching on those would run a
handler twice for one interrupt.
.PP
The check also has to run in the right place.  It cannot live in
.CW armtmrinit()
with the counter tests: every device init on this board runs before
.CW init0()
calls
.CW spllo() ,
and a counter in
.CW trap()
reads zero entries there \- the CPU is not taking interrupts at all
yet.  A test for interrupt delivery run with interrupts masked reports
"delivers nothing" whatever the hardware does, which fails for the
wrong reason as surely as the counter test could have passed for one.
So it runs from
.CW init0() ,
after
.CW chandevinit() ,
and reports
.CW ARMTIMER-INTR-OK
with 19 interrupts counted in 200019us at 100Hz, twice running.
.PP
The window is 200ms rather than the 50ms it takes to prove delivery,
because a test that only proves delivery is weaker than the counter
checks beside it and this chapter presents them as equals.  At 50ms the
expected count is 5, a single missed edge is a fifth of it, and the
tolerance needed to absorb that would pass a timer running at half or
double the programmed rate.  At 200ms it is about 20, one edge is 5%,
and the bound can be a quarter \- the same as the counter checks.  It
costs 150ms of boot.
.PP
.CW intrenable()
now panics above the basic bank rather than accepting a number nothing
can deliver, and
.CW GicIRQMax
is 72 \- the real end of this controller's number space \- rather than
the 96 inherited from the
.CW "-M virt"
board this file was adapted from, where it left room for virtio slots
that raspi3b does not have.  IRQ 33 was accepted for the console, armed
in a register nobody read, and cost a long time to find; the next wrong
number is loud.
.PP
One more quiet refusal came out with it.
.CW gicenable()
skipped IRQ 30 as "the generic timer, enabled by clock.c".  That is
virt-board legacy too:
.CW clock.c
drives the generic timer through
.CW timerie()
and never calls
.CW intrenable()
at all, while 30 is an ordinary GPU source on this controller.  The
special case did nothing but silently refuse to enable one real IRQ \-
the same failure as the other two, and it had not bitten yet only
because nothing on the board has claimed 30.
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
.PP
.B "The secondary memory interface"
.CW ( smibcm.c ,
0x3f600000, and
.CW tools/qemu-patches/0014 )
was recorded in this document as unmodelable, on the grounds that its
register semantics were not public in enough detail.  That was true of
what was to hand and not of what exists: the Raspberry Pi kernel's
.CW include/linux/broadcom/bcm2835_smi.h
documents what every bit does rather than merely naming it, which is a
higher standard than several blocks in this series were built from.
Upstream Linux has no driver, which is what made it look undocumented.
.PP
SMI drives a parallel bus off the SoC on GPIO 0-25 in alt1 \- address,
data and strobes \- and is how a Pi talks to an FPGA, a parallel LCD
controller or a camera sensor.  It has two register sets for two jobs:
direct mode asserts one address and one word, for registers on the far
side, and programmed mode moves a length through a FIFO, for bulk.
.PP
It is the only peripheral on this SoC whose
.I timing
is programmable the way a memory controller's is.  A word takes setup +
strobe + hold + pace cycles of the SMI clock, all set per device, and
there are four independent device banks so one bus can carry
peripherals that need different timing.  Getting that arithmetic wrong
gives a bus running at the wrong speed rather than an error, which on a
board means marginal signals rather than a visible failure.
.PP
Three things this block gets a driver wrong are written into the file.
DONE means different things in each direction: for a write it is set
when the last word has gone, and for a read not until the FIFO has been
emptied as well, so a driver that waits on DONE and only then starts
reading waits forever.  SMIFD's two counters are six bits, so they
saturate at 63 and cannot express a full 64-word FIFO, and a driver
that drains exactly FCNT words leaves one behind.  And SMICS must not
be read-modify-written, for the reason
.CW i2sbcm.c
learnt the hard way.
.PP
There is no device on the far side of the pins and there cannot be one:
QEMU has no abstraction for a parallel memory-mapped peripheral, so
unlike the AUX SPI this cannot borrow a model somebody else wrote.
That puts it at the same tier as the PWM \- registers, FIFO discipline
and error reporting modelled, nothing reaching a pin.
.PP
So the check leans on the one thing that can be measured
independently.  The exercise programs 32 setup, 64 strobe and 32 hold
cycles at 1.28MHz, which is 128 cycles a word and so 10000 words a
second, and times a 64-word programmed read against the 1MHz system
timer: 6441 microseconds against 6400 expected.  That is what gives the
device settings registers an observable consequence instead of leaving
them as storage.  The FIFO depth is measured rather than assumed \- it
fills until TXD clears and reports 64 \- because a test built on a
remembered constant passes for the wrong reason on the day the constant
is wrong, and both error paths are exercised: AFERR by over- and
under-running the FIFO, and SETERR by writing a settings register
during a transfer, which needs neither a FIFO nor a device.
.PP
.B "The SPI/BSC slave"
.CW ( bscslbcm.c ,
0x3f214000, and
.CW tools/qemu-patches/0015 )
is the one peripheral here that makes the Pi the
.I slave :
another chip on the I2C bus addresses it and the Pi answers.  It is how
a Pi is made to look like a peripheral to a microcontroller, and how
the VideoCore boots a host.
.PP
This document twice gave a wrong reason for leaving it alone.  Neither
survived contact with the sources.  It does not need an external
master, because the Pi has its own and QEMU models it; and its register
semantics are not unavailable, because the datasheet's section 11
specifies every bit of CR, FR, RSR, DR, IFLS and IMSC.  Linux having no
driver \- neither upstream nor in the Raspberry Pi tree \- is what made
it look undocumented.
.PP
It is modelled as an I2C slave on BSC0's bus, which is the master the
ARM can reach, so
.CW bscslbcm.c
drives both ends of every transfer.  On a board that is a jumper
between GPIO 0/1 and 18/19.  What makes this worth more than a
loopback is that the master is
.CW hw/i2c/bcm2835_i2c.c ,
which is not part of this series and was not touched to make it work:
a byte that arrives at the slave has been through code this port did
not write.
.PP
Four things a driver gets wrong are written into the file, and three
are peculiar to this block.  RSR's two error bits are cleared by
writing
.I zero
to them \- every other error bit on this SoC, the PWM's and the I2S's
and the SMI's and the AUX SPI's, is write-one-to-clear, so the usual
idiom leaves the error set forever while appearing to clear it.  The
exercise checks that both ways round: writing the bit back must
.I not
clear it.  A disabled block does not answer its address at all, so a
master sees no device rather than a broken one, and that is checked
before the block is enabled so a later success cannot be mistaken for a
block that answers regardless.  Transmission and reception are
separately enabled.  And DR carries the FIFO levels, the busy flags and
both error bits alongside the data byte, while FR reports the same
flags at different bit positions.
.PP
The exercise moves four bytes each way through the Pi's own master,
underruns the transmit FIFO by reading it empty, overruns the receive
FIFO from the master side, and measures the receive FIFO at 16 deep
rather than assuming a number the datasheet does not give.
.NH 1
What stays unmodelled, and why
.PP
The remaining
.CW create_unimp
blocks in QEMU's Pi peripherals are not a to-do list.  What is left is
short, because everything else that was on it turned out to be there
for a bad reason.  Three blocks were written up here as unmodelable \-
the PWM because nothing wanted it, the BSC slave because it needed a
master that did not exist, SMI because its registers were not
documented \- and all three verdicts fell the moment somebody went and
looked: at QEMU's own I2C models, at the Raspberry Pi kernel's headers,
at the datasheet itself.  The pattern is worth naming, because it cost
this document four wrong entries: "not documented" nearly always meant
"not documented in what was already open".
.PP
.B "TXP, DBUS, AVE0, V3D and SDRAMC"
are internal to the SoC.  They are either undocumented, driven only by
the VideoCore firmware, or \- in V3D's case \- a GPU, which is out of
scope for this port by the same decision that leaves out OpenGL below.
.NH 1
Timed checks must not assume a bound on their own scheduling
.PP
Three checks in this suite time a piece of hardware against the system
timer, and a real 115200 console broke two of them within a day of
each other.  The fault is the same in both and it is worth stating once
rather than three times.
.PP
What such a check wants to measure is how long the block took.  What it
can observe is how long the kernel took to get back \- and everything
that can come between those two, an interrupt, a preemption, a console
drain, only ever makes the second larger.  The error is one-sided.  A
check that compares a single observation against an expected value with
a symmetric tolerance is therefore not measuring the hardware; it is
measuring the hardware plus whatever the kernel happened to be doing,
and it fails in one direction only, intermittently, blaming the
hardware.
.PP
Two answers, depending on the shape of the measurement:
.IP \(bu
.B "Count events over a window."
The ARM timer's wrap check counts reloads over 400ms and the interrupt
check counts interrupts over 200ms.  A delay inside the window costs
nothing as long as the window is long compared to it, and no assumption
about scheduling is needed at all.  This is the stronger answer where
the thing being tested happens repeatedly.
.IP \(bu
.B "Take the best of several."
The SMI programmed read and both I2S FIFO timings are single events
that cannot be counted, so each is run five times and the minimum is
used.  Since delay is one-sided, the minimum is the closest estimate of
the hardware's own time available from here.
.PP
The second is not merely more stable, it is more accurate, and the
numbers say so.  The I2S TX drain read 1363us against 1333 expected as
a single attempt \- 2.3% over, which is scheduling and not the block.
Best of five reads 1335 to 1337 across six boots, 0.15 to 0.30% over.
The measurement got better, not just quieter.
.PP
The ARM timer's rate check adds one more thing worth copying: it
asserts the precondition its arithmetic needs, and when the
precondition fails it reports
.CW ARMTIMER-NONE ,
"nothing was measured", rather than a verdict.  A measurement that
could not be made and a device that failed are different claims, and a
suite that cannot say the first will eventually say the second about
working hardware.
.NH 1
The kfs check reamed the whole card, and boot time said so
.PP
.CW sdfs()
gives
.CW "kfs -r"
a device and kfs writes every block of it.  It was given
.CW /dev/sdM0/data ,
which is the whole card, so the cost of this one check was proportional
to whatever card was fitted.  On the 16MB test image that is about a
second and invisible.  It stopped being invisible when a 4GB image was
brought in to reach the CSD v2 decode: boot went from 44 seconds to 418.
.PP
The 4GB card only made it measurable.  The problem was already there,
and it is worse on the board than in the emulator, because a real Pi's
card is larger than either test image and this ran at every boot.  It
also destroyed the entire card each time rather than a corner of it,
which is a great deal to ask of a machine whose card might have
something on it.
.PP
So the check now makes its own partition \-
.CW "part fs 256 8448"
through the ctl file, 4MB from sector 256, clear of every block the
controller checks use \- and reams that.  Boot to the last marker is
31.5 seconds with the 16MB card and 31.5 seconds with the 4GB one: the
same, which is the property that was missing, and faster than the 44
seconds the small card used to take.
.PP
This is worth writing down as more than a fix.  The 4GB card was added
to cover a decode branch and it exposed something else entirely, in a
part of the boot nobody was looking at, because it changed a quantity
the check had silently made itself proportional to.  Varying an input
that ought not to matter is how you find out whether it does.
.NH 1
What DISK-NONE means, since it has been misread
.PP
.CW DISK-NONE
is not a failure and is not the kfs bug below.  It is
.CW raspi3binit.b
saying no USB mass storage appeared under
.CW /chan ,
which is the correct result when no stick was attached.  Attach one and
the marker changes:
.CW DOS-FAIL
if the image has no filesystem on it, and
.CW DISK-BLK ,
.CW DISK-DOS ,
.CW DISK-READ ,
.CW DISK-WRITE
if it has.  All four pass \- but not against the same image, and the
difference is the point.
.PP
.B "Which filesystem, and why it decides the fourth marker."
QEMU's vvfat
.CW ( file=fat:rw:<directory> )
presents a host directory as a FAT16 volume with no host tool at all.
It is the convenient one, and it reads only: it gives
.CW DISK-BLK-OK ,
.CW DISK-DOS-OK
and
.CW DISK-READ-OK ,
then
.CW DISK-WRITE-FAIL .
This chapter recorded that as expected and moved on, which was one
step short.  The failure is worth reading: it is at the
.I reopen ,
"no such fid", with the create and the write both having returned
success.  That is the shape of a write that went nowhere, not of one
that was refused, and it says nothing about the guest.
.PP
Against a real FAT16 image the same check reports
.CW DISK-WRITE-OK ,
and the evidence is outside the emulator: detaching the image
afterwards and mounting it on the host shows
.CW PI.TXT ,
29 bytes,
.CW "written by inferno on the pi" .
The guest's bytes on a filesystem something else reads back
independently \- dossrv, SCSI WRITE(10), the bulk endpoints and the
DWC2 driver, all of it.
.PP
This document also had the host tooling wrong.  It said macOS could
not make such an image, because
.CW newfs_msdos
on a plain file fails with "Cannot get partition offset".  It can: the
file needs a device node first, which
.CW "hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage"
gives it, and then
.CW newfs_msdos
and
.CW mount
work normally.
.CW tools/qemu-patches/README
carries the sequence.  The claim was not that the tool was missing but
that the file could not be formatted, and that was simply untrue.
.PP
One wart is visible in that host listing:
.CW PI.TXT
is dated 2097.  The Pi has no RTC, the kernel's clock starts at the
epoch, and FAT counts from 1980, so a 1970 timestamp has nowhere to
go.  It is cosmetic, it is in shared dossrv rather than in this board,
and it is left alone.
.NH 1
The kfs create failure was the console, and the create always worked
.PP
There is no kfs create bug.  There never was one.  The create succeeds,
.CW sdfs()
runs to its end, and
.I init
carries on and starts the shell.  What failed was the console: every
byte written to it after a certain point was queued and never emitted,
so
.CW SD-FS-CREATE-OK
was produced and never seen, and a working board looked like a wedged
one.
.PP
.B "How it was found."
Not by pursuing the saved Dis state, which was the recorded next step.
The one hard fact was that the created FD reached refcount zero, and a
refcount reaches zero in only a few ways, which
.CW freeFD 's
own
.CW swept
argument tells apart without needing
.CW destroy() 's
caller pc \- a value this tree had already recorded as untrustworthy.
Every FD in the whole boot came back
.CW "swept 0" :
never the collector, always an ordinary
.CW destroy() .
.PP
That killed the garbage-collector hypothesis, and printing the running
module and PC at each free killed the rest.  The two frees blamed on the
create both landed at Init instruction 1064, and
.CW raspi3binit.sbl
maps 1063 and 1064 to
.I "line 458" \-
the
.CW sdfs()
call site itself, not anything inside it.  So those frees were
.CW sdfs()
returning normally and its frame being torn down, which is correct
behaviour and not a bug at all.  Instruction 1065 is line 460, and the
trace showed the
.CW Readdir ,
.CW Env ,
.CW Sh
and
.CW Echo
modules running after it: the shell had loaded and run.
.PP
.B "The actual bug."
Console output goes through
.CW serialoq ,
which the uart drains from its kick routine.  But
.CW qbwrite()
calls a queue's kick only when it is waking a starving reader or when
.CW Qkick
is set on the queue, and
.CW Qkick
appears exactly once in
.CW os/inferno/port/qio.c \-
in that test.  Nothing ever set it.  Nothing reads
.CW serialoq
either, since the uart drains it from the kick.  So console output
moved only by coincidence, and a workload that stopped producing those
coincidences lost every byte from that point on.
.PP
Measured directly: with
.CW sdfs()
running,
.CW qlen
on the console queue climbs monotonically to 1121 and is never once
observed to fall.
.CW RASPI3B-SH-OK
reaches the console driver \- the string is there, with the queue only
1121 bytes deep, nowhere near its 8K limit \- and is never emitted.  On
an ordinary boot the queue peaks at 33 and drains, which is why this
was only ever seen under kfs.
.PP
.CW portdat.h
documents the fix in its own comment on the flag:
.CW Qkick ,
"always call the kick routine after qwrite", and the same line says it
can be set in
.CW qopen .
.CW devuart.c
opened the output queue with flags of 0.  With
.CW Qkick
the queue drains and both
.CW SD-FS-CREATE-OK
and
.CW RASPI3B-SH-OK
appear, on stock QEMU as well as the patched build.
.PP
The queue depths, since three drivers are described in this chapter
and each has its own:
.IP \(bu
Broken, no
.CW Qkick :
climbs monotonically to 1121 and is never once observed to fall.
.IP \(bu
.CW Qkick ,
fill loop unbounded at 128: peaks at 79.
.IP \(bu
.CW Qkick
plus a fill loop capped at 16 \- peaks at 337.  Higher, and expected to
be: each kick now moves 16 bytes and hands the remainder to the
interrupt rather than emptying the queue in one call, so more of the
output is in flight at any moment.  It is bounded and it drains, which
is the property that matters; 337 is a twentieth of the 8K queue.
.PP
These three were measured when the 16-byte cap was in the driver,
standing in for a TXFF the model never asserted.  It is in the model
now and the cap is gone \- see below \- so the third case is the
shipping one only in the sense that the depth is still 16; it is
imposed by
.CW hw/char/pl011.c
rather than by a loop bound.
.PP
All three figures are measured with the
.CW track: ,
.CW devprog:
and
.CW newa:
instrumentation left in
.CW libinterp
by earlier work still present, and that instrumentation is the dominant
console load on every boot \- see the note at the end of this chapter.
Anyone who removes it will measure lower numbers than these.
.PP
.B "The transmit interrupt, and why claiming it worked was wrong."
.CW Qkick
starts a burst; it cannot finish one.  On a board the TX FIFO fills
after 16 bytes, the kick returns with the rest still queued, and only a
transmit interrupt comes back for the remainder.  So the interrupt is
not defence in depth here \- it is required, and
.CW Qkick
alone is not sufficient on hardware.
.PP
This chapter first claimed the handler "restarts transmission".  That
was written from reasoning, not measurement, and it was false.  A
counter in
.CW uartintr
showed the handler was never entered
.I once \-
not for transmit, and not for receive either.  Two independent faults:
.IP \(bu
.CW trap()
read only
.CW IRQ_PENDING1
and looped
.CW "irq < 32" .
The BCM2835 controller carries 64 GPU sources across two pending
registers, and
.CW gicenable()
already wrote whichever ENABLE register a source belonged to \- so
everything from 32 up was armed in the controller and dispatched by
nobody.  Half the interrupt controller was missing.
.IP \(bu
The PL011 was registered at IRQ 33.  It is GPU IRQ 57
.CW ( INTERRUPT_UART0
in QEMU's own
.CW raspi_platform.h ).
Wrong number, in the bank that was never read.
.PP
Both are fixed:
.CW trap()
walks both banks, and the uart registers 57.
.PP
.B "Getting evidence out of an emulator that could not supply it."
QEMU's PL011 modelled no TX FIFO at all \-
.CW PL011_FLAG_TXFF
is assigned in exactly one place in
.CW hw/char/pl011.c ,
where it is
.I cleared \-
and every write went out synchronously under an
.CW XXX
admitting the design blocks the thread.  So the FIFO never filled, an
unbounded fill loop always emptied the queue in one call, TXIM was
never left armed, and the continuation path could not be exercised
however correct it was.
.PP
Patching
.CW pl011.c
to model a real FIFO was rejected twice, on this reasoning: TXFF can
only assert if the drain is paced against a clock, which changes
console timing for every PL011 board in QEMU and risks the qtest suite,
to fix a fidelity gap in a shared core device rather than to add a
missing peripheral.  Every clause of that is true.  The conclusion is
still wrong, and it is worth saying exactly how, because the error is
not in any of the steps.  It is in an assumption none of them state:
that the new behaviour has to be unconditional.  Make it a property
that defaults to the old behaviour and no board but this one moves \-
which is how
.CW capareg
and
.CW sd-spec-version
were already being set for this machine, two devices over in the same
file.  A sound argument on a frame that was never examined.
.PP
So patch 0018 adds
.CW tx-fifo-depth
and
.CW tx-drain-bps ,
and
.CW bcm2835_peripherals.c
asks for the 16x8 transmit FIFO the datasheet gives UART0, drained a
character at a time by a timer.  FR.TXFF now asserts, so the driver's
fill loop stops on TXFF and nothing else \- the loop that runs on the
board.  The
.CW Fifodepth
cap that used to stand in for it is gone.
.PP
The drain rate is not a claim about serial timing and the patch says
so.  A guest that only ever writes UARTDR never programs IBRD or FBRD,
so
.CW pl011_get_baudrate()
returns 0 and the model has no rate to pace against; the board must
name one.  3 Mbaud is the fastest this part can be set to \- its 48 MHz
reference over the minimum divisor of 16 \- so it is the cheapest rate
in console throughput that the hardware could really run at.
.CW tx-drain-bps
has no default, and
.CW realize()
refuses a depth without one, because a rate invented inside the device
would be a number nobody could trace back to anything.
.PP
.B "What the model buys that the driver-side cap could not."
Deleting the transmit-interrupt continuation from
.CW uartintr
now stops the console dead part-way through a line: 51 lines of 99,
truncated mid-word at
.CW "ARMTIMER-INTR-OK interrupt arrives at the programm" .
That is the failure a board would show, produced on demand.  Against
the unpatched model the same deletion changes nothing whatever, which
is the entire reason the cap existed.  The marker sequence with the
FIFO in place is identical to the sequence without it, and no
.CW LOG_GUEST_ERROR
appears \- the driver never writes a full FIFO.  Cost, boot to the last
self-test marker: 15.6 s before, 17.7 s after.
.PP
It also caught three live bugs, none of them in QEMU.
.PP
.B "One: the polled path wrote blind."
.CW virtarm64_putc() ,
the path
.CW panic()
and
.CW iprint()
use, wrote UARTDR and then spun a fixed count, with a comment blaming
unreliable FR flags.  The flags were not unreliable; TXFF simply could
never assert.  On a Pi that write is a dropped character in exactly the
situation where the output matters most.  It now waits for room,
bounded so a dead UART cannot hang a panic.
.PP
.B "Two: the wait was compiled away."
.CW Ctlr.base
was a plain
.CW u32* .
A loop that polls FR and does nothing else lets the compiler hoist the
load out and spin on a register, so the new wait did nothing whatever.
.CW virtarm64_kick()
had never shown this because its loop also stores to UARTDR through the
same pointer, which blocks the optimisation.  The word is
.CW volatile
now.  This is the failure mode the marker suite exists to catch: the
check said
.CW UART-PUTC-NONE ,
"the transmit FIFO never filled; nothing here was tested", rather than
passing.
.PP
.B "Three: the baud rate was never programmed, and the model lied about the clock."
.CW virtarm64_baud()
was a stub returning 0.  The divisors were never written, so the part
ran at whatever the firmware left \- right by luck on a Pi, and wrong
in principle, since
.CW uart->baud
then reports a rate nothing programmed.
.CW Uart.freq
held 24 MHz, the
.CW "-M virt"
apb-pclk copied in with the driver, which is not this part's clock on
any Pi.
.PP
UARTCLK cannot be hardcoded: it is not a property of the part, it
differs between Pi models, and the only way to learn it is to ask the
firmware.  So
.CW virtarm64_enable()
now asks \- mailbox tag 0x00030002, clock id 2 \- and
.CW virtarm64_baud()
computes IBRD/FBRD as UARTCLK/(16*baud) and writes them before LCR_H,
which is what latches them.
.PP
Doing that correctly produced a boot that took 32 s instead of 18, and
.CW pl011_baudrate_change
named the reason: the firmware was answering 3000000, the constant
.CW RPI_FIRMWARE_UART_CLK_RATE
in
.CW include/hw/arm/raspi_platform.h ,
while the CPRMAN clock actually wired to the PL011 in
.CW bcm2835_peripherals.c
runs at 47999625 Hz.  Two parts of the same model, sixteen apart.  A
guest asking for 115200 got 1846136, and nothing in the guest could
detect it.  Patch 0019 wires the real clock into the property device
and reports it; the guest then programs IBRD 26, FBRD 3, and the model
runs 115176.
.PP
That finding is worth more than the patch.  It exists only because 0018
gave the console a measurable drain rate: with write-through
transmission a sixteen-fold baud error has no observable consequence at
all.  Accuracy compounds \- the first correction is what made the
second one visible \- and the class of divergence is one this audit had
no category for.  Nothing was lenient and nothing was missing; the
model simply told the guest something untrue about itself, and punished
the guest for believing it.
.PP
.B "What the polled path is now known to do."
.CW uartputccheck() ,
called from
.CW init0() ,
writes eight numbered 48-character lines a character at a time through
.CW virtarm64_putc()
and reports what the wait had to do.  On a boot with the SD image and
USB disk attached:
.CW "UART-PUTC-OK polled writes waited for FIFO room 400 times, worst wait 35726 iterations of 1000000" .
Every one of the 400 characters met a full FIFO, all eight lines
arrive complete, and the worst wait is a twenty-eighth of the bound \-
so the bound protects a dead UART without truncating a live one.  The
numbering in the lines is what makes a short arrival visible.
.PP
The cost of all of this is a console that runs at the rate a console
runs at.  Boot to the last self-test marker: 15.6 s with the model
transmitting write-through, 17.7 s with the FIFO at 3 Mbaud, 45.0 s at
a correctly programmed 115200.  The last figure is what the board does.
The marker sequence is unchanged across all three except for
.CW UART-PUTC
itself, and QEMU logs no guest error, so the driver never writes a full
FIFO.
.PP
Console
.I input
was never affected:
.CW clockpoll()
in
.CW clock.c
polls
.CW getc
from the clock tick, which is why typing worked all along with the
interrupt dead.  It still works.
.PP
.B "What this says about the old diagnosis."
The chapter this replaces was careful, and its measurements were sound:
the Styx does complete, the fgrp does not diverge, the frame does not
move, and the
.CW mount (2)
double-close it found on the way was a real bug and is really fixed.
What it lacked was a reason to doubt that the absence of a marker meant
the absence of the work.  It had even recorded the mechanism \- that
.CW print()
queues and can be swallowed, which is why
.CW iprint
was used for the tracing \- without applying it to the marker whose
absence defined the bug.  A missing marker is evidence about the
console until the console is ruled out.
.PP
.CW sdfs()
is now called on every boot rather than commented out, and
.CW SD-FS-CREATE-OK
is part of the regression.
.PP
.B "Not fixed here: the interpreter's tracking instrumentation."
Earlier debugging left a live object-tracking facility in
.CW libinterp/heap.c ,
and
.CW xec.c
calls
.CW checktracked()
from the interpreter's inner loop \- at
.CW xec.c:2431 ,
with the checkpoint name "instr", once per Dis instruction.  It prints
.CW track: ,
.CW devprog:
and
.CW newa:
lines throughout every boot and is the largest single source of console
traffic on this board.
.PP
It is left alone deliberately.  It is in
.CW libinterp ,
which every platform in the tree shares, not in
.CW os/inferno/raspi3b ,
so gating or removing it is a change to every port at once and belongs
to whoever owns that decision \- its own comment says "pc64-only,
temporary".  It is recorded here because it distorts every console
measurement above, and because a per-instruction check in the
interpreter's hot path is a performance question as much as a noise
one.
.PP
.B "But it is reporting something here, and not the shape it explains."
The first instinct on finding this much noise is to gate it off.  That
would have been wrong, because on this board it fires twice a boot and
the hits do not match what its author characterised as benign.
.PP
The comment in
.CW checktracked()
describes the expected false positive exactly: checkpoint
.CW instr ,
.CW R.d
equal to the watched address so the op wrote it itself, old value
.CW H ,
new value 0, and the object being the current frame \- the signature
of a frame word conservatively marked as a pointer in its type's map
while actually holding a non-pointer local.  Its test for benign is
given too: "if the system still reaches a working shell after a hit,
the write was benign."
.PP
On raspi3b both hits pass that test \-
.CW RASPI3B-SH-OK
follows them \- and match none of that signature.  The checkpoint is
.CW readmod:after-parsemod ,
not
.CW instr ;
.CW R.d
is 0x3939f40 and the watched addresses are 0x3b67620 and 0x3b675f0, so
by the comment's own reasoning the write happened deeper in the call
tree and the reported op is only the enclosing dispatch; the object at
0x3b675b0 is not the
.I current
frame, which is at 0x3939ef0; and while one word went from
.CW H
to 0, the other went from 0x3adb7f0 \- a live heap pointer \- to 0.
.PP
What the checkpoint does
.I not
say is where the write happened.  A hit drops its own watch
.CW ( "track[i].addr = nil" ,
the last line of the reporting block), so an earlier checkpoint that
stayed quiet proves nothing unless the watch already existed when it
ran.  These watches are created when the object is, which is inside
the same stretch being bracketed.  The window is therefore that whole
call and nothing narrower, and the comparison with the pc64 finding \-
whose
.CW before-parsemod
ruled parsemod out for a different slot \- does not carry over.
.PP
That is not a claim that there is a bug.  It is a claim that these two
hits are unexplained by the analysis that made the noise acceptable,
and that silencing the instrumentation would have thrown the report
away rather than answered it.  Whoever owns the pc64 tracker should
see this; it is why the recommendation here is to leave it running and
not to gate it.
.PP
.B "One hypothesis, eliminated."
The obvious benign explanation is that the object is a module's data
segment.
.CW load.c
allocates
.CW origmp
with
.CW dtype() ,
which sets its pointer words to
.CW H
and so registers exactly these watches, and then the DEFF/DEFS/DEFA
writes fill it from the module file's data section \- which encodes
literal zeroes for pointer fields that the module's own
.CW init
assigns later.  That would make a watched pointer word going to 0
correct by construction, and it would explain the checkpoint too,
since the fill happens inside
.CW parsemod() .
.PP
It is not that.  Printing
.CW m->origmp
and its size at every allocation gives, in order and both before the
hits, 0x3acc270 of 112 bytes and 0x3adbcf0 of 408.  The flagged object
is at 0x3b675b0 and is 144 bytes: no data segment allocated up to that
point is either.
.PP
So that explanation is closed.  The registration shape names what the
object is, though, and this part is derivable rather than guessed.
.CW initmemtt()
is passed a
.CW typetagp
by four callers:
.CW heap()
and
.CW heapz()
pass
.CW &h->t ,
which lies in the header
.I before
the data;
.CW heaparray()
passes
.CW &a->t ;
and
.CW xec.c 's
.CW frame
instruction passes
.CW &f->t ,
a field
.I inside
the frame it just allocated.
.CW struct Frame
is
.CW lr ,
.CW fp ,
.CW mr ,
.CW t ,
so on LP64
.CW t
is at offset 0x18 \- exactly the diff reported.
.PP
The flagged object is a Dis call frame, created by the
.CW frame
instruction at
.CW xec.c:711 ,
and it belongs to pid 7 while pid 1 was the process running when the
change was noticed.  That puts it back in the same family as the
benign case the tracker's comment describes \- a frame word
conservatively marked as a pointer in its type's map \- but on a frame
that is not the running one, where a frame whose call has returned and
whose memory has been reused by another frame of the same type would
pass the staleness check unchanged.  That is the next thing to test,
and it needs someone who owns the tracker.
.NH 1
"mk acid" on this board succeeds and produces nothing
.PP
Worth knowing before someone tries to debug this kernel with acid.
.CW "mk acid"
in
.CW os/inferno/raspi3b
exits 0, prints
.CW "srclist: crackhdr: bad ELF class - not 32 bit"
to standard error, and writes a 21-byte
.CW iraspi3b.acid
whose entire contents are
.CW "include (\(dqinferno\(dq);" .
No sources, no symbols, no error status.
.PP
The chain is short.
.CW utils/libmach/executable.c:536
accepts only
.CW ELFCLASS32 ,
so libmach cannot read this board's kernel at all \- and the reader
is there, it is 32-bit only, which makes Elf64 an extension of an
existing path rather than a new one.
.CW srclist
runs on libmach, so it lists nothing; the acid rule loops over nothing
and writes only its trailing include line; and
.CW mk
sees a successful loop over an empty list.
.PP
This board's own
.CW mkfile
defines
.CW "default:V: i$CONF" ,
so an ordinary build never runs the rule and never sees this.  Only an
explicit
.CW "mk acid"
does, which is why it has gone unnoticed.
.PP
It is recorded rather than fixed for the same reason as the tracker:
.CW utils/libmach
is shared by every platform and by the
.CW acid ,
.CW inm
and
.CW srclist
tools, and Elf64 support there is a piece of work with its own
consumers beyond this board.  The part that belongs in this document
is the shape of the failure, which is the one this whole port keeps
meeting: a step that reports success while doing nothing is worse than
one that fails, because nothing downstream can tell the difference.
Kernels here link stripped, so a
.CW "7l -a"
listing regenerated after each build remains the only way to turn a PC
into a symbol on this board.
.NH 1
Where the suite stands
.PP
Three consecutive boots with a 16MB SD image, a FAT16 USB disk and USB
ethernet attached, against QEMU v10.1.3 plus the patches in
.CW tools/qemu-patches :
39 markers, no
.CW -FAIL ,
and QEMU logging no guest error.  26.1, 28.3 and 29.3 seconds to the
last marker.
.PP
This said 38 and no
.CW -NONE
at all, and that was an artifact of the harness rather than a fact
about the board.
.CW USB-MOUSE-NONE
is the correct answer for a machine with no mouse attached, and it
arrives on the line after
.CW RASPI3B-SH-OK
\- line 132 of 132 \- because the mouse check waits out its own timeout
before reporting.  A harness that stops three seconds after the last
marker misses it and one that waits five catches it, which is the whole
difference between the two numbers.  The count is 39.
.PP
.CW "ARMTIMER-INTR-OK ARMTIMER-OK AUX-OK AUXSPI-OK BSCSL-OK DISK-BLK-OK"
.br
.CW "DISK-DOS-OK DISK-READ-OK DISK-WRITE-OK DMA-OK DRAW-OK ETHER-DHCP-OK"
.br
.CW "ETHERBIND-OK I2S-OK MBOX-OK OTP-OK PWM-OK RANDOM-OK RASPI3B-OK"
.br
.CW "RASPI3B-SH-OK RNG-OK SD-CAP-OK SD-FS-CREATE-OK SD-MULTIBLOCK-OK"
.br
.CW "SD-OK SD-WRITE-OK SDHCI-4BIT-OK SDHCI-CAP-OK SDHCI-HISPEED-ACCEPTED"
.br
.CW "SDHCI-MULTIBLOCK-OK SDHCI-OK SDHCI-SPEED-ACCEPTED SDHCI-WRITE-OK"
.br
.CW "SMI-OK SYSTMR-OK THERM-OK UART-PUTC-OK USB-OK"
.PP
The two
.CW ACCEPTED
markers are the ones that must stay
.CW ACCEPTED :
both are SD clock rates, and nothing in the model times a transfer
against SDCLK, so the sequence is verified and the physical change is
not.  That distinction is the whole reason the word exists, and a boot
where either turned into
.CW -OK
without hardware underneath it would be a lie.
.PP
That baseline is one configuration, and it used to leave two branches
of
.CW sdhcibcm.c
to boots someone did by hand and remembered to do.  Both are covered
now, and neither by a hand-edit.
.PP
.CW SDHCI-SPEED
said
.CW "base 52MHz from capabilities" ,
so the firmware-clock branch \- the only one hardware takes \- was not
in these runs at all; it was reachable only by editing a constant in a
local QEMU.  That turned out to be the model's fault rather than the
suite's.  A real Arasan does not report a base clock: Linux marks
.CW brcm,bcm2835-sdhci
.CW "missing_caps = true"
and substitutes a table carrying no base clock either.  So
qemu-patches 0026 clears the field, this board now takes the firmware
branch by default \- it reads
.CW "base 50MHz from firmware clock 1 undivided"
\- and the capabilities branch is exercised where it belongs, on the Pi
4's emmc2, which
.CW sdhci-iproc
does
.I not
mark
.CW missing_caps .
Each branch runs on the controller that takes it.
.PP
The
.CW "csd v2"
decode still needs a card bigger than 2GB, which no default run has.
That one is now a configuration rather than a memory:
.CW tools/boardsuite/run
boots four of them \- this board on a 16MB card and on a 4GB card, and
the Pi 4 at both ends of its temperature sensor \- diffs each marker
set against a checked-in baseline, and fails a run whose markers are
right and whose evidence lines are wrong, because
.CW SDHCI-SPEED-ACCEPTED
is the same marker whichever branch produced it.
.PP
One thing that script found on its first day is worth recording here,
because it is the chapter above wearing different clothes.  Run
alongside a QEMU test suite, on a machine with nothing left to give,
.CW ARMTIMER ,
.CW ARMTIMER-INTR
and
.CW SYSTMR
all reported
.CW -FAIL
for a board that was fine, and the same configuration passed alone a
minute later.  Host load only ever costs a timed check events, never
gains it any \- the one-sided error again, arriving one level up, at
the harness rather than inside the check.  So a failing configuration
is booted a second time and a run that passes then says it needed to.
A real regression fails twice; a retry nobody is told about is a suite
that hides a flake, which is worse than a suite that fails.
.PP
It covers the other boards too, and doing that turned up the same shape
of finding the model work kept producing: a check that fails because
nothing ever gave it the device it tests.  The riscv64
.CW virt
board's
.CW blkcheck()
reads sector 0 of
.CW /dev/sdF0/data
and wants the 0x55AA boot signature, and every log of that board in
this tree says
.CW BLK-FAIL .
Attaching a virtio-blk disk with a real FAT filesystem on it turns that
into
.CW BLK-OK ,
and the boot then runs its whole suite rather than stopping short: 4
markers became 32.
.CW virtarm64 's
.CW NET-FAIL
became
.CW NET-OK
the moment a virtio-net was attached.  Neither was a bug in a driver.
Both were a question nobody had asked since the board was written.
.PP
Those boards also fail a good many checks for a reason that is not a
bug either: they reach a shell and then fail everything wanting a
module their root does not carry \- Tk, Draw/Tk, wm, freetype, math,
memfs \- each saying
.CW "file does not exist" .
That is a real state of a board, so the script records it as one: a
configuration may carry a list of markers known to fail, checked as
strictly as the marker set, and a passing run says what it carried \-
.CW "ok 31 markers and 16 known -FAIL" .
A new failure fails the run, and so does one that went away, because a
debt that got paid should be written down.  Reporting a board with
sixteen broken checks as simply
.CW ok
would be a lie of omission, and those lists are debt rather than a
baseline to be comfortable with.
.PP
That script also carries the two harness bugs this document had to
correct, fixed once where they cannot recur: it waits six seconds after
the last marker rather than three, because
.CW USB-MOUSE-NONE
arrives after it, and its marker pattern has no trailing word boundary,
because
.CW SD-FS-CREATE-OK
came out as
.CW SD-FS-CREATE-OKtrack:
in a run where another process printed on the same line, and a
harness that missed it reported a regression in the SD path that had
not happened.
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
rather than as a test.  The answer is not to mount kfs, though: kfs is
the wrong shape for an SD card in two separate ways \(em its recovery
story is a check pass on a board whose way out of
.CW exit()
is the watchdog, and its I/O is 1KB blocks with the free list living
inside the superblock, so every allocation rewrites the same address.
.I Efs ,
planned in
.CW doc/efs-plan.ms ,
is the replacement: a copy-on-write Styx server whose recovery is a
superblock flip and whose commits are batched aligned writes.  Nothing
of it is implemented.
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
The receive readers, on the board, 17 September 2026
.PP
The kernel carrying the
.CW ethermedium.c
change (a failed read no longer ends the IPv4, IPv6 or ARP reader) was
booted on the Pi from a card holding exactly that build.  DHCP gave it
192.168.8.105, on a different network from the earlier runs.  From a
Mac on the same segment, 600 pings at one a second over ten minutes:
600 answered, none lost, 13 milliseconds average.  A connection to a
closed TCP port was refused.  At the end the server's counters read 651
IPv4 frames in and 651 handed to a reader, 74 ARP in and 74 out, and 0
dropped on any conversation.  The console showed no
.CW "ipv4 read:"
or
.CW "giving up"
line.  So no reader failed during this run.  The fix was in the kernel,
but the run does not show an error being survived; it shows the
network staying up for ten minutes.  The bulk IN re-arm fired once in
the visible log
.CW "usbdwc: ep3.1 re-armed after 2 s (1 times)" ), (
and receive carried on after it.
.PP
The board still prints its
.CW NETTX ,
.CW NETICMP
and
.CW TXDUMP
diagnostics every few seconds.  The console scrollback holds about 125
lines, so those lines push the boot markers out of it within a minute.
They should come out of the next build.
.PP
They are opt-in now: the merged init prints them only when the card's
FAT partition holds a file named
.CW netdebug .
.NH 2
One tree for the Pi, 17 September 2026
.PP
The board work above was done on the
.CW osprey-port
branch and the QEMU work in the chapters before it on
.CW raspi3b-port .
The two are merged, on
.CW raspi3b-port .
Where they disagreed, the version that had run on the board was taken.
The card is
.CW sdemmcbcm 's,
on the Arasan controller.
.CW sdhostbcm
and
.CW sdhcibcm
are still in the tree and no longer linked: the first claimed the same
unit letter and does not work from a polled driver on silicon, and the
second drives the same Arasan block as
.CW sdemmcbcm .
The
.CW SDHCI-*
markers and the SDIO transport check go with them, which leaves Phase 6
with no linked SDIO driver.
The console, the interrupt dispatch, the DWC2 driver and init come from
the board side, with this side's peripheral drivers, baud arithmetic,
polled-console check, basic-bank dispatch and USB disk, mouse, tablet
and keyboard checks added back.
.PP
The suite's Pi 3B cards now carry what the board's card carries: a
partition table, and a FAT partition at sector 16384 holding a file
named
.CW kernel8.img .
The init reads that table to find its FAT partition and the gap it may
ream, so a blank card had made it report
.CW FAT-NONE
and skip the kfs check.  With the table,
.CW FAT-OK ,
.CW FAT-WRITE-OK
and
.CW SD-FS-CREATE-OK
run under QEMU, and the multi-block read checks itself against the real
FAT boot sector.  The 4GB card's partition is FAT32, which is the
only place
.CW dossrv 's
FAT32 path runs off the board.  All four Pi 3B configurations pass:
39, 39, 43 and 42 markers.
.NH 2
The IPv4 reader stops after a connection to a live host
.PP
The board can fetch a kernel for itself:
.CW kupdate()
in the init reads
.CW kupdate.txt
from the FAT partition, dials the addresses in it, mounts what answers
and copies the named file over
.CW kernel8.img ,
keeping the old one as
.CW kernel8.bak .
On the Mac the tree is served with
.P1
emu -r $ROOT sh -c "styxlisten -A 'tcp!*!6666' export /; sleep 36000"
.P2
The card's file named a Mac address that no longer existed after the
router change, so every boot until now dialled nothing and only ever
sent ARP.  With the Mac's current address in it, the board rebooted,
dialled, and within its first 80 seconds the IPv4 conversation stopped:
.P1
NETTX conv 0 etype 0x800 in 117 out 32 drop 20 held 8 waiting 0
.P2
Eight frames held, no read outstanding, and the count handed to the
kernel frozen at 32 while ARP went on being answered
.CW "in 171 out 171" ). (
The Mac never saw a connection arrive, the board stopped answering
ping, and a
.CW mount
typed at its shell to the same address never returned.  The same
fetch under QEMU, over the same USB NIC model and a user-mode network
to the same server, completes: 1622552 bytes, installed, and the IPv4
reader still waiting for its next frame afterwards.
.PP
"No read outstanding" means the kernel's
.CW etherread4
is somewhere other than its read.  That process runs the whole input
path under the interface's read lock, and a TCP segment can make it
transmit, which on this board is a write through a mount to a Limbo
server; so it is either blocked in the IP input path or in that write.
Which one is what
.CW "echo procdump >/dev/sysctl"
is for: every process on one line, and the kernel text addresses on
each sleeping process's stack, which a
.CW "7l -a"
listing of the same build turns into names.  The kernel carrying it is
on the card; the next boot of the board answers the question.
.NH 2
Smaller things the board showed on 17 September
.IP \(bu
Characters typed at the console while the board is printing are lost
.CW "cat /n/dosuaex hKRE" ). (
The transmit kick waits for FIFO room with interrupts off, about 87
microseconds a byte, so a burst of output holds off the receive
interrupt for long enough to overrun a 16-byte receive FIFO.  Typing a
character every 50 milliseconds gets through.
.IP \(bu
The first line typed at the shell lost its first word:
.CW "echo x > file"
reported
.CW "sh: x: file does not exist"
and left
.CW file
empty, and the same command a second time worked.  It was not a race.
The init started
.CW mntgen
as
.CW "mg->init(nil, \(dqmntgen\(dq :: \(dq/n\(dq :: nil)" ,
but
.CW mntgen
serves Styx on its standard input and is meant to be run as
.CW "mount {mntgen} /n" .
Called that way it mounted nothing and read the console: it took the
start of the first line as a Styx message, exited on it, and the shell
ran what was left.  Found by printing every exiting process with its
module under QEMU, which showed
.CW mntgen
dying at the moment the line was typed and
.CW echo
never loaded.  The directories it was meant to make are in the
kernel's root already, so the init no longer starts it.  Osprey's init
had the same call, so the board had the same fault.
.IP \(bu
A file
.CW dossrv
wrote on the board carries a date in 2097.  The Pi has no clock, and
nothing yet gives it the time.
.NH 2
The peripheral checks, on the board, 17 September 2026
.PP
The merged kernel booted on the Pi and ran this branch's peripheral
checks on silicon for the first time.  They had only ever run against
QEMU's models, several of them against models in
.CW tools/qemu-patches ,
so this is the first time any of them is
.B hardware
rather than
.B qemu+patch .
.PP
Passing on the board: the hardware RNG
.CW ( RNG-OK ,
two different words), the power-management watchdog
.CW ( WDOG-PRESENT ,
loaded and holding while disarmed), the 1MHz system timer
.CW ( SYSTMR-OK ,
50001 microseconds measured across a 50ms delay and agreeing with the
ARM generic timer), the board identity and customer OTP
.CW ( OTP-OK ,
revision 0x00a02082, serial 6289a97b, no fuses set), and the DMA
controller
.CW ( DMA-OK ,
256 bytes copied by a control block on channel 0, which the firmware's
channel mask 0x7ff5 grants).  DMA had never moved a byte outside the
emulator before.
.PP
Not passing, and each one is the board rather than the driver.
.CW PWM-FAIL :
channel 1 does not transmit when enabled.
.CW THERM-NONE :
no valid reading at 0x3f212000.
.CW "gpio ... pin21 high=1 low=1 (FAIL)" :
the pin reads 1 whichever level is driven, which is what an unloaded
pin with a pull-up does.  The I2C probe reports its DS1338 mismatch,
which is correct for a bus with no clock chip on it.  Those four want a
scope and a part on the header, not a rewrite.
.PP
.B "And one that was not the board: the check stole the console."
After
.CW DMA-OK
the console stopped and the serial line carried
.CW AUXUART-HELLO
in the wrong shape.  Not a crash:
.CW auxuartinit()
routed GPIO 14 and 15 to the mini UART, and on a Pi 3 with
.CW dtoverlay=disable-bt
those are the PL011's pins \(em the console's.  The emulator cannot show
this, because a QEMU console is not attached to pins at all.  Routing
is a separate call now, which the check does not make.  The general
form is worth keeping: a peripheral check that configures pins is
configuring a board, and the board it is configuring here has a console
on two of them.
.NH 2
What the wedge was: a protocol lock held across a file server
.PP
The board's network stopped a few seconds into every boot that talked to
a live host.  It is fixed, and the way it was found is worth as much as
the fix.
.PP
The first instrument was
.CW "echo procdump >/dev/sysctl" :
every process on one line, and the kernel-text words on each sleeping
one's stack, which a
.CW "7l -a"
listing of the same build turns into names.  That named three waiters
\(em the IPv4 reader queueing inside
.CW tcpiput ,
TCP's timer inside
.CW tcptimeout ,
and a writer inside
.CW tcpkick
\(em all on a TCP conversation's
.CW qlock ,
and none of them said who held it: a waiting process records where
.I it
called
.CW qlock ,
which is a different question.  So
.CW QLock
gained an owner and the dump learned to print it.  The next boot said
.CW "qlock 0x3d2da18 held by 18 acquired at 0x0" ,
and process 18 was asleep in a queue wait.
.PP
The holder was in the transmit path.
.CW ethermedium.c
wrote each frame to its device file inline, and
.CW tcpkick()
makes that call with the conversation's
.CW qlock
held.  On a board whose ethernet is a kernel driver that is a queue
insertion; here the device is a file served by a Limbo program, so it is
a 9P round trip, and a round trip that does not come back holds a
protocol lock for good.  Everything behind that lock stopped: 120 frames
arrived, 15 were handed on, 8 sat held, and ARP \(em which does not take
that lock \(em answered throughout, which is exactly why the board looked
half alive and why the earlier reading blamed the driver.
.PP
Each conversation now has an output queue and a process that drains it
into the device, so the protocol hands a frame over and returns.  A full
queue drops the frame and counts it, which is what an ethernet driver
does with a frame it cannot send.  The blocking write still exists \(em it
is just that a driver process waits in it now, not TCP.
.PP
Two things about the board made this take as long as it did, and both
are fixed.  Its console dropped typed characters while it printed,
because the transmit kick waited for FIFO room with interrupts off; and
the console's 125-line scrollback lost every dump.  Copying
.CW /dev/kmesg
to the card's FAT partition and reading it back in 700-byte pieces is
what finally produced a whole process dump.
.PP
One trap to record:
.CW ps
prints Dis process numbers and the kernel's dump prints kernel process
numbers, and they are not the same numbering.  A kill aimed at "18" from
the shell killed the FAT server instead of the lock holder.
.NH 2
Three of the peripheral checks were wrong about the part
.PP
Of the five checks that failed on the board, three were the check and
not the silicon, and each failed the same way: it asserted something
QEMU's model does and the part does not.
.IP \(bu
.CW AUX .
.CW auxuartputc()
spun a fixed iteration count for transmit-FIFO room and
.CW auxinit()
read the transmitter's state the instant after its last byte.  A byte
is 87 microseconds at 115200 and the FIFO is eight deep; QEMU's mini
UART empties inside the register write.  The waits are in microseconds
now, and the final one waits for the transmitter to go idle.
.IP \(bu
.CW I2S .
The check asserted
.CW CS_A
reads zero at reset.  Its top half is status \(em TX FIFO empty, has
room, needs writing, and the two sync bits \(em and an idle block on the
board reports all five (0x2a6000).  It masks to the writable bits now.
.IP \(bu
.CW AUXSPI .
The check asserted
.CW STAT 's
bit count equals the shift length written to
.CW CNTL0 .
The datasheet calls that field the number of bits still to be
processed, so an idle controller reports 0; QEMU's model mirrors
.CW CNTL0 .
It is printed now rather than asserted.
.PP
Two remain, and they are not yet understood well enough to say which
side is wrong:
.CW SMI
probes a FIFO depth and gets 256 with
.CW cs
0x54000001, and the BSC slave check finds that a disabled slave
acknowledges its address.  Both want the datasheet open beside the
part, not another guess.
.PP
The pattern is the one this document has met before, and it is the cost
of a model written alongside the driver that uses it: the emulator
agrees with the code because both came from the same reading.  A check
that passes on
.B qemu+patch
and fails on
.B hardware
is worth more than one that passes on both, because it is the only
place the two readings can be told apart.
.NH 2
The board, with the fix, 17 September 2026
.PP
The Pi boots the merged kernel to an interactive shell, brings up its
LAN9514, takes 192.168.8.105 by DHCP and answers its own ping.  Six
hundred pings at one a second over ten minutes: 600 answered, none
lost.  At the end the ethernet server's counters read 2261 IPv4 frames
in, 8 dropped, none held and a read outstanding; 1546 frames
transmitted with no error; and the interface 2253 in, 1464 out.  The
watchdog that reports a stopped reader printed nothing.  Before the
fix the same board stopped handing frames up within eighty seconds and
never started again.
.PP
SD is right on silicon too, in the same boot:
.CW SD-OK ,
.CW SD-MULTI-OK ,
.CW SD-CAP-OK
against a card that reports 30228480 sectors,
.CW SD-FS-CREATE-OK
for a kfs reamed in the gap below the first partition, and
.CW FAT-OK
and
.CW FAT-WRITE-OK
through dossrv on the boot partition.
.PP
.B "And the board now updates itself."
.CW kupdate()
dialled the Mac's
.CW styxlisten ,
mounted it, fetched
.CW kernel8.img
and installed it over the one on the card, keeping the old one as
.CW kernel8.bak :
.CW "KUPDATE-OK 1627816 bytes installed" .
The card has not had to move since.  That is the practical end of the
bring-up loop this document opened with: a kernel can be built here and
booted there without carrying anything.
.NH 2
The FAT bugs, found in seconds instead of one boot at a time
.PP
Every corruption this card suffered was found by booting the board,
looking at what broke, and swapping the card.
.I Fatstress (1)
and
.CW tests/dossrv-stress.sh
do the same work on the build host: write, read back, rename, rename
onto a name that exists, remove, on FAT16, on FAT32 with 512-byte
clusters and a filler so files land above cluster 65535, and on FAT32
with 4KB clusters \(em and then
.CW "fsck_msdos -n"
over each image.  Reading the files back through the code that wrote
them is not a check on that code: every bug here left an image that
still mounted and still listed.  All three pass, fsck clean.
.PP
It found four more, none of which the board had reached:
.IP \(bu
.CW doremove
followed a long name into the sector before it whenever its backward
walk stopped at offset 0 \(em including when it stopped there because
that entry is live and the chain had already ended.  It deleted the
trailing long-name entries of a different file, which was left with a
live directory entry and no name.  Six files renamed and removed in
turn was enough to show it.
.IP \(bu
The short-alias search in the rename path was given the file being
renamed instead of its parent, so it walked a file as a directory and
panicked.
.IP \(bu
.CW mkdentry 's
error path left a sector held.
.IP \(bu
The free-run search kept its start across a live entry, so a directory
could be extended from one place and written in another.
.PP
The rename-onto-an-existing-name check is back at the top of the
rename, where it refuses before anything is touched, and it asks by the
name given rather than by its 8.3 form \(em a file created as
.CW inferno.txt
has the short alias
.CW INFERN~1TXT ,
so the 8.3 form finds nothing and the check passes over the very file
it exists to find.
.NH 2
Bluetooth: the radio is wired, the board has not answered yet
.PP
The BCM43438 is an H4 controller on the PL011, and nothing it needs is
Bluetooth's doing.  The console has to be elsewhere, which it now is:
the firmware gives the header the mini UART and keeps the PL011 for the
radio, and the kernel reads GPIO 14's function at boot and follows that
rather than assuming.  The UART has to be routed to GPIO 32 and 33 with
flow control on 30 and 31 at alt3.  And the radio has to be powered \(em
BT_ON is not a SoC pin at all but line 0 of an eight-line expander the
VideoCore owns, reached only by a mailbox property call.
.PP
.CW btbcm.c
does the three of them at boot and then sends HCI Reset on the raw
PL011, so the console says whether a controller is answering before any
Limbo starts:
.CW BT-OK ,
.CW BT-FAIL
with what did arrive, or
.CW BT-NONE
where the console has the PL011 and there is no radio, which is every
QEMU boot.  It does not load
.CW BCM4345C0.hcd ;
a cold controller answers Reset and the vendor download commands and
refuses much else, so
.CW BT-OK
means a controller talking and not yet a usable radio.
.PP
.B "It runs on the board."
.CW BT-OK :
HCI Reset sent on the raw PL011 and the Command Complete read back, on
silicon.  Getting there meant giving something up.  This firmware sets
the response word's top bit for the get (0x80000008) and not for either
set (0x18, 0x8), while the get reports BT_ON already at 1 \(em so the
radio is powered and the bit says nothing useful about it.  Refusing on
that bit was the only thing in the way; the kernel now asks, prints what
the firmware answered, and lets the controller judge.
.PP
.B "What was written here first, and was wrong."
When the board went dark after a kernel was copied onto its card, this
said the copy was the suspect and the card had to be looked at before
anything was repaired.  The looking was right and the suspicion was
not: the installed image booted under QEMU from the same file, the
board's own later copy of a spare kernel was
.CW cmp 'd
byte for byte against its source and matched, and every firmware file
on the card md5'd equal to the upstream Raspberry Pi firmware.  The
card was damaged, and repairing it was worth doing, but the damage was
not why the board was dark.  A rename that wrote a zero length was.
See the chapter above.
.PP
Two lessons already banked.
.CW kupdate()
writes
.CW kernel8.new
and renames, keeping the old kernel as
.CW kernel8.bak ,
precisely so a bad image costs a card swap rather than the board;
copying over
.CW kernel8.img
in place gave that up.  And
.CW "ls -l"
is not a read-back: the length it prints is the directory entry, which
is the field most likely to be the wrong one.
.NH 2
The rename that emptied a kernel, and why the board was dark
.PP
Twice the board went dark after a reboot and came up perfectly from
cold, and twice that was read as a peripheral a cold start
power-cycles.  It was not.
.CW fsck
on the card said it in one line:
.CW "/KERNEL8.IMG has too many clusters allocated (logical=0, physical=1795584)"
\(em the kernel's directory entry had the whole chain and a length of
zero, and a kernel of zero bytes is one the firmware will not load.
.CW KERNEL8.BAK
had a length of 4177531875.
.I Kupdate
renames
.CW kernel8.img
to
.CW kernel8.bak
and
.CW kernel8.new
to
.CW kernel8.img
on every update, so the board emptied its own kernel every time it
updated itself.
.PP
.B "The cause is one line, and it is in Limbo's semantics."
.CW Dosdir.arr2Dd
builds a
.CW Dosdir
whose
.CW reserved ,
.CW time ,
.CW date ,
.CW start
and
.CW length
are
.I slices
of the sector it was read from, and a Limbo slice shares the array it
is taken from.  A
.CW Dosdir
is therefore a window on a buffer, not a copy of an entry, and it is
only valid while that buffer holds that sector.
.CW Rwstat
took the length from the old entry and then, before writing it into the
new one, released the file, removed the old entry and searched the
directory for a slot \(em and that search is what hands the buffer to
another sector.  The four bytes written into the new entry were whatever
had landed there.
.PP
.B "Which is why nothing on the host could see it."
On a small filesystem the search touches few sectors, the buffer
survives, and the window still shows the right bytes.
.I Fatstress
passed on FAT16, on FAT32 with 512-byte clusters and files above cluster
65535, and on FAT32 with 4KB clusters, while the board failed the same
rename on every boot.  What it takes is a root directory long enough for
the search to recycle the buffer: an image built like the Pi's own boot
partition \(em sixty long-named files and a hundred-odd megabytes in
them \(em fails against the old server and passes against the fixed one,
and that image is now the fourth case in
.CW tests/dossrv-stress.sh .
.PP
The fix is to copy the four bytes.  Making
.CW arr2Dd
copy everything was tried first and is wrong: the window is depended on
\(em a
.CW Dosptr
caches its entry in
.CW .d
and expects it to track the buffer, and
.I rcreate
stamps the parent directory's time through the window and only marks the
sector modified.  With the copy in place the files came back with no
clusters at all.  So the copy is where the value outlives the sector,
and what
.CW arr2Dd
returns is documented as what it is.
.PP
.B "A correction to the commit before it."
The USB controller's
.CW shutdown
hook was
.CW USED(hp) ,
and it now quiesces the core before the machine resets \(em masking
interrupts, halting every channel, dropping port power and resetting the
core \(em because the PM watchdog resets the ARM and leaves the
peripherals bus-mastering into RAM.  That is worth doing and it is not
why the board was dark.  The commit that made it said it was.
.NH 2
Why the mini UART looked slow to come up
.PP
It did not.  Everything the kernel printed before
.CW uartconsole()
chose a console went to the PL011, because that is what
.CW serialputc()
fell back to while
.CW consuart
was nil \(em and on a Pi 3 wired the firmware's own way the PL011 is the
Bluetooth pins.  Measured, with both of QEMU's serial ports captured to
separate files and the console forced to the mini UART: the PL011 port
took 40 bytes, exactly the build banner, and the mini UART took the
other 4736.  So the header's first sight of the kernel was the pool
sizes, a good way into the boot, and a board that says nothing for its
first half second looks exactly like a board that did not start.
.PP
The early path now asks the pins, which is what
.CW uartconsole()
asks a moment later and with the same answer.  It asks a stricter
question than the console does \(em the AUX enable bit as well as the
pin function \(em because it cannot turn anything on: a mini UART whose
enable is clear reads every register as zero, zero in LSR says the
transmitter is not ready, and a character then costs a million polls on
the one path that runs before anything else works.  With the fix and the
same measurement, the PL011 port takes nothing at all and the banner is
the mini UART's first line.
.NH 2
The ethernet's start-up time is the boot's, and it is not a constant
.PP
.CW ETHERUSB-SETUP
now times the chip set-up, and the init check prints how long it waited.
Measured on the board:
.CW "ETHERUSB-SETUP 10380 ms"
with the check waiting 11000, and on other boots 8700, 9200, 12300 and
one over 95000.  There is no sleep anywhere in that path \(em it is all
control transfers to the LAN9514's registers \(em so what varies is the
host controller's control path on this silicon, and that is where the
next look belongs.
.PP
It cost two wrong guesses first.  Ten seconds: the board printed
.CW ETHER-NONE
and
.I etherusb
served immediately afterwards, and with no
.CW /net
bound that whole boot had no network, no
.I kupdate ,
and nothing to reach the board by but the console.  Sixty seconds: the
same thing again.  The check now waits as long as usbd's
.CW ctl
file says there is an adapter to wait for, and gives up at once when
there is not \(em which is every QEMU boot, so the marker suite still
sees
.CW ETHER-NONE
promptly.  A deadline on hardware whose timing has not been measured is
a guess, and this one was wrong twice in the same afternoon.
.NH 2
The clock, and the three bugs between an answer and a timestamp
.PP
The board has no clock \(em there is no battery-backed RTC on a Pi \(em
and nothing here ever asked anyone, so every boot started at the epoch.
sntp(8) was already in the tree and simply never run.  Running it took
three fixes, and each one hid the next.
.IP 1.
.CW /dev/time
on the native kernel took seconds in a thirteen-character buffer.
cons(3) says microseconds, the hosted kernel has always read
microseconds, and both programs in this tree that set the clock write
microseconds.  So a correct write was a thousand times too large and too
long to fit, and failed; sntp ignores the error.
.IP 2.
The same file
.I read
as Plan 9's four fields \(em seconds, nanoseconds, ticks, tick rate \(em
while every Limbo program that asks the time reads the first number and
divides it by a million:
.CW daytime(2) 's
.CW now() ,
which is what dates a file, and ping's round trip, and cs, dns, keyfs,
iostats, timestamp, memfs, lockfs.  On a native kernel all of them got
zero.  That is why the Pi dated every file 1 January 1980 whatever the
clock said, and why every ping it printed read
.CW "rtt 0 us" .
.IP 3.
.I Dossrv
stamped files from a clock it read once at startup plus a stopwatch, so
a board whose clock is set after it starts goes on writing 1980.
.PP
On the board:
.CW "TIME-OK Fri Sep 18 15:14:27 GMT 2026 from 192.168.8.1" ,
the gateway, which answered all along \(em the earlier
.CW TIME-NONE
came from a check of mine that divided seconds by a million.
.CW /dev/time
then read within nine seconds of this machine.
.PP
Two things worth keeping from the way round it went.  A service name
needs a connection server:
.CW "udp!gw!ntp"
came back "non-numeric port number", which reads like a network failure
and is dial(2) falling back to identity translation when there is no
/net/cs, so the kernel now carries cs and the three ndb files.  And
fixing the round trips broke the clock: with real timings ping counted
its first message lost \(em 471 milliseconds, which is the ARP \(em and
raised, and that exception unwound through the caller and skipped the
time check that followed it.
.NH 2
A mount whose far end hangs up
.PP
The board fetched a kernel over a Styx link that hung up mid-read and
then wedged: the console still echoed every character typed, and no Dis
process ran again.
.I Kupdate
had returned with the dead mount still on
.CW /n/remote ,
which it no longer does \(em a mount whose far end is gone is not a file
that fails, it is one that waits.
.PP
That is the fix for the symptom and it is not a diagnosis.  The hangup
itself was reproduced deliberately under QEMU \(em mount this machine's
export, start a long read, kill the server \(em and the kernel survives
it: the same
.CW "mountio waserror()"
prints, the same
.CW Hangup
on the read, and a shell that answers afterwards.  So something else was
in the board's wedge, and the instrumentation already in
.CW os/inferno/port/dis.c
is the place to look next: it reports that
.CW delprog 's
window \(em where it releases the scheduler lock to close a process's
groups \(em overlaps another's on this board regularly, which is where a
kernel that still takes interrupts while no Dis program runs would come
from.
.NH 2
Where the ethernet's ten to a hundred and fifty seconds go
.PP
.CW ETHERUSB-SETUP
times the LAN9514's set-up and
.I etherusb
counts the control transfers it takes: 86 of them, and on this board
each one costs about 120ms.  A control transfer is a millisecond's work,
so the count was never the surprising number.
.PP
Two guesses were wrong before the measurement.  A NAK used to cost a
whole clock tick \(em
.CW tsleep 's
resolution is the tick and this kernel ticks at 100Hz \(em so the first
64 NAKs now spin instead, and then 2000 of them; neither changed the
120ms.  What settled it was timing the transfers inside the driver:
.IP
.EX
usbdwc: ep2.0 type 1 len 8: 20305 us, 1 loops, 0 naks, 0 nyets
usbdwc: ep2.0 type 1 len 0: 93802 us, 1 loops, 0 naks, 0 nyets
usbdwc: ep2.0 type 1 len 0: 8 us, 1 loops, 0 naks, 0 nyets
.EE
.PP
One loop, no NAKs, no Nyets, and either 8 microseconds or ninety
milliseconds.  Nothing is being retried: the transfer is waiting for the
CPU.  This kernel's SD driver is polled, so the boot's 1.5MB FAT write
and the kfs ream hold the processor while USB enumeration is a Dis
program waiting on completion interrupts, and the whole spread is which
of them got there first.
.PP
Making the card's work wait for the ethernet was tried and is not the
answer: it moves the contention rather than removing it, and the boot it
produced died in the kernel with
.CW "double sleep"
where the ordering before it does not.  What removes it is DMA for the
SD controller.
.PP
.B "And the answer was neither of them."
The timing was taken one level further in \(em when the channel was
armed, when the interrupt recorded the completion, when the process
waiting on it actually ran:
.IP
.EX
ep2.0 len 8:  44603 us total, 3 us to intr, 44596 us to wake
ep2.0 len 0:  86553 us total, 3 us to intr, 86547 us to wake
ep2.0 len 0: 142411 us total, 3 us to intr, 142405 us to wake
.EE
.PP
Three or four microseconds to the interrupt, every time: the controller
and the device are instant.  What the transfer waits for is a trip round
this kernel's run queue, once per transfer, and the set-up is 83 of
them.  A sleep that is woken four microseconds later is a sleep that
should not have happened, so
.CW chanwait
now spins 200 microseconds for the completion before it sleeps for it.
.PP
On the board that took
.CW ETHERUSB-SETUP
from 9620ms to 2280ms and
.CW ETHER-WAITED
from 9600ms to 2600ms, with every traced transfer costing 6 to 13
microseconds and none of them sleeping at all.  The card's contention
is real and the SD driver sleeps for its interrupt now rather than
spinning, which is right on its own; it was not what the ethernet was
waiting for.
.PP
.B "Which is what both of the systems this port learns from do."
Plan 9 and 9front's
.CW bcm/emmc.c
transfers with the DMA controller \(em
.CW "dmastart(DmaChanEmmc, DmaDevEmmc, ...)"
and
.CW dmawait
\(em and waits for the interrupt with
.CW "tsleep(&emmc.r, datadone, 0, 3000)" .
Linux's
.CW drivers/mmc/host/bcm2835.c
sets
.CW "PIO_THRESHOLD 1" ,
commented "Maximum block count for PIO (0 = always DMA)", so anything
past a single block is DMA and even the PIO path is interrupt-driven
through a work queue.  Neither holds the processor for the length of a
transfer.  This driver polls, always, and that is the difference the
measurement found.
.PP
The same comparison on the USB side says the other half of it.  9front
runs the DWC2 channel scan in a fast interrupt and defers the wakeups it
needs to a normal one, so completion handling outranks whatever else the
machine is doing; this port dropped the FIQ deliberately, which its own
header records.  Linux's dwc2 masks NAK as an interrupt condition
.RB ( HCINTMSK_NAK )
and completes transfers from the handler, so nothing sleeps per NAK
there at all.  And 9front's NAK path is what this file had before today,
to the character:
.CW "tsleep(&up->sleep, return0, 0, 1)" .
Spinning instead was a deviation from the donor that measurement showed
bought nothing, and it has been put back.  The timing is still in the driver, off by default \(em
.CW chaniotrace
names how many transfers to time \(em because the next person to wonder
where a USB transfer went should not have to guess twice first.
.NH 2
The card is 86 KB/s, and which driver that is
.PP
.CW FAT-BIG-OK
now prints what the boot's 1.5MB write cost:
.CW "17420 ms (86 KB/s)" .
That is the number to beat, and finding where it goes cost a wrong turn
worth writing down.
.PP
.B "There are two drivers for one controller."
.CW sdhcibcm.c
and
.CW sdemmcbcm.c
both drive the Arasan SDHCI at 0x3f300000, and the board's card is
served by the second \(em its line is the
.CW "emmc: card rca 0x1234"
on every boot.  An afternoon's work went into making the first one wait
on the controller's interrupt instead of spinning before that was
noticed, and it has been taken out again: an unused driver arming IRQ
62 on the same controller the used one is polling is a hazard, not an
improvement.  Whichever of the two is kept, this is a thing to settle
before either grows an interrupt handler.
.PP
.B "The active driver busy-waits."
.CW awaitirq
spins a hundred thousand status reads and then calls
.CW delay(1)
in a loop, so the processor is held for as long as the card takes \(em
and a card programming a block takes milliseconds.  Yielding there with
.CW "tsleep(&up->sleep, return0, 0, 1)"
was tried and panicked the board in
.CW wakeup() :
.CW "696d68 696d68 2" ,
the same Rendez with the process already Ready, so something else
readies a process sleeping that way.  Sleeping on
.CW up->sleep
with a condition that is never true is not how to wait for hardware
anyway.  What the driver wants is the controller's own interrupt and a
Rendez of its own, spinning briefly first for the same reason
.CW chanwait
does.
.PP
The instrumentation is in the file, off by default:
.CW emmctrace
aggregates how many waits there were, how many of them slept, and what
they cost, which is what a change here should be measured with.
.NH 2
The wedge was one missing line in qlock
.PP
This board has wedged all day \(em the console still echoing every
character typed, no program running again \(em and panicked in two
different places on the way there,
.CW "panic: pexit"
and
.CW "panic: wakeup: state" .
They are one bug.
.PP
.CW qlock()
never set
.CW up->qnext
to nil.
.CW eqlock ,
.CW rlock ,
.CW wlock
and the Plan 9
.CW qlock
this came from all do; only this one lost it.  So a process joining a
lock's queue carried whatever
.CW qnext
it had from the last time it waited for anything, and when the lock was
handed over,
.CW qunlock 's
.CW "q->head = p->qnext"
pointed the queue at a process that was not waiting for that lock at
all \(em and readied it.
.PP
That is both symptoms.  Readying a process that is asleep on a Rendez
leaves
.CW r->p
pointing at a running process, and the next wakeup on it panics.
Readying one that is dying gets it scheduled again after
.CW schedinit
has freed it, and
.CW pexit
panics because
.CW sched()
came back.  And the process that really was waiting for the lock is no
longer on the queue to be handed it, so it waits for ever holding
whatever it holds: the wedge.
.PP
.B "How it was found, since each step was built for the one before."
.CW ^\e
on the console dumps every process from a kproc, because a kproc still
runs when the Dis scheduler does not.
.CW ready()
reports a process readied while still attached to a Rendez, and names
the caller's pc.
.CW tools/ksym
turns that pc into a name from a
.CW "7l -a"
listing of the same build.  The board then printed
.IP
.EX
ready dis 18 still on rendez 0x696e18 from pc 0x15bda8
panic: wakeup: state
.EE
.PP
and
.CW 0x15bda8
is
.CW qunlock+0x9c .
The diagnostic that caught it was committed eleven minutes before it
fired.
.NH 2
What a woken process waits for, which is the next thing to fix
.PP
Two drivers have now been measured into the same wall.
.PP
.CW usbdwc :
3 or 4 microseconds from arming a channel to the completion interrupt,
and then 2.7 to 142 milliseconds before the waiting process ran.
Spinning 200 microseconds for the completion took
.CW ETHERUSB-SETUP
from 9620ms to 2280ms, because at that length the sleep never happens.
.PP
.CW sdemmcbcm :
the controller's interrupt works, the handler runs,
.CW EMMC-NOINTR
never prints \(em and sleeping for it measured
.CW "6 KB/s"
against
.CW "86 KB/s"
for the busy wait it replaced.  A card takes milliseconds over a block,
which is past any sensible spin, so this driver pays the wake-up
latency once per block and there is no way to dodge it from inside the
driver.  The interrupt path is kept and switched off:
.CW emmcsleep
in
.CW sdemmcbcm.c
turns it on, which is how a fix to the latency gets measured.
.PP
.B "So the thing to fix is the latency itself."
A process readied from an interrupt handler goes to the back of its
priority's run queue, and this kernel ticks at 100Hz, so it waits for
the running process's quantum and for everything queued ahead of it.
At boot, with the Dis VM, kfs, dossrv, usbd and etherusb all runnable,
that is the tens of milliseconds measured.  Where to look:
.CW ready()
sets
.CW m->readied
as a hint but nothing preempts on it;
.CW sched()
only reschedules at a quantum boundary or when a process blocks; and
.CW HZ
is 100, so the boundary is 10ms.  9front carries the same design and
does not feel it here because its Pi is not reaming a kfs and writing
1.5MB while it enumerates USB; Linux does not have it at all, because
its completions run in the handler and the next transfer is submitted
from there rather than by a process that has to be scheduled first.
.PP
.I "Two sections on, this paragraph turns out to be wrong about the quantum: there was not one."
It is left as it was written because what it
got right \(em that the time is in this kernel and not in the device
\(em is what made looking there worth it.
.NH 2
Preemption on interrupt return: measured, written, and switched off
.PP
The wake-up latency above has an answer and this kernel already
contains it.
.CW preempted()
is in
.CW os/inferno/port/proc.c ,
declared in
.CW portfns.h ,
with its own field in
.CW Proc ,
and nothing anywhere calls it.  Plan 9's
.CW trap()
ends every non-clock interrupt with
.CW "if(up && !clockintr && m->ilockdepth == 0) preempted();" .
.PP
Adding that call took two more things, each of which had to be measured
rather than assumed.
.IP 1.
It has to run.  Guarding it on
.CW islo()
never lets it: interrupts are masked inside a handler, and the counters
stayed at zero through a whole boot.
.IP 2.
Something has to outrank the runner.
.CW anyhigher()
wants a strictly higher priority queue to be non-empty, and with every
process here a kernel process at
.CW PriKproc
it was true 33 times in 10000 calls \(em
.CW "up pri 13 runvec 0x2000" .
A process woken from a sleep now gets one level, which
.CW reprioritize
takes away again as soon as it uses processor: 5501 in 10000 after that.
.PP
With both, on the board: the wake takes 203 microseconds, measured from
the interrupt handler to the waiter running, and
.CW ETHERUSB-SETUP
with no spin at all in the driver is 2300ms against 9620.  That is the
whole of what
.CW usbdwc 's
200-microsecond spin was standing in for.
.PP
.B "And it wedges the board."
Not in the way that was expected \(em
.CW sched()
gives up delaying a reschedule after twenty tries and switches away from
a lock holder anyway, which on a uniprocessor is a deadlock, so the call
site guards on
.CW up->nlocks
as well.  With that guard it still wedges, and
.CW ^\e
says how: every process in
.CW acquire() ,
which is not a QLock but the Dis interpreter's own hand-off queue, and
nobody running to release it.  Preempting a process that holds the
interpreter looks legitimate and something about it is not.
.PP
So it is committed and switched off \(em
.CW intrpreempt
in
.CW trap.c ,
.CW ioboost
in
.CW proc.c
\(em with the spin back in
.CW usbdwc
holding the line at 2280ms.
.NH 2
There was no scheduler clock
.PP
Before the question about the interpreter could be answered, a smaller
one turned out to have a wrong answer in this document.  The section
above says a woken process "waits for the running process's quantum".
There is no quantum.
.PP
.CW hzsched()
is in
.CW os/inferno/port/proc.c .
It is what raises
.CW up->delaysched
when a process has had its 100ms or when something better is ready, and
in Plan 9 the clock interrupt calls it on every tick.  It is compiled
into this kernel; it is in the link line;
.CW iraspi3b.listing
has it at
.CW 00155f14 .
.B "Nothing calls it."
Not
.CW raspi3b/clock.c ,
not
.CW raspi4 ,
not
.CW virtarm64 ,
not the RISC-V boards \(em
.CW "grep -l hzsched os/inferno/*/clock.c"
returns nothing at all.
.CW accounttime()
is dead in exactly the same way, which is why
.CW /prog/ * /status
never showed a process using any time.
.PP
So this kernel does not preempt.  It has never preempted.  The
processor changes hands when a process blocks of its own accord \(em
.CW sleep() ,
.CW qlock() ,
or the
.CW release()
that brackets a blocking Dis system call \(em and at no other moment.  A
Limbo program in a loop holds the processor until it makes a system
call, and a process a device interrupt readied waits precisely that
long.  That is the 2.7 to 142 milliseconds, and it is not a queue
depth, a priority, or a tick: it is the absence of the mechanism
entirely.  The
.CW 142411
microseconds in the trace above is one Limbo loop between two system
calls.
.NH 2
Asking for the processor instead of taking it
.PP
Which leaves the question the wedge asked: where, in a kernel with no
user mode, is it safe to take the processor away?
.PP
Plan 9 answers with the hardware.  A process it preempts is in user
mode, or in a system call written to be abandoned anywhere, and
.CW up->nlocks
covers the rest.  Native Inferno has no user mode.  Every process here
is a kernel process running C, so "preempt whoever is running" means
"switch away from arbitrary kernel code", and
.CW nlocks
counts spin locks and nothing else.  It does not count the Dis
interpreter's hand-off token, which is neither a
.CW Lock
nor a
.CW QLock ;
it does not count a
.CW waserror()
frame half built.  That is why the board wedged with every process in
.CW acquire() ,
and it is why no guard on
.CW preempted()
was going to be enough: the scheme wants an invariant this kernel does
not have.
.PP
But it has one place where the invariant holds exactly.  At the top of
.CW vmachine() 's
loop, control is between two Dis instructions.  The whole machine is
.CW R
and the heap, both of which
.CW xec()
has just written back into the
.CW Prog .
No C invariant is half written, no lock is held, no error label is in
flight.  It is what user mode is in Plan 9, and a CPU-bound Limbo loop
reaches it every
.CW PQUANTA
\(em 2048 \(em instructions whatever it is doing, because that is how
the interpreter already slices between
.CW Prog s.
.PP
So interrupts ask and the interpreter gives:
.IP \(bu
.CW raspi3b/clock.c
calls
.CW accounttime()
and
.CW hzsched() ,
which is the tick this kernel was missing.
.IP \(bu
.CW wantsched()
in
.CW port/proc.c
is what a device interrupt calls at the end of
.CW trap() .
It adds one to
.CW up->delaysched
and returns.  It switches nothing, so it needs no guards at all \(em it
is safe at any interrupt depth, holding anything.
.IP \(bu
.CW vmachine()
begins each pass with
.CW "if(up->delaysched) sched();" .
.CW sched()
clears the flag and puts the process on the back of its run queue,
which is what a quantum expiry does in Plan 9.
.PP
Everything that is not the interpreter is left alone, and that is the
design and not an omission.  A driver kproc either blocks by itself, in
which case there is nothing to take, or it is spinning on a device
register, in which case taking the processor from it is the wrong
answer \(em
.CW sdemmcbcm
measured 86 KB/s spinning against 6 KB/s sleeping for the same
interrupt.  The only process that can hold the processor for an
unbounded time without blocking is the one running Limbo, and that is
the one this reaches.
.PP
One more line came out of the same reading.
.CW acquire()
calls
.CW sched()
and assumes it switched;
.CW sched()
makes no such promise, returning without switching while the process
holds a spin lock, up to twenty times in a row.  Had that ever happened
there, the process would have fallen through and run the interpreter
without the token while still linked on
.CW isched.vmq
for
.CW release()
to hand the token to \(em and the token would be gone, with every other
process queued in
.CW acquire()
behind a VM nobody is running.  That is the shape of the wedge, so
.CW acquire()
now panics instead of hanging.  It costs nothing and it names the fault
if it is ever reached.
.PP
And the measurement stops being something to switch on.
.CW usbdwc
prints
.CW USB-WAKE
on every boot: the first completion that actually slept on its own,
then the mean and the worst of the first eight, each measured from the
interrupt handler waking the waiter to the waiter running.  Completions
the 200-microsecond spin catches are counted separately and not
averaged in, because a transfer that never waited has no latency to
report \(em and the ratio is itself the answer to whether the spin is
still earning its place.  Under QEMU it is 2287 caught for the first
one that slept.
.PP
Two things it got wrong first, both worth keeping written down.
Sixty-four samples was too many: a whole QEMU boot produced fewer and
printed nothing at all, which is the one way an always-on instrument
can fail.  And the timestamp the handler leaves behind belongs to a
channel, not to a transfer, so a
.CW tsleep
that timed out with no interrupt at all measured from whenever that
channel last completed \(em QEMU's idle bulk IN reported a 1.1 second
scheduler latency, which is a stale subtraction and not a fact about
anything.  Clearing it when the channel is armed is what makes the
number mean what it says.
.NH 2
The rename that loses a file, and how to pick it up cold
.PP
This is the top of the list and it is the only thing on it that has
cost a working board.  A kernel installed over the network has twice
come back with whole 32KB chunks holding the previous kernel's bytes,
and the board did not boot; the card had to come out and be read on the
host to find out why.
.PP
.B "It reproduces without the Pi, and that is the whole of the good news."
.CW "sh tests/dossrv-stress.sh card"
builds a 2400MB FAT32 image with 64 sectors to a cluster \(em 32KB, the
card's own shape, which none of the other four cases comes near \(em
and runs
.CW fatstress
against it under
.CW emu .
The first run of it failed in seconds:
.P1
=== card (FAT32, 64 sector(s) per cluster, 0MB filler)
FATSTRESS-FAIL open /n/t/k.img: '/n/t/k.img' does not exist
.P2
That is round 0 of
.CW kupdaterehearsal
in
.CW appl/cmd/fatstress.b :
write 1.5MB as
.CW k.new ,
remove
.CW k.bak ,
rename
.CW k.new
to
.CW k.img ,
and read it back.  The rename returned success and the file is not
there.  It is the sequence
.CW kupdate()
performs on the board, at the cluster size the board uses.
.PP
.B "What is known."
.IP \(bu
It is intermittent.  The second run passed.  A rate is the first thing
to establish and a loop over
.CW "sh tests/dossrv-stress.sh card"
is how.
.IP \(bu
It is not the SD driver.  The board reports
.CW "errors 0"
in
.CW /dev/sdM0/ctl ,
so
.CW emmcbio
never refused a block, nothing short ever reached
.CW devwrite ,
and the
.CW twrite
failure path fixed in
.CW 4ba7ee59
\(em real, and worth having \(em is not this.
.IP \(bu
It is cluster-size dependent.  The other four cases use 512-byte,
512-byte, 4KB and 512-byte clusters and have never shown it.
.IP \(bu
On the board the symptom is different and may or may not be the same
fault: there the file exists at the right size and some of its clusters
were never written.  Here the file is gone.  Both follow a rename of a
large file.
.PP
.B "Where to go next, in order."
.IP 1.
Shrink it.
.CW ROUNDS=1
.CW FILES=1
cuts the case to one round, and
.CW kupdaterehearsal
still runs.  A failing sequence that takes seconds is worth more than
an explanation.
.IP 2.
.CW dossrv
has
.CW iodebug
and
.CW chat ;
turn them on for the failing round and watch the directory entry and
the FAT chain across the rename.
.CW rwstat
is the rename, and this tree has already fixed two bugs in that
neighbourhood \(em
.CW doremove
deleting a neighbouring file's long-name entries, and
.CW rwstat
aliasing the sector window instead of copying the length \(em so the
third is likely to be near them.
.IP 3.
Ask whether the shape matters rather than the size: 32KB is 64 sectors,
and
.CW sect2trk
comes from the BPB's sectors-per-track, not from the cluster size.  A
directory that is one cluster, a cluster that spans several tracks, and
a track that spans several clusters are three different arithmetics and
only one of them is exercised by the existing cases.
.NH 2
The kernel that came back stale, 20 September 2026 -- the bug, measured
.PP
.B "It is not fixed, and the reason four checks said it was is the finding."
The section above ends by recording that the rename failure did not
reproduce in 60 host runs or in a full stress run on the board, and
that the likely reading was that it no longer existed.  That was wrong.
.PP
The card came out of the board with a
.CW kernel8.img
of exactly the right length \(em 1918040 bytes, to the byte \(em and
213075 wrong ones.  Compared against the build it came from, and
against the kernel it replaced:
.P1
stale region: bytes 40..262143 = 262144 bytes = 256KB
              = 512 sectors = 64 of this card's 4KB clusters
bytes after 262143 that are wrong: 0
of the 213075 differing bytes, 213075 match kernel8.bak
.P2
So the first 256KB of the file was never written, what stands in its
place is the previous kernel's content, and everything past that point
is correct.  The board booted 8KB of a kernel and wedged.
.PP
.B "Every instrument aimed at this ran through the thing under test."
.CW kupdate
printed
.CW "KUPDATE-VERIFY 1918040 bytes read back identical"
about that file.  It reads the file back through the
.I dossrv
that has just written it, so the sector cache answers with the bytes it
is still holding and the sum agrees with itself.
.CW fsck_msdos
passed on the same card, because the chains, the directories and the
free count were all correct \(em it is an outside opinion about the
.I structure ,
and nothing was checking the contents.
.CW fatstress
reads back the same way
.I dossrv
wrote.  And the copy I made by hand, and the
.CW cmp
that pronounced it identical, both went over a styx mount that had hung
up: the same dead channel reported the write and then confirmed it.
.PP
That is the lesson worth keeping, and it is the one in
.CW blind-instrument-rule :
a check that reaches its answer through the path it is checking cannot
fail.  Four of them agreed, and all four were the same check.
.NH 2
The check that does not, and what it has ruled out
.PP
.CW tests/dossrv-outside.sh .
.I Dossrv
writes the file under
.I emu ,
.I emu
exits, and macOS mounts the image and compares the bytes.  Two
filesystem implementations with no cache in common, and the one doing
the checking has never heard of the one being checked.  It performs
.CW kupdate 's
sequence rather than a plain write \(em write
.CW kernel8.new ,
rename
.CW kernel8.img
to
.CW kernel8.bak ,
rename
.CW kernel8.new
into place \(em over several rounds, so the clusters of the previous
file are freed and handed straight back out as they are on the board,
and it checks
.CW kernel8.bak
as well.  Where the bytes differ it prints the differing runs, because
a stale prefix and a scatter are different faults.
.PP
.B "It does not reproduce it, and that is information."
Three arrangements have now passed, each adding what the one before it
lacked:
.IP \(bu
One write and one rename into an empty filesystem: clean.
.IP \(bu
Four rounds of the full
.CW kupdate
sequence, so every round writes over clusters the previous round
freed: clean.
.IP \(bu
The same, with
.CW "fatstress -n 12 -f 8"
running against the same
.I dossrv
at the same time \(em which is the board's own arrangement, where
.CW kupdate
is spawned on purpose so the fetch and the FAT checks proceed together
and share one server and one cache: clean.
.PP
So it is not the sequence, not cluster recycling, and not a second
client competing for the cache.  What is left that the host does not
have is the medium: on the board these writes go through
.CW devsd
and
.CW sdemmcbcm
to a real card, and under
.I emu
they go to a file.  Which is where the plan said to look for a
different reason, and is now where it should be looked at.
.PP
.B "What to do on the board, in order."
.IP 1.
Make
.CW kupdate 's
verify mean something.  Reading the file back through the server that
wrote it will always agree; reading it through a
.I dossrv
that has just been started will not, because its cache is empty.  The
cheapest honest verify is to take the mount down and put it back up
before reading.  Until that is done the board cannot tell a good
install from this one.
.IP 2.
Find where the early writes went.  The bytes are not merely missing:
the file's first 64 clusters hold the
.I previous
file's content, which means either those clusters were never written,
or what was written for them landed somewhere else.  Reading the raw
partition and following the chain by hand says which, and the board can
do it now that
.CW dd
is in its root.
.IP 3.
Ask whether 256KB is a number in this system.  It is 512 sectors, 64
clusters, and 8 of the SD driver's 64-block transfers; it is not 20
tracks of 9 sectors, which is what
.I dossrv
caches.  A boundary that exact belongs to something.
.NH 2
What the card's boot partition actually is, 19 September 2026
.PP
The section above rests on a premise, and the premise is wrong.  It says
the card's filesystem has 64 sectors to a cluster, and the
.CW card
case in
.CW tests/dossrv-stress.sh
was built to match: 2400MB, FAT32, 64 sectors per cluster, at that size
only because FAT32 needs 65525 clusters and 32KB ones do not reach that
until 2.1GB.  So the case that was supposed to be the card's own shape
is the only one in the file that is nothing like it.
.PP
The boot sector was read off the board today rather than assumed.  A
2MB prefix of
.CW /dev/sdM0/dos
copied to the host through the styx mount, and parsed:
.P1
bytes/sector 512   sectors/cluster 1   reserved 32   nfats 2
sectors/FAT32 8066   total sectors 1048572   sectors/track 63
clusters 1032408
oem "mkfs.fat"   label "bootfs"   hidden sectors 16384   sig 55 aa
.P2
.B "Corrected again, 20 September: the card was rebuilt and is now 4KB
clusters."
The partition was reformatted from the reader \(em same start, same
size, hid=16384 and bsec=1048576 unchanged \(em and
.CW newfs_msdos
chose 8 sectors to a cluster.  That is kept: it is one eighth the FAT,
1022 sectors instead of 8066, so far fewer FAT sector rewrites per
file, which is the argument
.CW doc/efs-plan.ms
makes about flash.  The board reads the BPB at runtime and adapts.  The
paragraph below describes what the card was before that, and the 256KB
stale region in the section above is 64 of the new 4KB clusters.
.PP
.B "One sector to a cluster."
512-byte clusters, a million of them, and the partition really is the
one the firmware boots from \(em hidden sectors 16384 is its start, the
label is the one the plan names, and the signature is there.  Whatever
made a kernel come back with 448KB of the previous one, it was not a
32KB cluster, because there are no 32KB clusters on this card.
.PP
The second half of that step is wrong too.
.CW sect2trk
does not come from the BPB.
.CW dossrv 's
.CW -S
option sets it and nothing else does, the default is 9 \(em a 1980s
floppy track \(em and
.CW raspi3binit.b
starts the server as
.CW "dossrv -f /dev/sdM0/dos -m /n/dos"
with no
.CW -S .
So the server reads and writes this card in 9-sector, 4608-byte units
that correspond to nothing on the medium, and caches 20 of them: 92KB
of write-back cache in front of a card whose own BPB says 63 sectors to
a track.  That is the granularity the corruption should be measured
against, and 448KB is 97 of those tracks.
.PP
What this leaves standing, and what it removes.  It removes the cluster
size as an explanation and it removes the
.CW card
case as evidence of anything about this card.  It leaves the
.CW busy
case as the closest thing in the file to the real shape \(em 512-byte
clusters, 512MB, a Pi boot partition's root \(em and that case passes.
So the difference between the host and the board is not the filesystem's
shape.  It is
.CW devsd
and
.CW sdemmcbcm ,
and the board is where to look, which is what the plan said for a worse
reason than it now has.
.PP
.B "First measurements from the board."
The installed
.CW kernel8.img
was compared byte for byte against the host's copy through the same
mount
.CW ( cmp
over
.CW "mount -A tcp!192.168.8.153!6666 /n/remote" )
and is identical, so the card is clean as it stands and there is a
baseline to go back to.
.CW fatstress
was then run against
.CW /n/dos
on the board itself, which is the first time that program has ever run
on real silicon:
.CW "-n 1 -f 1"
passes.  A fuller run is what has to be pushed on, since 60 runs on the
host at that size never reproduced the failure either.
.PP
Reading the card at all is slow enough to shape what is worth trying:
10MB from
.CW /dev/sdM0/dos
to the host over styx took about 45 seconds, some 230KB/s, so copying
the whole 512MB partition for a backup is a 40-minute operation and was
not done.  Only the first 2MB was saved, which covers the reserved
sectors and both FATs (they end at byte 8275968 \(em so in fact the
saved prefix does not cover them, and a full metadata backup needs 8MB,
which is worth doing before the next destructive run).
.NH 2
FAT32 in disk/format -- DONE
.PP
.CW appl/cmd/disk/format.b
cannot make a FAT32 filesystem.  It sizes the FAT by trying 12 bits and
then 16, iterating the cluster count against the table size until the
two agree, and then:
.P1
if(clusters >= 65527)
	fatal("disk too big; implement fat32");
.P2
That line is twenty-odd years old and until this week nothing in this
tree needed it to be otherwise.  It is needed now, and this is where it
bit: the card's unallocated 29GB is the obvious place to put a scratch
FAT32 with the card's own geometry, so that
.I dossrv
can be hammered on real silicon through the real driver without
risking the partition the firmware boots from.  There is no way to
create one.  Every FAT32 this port has ever touched was written by some
other machine \(em
.CW mkfs.fat
wrote the board's, and
.CW newfs_msdos
writes the stress images \(em and a system that can only ever read a
filesystem someone else made cannot test its own writer against a
fresh one.
.PP
.B "What it takes."
Not much, and the shape of the existing code is most of the way there.
.IP \(bu
The sizing loop gains a third pass.  It already iterates fatbits 12
then 16; 32 is the same loop with a different width, and the boundary
is 65525 clusters, the number that defines FAT32 \(em not 65527, which
is what the
.CW fatal
above compares against and is itself off by two.
.IP \(bu
The BPB changes shape rather than gaining fields.  The 16-bit
.CW DB_FATSIZE
and
.CW DB_ROOTSIZE
must both be written as zero, the 32-bit sectors-per-FAT goes at offset
36, the root directory becomes an ordinary cluster chain whose first
cluster (normally 2) goes at offset 44, and the whole extended BPB \(em
drive number, boot signature, volume id, label, the
.CW "FAT32   "
type string \(em moves from offset 36 to offset 64.  That last move is
the one that silently produces a filesystem every other system refuses,
because the fields are all still there, just four bytes at a time in
the wrong place.
.IP \(bu
Two sectors that FAT12 and FAT16 do not have: an FSInfo sector, whose
number goes at offset 48 and is normally 1, and a backup boot sector at
offset 50, normally 6.  The free-cluster count in FSInfo may be written
as the specification's "unknown" value, which is what
.I dossrv
already does and what
.CW fsck_msdos
already accepts from this tree.
.IP \(bu
FAT entries are 32-bit with the top four bits reserved, so a write is a
read-modify-write of those four bits and end-of-chain is any of
0x0FFFFFF8 through 0x0FFFFFFF.  The media-descriptor entry at index 0
is 0x0FFFFFF8.  The one rule to write into the code rather than the
comment is that no FAT32 cluster number is ever assembled from two
halves; this tree has now fixed that truncation three times in
.I dossrv
alone.
.PP
.B "How it gets believed."
Three checks, in order, and the third is the one that matters.
.IP "1." 5
.CW fsck_msdos
on the host against an image
.CW disk/format
made.  An outside opinion that knows nothing about this tree, and the
same one
.CW tests/dossrv-stress.sh
already uses.
.IP "2." 5
Mount it with
.I dossrv
and run
.CW fatstress
on it, then
.CW fsck_msdos
again.  A new case in
.CW tests/dossrv-stress.sh
whose image is made by
.CW disk/format
instead of
.CW newfs_msdos ,
so that the tree's writer and the tree's reader are checked against each
other and against an outsider at once.
.IP "3." 5
Format a scratch partition on the board's own card, at the card's own
geometry, and hammer it there.  That is the thing this is wanted for:
it makes the SD write path testable on silicon without the boot
partition on the table.
.PP
One further prize once it works, and it is worth saying out loud: a
.CW disk/format
that writes FAT32 can lay down the boot partition itself, so the card
stops being something a Linux machine has to prepare before Inferno can
use it.
.PP
.B "Done, 19 September 2026, and it cost a compiler bug on the way."
All three checks above pass.
.CW disk/format
then
.CW fsck_msdos :
2MB gives FAT12, 32MB FAT16, 64MB and 512MB FAT32, and all four are
clean \(em the only lines
.CW fsck_msdos
prints are the summary count and "Free space in FSInfo block is unset",
which are the two the stress harness already allows because
.I dossrv
chooses to write the specification's "unknown" rather than a number
nothing maintains.  Then
.I dossrv
mounted on a 512MB FAT32 this tree made,
.CW "fatstress -n 2 -f 6"
through it, and
.CW fsck_msdos
again: FATSTRESS-OK, eight files, clean.  The writer and the reader in
this tree now check each other with an outsider watching, which is the
thing that could not be done before.
.PP
The sizing turned out to be the larger half of the work and it was
wrong at every width, not just the missing one.  The FAT and the data
area depend on each other, and the code iterated from a guess of zero
clusters and gave up after ten rounds with "can't decide how many
clusters to use".  That is what any volume needing a FAT of more than a
few hundred sectors does: the iteration settles into a two-cycle
between adjacent values rather than a fixed point.  So the width was
never chosen for such a volume at all, and the FAT12/FAT16 boundary
above was unreachable for the same reason the FAT32 one was.  It grows
the FAT instead, which converges in one direction, and stops when the
FAT holds every entry the data area can ask for \(em which is the
invariant
.CW fsck_msdos
checks and the one the old arithmetic met only by accident.  It said so
out loud the first time:
.CW "FAT size too small, 129026 entries won't fit into 1008 sectors" .
.PP
.B "And disk/format had never run in this tree at all."
The first attempt died with
.CW "exception: illegal dis instruction" ,
on unmodified source, before any of this.  The cause is not in
.CW format.b .
.CW optabinit()
in the limbo compiler fills two tables, one of opcodes and one of types
\(em
.CW precasttab ,
the pairs no single Dis instruction converts, each naming the type to go
through.
.CW optabinit()
runs before the command line is parsed, and
.CW typeinit()
was moved to after the flags in
.CW 97b2543b
so that
.CW -W
could size the built-in types.  So every
.CW "precasttab[a][b] = tint"
stored a nil, no cast got its step through int, and
.CW casttab 's
0xff sentinel went out as an instruction: opcode 255, no optab entry,
.CW badop .
Every conversion between
.CW byte
and
.CW big ,
.CW real ,
.CW string
or
.CW fix ,
in every program this branch has compiled.
.CW "big b[DB_NFATS]"
in the boot sector code is the one that found it, and writing the same
cast out by hand as
.CW "big (int b[0])"
works, which is what makes it look like a strange bug in one program
rather than the compiler under all of them.
.CW multicore
and
.CW inferno-ports
moved
.CW typeinit
the same way and have the same bug;
.CW inferno-rio ,
.CW main ,
.CW arm64
and
.CW pr-ember
call it first and do not.
.NH 2
fatstress on real silicon, 19 September 2026
.PP
.CW fatstress
had never run on the board.  It does now, over the styx mount that
.I kupdate
already uses
.CW ( "mount -A tcp!192.168.8.153!6666 /n/remote" ),
so the host's
.CW /dis
is available to the board without rebuilding a kernel to carry a test
program into it.
.PP
.B "The full case passes."
.CW "fatstress -n 4 -f 12 /n/dos"
against the card's own boot partition, through
.I dossrv ,
.CW devsd
and
.CW sdemmcbcm
on real hardware: four rounds, FATSTRESS-OK.  Afterwards the installed
.CW kernel8.img
is still byte for byte the host's copy and
.CW /dev/sdM0/ctl
still says
.CW "errors 0" .
.PP
That is worth stating plainly because of what it removes.  The rename
that loses a file does not reproduce on the host in 60 runs and does not
reproduce on the board in a full stress run, with the
.I dossrv
that carries
.CW 4ba7ee59 's
write-back failure path and the two rename fixes before it.  The most
likely reading is that it is already fixed and that the section above is
describing a bug that no longer exists.  What would settle it is the
scratch partition: sectors above 1064960 are unallocated, so a FAT32
there at the boot partition's own geometry can be hammered for as long
as it takes without the firmware's partition on the table \(em and that
is exactly what
.CW disk/format
could not make until today.
.PP
One thing the board said during the run and nothing here has chased:
.CW "usbdwc: ep3.1 re-armed after 2 s (1000 times): hcchar 00d88a00 hcint 00000000" .
.NH 2
Stage one: making the clock scheduling actually work
.PP
The tick is wired up and the interpreter yields on request, and that is
not the same as working.  What was written is a mechanism with four
links in it, and the thing about a chain of four is that three of them
working looks exactly like none.  So stage one was not more design: it
was making each link report, separately, whether it did its job.  Both
of the bugs below were found that way and neither was where the design
said to look.
.PP
.B "The counters."
.CW "echo sched >/dev/sysctl"
prints them.
.CW hzschedcalls
says the tick reaches
.CW hzsched()
at all \(em it is called only when a process is Running, so on an idle
board it is not called and nothing would otherwise say so.
.CW reschedraised
says the gate opened;
.CW reschedtaken
says
.CW vmachine()
acted on it.  Raised much larger than taken would mean the process
holding the processor is not the interpreter, and the safe point is in
the wrong place \(em the one link in the chain that was reasoned rather
than measured.  It is not: raised and taken track each other.
.PP
.B "The check."
.CW SCHED-LAT ,
in
.CW raspi3binit.b ,
and it needs nothing but the board.  Sleep 50ms ten times and record
the overshoot; spawn a Limbo loop that never makes a system call and do
it again.  The difference is the whole of what this work changes, and
it is self-calibrating: a 50ms sleep overshoots on an idle board too,
by the tick granularity, by the emulator, and by the host underneath
it, and all of that is in both figures.  The median is the verdict and
the worst is printed beside it, because they answer different questions
and averaging either away would be the point of the check going
missing.
.PP
.B "What it found first: a priority boost with no matching restore."
.CW canlock()
in
.CW port/taslock.c
raised its caller to
.CW PriLock ,
the top of the ordinary range, and saved what it had in
.CW l->priority .
Nothing ever put it back.
.CW l->priority
is written there and read nowhere in the tree,
.CW unlock()
does not touch the priority, and
.CW lock()
never did any of this \(em so a successful
.CW canlock()
pinned its caller at 20 until the next
.CW sched()
recomputed it from
.CW basepri .
.PP
That is not abstract.
.CW clockintr()
ends with
.CW "if(canlock(&clock0lock))" ,
in interrupt context, where
.CW up
is whatever process was interrupted, so
.B "every clock tick left the running process at priority 20."
Counted on this board with a Limbo loop running:
.CW up->priority
was 14 or above on 138 of 256 ticks, and
.CW anyhigher() ,
which asks whether anything strictly above the runner is ready, was
therefore true on 22 of them.
.PP
.B "That is the whole of the \(lq33 times in 10000\(rq"
this document recorded two sections above as a fact about every process
here being a kproc at
.CW PriKproc .
It was a fact about one line.  The boost is removed rather than
repaired, because what it was for \(em do not reschedule a process
holding a spin lock \(em is
.CW up->nlocks ,
which
.CW lock() ,
.CW canlock()
and
.CW unlock()
maintain symmetrically and which
.CW sched()
already honours.  A lock holder is running, not queued, so its queue
priority does not arise until it has let go.
.PP
.B "And what it found second: anyhigher() is still the wrong gate."
With the boost gone,
.CW anyhigher()
works \(em it fired on 91 ticks out of 220 rather than 22.  It is still
worse than asking the cheaper question.  Measured both ways, the total
run-queue wait over ten 50ms sleeps against a Limbo loop was 160 ticks
with
.CW anyhigher()
and 68 with
.CW anyready() ,
and the trace says why:
.CW reprioritize()
lowers the woken process to the interpreter's own level as soon as it
has run for a while, so "strictly higher" stops seeing it.
.PP
Plan 9 asks the strict question because switching away from a user
process to ask is not free.  Here what is yielded to is a Dis
instruction boundary, where giving the processor up costs a context
switch and nothing else, so "somebody else could run" is a good enough
reason and being wrong about it costs microseconds.  Both
.CW hzsched()
and
.CW wantsched()
use
.CW anyready() .
.PP
.B "ioboost is a dead end, and the counters say why."
It was written to give a process woken from a sleep one priority level,
so that it would outrank whatever had been computing.  Every kproc in
this kernel sleeps, so every kproc gets the boost: with it on, the
running process was itself at 14 or above on 221 of 266 ticks.  A boost
everyone has is not a boost.  It is committed, set to 0, and kept for
the measurement.
.PP
.B "Where it stands, on the board."
.CW SCHED-LAT-OK
on all four QEMU configurations and on silicon: a 50ms sleep against a
Limbo loop overshoots by a median of 0ms under QEMU and 10ms on the
board, and 10ms on the board with nothing running at all.  The two
figures are the same, which is the whole claim.  Before this work the
loaded figure was not a few ticks worse, it was unbounded \(em a Dis
program that makes no system call held the processor until it made one.
.PP
.B "And the board corrected two numbers and two instruments."
The 40 milliseconds
.CW ILOCK-MAX
reported in
.CW uartkick
under QEMU is 3.2 milliseconds on silicon, in the same function, which
is what the emulator's instant-drain PL011 predicted it would be.  A
term worth three tenths of a tick, not four.
.PP
Both instrument bugs were found by the board and neither could have
been found anywhere else.
.CW lcycles()
returns a
.CW long ,
kencc's
.CW long
is 32 bits, and the A53's counter runs at 19.2MHz \(em so its low half
is negative for half of every 223 seconds, and the ilock instrument,
which used the sign of the saved start time as its armed flag, counted
506 ilocks early in a boot and then zero for the rest of it.  Zero
ilocks reads exactly like a quiet kernel.  It carries its own armed bit
now, and subtracting two wrapped 32-bit counts is still right for any
interval shorter than the wrap.
.PP
The idle-GC timer kept its start in a static, and
.CW execatidle() 's
loop calls
.CW sched() ,
so every interpreter kproc measured from whichever one ran last: the
total came to 1.8 million ticks on a board that had been up for 12
thousand.  A counter larger than the uptime is the tell, and the fix is
a local.
.PP
.B "What the board then said about the real problem."
Over two minutes of ordinary running \(em ethernet, kfs, the FAT
checks \(em the worst run-queue wait was 1824 ticks.  Eighteen seconds.
.CW USB-WAKE
over the same boot is a mean of 107 milliseconds and a worst of 855
over the eight completions that slept.  That is not the scheduler
failing to yield: the counters say it yielded, and
.CW SCHED-LAT
says a woken process gets the processor at once when what holds it is
Limbo.  It is the first thing stage one wrote down as not preempted on
purpose \(em a kproc in a C loop \(em and on this board that kproc is
the polled SD driver, which holds the processor for as long as it takes
to move a block and is the reason writing 1.5MB took 212 seconds while
everything else ran.  Stage two is where that becomes a number instead
of a cause.
.PP
.B "And one thing that is not explained."
The worst of the ten is 670 milliseconds, every time, on the first
sleep after the second interpreter kproc appears \(em and only that
one; the other nine are at zero.  Over that wait the interpreter
yielded on every tick, 67 raised and 67 taken, and the process stayed
on a run queue anyway.  It is not the garbage collector: the busy pass
is timed now and totals zero ticks, and the idle pass has not run since
boot.  Part of it is the console: with the interrupt-masked window
measured over exactly this interval,
.CW ILOCK-MAX
is 46 milliseconds in
.CW uartkick ,
which is one call.  That is a stage-two term arriving early and it does
not account for all of 670.  It is written here rather than averaged
out of the check.
.PP
.B "And one check that can only fail."
.CW acquire()
panics if
.CW sched()
returns without having switched.  That path was reasoned to be
unreachable; it has not fired.
.PP
.B "What stage one does not do, deliberately."
Three kinds of process remain unpreemptible and each is a decision
rather than an omission, and each has to be written down here because
stage two has to add them up.
.IP 1.
A kproc in a C loop.  The driver that spins on a device register is the
point of the design, but the same is true of any kproc that computes:
.CW usbd ,
the ethernet reader, the GC when it runs outside the interpreter.
.IP 2.
A Dis process inside a system call, between
.CW release()
and
.CW acquire() .
It does not hold the token and it is about to block, so there is
nothing to take \(em unless the system call is a long computation in C,
which
.CW sysfile 's
large reads and the FAT server's sector walks can be.
.IP 3.
The interrupt handler itself, which is upstream of all of this and is
stage two's first term.
.NH 2
The card came out, and what was on it
.PP
A kernel installed over the network did not boot, and the card had to
be read on the host to find out why.  What was there was the right
name, the right size to the byte, and the wrong contents: 13780 bytes
wrong out of 1851880, in what looked at first like 8363 scattered runs
of one and two bytes.
.PP
That shape was the whole answer, and it took one more question to see
it.  Two adjacent builds of this kernel differ only in scattered bytes,
so a whole block written from the wrong build shows up as scattered
bytes.  Aligning the comparison says so plainly: at 32KB \(em the
cluster size on this card \(em 42 chunks matched the new kernel, 14
matched the old one exactly, and one, the last, was partial.  The 14
are chunks 0 to 13 and chunk 29.
.B "The first 448KB of the file was never written, and nothing said so."
.PP
.CW kupdate()
checks every write it makes.  Every one of them returned the length it
was given; the fetched total was right; it printed
.CW "KUPDATE fetched 1851880 bytes"
and installed it.  So the loss is below
.CW sys->write :
in
.CW dossrv ,
in
.CW devsd ,
or in
.CW sdemmcbcm ,
and it is silent.  That is a more serious thing than any number in the
section below, because it means a write on this board can be believed
and be wrong.
.PP
The first thing to do about it is not to fix it, it is to stop it
costing a card swap.
.CW kupdate()
now sums what it fetches as it fetches it, reads the file back off the
card, and sums that too.  If they differ it says so and leaves the old
kernel exactly where it is.  It costs one more pass over 1.8MB through
the same slow path, which is tens of seconds, and it turns a board that
does not boot into a line that says why.  That trade is not close.
.PP
Then the fault itself.  It is reproducible in principle without the
board \(em
.CW fatstress
and
.CW tests/dossrv-stress.sh
drive the same
.CW dossrv
against a file image under
.CW emu ,
and the FAT32 case there uses 512-byte clusters where the card uses
32KB.  A first pass should be a 1.8MB sequential write to a 32KB
cluster image, read back and compared, because that is the exact shape
that failed.  If it passes there, the difference is
.CW devsd
or the driver, and
.CW sdemmcbcm 's
short-count return on error is the first place to look:
.CW emmcbio
breaks out of its block loop and returns the bytes it managed, and
whether anything above it notices is a question this has not asked.
.NH 2
Stage two: soft real time, which is turning a latency into a bound
.PP
.B "Soft real time is a bound you can measure."
A process woken by a device runs within some time, and the time has a
number on it rather than a hope.  With nothing preempting, that number
was 142 milliseconds and it was not a bound at all \(em it was however
long the running Limbo program took to reach its next system call, so
it was unbounded in principle and merely finite in practice.  With
stage one proved, the bound is a sum of terms, and stage two is
measuring each term and then measuring the sum under load to see
whether the two agree.
.IP 1.
.B "Interrupt latency."
How long the kernel keeps interrupts masked, which every other term
sits on top of.
.CW port/taslock.c
measures it now:
.CW "echo ilock on >/dev/sysctl"
starts counting,
.CW "echo ilock >/dev/sysctl"
prints the longest window in microseconds, the kernel address that took
the lock, and the mean over every ilock since, and resets \(em so the
number can be taken over a named interval, a
.CW fatstress
run or a USB enumeration, rather than over whatever happened since
boot.  It is off until asked because it costs two counter reads on
every ilock in the kernel; off it is one predictable branch.  The
.CW Lock
field it needs and
.CW lcycles()
exist only on this board, so
.CW -DILOCKTRACE
is in the raspi3b mkfile and the other boards compile past it
unchanged.
.IP
First reading, over stage one's
.CW SCHED-LAT
interval: 40 milliseconds, in
.CW uartkick ,
in one call.  That is the console, and it is far and away the largest
thing found so far.
.IP
.B "And it is mostly the emulator, which took a second look to see."
.CW pl011_kick
fills the transmit FIFO and stops when interrupts are on, and that
FIFO is 16 bytes \(em but QEMU's model consumes a byte the instant it
is written, so the FIFO never fills and the loop writes the whole
console queue, one trapping MMIO access each, with the host's own
chardev write inside the
.CW ilock .
A number taken on an emulator for a thing the emulator does not model
is not a fact about this kernel, and this one is not.  The term is
real; the reading has to be taken on the board.
.IP
What is worth fixing regardless is the other path.  With interrupts
already off \(em which is what
.CW print()
from inside a handler does \(em
.CW pl011_kick
drains the whole queue, spinning per byte, and the length of that is
the length of the queue.  That is now bounded at 64 bytes, because the
TX interrupt and
.CW uarttxpoll()
will finish what is left and leaving costs a tick at worst.  The
exception is a machine that is stopping, where nothing will come back
for the rest: under
.CW panicking
or
.CW active.exiting
the whole queue still goes out, and
.CW main.c 's
.CW exit()
sets the second for that reason.  This is reasoning, not measurement:
QEMU cannot show what it is worth and the board has not been asked
yet.
.IP
Not yet measured, and part of the same term: the masked windows that
are not ilocks \(em
.CW splhi()
in
.CW sched() ,
the trap prologue before the handler is reached, and whatever a handler
does before it returns.
.IP 1a.
.B "And the SD number went backwards, which is how the term got found."
The board's 1.5MB FAT write measured 17.4 seconds at the commit that
recorded 88 KB/s for the spinning driver, and 219 seconds now \(em 6
KB/s, which is exactly the figure that same commit recorded for the
sleeping driver it rejected.  Same check, same board, same
.CW emmcsleep=0 .
.IP
The first thing to rule out was the driver, and the way to rule it out
is a quiet board: copying 1.85MB card to card from the shell, with
nothing else running, took 36 seconds \(em 3.7MB of traffic through the
same path, about 100 KB/s.  So the path is not slower.  What is slower
is the writer's share of the processor while the rest of the boot is
happening, which is a scheduling answer to a throughput question and is
the reason this section exists.
.IP
Two candidates, and both are switches now rather than arguments.
.CW schedclock
turns off the tick's calls to
.CW hzsched()
and
.CW accounttime() ,
which is what this kernel did before any of this work: nothing
preempted, and a process doing a long write ran uninterrupted until it
blocked.
.CW lockboost
restores
.CW canlock() 's
unrestored
.CW PriLock ,
removed above as a bug and quite possibly load-bearing \(em
.CW clockintr()
calls
.CW canlock()
every tick, so whoever was running was pinned at the top of the
ordinary range until its next
.CW sched() ,
and that includes the process doing the writing.  Pinning the runner at
20 is not a defensible way to get throughput.  Whether it is what was
providing it is a measurement, and
.CW FAT-BIG
is the same 1.5MB write all three numbers came from, so they compare
directly.
.IP 2.
.B "The spins the drivers keep on purpose."
.CW usbdwc
spins 200 microseconds for a completion and
.CW sdemmcbcm
polls its data register for a whole block, both deliberately, both
bought with latency for throughput \(em 86 KB/s spinning against 6
sleeping.  A spin in a kproc is not preemptible under this design, so
every such spin is an addend in the worst case.  They have to be
counted and named, not removed.  The SD one is the large one and it is
a whole block, not a fixed number of microseconds, so it has to be
measured rather than read off a constant.
.IP 3.
.B "The garbage collector."
.CW rungc()
runs inside the interpreter's own loop, in the same kproc, between Dis
instructions, and the resched check is at the top of that loop \(em so
whatever a pass costs is added to every wake that lands behind it.
Timed now, and reported with the other counters: the busy pass
.CW vmachine()
runs every 256 iterations totals zero ticks over a boot, and the idle
pass in
.CW execatidle()
has a worst of 137 ticks, 1.4 seconds.  The idle one only runs when
nothing else is runnable, which is why it does not show up in
.CW SCHED-LAT ,
but it is 1.4 seconds of a kproc that yields only every 256 passes and
it is the term to attack first if a wake ever lands behind it.
.IP 4.
.B "The scheduler itself."
.CW runproc() 's
walk of the run queues, and the context switch.  Small, and the only
term that is bounded by construction rather than by measurement.
.PP
Then the sum, against the parts.  Run
.CW fatstress
and the ethernet and a USB enumeration at once, take
.CW USB-WAKE
and
.CW ILOCK-MAX
over that interval, and see whether the worst wake is explained by the
terms or exceeds them.  A worst case larger than the sum of its parts
means a term is missing, and that is the finding worth having.  What
this stage publishes is a number with the conditions it was taken
under, not a guarantee.
.NH 2
Stage three: hard real time, which is admission control
.PP
.B "Plan 9's is already here."
.CW os/inferno/port/edf.c
is the earliest-deadline-first scheduler from the Plan 9 real-time work
\(em 679 lines, with release timers, cost budgets, deadline notes and
schedulability admission.
.CW Proc
carries an
.CW Edf* ,
.CW schedinit()
calls
.CW edfrecord() ,
.CW taslock.c
has a branch for a lock taken by an admitted process, and
.CW runq
reserves
.CW PriEdf
and
.CW PriRelease
above every ordinary queue.  It compiles for this board unchanged;
.CW "7c ../port/edf.c"
produces nothing but format warnings.
.PP
What is missing is three things, and the third is the interesting one.
.IP 1.
.CW edf.c
is not linked.
.CW raspi3b/stubs.c
supplies six empty functions with the comment "EDF scheduler optional
\(em classic Inferno ready queue only", and every board here does the
same.  Linking the real one is a line in the mkfile and deleting the
stubs.  It must be done
.I after
stage two's ilock number is taken, not before:
.CW taslock.c
has an EDF branch in
.CW lock() ,
so the two changes touch the same path and a number that moved would
not say which one moved it.
.IP 2.
Nothing can admit a process.  Plan 9 writes
.CW admit ,
.CW period ,
.CW cost
and
.CW deadline
to
.CW /proc/ n /ctl ;
.CW port/devproc.c
carries that code and its whole
.CW ctl
body is commented out, because Inferno's process files are
.CW /prog ,
served by
.CW devprog.c ,
which has no such verbs.  They have to be written there.
.IP 3.
.B "A Dis program is not a process."
Many
.CW Prog s
share one interpreter kproc and take turns inside
.CW vmachine() 's
loop; EDF schedules
.CW Proc s.
So admitting a Limbo program to a deadline means deciding which of
these it is: give the admitted
.CW Prog
a kproc of its own, so that EDF is scheduling the thing that has the
deadline \(em which is what this kernel already does for a
.CW Prog
blocked in a system call, and is the honest answer; or admit the
interpreter kproc and schedule
.CW Prog s
within it, which gives the VM a guaranteed share and gives no
individual program anything.  The first is the one worth building and
it is not free: it means a
.CW Prog
that is admitted stops sharing the token round-robin and holds it for
its budget, which is exactly what a deadline means and exactly what
.CW acquire() /
.CW release()
were not written to express.
.PP
.B "The test that proves it."
A Limbo program admitted at a 10ms period and a 2ms cost, released by
one of this board's real timers, printing the distance between each
deadline and the moment it finished that period's work \(em while
.CW fatstress
reams the card and the ethernet runs.  A missed deadline is a number,
not an impression, and admission control that never refuses anything
has not been tested: the same test has to include a set that
.I "should not"
be admitted and check that it is not.
.PP
And the honest limit, which belongs in the same paragraph as the claim:
an admitted process cannot beat the worst interrupt-masked window,
because that window is time in which the release timer itself cannot be
taken.  Stage two's number is the ceiling on anything stage three can
promise, which is why it comes first.
.NH 2
Suggested order
.PP
.B "First, the rename that loses a file on a 32KB cluster."
It destroys kernels, it has done so twice, and until it is fixed every
cycle on this board carries the risk of ending with the card in a
reader.  It is also the cheapest thing on this list to work on now that
.CW "tests/dossrv-stress.sh card"
reproduces it in emu in seconds: write 1.5MB as
.CW k.new ,
rename it to
.CW k.img ,
open it, and find nothing there, with the rename having returned
success.
.PP
.B "Corrected 19 September 2026, and the correction matters."
That paragraph describes a failure seen once.  Sixty runs at
.CW ROUNDS=1
.CW FILES=1
never reproduced it, so the smaller sequence the step above asks for is
answered: at that size it does not fail, and the shrink is not the way
in.  What does reproduce in seconds, about one run in fifteen, is a
.I hang
with an empty log, and that hang is not
.I dossrv
at all \(em it is emu, and it is fixed; see the two sections below.  So
"reproduces it in emu in seconds" was true of the hang and not of the
rename.  And the card case it was reproduced in has the wrong geometry
anyway: the card has 512-byte clusters, not 32KB ones.
.PP
.B "Second, what the board said about it."
.CW "cat /dev/sdM0/ctl"
reports
.CW "errors 0" .
The driver never refused a write, so the data was never offered to it
\(em which rules out the SD driver and the
.CW twrite
failure path both, and points the whole question at
.CW dossrv .
.PP
.B "Third, a filesystem for the card that is not kfs."
.CW doc/efs-plan.ms
has the whole of it; what belongs here is why it sits this high and
what it does not displace.  It does not displace the rename fix: the
firmware reads the FAT partition and
.I dossrv
stays the tool for it no matter what else the card grows, so a bug that
empties a kernel there has to be fixed there.  What
.I efs
replaces is
.I kfs ,
and the case against
.I kfs
is that it is wrong for this machine twice over.  Its recovery story is
a check pass that walks the filesystem, on a board whose ordinary way
out of
.CW exit()
is the PM watchdog and whose power was pulled mid-write dozens of times
a day during bring-up.  And its I/O is the pattern an SD card handles
worst: the board reams it with the default 1KB block, two sectors, and
the free list lives inside the superblock's own buffer, so
.CW balloc
and
.CW addfree
rewrite block 1 on every allocation and every free \(em the same
kilobyte at the same address, thousands of times, in front of a
translation layer whose erase blocks are megabytes.
.I Efs
is copy on write: no metadata is edited in place, so there is no block
1, recovery is which of two superblocks checksums and has the higher
generation, and a commit is a batch of aligned whole-block writes.
.PP
It sits behind the rename bug and ahead of the peripheral work for one
practical reason rather than an architectural one: like the rename bug
and unlike everything below, none of it needs the Pi.  Milestones 1-6
are a format document, a mkfs, a dump, a server and a crash harness,
all of them run under
.I emu
against an image on the build host, which is where every
.I dossrv
bug in this port was actually found.  Only milestone 7 wants the board.
So it proceeds alongside the silicon work rather than blocking on a
slot in it.  Milestone 5 \(em mount after a write-failure injection
gives back exactly the last commit \(em is the one that decides whether
the project was worth doing; if it does not hold,
.I efs
is not better than
.I kfs
and should not replace it.
.PP
.B "Before any of it, the board has to stay up."
It wedged five times over two days, twice costing a card swap, and the
cause was not any of the four things it was believed to be \(em not the
network (it pings during the stall), not the styx server (it answers the
host), not the out-of-order RST (tcp.c closes on it), and not emu's
missing release barrier (this board's unlock does have one).  Caught
with ^\\ at the moment of the stall it is the Dis interpreter's
hand-off: thirteen processes Queueing for the VM, three Ready, and
nobody running them.  doc/raspi3b-stability-plan.ms has what was
measured, what it rules out, and the order to fix it in.  Nothing else
on this list can be worked on honestly from a machine that needs
rescuing by hand every half hour.
.PP
.B "Alongside it, FAT32 in disk/format -- DONE 19 September 2026."
It was wanted for the obvious safe experiment: a scratch FAT32 on the
card's unallocated 29GB, at the card's own geometry, where
.I dossrv
can be hammered through the real driver with the boot partition off the
table.  That experiment is now the next thing to do and nothing blocks
it.  Getting there also fixed a sizing bug at every FAT width and a
limbo bug that had broken every cast between
.CW byte
and
.CW big ,
.CW real ,
.CW string
or
.CW fix
in every program this branch compiled; both are written up above.
.PP
Then the rest, in the order it was in.
The transmit-queue fix is confirmed on the board and kernel updates
come over the network.  Next, then:
the peripheral checks that fail on silicon and pass on the models \(em
AUX, I2S, AUXSPI, SMI and the BSC slave \(em each of which is a model
this tree wrote and a part it has now met; then USB storage and the
keyboard on the board; then the
SD/Wi-Fi controller question; then DMA for SD; then the peripherals
nothing is currently attached to.
.PP
Stage one of the scheduling work used to come before all of it, and it
is done: the counters, the
.CW SCHED-LAT
check and both readings are on silicon, and the section above says what
it found.  This paragraph asked for it as though it were still ahead,
which is how it came to be recommended as the next thing to do on 19
September, six weeks after it was finished.  A plan that keeps a
completed item in the imperative will get it done twice.
.PP
.B "And it settles where I/O performance is not."
The card is slow \(em 10MB off
.CW /dev/sdM0/dos
took about 45 seconds over the styx mount, and writing 1.5MB through
.I dossrv
took 212 seconds with everything else running \(em and none of that is
the scheduler.
.CW SCHED-LAT
says a woken process gets the processor at once when what holds it is
Limbo, and the counters say the interpreter yields on every tick it is
asked to.  What holds the processor is a kproc in a C loop, which is
the one thing stage one wrote down as not preempted on purpose, and on
this board that kproc is the polled SD driver: it owns the processor
for as long as a block takes.  So the throughput item is DMA for SD and
the latency item is stage two bounding what a non-preemptible kproc may
hold, and neither of them is more scheduler work.
.PP
Stage two runs alongside the peripheral work rather than after it,
because its terms are measurements the board takes while it is doing
everything else.  Stage three is its own piece and waits for stage
two's ceiling.
.NH 1
The development loop changed: a kernel now loads over JTAG
.PP
Everything above was built through one loop: compile a kernel, write
1.9MB to the card through
.I dossrv
\(em which is itself one of the things under test \(em read it back to
verify, reboot, hope.  Three to six minutes when it worked.  Twice it
silently installed the wrong bytes, once a kernel truncated to 8192
and once one whose first 256KB were the previous kernel's, and each of
those cost an hour and a card carried to another machine.  Every
question asked of a driver cost one of these cycles.
.PP
On 21 September that loop was replaced.  A kernel built on the host
now goes into the board over JTAG and runs, without the card being
touched:
.P1
openocd -f interface/ftdi/olimex-arm-usb-tiny-h.cfg \e
        -f tools/jtag/raspi3b.cfg -c 'init; jtagrestart; resume; exit'
.P2
Twenty-eight seconds, and the class of failure where the install
silently writes the wrong bytes stops existing, because nothing is
installed.  The board it was first done to was dead at the time \(em
.CW "WILDSP type 1"
with every register zero \(em which is the case that used to mean
carrying the card to another machine.
.PP
.B "How it works, and the one thing that makes it necessary."
JTAG replaces memory; it does not recreate the architectural reset
state.  A kernel entry assumes the machine the firmware hands over,
and a halted running kernel has none of it: the MMU is on, its page
tables are live,
.CW VBAR_EL1
points at its own vectors, the TLBs are full.  Jumping straight to
.CW KTZERO
faults on the first instruction, and did.  So the pc goes to a
trampoline instead \(em
.CW jtagstub
in
.CW l.s ,
which masks exceptions, cleans the image range to the point of
coherency, turns off the MMU and caches, invalidates the TLBs, clears
.CW TTBR0/1_EL1
and
.CW VBAR_EL1 ,
and branches to
.CW KTZERO
with
.CW x0
= 0x4a544147 ("JTAG") so the kernel can tell a warm restart from a
cold boot.  That ABI is written down in
.CW tools/jtag/README .
Confirmed on the board with a hardware breakpoint at
.CW KTZERO :
it arrives, with
.CW x0
holding the magic.
.PP
.B "The trampoline must be position-independent, and the first one was not."
It is assembled at its link address and run from 0x70000, below the
load address so an image cannot overwrite the code about to enter it.
7a assembles
.CW "MOV $0x80000, R1"
as a load from a literal pool, and 7l put that pool 0x2f8c bytes past
the end of the stub; four of the stub's instructions were such loads.
Copied to 0x70000 they read 0x72f8c, which is not the constant and not
kernel memory.
.PP
Nothing in the toolchain says a word about this.  It assembles, it
links, the kernel prints
.CW "JTAG-STUB 124 bytes at 0x70000" ,
and the trampoline is scrap.
.CW $0x1005
three instructions later
.I does
assemble inline, because it fits a bare
.CW MOVZ
and 7a takes that path \(em so two constants a few instructions apart
compile two different ways and only one survives being copied.  The
board said so itself, in the crumb the next boot printed:
.P1
CRUMB previous boot: exceptions 17339, last type 1
    esr 7dd80500 elr 0000000000070000 spsr 345
.P2
17339 exceptions with
.CW elr
at 0x70000 is the old stub faulting at the trampoline, in a loop.
.CW MOVZ/MOVK
is the only form guaranteed to carry its operand in the instruction,
and
.CW tools/jtag/checkstub
now rejects any
.CW ADR ,
.CW ADRP
or literal load in the stub, and any branch leaving it, when
.CW kernel8.img
is built.
.PP
.B "The debugger installs the stub, not the kernel."
The kernel does copy it to 0x70000 at boot and says so, and that copy
was verified correct by reading it back over JTAG \(em the only check
there has ever been that its
.CW memmove
and
.CW cacheflush
do what they say.  But that copy belongs to whichever kernel is
running: against a board booted from an older card it is an older
stub, and against a kernel that wedged before
.CW jtagstubinstall
ran it is not there at all.  A debugger that needs the program it is
debugging to have installed the debugger's own entry code has the
dependency backwards, and it fails in exactly the case the debugger
exists for.  So
.CW checkstub
cuts the stub out of the linked image as
.CW jtagstub.bin
and
.CW jtagrestart
writes those bytes itself.
.PP
.B "What this does to the rest of the plan."
Every open item above is gated on asking the board a question and
getting an answer back.  The SD DMA write stall was characterised by
adding a print, rebuilding, installing and rebooting, once per
question, for a day; the thing that actually cracked it was capturing
the controller's registers at the moment of the stall, which with a
debugger is a read rather than a release cycle
.CW ( emmcregs
does exactly that).  The stale-kernel corruption is a question about
what reached the medium, and the medium is no longer in the loop at
all.  Nothing below is finished, but the cost of each attempt at it
has gone from minutes to seconds, and the failure mode where the
instrument corrupts the experiment has gone.
.PP
Two cautions, both learned the same day.
.CW load_image
over a running kernel replaces its data section with that section's
boot-time contents, so every live pointer, list and counter in it
becomes a constant from the past; the board can keep answering the
console afterwards and be thoroughly corrupt.  One such load produced
a fault whose reported faulting address,
.CW b900080152b00169 ,
is two AArch64 instruction encodings \(em a pointer read out of memory
that had been overwritten with code.  Numbers taken from a boot like
that are void.  And
.CW jtagbounce ,
which enters the trampoline without loading an image, is the way to
test the trampoline alone: it reached a banner from a board whose
console had gone silent, then panicked in
.CW poolsize
because
.CW .data
still held the previous run's pool bookkeeping.  Reaching
.CW KTZERO
is the pass condition for the trampoline; a clean boot needs the image
load, which restores
.CW .data ,
and does.
.NH 1
The SD DMA write failure is deterministic
.PP
It has been treated as an intermittent race since
.CW 72d107da
retracted a fix claimed on one pass against one failure.  It is not
intermittent.  Two independent occurrences, on the filesystem path,
were identical in every field the driver prints:
.P1
start block     30946
requested       9 blocks / 4608 bytes
DMA transferred 3 blocks / 1536 bytes
DMA remaining   6 blocks / 3072 bytes
dma cs 0x21 debug 0x4808000 ti 0xb0148
dma src 0xc3f3b640 dst 0x7e300020 (engine still active)
BEFORE: dma cs 0xa emmc interrupt 0x10 status 0x1ff0506
.P2
Same block, same three of nine, same channel state, same eMMC state
before arming, same source address.  And it reproduces on demand,
which it never has before: with
.CW dmaclearirq
0 it failed on the first write of a fresh boot, repeatedly.
.PP
Two things in that dump are new and neither had been visible before,
because before this the failure could not be provoked to order.
.IP \(bu
.B "Iwriterdy is already set before the channel is armed."
.CW BEFORE
shows
.CW "emmc interrupt 0x10" ,
bit 4, left over from the previous transfer.  The driver arms a
DMA channel against a controller that is already asserting write-ready.
.IP \(bu
.B "The channel's own CS still holds END and DREQ."
.CW "dma cs 0xa"
is the state the previous transfer left.  Nothing clears it between
transfers.
.PP
.B "The raw device cannot see any of this,"
which is why it has stayed open so long.  Raw writes have never failed
\(em 500 in-kernel transfers clean, and writes work raw at
.I dossrv 's
own transfer size \(em so a measurement pointed at
.CW /dev/sdM0/kfstest
returns zero failures and reads as "there is no problem here".  The
first version of the rate harness did exactly that and would have
reported the acknowledge as making no difference.  A test that is
exact because the term vanishes cannot see that term.
.PP
.B "The failure kills the file server, and that is the wedge."
.CW "dosfs: panic: write"
follows it, and every write to
.CW /n/dos
afterwards blocks for ever on a mount whose server is gone \(em
.CW devmnt.c
waits with no timeout, which section 3 of
.CW doc/raspi3b-stability-plan.ms
describes.  The board is not spinning when this happens:
.CW tools/jtag/where
puts cpu0 at
.CW idle+0x4 .
The kernel is fine and idle; it is the namespace that is dead.  So
"the board wedged" and "the DMA write failed" have been one event, at
least this time.
.PP
The rate measurement this run was meant to produce is still owed.  It
was lost a fifth time, to a harness bug rather than to the board: five
writes were scored as failures when the server had already panicked
and they never ran, because
.CW "screen -X scrollback 0"
empties the history and not the display, so the first failure's report
was still on screen for all of them.  All three counting bugs in that
script have been the same bug \(em reading a console buffer for
evidence of an event without first establishing that anything in the
buffer is new.
.NH 2
Settled: the eMMC interrupt acknowledge is not the fix
.PP
.CW 72d107da
retracted a DMA fix claimed on one pass against one failure, and said
what the honest form would be: N transfers with the acknowledge on and
N with it off.  That measurement was owed for two days and lost five
times, four of them to a wedged board and once to a harness that
scored writes which never ran.
.PP
It was also the wrong instrument.  A rate answers a question about a
random failure, and this failure is deterministic.  So:
.CW tools/jtag/dmaab.sh
reboots the board with
.CW ^R ,
sets
.CW dmaclearirq
one way, does one write, keeps the dump; reboots, sets it the other
way, does one write; and diffs the two.  Two boots, four minutes.
.PP
.B "Both arms failed, and the dumps differ in three lines."
Two are incidental \(em the start block and the DMA source address,
both of which follow from where the file landed.  The third is the
only thing the switch controls:
.P1
off:  BEFORE: dma cs 0xa emmc interrupt 0x10 status 0x1ff0506
on:   BEFORE: dma cs 0xa emmc interrupt 0x00 status 0x1ff0506
.P2
The switch does exactly what it claims.
.CW Iwriterdy
is set when the channel is armed with it off and clear with it on, and
the transfer stalls in precisely the same place either way \(em three
blocks of nine,
.CW "cs 0x21" ,
.CW "ti 0xb0148" ,
.CW "blksizecnt 0x70200" ,
the same registers afterwards.  The stale interrupt is not what the
stall is about.
.PP
That is as clean a negative as this port has produced: the mechanism
was real, the intervention demonstrably worked, and the outcome did
not move.  It is worth more than the rate would have been, because a
rate could only ever have said "about as often either way".
.PP
.B "What is still uncleared, identically in both arms, is the DMA
.B "channel's own CS."
.CW "dma cs 0xa"
before arming is END and DREQ left by the previous transfer, and
nothing clears it between transfers.  That is the next thing to
suspect and it is now cheap to test the same way \(em which is the
real change here.  The question that took two days to fail to answer
now costs four minutes to answer properly.
.PP
Three harness bugs were found getting there, and all three were the
same bug: reading the console for evidence of an event without first
establishing that anything in the buffer was new.  Counting across a
saturated scrollback compared two sliding windows; clearing the
history left the display, so one failure report was scored four more
times; and both of those were fixed by the wrong thing before the
right one, which is to type a marker and read only what follows it.
A fourth was an ordering mistake with the same shape: the first run
set
.CW dma
before
.CW dmaclearirq ,
so the failure fired between them and arm 1's dump was taken with the
acknowledge still at its default \(em the arm reported neither a
completion nor a failure, and the pair read as "only the off arm
failed", which is the retracted claim all over again.
.NH 2
Two negatives, one non-result, and a correction
.PP
.B "The correction first, because it changes how the other two read."
The section above called the DMA write failure deterministic, on the
strength of dumps that matched in every field across several
occurrences.  It is not.  On 21 September an arm completed with no
failure at all \(em the first write in the whole sequence to do so
\(em so the base rate is high but not one.
.PP
That does not disturb the two negatives, because of their shape.
.CW dmaclearirq
and
.CW dmareset
were each tested with one boot per arm, and in both experiments
.I both
arms failed.  An intervention that prevents the stall cannot be
present while the stall happens, so a single failure with the
intervention demonstrably active disproves "this fixes it" whatever
the base rate is.  Both dumps show the intervention active
\(em
.CW "emmc interrupt 0x00"
against
.CW 0x10 ,
.CW "dma cs 0x8"
against
.CW 0xa
\(em and the stall unchanged in every other field.  Those stand.
.PP
What the correction does disturb is the other direction.  An arm that
.I passes
says nothing on one boot, because a pass is what a high-but-not-one
base rate produces sometimes anyway.  So a one-sided result is not a
result, and
.CW dmaab.sh
now says so in its own output rather than leaving it to be read
charitably.
.NH 2
The interrupt-enable question is untested, not answered
.PP
The best remaining hypothesis was the one
.CW tools/jtag/README
wrote down the first time registers were ever read over JTAG: the
controller may gate its DMA request on
.CW irpt_en
rather than on the status, and this driver leaves that register at 0
through a transfer.  It fits what the failure looks like \(em the
engine waiting correctly with DREQ clear, the controller holding
.CW Iwriterdy
set and not asking.
.PP
.CW dmairqen
sets
.CW Ireadrdy|Iwriterdy
in
.CW Rirpten
for the transfer.  The arm with it on failed, which would read as a
third clean negative.  It is not one, and the dump says so:
.P1
BEFORE: dma cs 0xa emmc interrupt 0x10 status 0x1ff0506 irpten 0x0
.P2
.CW irpten
reads 0 at the moment the channel is armed, three instructions after
the register was written.  The write is being dropped.
.CW Rstatus
is
.CW 0x1ff0506
there, which has
.CW Sdatinhibit
set \(em the command is issued and the data circuit is live \(em and
this controller appears not to accept that register then.  The enable
has to be set before the command, not between the command and the
transfer.
.PP
That the dump could say this at all is the reason the
.CW BEFORE
line prints
.CW irpten .
An intervention assumed to have happened is not an experiment, and
this one would have been filed as an answer.
.NH 1
Plan: how to fix the SD DMA write stall
.PP
Ordered by value rather than by curiosity.  The first item is worth
doing whatever the cause turns out to be, and the second is what makes
every item after it cheap.
.NH 2
1.  Make the failure survivable, before making it rare
.PP
The driver already means to do this \(em the comment at the fallback
says a DMA path being wrong "is a reason to stop using it, not a
reason to lose the transfer" \(em and it does not work.  What actually
happens:
.P1
emmc: DMA WRITE FAILURE ...
emmc: write block 30946 failed: interrupt 0x10 status 0x1ef0106
emmc: write block 30954 failed: interrupt 0x2 status 0x1ff0000
dosfs: panic: write
.P2
.CW bioerror()
runs, DMA is switched off, the block is retried in PIO \(em and the
retry fails too, eight blocks later the ninth fails as well, the write
returns short, and
.I dossrv
panics.  After that every write to
.CW /n/dos
blocks for ever on a mount whose server is gone, which is the "hung
board" of the last three days.  The kernel is fine throughout:
.CW tools/jtag/where
puts cpu0 at
.CW idle+0x4 .
.PP
So the abort is not putting the controller and the card back into a
state a retry can use.  It sends CMD12, resets the command and data
circuits and polls CMD13 for READY_FOR_DATA, and none of those steps
is checked for having worked.  The work is to check each one and say
which fails:
.IP \(bu
Did CMD12 complete, or did it go into a controller with
.CW Sdatinhibit
still set and get swallowed the way the
.CW Rirpten
write did?
.IP \(bu
Did the data-circuit reset finish, or did the timeout loop expire?
.IP \(bu
Did the card come back to TRAN, and how long did it take?
.PP
And if the abort cannot be completed, stop retrying that block and
fall back for the whole rest of the transfer, so the caller always
gets its bytes.  A driver that cannot recover from its own DMA failure
is worse than one with no DMA at all, and this is independent of why
the stall happens.
.NH 2
2.  Get a reproducer off the filesystem path
.PP
Every experiment so far has cost a boot, a
.I dossrv
panic and a
.CW ^R ,
because the only way to provoke the failure has been to write a file.
.PP
.B "The reason it has never been reproduced raw is probably in the dumps,"
and it is the one field nobody was reading.  Seven failures collected
over three days, and every one of them:
.P1
dma src 0xc3bb6640   0xc3f2e640   0xc3f3b640   0xc3f84640
     0xc3f87640   0xc3f9b640   0xc3fb2640
.P2
Seven for seven at page offset
.CW 0x640 .
That is
.I dossrv 's
buffer \(em 64-byte aligned, which is one cache line, but not
512-aligned and not page-aligned.  Raw
.CW dd
hands the driver something else entirely, and raw has never failed.
.PP
.B "And the sweep that supposedly ruled size out did not."
.CW tools/jtag/dmasizes.sh
tried 1, 2, 3, 4, 8, 9 and 16 blocks and found nothing \(em against
.CW /dev/sdM0/kfstest ,
the raw device, which is the path that never fails.  It could only
ever have returned "clean".  Size, repetition, sustained traffic and
mixed direction were all "ruled out" the same way and none of them
is.
.PP
So: a ctl command that does one 9-block DMA write, in the kernel, from
a buffer at a chosen page offset, to a scratch block.  Then two
questions, neither of which needs a file server:
.IP 1.
Offset
.CW 0x640 ,
9 blocks.  Does it fail?
.IP 2.
Offset 0, 9 blocks.  Does it fail?
.PP
If the first fails and the second does not, the trigger is the buffer
and the fix is a bounce buffer for anything not suitably aligned \(em
and the whole investigation moves to a path where a failure costs
nothing and can be repeated fifty times in one boot.  If both fail,
the filesystem is not special and the raw sweep was simply asking the
wrong sizes.  If neither fails, the buffer is not it either, and what
is left is the surrounding command pattern.
.NH 2
3.  Ask the interrupt-enable question properly
.PP
Untested, not disproved: the write to
.CW Rirpten
is dropped because it happens between the command and the transfer,
with
.CW Sdatinhibit
set.  Move it before the command is issued.  The
.CW BEFORE
line prints
.CW irpten
now, so the arm shows whether the intervention took \(em and no
conclusion may be drawn from an arm whose dump says
.CW "irpten 0x0" .
.PP
This is the last hypothesis that fits the shape of the failure without
inventing anything: the engine is waiting correctly with DREQ clear,
and the controller is holding
.CW Iwriterdy
set, saying it has room, while not asking.
.NH 2
4.  Repeats, because the base rate is not one
.PP
One boot per arm was enough to disprove two fixes, because in both
experiments both arms failed and a fix cannot be active while the
thing it fixes happens.  It is not enough to confirm anything: an arm
that passes is what a high-but-not-one base rate produces sometimes
anyway.  Once item 2 gives an in-kernel reproducer, N is free \(em
fifty transfers in one boot, counted, with the intervention shown
active in the dump.
.NH 2
What the evidence says the answer will look like
.PP
At the stall the engine is ACTIVE with DREQ_STOPS_DMA set and the DREQ
bit clear: it is waiting, correctly, for a request that is not coming.
The controller has retired two blocks to the card, holds one in its
buffer,
.CW blksizecnt
says seven of nine remain, its status has
.CW Swritetransfer
set and its interrupt register has
.CW Iwriterdy
set.  It has room, it says so in two registers, and it is not raising
the line.  Either it stops asserting DREQ when it should not, or it is
waiting for something this driver never does \(em and item 3 is the
only named candidate for the second.
.NH 2
Where the DMA stall investigation actually stands
.PP
.B "Eliminated, each with the intervention shown active in the dump or
.B "the test shown running:"
the stale eMMC interrupt
.CW ( dmaclearirq :
.CW "interrupt 0x00"
against
.CW 0x10 ,
stall unchanged); stale DMA channel state
.CW ( dmareset :
.CW "cs 0x8"
against
.CW 0xa ,
stall unchanged); the source buffer's page offset (50 clean at
.CW 0x640 ,
the offset every recorded failure has); direction alternation (500
alternating 9-block transfers clean); and the exact shape
.I dossrv
uses, a single-block read followed by a nine-block write (100 clean).
.PP
.B "The in-kernel path does not fail at all."
Five hundred transfers, a hundred, fifty, at two page offsets, in
three patterns \(em every one clean.  Through
.I dossrv
the same card fails about two writes in three.  So the trigger is not
the shape of a transfer, and five successive guesses at what else
might differ have all been wrong.
.NH 2
What biotrace shows, and the lead it dissolves
.PP
.CW "echo biotrace 1 >/dev/sdM0/ctl"
prints every
.CW emmcbio
call.  Over 310 calls during writes through
.I dossrv :
.P1
bio w nb 9 bno 53644 buf 0x3f89000 pid 20
bio r nb 9 bno 53671 buf 0x3f89000 pid 17
bio w nb 9 bno 53671 buf 0x3f89000 pid 17
bio r nb 9 bno 53680 buf 0x3f89000 pid 15
.P2
Every call is nine blocks, every one uses the same buffer, and that
buffer is
.B page-aligned .
Three different processes issue them, read-modify-write, interleaved.
.PP
.B "Which means the 0x640 lead was arithmetic, not alignment."
Every recorded failure reports
.CW "dma src"
ending in
.CW 0x640 ,
and that was written up as
.I dossrv 's
buffer being 64-byte but not 512-byte aligned.  The trace says the
buffer is page-aligned, and 0x640 is 1600 bytes, which is not a
multiple of 512 and so cannot be a page-aligned buffer plus any whole
number of blocks.  The likely reading is that
.CW dma
.CW src
is the engine's
.I current
source pointer, read after the stall: 1536 bytes delivered
.CW ( 0x600 ,
the three blocks the dump also reports) plus one 64-byte burst the
engine has read ahead into its own FIFO and not yet handed over.  That
is consistent with every failure and with the page-offset test finding
nothing, but it has not been confirmed by matching a traced buffer to
a failure in the same run \(em the attempt to do so read an older
failure out of the scrollback, which is the fourth time that buffer
has produced a wrong answer here.
.NH 2
What is left
.PP
.B "Concurrency."
It is the one difference between the two paths that has not been
tested: the trace shows three processes interleaving block I/O, and
.CW dmatest
is a single call from a single process with nothing else running.
.IP 1.
Confirm the source-pointer reading by capturing a failure and its own
.CW bio
line in one marked window, rather than grepping a saturated buffer.
If
.CW "src == buf + 0x640"
then the alignment lead is closed for good and the 64-byte read-ahead
is a fact about the engine worth knowing.
.IP 2.
Run block I/O from two processes at once against the raw device and
see whether that alone reproduces it.  If it does, the investigation
moves to what
.CW emmcbio 's
.CW qlock
does and does not cover \(em it serialises calls, but the DMA channel
and the controller are global and the abort path is the only place
anything is reset.
.IP 3.
Only then the interrupt-enable question, which is still untested: the
write to
.CW Rirpten
was being dropped between the command and the transfer and has been
moved ahead of the command, but no run since has produced a failure
with
.CW dmairqen
on to show whether it now takes.
.NH 2
The stale kernel is live, and KUPDATE-VERIFY cannot see it
.PP
Three installs in a row reported
.P1
KUPDATE fetched 1923672 bytes
KUPDATE-VERIFY 1923672 bytes read back identical
KUPDATE-OK 1923672 bytes installed
.P2
and the board rebooted into the previous kernel every time \(em
checked by build stamp, not by size, because two builds differing only
in a comment came out the same length.  Then, from the board:
.P1
cmp /n/dos/kernel8.img /n/remote/os/inferno/raspi3b/kernel8.img
/n/dos/kernel8.img /n/remote/...: differ: char 42
.P2
.B "The file on the card is not the file that was fetched,"
and the verify that had just called them identical read it back
through the same
.I dossrv
that wrote it.  That is the blind instrument this document warns
about, in the one place where it costs the most: the mechanism whose
entire purpose is to avoid a bad kernel reaching the card is the one
that cannot tell when one has.
.PP
This also explains a day of confusion.  Between installs nothing about
the board changed, so experiments that looked like they were testing a
new kernel were testing the old one, and the negative results from
those runs are worth nothing.  A build stamp read out of the image
with
.CW ksyms
and matched against the boot banner is now the only thing
.CW install.sh
believes.
.PP
.B "What to do about it."
.CW kuverify
reads back through the file server.  It has to read through something
else \(em the raw partition under the file, or a reopened
.I dossrv
\(em or the check is a formality.  The cheap version is to compare
against the host over the styx mount, which is what
.CW cmp
just did and what caught this; the honest version is to read the
blocks the FAT says the file occupies and compare those, which is the
only form that sees the medium.
.PP
It sits above the DMA work now.  Every kernel change under
investigation has to reach the board to be tested, and at the moment
they do not reliably arrive.
.NH 2
Correction: the stale kernel was not reproduced, and a sixth candidate is out
.PP
.B "The dirty buffer is not the trigger."
.CW devsd
will not hand the engine a Dis process's buffer directly, so it
.CW sdmalloc s
one and
.CW memmove s
into it for every call \(em the engine always reads lines the CPU has
just written, where
.CW dmatest
handed over the same clean lines a thousand times.  With the engine's
64-byte read-ahead being exactly one cache line, that was worth
asking.  Two hundred transfers from a buffer re-dirtied before every
one of them are as clean as two hundred from a buffer left alone.
Sixth candidate eliminated.
.PP
.B "And the section above overstates what was seen."
It says the stale kernel is live, on three installs that reported
success while the board kept booting the previous kernel, and a
.CW cmp
saying the card's file differed from its source at byte 42.  The board
has since booted the build those installs were carrying.  So they were
landing, and what went wrong was timing: kupdate starts some minutes
after boot, the reboots checking on it kept arriving first, and the
.CW cmp
was most likely taken while kupdate was part way through writing.
.PP
.B "What survives that correction, and what does not."
The reasoning about
.CW fatcheck
stands on its own: it ran kupdate's 1.9MB write concurrently with
.CW fatwrite() 's
1.5MB one, through a single
.I dossrv ,
and the 14-of-57-chunks corruption recorded earlier in this document
is real and was found the hard way.  Removing the second writer is
right whether or not it was the cause today.
.CW kuverify
reading back through the server that just wrote is a blind check,
also independently.  But "reproduced today" was wrong, and the three
failed installs are explained by a race with kupdate's schedule rather
than by corruption.
.PP
The general fault is the one this document keeps recording: a
conclusion drawn from a console buffer without establishing that what
was read belonged to the event being asked about.  That is now four
times.
.NH 2
Not timing either, and a note on how that was nearly concluded
.PP
One run with
.CW biotrace
on \(em a console print per block-device call, milliseconds each, on
every transfer \(em produced no failure in 160 transfers, where the
identical concurrent pair without it had just failed.  That looks like
a timing sensitivity and was written down as one.
.PP
Repeated three times each way it is nothing:
.P1
biotrace 1:  3 of 3 runs had a failure
biotrace 0:  2 of 3 runs had a failure
.P2
The one clean run was the base rate not firing.  A 50us delay before
arming the channel
.CW ( dmadelay )
is the same story: 1 of 3 against 2 of 3, which at this n is not a
difference.  Seventh candidate out, and the only reason it did not
join the plan as a finding is that it was repeated before it was
believed.
.PP
.B "That is three conclusions in one session drawn from a single run,"
and
.CW dmaab.sh
prints "ONE pass each; say so, do not conclude" in its own output
precisely because of the first one.  The rule that survives: an arm
that fails disproves a fix whatever the base rate, because a fix
cannot be active while the thing it fixes happens; an arm that passes
says nothing until it has been repeated.
.NH 2
What is actually known about the trigger
.PP
.B "Concurrency is the only thing that has ever changed the rate."
Two processes writing the raw device at
.CW bs=4608
fail in two or three runs of three.  One process writing the same
blocks, the same sizes, the same patterns, through the kernel, does
not fail in over a thousand transfers \(em and in a run where a
.I dmatest
loop and a background
.CW dd
were going at once, the
.CW dd
failed and the
.I dmatest
did not.
.PP
So the failing path is
.CW devsd 's,
and a second process raises the rate.  Seven things have been ruled
out with the intervention shown active: the stale eMMC interrupt,
stale DMA channel state, the buffer's page offset, direction
alternation,
.I dossrv 's
read-then-write shape, a buffer the CPU has just dirtied, and delay.
.PP
What has not been looked at is what
.CW devsd
does around the call that
.CW dmatest
does not: it holds
.CW qlock(&unit->ctl)
across the whole of
.CW sdbio ,
allocates and frees a transfer buffer per call, and copies into it.
The allocation is the one with a mechanism behind it \(em two
processes allocating and freeing transfer buffers around a DMA the
engine is still reading from is a shape worth checking, and before the
channel reset landed, a stalled engine stayed ACTIVE while
.CW sdbio
went on to free the buffer underneath it.
.NH 2
The stale kernel, measured from outside the board at last
.PP
It bricked the board.  The card came out, went into a reader, and for
the first time the file could be compared against something other than
the server that wrote it:
.P1
card kernel8.img  1923688 bytes
card kernel8.bak  1923672 bytes
32KB chunks compared: 59
  identical to the PREVIOUS kernel: 6
  differing (actually new):        53
  first differing byte at 0x34000 (212992)
.P2
.B "The first 208KB of the installed kernel are the previous kernel's
.B "bytes,"
and everything after it is the new one.  Old entry code, new body,
which is why it did not boot.  That is the same signature as the
earlier occurrence recorded in this document \(em "14 of its 57 32KB
chunks, the first 448KB and one more" \(em and it is now a
measurement rather than an inference, because nothing in the path
between the card and the comparison belonged to the board.
.PP
.B "An earlier section in this document retracts this finding.  That
.B "retraction was wrong."
It reasoned that three installs reporting success while the board
booted the old kernel were a race with kupdate's schedule, because the
board later came up on one of those builds.  It did come up on one of
them; that did not make the others sound.  The retraction was drawn
from the same kind of evidence as the claim it withdrew, and the way
to tell them apart existed the whole time and was not used: take the
card out.
.PP
.B "The mechanism is confirmed by which kernel was running."
The board that produced this image was running a build whose
.CW fatcheck
still did
.CW "spawn kupdate()"
followed immediately by
.CW fatwrite() :
1.9MB and 1.5MB written concurrently, through one
.I dossrv ,
to two files.  The fix that removes the second writer had been
committed but never reached the board \(em which is the whole
difficulty in one sentence, since the mechanism that installs kernels
is the mechanism that was broken.
.PP
The card was repaired by writing the image to it directly from the
host and comparing SHA-256 both ways: 1923720 bytes, identical.  That
is the check
.CW kuverify
cannot make and should be made to approximate \(em by reading the
blocks the FAT says the file occupies rather than reading the file.
.NH 2
Eighth out: allocating the buffer per transfer is not it either
.PP
.CW sdbio
will only hand the engine the caller's own buffer when it is a
page-aligned kernel address, which a Dis process's buffer is not, so
it takes one from
.CW sdmalloc
for every write and returns it afterwards.
.CW dmatest
had always held one buffer for a whole run.  That was the last
structural difference between the two paths, and it had a mechanism
behind it: two processes taking and returning page-aligned transfer
buffers around a DMA the engine is reading from.
.P1
emmc: dmatest 200 transfers of 9 blocks, all clean (a fresh buffer each time)
.P2
The parenthesis is deliberate.  The first run of this test reported
"all clean" with a banner that said "re-dirtied each time", which is
what the previous mode prints, so the output did not show whether the
allocation under test had happened at all.  Of the eight things now
eliminated, the ones worth anything are the ones where the dump showed
the intervention active.
.PP
.B "And in the same window, something else failed."
A
.CW "DMA WRITE FAILURE"
landed while those 200 transfers were clean, from a
.I devsd
writer running alongside.  That is the third time a
.CW dmatest
loop has come through untouched while a concurrent
.I devsd
transfer stalled, and it is the most reliable thing known about the
trigger: it is not the transfer, it is the path.
.NH 2
What Linux does with this controller, checked against the source
.PP
.CW drivers/mmc/host/sdhci-iproc.c ,
fetched and read rather than recalled.  The Pi 3's Arasan is
.CW "brcm,bcm2835-sdhci" ,
which maps to
.CW bcm2835_data :
.P1
static const struct sdhci_iproc_data bcm2835_data = {
        .pdata = &sdhci_bcm2835_pltfm_data,
        .caps = ((0x1 << SDHCI_MAX_BLOCK_SHIFT) & SDHCI_MAX_BLOCK_MASK) |
                SDHCI_CAN_VDD_330 |
                SDHCI_CAN_DO_HISPD,
        .caps1 = SDHCI_DRIVER_TYPE_A | SDHCI_DRIVER_TYPE_C,
        .missing_caps = true,
};
.P2
Two things follow, and both matter here.
.IP \(bu
.B "The capabilities register really is broken."
.CW "missing_caps = true"
makes the driver ignore the hardware register and supply those values
itself.  This driver's own note \(em that
.CW caps
reads
.CW "0x0 0x0"
on the board \(em was not a misread and was not a mistake in the
initialisation order.  Linux found the same thing and works around it.
.IP \(bu
.B "Linux does not DMA this controller at all."
The caps it supplies contain no
.CW SDHCI_CAN_DO_SDMA
and no
.CW SDHCI_CAN_DO_ADMA2 ;
the entries in that file which do claim them are the Cygnus and iProc
parts, not the Pi.  With neither capability advertised, sdhci runs the
Pi 3's eMMC in PIO.
.PP
.B "And the external DMA engine is what it uses on the OTHER controller."
.CW drivers/mmc/host/bcm2835-sdhost.c
pulls in
.CW <linux/dmaengine.h>
and takes a channel for SDHOST.  So the two arrangements Linux ships
are: Arasan by PIO, SDHOST by external DMA.
.PP
.B "This driver does neither."
It drives the Arasan with the external engine on DREQ 11, which is a
pairing no production driver here uses.  The hardware nominally
provides that DREQ, and reads work and are byte-correct, so it is not
obviously wrong \(em but the stall has now survived eight eliminations
in a configuration with no precedent, and that is worth weighing
before a ninth.
.PP
Three ways forward, and the choice is a judgement about what the board
is for rather than another experiment:
.IP 1.
.B "Keep the Arasan on PIO,"
as Linux does, and stop treating DMA here as a goal.  The stall
becomes irrelevant rather than fixed.  Throughput stays where PIO puts
it.
.IP 2.
.B "Put the DMA work on SDHOST" ,
which is the controller Linux drives with this same engine, and which
already has a driver in
.CW sdhostbcm.c .
That is the arrangement with a working precedent.
.IP 3.
.B "Continue on the Arasan" ,
with the interrupt-acknowledgement hypothesis as the current
candidate.  Worth doing only if DMA on this particular controller is
itself the point.
.NH 1
TODO: the Arasan DMA write stall
.PP
Parked, not abandoned, and parked for a reason: Linux runs this
controller in PIO and uses the external engine on SDHOST instead, so
the stall lives in a configuration with no production precedent.  The
board loses nothing by leaving it \(em
.CW emmcdma
is 0 by default, the PIO path is what every transfer takes, and a
stall is no longer fatal since the channel reset landed.
.PP
.B "What is known, so none of it has to be found again."
The failure is a nine-block DMA write that stops with the engine
ACTIVE and DREQ_STOPS_DMA set, the DREQ line clear, and the controller
still reporting room in its status.
.CW blksizecnt
says the controller holds exactly one block whichever position it
stops at \(em three blocks in, twenty-eight times, and eight blocks in
once \(em so it is flow control behaving correctly and never
resuming.
.CW "dma src"
is the engine's live source pointer, delivered plus one 64-byte burst
of read-ahead, not a property of the buffer.
.PP
.B "Eight things are eliminated, each with the intervention shown
.B "active in the dump or the test shown running:"
the stale eMMC interrupt
.CW ( dmaclearirq ),
stale DMA channel state
.CW ( dmareset ),
the source buffer's page offset, direction alternation,
.I dossrv 's
single-block-read-then-nine-block-write shape, a buffer the CPU has
just dirtied, delay
.CW ( dmadelay
and a console print per call), and allocating the buffer per transfer
as
.CW sdbio
does.  In-kernel transfers do not fail in over a thousand attempts;
.I devsd 's
do, two or three runs in three, and in one run a
.CW dmatest
loop came through clean while a concurrent
.I devsd
transfer stalled beside it.
.PP
.B "The hypothesis to test if it resumes, and the switch to test it with."
.CW Iwriterdy
is a latched status bit, cleared only by writing it back, and nothing
clears it during a DMA transfer \(em the driver acknowledges it only
in the PIO path inside
.CW awaitirq .
If the controller re-asserts DREQ when its buffer goes from full to
having room, and that re-assertion needs the latched bit acknowledged,
the first time the card goes busy long enough for the buffer to fill
DREQ drops and never returns.  That also explains why
.CW dmaclearirq
changed nothing: it clears the register once BEFORE arming, and the
re-assertion in question happens three blocks in.
.PP
.CW "echo dmaunstick 1"
is the experiment, already in the driver and off.  At the stall it
acknowledges
.CW Iwriterdy
and watches the engine's live
.CW TXFR_LEN
.CW ( dmachanleft() ).
If the remaining count moves, the mechanism is proved and the fix is
to acknowledge during the transfer rather than after it.  If it does
not, the hypothesis is dead and the dump says so.
.PP
.B "And one rule for whoever picks it up."
Of the eight eliminations the only ones worth anything are those where
the dump showed the intervention active; three conclusions in one
session were drawn from a single run and all three were wrong.  A
failing arm disproves a fix whatever the base rate, because a fix
cannot be active while the thing it fixes happens.  A passing arm says
nothing until it is repeated.
.NH 2
TODO, revised: there IS a precedent, and it does the opposite of what was planned
.PP
The claim above that no production driver pairs the Arasan with the
external engine is too strong.
.CW drivers/mmc/host/bcm2835-mmc.c
in the Raspberry Pi kernel \(em
.CW "brcm,bcm2835-mmc" ,
a different binding from
.CW "brcm,bcm2835-sdhci"
\(em takes a dmaengine channel and drives this controller with it.  It
is also the path with field reports of DMA hangs, and of people
switching to the SDHCI driver to get a stable interface, which is its
own kind of corroboration.
.PP
.B "What it does that this driver does not."
Before every transfer it sets the interrupt registers according to
whether that transfer is DMA:
.P1
u32 pio_irqs = SDHCI_INT_DATA_AVAIL | SDHCI_INT_SPACE_AVAIL;
u32 dma_irqs = SDHCI_INT_DMA_END | SDHCI_INT_ADMA_ERROR;

if (host->use_dma)
        host->ier = (host->ier & ~pio_irqs) | dma_irqs;
else
        host->ier = (host->ier & ~dma_irqs) | pio_irqs;

writel(host->ier, SDHCI_INT_ENABLE);       /* 0x34 */
writel(host->ier, SDHCI_SIGNAL_ENABLE);    /* 0x38 */
.P2
.CW SDHCI_INT_SPACE_AVAIL
is write-buffer-ready, which is
.CW Iwriterdy
here, and
.CW SDHCI_INT_DATA_AVAIL
is
.CW Ireadrdy .
For a DMA transfer it clears both of them from
.B both
.CW SDHCI_INT_ENABLE
(0x34, this driver's
.CW Rirptmask )
and
.CW SDHCI_SIGNAL_ENABLE
(0x38,
.CW Rirpten ).
.PP
This driver sets
.CW irpt_mask
to
.CW Iall ,
.CW 0x017f7137 ,
which has both bits in it, and leaves it there for the whole of a DMA
transfer.  The failure dumps say so:
.CW "irpt_mask 0x017f7137" ,
and
.CW Iwriterdy
duly latched in the status register before the channel is even armed.
.PP
.B "So the hypothesis written into the TODO above is backwards."
It proposed setting
.CW Ireadrdy|Iwriterdy
in
.CW Rirpten
.CW ( dmairqen ),
on the reasoning that the DREQ might be gated on the enable.  The
production driver clears them, from the mask as well.  What
.CW dmairqen
would have tested is the opposite of what works elsewhere, and the
.CW dmaunstick
probe \(em acknowledging the latched bit at the stall \(em is aimed at
a bit that driver arranges never to latch in the first place.
.PP
.B "The experiment to run first if this resumes"
is therefore: clear
.CW Ireadrdy|Iwriterdy
from
.CW Rirptmask
(and
.CW Rirpten )
for the duration of a DMA transfer and restore them after, exactly as
.CW bcm2835_mmc_set_transfer_irqs
does.  It is a few lines, it has a production precedent on this
controller, and it is the only proposed change so far that is a
difference from a driver known to work rather than a guess about the
hardware.
.NH 2
SDHOST: the DMA is written, and it sits on a data path that does not work
.PP
.B "sdhostbcm.c was never in the kernel."
The board config listed
.CW sdemmcbcm
and not
.CW sdhostbcm ,
so the file had no
.CW .7
and had never been through the compiler at all.  A build after editing
it reported no errors because nothing compiled it \(em which is the
failure this port already has a note about, grepping build output for
a filename rather than for diagnostics.  It is in the config now,
compiles clean, and probes:
.P1
sdhost: card rca 0x1234 block 30228480 sectors, core clock 250000000 Hz
sdhost dma 0 dreq 13
.P2
Same card, same capacity the Arasan reports, and the DMA switch is
live.
.PP
.B "The data path fails in both directions, with DMA off."
.P1
dd -of /dev/sdN0/data -bs 4608 ... dma 1
  sdhost: write block 4999996 failed: sdhsts 0x1 sdcmd 0x800d sdedm 0x10803
dd -of /dev/sdN0/data -bs 4608 ... dma 0
  sdhost: write block 4999995 failed: sdhsts 0x1 sdcmd 0x800d sdedm 0x10803
dd -if /dev/sdN0/data ...          dma 0
  sdhost: read  block 0       failed: sdhsts 0x1 sdcmd 0x800d sdedm 0x10803
.P2
Identical every time, and the PIO control is what matters: this is not
the DMA path.  It is also not the data phase.
.CW "sdcmd 0x800d"
is NEW_FLAG still set on command
.B 13 ,
SEND_STATUS \(em the
.CW cardready()
poll at the top of the transfer loop, which never completes, before
any data command is issued.
.CW sdedm
reads FSM 3, WRITEDATA, on a read as well as a write, which is another
sign the controller is not where the driver thinks it is.
.PP
So the identification path works on real silicon and the transfer path
has never run there.  That is not surprising \(em the driver was
written against QEMU and then left out of the kernel \(em but it means
the DMA work cannot be assessed until CMD13 completes.
.PP
.B "Next, in order."
Find why
.CW cardready() 's
CMD13 leaves NEW_FLAG set.  The identification sequence issues
commands successfully, so the difference is in what the transfer loop
does before it \(em block count and length registers written while the
previous command is still pending is the first thing to look at, since
.CW SDHBCT
and
.CW SDHBLC
are set immediately before
.CW cardready() .
Only then is there a PIO baseline to measure DMA against.
.NH 2
SDHOST PIO: one real bug fixed, and where it stops now
.PP
.B "Fixed: the status poll was issued with the block registers armed."
.CW SDHBCT
and
.CW SDHBLC
are how this controller is told that the next command carries a data
phase.  The transfer loop set them and then called
.CW cardready() ,
which issues CMD13 \(em a command with no data phase.  The controller
waited for a phase that never came and
.CW NEW_FLAG
never cleared, so every transfer failed before any data command was
issued at all:
.P1
sdhost: read block 0 failed: sdhsts 0x1 sdcmd 0x800d sdedm 0x10803
.P2
.CW 0x800d
is
.CW NEW_FLAG
still set on command 13, with the FSM in WRITEDATA on a read.  Linux's
.CW bcm2835-sdhost
sets those registers from
.CW prepare_data() ,
which runs only for commands that carry data.  Two other paths in this
same file already polled before arming; only the transfer loop had it
backwards.
.PP
Moving the poll ahead of the registers changes the failure completely,
which is what says it was a real bug:
.P1
before:  sdhsts 0x1  sdcmd 0x800d  sdedm 0x10803
after:   sdhsts 0x0  sdcmd 0x51    sdedm 0x10801
.P2
.CW 0x51
is CMD17 with
.CW READ_CMD
set and
.CW NEW_FLAG
clear: the command was issued and completed, with no error.
.PP
.B "Where it stops now: the command completes and no data phase starts."
.CW sdedm
reads FSM 1, DATAMODE, where a read should take it to 2, READDATA, and
.CW sdhsts
is 0 \(em no data, no error.  The block registers are armed before the
command, the read flag is set, the card was in TRAN when asked.
Setting
.CW "bytemode 1" ,
which switches to the byte-per-read loop written for real silicon,
makes no difference: the same
.CW fifodata()
wait times out, so it is not the loop variant.
.PP
So the controller accepts a read command and declines to start the
transfer.  That is a much narrower question than the one this started
with, and it is where the next session picks up.  Worth checking
first: whether anything between
.CW cardready()
and
.CW sdcmdstart()
disturbs the armed registers, and what
.CW SDHCFG
needs beyond
.CW Cfgslowcard
\(em it currently reads
.CW 0x8 ,
and Linux sets rather more than that.
.NH 2
The unstick probe: acknowledging the interrupt does not release the transfer
.PP
The hypothesis was that
.CW Iwriterdy
is latched, that nothing clears it during a DMA transfer, and that the
controller might only re-assert DREQ once it is acknowledged.  It was
the best remaining candidate and the reason the dig was worth one more
build.  Run with the probe armed and the stall provoked by two
concurrent writers:
.P1
emmc: DMA WRITE FAILURE
    DMA transferred 3 blocks / 1536 bytes
    DMA remaining   6 blocks / 3072 bytes
emmc: UNSTICK ack Iwriterdy: remaining 3072 -> 3072 after 20100 us,
      cs 0x21 (no change)
.P2
.CW Rinterrupt
was written with
.CW Iwriterdy ,
and the engine's live
.CW TXFR_LEN
was then read every 100us for twenty milliseconds.  It did not move by
one byte, and
.CW cs
stayed
.CW 0x21 .
.PP
.B "Ninth eliminated, and this one closes the line of enquiry."
The stall is not a latched-interrupt acknowledgement problem.
Whatever stops the controller asserting DREQ, writing back the status
bit does not restart it.
.PP
So the Arasan runs in PIO, which is what Linux does with this
controller, and the DMA switch there stays off.  The remaining
observations \(em that concurrency is the only thing that moves the
rate, that the failing path is always
.I devsd 's,
that in-kernel transfers never fail in over a thousand attempts \(em
are recorded above for anyone who returns to it, but it is closed as
an active question.
.PP
One correction to carry forward, because it has been restated three
times and keeps reappearing in reasoning about this bug: the stall
position is not fixed and is not a page boundary.  Twenty-eight of
twenty-nine dumps stop at three blocks, 1536 bytes; exactly one
stopped at eight blocks, 4096.  The invariant across both is that the
controller holds exactly one block, which is flow control working and
then never resuming.
.NH 2
SDHOST: two more eliminated, and a confound that invalidates the rest
.PP
.B "Not SDHCFG."
Linux keeps
.CW SDHCFG_DATA_IRPT_EN
and
.CW SDHCFG_BUSY_IRPT_EN
set for PIO and drops only the data one for DMA, which does not look
like a bit that merely routes an interrupt to a CPU \(em and this
driver had
.CW SDHCFG
at
.CW 0x8 ,
.CW Cfgslowcard
alone.  Setting both enables, and mirroring Linux's per-transfer
choice, changes nothing:
.CW "sdhsts 0x0 sdcmd 0x51 sdedm 0x10801" ,
the same failure.
.PP
.B "Not the data timeout either."
.CW SDTOUT
is already
.CW 0xf00000 ,
the value
.CW bcm2835-sdhost
writes at init.
.PP
.B "But none of these tests were clean, and this is the finding."
One card, two controllers, and the boot opens
.CW /dev/sdM0
for
.CW /n/dos
before anything touches SDHOST.  The Arasan therefore initialises the
card and holds the pins; opening
.CW /dev/sdN0
makes SDHOST take them and re-identify the card underneath a mounted
filesystem.  The console says so plainly:
.P1
sdhost: reinit ok
emmc: write block 19606 failed: interrupt 0x38100 status 0xf0001
dosfs: panic: write
.P2
SDHOST re-identified the card successfully and the Arasan's very next
write failed, taking
.I dossrv
with it.  So every SDHOST transfer measured so far ran against a card
another driver was still using, and a failure cannot be attributed to
the SDHOST path.
.PP
.B "The next step is a boot where only SDHOST touches the card."
That means
.CW raspi3binit.b
opening
.CW /dev/sdN0
rather than
.CW /dev/sdM0
\(em which also moves
.CW /n/dos ,
and therefore
.CW kupdate ,
onto SDHOST.  Loading that kernel over JTAG rather than through
.CW kupdate
avoids the circularity.  Until then the SDHOST results above stand
only as "not obviously fixed by this", not as eliminations.
.NH 2
SDHOST, on a card nobody else touches: SDHBCT does not hold what it is given
.PP
The confound is gone.
.CW raspi3binit.b
now reaches the card through one constant,
.CW SDDEV ,
pointed at
.CW /dev/sdN0 ,
so SDHOST owns the pins from boot and the Arasan never opens it.  On
such a boot the read still fails identically:
.P1
sdhost: read block 0 failed: sdhsts 0x0 sdcmd 0x51 sdedm 0x10801
.P2
which is worth having on its own \(em it means the failure is the
SDHOST path and not contention, and it restores the
.CW SDHCFG
and
.CW SDTOUT
results to real eliminations.
.PP
.B "And the failure report, asked for more, says this:"
.P1
sdhost: read block 0 failed: sdhsts 0x0 sdcmd 0x51 sdedm 0x10801
    (fsm 1 fill 0) sdhbct 6 sdhblc 1 sdhcfg 0x418
.P2
.CW sdhblc
is 1, as written.
.CW sdhbct
is
.B 6 .
The driver writes
.CW Secsize ,
512.
.PP
.B "The register does hold writes,"
which is the part that makes this a lead rather than a puzzle.  Asked
directly over JTAG, with the kernel halted:
.P1
SDHBCT before  0x6
SDHBCT written 512, reads 0x200
SDHBLC written 1,   reads 0x1
.P2
So 0x3c is the right offset, the register is writable, it retains what
it is given, and by the time the transfer has failed it holds 6
instead of 512.  Something between the driver writing it and the wait
timing out changes it, and with
.CW fill
0 and
.CW sdhsts
0 nothing has moved through the FIFO to explain a count being
consumed.
.PP
Linux calls this register "Host byte count (debug)", which may mean it
is not a plain latch during a transfer.  The next measurement is the
one this build was for and which has not run yet: print
.CW SDHBCT
immediately after the command is issued, before any wait, so "the data
phase never started" can be told apart from "it started and stopped".
The trace is written and committed; the board wants a restart to run
it.
.NH 2
SDHOST PIO: reads stop aborting, and the threshold that makes them
.PP
.B "The first read of SDHSTS must not happen for about a millisecond
.B "after the command."
Found by accident \(em a trace print between issuing the command and
entering the poll loop turned every failing read into a passing one,
and toggling only that print in one boot is the whole experiment:
.P1
trace 1:  10+0 records out
trace 0:  read block 0 failed, 0+0 records out
.P2
The print fixed nothing; it delayed the poll.  Made explicit and
swept:
.P1
delay 0us:    read block 0 failed (sdhsts 0x8, Failflag set)
delay 200us:  read block 0 failed
delay 1000us: 10+0 records out
delay 5000us: 10+0 records out
.P2
.CW sdhsts
.CW 0x8
is
.CW Hstsfifo ,
a FIFO error, with
.CW Failflag
in
.CW sdcmd :
touching that register while the data phase is starting aborts it.
.PP
.B "It is the first read, not the rate of reading."
Pacing the poll loop at one microsecond a read still reads at t=0, and
still fails; waiting 1ms and then polling flat out works.  Two
hypotheses died on the way to that \(em that the
.CW FORCE_DATA_MODE
write in the poll loop was corrupting the transfer (removing it
changed nothing), and that hammering the register was (pacing changed
nothing).
.PP
With
.CW sdhostdelay
at 1000 the read aborts are gone: a boot with SDHOST holding the card
prints
.CW SD-READ-OK
and no failures at all, where every read failed before.
.PP
.B "What is still wrong: the data is not right."
.P1
SD-MULTI-FAIL byte 1 of the last block: 00 not d7
SD-FS skipped: no partition table to find a gap in
.P2
Reads now complete without error and return wrong content \(em the
last block of a run reads as zeros, and block 0 does not look like an
MBR.  So the transfer starts and finishes and something about how the
words are taken out of the FIFO is wrong, which is a different
question from the one just answered and is where this picks up.
.PP
.B "And the delay is a characterisation, not a fix."
A millisecond a block caps this path near 500KB/s before anything else
is counted.  It wants replacing by a wait for whatever the real
condition is; what that condition is remains unknown, and
.CW SDEDM 's
FSM stays in DATAMODE throughout, so it is not that.
.PP
One thing settled along the way:
.CW SDHBCT
is a live counter, not a latch.  It reads 512 at command issue and 6
after a failed transfer, and writing it directly over JTAG with the
kernel halted reads 0x200 straight back \(em so the "sdhbct 6"
recorded earlier was the controller consuming it, not the driver
failing to set it.
.NH 2
SDHOST PIO reads work
.P1
sdhost: bytemode 1 (block 0 ends 55 aa)
SD-READ-OK
SD-MULTI-OK 32768 bytes, last block matches it read alone (eb589042)
SD-CAP-OK sector 30228479 reads and 30228480 does not; the claimed
          capacity is the real one
SD-OK
.P2
with the card on SDHOST and the Arasan never opened.  Two things had
to be true at once.
.IP 1.
.B "The first read of SDHSTS waits 1ms after the command,"
or the data phase aborts with
.CW Hstsfifo
and
.CW Failflag .
Measured threshold, above.
.IP 2.
.B "The data register hands over one byte per read."
This is in the driver's own comments and the switch for it defaulted
to off, so every read collected the same 32-bit window smeared a byte
at a time.  Block 0 of this card, both ways:
.P1
word: faaa5500b8faaa5500b8faaa1000b8fa8e1000b8d08e1000bcd08e1000bcd08e
byte: fab800108ed0bc00b0b800008ed88ec0fbbe007cbf0006b90002f3a4ea210600
.P2
The second is an x86 boot sector and ends
.CW "55 aa"
at 510.  The first is the same bytes smeared, with
.CW "fa b8 00 10 8e d0 bc"
visible marching through it.
.PP
It is now detected rather than assumed:
.CW pickbytemode()
reads block 0 each way at online time and takes the one whose last two
bytes are
.CW "55 aa" .
QEMU's model hands over whole words and silicon does not, so neither
can be the default and a guess would be wrong on one of them.
.NH 2
SDHOST writes do not, yet
.P1
sdhost: write block 2049 failed: sdhsts 0x1 sdcmd 0x800d
    sdedm 0x10803 (fsm 3 fill 0) sdhbct 384 sdhblc 1
.P2
.CW sdhbct
384 of 512 means 128 bytes went and the rest did not; the FSM is left
in WRITEDATA (3); and the
.CW "sdcmd 0x800d"
is the NEXT command, CMD13 from
.CW cardready() ,
unable to start against a controller still mid-transfer.  So the
visible symptom is the same stuck-CMD13 as before but the cause is
downstream of it this time.
.PP
The write path waits with
.CW fifospace() ,
which polls
.CW SDEDM 's
fill level, where the read path waits on
.CW SDHSTS 's
data flag.  The 1ms delay is applied to both, so whatever writes need
is not simply more of that.  That is the next thing.
.NH 2
Writes: bursting is not the answer either
.PP
The read side was fixed by not touching the status register while the
data phase starts, so the write side was rewritten the same way:
.CW bcm2835-sdhost
reads
.CW SDEDM
once per burst of eight words and, when there is no room, waits a time
proportional to the shortfall instead of spinning.  This driver had
been calling
.CW fifospace()
-- itself a spin on
.CW SDEDM
-- before every single word.
.PP
Ported faithfully, and it changes nothing.  A stamp-verified boot of
the bursting build:
.P1
SD-READ-OK
SD-MULTI-OK 32768 bytes, last block matches it read alone (eb589042)
SD-CAP-OK ... the claimed capacity is the real one
SD-OK
sdhost: write block 2049 failed: sdhsts 0x1 sdcmd 0x800d
    sdedm 0x10803 (fsm 3 fill 0) sdhbct 384 sdhblc 1
.P2
Byte for byte the failure it replaced:
.CW sdhbct
384 of 512, so 128 bytes went and no more, the FSM left in WRITEDATA,
and the
.CW "sdcmd 0x800d"
that follows is the next command's CMD13 unable to start against it.
.PP
.B "128 bytes is 32 words, and the FIFO is 16."
The controller accepts two FIFOs' worth and then stops draining to the
card, whether the words arrive one at a time with a poll between each
or eight at a time with one poll per burst.  So it is not the rate of
writing and not the rate of polling.
.PP
Kept anyway, because it matches the reference implementation and is no
worse, but it should not be mistaken for a fix.  What writes need is
still unknown, and the next thing to look at is what the card is doing
-- CMD13's status at the point of the stall, and whether the write
command was accepted at all -- rather than anything on the host side
of the FIFO, which has now been rewritten twice to no effect.
.NH 2
The card is not the problem
.P1
sdhost: write block 2049 failed: sdhsts 0x1 sdcmd 0x800d
    sdedm 0x10803 (fsm 3 fill 0) sdhbct 384 sdhblc 1
sdhost:   card rsp 0x900 (state 4, ready for data)
.P2
.CW 0x900
is state 4 -- TRAN -- with READY_FOR_DATA set and no error bit
anywhere.  The card accepted the command and is sitting there willing.
.PP
So the two ends disagree.  The controller's FSM is 3, WRITEDATA, with
.CW sdhbct
saying 384 of 512 bytes still expected; the card says it is idle in
TRAN and ready.  Nothing is being refused and nothing has errored:
one side is mid-transfer and the other has nothing to do.
.PP
That rules the card out and puts the fault between the FIFO and the SD
bus.  It also rules out everything tried so far, all of which was on
the host side of the FIFO: writing a word at a time with a poll
between each, writing eight at a time with one poll per burst, and
delaying the first poll by a millisecond.  The controller takes 128
bytes -- two FIFOs of 16 words -- and stops clocking them out.
.PP
Worth noting what is NOT set:
.CW sdhsts
is
.CW 0x1 ,
.CW Hstsdata
alone.  No
.CW Hstsrewtout
(read/write timeout), no CRC error, no
.CW Hstsfifo .
The controller is not reporting a fault, it has simply stopped.  That
is the same shape as the Arasan's DMA stall -- flow control engaging
correctly and never disengaging -- on a completely different
controller, which is interesting and may not be a coincidence.
.NH 2
SDHOST works: the whole suite, zero failures
.P1
SD-READ-OK
SD-MULTI-OK 32768 bytes, last block matches it read alone (eb589042)
SD-CAP-OK sector 30228479 reads and 30228480 does not
SD-OK
FAT-OK /n/dos/kernel8.img is 1938696 bytes
SD-FS-CREATE-OK
KUPDATE fetched 1938696 bytes
KUPDATE-VERIFY 1938696 bytes read back identical
KUPDATE-OK 1938696 bytes installed
FAT-WRITE-OK /n/dos/inferno.txt holds 29 bytes
FAT-RENAME-OK 29 bytes, contents intact across a rename
FAT-CLOBBER-OK refused, and the source is whole
FAT-HELD-OK 26 bytes across a rename with the file open
FAT-BIG-OK 1536000 bytes written, read back and renamed, 60220 ms
.P2
with the card on SDHOST, the Arasan never opened, and
.B "zero"
.CW "sdhost: ... failed"
lines in the boot.  kfs makes a filesystem, dosfs does the lot, and
kupdate writes a 1.9MB kernel and reads it back identical.
.PP
Three things had to be right, and each hid the ones behind it.
.IP 1.
.B "The first read of SDHSTS waits 1ms after the command."
Below that the data phase aborts with
.CW Hstsfifo
and
.CW Failflag .
Found because a debug print made every read pass.
.IP 2.
.B "The data register moves ONE BYTE per access, both ways."
Reading is documented in this driver and the switch defaulted off, so
reads returned the same word smeared.  Writing is not documented
anywhere and the loop wrote words: 128 of them, which the controller
counted as 128
.I bytes
.CW ( sdhbct
512 to 384), so three quarters of every block never arrived.
.IP 3.
.B "A command whose data phase never starts is re-issued."
The 1ms is necessary and not sufficient \(em block 36864 of the
sustained test still aborted.  When the FSM is still in DATAMODE with
no error bit and an empty FIFO, nothing was transferred and the card
is idle in TRAN, so re-issuing is safe.  Four attempts a block.
.PP
.B "What this cost, and the lesson in it."
The write loop was rewritten three times before the arithmetic was
done \(em per-word polling to bursts, then the interrupt-enable bit
Linux uses for writes \(em each a faithful port of
.CW bcm2835-sdhost ,
none of which could have worked, because they all changed WHEN the
words went and the fault was that each carried a quarter of what it
looked like.  The number was in the first dump:
.CW "sdhbct 384"
against 128 words written.
.PP
.B "And it is slow."
24 KB/s against the Arasan's 50, because a byte per register access is
four times the MMIO for the same data.  That is what the DMA path on
this controller is for, and it is written and waiting behind
.CW "echo dma 1" .
.NH 2
The byte-at-a-time data register was a card on one wire
.PP
.B "The one-byte-per-access behaviour is not a property of this silicon."
It is what an SDHOST does when the card is talking on one DAT line and
.CW SDHCFG
has its two bus-width bits clear.  Three things set the width and all
three have to agree: ACMD6 tells the
.I card
to use four lines,
.CW WIDE_EXT_BUS
tells the controller the same about DAT1-3, and
.CW WIDE_INT_BUS
widens the path between the controller and
.CW SDDATA .
This driver did none of them.  Its constants
.CW Cfgwideext
and
.CW Cfgwideint
had been defined and never used, and the board reported
.CW "sdhcfg 0x408"
through every one of the failures in the section above.
.PP
.B "Setting WIDE_INT_BUS alone does not fix it; it stops the transfer."
That was the obvious first experiment, because
.CW bcm2835-sdhost
sets that bit unconditionally in
.CW set_ios
and the other only for a 4-bit card.  On the board:
.P1
sdhcfg 0x41a, read block 0 failed, sdhsts 0x0
sdcmd 0x51 sdedm 0x10801 (fsm 1 fill 0) sdhbct 512
.P2
.CW SDHBCT
untouched at 512 with an empty FIFO and no error bit means nothing
arrived from the
.I card
at all.  A bit that only set the width of a host-side register access
could not do that \(em the data would still have come and merely been
read wrong, and
.CW SDHBCT
would have counted down.  So the name is not the whole story, and the
bit is not simply the absence of the bug.
.PP
.B "All three together, and the probe comes back the other way."
.CW sdcardinit()
now sends ACMD6 once the card is selected and then sets both bits, and
.CW pickbytemode()
tries the mode the configuration implies first:
.P1
sdhost: card rca 0x1234 block 30228480 sectors,
    core clock 250000000 Hz, 4-bit, sdhcfg 0x41e
sdhost: bytemode 0 (block 0 ends 55 aa)
SD-READ-OK
SD-MULTI-OK 32768 bytes, last block matches it read alone
SD-CAP-OK sector 30228479 reads and 30228480 does not
SD-OK
SD-FS-CREATE-OK
.P2
Block 0 read 32 bits at a time ends 55 aa.  The whole bytemode path
stays, because it is what an unconfigured controller does and a card
that refuses ACMD6 lands back on it, but on this board it is no longer
the path taken.
.NH 2
SDHOST DMA works, in both directions, and is not faster
.PP
With the register handing over whole words the DMA engine's 32-bit
accesses carry four bytes each, and both directions work.  Verified
with a new
.CW ctl
command that touches no filesystem:
.P1
echo wrverify <blk> <n> <writedma> <readdma> >/dev/sdN0/ctl
.P2
It fills a buffer with a pattern made from the block number, writes,
reads back with the DMA switch set independently for the two
directions, and compares in the kernel.  All four combinations, 64
blocks each, on blocks past every partition:
.P1
WRVERIFY-OK 64 blocks, write dma 0 read dma 0, 350 ms
WRVERIFY-OK 64 blocks, write dma 1 read dma 0, 420 ms
WRVERIFY-OK 64 blocks, write dma 0 read dma 1, 370 ms
WRVERIFY-OK 64 blocks, write dma 1 read dma 1, 360 ms
.P2
and 200KB read by DMA to a file compared byte-identical against the
same read by PIO.
.PP
.B "It buys nothing measurable."
1024 blocks written and read back, alternating, is 6580, 6330 and 5660
ms with DMA against 7970, 5400 and 7530 without.  The spread inside
each is larger than the gap between them.  DMA on this controller is
correct, not fast: every block is its own CMD24 or CMD17 with a CMD13
poll in front of it, and that is where the time goes, not in moving
512 bytes across the bus.  So it stays behind
.CW "echo dma 1"
rather than becoming the default, and the claim in the section above
\(em that a byte per access was four times the MMIO and DMA was what
that path was for \(em was wrong about the remedy.  Four lines fixed
the width; the engine did not fix the rate.
.PP
.B "Two bugs of this driver's own, found by the failures above."
The first is why a failing probe crashed the kernel.  The bounded
retry rewound the block index and re-issued the command but did not
rewind
.CW p ,
so an attempt that moved some bytes and stalled left the pointer
advanced and the next attempt wrote a further block from there \(em up
to 2560 bytes into a 512-byte buffer.
.CW pickbytemode() 's
buffer is on the stack eight bytes below its caller's saved arguments,
so the overrun landed on the
.CW SDunit*
and the next call through it took a translation fault on an address
made of instruction bytes.  It had sat there since the retry was
written, invisible while the first probe always succeeded.
.PP
The second was in the verifier, not the driver, and is the tree's
standing kencc trap: the pattern was written
.CW "(uchar)(k*7 + (bno+b)*13 + (k>>8))"
with
.CW bno
a
.CW uvlong ,
and this compiler emits no truncation for a narrowing cast of a
64-bit value.  Every block failed on byte 0 with the print saying
.CW "is bc want bc" ,
because
.CW %.2ux
showed two hex digits of each while the comparison held a byte from
the card against a full 64-bit number.  Mask, do not cast.
.NH 2
The word read loop had no retry, because it had never run
.PP
The first sustained test with the card on four lines failed:
.P1
sdhost: read block 39811 failed: sdhsts 0x0 sdcmd 0x51
    sdedm 0x10801 (fsm 1 fill 0) sdhbct 6 sdhblc 1 sdhcfg 0x41e
sdhost:   card rsp 0x900 (state 4, ready for data)
FAT-BIG-FAIL read at 0: mount rpc error
.P2
.CW "sdhbct 6"
is six bytes short of the block, with the FSM back in DATAMODE, the
FIFO empty, no error bit and the card idle in TRAN \(em exactly the
condition the bounded retry was written for, and exactly the condition
that had been re-issuing commands successfully for weeks.
.PP
It was in the
.I byte
read loop only.  The word loop called
.CW bioerror
and gave up, and nobody noticed, because until the bus width was set
that loop was never the one taken on real silicon: every transfer on
this board went down the byte path.  Putting the card on four lines
moved all of them to a path that could not recover, and the first
1.5MB transfer found it.  The write loop's 20000-try give-up had the
same hole.  Both now retry the same way, and the retry rewinds
.CW p
\(em see the stack overrun above, which is the bug that rewind fixes.
.PP
.B "And a census, because a failure report has to distinguish two cases."
.CW "retried N gaveup M"
in
.CW /dev/sdN0/ctl
and in every failure print.  Without it a report cannot tell "the
retry never fired" from "it fired four times and the block still
would not come", and those want opposite fixes \(em which is precisely
the mistake that let this sit: the failure above looks identical to a
retry that ran out.
.PP
.B "What it survives now."
The kernel booted from the card with no debugger and ran the whole
suite, then 3000 blocks written and verified in PIO and 4000 in DMA
both ways \(em 2MB each way \(em each while a second process read 16MB
from the raw device concurrently.  No failures, and
.CW FAT-BIG-OK
at 24-25 KB/s.  The intermittent read stall that started this has not
recurred; the honest statement is that it is now recovered from, not
that it is understood.
.NH 2
One DMA engine, two drivers, no lock
.PP
.CW dmaxfer()
holds the channel number and the control block in file statics:
.P1
static uchar raw[sizeof(Cb) + 32];
.P2
one block, one channel, and until now one caller \(em
.CW sdhostbcm.c
was not even in the build.  It is now, with a DMA path of its own, and
each driver calls
.CW dmaxfer
under its own controller's
.CW qlock ,
which serialises neither against the other.  Two transfers would each
rewrite that control block while the engine read the other's, and
nothing anywhere would report an error.  The engine is the shared
resource, so the lock goes in
.CW dmabcm.c
and not in the drivers \(em a
.CW QLock ,
because
.CW dmaperiph()
spins for the transfer and is always called from process context.
.PP
Verified after the change: 3000 blocks written and read back by DMA
and byte-compared, while a second process read 12MB from the raw
device, and
.CW "retried 0 gaveup 0"
afterwards.
.NH 2
The warm restart fails about half the time, and it is not understood
.PP
.CW jtagrestart
comes up garbled and panics in
.CW chandevreset
with a devtab full of rubbish roughly every other attempt:
.P1
reset #/
reset #
0 x 8a000000 0019bca2 i 0014b764 ... panic:
shutdown: devtab[11] is corrupt (0x1dab40), skipped
.P2
A retry works, so
.CW tools/jtag/boot.sh
retries up to four times and, more to the point, proves which kernel
is running rather than assuming.  The cause is open.  The obvious
theory \(em that OpenOCD writes the image to RAM while the CPU holds
dirty lines over it, and the stub's clean then writes them back over
the new image \(em does not hold up: OpenOCD writes aarch64 memory by
executing loads and stores on the halted core, so the image is in the
same cache the stub cleans.
.PP
.B "And the harness bug the first version of boot.sh had, because it
.B "is the same one this directory keeps making."
It typed
.CW "echo ==MARK=="
to the board and waited for the build stamp to appear after it.  That
cannot work: the marker goes to the OLD kernel's shell, and the reason
for restarting is usually that the old kernel has panicked and has no
shell.  Two attempts were reported as failures with no evidence either
way.  The reference point has to be something the board is not asked
to produce \(em so it counts how many times this build's banner is
already in the buffer and waits for one more.
.NH 2
The Arasan stall: the latched-Iwriterdy hypothesis is dead
.PP
The experiment the TODO above asked for has been run, on the board,
with the stall captured in the same window as its own dump.  The
answer is no:
.P1
    requested       9 blocks / 4608 bytes
    DMA transferred 3 blocks / 1536 bytes
    DMA remaining   6 blocks / 3072 bytes
    dma cs 0x21 debug 0x4808000 ti 0xb0148
    dma src 0xc3bb2640 dst 0x7e300020 (engine still active)
    BEFORE: dma cs 0xa emmc interrupt 0x10 status 0x1ff0506
    emmc status 0x1ef0106 interrupt 0x10
    emmc control0 0x100 control1 0xe0407 blksizecnt 0x70200
emmc: UNSTICK ack Iwriterdy: remaining 3072 -> 3072
    after 20100 us, cs 0x21 (no change)
.P2
Acknowledging
.CW Iwriterdy
and waiting 20ms moved nothing.  If DREQ re-assertion needed that
latched bit cleared, it would have moved.  It did not, so that is not
the mechanism, and the fix it implied \(em acknowledge during the
transfer rather than after it \(em would not have worked.
.PP
.B "What the dump says instead, and it is new."
Two readings in it were not in any earlier capture, and they change
the shape of the problem.
.IP 1.
.B "The controller has ENDED the write transfer."
.CW status
goes
.CW 0x1ff0506
before to
.CW 0x1ef0106
at the stall, and the bit that cleared is 0x400,
.CW WRITE_TRANSFER_ACTIVE .
With
.CW blksizecnt 0x70200
\(em seven blocks of 512 still outstanding \(em the controller is
saying it is not in a write transfer any more.  That explains DREQ
being clear in
.CW "cs 0x21"
.CW ( ACTIVE | DREQ_STOPS_DMA ,
and bit 3 DREQ low): there is no transfer for it to request data for.
The question was "why does DREQ not come back"; it is now "why did the
controller drop the transfer with seven blocks to go".
.IP 2.
.B "The card is busy."
The DAT line levels in
.CW status
bits 20-23 go from
.CW 0xf
before to
.CW 0xe
at the stall \(em DAT0 held low, which is how a card says it is
programming.  So the sequence is: the card goes busy part way through
a multi-block write, the controller drops
.CW WRITE_TRANSFER_ACTIVE
and its DREQ, and neither comes back when the card finishes.
.PP
.B "The next hypothesis, and why it is worth more than the last one."
This Arasan is the block Linux wraps in a minimum delay between
consecutive register writes \(em
.CW sdhci-bcm2835.c
carried a
.CW writel
that busy-waits so two writes cannot land closer than about 8 SD
clocks.  That is a CPU-side workaround, and an external DMA engine
writing
.CW 0x7e300020
knows nothing about it: it writes the data register back to back at
bus speed with
.CW WAITS
zero in
.CW ti 0xb0148 .
A PIO loop is slower and stops at every block for
.CW awaitirq ,
which is why PIO has never shown this.
.PP
It is directly testable: the BCM2835 DMA
.CW TI
register has a
.CW WAITS
field, bits 21-25, that inserts wait cycles between transfers, and a
.CW NO_WIDE_BURSTS
bit at 26.  Both are one bit of configuration and neither has ever
been set here.  Unlike the last hypothesis this one predicts the
specific thing observed \(em a failure that appears only once enough
writes have gone back to back, and only on the path with no
per-block pause.
.NH 2
The Arasan DMA write stall: there was never a stall
.PP
.B "It is a timeout, and the timeout was a spin count."
.CW dmaperiph()
waited for the engine with
.P1
for(i = 0; i < Timeout; i++){ ... }
.P2
and
.CW Timeout
is 1000000 \(em a bare count of uncached reads of the channel's
.CW Cs
register, worth something like a tenth of a second on this board and
nothing in particular on any other.  A peripheral-paced transfer runs
at the peripheral's speed, and an SD card part way through a
multi-block write fills its internal buffer, holds DAT0 low and
programs; the specification allows it 250ms to do that.  So the driver
declared failure over a card that was working, and everything built on
top of that \(em nine eliminations, a DREQ hypothesis, a latched-bit
hypothesis \(em was explaining a fault that did not exist.
.PP
.B "Measured, by watching all three parties through one stall."
.CW "echo dmawatch 2000"
samples the card's DAT0 level, the host's BUFFER_WRITE_ENABLE and the
engine's remaining count every 100us for two seconds at the moment the
old code gave up:
.P1
emmc: WATCH 2000ms: dat0 high at 2473, bufwren at 2422,
    dma moved at 815 (x100us; -1 never)
emmc:   status 0x1ef0106 -> 0x1ff0000 interrupt 0x12
    remaining 3072 -> 0 cs 0x2
.P2
The engine resumed at 81ms, the host buffer had room again at 242ms,
the card released DAT0 at 247ms \(em and the transfer
.B completed:
nothing remaining, the END flag set,
.CW Idataend
and
.CW Iwriterdy
raised.  At 50ms none of the three had moved, which is why a shorter
watch looked like a hang and reinforced the wrong story.
.PP
.B "A correction to the section above, because the wrong reading
.B "pointed at the wrong bug."
That section says the bit which clears in
.CW status
is
.CW WRITE_TRANSFER_ACTIVE .
It is not.  0x400 is bit 10,
.CW BUFFER_WRITE_ENABLE ;
bit 8,
.CW WRITE_TRANSFER_ACTIVE ,
stays set throughout.  So nothing at the stall was in a broken state
at all: the transfer was active, the host's buffer was correctly full,
DREQ was correctly dropped, DAT0 was correctly low.  Every party was
behaving, which is exactly what should have been suspicious.
.PP
.B "The fix."
Wait by the clock and wait long enough for a card:
.CW systmrread()
is a 1MHz counter, and
.CW dmaxferus
gives a peripheral-paced transfer one second \(em the
specification's limit and then some.  The engine is still ACTIVE and
still correctly waiting; there is nothing to gain by giving up sooner.
And the pacing hypothesis from the previous section is dead too:
.CW "dmawaits 31"
put
.CW WAITS
at its maximum, confirmed live in the control block as
.CW "ti 0x3eb0148" ,
and the transfer stopped at the same three blocks of nine.
.PP
.B "Why every earlier elimination found nothing, and the lesson."
None of them was about how long the code waited.  Stale interrupts,
stale channel state, page offset, direction alternation, buffer
dirtiness, delay, per-transfer allocation \(em all nine were about
.I what
was configured, and the fault was
.I when
the driver stopped listening.  PIO never showed it because the PIO
path waits per block in
.CW awaitirq ,
which has a real timeout.  In-kernel
.CW dmatest
never showed it because it does not write enough consecutive blocks to
make the card program mid-transfer.  A spin count is not a timeout: it
is a timeout whose length is a property of the machine, the compiler
and the bus, and this one was shorter than the hardware it was waiting
for.
.NH 2
Open: warm JTAG entry is unreliable, and its three faces are one fault
.PP
About half of
.CW jtagrestart 's
attempts produce one of three things, and they are almost certainly
the same underlying fault \(em memory that is not what the kernel
thinks it is:
.IP \(bu
a garbled console from the first byte, and a panic in
.CW chandevreset
with
.CW "devtab[11] is corrupt" ;
.IP \(bu
a hang part way through the peripheral suite \(em twice at
.CW "i2c: bsc0 ... up," ;
.IP \(bu
a data abort at
.CW accounttime+0x24
from
.CW clockintr ,
which is
.CW "p->time[p->insyscall]++"
with
.CW m->proc
holding eight bytes read out of kernel text
.CW ( far
.CW b900080152b00169 ,
which decodes as
.CW "MOVZ W9, #0x800B, LSL #16"
and
.CW "STR W1, [X0, #8]" ).
.PP
The identical
.CW far
across four different builds is what says these are systematic rather
than a stray pointer.  None of them has ever been seen on a kernel
booted from the card: the two card boots in this session ran the whole
suite clean.  The cause is open.
.CW tools/jtag/boot.sh
works around it by retrying and by proving which kernel is running,
which is enough to keep working, and is not a fix.
.PP
.B "What is proven and what is owed."
Proven on the board: the mechanism, by the two-second watch above \(em
the transfer completes at 247ms on a path the old code abandoned at
roughly 100ms.  Proven on the committed tree: the clock-based wait
does not disturb what already worked, with the full suite passing and
2000 blocks written and read back by SDHOST DMA and byte-compared
while a second process read 8MB.  Owed: the same 4608-byte
.I dossrv
write that used to stall, run to completion with
.CW "emmc dma 1"
on an Arasan kernel.  That needs the card routed to the Arasan, which
needs a JTAG boot, and four warm entries in a row came up hung or
garbled \(em the open item below.  The fix is a strictly longer wait
on the same code path the watch instrumented, so the claim here is
"measured cause, fix follows, end-to-end demonstration outstanding",
not "fixed".
.PP
.B "Two corrections to the wait itself, from review."
The first version signalled the deadline by setting
.CW "i = Timeout"
and testing
.CW "i == Timeout"
afterwards.  That was safe only while the loop was bounded by
.CW Timeout ,
and it is not any more:
.CW i
now free-runs for up to a second of MMIO reads, several million of
them, so a transfer that SUCCEEDED could break out with
.CW i
at exactly 1000000 and be reported as a timeout.  A separate flag,
not a sentinel the loop can reach on its own.
.PP
The second is a hazard that turned out not to exist, checked rather
than assumed: differencing
.CW systmrread()
is only correct if it does not wrap under the subtraction.  It reads
CHI and CLO with the re-read dance and returns a true 64-bit
microsecond count, so it does not.  Both re-verified on the board:
full suite, and 2000 blocks written and read back by DMA and
byte-compared against a concurrent 8MB reader.
.NH 2
The Arasan write runs clean: what was owed is paid
.PP
On an Arasan kernel with the card routed to it, the write that used to
stall, twice:
.P1
; echo dma 1 >/dev/sdM0/ctl
; dd -if /dev/sdM0/data -of /n/dos/d1.tmp -bs 4608 -count 400
400+0 records out
emmc status 0x1ff0000 ... interrupt 0x10 ... errors 0
; dd -if /dev/sdM0/data -of /n/dos/d2.tmp -bs 4608 -count 400
400+0 records out
emmc: dmatest 9 blocks x 100, ... dma 1 ...
emmc: dmatest 100 transfers of 9 blocks, all clean
.P2
1.84MB through
.I dossrv
at 4608 bytes a time, twice, with the engine doing the writing.  The
proof that nothing failed is not the absence of a message: it is that
.CW dma
still reads 1 afterwards, because the failure path sets
.CW emmcdma
to 0 on the way out.  The controller's own error count is 0.
.PP
So both SD controllers on this board now have a working, verified DMA
path, and the difference between them is what it should be: SDHOST is
the one the card is on because that is what a Pi 3B wants, and the
Arasan is there for the SDIO function.
.NH 2
Warm entry: halting the CPU does not stop a bus master
.PP
.B "The USB controller is running while the image is loaded, and it
.B "has been all along."
Halting the cores stops the cores.  It does not stop the DWC OTG core
at 0x3f980000, which is a bus master: it writes received packet data
straight into the kernel's buffers, continuously, whether or not
anything is plugged in \(em this board says so every two seconds,
.CW "usbdwc: ep3.1 re-armed" .
So the debugger halts a kernel, loads a new one over it, and the USB
core carries on writing packets into buffers belonging to the kernel
that is no longer there, which are now inside the image just loaded.
.PP
The old
.CW quiesce
stopped the DMA engines, the eMMC and the interrupt controller, and
never touched USB.  Proof that it was live, from the first run of the
new one:
.P1
quiesce: USB host channels STILL ENABLED on entry:
quiesce: usb ahbcfg 0x21 -> 0, ahbidle 1, soft reset took
quiesce: after -- 0 DMA channels active, ..., 0 USB channels enabled
.P2
.CW "ahbcfg 0x21"
is DMA enable and the global interrupt, both on, at the moment of the
halt.
.PP
.CW quiesce
now halts each host channel with
.CW Chdis
(polled and bounded \(em it is asynchronous on this part), clears the
channel interrupts and masks, turns off DMA and the global interrupt
in
.CW gahbcfg ,
waits for the core to go AHB-idle, soft-resets it, and reports the
count of channels still enabled afterwards so the claim is checkable.
That leaves the core mastering nothing, which is the state a cold boot
hands over.
.PP
.B "It fits every symptom, and it is not yet shown to be the cause."
Garbled console, corrupt devtab at
.CW chandevreset ,
a hang in the peripheral suite, and a data abort at
.CW accounttime+0x24
are all "memory is not what the kernel thinks"; they happen about half
the time, which is how often a transfer lands somewhere that matters;
and they have never happened on a kernel booted from the card, where
nothing masters the bus during a load.  What is missing is a measured
success rate with the new quiesce, over enough restarts to tell half
from nearly-all.  That run is outstanding: the debug interface went
into
.CW DSCR.ERR=1
part way through it and wants a power cycle.
.PP
.B "And the trap report now says which of two things m is doing."
.CW accounttime+0x24
is
.CW "p->time[p->insyscall]++"
with
.CW "p = m->proc" ,
and the report has never distinguished
.CW m
pointing somewhere wrong from
.CW m
pointing correctly at a Mach whose contents were overwritten.  It now
prints
.CW m ,
.CW MACHP(0)
\(em the address it is supposed to hold \(em and
.CW splpc ,
.CW machno ,
.CW proc
and
.CW ticks ,
straight to the UART before anything that can take a lock.
.NH 2
Chasing the accounttime trap: what is established
.PP
.B "Where it faults, exactly."
.CW accounttime+0x24
disassembles to
.P1
ldr   x9, [x28, #264]     ; m
ldr   x9, [x9, #8]        ; m->proc
...
ldrsw x5, [x9, #360]      ; p->insyscall   <- faults
.P2
so the faulting address is
.CW m->proc
+ 360, and with
.CW far
.CW b900080152b00169
that makes
.CW m->proc
=
.CW 0xb900080152b00001 .
.PP
.B "What that rules out."
It is not stale BSS from a warm entry:
.CW main()
zeroes
.CW edata..end
on the way in, and the fault has happened after a kernel booted
cleanly through the whole peripheral suite and the network tests \(em
so the Mach is being corrupted while running, not left dirty by the
load.  It is not the CRUMB area overlapping the Mach either: CRUMB is
0x20000000 and
.CW mach0
is 0x2696b0.  And the value is not a byte pattern found anywhere in
the kernel's text, so "something copied code over it" does not hold up
as stated.
.PP
The
.CW sp
differs between occurrences (0x675dd0, 0x676fe0, 0x677160, 0x3cf3610)
while
.CW far
is identical, which says the fault is not tied to one process but the
bad value is not random either \(em the same constant is arriving at
.CW mach0+8
every time.
.PP
.B "The instrument, since the debugger cannot be relied on for this."
The trap report now prints
.CW m ,
.CW MACHP(0) ,
and the Mach's
.CW splpc ,
.CW machno ,
.CW proc
and
.CW ticks ,
on the UART before anything that can take a lock.  That distinguishes
.CW m
pointing somewhere wrong from
.CW m
pointing correctly at a Mach that was overwritten, which is the fork
in the road and has never been answered.
.NH 2
A real bug found on the way: splhi wrote eight bytes into a four-byte field
.PP
.CW splhi()
and
.CW splx()
both do
.P1
MOV	$mach0(SB), R2
MOV	R30, 0(R2)		/* m->splpc */
.P2
and
.CW m->splpc
is a
.CW ulong ,
which is
.B four
bytes in this compiler.
.CW MOV
of an X register stores eight, and the image confirms it:
.CW "str x30, [x2]" .
So every
.CW splhi
and every
.CW splx
\(em which is to say, constantly \(em also wrote the next field of the
Mach,
.CW machno
at offset 4.
.PP
It has been harmless, and only by accident: the high half of a kernel
return address is zero, and
.CW machno
is supposed to be zero on a one-processor board, so the wrong store
happened to write the right value.  That stops being true the moment
the struct is reordered or a second processor exists.
.CW MOVW
now, which assembles to
.CW "str w30, [x2]" .
It does not reach
.CW proc
at offset 8, so it is not the accounttime fault.
.NH 2
jtagreboot: the device cleanup that works, because the silicon does it
.PP
The right answer to "quiesce every device before a warm load" turned
out to be: do not warm load.  The BCM2835 watchdog's full-reset mode
resets
.I every
peripheral, not the ones a script remembered, and it can be armed from
the debugger \(em two register writes at 0x3f100000 with 0x5a000000 in
the top byte, WRCFG set to full reset, and a count of ten 65536ths of
a second.  The board goes down and comes back from the card as if
power-cycled.
.P1
proc jtagreboot { }
    ... write PM_WDOG, write PM_RSTC, resume
.P2
OpenOCD reports
.CW "Invalid ACK (7)"
and a sticky DAP error when it does this, which is not a failure: the
chip resets out from under the debugger mid-transaction.  The console
says what actually happened \(em a fresh banner and a clean SD suite.
.PP
.B "It is also the way out of a board that is blocked rather than
.B "crashed."
That distinction was invisible until JTAG made it: a board that looked
hung, ignoring the console entirely, had cpu0 sitting at one address
across five samples fifteen seconds apart, and the instruction there,
read out of the board's own memory rather than guessed from a symbol
table belonging to a different build, was
.CW d503207f
\(em
.CW WFI .
The kernel was idle with every process asleep, which from the console
is indistinguishable from a crash and wants the opposite response.
.PP
Before this the only ways back were
.CW jtagrestart ,
which fails about half the time and replaces the kernel rather than
restarting the one on the card, and asking for the power to be pulled.
.NH 2
A board that looks hung, and is not: two host-side faults
.PP
.B "The kernel was idle, not stuck."
JTAG settled it in one reading.  cpu0 sat at the same address across
five samples fifteen seconds apart, and the instruction there \(em
read out of the board's own memory rather than resolved against a
symbol table belonging to a different build, which would have been a
guess \(em was
.CW d503207f ,
.CW WFI .
Every process was asleep.  From the console that is indistinguishable
from a crash and wants the opposite response.
.PP
.B "First fault: the host's styx server had wedged."
.CW kupdate
printed nothing at all, on boot after boot, and neither did
.CW fatwrite
\(em which runs after it in the same spawned process, so the pair was
blocked inside
.CW kupdate .
It dials the host and mounts
.CW /n/remote ,
and the server there had been up three and a half days:
.P1
emu -r .../raspi3b-port sh -c styxlisten -A 'tcp!*!6666' export /
.P2
It still accepted the TCP connection and never answered a Styx
.CW Tversion .
A handshake by hand from the host timed out; a fresh server replies in
milliseconds.  Every process that touched the mount went to sleep
behind it, which is why the whole board went quiet.
.PP
.B "Second fault: nothing the host types reaches the board."
.CW ^R
is handled by the kernel's console driver, not by any program, and it
did not reboot.  So the question was whether the kernel was failing to
read the UART or the UART was getting nothing, and the registers
answer it \(em taking care to read
.CW AUX_MU_LSR
and
.CW AUX_MU_STAT
and NOT
.CW AUX_MU_IO ,
because reading the IO register pops the receive FIFO and the
diagnostic would eat the very byte it was looking for:
.P1
before:            LSR 0x60  STAT 0x34e  AUX_IRQ 0
type 40 characters
after:             LSR 0x60  STAT 0x34e  AUX_IRQ 0
.P2
Identical.  No data ready, receiver idle, FIFO empty, no interrupt
pending.  And the board's side is configured correctly:
.CW GPFSEL1
reads
.CW 0x1b6d2000 ,
which decodes to GPIO14 and GPIO15 both in ALT5 \(em the mini UART's
TX and RX \(em the mini UART is enabled in
.CW AUX_ENABLES ,
its receive interrupt is on in
.CW AUX_MU_IER ,
and IRQ 29 is enabled in the interrupt controller.  Transmit works
throughout.  So the serial line from host to board carries nothing,
and the adapter's device node was re-created at 08:03 while the screen
session has held a file descriptor to it since long before.
.PP
.B "And a caution about what was blamed on the warm restart."
Some of what this document calls a warm-entry hang may have been this:
a board that booted perfectly and could not be spoken to.  The
.I garbled
output and the corrupt devtab are real and are on the output side, so
those stand.  The hangs are less certain than they were written down
as being, and the measured success rate that is still owed should be
taken with a console known to be working in both directions.
.PP
.B "Resolved: the adapter, not the wire and not the board."
Reseating the USB-serial adapter fixed it, and the measurements say
exactly why that worked.  GPIO15 switched to a plain input read
.CW 0x2347c1ff
eight times in a row \(em bit 15 high, rock steady \(em which is a
transmitter actively holding a UART line at idle, not a floating pin,
which would have read differently each time.  So the wire was
connected throughout and this document's earlier conclusion that it
was not is wrong.  The adapter was driving idle and never transmitting
a bit: with the CPU HALTED over JTAG so nothing could drain the FIFO,
eight bytes sent twenty seconds later left
.CW LSR
at 0x60 and the FIFO empty.
.PP
Two instrument faults made this take far longer than it should have.
The first: reading
.CW AUX_MU_IO
to check for data POPS the receive FIFO, so the diagnostic destroys
what it is looking for \(em
.CW LSR
and
.CW STAT
are the registers to read.  The second, and the expensive one:
.CW "screen -X"
against a session that has been killed and restarted fails
.I quietly .
Every script in
.CW tools/jtag
had the session name written into it, so after the session was
restarted they all typed into nothing and the board looked
unresponsive while nobody was speaking to it.  They find the session
now instead of remembering it.
.NH 2
Driving the board from the host, and what the silence cost
.PP
.B "It works, on the board."
With the styx server proved healthy first,
.CW board.cmd
in the worktree runs on the Pi:
.P1
RCMD-BEGIN 1 cat /dev/sdN0/ctl
sdhost rca 0x1234 blockaddr sectors 30228480 coreclock 250000000 cdiv 8
sdhost dma 0 dreq 13 retried 0 gaveup 0
sdhost sdcmd 0x98 sdhsts 0x0 sdedm 0x10801 sdhcfg 0x50e errors 0
part data 0 30228480
...
KUPDATE fetched 1945288 bytes
KUPDATE-VERIFY 1945288 bytes read back identical
KUPDATE-OK 1945288 bytes installed
.P2
Nothing was typed to produce that.  A board whose console is
one-directional \(em which is how this one spent an afternoon \(em can
still be driven and still be read.
.PP
.B "And kupdate no longer returns in silence."
Its one quiet path was "cannot open /n/dos/kupdate.txt within sixty
seconds", deliberately silent so a board with no
.CW kupdate.txt
would not nag.  That silence is what made a wedged host server
indistinguishable from a board that had hung: the board booted,
printed nothing about updating, and sat there.  One line,
.CW KUPDATE-NONE ,
is cheaper than telling those two apart from outside \(em and the
general rule is the one this port keeps rediscovering, that an absence
is the worst kind of evidence.
.NH 2
The accounttime fault: m is nil, and the clock was still armed
.PP
.B "The trap report answers it in one line."
.P1
TRAP type 0 esr 96000004 pc 0015f328 lr 00168194
    far b900080152b00169 sp 00677790
  m = 0000000000000000 mach0 0000000000269cb0
.P2
.CW m
is
.I nil .
Not a Mach whose contents were overwritten \(em the global pointer
itself is zero, while
.CW MACHP(0)
is 0x269cb0 where it should be.  Every earlier guess in this document
about what was writing into the Mach was looking at the wrong object.
.PP
.B "And it is not corrupted while the kernel runs."
A write watchpoint on the global
.CW m
at 0x171108, armed over JTAG on a freshly booted board and left for
eight minutes, never fired;
.CW m
read 0x269cb0 throughout.  So nothing scribbles on it.  It is
.I zero
because
.CW m
lives in the DATA segment with an initial value of 0 \(em the symbol
table says
.CW "D m"
\(em and a warm restart loads a new image over the running kernel,
which puts that 0 back.
.PP
.B "What fires into that window: the per-core interrupt controller."
Disabling the legacy controller at 0x3f00b200 is not disabling the
interrupts.  On a BCM2836/2837 the ARM generic timer and the core
mailboxes go to a separate block at 0x40000000, and the kernel's clock
.I is
the generic timer.  Read on a running board, and printed by
.CW quiesce
now:
.P1
quiesce: core timer irq control on entry: 0x2 0 0 0
quiesce: core0 irq source 0x2
.P2
Bit 1 is CNTPNSIRQ: enabled, and already
.I pending .
So the sequence is: the image load resets
.CW m
to 0, that armed and pending timer interrupt survives into the new
kernel, and if it is taken before
.CW main()
reaches
.CW machinit() ,
.CW clockintr
calls
.CW accounttime ,
which does
.CW "p->time[p->insyscall]++"
with
.CW "p = m->proc"
and
.CW m
nil.
.PP
That is why it has never once happened on a kernel booted from the
card: a cold boot has no pending anything.  And it is why every
attempt to find the corruption failed \(em there was none.
.CW quiesce
now clears the per-core timer and mailbox enables for all four cores
and the local control register, and reports them before and after so
the claim is checkable.
.PP
.B "And one correction, measured: do not touch the local control
.B "register."
The first version of this cleared 0x40000000 as well as the per-core
enables.  That register selects the core timer's clock source, so
zeroing it does not quiesce anything \(em it moves the next kernel's
timer off the clock it expects.  Measured immediately: warm restarts
went from failing about half the time to four attempts in a row, none
of which came up.  Disable the enables; leave the wiring alone.
.NH 2
m is never nil now, and the warm restart is still not measured
.PP
.B "The fault is fixed at its source."
.CW "Mach *m = &mach0;"
\(em an initialised pointer, because
.CW m
is in the data segment and an uninitialised one puts 0 in the image,
which a warm restart then loads back over a running kernel.  Checked
in the built image rather than assumed: the eight bytes at
.CW m 's
address read 0x269cb0, which is
.CW mach0 .
So there is no longer an instant in which
.CW m
is nil for a pending timer interrupt to find.
.PP
.B "The success rate is still not measured, and the last attempt to
.B "measure it produced false data."
.CW boot.sh
decides whether a kernel came up by counting banners in the screen
session's scrollback.  The session went away part way through the run.
.CW "screen -X hardcopy"
then fails
.I quietly ,
the count stays at zero, and every attempt is recorded as "did not
come up" \(em so a run of four failures was logged for a board that
may well have booted every time.  The first run, taken while the
console was alive, came up on attempt 1, which is the only datum in
that log worth keeping and is one sample.
.PP
.CW boot.sh
and
.CW install.sh
now refuse to run at all without a console rather than returning an
answer they cannot support.  An instrument that cannot see must say
so.  This is the third time in this port that a quiet failure in the
measuring apparatus has been mistaken for a result, and the other two
are written up above; the pattern is worth more than any of the
individual cases.
.NH 2
The warm restart is reliable, and it is measured without the console
.PP
.B "Ten out of ten."
.P1
restart 1: OK (alive 11497)   restart 6:  OK (alive 11568)
restart 2: OK (alive 11575)   restart 7:  OK (alive 11601)
restart 3: OK (alive 11551)   restart 8:  OK (alive 11586)
restart 4: OK (alive 11537)   restart 9:  OK (alive 11515)
restart 5: OK (alive 11481)   restart 10: OK (alive 11575)
TOTAL: 10 up, 0 down out of 10
.P2
against "about half the time" before.  Every tick count is near 11500,
which at HZ is 115 seconds -- the age of a kernel that has just
finished booting, not one that was already running.
.PP
Two changes could account for it and this run cannot separate them:
the static initialiser on
.CW m ,
which removes the nil-pointer window the pending clock fell into, and
.CW quiesce
clearing the per-core timer and mailbox enables, which removes the
pending clock.  Each is independently justified by a measurement, so
neither is a reason to drop the other, but the split between them is
not known.
.PP
.B "And the measurement does not go through the console, which is why
.B "it exists."
.CW tools/jtag/alive
reads
.CW m->ticks
at
.CW mach0 +0x28
over JTAG, twice, three seconds apart: advancing means a kernel is
alive and clocking, and a low count means it booted recently rather
than being the one that was already there.
.CW mach0 's
address comes from the symbol table, because it moves with every
build.
.PP
Every previous attempt at this number went through the serial console,
and the console is the least reliable part of this rig \(em the
adapter wedges, and the screen session died mid-run twice, which turns
"cannot see" into "did not boot" and invents failures for a board that
was fine.  Two whole runs were thrown away to that before the
instrument was moved off it.  The rule this keeps proving: measure
through the most reliable thing available, not the most convenient.
.NH 2
The console is now optional in both directions
.PP
The serial console is the least reliable part of this rig.  The
adapter wedges, the screen session has died three times in a day, and
every one of those looked from outside exactly like a board that had
crashed.  So none of the instruments depend on it any more.
.IP \(bu
.CW tools/jtag/kmesg
reads the kernel's own 16K console ring
.CW ( "struct { Lock lk; uint n; char buf[16384]; } kmesg"
in devcons.c) over JTAG.  The whole boot is in RAM whether or not
anything was listening to the UART.
.IP \(bu
.CW tools/jtag/alive
reads
.CW m->ticks
over JTAG: advancing means a kernel is clocking, a low count means it
booted recently.
.IP \(bu
.CW board.cmd
carries a command in over the styx mount and
.CW board.out
carries the answer back out.  Proven end to end with nothing attached
to the UART:
.P1
RCMD 1: cat /dev/sdN0/ctl
inquiry
geometry 30228480 512
sdhost rca 0x1234 blockaddr sectors 30228480 coreclock 250000000 cdiv 8
sdhost dma 0 dreq 13 retried 0 gaveup 0
part data 0 30228480
.P2
.PP
.B "Three things had to be fixed to get the last of those working, and
.B "two were mine."
.IP 1.
.CW sys->create
on the host returned
.I "permission denied" .
emu's
.CW setid()
gave the process uid and gid \-1 whenever the Inferno user had no host
account, so
.CW fsperm()
refused every create and write in a directory the host user owns.
Fixed on another branch months ago and never carried here;
cherry-picked.  The chan.c half of that commit was already present.
.IP 2.
.CW runremote()
unmounted only on the path where the create SUCCEEDED, so a refused
create left
.CW /n/remote
mounted, the next pass mounted over it, and the mounts piled up until
the loop stopped making progress \(em one command ran and then nothing
ever did.  That is the same mistake kupdate's own comments warn about,
made again two hundred lines away.
.IP 3.
.CW jtagreboot
cold-boots whatever is on the CARD;
.CW jtagrestart
loads the image just built.  Half an hour went into testing a fix
against a kernel that did not contain it.
.NH 2
Open: the host's styx server wedges during a large read
.PP
.B "Reproducible, and it is the blocker for the card-install path."
.CW kupdate
fetches a 1.9MB kernel over
.P1
emu -r <worktree> sh -c "styxlisten -A 'tcp!*!6666' export /"
.P2
and part way through that read the server stops answering.  It keeps
LISTENING and keeps accepting connections; it just never replies to
another Styx message, at 0% CPU.  The board's side reports it
correctly once the server is killed:
.P1
KUPDATE-FAIL read /os/inferno/raspi3b/kernel8.img: Hangup
.P2
It has happened on every fetch attempt this session bar one, and it is
not age \(em a server started seconds earlier wedges the same way.
.PP
.B "What has been eliminated."
The scheduler hang this tree already knows about is not it:
.CW emu/port/lock.c
has the release store in
.CW unlock()
.CW ( "__atomic_store_n(&l->val, 0, __ATOMIC_RELEASE)" ),
and the lost-wakeup race in
.CW qlock() 's
window between
.CW unlock(&q->use)
and
.CW osblock()
cannot bite because the semaphore counts \(em
.CW osready()
does
.CW sem->v++
and
.CW osblock()
waits on
.CW "while(sem->v == 0)" ,
so a wakeup that arrives early is kept.  Nor is it the devfs-posix
change cherry-picked today: the first wedge of the day predates it by
hours.
.PP
.B "The workaround, and why it is not urgent."
.CW jtagrestart
puts a kernel in RAM without going near the server or the card, and
that path is now reliable \(em ten warm restarts out of ten.  The card
only needs writing when the board must boot standalone.  So this is
logged rather than chased: it is a host-side emu bug, it wants its own
investigation, and nothing on the board is waiting for it.
.PP
.B "A local reproducer was claimed and does not hold up."
A 9P client on the host
.CW ( styxread.py ,
.CW styxabort.py
in the scratch directory) reads the same 1.9MB file the board fetches.
It does not wedge the server:
.IP \(bu
one connection reading the whole file: 239 reads, instant;
.IP \(bu
four concurrent connections reading it: all four clean;
.IP \(bu
six connections dropped abruptly mid-read (SO_LINGER 0, so a reset
rather than a clean close, which is what an unmount mid-fetch looks
like): the server stopped answering \(em ONCE.  Repeated twice more
against a freshly started server, it survived six drops both times,
and survived eight sequential drops with a probe between each.
.PP
So the abrupt-drop theory was announced on a single observation and
the repeat killed it.  That is the same error this document records
being made three times already, made again: a failing arm is not a
reproduction until it repeats, exactly as a passing arm is not a fix.
The one thing the client does establish is that size, concurrency and
reset-mid-read are each individually survivable, which is more than
was known before, and it is a fast harness for the next attempt \(em
seconds per trial, no board, no JTAG.
.NH 2
The styx server wedge, characterised: it stops accepting
.PP
.B "It is not a deadlock, and it is not the file service."
A
.CW sample
of the wedged emu says so.  Every Dis thread is idle:
.P1
7  __psynch_cvwait     (osblock -- blocked Dis processes)
1  __accept            (styxlisten, waiting for a connection)
1  __sigsuspend, 1 __semwait_signal, 2 mach_msg (Cocoa)
.P2
The
.CW exslave
processes are in
.CW "Sleep(&exq.rwait, exwork)" ,
which is their normal idle state waiting for work, and no thread holds
a lock.  Nothing is blocked reading a socket either.  So the file
service is fine and nobody is deadlocked; the work simply never
arrives.
.PP
.B "What is arriving, and not being taken."
With the server wedged, a fresh connection to port 6666 completes at
the OS level and then sits there:
.P1
tcp4  127.0.0.1.6666  127.0.0.1.59357  ESTABLISHED
tcp4  *.6666          *.*              LISTEN
.P2
while
.CW styxlisten
is blocked in
.CW accept() .
A completed connection is in the backlog and the accept never returns.
That is the whole failure in one line: the server stops accepting, so
every later mount hangs, which on the board looks like kupdate freezing
with no message at all.
.PP
.B "Eliminated."
Not descriptor exhaustion \(em 23 open files against a limit of a
million, one IPv4 socket.  Not the scheduler hang this tree knows
about \(em
.CW unlock()
has its release store and
.CW qlock() 's
pre-
.CW osblock()
window cannot lose a wakeup because the semaphore counts.  Not
.CW exslave 's
locking, which was read line by line on suspicion and releases
.CW exq.l
on both paths.  Not the devfs-posix change: the first wedge predates it
by hours.  And not anything a local 9P client can provoke \(em reads of
the same 1.9MB file, four concurrent readers, resets mid-read and
create-then-write all leave the server healthy.
.PP
.B "The hypothesis to test next."
An accept blocked on a stale listening descriptor: if devip recreates
the listening socket after an error and the accept still refers to the
old one, connections to the current listener would complete and never
be taken, which is exactly what is observed.  That is a guess and is
labelled as one; what is established is everything above it.  The next
step is to find which host descriptor that
.CW __accept
is waiting on and compare it with the socket the OS is queueing to.
.NH 2
Multi-block transfers: 474 KB/s to 12.8 MB/s
.PP
.B "The driver issued one command per 512-byte block."
CMD17 for every read and CMD24 for every write, each preceded by a
CMD13 status poll and followed by a 1ms settling delay.  That delay
alone caps the path near 500KB/s before anything else is counted, and
measured it ran at 474 KB/s.  Copying a 1.9MB kernel therefore took
minutes, and the cost was never the transfer \(em it was the ceremony
around each block.
.PP
CMD18 and CMD25 carry as many blocks as SDHBLC says in ONE data phase:
one command, one poll, one delay, one CMD12 at the end.  Swept on the
board, 512 blocks per request:
.P1
multi 1:    512 blocks in 540 ms =   474 KB/s
multi 8:    512 blocks in 100 ms =  2560 KB/s
multi 32:   512 blocks in  40 ms =  6400 KB/s
multi 128:  512 blocks in  20 ms = 12800 KB/s
.P2
Twenty-seven times faster, and 12.8 MB/s is the right order for a card
at 25MHz on four lines.
.PP
.B "The first attempt to measure this said it did not matter."
.CW wrverify
reported 3850, 3200 and 3970 ms for 1, 16 and 64 blocks per command
\(em no effect.  It calls
.CW sdhostbio
once per block, so the multi-block path never engaged and the test was
varying something it could not see.  A test blind to the thing it
varies will report that the thing does not matter, which is the most
expensive kind of wrong answer because it looks like a result.
.CW readspeed
and
.CW multiverify
issue ONE request of N blocks, which is what the change is about.
.PP
.B "Reads are the default; writes are not, yet."
.CW sdhostmulti
is 128 and applies to reads.  Writes stay single-block behind
.CW "echo multiwrite 1"
until a multi-block write has been verified on the board, because a
read that goes wrong is a wrong answer and a write that goes wrong is
a damaged card.
.CW multiverify
\(em write N blocks in one request, read them back in one, compare \(em
is written and has not yet been run to completion: it runs from
.CW board.cmd ,
which waits for kupdate, and kupdate is slow precisely because its
write side is still single-block.  That circle wants breaking with a
kernel whose boot script runs the check before kupdate, and it is the
next thing to do.
.NH 2
Multi-block, verified this time, and the stall it uncovered
.PP
.B "Two real faults were hiding under the speedup."
.IP 1.
A multi-block read overran the FIFO after eight blocks \(em first bad
byte 4092, sdhsts 0x8 \(em because the card streams continuously once
CMD18 starts and a per-word polling loop cannot drain it.  Worse, every
error path did "goto out" and skipped the CMD12 that ends a CMD18 or
CMD25, so the card was left mid-stream and the next cardready()
\(em a CMD13 \(em never saw TRAN again.  One failed read poisoned every
transfer after it, which is a far worse fault than the one that
started it.  CMD12 now runs on every exit.
.IP 2.
.B "The bounded retry was not a retry."
It re-issued the command immediately, and the counters said so:
.CW "retried 4 blocks, gave up on 1" .
Hammering a card that is not ready with the same command is the same
failure four times.  It backs off by the settling delay each round
now, and Maxretry is 8.  That alone turned the single-block case from
MISMATCH to OK \(em so this fixed the intermittent read stall this
document has carried unexplained since the SDHOST work began.
.PP
.B "Measured, and byte-compared, with those fixed:"
.P1
64 blocks,  1 per command:  write 270ms  read 60ms
64 blocks, 64 per command:  write 270ms  read 10ms
64 blocks, 64 + multiwrite: write  10ms  read  0ms
512 blocks (256KB), 64:     write  70ms  read 30ms
.P2
27x on writes, and every byte checked against what was written.  The
defaults are now 64 blocks a command with multi-block writes on.
.PP
.B "DMA is not part of it."
.CW "multi 64 dma 1"
still fails, and PIO at 64 blocks a command is fast enough that the
engine has nothing left to offer on this controller.  It stays behind
.CW "echo dma 1" .
.PP
.B "And the check runs on every boot, before kupdate."
.CW multiblockcheck()
in the SD suite runs single-block first so a failure says which arm
broke.  It was first written into
.CW board.cmd ,
which cannot work: that waits for kupdate, and kupdate was slow
precisely because of the thing being checked.  A test that cannot run
until the bug is fixed is no test.
.PP
.B "One loose end, recorded rather than waved away."
A
.CW multiverify
run from
.CW board.cmd
\(em concurrent with the boot's own kfs and dosfs, rather than from the
SD suite \(em failed at 256 blocks with
.CW "first bad byte 0" ,
single block per command, the write reporting success.  Every byte
wrong with a write that claimed to work is a different shape of fault
from anything above, and it happened only on the concurrent path.  The
boot-suite check, which is the authoritative one and runs with the
card to itself, passes all four PIO arms on every boot.  Whether that
concurrent failure is a real driver bug or the test racing the
filesystems over the same controller is not known, and it is the next
thing to settle: run the same check while a dd is running against
.CW /dev/sdN0/data
and see whether it reproduces.
.NH 2
How the concurrent failure gets fixed
.PP
.B "First, by noticing it was not interpretable."
Two agents were driving the card at once and BOTH were writing the
driver's global switches: the boot suite's
.CW multiblockcheck
and
.CW board.cmd .
The report even named a configuration the transfer had not run under
\(em logged "multi 1" for a write that went out at 128 \(em because
the print read the globals after the fact.  A result that cannot say
what produced it is not a result, and no amount of staring at that run
would have been worth anything.
.PP
.B "Then by fixing the real bug underneath it."
.CW sdhostmulti ,
.CW sdhostmultiwrite
and
.CW sdhostdma
were read fresh on every block of every transfer, so an
.CW "echo ... >ctl"
from anywhere could change a transfer's behaviour half way through: a
request could start single-block and finish multi-block, or start in
PIO and finish in DMA.  They are sampled ONCE now, into locals, under
the qlock that already serialises transfers.  That is a correctness
fix independent of any test: a driver whose behaviour can change
mid-request has no defined behaviour.
.PP
.B "And by making the check restore rather than impose."
.CW multiblockcheck
ended with "multi 1; multiwrite 0", which is not restoring the
driver's defaults \(em it is quietly overriding them on every boot
with the old slow settings.  It puts them back to what the driver
declares.
.PP
.B "What is still owed."
The deliberate version of the experiment: one agent, no switch
writing,
.CW multiverify
running while a
.CW dd
works the same controller.  It is written into
.CW board.cmd
and has not yet produced a result, so whether there is any concurrent
fault left is still unknown.  What can be said is that the run which
raised the question could not have answered it either way.
.NH 2
The concurrent fault was real, and it was another spin count
.PP
.B "The experiment finally ran, because it stopped needing the network."
It lived in
.CW board.cmd ,
which needs the styx mount, which needs kupdate, which needs the host
\(em so a test of the CARD kept not running for reasons that had
nothing to do with the card.  Moved into the SD suite it needs nothing
but the board: spawn a process reading the raw device in a loop, run
.CW multiverify
against it, stop the reader.
.PP
.B "It failed immediately, twice, and said why."
.P1
write block 2920000 failed: sdhsts 0x0 sdcmd 0x99
    sdedm 0x10907 (fsm 7 fill 16) sdhblc 64
retried 0 blocks, gave up on 1
MULTIVERIFY-FAIL write 0 of 131072
.P2
FSM 7 is WRITEWAIT1, fill 16 is a FULL FIFO, and there is no error bit
anywhere: the card was busy programming and had not drained yet.  The
whole 128KB request was refused.  And
.CW "retried 0"
says the retry never even fired, because its guard wants the FSM in
DATAMODE and this one was not.
.PP
.B "The cause: a bounded spin standing in for a timeout, again."
The write waited for FIFO room with
.CW "if(++tries > 20000)" ,
about 160ms of 8us delays, and the SD specification allows a card
250ms to program a block.  Under contention it needs it.  That is the
same fault as the DMA engine's
.CW Timeout ,
found and fixed in the same week, in a different file, by the same
reasoning: a spin count is a timeout whose length is a property of the
machine rather than of the hardware it waits for.  It waits by the
1MHz counter now, up to a second, and restarts the clock whenever
progress is made.
.PP
.B "Result, with a reader hammering the same controller throughout:"
.P1
MULTIVERIFY-OK 256 blocks at 2920000: write  60ms read 10ms
MULTIVERIFY-OK 256 blocks at 2930000: write 530ms read 10ms
.P2
128KB written and read back byte-correct, twice, under load.  Every
PIO arm of the boot check now passes.
.PP
.B "And it closed a second bug that looked separate."
A failed DMA transfer appeared to leave the next request unusable: run
the DMA arm in the middle and the transfer after it came back "write 0
of 131072".  That was written down as its own open bug.  It was not \(em
it was this one.  A failed DMA leaves the card busy, and the next
write then had 160ms to wait out a card that is allowed 250ms.  With
the clock-based wait, the DMA arm still fails and the transfer after
it passes:
.P1
MULTIVERIFY-FAIL 64 blocks at 2900700 (multi 64 dma 1) MISMATCH
MULTIVERIFY-OK 256 blocks at 2920000: write 1370ms read 10ms
MULTIVERIFY-OK 256 blocks at 2930000: write  550ms read 20ms
.P2
1370ms is the recovery being waited out rather than given up on.  Two
symptoms, one cause, and the second would have been chased separately
if the arm had been left running last where it could not be seen.
.PP
What remains is narrow: DMA paired with multi-block returns wrong data.
DMA is off by default, PIO at 64 blocks a command is fast, and the
failure no longer harms anything around it.
.NH 2
The dosfs panic was a failing card, not a driver bug
.PP
.B "The symptom."
Every boot ended the same way:
.P1
sdhost: read block 61213 failed: sdhsts 0x8 ... sdhbct 6 sdhblc 6
sdhost:   retried 8 blocks, gave up on 1
dosfs: panic: read
.P2
The filesystem died, and with it
.I /n/dos ,
the kernel update, and the board's only channel for reporting off
itself.
.PP
.B "Three fixes that did not move it."
A FIFO error was excluded from the retry guard, so the one error most
worth retrying was the one never retried; the retry re-issued the
command without the CMD12 that ends an abandoned CMD18 stream, so the
card was still in state 5 (DATA) and every retry hit the same wall; and
.CW fifodata
waited on a spin count rather than a clock, the last such wait in this
driver after the DMA engine's and the write side's were converted.
All three were real, all three are fixed, and the panic happened again
on the next boot, unchanged.
.PP
.B "What it actually was."
The driver has
.CW readspeed
in its ctl interface and the console shell survives the panic, so the
failing read can be issued by hand instead of by waiting four minutes
for another boot.  Single blocks, in isolation:
.P1
61213  ok      61216  FAIL
61214  ok      61217  FAIL
61215  ok      61220  FAIL
61230  ok
.P2
A bad region of about fourteen sectors, inside the FAT partition,
deterministic across every boot and untouched by every timing change \(em
which is exactly why three correct fixes moved nothing.
.PP
.B "Proof, not inference."
An SD card remaps a bad block when it is written.  Writing over the
region and re-reading it:
.P1
MULTIVERIFY-OK 8 blocks at 61216: write 10ms read 0ms
readspeed 61216 1   1 of 1 blocks
readspeed 61220 1   1 of 1 blocks
readspeed 61213 6   6 of 6 blocks
.P2
The last line is the exact read that had killed dosfs on four
consecutive boots.  The media was bad; the driver was reporting it
correctly.
.PP
.B "What the session is owed."
The three driver fixes stay \(em they are right, and a FIFO error from
a driver-side overrun is still worth retrying.  One number changed
afterwards: the read wait is now
.CW Readwaitus ,
200ms, not the write side's 1s.  A write waits on a card that the
specification allows 250ms to program; a read waits for data already
asked for, whose access time is tens of milliseconds.  Waiting a second
eight times over bought nothing on a sector that could never answer and
cost nine seconds each time it happened.
.PP
.B "Still open."
Whether this card has more weak sectors elsewhere.  A full surface read
would say, and the kernel update rewrites 1.9MB of it as a side effect.
And dosfs panicking on a read error rather than returning one is a real
fragility \(em one bad sector should not take a filesystem down \(em but
it was left alone deliberately today, because that panic was the only
signal the fault had.
.NH 2
The kernel update is a shell script now
.PP
.CW kupdate() ,
two hundred lines of Limbo that dialled the host, mounted it, read
1.9MB in chunks with its own progress counter, checksummed what had
landed and renamed twice, is gone.
.CW remotecmd()
already mounts the host on
.CW /n/remote
and redirects a script's output to a file on it, so the update is what
it always was underneath:
.P1
cp $K /n/dos/kernel8.new
cmp $K /n/dos/kernel8.new
cp /n/dos/kernel8.new /n/dos/kernel8.img
cmp $K /n/dos/kernel8.img
.P2
.CW cmp
is the checksum, compared against the source rather than against a
number derived from it.  The gain is not brevity: the Limbo version
reported only to the console, so an update that had stopped and one
still running looked identical, and it held
.CW /n/remote
while it ran \(em shutting the one channel that reports off the board for
the whole of the operation most likely to hang.
.NH 2
Why the kernel update takes half an hour: it is the board's network
.PP
.B "The measurement."
The update copies 1.95MB from the host to the card and took 35m50s.
Split into its two halves, each measured on its own:
.P1
1MB written to the card through dossrv      7 s
1MB read from the host over styx          419 s
.P2
The card is not the bottleneck.  Sixty times over, the cost is the
board reading from the host.
.PP
.B "Client or host?"
The same host server, the same file, the same 1MB in 8KB reads, from
this machine over loopback instead of from the board:
.P1
host -> its own server, loopback          0.46 s
board -> same server, USB ethernet         419 s
.P2
Nine hundred times.  The host side \(em
.CW exportfs ,
the per-request workers, the dispatch rewritten earlier in this work \(em
is not involved.  The fault is on the board.
.PP
.B "What it is not."
Four mechanisms were proposed and each was killed by a measurement
rather than by argument:
.IP \(bu
.I "The USB bulk-IN watchdog."
.CW usbdwc
re-arms a stalled endpoint after two seconds and says so, and three
seconds a read looked like exactly that.  The re-arm counter did not
move at all across the slow reads.
.IP \(bu
.I "A size threshold."
Small reads looked a hundred times faster per byte than large ones.
That never reproduced.  It was an instrument fault: the console timer
matched a marker at the start of any line, and a long typed command
wraps, so it was matching the ECHO of the command rather than its
completion.  The check now requires the marker to be the whole line.
.IP \(bu
.I "TCP backpressure."
The host's socket shows send and receive queues both empty and
.CW emu
at 0% CPU throughout \(em it has nothing to send and is waiting to be
asked.
.IP \(bu
.I "A wakeup that any packet would deliver."
Two hundred pings at 200ms intervals through a stalled read changed
nothing.
.PP
.B "What is left."
The board stops issuing requests.  The host is idle with empty queues,
the data that was asked for has arrived, and seconds pass before the
next Tread goes out.  The strongest remaining signal is that it is
.I concurrency :
the console and
.CW remotecmd
were both reading through
.CW /n/remote
when it stalled hardest, and
.CW remotecmd
has now twice failed to print RCMD-END after its script finished \(em it
does not return from
.CW runremote ,
whose only work after the shell exits is closing the output file, two
dups, and unmounting the mount the script was itself using.
.PP
.B "Two things this cost."
The cluster size was guessed at and believed for an hour.  dossrv now
prints its geometry at mount, and it says 8 sectors to a cluster, not
the one that was assumed \(em so the track-size change made on that
theory was backed out.  And
.CW cmp
reported the installed kernel differing from the source at byte 442,
which was not corruption: the source was rebuilt while
.CW cp
had it open.  The card holds a complete 1949000-byte kernel, the size
of that mid-copy build.  The update path works.
.NH 2
The bottleneck is the host's styx server, and it stops accepting
.PP
The profile above said the board was slow and the host was fast, and
that was measured at a moment when the host happened to be healthy.  It
does not stay healthy.  Fifty minutes later the same loopback read that
took 0.46s had not finished in 400s, and a bare Styx handshake \(em
connect, send Tversion, wait \(em timed out three times at twenty
seconds each.
.PP
.B "What the server looks like when it has stopped."
.P1
lsof: emu holds ONE socket, *:6666 (LISTEN)
netstat: two connections ESTABLISHED, recvq=19 each
sample: a thread inside accept(), via
        Sys_open -> kopen -> namec -> ipopen -> so_accept
.P2
Nineteen bytes is exactly a Tversion.  Both clients completed their TCP
handshake, sent their first message, and waited.  The server never took
either connection: it holds no descriptor for them, so they are sitting
in the kernel's accept backlog \(em while one of its own threads is
blocked inside
.CW accept (2)
on the socket that backlog belongs to.
.PP
.B "Proved rather than inferred."
Open a fresh connection and watch the server's descriptor count:
.P1
emu fds before:  1   (the listener)
connected
emu fds during:  1   (unchanged)
.P2
.CW accept
does not return.  A restart fixes it completely \(em 1MB over loopback in
0.54s immediately afterwards, against a read that had hung past 400s
minutes earlier \(em which is what establishes that the server, not the
board, is the thing that degrades.
.PP
.B "Why every earlier measurement disagreed with the last."
Every board number in this work \(em the 36-minute copy, 419s for 1MB,
3.1s a read, the sizes that looked fast and then did not reproduce \(em
was taken against a server somewhere on its way from healthy to
stopped.  That is the whole of the variance, and no property of the
board explains any of it.  The Styx handshake in
.CW tools/jtag/styxd.sh
takes under a second on a healthy server and is the honest way to ask
before believing any number measured through it.
.NH 2
board.cmd ran exactly once per boot: sh->init() does not return
.PP
Four boots printed RCMD-BEGIN 1 and never RCMD-END, and it was read as
a hang three times.  It was not a hang \(em the process was gone.  Five
Init processes before the script, three after; a blocked process is
still in
.CW ps
and this one was not.
.PP
.CW sh.b 's
.CW init() ,
given
.CW -c
and not interactive, finishes its work with
.P1
if (status != nil)
        raise "fail:" + status;
exit;
.P2
and
.CW exit
terminates the process that called
.CW init .
So
.CW runremote 's
.CW "sh->init(nil, \"sh\" :: \"-c\" :: cmd :: nil)"
killed
.CW remotecmd
every time a script SUCCEEDED, silently, with no exception to catch.
The script itself ran and its output reached
.CW board.out ,
which is why this looked like a wedge rather than a death.
.PP
The shell runs in a spawned child now, which shares the descriptor
group (so it inherits the redirection to
.CW board.out )
and the namespace (so it sees
.CW /n/remote ),
and the parent waits for
.CW /prog/<pid>
to go.  RCMD-END 1 now prints and the poller survives its script.
.NH 2
Fixed: a flushed request was answered twice
.PP
.B "The sequence, from the server's own trace."
.CW INFERNO_MNTDEBUG=1
prints every message on the shared pipe, and the fault is one screen
long:
.P1
-> T116 tag 1 fid 31     the read
-> T108 tag 2 fid 0      flush it
<- R109 tag 2            Rflush: "that reply will never come"
-> T104 tag 1 fid 37     tag 1 reused, correctly
<- R117 tag 1 len 4107   the read's reply, after all
mnt: mismatch ... T104 R117
.P2
The server answered Rflush and then sent the flushed request's reply
anyway.  The client had been told the tag was free, reused it, and
received somebody else's answer.
.PP
.B "Two bugs, both in emu/port/exportfs.c."
.IP 1.
.I "A registration race."
A request joined
.CW fs->work
inside the WORKER, but the reader spawns a worker and goes straight
back for the next message.  A Tflush naming a request already handed
out therefore found an empty list, reported "not found", and the reader
answered Rflush while the worker was still running.  The request now
joins the list in the reader, before it can read anything else \(em the
only place where finding it is guaranteed.
.IP 2.
.I "A double reply."
.CW "if(q->flush == nil || err == nil)"
sent the original reply whenever the request had SUCCEEDED, even though
it had been flushed, and then sent the Rflush as well.  Two replies for
one tag.  Whatever work was done is wasted either way; sending it is
not a saving.  It is now
.CW "if(q->flush == nil)" .
.PP
.B "Measured."
.CW tools/jtag/styxabrupt.py ,
which kills clients mid-read the way the board does on every reboot:
.P1
before   DEAD after 5 disconnects
after    survived 500, worst health 0.030s, 0 mismatches
.P2
And nothing else moved: 500 clean connections in 2.0s, 179MB through a
bulk reader while 200 more connect.  The
.CW mntfree
tag-retirement guard added while hunting this now never fires \(em zero
tags retired in 100 disconnects \(em because no rpc is abandoned
unanswered any more.  It stays as a check on a real invariant, at no
cost.
.PP
.B "On the board."
1MB over styx went from 419s to 23s, and the kernel update from 35m50s
to 160s.  What the update reports now is the truth about the card:
.P1
error on /n/dos/kernel8.new after 1245184 bytes
KU-CMP read error
.P2
.CW "sdhost: read block 61213 failed ... gave up on 1" .
That is the bad media found earlier in this work, reported as an I/O
error instead of a panic, and it is the next thing in the way.
.NH 2
A control card settles it: the old card was bad
.PP
A spare 32GB card, formatted FAT32 and given the Pi firmware, our
config.txt and a kernel, booted first time.  The same suite, same
kernel, same driver:
.P1
                          old card      new card
first two MULTIVERIFY     FAIL always   pass
sdhsts 0x8 / retries      routine       none
MULTIVERIFY writes        360-1370ms    0-110ms
FAT-BIG 1.5MB             46.8s         16.2s
DMA + multi-block arm     MISMATCH      MISMATCH
.P2
So the intermittent read stalls, the retries, and the long-standing
"first two MULTIVERIFY arms fail after boot" were the MEDIA, not the
driver \(em and several of them had been written down here as driver
mysteries.  The one failure that reproduces identically on both cards
is DMA paired with multi-block, which is therefore really the driver,
and is already off by default.
.PP
The old card's own story is odder than "dead page".  Blocks
61216..61222 were unreadable on every attempt across hours and several
boots, from a clean reinit, with neighbours reading in 0ms and a
control region far away perfect.  Then, after the files occupying them
were deleted, a full scan of all 130814 clusters came back clean and
those same blocks read in 0ms.  Marginal, state-dependent cells rather
than a cleanly failed page.
.NH 2
Handling a bad card, which is a common thing and was not handled at all
.PP
FAT has always had a way to say "never allocate this": the reserved
entry 0xFFFFFF7.  dossrv honoured it without knowing it \(em
.CW falloc()
takes only clusters whose entry is 0, so anything else is skipped \(em
but nothing in this system could WRITE one.  So one dead page was
handed to whoever wrote next, for ever: deleting the kernel and copying
it again landed on the same clusters and failed at the same byte,
1245184, every single time.
.PP
Three things now, all in
.CW dossrv
rather than beside it, because
.CW putfat()
already knows which width the entries are and writes EVERY copy of the
FAT \(em which is what stops a repair program later "fixing" the
partition by copying a stale FAT back over the work.  Written as a
separate tool first, that had to be guessed at twice.
.IP 1.
.CW "dossrv -b"
scans the partition and marks every unreadable cluster bad;
.CW -B
reports without changing anything.  A cluster already in use is
reported and left alone: marking it would cut its file in two and give
the tail to the next writer, which is worse than an unreadable block
that announces itself.
.IP 2.
.CW falloc()
verifies a cluster before allocating it, and marks it bad and moves on
if it cannot be read.  One read per cluster allocated \(em 128 of them
for a 2MB kernel at 16KB clusters \(em and the filesystem never hands
out a block the card cannot deliver.
.CW -A
turns it off.
.IP 3.
A short read is an error and not a panic, and it does NOT drop the
device; only that one request fails.
.PP
And the update itself never removes kernel8.img until a verified
replacement is on the card.  It did, once, with
.CW mv
in the middle \(em and
.CW mv
raises "permission denied" on the board although
.CW /dis/mv.dis
is present, readable, the right size, and works under the host emu.
That is unexplained and is why the script uses
.CW cp
and a verify instead.
.NH 2
Measured, end to end
.P1
KU-COPY    ok      1.95MB fetched over styx
KU-CMP     ok      matches the host byte for byte
KU-INSTALL ok
KU-VERIFY  ok      the installed kernel matches the host
.P2
286 seconds for the whole cycle, against 35m50s for the attempt that
failed its verify.
.PP
.B "One of those minutes was mine."
The server was left running with
.CW INFERNO_MNTDEBUG=1
after a debugging session.  A traced server prints two lines per Styx
message and is about thirty times slower \(em 1MB over loopback 0.42s
becomes 17.4s, a handshake 0.001s becomes 5s \(em which looks exactly
like the fault the tracing exists to find, and was reported as a
regression.
.CW styxd.sh
now says so, loudly, before it does anything else.
.NH 2
The mount kept going away
.PP
A mount made by hand at the console
.P1
mount -A tcp!192.168.8.233!6666 /n/remote
.P2
succeeded, listed the host's files, and was gone moments later \(em over
and over.  Baffling from that end, and obvious from the other:
.CW remotecmd()
mounts the host on
.CW /n/remote ,
reads
.CW board.cmd ,
unmounts, and does it again fifteen seconds later, and it was doing all
of that in the namespace everything else shares.
.PP
It has its own now.
.CW "sys->pctl(Sys->FORKNS, nil)" ,
placed after the wait for
.CW kudone
and not at the top of the function: the copy has to be taken after
.CW fatcheck
has mounted
.CW /n/dos ,
or every board.cmd script loses the card.  The shell that
.CW runremote
spawns shares this namespace and still sees both; the console sees
neither of the poller's mounts, which is the point.
.PP
Verified: the poller still runs (board.out is written, so it still has
its own
.CW /n/remote ),
a hand mount at the console survives five poll cycles, and scripts still
reach
.CW /n/dos .
.NH 2
Why the board is slow over styx: the MTU, and a cliff at eleven frames
.PP
The board reads about 50KB/s from the host while this machine reads the
same file from the same server in under half a second.  The cost is
per MESSAGE, not per byte:
.P1
256KB as 256 reads of 1024   32s
256KB as  64 reads of 4096    4s
256KB as  32 reads of 8192    2s
.P2
.B "It is the MTU."
Ping the board with payloads either side of 1500 bytes and the shape is
unmistakable:
.P1
payload  frames   min RTT   avg RTT
    64      1      5.6ms     20.3ms
  1400      1      7.8ms     15.1ms
  4000      3      9.8ms     20.5ms
  8000      6     14.6ms     47.6ms
 16000     11        --      100% LOSS
.P2
One Styx message of 8KB is six Ethernet frames, and six frames cost
about 48ms \(em which is the per-message cost measured above, arrived at
from the other direction.  Eleven frames are not delivered at all.  The
board's receive path degrades with burst length and then falls off a
cliff.
.PP
.B "Which kills the obvious idea."
emu's exportfs has always been willing to grant up to
.CW MAXRPCMAX ,
64KB, and clamps to whatever the client asks; the client
.CW ( devmnt 's
.CW MAXRPC )
never asked for more than 8KB.  Raising it to 64KB looks like an eight
fold cut in round trips and is not: 64KB is forty four frames, far past
where this board already loses everything.  It was tried, and
.CW ls
came back "stat buffer too small".  Reverted.
.PP
.B "And an attempted fix that was not kept."
.CW rxproc
in
.CW etherusb.b
reads the bulk-in endpoint one transfer at a time, and on an empty read
\(em which the SMSC chip returns immediately when its FIFO is empty,
because smscsetup sets Bir \(em it sleeps 10ms.  A request/response
protocol is idle exactly while it waits for its reply, so that put up to
10ms in front of every one.  Backing off adaptively instead did improve
the packet: 8000-byte ping average fell from 47.6ms to 19.3ms.  It made
the WORK slower \(em 1MB went from 20s to 42s \(em because the yield in
the fast path starves the rest of the VM.  A 1ms sleep instead split the
difference and left a 200s outlier in three runs.  None of that is a
result worth shipping, so it is reverted and written down here instead.
.PP
.B "What the next attempt should do."
Not tune the sleep.  The receive path posts one transfer at a time and
has nothing armed between the read returning and the next one being
posted, which is what makes a burst expensive and an eleven frame burst
fatal.  Keeping several buffers posted is the change that would matter,
and it is a real piece of work rather than a constant.
.NH 2
Correction: there is no cliff, and four attempted fixes all made it worse
.PP
.B "Retracted."
The section above reports 100% loss at eleven frames.  Repeated, that
does not hold: three tries of a 16000-byte ping, 0% loss every time.
Whatever produced the total loss was a state the board was in, not a
property of eleven frames, and it was measured once and believed \(em the
same mistake this work has made repeatedly and written down twice.
.PP
.B "What survives repetition is the MINIMUM."
Three rounds of fifteen pings each:
.P1
             round 1   round 2   round 3
1400B  (1 frame)  6.32ms    6.43ms    6.55ms
8000B  (6 frames) 28.8ms    29.9ms    29.3ms
.P2
That is stable to a tenth of a millisecond, and it says about 4.6ms per
additional frame against a 6.4ms floor.  The AVERAGES, which the earlier
section quoted, ranged from 15ms to 87ms for the same 8000-byte case
across the afternoon and carry no information at all.
.PP
.B "Four fixes, four regressions, all reverted."
.IP 1.
.I "64KB Styx messages."
Eight times fewer round trips on paper.
.CW ls
returned "stat buffer too small".
.IP 2.
.I "Adaptive backoff in rxproc, yielding."
8000-byte ping average 47.6ms to 19.3ms, and 1MB of real work 20s to
42s: the yield starves the VM.
.IP 3.
.I "Adaptive backoff, 1ms sleep."
Within noise on throughput, and one run in three took 200s.
.IP 4.
.I "Four receive transfers kept posted."
The one with a mechanism behind it \(em devusb serialises endpoint reads
on a FIFO qlock, so a queued reader should issue the instant the last
completes.  It was the worst of the four: 1400-byte ping 15.1ms to
33.4ms with eleven of twelve pings LOST, and 8000-byte 47.6ms to 87ms.
The SMSC bulk-in stream is a packed sequence of status-prefixed frames
per transfer, and concurrent transfers do not survive it.
.PP
The tree is back to where it started on all four.  What is left is a
real measurement \(em 6.4ms for one frame, 4.6ms for each one after \(em
and no fix.
.NH 1
Phase 6 on real silicon: what exists, what is missing, and the trap
.PP
Surveyed rather than started, because one of the obvious first steps
would take the board off the network and off its update path.
.PP
.B "What already exists, and is better than the plan above implies."
.IP \(bu
.CW sdioinit()
in
.CW sdhcibcm.c
\(em a bring-up that is a SEPARATE entry point from
.CW sdhcicardinit()
precisely so it never touches the card pins, with the SDIO sequence
(no CMD8, no ACMD41, no CSD) and GPIO 34-39 in alt3, which is where a
real Pi puts the Wi-Fi.
.IP \(bu
.CW sdiocmd52 / sdiocmd53 ,
byte and block mode, exercised against the generic
.CW sd-io
model in tools/qemu-patches and reported
.CW SDIO-OK .
.IP \(bu
WL_ON.
.CW mailbox.c
drives the VideoCore GPIO expander the ARM cannot reach, and names the
lines: 128 is BT_ON, 129 is WL_ON, the Wi-Fi radio's enable.  A radio
that is never powered looks exactly like a radio that is not
answering, and this is what avoids that.
.PP
.B "What is missing."
.IP 1.
.CW sdhcibcm
is NOT IN THE BOARD'S KERNEL.  The raspi3b config lists
.CW sdemmcbcm
and
.CW sdhostbcm
only, so every line of SDIO code above is compiled out on real
hardware.  That is why nothing about SDIO appears in any boot log.
.IP 2.
.CW ether4330
does not exist in this tree.  Only
.CW os/9front/boot/ether4330.proto
is here, which is the firmware MANIFEST, not the driver.
.IP 3.
The firmware blob.  That manifest names
.CW brcmfmac43430-sdio.bin
for this chip and it is not in the tree either.
.PP
.B "THE TRAP, which is why this stops here."
Adding
.CW sdhcibcm
to the config is the obvious first move and it would take the card
away from SDHOST.
.CW sdhcionline()
calls
.CW sdhcicardinit() ,
whose first act is
.P1
	for(i = 48; i <= 53; i++)
		gpiofsel(i, Alt3);
.P2
unconditionally.  On this board the card is on SDHOST as
.CW /dev/sdN0 ,
.CW SDDEV
in raspi3binit.b names it, /n/dos rides on it, and
.CW tools/jtag/kinstall.sh
installs kernels through it.  Stealing those pins costs the update path
and the recovery would be a card reader or JTAG.
.PP
.B "So the order, when this is picked up."
.IP 1.
Make the card path in
.CW sdhcibcm
not run on this board \(em the driver's own comment says the split
exists for exactly this \(em so the unit comes up SDIO-only and never
calls
.CW sdhcicardinit() .
Verify /dev/sdN0 still reads before anything else.
.IP 2.
Add it to the config; its idno is 'H' and the card's is 'N', so the
letters do not collide.  Call
.CW sdioinit()
and WL_ON, and see whether a BCM43430 answers CMD5 on real silicon.
That is the first thing in this whole phase that QEMU cannot tell us.
.IP 3.
Only then port ether4330 and find the firmware.  Both are pointless
until a chip has answered.
.SH
What step 1 and 2 actually cost, and the two bugs they uncovered
.PP
Steps 1 and 2 above were tried.  The
.CW sdhcicard
guard worked: the card survived, /dev/sdN0 read, /n/dos mounted, and the
kernel reported
.CW SDIO-NONE
\(em bring-up stopped at CMD0/CMD5 with WL_ON unset, which is
inconclusive by design, because an unpowered radio and an absent one
look alike.
.PP
What was not expected is that the board became unreachable.  That kernel
booted completely \(em card, FAT, USB ethernet, DHCP, DNS, an
interactive shell \(em and answered nothing.  Recovery was JTAG.  Two
independent defects were behind it, and neither is about Wi-Fi.
.PP
.B "The remote command poller failed silently."
Every giving-up path in
.CW remotecmd
returned nil: no kupdate.txt, dial refused, mount refused, board.cmd
unreadable, a short read.  The caller cannot tell nil from \fIboard.cmd
has not changed\fP, so a poller failing every fifteen seconds looked
exactly like one with nothing to do.  The console has been deaf on this
desk for months \(em that is why the poller exists \(em so there was no
second opinion to consult.  It now prints
.CW RCMD-ON
with the address it polls,
.CW RCMD-NOADDR
naming which step of reading kupdate.txt failed,
.CW RCMD-DOWN
on the first failure and every twentieth after it, and
.CW RCMD-UP
on recovery.
.PP
.B "remotecmd took its private namespace before the network existed."
.CW remotecmd
calls
.CW "sys->pctl(Sys->FORKNS, nil)"
and dials through that snapshot for the life of the boot.  Taken before
ethercheck's
.CW "sys->bind(\"#I\", \"/net\", ...)" ,
the snapshot has no /net and no later bind can put one there, so every
poll fails with \fIfile does not exist\fP until reboot.  The bind's own
comment already warned about that error string, for a different reason.
.PP
The race has always been there and usually won.  A kernel that did a
little extra work early in
.CW main()
\(em the SDIO probe \(em was enough to make it lose.  The new
instrument is what caught it: with the poller reporting, one hardcopy
showed
.CW RCMD-ON
at line 177 and
.CW ETHERBIND-OK
at line 179.  Read by line number, never by presence: that scrollback
holds several boots and any string worth grepping for is already in it.
.PP
The fix is a
.CW netdone
flag set when an interface has been bound and has an address, which
remotecmd waits for alongside
.CW kudone
before FORKNS, bounded at 180 seconds so a board with no ethernet still
reaches the code that says why it is unreachable.  Verified by the same
line-ordering check: ETHERBIND-OK 188, ETHER-DHCP-OK 189, RCMD-ON 192.
.PP
.B "kinstall.sh now refuses to install a kernel it has not proved."
It boots the candidate over JTAG into RAM \(em the card untouched \(em
requires that build's own stamp, and then requires the board to answer
a command through the poller.  Only then does it stage, back up and
write.  It also leaves board.cmd harmless on every exit: it used to
leave
.CW "echo reboot > /dev/sysctl"
there, and remotecmd's memory of the last command does not survive the
reboot it just performed, so the board came up, saw a command it had no
record of running, and rebooted again, every fifteen seconds.
.PP
Be clear about what that gate does and does not buy.  It catches a
kernel that is broken.  It does not catch a kernel that \fIraces\fP: a
JTAG boot into RAM and a boot from the card have different timing, and
this very race passed the pre-flight and then failed the post-install
check.  Failing late is better than not failing, and the card still has
kernel8.bak, but the pre-flight is not a proof of drivability from the
card.
.PP
.B "The install steps are guarded on the board, with sh's \f(CWand\fP."
.CW "cp a b; cmp a b"
runs the cmp whether or not the cp worked, and every step of the
installer used to be that shape: the board ran both unconditionally and
the host decided afterwards by reading text out of board.out.  A missing
marker and a failed step were the same observation, and the next
destructive step went out anyway.
.PP
.IR sh-std (1)
has
.CW and ,
which evaluates each command until one returns false, and both commands
involved report properly:
.IR cmp (1)
raises
.CW fail:differ
on a difference and
.CW fail:open
if it cannot read a side, and
.IR cp (1)
counts every warning and raises
.CW fail:error
at the end.  So each step is now a chain ending in its own marker, and
the marker is reached only if every link was true.
.PP
Measured on the board, both directions, because a guard that has only
ever been reasoned about is not a guard: with two files that differ the
chain stopped and the marker did not print, and the script carried on to
its next command; with two that match the marker printed.  The end token
is echoed OUTSIDE the chain, so it prints either way and a failed step
is seen in seconds instead of at the timeout.
.PP
Before the overwrite the board re-checks, itself, that kernel8.bak still
matches the kernel8.img it is about to replace \(em a verified way back
must exist at that moment, not merely have existed when the host checked
minutes earlier.  Deliberately the local check and not a second remote
one: a single compare of this 1.9MB kernel across the styx mount took
most of ten minutes, and KI-STAGED has already proved the staged file
against the host.
.SH
Wi-Fi on real silicon: what the board actually says
.PP
With the board reachable again, the SDIO probe was installed and read.
Four findings, in the order they were established, each from a probe
built to separate causes that had been sharing one message.
.PP
.B "The radio is already powered, and the earlier ambiguity is gone."
.CW GET_GPIO_STATE
(tag 0x00030041) answers for every expander line, and the values are
coherent rather than a uniform unfilled buffer: 128 BT_ON 1, 129 WL_ON
1, 130 PWR_LED_OFF 0, 131 GLOBAL_RESET 1.  WL_ON reads 1.  So the
\fIsleeping radio and an absent radio look alike\fP caveat no longer
applies \(em the chip has power and still answers nothing.
.PP
.B "This firmware has GET_GPIO_STATE but not SET_GPIO_STATE."
.CW SET
(tag 0x00038041) comes back with bit 31 of the tag response clear, which
in this protocol means the firmware did not handle the tag \(em not that
it handled it and refused.  A malformed request looks the same from
outside, so two controls were needed.  First: the rest of mailbox.c \(em
memory, MAC, board revision, serial, OTP, clocks, framebuffer \(em
answers through the identical request path, and
.CW mboxsetgpio
is built field for field like
.CW mboxsetclock ,
which works.  Second, and decisive: writing line 130 back the value it
already reads is refused in exactly the same way.  So it is the tag that
is missing, not the line that is protected.  Firmware revision
0x6a0eead5.
.PP
.B "The identification clock was out of spec, and that was not the cause."
.CW sdhcictlrinit
hardcoded divider 0x80 with a comment claiming it was slow enough from
any plausible base clock.  The base clock, read from the controller's
own capabilities, is 200MHz, so 0x80 \(em the 8-bit divided-clock form,
dividing by 2N \(em was running identification at 781kHz against a
400kHz ceiling.  Eight bits cannot express what is needed here; SDHCI
3.0 keeps the top two bits of a 10-bit divider in Control1 bits 6-7.
It now computes the divider from the base clock and reports it: 250,
400000 Hz exactly.  A missing post-clock settling delay was added with
it.
.PP
Nothing before CMD5 could ever have exposed this, which is why it
survived: CMD0 carries no response and therefore cannot fail, so a
passing CMD0 is not evidence that the bus works.  Say plainly what the
fix did: it corrected a real out-of-spec clock and it did NOT change the
outcome.  CMD5 fails identically before and after.
.PP
.B "CMD5 times out with the bus idle."
The controller initialises, CMD0 is accepted, and CMD5 returns
interrupt 0x18000 \(em Interr plus bit 16, command timeout \(em with
status 0x1ff0001: card present, and every DAT line and CMD sitting
high.  Pull-ups are doing their job and nothing is pulling them down.
The controller drove the command and no device on those pins answered.
.PP
.B "So the next step is the firmware on the card, not more driver work."
The BCM43430 wants its enable toggled to reset it into SDIO mode, and
with no SET_GPIO_STATE there is no way to toggle it from here.  Every
remaining driver-side theory \(em pin routing, clock, controller
setup \(em is now checked or corrected, and the one thing that cannot
be done at all is the one thing a non-responding radio most wants.  The
boot partition is writable through
.CW /n/dos ,
so replacing start.elf and bootcode.bin with a firmware that carries the
tag is a real option and should be tried before anything else.  Porting
ether4330 remains pointless until a chip has answered CMD5.
.PP
.B "The SET finding, retested, survives."
The conclusion above rests on tag 0x00038041 coming back unhandled, and
the control for it \(em writing line 130 \(em shares a possible cause
with the thing it was meant to rule out: a malformed request.  The
working call on these lines,
.CW mboxgetgpio ,
sends a value-buffer size of 8 with a request length of 4, while
.CW mboxsetgpio
sends 8 and 8, so the two differ in exactly the field meaning \fIhow
many bytes of the value buffer are request data\fP \(em and
.CW mboxsetclock ,
the comparison originally used, cannot arbitrate it because its two
numbers are equal.  Retested on the board with request lengths 0, 4 and
8: all three unhandled, each returning the tag response exactly as
written (0x0, 0x4, 0x8), bit 31 never set.  The firmware has no
SET_GPIO_STATE.  This mattered because replacing the boot firmware is
the one change here that kinstall cannot pre-flight and kernel8.bak
does not protect.
.PP
.B "The installer asks the board what it is running."
The post-install check read the console: find the reboot's own RCMD line
and require the banner below it.  A reference point was needed because
the pre-flight JTAG boot of the same build has already printed that
banner into that buffer.  But
.CW "screen -X hardcopy -h"
returns about two hundred lines and a full boot is most of that, so the
reference point scrolls out before the banner arrives, and a board that
booted perfectly is reported as having failed.  An instrument whose
window is smaller than the thing it measures is not fixed by waiting
longer: waiting only guarantees the evidence is gone.
.PP
devcons serves /dev/osversion as
.CW "2000 <kerndate>" ,
so the board states its own running build, over the poller, inside a
command tagged with a token no earlier run can have produced.  That
answer cannot come from scrollback and does not depend on a buffer size.
.PP
It needed one more correction to work: /dev/osversion carries no
trailing newline, so
.CW "cat /dev/osversion; echo KI-UP"
prints
.CW 2000\ 1790273432KI-UP
on one line and an anchored search for the marker finds nothing \(em
reporting a healthy board, running exactly the build just written, as
JTAG-only.  The same merge would have swallowed the end token that
follows.  The marker goes first and a newline is emitted after the
version.
.PP
.B "A command failure used to wedge the controller for good."
Retrying CMD5 exposed it: attempt 0 fails with a command timeout and
attempts 1, 2 and 3 all fail with \fIthe command line never went
idle\fP.  A command that errors leaves Cmdinhibit set and the Simplified
Spec is explicit that software must reset the CMD line to clear it.
This driver never did, so the first failure wedged the controller for
the life of the boot.
.PP
That is not cosmetic, and it undermined the finding it was hiding
behind: one CMD5 timeout was the entire basis for \fIno I/O function
answered\fP, because the retries after it could not reach the bus
whatever was on the far end.  On the card path a single transient error
would have taken the disk away and never given it back.  With the reset
in place all four attempts reach the bus and all four return a genuine
command timeout, and SD-OK and FAT-OK are unchanged.
.PP
.B "The preconditions are all satisfied and the chip still does not answer."
Board revision 0xa02082 is a Pi 3 Model B rev 1.2, which carries a
BCM43438, so \fIthere is no chip\fP is not available as an explanation.
GPIO 43 is in alt0 (GPCLK2) with GP2CTL 0x291 \(em enabled, sourced
from the oscillator \(em and GP2DIV 0x249f00, which is DIVI 585 and DIVF
3840: 19.2MHz over 585.9375 is 32768Hz exactly, so the radio's low-power
oscillator is running.  All six SDIO pins are read BACK as alt3 rather
than merely written.  The bus clock is 400kHz.  WL_ON reads 1.  Four
CMD5s time out with the controller never seeing a response start bit,
which is not a CRC complaint \(em nothing drives CMD at all.
.PP
.B "One caveat on \(lqthe radio is powered\(rq."
That rests on GET_GPIO_STATE, and the same firmware has no
SET_GPIO_STATE.  A firmware with a stubbed expander implementation could
return plausible defaults from GET and implement nothing, and the
coherence of the four values is suggestive but not proof.  It cannot be
settled from here: the one line whose state is externally visible is
PWR_LED_OFF, and checking it means looking at the board.
.PP
.B "Why the next step is not more driver work."
Linux resets this part by driving its enable low and then high \(em
mmc-pwrseq-simple with an active-low reset on expander line 1 \(em and
with no SET_GPIO_STATE that cannot be done from here at all.  Every
other explanation has now been checked and eliminated or corrected.
.PP
Replacing start.elf and bootcode.bin is the obvious remedy and it is
also the one change on this board that nothing here protects.  kinstall
guards the kernel with a JTAG pre-flight and kernel8.bak; neither
applies to the firmware, and the failure mode is worse than a bad
kernel.  A bad kernel leaves the ARM running something JTAG can reach.
A bad start.elf means the firmware never releases the ARM, so there is
nothing for JTAG to halt and the card has to come out of the board.
That is a decision with a physical recovery, and it should be taken
deliberately rather than as the next automatic step.
.SH
The radio answers \(em and the firmware conclusion above was wrong
.PP
.B "Correction."
The section above concludes that the BCM43438 cannot be reset without
SET_GPIO_STATE and that the next step is replacing start.elf.  That is
wrong, and it is left standing above rather than quietly edited because
the reasoning that produced it was sound at every step and still reached
the wrong place.  Every precondition had been checked, every
driver-side theory eliminated or corrected, and what remained looked
like the only possibility.  It was not; it was the only possibility
\fIthat had been thought of\fP.
.PP
Replacing the firmware is also the one change on this board that nothing
protects: a bad kernel leaves the ARM running something JTAG can reach,
a bad start.elf means the ARM is never released and the card has to come
out.  The wrong conclusion was one step from an irreversible action.
.PP
.B "What the radio actually says."
.P1
sdio: CMD5 r4 0x20ffff00: 2 function(s), window 0xffff00
sdio: 2 I/O function(s), rca 0x1
sdio: CCCR revision 0x32
.P2
Two I/O functions, a relative address assigned, and CMD52 reading the
card common control registers.  Reproduced over three boots, with SD-OK
and FAT-OK unaffected on every one.
.PP
.B "What makes the difference, and what does not."
The controller must be brought up once while it is connected to the
CARD pins \(em GPIO 48-53 in alt3 \(em before it will talk on its own
pins at all.  That was found by accident: a probe written to ask
whether the CONTROLLER worked changed the thing it was measuring, and
the change is what found the bug.
.PP
Four cheaper explanations were then tested on the Wi-Fi pins alone and
every one failed to reproduce it: an extra host reset with a 150ms wait;
150ms of \fIrunning\fP bus clock before the first command; calling
.CW sdhcictlrinit()
twice; and a full bring-up followed by a command that fails and the
CMD-line reset after it.  Each was a reasonable mechanism and each is
now excluded by measurement rather than by argument.
.PP
.B "Why it works is not known."
Nothing here explains it, and it is recorded as an observed fact with a
reproduction rather than as understood behaviour.  It also must not ship
in a real bring-up path as it stands \(em a Wi-Fi driver has no business
touching the card's pins \(em so it lives in the probe, behind
-DSDIOTEST, until the mechanism is understood.  A first thing to try is
whether the pin round trip alone suffices, without the controller init
on those pins.
.PP
.B "Next."
CMD53, the block transfer, is now the failing step; CMD52 works.  That
is the transport ether4330 needs, and it is a bounded piece of work on
a chip that is finally answering.
.PP
.B "Narrowed: it is two register writes."
The controller init on the card pins turned out not to be needed either.
Flipping GPIO 48-53 to alt3 and straight back to alt0, with no
controller bring-up, no command and nothing driving the card's bus, is
enough on its own \(em the radio enumerates exactly as before.  So the
count of eliminated explanations is five, not four, and the surviving
fix touches nothing.
.PP
One lead ruled out while writing it down: pins 48-53 and pin 43
(GPCLK2, the radio's low-power oscillator) share GPFSEL4, so a careless
write could have disturbed the LPO.  It does not \(em
.CW gpiofsel
does a read-modify-write and leaves 43 alone \(em so that is not the
mechanism.  Still unknown.
.PP
.B "CMD53 now fails with a data CRC error, which is progress."
The data phase had the same one-message problem as everything else \(em
the command completing and the data arriving are separate events with
separate ways to fail, and \fICMD53 read\fP named neither.  Split apart,
it says: \fIthe card never offered data\fP, interrupt 0x208000, status
0x1ff0202.  Bit 21 of the interrupt register is Data CRC Error.
.PP
That is a different kind of failure from everything before it.  Silence
means nothing is driving the bus; a CRC error means the card IS driving
it and the bits are not surviving the trip.  CMD52 \(em single-byte
register access over the same lines \(em works, so the command path and
the response path are sound and only the data phase is not.
.PP
Worth checking in this order: the bus is in 1-bit mode and the card's
default is 1-bit, which agrees, so width is unlikely but should be
confirmed rather than assumed; the pad pull-ups on GPIO 34-39 are left
however the firmware set them, and nothing here programs GPPUD; and the
data timeout exponent and the clock in force during the data phase have
not been checked at all.
.PP
.B "The CMD53 test is not valid against this chip."
Pull-ups on 34-39 were programmed \(em nothing here had ever set them
\(em and the block sizes too, and neither changed the CRC.  Reading the
driver's own comment explains why: the CMD53 path was written against
the SDIO function model in tools/qemu-patches, which has plain readable
memory at function 1 offset 0x400.  A BCM43438 does not.  That offset is
the chip's backplane window, and reading it without first setting the
window up is not a meaningful request, so a failure there is not
evidence that the transport is broken.  It is now reported as
SDIO-CMD53-NA and says so.
.PP
.B "What the real chip says about itself, over CMD52."
.P1
CCCR 32 02 02 02 00 00 00 40 02 70 10 00
     00 00 00 00 00 00 01 01 00 00 00
.P2
CCCR 3.00 with SDIO 2.00; function 1 both enabled (0x02) and ready
(0x03); bus interface control 0x40, so the bus is in 1-bit mode, which
agrees with the controller; and the CIS pointer at 0x001070.
.PP
One defect came straight out of that dump: function 0's block size, CCCR
0x10/0x11, comes up ZERO, and function 1's had never been set either.
Every real SDIO driver programs both before it moves anything.  They are
now set to 64 \(em what ether4330 uses for this part \(em and read back
to confirm it.  That did not change the CRC, which is consistent with
the test target being meaningless rather than the transport being at
fault, but it is required regardless and was simply missing.
.PP
.B "Next."
The transport is proven as far as CMD52 on real silicon.  The next piece
is the beginning of the ether4330 port rather than more probing: set up
the backplane window through function 1 and read the chip's own ID back.
That is the first CMD53 whose answer is worth anything on this part, and
it is what a driver needs first anyway.
.SH
The transport is finished: CMD53 works and the chip names itself
.PP
The CMD53 question is settled, and the test that settles it is the one
that was missing all along.  Every earlier attempt used function 1
offset 0x400, which is plain memory on the QEMU function model and the
backplane window on silicon, so a failure there said nothing about the
transport.  The right test reads the SAME four bytes at the SAME address
by both routes, with CMD52 \(em already proven \(em as the control.
.PP
The window is set through function 1's SBADDRLOW/MID/HIGH at 0x1000a-c;
the low fifteen bits of the backplane address are then the offset inside
it.  0x18000000 is the SI enumeration space and its first word is the
chipid register.
.P1
sdio: chipid 0x1541a9a6 -> chip 0xa9a6 rev 1, 5 cores
sdio: CMD53-OK the same four bytes read back identically through CMD53
.P2
.PP
0xa9a6 is 43430 in hex.  That was written down as a prediction before
the run, so it is a real test of which chip is on the other end and not
a liveness check that would have accepted anything: a BCM43430A1,
revision 1, five cores.  And CMD53 returns exactly what CMD52 returns.
.PP
So the earlier data CRC error was entirely an artifact of reading an
address that means nothing on this part.  The transport \(em CMD52,
CMD53, and the backplane window \(em is done.
.PP
.B "Read the kernel log over the network."
The console screen session vanished mid-session, and none of this needed
it: devcons already serves /dev/kmesg, so the whole boot log comes back
through the board.cmd poller with
.CW "cat /dev/kmesg" .
The installer no longer depends on the console either \(em it asks the
board for /dev/osversion \(em so a kernel was built, installed, booted
and read with the console entirely absent.
.SH
Block mode: a real bug, and what is still unproven
.PP
The four-byte read that proved CMD53 proved byte mode and nothing else,
and the firmware upload is several hundred kilobytes of BLOCK writes, so
that gap mattered.  Testing it found a real bug.
.PP
.B "sdiocmd53 hardcoded 512 as the block size."
An SDIO function's block size is whatever CCCR 0x10/0x11 and the FBR
were programmed with \(em 64 for this part, which is what ether4330 uses
\(em so the card was sending 64-byte blocks while the controller had
been told to expect 512.  The symptom is a data CRC error together with
a data end-bit error, interrupt 0x608000, because the controller is
still waiting for the rest of a block the card has already finished.
Byte mode never saw it, which is exactly why it survived: the only CMD53
that had ever worked was four bytes long.
.PP
Fixed, and the fix is visible in the failure: 0x608000 became 0x208000,
the end-bit error gone and a CRC left.  Then, with one block instead of
eight:
.P1
sdio: BLOCK1-OK one 64-byte block reads the chipid correctly
SDIO-BLOCK-FAIL 8x64 read (interrupt 0x208000)
.P2
.PP
.B "So block mode works; multi-block over THIS range does not."
That is where the honest account stops.  0x18000000 is the SI
enumeration space \(em registers, not memory \(em and the failing read
walks an incrementing address across 512 bytes of them, which is not
obviously a legal thing to ask for.  The same mistake as the 0x400 test,
one level up: a transport is being judged against an address that may
not support the access.
.PP
Proving multi-block needs a span of real memory, which means chip RAM,
which means bringing the SOCRAM core up first.  That is step one of the
driver anyway, so the remaining transport question and the next piece of
work are the same piece of work.
