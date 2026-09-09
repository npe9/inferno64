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
When this is done
.PP
With Phases 0-4 the Pi 3B is an interactive networked Inferno
workstation: framebuffer display, USB keyboard and mouse, wired ethernet,
and USB storage, over a firmware-loaded kernel8.img on real hardware.
Phases 5-7 add Wi-Fi and the small peripherals.  Left out on purpose,
until the machine is otherwise complete: Bluetooth, the CSI camera, DSI
display, and anything GPU/OpenGL/VideoCore-accelerated.
