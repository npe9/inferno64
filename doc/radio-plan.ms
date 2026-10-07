.TL
A radio for the emulator, a driver for the kernel, and a file to read it through
.AU
.PP
A plan for the one piece of PyCubed hardware that nothing in this tree
models, drives or exposes: the RFM9x, an HopeRF module around a Semtech
SX1276 LoRa transceiver on SPI.  Companion to
.CW doc/pycubed-plan.ms ,
which has the mission and the budget, and to
.CW tools/qemu-patches/README ,
whose evidence tiers and rules for adding a device model this follows.
.PP
Marked
.B measured
where a figure comes from a build, a booted kernel or a file in this
tree, and
.B estimated
where it does not.
.NH 1
What is there now, which is nothing
.PP
.B Measured .
.CW "grep -riE 'rfm9|sx127|lora|radiohead'"
over the whole checkout finds documentation, a word list and an
unrelated Cocoa file.  There is no driver.
.CW appl/pycubed/hw.b 's
.CW haveradio ()
returns 0 unconditionally and every booted run of
.I pycubed/beepsat
prints
.CW "beacon | no radio on this board, nothing sent" .
.PP
Nor is there anything to put one on.  Four SPI drivers exist \-
.CW os/inferno/raspi3b/spibcm.c ,
.CW auxspibcm.c ,
.CW os/inferno/raspi4/spibcm.c
and
.CW os/inferno/riscv/spisifive.c
\- and none of them is a device: they are C functions other C calls, and
.CW "grep -rln 'spidevtab\e|devspi' os/"
finds nothing.  The one bus device in the tree,
.CW os/inferno/port/devi2c.c
.CW ( #J ),
does not build for Inferno because its
.CW I2Cdev
header lives only under
.CW os/osprey
and
.CW os/9front .
.PP
So all three halves are missing: the emulated part, the driver, and the
file interface.  Taking them in that order is what makes each step
testable by the one before it.
.NH 1
One processor, two radio sockets, one bus
.PP
Asked whether this is a distributed system and whether two emulated
machines should be wired together.  Read from the board sources rather
than assumed, and the answer is no for the reason that matters: there is
only one processor to wire.
.PP
.CW pycubedv05_build/mpconfigboard.mk
is
.CW "CHIP_VARIANT = SAMD51J19A"
and
.CW "CHIP_FAMILY = samd51" ;
.CW mpconfigboard.h
is
.CW "MICROPY_HW_MCU_NAME \(dqsamd51j19\(dq" .
One MCU.  And the radio is not a second one: an RFM9x is a bare Semtech
SX1276 with its matching network and crystal, a register file on SPI
with no processor in it and no firmware of its own.  Everything
RadioHead does \- the header, the sequence number, the acknowledgement,
the retry \- runs on the host, in
.CW lib/pycubed_rfm9x.py
today and in the C driver of R2.2 tomorrow.  There is nothing on this
board for two machines to be.
.PP
What the pin map does say, and what this plan did not have before, is
that there are
.I two
radio sockets on one bus.  From
.CW pycubedv05_build/pins.c :
.DS
.CW "  RF1_CS   PB30    RF2_CS   PB09"
.CW "  RF1_RST  PB00    RF2_RST  PB14"
.CW "  RF1_IO0  PB05    RF2_IO0  PB06"
.CW "  RF1_IO4  PB04    RF2_IO4  PB07"
.CW "  EN_RF    PA04    SD_CS    PA27"
.DE
with one SPI \-
.CW "SCK PA13, MOSI PA12, MISO PA14"
\- carrying both radios
.I and
the SD card.
.CW lib/pycubed.py:92
takes a single
.CW board.SPI ()
and line 113 says "always init SD before anything else on spi bus".  The
example populates
.CW radio1
only;
.CW radio2
appears in its power-down path, so the second socket is a board feature
this software does not drive.
.PP
Three consequences for the design below, all of which it survives.
.IP \(bu
.CW #W
is numbered per interface already, so two sockets are
.CW radio0
and
.CW radio1
and nothing changes.
.IP \(bu
The bus is shared with storage, so the driver needs arbitration rather
than assuming it owns the controller.  That is what
.CW lib/tasko/managed_spi.py
was for, and
.CW doc/pycubed-plan.ms
records it as deleted because Inferno has locks \- which is true and is
also a promise this driver has to keep.
.IP \(bu
.CW EN_RF
gates power to the radios and
.CW RF1_RST
resets one, so
.CW ctl
needs
.CW enable
and
.CW reset ,
and DIO0 and DIO4 are two interrupt lines per socket, not one.
.PP
So the distributed system here is not inside the spacecraft.  It is the
spacecraft and the ground, which is exactly the pair R1.3 wires together
over a multicast group and exactly what the namespace-over-Styx argument
in
.CW doc/pycubed-plan.ms
is about.
.NH 2
A board that already exists, and why this does not use it
.PP
Worth saying before the rest, because it will be found: there is a
QEMU checkout on this machine at
.CW /Users/npe/src/qemu
whose HEAD is
.CW "upsat-comms devices updates" ,
and UPSAT is a CubeSat.  It is not a radio.
.CW hw/arm/upsat-comm.c
is 65 lines that instantiate an
.CW STM32F407VGTX
SoC and nothing else \- its own commit message calls it "a placeholder
for the upsat comms board" \- and there is no device model for a
transceiver anywhere in it.
.PP
It is also worth being exact about what QEMU has, because it changes the
answer: upstream
.CW v10.1.3
models the STM32F100, F205 and F405, and the
.CW STM32F407VGTX
is
.I local
to that checkout \- it appears in its diff against
.CW v6.2.0
alongside a modified
.CW hw/ssi/stm32f2xx_spi.c
and
.CW hw/gpio/stm32f2xx_gpio.c .
It is there because UPSAT genuinely is a two-board satellite, an OBC and
a COMMS subsystem each with its own STM32 and its own firmware.  Wiring
two of those together would be modelling UPSAT's architecture.  A
PyCubed does not have one.
.PP
This plan does not build on it, for three reasons, none of them a
judgement on the work.  It is based on
.CW v6.2.0
with 533 files of local change, while
.CW tools/qemu-patches
is pinned at
.CW v10.1.3
and the container that builds the patched QEMU builds that.  Its board
is an STM32F407, which no Inferno kernel in this tree boots.  And
.CW mps2-an500
is the only ARMv7-M board here that runs at all, which is the whole
reason phase 0 could be done without hardware.  If the UPSAT board grows
a radio and a kernel, the SX127x model below is the part that moves
across; the board wiring is not.
.NH 1
Phase R1: the emulated radio
.PP
The board this can be developed on is
.CW mps2-an500 ,
because it is the only ARMv7-M board here that runs.  The good news is
.B measured
from
.CW hw/arm/mps2.c
at
.CW v10.1.3 ,
which already creates five PL022 SPI controllers for every MPS2 variant,
with no conditional on which one:
.DS
.CW "0x40025000  External ADC   NVIC 22"
.CW "0x40020000  APB            \(bv"
.CW "0x40021000  LCD            \(bv- OR gate -> NVIC 11"
.CW "0x40026000  Shield0        \(bv"
.CW "0x40027000  Shield1        \(bv- OR gate -> NVIC 24"
.DE
and
.CW hw/ssi/pl022.c
calls
.CW "ssi_create_bus(dev, \(dqssi\(dq)" ,
so there is a named SSI bus to hang a peripheral on.  No controller
model is needed at all.
.PP
One thing that was needed and is not in that list.  The SX127x delimits
a SPI transaction with chip select \- the first byte after CS falls is
the register address \- and an MPS2 drives a shield's chip select from a
GPIO, as a PyCubed drives
.CW RF1_CS
from
.CW PB30 .
DIO0 comes back the same way.  But
.CW hw/arm/mps2.c
created all four GPIO blocks with
.CW create_unimplemented_device () ,
and
.B "no CMSDK GPIO model exists anywhere in QEMU"
\-
.CW "grep -rln 'cmsdk.*gpio' hw/ include/hw/"
finds
.CW mps2.c
and
.CW mps3r.c ,
both of which only name the string.  So there is a patch before the two
this section started with, and it is not a detour: a guest that cannot
drive a pin or take an interrupt from one cannot work this radio at all.
.B Done .
.PP
Two of those five are the point.
.CW Shield0
and
.CW Shield1
are the Arduino-style expansion headers an MPS2 physically has, and an
add-on radio board is exactly what they are for.  The SX1276 goes on
.CW Shield0 ,
which is where one would be plugged rather than somewhere chosen to be
convenient.
That makes the wiring a good deal less invented than it would otherwise
be, and it comes with a real constraint to drive rather than wish away:
the two shield controllers share NVIC 24 through an
.CW OR_IRQ ,
so the driver has a shared interrupt and must establish that a given
interrupt was its own.
.PP
Three patches.
.IP "R1.0" 8
.B "hw/gpio: model the ARM CMSDK AHB GPIO."
.B Done .
16 pins, each with its own interrupt as well as the combined one.  The
register map was written from the CMSDK documentation and then checked
against Zephyr's independent driver in
.CW include/zephyr/drivers/gpio/gpio_cmsdk_ahb.h ,
which agrees offset for offset.
.IP "R1.1" 8
.B "hw/ssi: model the Semtech SX1276."
.B Done .
An
.CW SSIPeripheral
implementing the register file: the FIFO at 0x00, the modem
configuration registers, the operating-mode register with its
sleep/standby/tx/rx-continuous states, the IRQ flags register, and the
address auto-increment the part does on FIFO access.  The device keeps
a payload buffer, a
.CW qemu_irq
for DIO0, and the parameters a guest sets so that
.CW stat
below has something true to report.
.IP
Written from the SX1276 datasheet, per the rule in
.CW tools/qemu-patches/README ,
not from what the Inferno driver emits, and rejecting protocol
violations rather than tolerating them: a FIFO write past the payload
length, a transmit from a mode that cannot transmit, or a register
write the datasheet marks reserved is a
.CW LOG_GUEST_ERROR ,
not a shrug.
.IP "R1.2" 8
.B "hw/arm/mps2: put it on the shield header."
.B Done .
The four GPIO blocks are real now, with the combined interrupts the MPS2
application notes give and Zephyr's
.CW mps2_base.dtsi
carries \- 6, 7, 16 and 17.
.CW "sysbus_create_simple(TYPE_PL022, ...)"
discards the
.CW DeviceState* ,
so the board code keeps the
.CW Shield0
one, takes
.CW "qdev_get_child_bus(dev, \(dqssi\(dq)"
and calls
.CW ssi_create_peripheral ()
on it.  DIO0 goes to one of the four
.CW cmsdk-ahb-gpio
inputs the board already has rather than to an NVIC line of its own,
because a shield's interrupt line is a GPIO on real hardware and
inventing a private interrupt number would be inventing a part.
.IP
Honest about what is still invented, because some of it is.  An MPS2 has
a shield header and no radio on it, so the presence of the part is a
fixture; the chip model comes from the SX1276 datasheet; and the chip
select and the GPIO number are chosen here rather than documented
anywhere.  A PyCubed's bus is different again \- a SAMD51 SERCOM, not a
PL022.  So a passing test proves the SX127x register, FIFO and interrupt
sequencing, and proves nothing whatever about the real board's bus.
That is
.CW qemu+patch ,
the weakest of the three tiers, and the patch and this document both say
so.  Put it behind a board property so the radio appears only when asked
for, and no other MPS2 configuration moves.
.IP "R1.3" 8
.B "A back end, so that two of them can hear each other."
A LoRa channel is a broadcast medium and QEMU already has one:
.CW qemu_new_nic ()
with
.CW -netdev
.CW "socket,mcast=" ,
where every instance in the group receives every frame and the socket
backend length-prefixes, so an arbitrary payload rather than an Ethernet
frame is fine.  Two
.CW imps2
instances on one multicast group are then a satellite and a ground
station.
.IP
And the thing to say about it before anyone trusts it: this models a
.I perfect
channel.  No loss, no range, no collisions, no interference \- which is
the exact opposite of the medium the acknowledge-and-retry layer exists
for, so as it stands the model cannot exercise that path at all.  Give
the device a drop-probability property, defaulting to zero, and the
retry path becomes testable by setting it.
.NH 1
Phase R2: the drivers, in C
.PP
Two drivers, and the split between them is the point.
.IP "R2.1" 8
.B "The PL022 controller, which is a test fixture and should say so."
Small: the control registers, the data register, and byte-at-a-time
transfer.  It exists because the emulator's bus is a PL022 and the
PyCubed's is not, so it is thrown away when the SAMD51 board arrives.
It is written to the same shape the tree already uses four times over \-
.CW "spibyte(u32 *r, int out)"
in
.CW os/inferno/riscv/spisifive.c:30
and
.CW os/inferno/raspi3b/spibcm.c:37
are the same function \- so that the chip driver above it does not know
which one it is talking to.
.IP "R2.2" 8
.B "The SX127x chip driver, which is the part that carries over."
Written against that transfer interface and nothing else, so that
re-hosting it on a SERCOM is a different
.CW spibyte
and no other change.  It owns: reset and version check, the modem
configuration (frequency, spreading factor, bandwidth, coding rate,
power), transmit through the FIFO, receive on the DIO0 interrupt, the
CRC flag, RSSI and SNR, and the RadioHead-compatible four-byte header
with its acknowledge and retry, which
.CW lib/pycubed_rfm9x.py
already has and which this is porting rather than inventing.
.IP
The interrupt is why this must be kernel C rather than Limbo:
.CW doc/pycubed-plan.ms
says it and it is still the reason.
.NH 1
Phase R3: the file interface
.PP
The question this plan was asked, and the answer is the shape Inferno
already uses for a thing with settings, traffic and counters:
.CW #D
.I ssl (3),
.CW #l
ether and
.CW #u
usb all have a numbered directory per interface holding
.CW data ,
.CW ctl
and a status file.  So:
.DS
.CW "  #W/radio0/data"
.CW "  #W/radio0/ctl"
.CW "  #W/radio0/stat"
.DE
bound at
.CW /dev/radio0 .
.CW W
is free \-
.B measured ,
by enumerating every
.CW Dev
letter under
.CW os/inferno ;
.CW R
is
.CW devready
and
.CW r
is
.CW devrtc .
.PP
.B "data is message-delimited, and that is the whole design."
One write is one packet on the air.  One read is one packet received,
blocking until there is one.  Not a byte stream, because the radio is
not one and because everything above depends on the boundary surviving:
.I ssl (3)
is a filter over a file descriptor, and Styx is a request and a reply.
.PP
Two refusals follow from that, and both are refusals rather than
conveniences on purpose, following
.CW tools/qemu-patches/README 's
second rule \- reject a protocol violation rather than tolerate it.
.IP \(bu
.B "A read with a buffer smaller than the packet is an error, not a truncation."
.I Ssl (3)
states the contract this inherits: "as long as reads always specify
buffers that are of equal or greater lengths than the writes at the
other end of the connection, one write will correspond to one read".  A
device that quietly returned the first
.I n
bytes would break that somewhere else entirely, long after the read that
did it.
.IP \(bu
.B "A write longer than the payload budget is an error, and the error string names the budget."
Not split into two packets.  Splitting is the segmentation layer; a
device that did it silently would hide the message-size problem below
rather than making someone decide about it.
.PP
.CW ctl
takes text lines, the way every Inferno control file does:
.CW freq ,
.CW power ,
.CW sf ,
.CW bw ,
.CW cr ,
.CW node ,
.CW dest ,
.CW ack ,
.CW retries ,
.CW timeout .
.CW stat
returns text: the parameters in force, the RSSI and SNR of the last
packet, and counters for sent, received, CRC errors, acknowledgements
and retries \- the things
.CW lib/pycubed.py
keeps in NVM counters and the things a pass over a ground station is
judged by.
.PP
The
.CW iounit
of
.CW data
is the payload budget, and it is not decoration.
.CW os/inferno/port/exportfs.c:806
is
.DS
.CW "if(iounit != 0 && iounit > 64 && iounit < r->msize)"
.CW "	r->msize = iounit;"
.DE
so a radio device that reports its true
.CW iounit
makes the satellite's own Styx server negotiate down to it without being
told anything.  Reporting it is the one line that makes
.CW doc/pycubed-plan.ms 's
message-size problem solve itself on the spacecraft side.
.NH 1
The order, and what each step proves
.PP
Each is checkable by the one before it, which is the only reason to do
them in this order.
.IP 1. 5
R1.1 and R1.2: the model exists and a guest can read its version
register over the PL022.
.B Proves
the bus wiring and the register file.
.IP 2. 5
R1.3: two instances, one multicast group, a byte sent from a QEMU
monitor-driven write arriving at the other.
.B Proves
the back end.
.IP 3. 5
R2.1 and R2.2: the kernel driver transmits and takes a DIO0 interrupt.
.B Proves
the driver against the model, no more \- both halves are ours, which is
what the weakest evidence tier means.
.IP 4. 5
R3: two kernels, one writing
.CW /dev/radio0/data
and one reading it, and
.CW haveradio ()
answering 1 at last, so
.I pycubed/beepsat
beacons for real between two emulated boards instead of printing that it
cannot.
.B "This is the first step whose result is visible from Limbo."
.IP 5. 5
.I Ssl (3)
pushed onto
.CW data :
.CW keyring->auth ()
over it, then
.CW ssl->connect ()
and
.CW secret (),
then a byte each way that the other end can only read because it
authenticated.
.B Proves
the claim in
.CW doc/pycubed-plan.ms
that an authenticated encrypted link over this radio needs no IP stack.
.B "Done, and the claim needed correcting twice over."
.I Radiostyx
asked
.IR ssl (3)
for
.B "alg sha"
until October 2026, which man/3/ssl documents as a DIGEST \- the bytes
went out readable while this plan, the source and the man page all
called the link encrypted.  It asks for
.B sha/rc4_256
now, and
.B "that is SHA-1 and RC4, which are not modern primitives:"
devssl offers RC4 at 40, 128 and 256 bits, DES at 40 and 56, and IDEA,
and nothing better.  It defeats somebody listening on 915MHz with a
software radio, which is the threat this document describes, and not
anybody who has read about RC4.
.IP 6. 5
.CW sys->export ()
over the result, and a ground station reading
.CW /dev/battery
off the satellite.
.B "Proves the whole argument"
\- and turns the message-size question from an argument into a
measurement, because the msize the two ends negotiate is a number that
gets printed.
.NH 1
Where this got to
.PP
.B "Steps 1 to 4 are done and run."
Two emulated MPS2 boards, one socket between them, an SX1276 on each
Shield0 header:
.DS
.CW "; pycubed/beepsat"
.CW "BEEPSAT-RUNNING 4 tasks"
.CW "       vbatt | 3.96V > threshold 3.60V"
.CW "      beacon | sent 12 bytes"
.DE
and on the other board
.CW "cat /dev/radio0/data"
printing
.CW "Hello World!" ,
which is what
.CW Tasks/beacon_task.py
beacons and what
.CW appl/pycubed/beepsat.b
now beacons through
.CW #W/radio0/data .
.CW haveradio ()
answers 1 at last.
.PP
Steps 5 and 6 \-
.I ssl (3)
pushed onto
.CW data ,
then
.CW sys->export ()
over it \- were not done, and
.B "the reason was not any missing code."
.CW os/inferno/stm32f407/stm32f407
had no
.B ssl
line in its
.B dev
section, so there was no
.B #D
on the board at all to push anything onto.  One word.
.PP
.B "And whether it composes with the segmentation is answerable without a radio."
.IR styxseg (1)
pushes
.IR ssl (3)
onto both ends of its chopped link before either speaks:
.B clear ,
.BR sha ,
.B sha/rc4_128
and
.B sha/rc4_256
all carried every size from 270 to 272 bytes over 109-byte frames
intact.
.I Devssl 's
.I ensure ()
loops until it has what its record header asked for, so a record chopped
into 109-byte pieces is reassembled the same way
.I devmnt
reassembles a Styx message \- which is why it works, rather than a
coincidence.
.PP
.PP
.B "And the init does it now."
.B os/inferno/init/armv7mstyx.b
pushes
.IR ssl (3)
onto the Styx end of its relay's pipe \- not onto the conversation, so
the chopping carries ciphertext \- and both ends do it in one function,
so they cannot disagree about the algorithm by being edited apart.
.B "The secret is a constant in that file and the file says it is not a key:"
what makes it real is
.CW keyring->auth ()
deriving one over the link, which wants a certificate per board under
.B /keys
and this root has none.  So the bytes are not in the clear and the
record layer survives the chopping; neither end knows who the other is.
.B "That is step 5 and the identity half of it is still open."
.PP
.IR Devssl 's
memory was the thing to check on a part with two SRAM regions of 65536
and 98304 bytes, and it is fine:
.B Maxdmsg
is
.CW 1<<16
but appears only as the count to
.IR bread (),
which
.I qbread
honours without allocating, and every
.I allocb
in the read and write paths is sized from the CALLER's message clamped
to
.CW s->max .
A Styx write here is 436 bytes, so the allocations are 436 bytes.
.PP
.B "What #D costs, measured: 26480 bytes of kernel text."
The satellite, station and styx images absorb it; the shell image came
to 926280 against a ceiling of 913408 and gave up
.I ax25chk
from its XIP list, which is the second thing that list has had to give
up.  A conf has one
.B dev
section for every init built from it, so the cost falls on the image
somebody types at rather than on the two that want the device.
.PP
.B ssl.dis
itself is carried by
.B EXTRAROOT
rather than the root section, for the same reason and with 2240 bytes
to spare it had to be: a 1650-byte raw module in the conf would have
left 590.  It is in the styx image's XIP list as well, which is the
reverse of the call made for
.I mount
in
.BR image-armv7minit :
that image is flash-tight and this one is memory-tight, so here the
module costs 5864 bytes of flash instead of its decoded array in RAM.
The styx image comes to 635744 of 913408 and the other three are
byte-identical to before.
.NH 2
The channel is two nodes, not a broadcast medium
.PP
The model is a QEMU NIC so that
.CW "-netdev socket,mcast="
would give a broadcast group, which is the right shape for a radio
channel.  On this host it does not deliver: two instances in a group,
with and without
.CW localaddr=127.0.0.1 ,
each transmit and neither hears the other.
.CW "socket,listen="
and
.CW "socket,connect="
do deliver, so everything above was tested over a point-to-point link
between exactly two stations.  The broadcast case is untried rather than
broken \- it is the same
.CW qemu_send_packet ()
either way \- but it is untried, and a third station has never been in
the room.
.NH 2
Three things the model caught
.PP
Which is what it is for.  All three are guest bugs, and none of them
would have been visible without a part to talk to.
.IP \(bu 4
.B "The transmit path raced its own interrupt handler."
The driver set
.CW RegDioMapping1
so DIO0 reports TxDone, then polled
.CW RegIrqFlags
for the same bit.  The interrupt arrives the moment the bit sets and the
handler clears it, so the poll never saw it and every transmit reported
"no TxDone after a second" while having transmitted perfectly.  The part
says when it is done; there is no reason to ask.  It sleeps on the
interrupt now.
.IP \(bu 4
.B "A struct grew a field and one of its users kept the old layout."
.CW sx127x.h
carries the
.CW Radio
struct, which three files share, and it was on no dependency line \-
.CW portmkfile 's
catch-all names the headers every object has, not the ones a particular
driver includes.  Adding a
.CW Rendez
to the middle of
.CW Radio
rebuilt two of the three; the third went on reading
.CW rq
at the old offset, and the first packet to arrive took a lock at address
0x50.  It does not fail to build.  This is the second time today \- the
first was
.CW include/pool.h ,
in
.CW doc/xip.ms
\- and the board mkfile names the dependency now.
.IP \(bu 4
.B "The short-read refusal did not work."
.CW qbread ()
on a
.CW Qmsg
queue hands back the
.I n
bytes asked for and throws the rest of the message away, so the check
for a too-small buffer could never fire: the truncation had already
happened inside the queue.  The device reads a whole packet and
.CW qputback () s
it when it does not fit, so the packet is still there for a read that is
big enough.  Found by
.I radiochk (1),
which exists because the console line discipline will not carry a
command line long enough for a shell to make an oversize write.
.NH 1
Getting it relevant and right
.PP
Everything above runs, and none of it is evidence about a real board.
The model and the driver that talks to it were written by the same hand
in the same sitting, so a passing test can mean the model implements the
driver's mistake; and an MPS2 has no radio, so the fixture is a fixture.
.CW doc/radio-evidence.ms
is the plan for both \- three independent checks, three steps toward a
part on a desk, the claims this work has asserted and never run, and a
table of which step moves which claim to which of
.CW tools/qemu-patches/README 's
evidence tiers.  It also says what would falsify the whole fixture.
.NH 1
What this will not tell anyone
.PP
Worth writing down now rather than discovering it at step 6.
.IP \(bu
Nothing about radio frequency.  No range, no link budget, no antenna, no
interference, no Doppler, and a perfect channel unless the drop
probability of R1.3 is turned up.
.IP \(bu
Nothing about the PyCubed's bus.  The wiring modelled is an MPS2 shield
header; the real one is a SAMD51 SERCOM.  R2.1 is discarded on contact
with hardware and R2.2 is what survives.
.IP \(bu
Nothing about timing.  QEMU under TCG is not the part, and a LoRa
symbol at spreading factor 7 is hundreds of microseconds of air time
that the model will not spend.
.PP
What it will tell anyone is whether the register sequencing, the
interrupt path, the file interface and everything Limbo does above them
are right, which is the part that is written blind today.

.NH 1
What is left, after the first silicon
.PP
The radio transmits and receives on a board.  A tinySA beside it
measured the carrier at 868.00445MHz, 69dB over the floor, and the
board's own band sweep agrees with that instrument about where the
868 to 928MHz band is busy \- including the gap at 879MHz that both
find and the quiet above 890 that they used to disagree about.  What
follows is in the order the dependencies run, not in order of
interest.
.IP "1.  The RSSI scale.  Done." 6
Everything else that reads the air depends on it.  Carrier sense, the
sweep, a link budget and any decision about whether a channel is
clear are all that number.  It is about a hundred decibels high, and
the reason is now known: AGC_GAIN_ADJUST is 0 on the part and not the
\-102 the driver writes.
.PP
It is not that register.  On silicon, after a boot, every register in
TI's table holds its table value and every register written after the
table holds its
.I reset
value \- PKT_LEN 3 where 125 was written, AGC_CS_THR and
AGC_GAIN_ADJUST 0, IOCFG1 and IOCFG2 still the table's rather than the
high-impedance the board wants.  The call after all of them,
setfreq(), plainly worked: the part is on 868 and a tinySA has seen it
there.  So a run of writes between two things that worked did not
reach the part.
.PP
None of it reproduces at a shell prompt.  Written by hand through the
ctl file the same registers take and read back; a plain write straight
after an extended write is fine, and so is one straight after the
three XOSC writes that end the extended table.  What a prompt cannot
reproduce is the timing, since at boot these run back to back at bus
speed and at a prompt they are a tenth of a second apart.  Nor does
the qemu model reproduce it, which is worth knowing before anyone
tries to debug this without the board.
.PP
What the part's own FREQ registers say settles where the boundary is.
They read 0x6c8000, which is setfreq()'s arithmetic for 868MHz, so the
lost run is bounded on both sides by runs that worked and is exactly
the eight writes that follow the extended table.  That table ends with
XOSC5, XOSC3 and XOSC1, the crystal oscillator's own configuration,
and eight two-byte writes at this bus rate is on the order of a
hundred microseconds \- the shape of a part that has taken its
oscillator down and back up and is not answering meanwhile.  So
cc1120init() waits for CHIP_RDYn after the tables, as it already does
after SRES and for the same reason.
.PP
It was the right diagnosis.  With the wait in, on the board:
.PP
.EX
	cc1120 mikrobus2: CC1120 rev 0x21, listening
	; cat /dev/radio0/stats
	rssi -110 offset -102 csthr -90 last 0
	pktcfg0 0x20 pktlen 125
.EE
.PP
\- no SETTINGS NOT APPLIED on the boot line, where the six read-backs
would have named any register that disagreed, and every one of the
eight writes in the part itself: AGC_GAIN_ADJUST 0x9a and AGC_CS_THR
0xa6 where both were 0x00, IOCFG1 and IOCFG2 0x30 where they still
held the table's 0xb0 and 0x06, PKT_LEN 0x7d where it held its reset
value of 3.  The RSSI reads \-110dBm where it read \-9.
.PP
So the number is no longer a hundred decibels out.  It is not yet
calibrated, which is item 2.
.IP "2.  Calibrate it against a source, not a datasheet.  Slope done; the offset wants a source accurate at 915MHz, not a connector." 6
\-102 is the figure TI's examples use and it is not a measurement of
this board.  The tinySA has a signal generator in it, so a known level
at a known frequency into the click's antenna gives the offset this
board actually wants.  That is the difference between an RSSI and a
number.
.PP
THE CLAIM BELOW IS WRONG AND IS KEPT FOR WHAT IT COST.  The generator
does reach the board \- but not for the reason first written here, and
the correction is worth more than the claim.
.PP
What made it work was the frequency, not the mode.  A generator's
frequency on this instrument is the
.B sweep
setting;
.CW "freq 915000000"
does not set it, which is why 915MHz asked for came out at 10 and why
the screen knew and the serial port did not \- bare
.CW mode ,
.CW freq ,
.CW level
and
.CW output
print their usage rather than their state.
.PP
.CW "mode output"
and
.CW "mode low output"
are the same thing on this firmware, measured: at 915MHz and
.CW "level -60"
this receiver reads \-76dBm under either.  So the generator is on its
low path, above the 800MHz that path is specified to, and the first
version of this section credited a mode change that changed nothing.
Two things were altered in one step and the wrong one was thanked.
Measured: generator off, this receiver's floor \-111 and peak \-106;
generator on, floor \-93 and peak \-92; three times, on command.
.PP
And cabled straight into the click, the scale comes out.  Stepping the
generator from \-52 to \-76dBm in fours, the receiver reads \-68, \-72,
\-76, \-79, \-83, \-89, \-89, which is a least-squares slope of 0.93 and
an intercept of \-20.  Above about \-50 it saturates flat at \-65 to
\-68 however hard it is driven, and with the generator off it reads
\-119, eight dB quieter than on the antenna, which is the cable
shielding it and is the best evidence the connection is real.
.PP
The slope is the part to keep.  It is a relative measurement and an
attenuator's steps are accurate whatever its absolute level is doing,
so 0.93 says this RSSI under-reports a change by seven per cent, and
that it is linear from \-68 down to at least \-89 and saturates above.
The intercept is not to be kept: the generator is out of its specified
band, so how much of \-20 is cable and how much is an uncalibrated
output cannot be separated here.
Nothing about a connector was ever in the way, only a word.
.PP
What is still not possible is the half that matters.  A known level
into the click's antenna is what gives an offset, and free space
between two antennas is an unknown loss, so what a radiated source
calibrates is the slope \- whether ten dB of generator moves ten dB of
RSSI \- and not the offset.
.PP
.B "THE NEXT SENTENCE USED TO SAY THE OFFSET WANTS A u.FL ADAPTER THIS BENCH DOES NOT HAVE, AND THAT IS WRONG."
It contradicted the paragraph above it, which records the generator
cabled straight into the click and the connection proved real by the
floor dropping eight decibels when it was made.  The cable exists and has
been used.  Worse, the claim was repeated for a day afterwards as the
reason item 2 is half done, in commits and in a report, by reading one
sentence and not the one before it.
.PP
.B "What the offset actually wants is a level-accurate source at 915MHz."
The tinySA's generator is out of its specified band there \- its low
output path stops at 800MHz \- so its absolute level cannot be trusted
and, as the paragraph above says, how much of that \-20 intercept is
cable and how much is an uncalibrated output cannot be separated here.
A connector does not fix that; a generator specified to 915, or a source
whose absolute level is known at 915 with a calibrated attenuator, does.
.PP
.B "The connector that IS missing is a different one."
There is no u.FL-to-u.FL cable, which is what would join the two
.I boards
to each other and take the air out of a measurement between them.  That
is what item 9's error-rate bullet wants \- a channel whose loss is set
by an attenuator rather than by how far apart two antennas happen to be
\- and not what item 2 wants.  Mixing the two up is how the wrong one
came to be written down.
.PP
What was written here before, and is false:
The generator does not reach the board.  At 868 it cannot: a tinySA
ULTRA's output is the low path, which stops at 800MHz.  At 433.92,
which both parts cover, the board's floor does not move between
.CW "level -76"
and
.CW "level -6"
\- the top of its range \- and the \-89dBm bursts that do appear are
there with the output off as well, which is 433.92 being the busiest
frequency in the ISM bands and not the generator.
.PP
The path between the two is not the problem, and the proof is in the
other direction: with the board holding a carrier, the tinySA on its
fitted antenna sees 868.004454MHz at \-35.1dBm against a \-106dBm
median, 71dB of margin.  So the antenna is on the tinySA's input
connector and the generator comes out of the other one.  Moving it, or
better a cable and a known attenuator between the two, is what this
needs; over the air the path loss is an unknown that cannot be
separated from the receiver's error, so it would be a comparison and
not a calibration.
.PP
What can be said without it, from both instruments sweeping 868-890 at
the same time: the board now reads 2 to 16dB below the tinySA, mean
about 9, where before item 1 it was about a hundred out.  That is a
sanity check and not a measurement \- different antennas, different
positions, different detectors, and the signals up there are bursts
that the two instruments are not looking at in the same instant \- but
it is the difference between a number that is wrong by the width of
the scale and one that is wrong by the width of an antenna.
.IP "3.  Receive a packet that somebody else sent." 6
.B DONE.
Ten packets between two clicker 2 boards, ten received, payload intact;
the answer is in the last section of this document and the fault was an
interrupt edge in a board file.  What follows is what was written before
it was answered, kept because the elimination was all sound and none of
it was ever the fault.
.PP
The transmitter is proven against an instrument and the receiver is
proven against an instrument, and neither has yet carried a packet on
silicon.  There is one CC1120 here, so this needs either a second one
or a transmitter already on the air.
.PP
Wireless M-Bus at 868.95MHz was the candidate named here, on the
grounds that it is what this chip family exists for and that a meter
is a transmitter that does not need arranging.  It is not a candidate
on this bench: 868.95 is a European allocation, and
.I tools/tinysa/survey.py
finds nothing there.  What it does find, twenty sweeps at 3.8ms a bin,
is worth writing down because it is the first measurement of this air
that distinguishes a transmitter from the noise:
.PP
.EX
	868-890   bursty across 869-884, 50kHz to 1.9MHz wide,
	          peaks -75 to -85, never in more than 6 of 20
	902-928   narrowband bursts 58-116kHz wide, peaks -64 to
	          -85, each seen in one sweep of twelve
	433-435   weak narrow bursts 4 to 18kHz wide, peaks -96
	          to -102, one sweep in twenty
.EE
.PP
The 902-928 signals hop.  Four runs put the strongest bin at 922.33,
913.23, 918.56 and 917.63MHz, each 58 to 116kHz wide and each seen
once, which is one hopping transmitter and not four fixed ones; and
922.33 reads \-64.4dBm in 58kHz bins and \-90 in 3kHz bins on a
different bin, which is the same fact from the other side.  A CC1120
can demodulate one hop and cannot follow a sequence it does not know.
.PP
So there is no standard FSK packet format on this air to lock a sync
word onto, and that changes what this item is.  It is not a register
table for somebody else's protocol; it is raw capture, and then
looking at timing.
.PP
The first half of that is built.  The ctl file takes
.CW "capture <ms> [dbm]" ,
which samples RSSI as fast as the bus allows and prints the run
lengths above and below a threshold, and the tinySA does the same
measurement from outside with
.CW "survey.py zero <hz>" ,
which puts the instrument in zero span so its 450 points become 450
instants.  Both run.  At 881MHz the instrument sees bursts under a
millisecond at a duty of 2 to 7 per cent, peaking at \-74dBm, with
gaps between 13 and 34ms; the board sees a threshold crossed there
that it never crosses at 893MHz, which is the control.
.PP
Two things were learned by doing it, and both are worth more than the
capture.
.PP
The SPI was running at APB1/256, the slowest divisor the part has,
because a comment said that was fast enough \- and it was, for
register writes.  164kHz makes one RSSI sample 293us, which is exactly
the 296us the capture measured for itself, so the time resolution of
everything this board could ever record was one line in
spistm32f4.c.  At APB1/16 it is 27us.
.PP
And polling the bus desensitises the part being polled.  At 893MHz,
with nothing transmitting and watch reporting a floor of \-118dBm, a
capture at 27us a sample crosses \-106 after 3.3ms and stays there.
Same kernel, same clock, same frequency: watch samples once a
millisecond and capture samples continuously, so it is the duty of the
SPI and not its speed, and the 3.3ms is the AGC settling to the noise
the bus is making.  A capture reads 15 to 20dB hot with its own bus as
the floor.
.PP
Which says what the second half is.  Not a faster bus \- not using the
bus: this part will put its demodulated data or its carrier sense on a
GPIO, and GPIO3 is already wired to this board's interrupt pin, so the
envelope can be read with no SPI traffic at all and at the resolution
of a timer rather than of a register read.
.PP
That is
.CW "gcapture <ms> [iocfg3]" ,
and it runs: 1.37 microseconds a sample on the board, against 27 for
the same thing over the bus and 296 before the SPI divisor was
changed.  Two hundred and fourteen times finer than where this
started, and no bus traffic to be heard by the receiver.
.PP
Which selection of IOCFG3 is the carrier sense was not known and is
not in this tree's notes, so it was swept.  0x11 is the only one of
thirty that follows the air: static low over 200ms at 893MHz on every
run, toggling at 881MHz, and moving with AGC_CS_THR the way a
threshold should \- at a csthr of \-112, under the noise, it toggles
at both, and at \-105, between the two floors, it separates them.  The
read path was checked first by inverting a selection rather than by
reasoning: bit 6 of IOCFG inverts the output, 0x06 reads low and 0x46
reads high.
.PP
What it sees at 881MHz is carrier present for 2.826, 2.826, 2.826 and
2.824ms in one run, 2.818, 2.817, 2.818, 2.804, 2.806 and 2.818 in
the next, and 2.857, 2.855, 2.844, 2.859, 2.859 and 2.858 in a third,
with longer ones at about twice that and gaps from 6 to 90ms.  A
length that repeats to two microseconds across three captures is a
real quantum of something.
.PP
It is not the transmitter's burst length, and what it is instead took
three wrong answers to find.
.PP
Not the threshold.  Raising csthr by 5dB does not shorten it, and on
the instrument the median burst stays 0.44ms from floor+2 to floor+12
while only the count changes, 369 down to 113.
.PP
Not the AGC hysteresis, which is AGC_CFG0's top two bits: over all
four values the 2.8ms survives in three.
.PP
And not, as was written here for an afternoon, a register field whose
meaning this driver had wrong.  AGC_CFG0 bits 3:2 are RSSI_VALID_CNT
after all \- 2, 3, 5 or 9 estimates \- and the reason they looked
wrong is that writing that register while the part is receiving leaves
the AGC somewhere the RSSI does not come back from.  0xc3 gave
+78dBm, and 0xcb gave a sane \-84 once and +113 an hour later from the
same write.  Written from IDLE and followed by a retune, all four
values read \-93 to \-110dBm, repeatably.
.PP
With that fixed the field measures itself, and the mystery with it.
The shortest carrier sense the part will assert is one RSSI update, so
at 881MHz the shortest burst is 0.608ms at 2 estimates, 0.927 at 3,
1.568 at 5 and 2.79 at 9 \- ratios of 1.52, 1.69 and 1.78 against the
1.5, 1.67 and 1.8 those counts predict, and 0.304, 0.309, 0.314 and
0.310ms an estimate.  One estimate is 0.309ms on this board.
.PP
So the 2.8ms was nine of them.  The envelope was never the
transmitter's; it was the receiver's own averaging, and the board was
reporting the shape of its filter.  At two estimates the shortest
burst is 0.61ms, which is under the 0.89ms the tinySA puts them at,
and the two instruments agree for the first time.
.PP
What the transmitter actually does is still not known, because 0.61ms
is the floor of this method rather than a measurement: the true burst
is at or below it.  Getting under that means the demodulator's output
rather than its carrier sense, which is a different pin selection.
.PP
Which one was a sweep, and the sweep is now a ctl verb.
.CW "gsweep <ms>"
sets IOCFG3 to each of the sixty-four selections in turn and prints
how many times the pin changed in the window, so the question takes a
third of a second on the board instead of sixty console round trips.
Three selections change fast: 0x28 at about 20kHz, 0x2e at 150, and
0x31 at the sampler's own rate.
.PP
Finding them hung the machine twice, which is the part worth
recording.  This board takes a rising edge on that pin as "a packet
happened", so a fast selection is an interrupt storm: the first sweep
printed as far as 0x27 and stopped, with no prompt and no echo, and
^R^R could not recover it because that is a keystroke and there was no
room left to service the uart.  Spidev grows irq() and the sweep holds
the line masked.  Then the capture verb did it again, because it
masked after writing IOCFG3 and unmasked before restoring it, and the
window between the two is enough.
.PP
0x28 carries the demodulator.  At 881MHz its pulses fall on a 49.2
microsecond grid and the intervals between them are dominated by two
grid steps \- 81 of 128 \- while at 893MHz, where nothing transmits,
the same capture gives 88 of 128 at one step with a tail out to
seventeen.  So the pin is not a free-running clock: it follows the
air, and on a real signal it collapses onto a 98.4 microsecond period.
That is symbol-level structure out of a real transmission, at 1.39
microseconds a sample, using the receiver's own demodulator.
.PP
WHAT IS TALKING, AND WHAT PROTOCOL.  Neither is known, and nothing
measured here justifies a guess at either.  What there is, is an
occupancy map.  Parking the receiver on a frequency for two seconds
and counting how much of it carrier sense is asserted, against
channels the sweep says are empty as a control:
.PP
.EX
	908.717  duty 95%  bursts to 88ms, gaps 0.6-1.9ms
	914.160  duty 84%  bursts to 45ms
	906.980  duty 39%
	904.500  duty 32%  picked as a control and is not one
	922.383  duty 26%
	918.000  duty  1%  14 bursts in two seconds
	926.000  duty  1%
.EE
.PP
That discriminates, which is the point of the control: 918 and 926 are
quiet and 908.7 is busy, measured the same way in the same minute.
The occupied bins in 902-928 fall in clusters three hundred to four
hundred kilohertz wide at 907.0, 908.6-909.1, 914.0-914.3, 921.2,
922.3 and 922.9, and the strongest one moves between sweeps, which is
hopping.
.PP
WHAT THE OCCUPANCY NUMBERS ARE WORTH, measured later and worth putting
before them.  Three runs of the same probe at 918MHz within a minute
gave a channel busy 89 per cent of the time, then 0, then 0.  The
difference is not the air.  The first pass of a probe only catches a
burst if one happens while it is looking, and on a channel busy a few
per cent of the time it often does not; the threshold then sits close
enough to the floor that the AGC breathing across it is counted, and
the run reports hundreds of bursts.
.PP
Comparing the peak against the floor does not separate the good runs
from the bad \- the bad ones had 14 and 20dB between them.  What does
is the shape of the result.  Noise crossing a line gives bursts and
gaps of the same shortest length, both at whatever the receiver can
resolve, and in numbers no transmitter sends; a real burst train has a
shortest gap far longer than its shortest burst.  The probe verb says
NOISE when it sees the first shape, and on every run recorded here
that rule agrees with which results repeated and which did not.
.PP
So the duty cycles in the table above are upper bounds on runs that
were not checked that way, and the ones that matter \- 918 and 926 at
1 per cent against 908.7 at 95 \- were reproducible.
.PP
And burst lengths from carrier sense are not lengths.  The shortest
assertion the part will make is one RSSI update, which is 0.62ms at
the fastest filter setting, so every duration comes out as a small
multiple of that: 631 to 645 microseconds at 917.4, about 1.35ms at
908.6 and at 918.  Six bursts measuring 1341 to 1343 microseconds
looks exactly like a transmitter with a fixed frame and is two
resolution cells.  Reading a burst length off this needs the
demodulator pin, not carrier sense.
.PP
THE DEMODULATOR PIN, AND THE THIRD TIME THIS LESSON LANDED.  Carrier
sense cannot resolve these bursts, so the next thing is IOCFG3 0x28,
which follows the demodulator and changes every ten microseconds
rather than every RSSI update.  Two ways of reading it were built and
neither answered the question.
.PP
.CW gcapture
keeps the sequence and fills its array in twelve milliseconds, which
on a channel busy five per cent of the time almost never contains a
burst.
.CW ghist
gives up the order to cover the whole window, and then averages the
burst away: two seconds at 918MHz and two at 926 came out the same to
within a few per cent, because in both the great majority of what it
counted was silence.  That result also undercuts an earlier one \- a
single twelve-millisecond capture at 881 against one at 893 had
looked like a clear difference, and on this evidence it was a small
sample.
.PP
.CW gtrig
is the answer to both: watch carrier sense until it asserts, switch
the pin, and record from there.  It works, and at 918MHz it records a
burst as narrow pulses separated by gaps of 22, 90, 158, 226, 311 and
430 samples at 0.44 microseconds a sample.  The sequence varies
through the burst and between captures, which is what data looks like.
.PP
It is not data.  The same capture at 926MHz gives the same set of
lengths \- 22, 45, 68, 90, 135, 203, 248, 316, 361, 429, every one a
multiple of about 22.6 samples, or 9.94 microseconds \- with the same
commonest value and only the tails differing.  A quantum common to two
channels is the receiver's clock.  So the pin shows when the
demodulator is doing something and not what it is doing, and three
separate measurements in one day \- the 2.8ms carrier sense quantum,
the 1.34ms burst length, and this \- have now all turned out to be the
instrument rather than the air.
.PP
THE PAGING BAND, which this survey had never looked at.  Every sweep
here stopped at 928MHz because that is where the ISM band ends, and
the US paging allocation starts immediately above it.  Twenty sweeps
of 928 to 932 find nine carriers \- 928.82, 929.38, 929.63, 929.84,
930.33, 930.54, 930.82, 931.32 and 931.81MHz \- peaking at \-83.8dBm
against a \-113 floor, 9 to 80kHz wide, on something close to a 25kHz
grid.  929.63 appeared in six sweeps of twenty, which is the most
persistent thing this bench has measured.
.PP
That is the right target for a first decode and the reason is the
part.  POCSAG is 2-FSK at 512, 1200 or 2400 bits a second with
\(+-4.5kHz deviation and a 32-bit frame sync word, 0x7CD215D8, and a
CC1120 does 2-FSK with 32-bit sync words.  Nothing about it is beyond
this receiver, which is not true of anything else measured here.
.PP
Configured for it \- 929.63MHz, 1200 symbols a second, 4486Hz
deviation against the 4500 asked, a 12.5kHz filter and that sync word,
every one read back off the part \- it received nothing in 140
seconds.  No packets, no CRC errors, no overflow.
.PP
The likely reason is the protocol and not the radio.  Most paging in
the United States is FLEX rather than POCSAG: 1600, 3200 or 6400 bits
a second, a different sync word, and 4-level as well as 2-level.  The
next thing to try is FLEX at 1600 two-level, and after that the other
POCSAG rates; all of them are a ctl line each now.
.PP
And FT8 is not a candidate, on any band, which is worth writing down
because the frequencies are inviting.  Three independent reasons: it
is 8-FSK and this part does 2 and 4; it is 6.25 symbols a second and
the slowest this part's rate register expresses is 61; and it is about
50Hz wide where the narrowest receive filter here is 1984Hz, which is
16dB of noise added to a signal designed to sit below the noise
already.  It also wants soft-decision metrics for its LDPC decoder and
this part hands over hard bits from a slicer.
.PP
What to point at it next is a different kind of measurement, and it
now exists.  Everything this bench could do until today reported a
threshold being crossed \- an RSSI, a carrier sense, a packet that did
or did not match a sync word \- and a threshold belongs to the
receiver.  That is how three separate measurements in one day came
back as a transmitter's signature and turned out to be the
instrument's own quantisation.
.PP
.B PKT_CFG2 's
PKT_FORMAT of 11 is transparent serial mode, where the packet engine
is out of the path entirely and the slicer's output goes to a GPIO.
Nothing filters it, so no sync word has to match: a transmission this
radio cannot decode is still one it can measure.  And what it measures
is a symbol period, which is a property of whatever is transmitting.
A preamble is an alternating pattern at the symbol rate, so under
.B ghist
it arrives as a pile of runs all one length \- 1953us for 512 symbols
a second, 833 for 1200, 625 for 1600, 417 for 2400 \- and noise has no
such pile.  The
.B serial
verb turns it on.
.PP
It has a positive control, which is why it is worth trusting at all,
and the control is a test rather than a memory:
.I tools/radio/serialrate.sh .
The qemu model grew a transparent mode and an
.B airrate
property that puts a rate on the channel the guest was never told;
with the guest configured for 2400 throughout, 300 symbols a second
measures a symbol period of 20 to 21.5ms against 1200's 7.3 to 7.4, a
ratio of 2.7 to 2.9 where the rates differ by four, on three runs.
The gap between that and 4 is the histogram: bins a power of two apart
locate a period to within a factor of two, so the test's band is a
factor of two either side of four and not tighter.
.PP
And it has been shown to fail, which is what makes those three runs
worth anything.  With both rates set to 300 the same test measures
20.7 and 21.1ms and prints SERIAL-FAILED at 0.9, so it is comparing
the channel and not something that would agree whatever the channel
did.  A control that has only ever passed is not known to be able to
fail, and this one is cited in two places as the reason to trust the
verb.  Those two numbers are also the measurement's repeatability, 1.5
per cent.  The absolute values are six
times long and 4800 measures the same period as 1200, both because a
guest polling a pin in a tight loop and qemu's virtual clock disagree;
silicon samples at 1.37us against the model's nine and takes its bits
from the air, so neither limit is the method's.  Silicon shows nothing at all, and that
has now been looked into rather than left as "not yet".
.PP
What
.B "serial on"
does on silicon, measured rather than assumed.  Both registers the mode
needs are set and read back off the part \- PKT_CFG2 0x07, PKT_FORMAT
11, and MDMCFG0 0x0d with TRANSPARENT_MODE_EN \- and GPIO3 does not
move, over half a second and 405000 samples at 1.23us, at all four
TRANSPARENT_INTFACT settings, with a serial clock configured on another
pin and without one.
.PP
The control is a sweep of all sixty-four IOCFG3 selections with the
mode off and with it on.  Exactly three move either way and by the same
amount both times \- 0x28 at 353 and 239 runs, 0x2e at 3011 and 4350,
0x31 at 38424 and 38375 \- so the instrument works and the mode changes
nothing observable.  Nor is any of the three the bit stream: 0x2e and
0x31 run in ones and twos of a sample and are identical at 1200 and
4800 symbols a second, which is a clock; 0x28's gaps do move with the
symbol rate but upward as the rate rises, which a symbol period does
not do.
.PP
One thing this board cannot rule out, and it is the likeliest: it wires
one of the part's four GPIOs, GPIO3 to PE14.  A mode that delivers on
another pin looks exactly like this from here, and a second wired GPIO
is a soldering job rather than a software one.
.PP
Two of the cheap things the POCSAG negative did not rule out are now
ruled out, by
.I tools/radio/pocsagmatrix.py :
the rate, since only 1200 of POCSAG's 512, 1200 and 2400 had been
tried, and the polarity, since the part compares the demodulated bits
against the sync word as written and an inverted on-air sense would
flip every one of them so that 0x7CD215D8 could never match however
much POCSAG was on the channel.  Eighteen windows of 45 seconds \-
929.630, 928.8196 and 929.840 by three rates by the word and its
complement 0x832DEA27 \- received nothing.  Thirteen and a half
minutes of the paging band.
.PP
No CRC errors either, in any of the eighteen, and that is the part
worth reading.  A receiver sync-matching on noise reports packets that fail
their CRC; a receiver whose sync word never matches reports neither.
So nothing matched at all, which is consistent with there being no
POCSAG on that carrier and equally consistent with this part's 32-bit
sync path not working on silicon \- and those cannot be separated from
here, because the sync path has never been shown to give a positive on
silicon.  The
.B serial
verb is what would break that tie, since it needs no sync word to
match.  It is flashed and it does not work on this board.
.PP
And a bench note, with what it is not.  A warm reset on
os/inferno/stm32f407 \- the ^R^R at the console, which is
.IR exit (0)
from the uart interrupt handler \- stopped after the poolsize contig
print and never reached a shell, three times running, with the console
left showing a line the board had cut short.  A later warm reset, from
a freshly booted machine, came back to a prompt.  So it is not
deterministic and it is not the reset path as such: it depends on the
state the machine was in when the reset arrived, and all three wedges
followed a shell that had died with "out of memory: heap".  That is
the shape of something left held \- except that
.I _start
copies .data out of flash and zeroes .bss before
.I main
runs, so nothing in the allocator's own structures can survive to be
held.  Unexplained, and written down as unexplained.
.PP
qemu cannot reproduce it and cannot be made to: it reloads the kernel
image on every reset, so its .data is fresh where a board's is
re-copied by code that has to run first.  The one thing fixed at the
source is the ambiguity the log had \- whether the board printed a
chunk of zero and went on or printed 614 and stopped inside the line,
which are different faults.  The value comes before the prose now, so
a cut line still carries the number.
.PP
That line was blamed on the console, and the console did not do it.
This bench had it written down that the board loses the tail of a line
longer than about fifty characters; measured with a digit ruler at 30,
40, 50, 60, 80 and 100 characters, nothing is lost in either
direction, and a 105-character command carrying a 100-character
argument came back whole.  So the reset did stop after exactly
"poolsize: poolalloc() contig chunk 0" \- one character into a
five-character number \- and whatever that is, it is inside
.IR print .
The same format prints correctly under qemu.  Unexplained, and one of
the two reasons the fixed trace is worth having: the next wedge will
say whether the number arrives.
.PP
THE THREE STRONGEST CARRIERS THIS RECEIVER CAN FIND ARE ITS OWN.
.PP
Asked, on a later day, what in the band might actually be decodable,
and the first thing to do was look rather than remember.  A max-hold of
928 to 932MHz \-
.I tools/radio/bandhold.py ,
which splits a span into the 64 steps the
.B hold
verb takes and reports what stands above the median of its own span \-
put every one of the nine paging carriers within a few dB of a \-109
floor, and found two things above it: 929.600 and 929.625 at \-102, and
928.000 at \-86, twenty-three dB up.
.PP
928.000 looked like the find of the session.  Continuous, narrow,
strong, and sitting exactly where the Part 15 band ends and the fixed
point-to-point allocation begins \- 928 to 929MHz is Multiple Address
System territory, SCADA and utility telemetry on 12.5kHz channels,
which commonly run 2-FSK or 4-FSK at a few kilobits and would be this
part's home ground.  A sweep of 926 to 928.5 found nothing else at all,
so it was not energy leaking up from the ISM soup.  Narrowing the
filter to the 8kHz minimum the part accepts gave a flat top from
927.998 to 928.004 and eight dB down at two kilohertz either side,
which is the filter's own shape: the signal is narrower than 8kHz.
.PP
It is the crystal.  28, 29 and 30 times 32.000000MHz are 896, 928 and
960, and all three are there \- \-86dBm at 896.000, \-86 at 928.000,
\-88 at 960.000, the same flat-topped shape at each, against floors of
\-110.  A 32MHz harmonic is always on, exactly on a round number,
strong because it is internal, and narrower than any filter the part
has.  Everything that made 928.000 convincing is a property of the
receiver.
.PP
.I bandhold.py
names them now rather than leaving it to whoever reads the output, and
says so when every candidate in a span is one.  That is the fourth time
in this work that structure turned out to be the instrument, and the
first time it was caught before it was claimed.
.PP
So, to the question.  Nothing in this band is decodable by this
receiver as it currently stands, and the reasons are specific rather
than general.
.IP \(bu
The three strongest carriers are the crystal.
.IP \(bu
The most active real signal is around 881MHz at 42 per cent duty, and
869 to 894 is the cellular downlink \- a base station, GMSK at 270.8
kilobaud or OFDM, in channels wider than the 200kHz this part's filter
reaches.  Undecodable in principle and not a near miss.
.IP \(bu
The paging carriers are the right target, for the allocation reason and
not for a hopeful one, and they are not there at the moment.  929.600
at 7dB over the floor is the only trace, which also means the eighteen
POCSAG windows may have been taken against dead air and cannot be read
as evidence about POCSAG.
.IP \(bu
And classifying 2-FSK against 4-FSK, which is what would tell FLEX from
POCSAG from telemetry, needs either the raw bit stream \- the serial pin
does not work on this board \- or a filter narrow enough to resolve the
deviation pair.  At \(+-4.8kHz the humps are 9.6kHz apart and the part's
narrowest filter is 8kHz, so that measurement is at the edge of
possible even with a signal present.
.PP
What would change it, cheapest first.  An antenna: the tinySA measured
\-83.8dBm where this receiver now reads \-102 to \-110, and twenty dB is
the single likeliest explanation for all of the above.  Then a
presence-triggered measurement instead of fixed windows, so the
receiver looks while something is transmitting rather than on a
schedule \- 
.B gtrig
armed on carrier sense over hours.  Then a second wired GPIO, which is
a soldering job.
.PP
TWO INSTRUMENTS AT THE SAME TIME, WHICH SETTLED BOTH QUESTIONS.
.PP
The crystal first.  A tinySA sweep of 895.8 to 896.2MHz, 1kHz bins,
reports nothing above a \-114.3 floor; of 959.8 to 960.2, nothing but
hits at exactly the reporting threshold, which is what noise looks
like; and of 927.8 to 928.2, one trace at 928.0058 at \-105.7dBm, twenty
dB below what the CC1120 claims for the same frequency at the same
moment.  So the receiver reads \-86dBm at 896.000 where an instrument
with a better view of the room reads nothing whatever, and the one
place the tinySA does see something is the frequency where the CC1120's
own harmonic would be radiating out of the click's antenna into it.
Internal, confirmed from outside.
.PP
And the band, which is the useful half.  Sixteen sweeps of 928 to 932
at the same time as all of the above:
.DS
.CW "      at MHz    width    peak    mean     p-m   seen"
.CW "    930.8241      18k   -80.2  -103.9    23.7    2/16"
.CW "    929.3274      18k   -85.2  -104.5    19.3    1/16"
.CW "    929.8263      27k   -90.7  -104.5    13.7    2/16"
.CW "    929.6036      62k   -91.2  -101.7    10.5    6/16"
.DE
which is a burst transmitter's signature and not a carrier's: a peak
twenty dB over the mean, and the mean at the floor, because most sweeps
caught the silence.  929.6036 is the same most-persistent channel the
earlier survey found, at the same level, six sweeps in sixteen.
.PP
So there is something to decode, and the reason this receiver is not
decoding it is the antenna and nothing subtler.  Its noise floor is
\-110 to \-112 against the tinySA's \-106.7 \- better, not worse \- and it
reads \-102 where the other reads peaks of \-80 to \-91.  A receiver with
the lower floor and ten to twenty dB less signal is a receiver whose
antenna is not delivering, which is a connector rather than a
soldering iron and is the one thing to fix before anything else here is
worth measuring again.
.PP
930.8241 is the channel to point it at when that is done: the strongest
of the four, and 18kHz wide, which is what 2-level FLEX at 1600 bits a
second or POCSAG at 1200 occupies.  At \-80dBm it would sit thirty dB
over this part's floor.
.PP
And pointed at it for sixteen seconds, in eight windows of two, it sees
nothing: floor \-113, peak never above \-110, no bursts in any window,
while the other instrument was reading \-80.2 there.  So the deficit is
measured on two channels now and it is about thirty dB, with this
receiver holding the better floor of the two by six.  A part whose noise
floor is \-113 is working; what is not reaching it is signal.  Nothing
else in this section is worth pursuing until an antenna is on that
click, and the shape of the evidence \- textbook floor, thirty dB of
missing signal \- is what a disconnected or wrong-band antenna looks
like rather than a subtle one.
.PP
930.824 IN ZERO SPAN, AND HOW MUCH OF IT TO BELIEVE.
.PP
.I tools/tinysa/listen.py
stays on one frequency instead of sweeping past it, and on 930.824 it
reports bursts at \-71 to \-73dBm against a \-96 floor \- eight dB
stronger than the sweep's \-80.2, and twenty-four dB over the floor, on
two separate runs.  That the signal is there is not in doubt.
.PP
What it is, is.  At 67us a point the bursts measure 1733us, run after
run, which looks like a number.  At 667us a point the same signal
measures 2667 and 3333.  A burst length that changes with the
instrument's resolution is the instrument, and the repetition disagrees
the same way \- about one burst per 30ms capture at the fine setting,
three to five per 300ms capture at the coarse one.  So nothing here
identifies a protocol, and in particular none of it matches paging:
FLEX frames are 1.875 seconds and a POCSAG batch at 1200 baud is about
half of one, against bursts of order milliseconds here.
.PP
The control for that was run and did not survive: zero span on 931.500,
which the sweep put at the floor, returned no captures at all in 174
seconds rather than captures containing nothing, and the instrument was
wedged when asked afterwards.  A tool that fails and a channel that is
quiet look identical in that output, so the 930.824 characterisation
stands uncontrolled and is written down as uncontrolled.
.PP
And a correction to the section above, which claimed the deficit was
measured on two channels.  It was measured on one.  The 881MHz
comparison used there is noise against noise: this driver's own probe
flags that frequency NOISE by its shape rule, and the tinySA's hits
across 878 to 884 are all within three dB of each other at one sweep in
twelve, which is what a reporting threshold looks like and not what a
transmitter does.
.PP
What survives, and it is enough to act on.  Two independent runs put a
real signal at \-72dBm on 930.824.  This receiver, whose noise floor is
\-113 there and whose synthesiser reads locked and correctly banded at
that frequency, sees nothing above \-110 in sixteen seconds.  Forty dB
between a healthy receiver and a signal two instruments agree is
present is a front end or an antenna and not a subtlety.
.PP
Three ways to settle which, cheapest first.  Swap the antennas between
the two instruments and repeat the 930.824 measurement on each: if the
deficit follows the antenna it is the antenna, and nothing has to
transmit.  Measure the element: a quarter wave is 82mm at 915MHz, 164mm
at 433 and 31mm at 2.4GHz, and which of those the whip is answers the
question by eye.  Or key the part at 915MHz, which is unlicensed at
Part 15 levels, and read it on the tinySA \- an antenna that does not
radiate does not receive either, and that measures the same thing by
reciprocity.
.PP
THE ANTENNA IS CONNECTED, AND THE TWO CLAIMS ABOVE THAT IT WAS NOT ARE
WITHDRAWN.
.PP
The part fitted is a Pulse W3312: a 75 by 15mm flexible PCB antenna for
863 to 928MHz, 45 per cent efficient, 0.8dBi, on 100mm of 1.13mm coax
with a U.FL connector, mounted with 3M467 tape.  Its return loss
resonates near 880MHz at \-16.7dB and does not climb back through the
\-8dB specification until about 935, so at 930.824 it is around \-8.5dB
\- two thirds of a dB of mismatch.  Nothing there costs forty dB, and
the release liner still on the tape costs a fraction of one.
.PP
And the receiver hears through it.  A max-hold across 822 to 958MHz at
the 25kHz bandwidth every other measurement here used is not flat: 874
reads \-92 and 878 reads \-93, the whole 846 to 890 stretch sits ten to
fifteen dB above the 894 to 930 region's \-105 to \-107, and that
elevated stretch is where the cellular allocations are.  A disconnected
input cannot make fifteen dB of structure that lines up with a band
plan.  Probed, 874 shows 82 bursts at 18 per cent duty and 878 shows 44
bursts of 2.9 to 6.3ms at 7 per cent, the latter passing this driver's
own NOISE rule rather than being flagged by it.
.PP
So the comparison that matters can finally be made properly, the
earlier one at 881 having been noise against noise.  At 878MHz the
tinySA reads \-92.5 and this receiver \-100, seven and a half dB apart.
At 930.824 the tinySA reads \-72 and this receiver \-102, thirty apart.
The chain is about twenty-two dB worse at 930 than at 878.
.PP
Which is a band fit and not a fault.  The antenna's specification stops
at 928 and the ccRF click carries its own matching network and balun for
the same ISM band; the paging allocation begins where both of them end.
Twenty-two dB of rolloff between 878 and 930 is more than the antenna's
return loss explains by itself, so the click's matching is the larger
half of it, and neither is something a driver can fix.
.PP
What that costs, stated plainly: the paging band is at the edge of this
hardware's reach.  A \-72dBm signal arriving twenty-two dB down is
\-94 at the demodulator against a \-112 floor, which is eighteen dB and
ought to be workable \- so the next question is why 930.824 reads \-102
rather than \-94, and that one is still open.
.PP
A TARGET INSIDE THE PASSBAND, AND A BUG THAT EXPLAINS A LOT.
.PP
Asked for something the hardware can actually reach, which means below
928MHz where the antenna and the click's matching both live.  Filters
first: at a quiet channel this part reports \-103 at 25 and 50kHz of
bandwidth, \-86 at 100kHz and \-43 at 200kHz, so anything over 50kHz is
not a measurement and the sweeps here use 50.
.PP
A max-hold of 902 to 928 at 200kHz steps finds, against a \-102 median:
918.200 at \-88, 927.200 at \-91, 908.200 at \-93, and a cluster at
911.4, 911.6, 912.0, 912.2 and 912.6 between \-93 and \-96 that is the
shape of a frequency hopper.  928.000 appears too and
.I bandhold.py
labels it as the crystal, which is the point of that check.
.PP
908.42MHz is the one worth having, and not because it is the strongest.
It is the US Z-Wave channel, and Z-Wave's parameters are published
rather than guessed: 2-FSK, \(+-20kHz deviation, 9.6kbit/s for R1 with a
0x55 preamble and an 0xF0 start of frame.  Nothing there has to be
derived, and the 50kHz filter this part tops out at is exactly what
\(+-20kHz and 9.6kbit/s want.  Probed, it gives an isolated 5183us burst
in one window and two of 52 to 55ms in another \- and 52ms at 9.6kbit/s
is 62 bytes, which is a full-length Z-Wave frame with its preamble.
Later a burst at \-77dBm, twenty-nine dB over the floor.
.PP
It receives nothing.  Configured for it and confirmed off the part \-
908.42MHz, 9600 baud, deviation 19958 against 20000 asked, 50kHz, fixed
length, CRC off \- and again at 19200 and 40000 baud, with a sixteen-bit
sync of 0xaaaa at the most permissive threshold, seventy seconds each:
no packets, no CRC errors, no overflow.  MARCSTATE reads 0x6d, whose
low five bits are 0x0d and that is RX, so the part is listening;
MARC_STATUS1 stays 0x00 and NUM_RXBYTES stays 0, so it never syncs and
the FIFO never sees a byte.
.PP
And one reason why, found by reading the registers back rather than
trusting the write.  Asked for a sixteen-bit sync of 0xaaaa, the part
holds SYNC3 0xaa, SYNC2 0xaa, SYNC1 0x51, SYNC0 0xde.  SYNC_MODE 2 is
SYNC15_0, which is SYNC1 and SYNC0; this driver wrote the word to SYNC3
and SYNC2 and set mode 2 anyway.  So every sixteen-bit sync word ever
asked for went where the part was not looking, and it went on comparing
against the 0x51de it was reset with.  Fixed in the driver and in the
qemu model together \- the model had the same convention, and its own
comment said it was a convention rather than a reading of the part and
that silicon would have to settle it.  Silicon settled it.  A model and
a driver wrong in the same direction pass every test between them,
which is what the two-board test had been doing.
.PP
That is not the whole of it, and the rest is now bounded rather than
guessed.  With the fix flashed and the sync registers read back correct,
the sync pin still never asserts.  Ruled out, each by measurement:
.IP \(bu
The threshold.  All of SYNC_THR 0, 4, 8, 16 and 31.
.IP \(bu
The modulation index, which was the leading suspect because Z-Wave's
\(+-20kHz against 9.6kbit/s is h = 4.2.  Static at h = 4.17, 2.08, 1.04,
1.00 and 0.50, an eight to one range.
.IP \(bu
The preamble detector gating the sync search, which would produce
exactly this.  Static with PREAMBLE_CFG0's PQT_EN set and cleared.
.IP \(bu
The packet engine being left in transparent mode.  PKT_CFG2 reads 0x04
and MDMCFG0 0x05.
.IP \(bu
The synthesiser.  FSCAL_CTRL reads locked and FS_CFG the 820-960 band at
every frequency tried.
.IP \(bu
The pin.  IOCFG3 0x06 reads low and 0x46, which is the same selection
inverted, reads high, so the register and the pin both work and a
selection that does not move is one that is not asserting.
.PP
What is left is the demodulator's supporting configuration \- the IF,
the AGC, the DC filter, the image correction \- which TI's tool sets as
one coherent group per configuration and which this driver updates only
in part when the rate, deviation and bandwidth change.  That is the next
place to look and it is a bigger job than a register.
.PP
THE RECEIVE PATH DOES NOT WORK ON THIS SILICON, AND HERE IS EVERYTHING
IT IS NOT.
.PP
The test bed changed, and that is most of why this is now worth
stating.  908.42 gives one burst in ten or twenty seconds, so a
two-second window there measures an empty channel whatever is being
swept; a six-minute watch found twelve windows with anything in them
and forty-one without.  874MHz gives 82 bursts of 2.8 to 8.6ms at 18
per cent duty, repeatably, inside the antenna's band.  Nothing here can
decode it \- 869 to 894 is the cellular downlink \- but decoding is not
the question.  Whether the sync machinery asserts at all is, and any
real modulated signal answers that.
.PP
Six and a half minutes on it, with a sixteen-bit sync of 0xaaaa at
SYNC_THR 0, fixed length, CRC off: no packets, no CRC errors, no
overflow.  Eighteen per cent of 380 seconds is about 68 seconds of
signal, which at 9600 baud is six hundred and fifty thousand bits, and
a sixteen-bit pattern turns up in random data about ten times in that
\- before allowing for a threshold of zero, which asks the qualifier
for as little as it can be asked for.  Zero is not a quiet channel.
.PP
Excluded, each by measurement rather than by reasoning:
.IP \(bu
The sync registers.  Fixed, verified off the part, and
.I tools/radio/synctest.sh
now pins the mapping to SWRU295E so it cannot come back.
.IP \(bu
The threshold: 0, 4, 8, 16 and 31.
.IP \(bu
The modulation index: h from 0.50 to 4.17.
.IP \(bu
The preamble gate.  PQT_EN set and cleared, the second time for six
and a half minutes on the busy channel rather than two seconds on the
quiet one.
.IP \(bu
FREQ_IF_CFG, which the driver never writes and which leaves at 0x40.
Eleven values across its whole range, all static.
.IP \(bu
The state.  MARCSTATE reads 0x6d throughout, whose low five bits are
0x0d, which is RX.
.IP \(bu
The configuration, read back register by register and checked against
its own arithmetic: MOD_FORMAT 000 is 2-FSK, DEVIATION_M 0x47 with
DEV_E 5 is 19958Hz, the DRATE triple is 9604 baud, CHAN_BW 0x04 is
50kHz, MDMCFG1 has FIFO_EN set and Manchester clear.
.IP \(bu
The pin and its selection.  IOCFG3 0x06 reads low and 0x46, the same
selection inverted, reads high; and carrier sense on 0x11 follows the
air, so ghist can see a pin that moves.
.PP
What is left needs the transmitter.  PKT_SYNC_RXTX is named for both
directions and asserts in TX as well as RX, so keying the part and
watching that pin separates a selection that is wrong from a receive
path that is broken \- and it is the only test left that does not need
a second radio.  915MHz is unlicensed at Part 15 levels and the part's
own default power into a 45 per cent efficient antenna is what that
rule is written for.  Nothing on this bench has ever transmitted, which
has been deliberate; this is the first measurement that needs it.
.PP
WHERE IN THE CHAIN IT STOPS, AND A CONCLUSION WITHDRAWN.
.PP
The section above says the receive path does not work on this silicon.
That is withdrawn, and the thing that withdrew it is a verb that took
ten minutes to write.
.PP
.B ghist
bins completed runs, so a pin that goes high and stays high has no
completed run in it and reads as "static" \- indistinguishable from a
pin that never moved.  Every conclusion above about a pin rests on that
reading.
.B gread
reports instead what fraction of a window the pin spent high, and run
across the receive chain's own status pins on 874MHz it gives a ladder:
.DS
.CW "  0x0d  RSSI_VALID      100% of 500ms high"
.CW "  0x11  carrier sense    28%"
.CW "  0x0b  PQT_REACHED       0%"
.CW "  0x06  PKT_SYNC_RXTX     0%"
.CW "  0x07  CRC_OK            0%"
.CW "  0x46  0x06 inverted   100%"
.DE
which says where it stops.  RSSI is valid, so the front end is running
and measuring.  Carrier sense is high twenty-eight per cent of the
time, so signal is arriving and crossing a threshold.  The inverted
selection reads full, so the pin and the register both work and a
selection at zero is one that is not asserting.  And the preamble
quality detector never fires.
.PP
Which is the answer, and it is not a fault.  874MHz is the cellular
downlink and cellular is GMSK at 270.833 kilobaud; it has no 0xAA
preamble at 9600 baud for a preamble detector to reach.  The channel
chosen as a control because it was busy cannot exercise the preamble
and sync path at all, so six and a half minutes of zeros on it is
evidence about cellular and not about this receiver.  The reasoning
that picked it \- any real modulated signal will do, because the
question is only whether the machinery asserts \- was wrong, and wrong
in the way this work keeps being wrong: a control that cannot produce
the positive is not a control.
.PP
So the receive path is untested rather than broken, and testing it
needs a channel carrying 2-FSK with a preamble the part can lock to.
908.42 is that channel and gives one burst in ten or twenty seconds,
which is why the ladder has not been run on it yet: it has to be run
while a burst is in the air.  The instrument for that exists \-
.B gtrig
arms on carrier sense and records \- and pointing it at the preamble
pin rather than the sync pin is the next measurement, because
PQT_REACHED is the first rung that a real 2-FSK preamble should light
and the first one that would prove any of this works.
.PP
Also found, and it invalidates the earlier silicon listens.  Running
the configuration silicon was wearing through the qemu model \-
.I tools/radio/silicfg.sh
\- no packet arrives, and bisecting the six ctl lines shows why:
.DS
.CW "  ARRIVED   nothing changed (control)"
.CW "  ARRIVED   sync 0xaaaa 16 only"
.CW "  ARRIVED   rate/dev/bw only"
.CW "  lost      txmode fixed + pktlen 64 only"
.DE
In fixed-length mode the receiver waits for exactly PKT_LEN bytes after
the sync word, and the test sends seven.  Every silicon listen before
this was in that mode, so a matched sync could only have completed a
packet if exactly sixty-four bytes followed it.  Repeated in variable
length on 874 it still receives nothing, but that is the channel's
fault rather than the configuration's, per the ladder above.
.PP
THE POSITIVE CONTROL, AT LAST, AND IT COST ONE TRANSMISSION.
.PP
Everything above rests on IOCFG3 selection 0x06 being PKT_SYNC_RXTX,
which was taken from a table and never demonstrated.  PKT_SYNC_RXTX is
named for both directions and asserts from the sync word to the end of
a packet in transmit as well as receive, so keying the part settles it
\- and nothing else can, short of a second radio.
.PP
.I tools/radio/txpin.py
does it at 915MHz, inside the unlicensed Part 15 band and inside the
W3312's 863-928 specification, at the part's own default power, for as
long as four pin reads take and no longer, with the carrier turned off
in a finally so an exception cannot leave a transmitter keyed:
.DS
.CW "  before      0x06 PKT_SYNC_RXTX    0% high   0x46 inverted 100%"
.CW "  keyed       0x06 PKT_SYNC_RXTX  100% high   0x46 inverted   0%"
.CW "  after       0x06 PKT_SYNC_RXTX    0% high   0x46 inverted 100%"
.DE
So the selection is that signal, the register drives the pin, the pin
is the one this board wires, and
.B gread
reads it.  Carrier sense correctly reads nothing while transmitting.
Every link from a register write to a number on the console is now
proven by a signal the part made on demand, which is what a positive
control is and what this work has been without from the beginning.
.PP
Which makes the receive-side zeros mean something at last.  A receiver
that never asserts that pin is failing to detect a sync word, and the
rung below it says why it never gets the chance: PQT_REACHED at zero
is a preamble detector that never fires.  On cellular that is correct
behaviour.  Whether it is correct on a channel carrying a real 2-FSK
preamble is the one thing still unmeasured, and 908.42 is where to
measure it \- with
.B gtrig
armed on carrier sense so the reading is taken while a burst is in the
air, and pointed at 0x0b rather than 0x06, because the preamble is the
first rung a working receiver would light.
.PP
WHY THE BOARD KEEPS NEEDING ITS BUTTON.  HALF THE HOST, HALF A KERNEL
LOOP WITH NO BOUND ON IT \- AND THE KERNEL HALF CAME FIRST.
.PP
.B gtrig
captured with
.CW "while(nrun < Ncaprun)"
and nothing else, so it ran until the pin had changed two hundred and
fifty-six times.  Pointed at a selection that does not assert \-
PQT_REACHED, which is exactly the one to watch when asking whether a
preamble is ever detected \- nrun stays at one and the loop never ends.
Interrupts stay on, so the console goes on echoing and the board looks
alive while the shell never comes back.  It is bounded by the same
window the caller already gave for the trigger now, and returns "no
burst in 3000ms" from the pin that used to hang it.
.PP
The rest of this section still holds and is the second half of the
mechanism rather than the whole of it.
.PP
It ends at
.CW "allocb: no memory 4788/40960" ,
hard enough that ^R^R cannot reach it and only the reset button can.
The block pool is not leaked by the driver: nothing in
.I devradio.c
allocates one, its ctl write goes straight to the driver and its reads
use malloc.  What fills it is the console queue, and what fills that is
this host.
.PP
Once the shell dies, nothing drains kbdq, and every character typed
after that allocates a block nobody will free.  So a tool that keeps
typing at a dead board converts a dead shell into a dead kernel, and
the difference between them is a walk across the room.
.PP
And a held-open cat cannot tell that the shell has died.  The echo
comes from the uart interrupt handler and keeps coming back long after
anything is running the commands; a marker cannot be used, because
inside a cat it would be written to the ctl file rather than run.  What
can be used is the command itself: probe, ghist, gread and gtrig always
print something, so an empty reply from one of those is a shell that is
gone.  Three in a row now stops the session and says so.
.PP
THE RECEIVE PATH WORKS.  IT RECEIVED PACKETS.
.PP
Everything that said otherwise in this file is superseded by three
numbers: recv 3, crcerr 3, on silicon, on 920MHz.
.PP
What was in the way was SYNC_THR, and specifically the direction of it.
Every test above set it to 0 and called that "maximally permissive",
which is the opposite of what the part does.  Swept on a channel where
the preamble detector reliably fires, PKT_SYNC_RXTX is static at 0, 2,
4, 8, 12, 16, 24, 26 and 28 and asserts at 30 \- three windows out of
three at 30 and one of three at 31.  So a higher number accepts more,
and every "permissive" negative in this work was taken at the strictest
setting there is.
.PP
Which is not a bug in the part and probably not one in the table.  The
driver's default is 11, and 11 rejecting noise is a sync detector doing
its job; 30 accepting it is the extreme.  What it cost was every
negative above, because a detector that correctly refuses noise looks
exactly like one that does not work when there is nothing else on the
channel to find.
.PP
The channel mattered as much as the number, and the control is what
found it.  Asking whether PQT_REACHED ever fires gave 24 windows in 33
on 908.42, which looked like preambles until it was asked of somewhere
quiet: 6 of 6 on 920MHz, which is in band and empty, and 0 of 6 on
944MHz, which is above the antenna's 928MHz edge.  So the firings are
noise arriving through an antenna that is working, and the quiet in-band
channel is a better bench than the busy one, because it produces a
preamble detection on demand and the cellular channel never could.
.PP
So the ladder is complete and every rung is demonstrated on silicon:
RSSI valid, carrier sense following the air, preamble detected, sync
word matched, packet into the FIFO, interrupt taken, counter moved.
Both ends of it were proven by something the bench could make happen
rather than by waiting \- the transmitter for the pin, and noise at
SYNC_THR 30 for the rest.
.PP
What remains is ordinary.  Receiving Z-Wave needs its sync word and its
rate at a threshold that rejects noise, and traffic to arrive while the
receiver is listening; none of that is blocked on anything now.
.PP
BYTES, AT LAST, AND WHAT THEY ARE NOT YET.
.PP
A packet counter cannot tell a frame from noise.  At every sync
threshold where this part's detector fires at all it fires on noise,
and equally on a channel carrying traffic and on an empty one \- three
windows in five on each, measured, which is the control refusing the
claim.  So "recv went up" is not evidence that anything transmitted,
and the discriminator has to be the bytes.
.PP
.B lastrx
keeps the front of the last packet and prints it in hex.  Its first cut
copied from
.CW "b->wp + Pkthdrlen" ,
which is past the end of the block by then, and printed the same
thirty-two bytes on every channel and every read: 0x0801b949 and
0x2001d1b8, a flash address and an SRAM one.  Uninitialised memory is
at least recognisable.  It copies from
.CW "b->wp - n"
now.
.PP
With that fixed, and the same settings on both channels: 920MHz gave
"none" four times over two minutes, and 908.42 gave
.DS
.CW "  96 aa 95 53 2a 95 55 53 12 aa 6b 4a a2 92 aa d0 54 64 ea a5 ..."
.DE
which is not random.  It is saturated with aa, 55, 95, 53, 2a, 56 and
52, every one of them an alternating-bit pattern, and noise is
uniformly distributed.  That is a 2-FSK transmission with a preamble,
sampled at a rate offset from its own \- which fits, because Z-Wave R1
is Manchester coded and puts 19.2kBaud on the air for 9.6kbit/s of
data, and this was clocking at 9600.
.PP
It is one packet, and that is all it is.  Later captures at 9600 and
19200 look random, the two rates returned identical bytes because
nothing new had arrived, and the control's silence was a single window
rather than a rate.  What is needed to make it a finding is a packet
count on both channels over equal time, and after that the content of
enough frames to see whether a home ID repeats.  Neither is blocked.
.PP
AND THE PACKET RATE SAYS NO.
.PP
.I tools/radio/pktrate.py
alternates between a target and a control, equal dwell, same minutes,
and counts.  Alternating rather than doing one and then the other is
the point: on a bench where the air changes, an hour of one followed by
an hour of the other compares two times as much as two frequencies.
.PP
Sixteen windows of forty-five seconds, twelve minutes in all, with the
registers read back off the part afterwards to show the configuration
held \- SYNC_CFG1 0x5e, SYNC1 and SYNC0 both 0xaa, CRC off, variable
length, PQT on:
.DS
.CW "  908.420MHz (target):   0 packets"
.CW "  920.000MHz (control):  1 packet"
.DE
The target took nothing and the control took one.  So the patterned
packet above does not reproduce, no Z-Wave reception is claimed, and
the tool says so itself rather than leaving it to be judged: the
counter is measuring the receiver and not the air.
.PP
That is the right place for this to stop rather than a disappointment.
Everything the bench needed to reach an honest answer now exists and is
demonstrated: a receive path proven end to end on silicon, a
transmitter that proves the pin, noise at a known threshold that proves
the sync detector, a ladder that says which rung a signal reaches, the
bytes of whatever arrives, and a rate comparison that refuses a claim
the counter cannot support.  What is missing is a transmitter on a
protocol this part can demodulate, close enough and often enough to
catch \- and the one in the house is a Z-Wave device somebody can
operate on purpose.
.PP
AND THE OTHER INSTRUMENT AGREES THE CHANNEL IS EMPTY.
.PP
The receiver took no packets on 908.42 in twelve minutes, which is only
worth anything if something was transmitting.  A tinySA sweep of the
same channel in the same minutes, 3kHz bins, fourteen passes:
.DS
.CW "  907.8-909.0MHz    908.5697  -102.4dBm  seen 1/14"
.CW "  919.4-920.6MHz    919.8249   -94.9dBm  seen 1/14"
.CW "                    920.3007  -101.4dBm  seen 1/14"
.CW "                    920.2633  -103.4dBm  seen 1/14"
.DE
against a \-111.9 floor on both.  The one hit near the Z-Wave channel
is 150kHz off it, three kilohertz wide and one sweep in fourteen; the
control band has more in it than the target does.
.PP
So nothing is transmitting on 908.42, the receiver's zero is correct
reporting rather than deafness, and the two instruments agree.  That is
the measurement this work has wanted from the beginning and could not
make: an independent witness that the channel is empty, so a negative
means the air and not the bench.
.PP
Worth noting against the antenna section above: over 1.2MHz with 3kHz
bins the tinySA's floor is \-111.9, which is where this receiver's
sits.  The thirty dB deficit measured at 930.8 was on a real signal and
stands, but the two instruments are not far apart on noise, and any
future comparison should say which of those it is measuring.
.PP
THE ONE EXPERIMENT THAT NEEDS NOBODY ELSE.
.PP
Everything above waits on somebody else's transmitter.  This does not:
a transmitter on the bench, an analyser on the bench, and a number the
driver computes that has only ever been checked by reading the register
back.  2-FSK puts two tones on the air 2*dev apart, so keying a carrier
and sweeping it while the deviation changes checks the arithmetic
against the air rather than against itself.
.PP
.CW "txpin.py spectrum"
does it, inside the same 902-928 guard and the same carrier-off-in-a-
finally as the pin test.  It works: at 915MHz the tinySA sees the
carrier at \-42.8dBm against a \-112 floor, seventy dB of it, so there
is no doubt the part transmits or that the antenna radiates.
.PP
The deviation register is right too, and the way it first looked wrong
is worth keeping.  Reading DEVIATION_M alone shows 0x47 at every
setting, which reads as a verb that does nothing; the mantissa lives
there and the exponent in MODCFG_DEV_E, and the two together give 4989,
9979, 19958, 39916 and 79833Hz for 5, 10, 20, 40 and 80kHz asked \-
every one inside 0.3 per cent.  A register read that only covers half a
field is worse than none.
.PP
What is not finished is the tone separation itself.  The first cut
measured occupied bandwidth above the floor and gave 156, 0, 389, 480
and 353kHz for a monotonic sweep of deviation, which is not a
measurement of anything; the second looks for two peaks 2*dev apart,
which is the right shape, and the board wedged before it produced a
figure.  The tool is there and the hard part \- a transmitter that is
certainly transmitting \- is proven.
.PP
A TRANSMITTER ON THE BENCH THAT SOMEBODY CAN SWITCH ON.
.PP
The tinySA's generator reaches 915MHz and this receiver hears it.  With
the antenna moved to the generator connector, "mode output", a zero-span
sweep at the frequency wanted and "output on":
.DS
.CW "  generator off   floor -111  peak -106"
.CW "  generator on    floor  -93  peak  -92"
.CW "  generator off   floor -111  peak -106"
.CW "  generator on    floor  -93  peak  -92"
.DE
Eighteen dB, twice, on command.  That is the positive control this work
has been without from its first measurement: every negative in it was
taken while nothing was known to be transmitting, and a receiver that
hears nothing when nothing is sent cannot be told from a deaf one.
.PP
Two traps in getting there, both worth keeping.  "mode low output" is
the low-band generator and clamps \- asked for 915MHz it sat at 10, which
the screen showed and the serial port did not.  And bare "mode", "freq",
"level" and "output" print their usage rather than their state, so
nothing can be read back; the sweep setting is the generator's
frequency and
.CW frequencies
does report it.
.PP
What this unlocks is the whole ladder over the air rather than on noise.
.CW "txpin.py link"
sets the generator to FM at \(+-6kHz with a modulating tone, which to a
2-FSK demodulator is a preamble at a known rate, and watches PQT,
PKT_SYNC_RXTX and carrier sense with it on and with it off.  That has
not produced a positive yet \- the first run predates knowing about
"mode output" \- and it is now the obvious next thing to run.
.PP
And the board grew a lamp.  A clicker 2 has LD1 on PE12 and LD2 on
PE15; LD2 is the scheduler's heartbeat from idlehands() and LD1 has
said only "the kernel started" since boot.  Spidev gained a
.CW led
member beside
.CW gpio
and
.CW irq ,
the stm32f407 wires it to LD1, and cc1120.c flips it on every packet
received.  A flip rather than a flash, because nothing here has a timer
to put a lamp out again: under traffic it flickers, and after a quiet
spell it sits where the last packet left it, so "has anything arrived
since I last looked" has an answer on the board itself.
.CW "led on|off|blink"
is there to prove it is wired before anything it says is believed.
.PP
THE WHOLE CHAIN, OVER THE AIR, AGAINST A SIGNAL SOMEBODY SWITCHED ON.
.PP
The tinySA's generator FMs a carrier by \(+-6kHz at a tone of one's
choosing, and to a 2-FSK demodulator that is a preamble: an alternating
symbol at a known rate.  Put on 915MHz at \-6dBm, with the receiver
tuned to it and hunting for 0xaaaa:
.DS
.CW "  tone 4800 rate 9600  ON    PQT   0%  SYNC  0%  CS 100%"
.CW "  tone 4800 rate 9600  off   PQT   0%  SYNC  0%  CS   0%"
.CW "  tone 2400 rate 4800  ON    PQT  81%  SYNC  7%  CS  85%"
.CW "  tone 2400 rate 4800  off   PQT   0%  SYNC  0%  CS   0%"
.CW "  tone 1200 rate 2400  ON    PQT  96%  SYNC  2%  CS  98%"
.CW "  tone 1200 rate 2400  off   PQT   0%  SYNC  0%  CS   0%"
.DE
Every off round is zero on every rung.  Every on round at a matched
rate lights the preamble detector, and the sync detector fires with it.
.PP
So the receive path is proven over the air and not on noise: a
transmission somebody switched on, a preamble found in it, and a sync
word matched in it, with the control being the same measurement a
second later with the transmitter off.  That is what every negative in
this file lacked.
.PP
The rate matters and the way it matters is worth keeping.  A 4800Hz
tone against 9600 baud gives nothing but carrier sense; halve both and
the preamble detector goes to 81 per cent, halve again and it goes to
96.  The generator's FM is a tone rather than a square, so its
instantaneous frequency sweeps rather than switching, and the slicer
follows it better the more symbol time it is given.  Which also says
what the modulation index does here: 2*6000 over 2400 is five, and five
works where 1.25 did not.
.PP
And the generator is doing what it claims.  Profiled with this very
receiver at an 8kHz filter, an unmodulated carrier occupies six 2kHz
bins and the same carrier under FM occupies twelve, peak five dB lower
for the same power spread wider.  Twenty-two kilohertz measured against
Carson's 2(6 + 4.8) = 21.6.  The part is a usable narrowband analyser
as well as a receiver.
.PP
AND WITH THE CALIBRATED RECEIVER POINTED AT THE BAND, NOTHING.
.PP
A max-hold of 902 to 928 put 927.200MHz seventeen dB over the median,
which is the shape of a find, and the probe found bursts there: two to
six milliseconds, one or two in a two-second window, peaking four to
eight dB over the floor.  The ladder read RSSI valid throughout and
carrier sense, preamble and sync all dark.
.PP
The control settles it.  The same measurement on 925.600, 1.6MHz away
and chosen for being unremarkable, gives seven bursts over three
windows against the target's seven, and nine dB over the floor against
the target's eight.  927.200 is not distinguishable from a quiet
channel, so its bursts are the threshold crossing noise \- which is what
this driver's own NOISE rule says of that shape \- and the max-hold's
\-87 was a rare excursion caught by fourteen passes rather than a
transmitter.
.PP
That is a negative worth having now, which it would not have been
yesterday.  The instrument that produced it has been shown, on the same
afternoon, to detect a preamble and match a sync word on a signal
somebody switched on: so "nothing there" is a statement about the band
and not about the bench.  What the band wants next is the tinySA's
antenna, which sees ten to twenty dB more than the click's.
.PP
A FREQUENCY HOPPER, WHICH IS AN IDENTIFICATION OF A KIND.
.PP
With the tinySA's antenna back on its receive connector, three
consecutive sweeps of 902 to 928MHz, twelve passes each:
.DS
.CW "  pass 1   904.2004  -76.7dBm  174kHz wide  seen 1/12"
.CW "  pass 2   903.0423  -80.2dBm  347kHz wide  seen 1/12"
.CW "  pass 3   925.7416  -77.1dBm  231kHz wide  seen 1/12"
.DE
and an earlier one at 915.1448, \-41.9dBm, 231kHz, also one sweep in
eighteen.  Always one strong wide burst, always caught in exactly one
sweep, always somewhere else.  That is frequency hopping across the
whole band, which is what the US ISM allocation is mostly full of \-
telemetry, meters, alarms, cordless things \- and it is the first
positive identification of a signal class this work has made.
.PP
Checked against ourselves first, because \-41.9dBm at 915MHz is what
this bench's own transmitter measured earlier and a spectrum run had
wedged the board partway through: MARCSTATE read 0x6d, which is RX,
before and after.  Not us.
.PP
Zooming in does not find it.  Twenty passes of 914.6 to 915.8 at 3kHz
bins gave one marginal hit at \-95.3, which is what a hopper looks like
from a narrow window: it was caught in the wide sweep because the sweep
happened to be in that bin when it landed there, and a window a
fiftieth as wide almost never is.
.PP
Nor can this receiver catch it.  A hop the tinySA sees at \-77 arrives
here ten to twenty dB down, so carrier sense at a threshold of \-95
never asserted in five seconds on the target or on the control.  The
click's antenna is the limit, as it has been all along.
.PP
And a later sweep of thirty passes found nothing at all but 928.0000 at
\-84, one sweep in thirty \- which is 29 times 32MHz, this board's own
crystal, reaching the other instrument.  So the hopper is intermittent
over minutes as well as over frequency, and the band is empty between
whatever it is doing.
.PP
RAISING THE ANTENNA, AND THIS RECEIVER FINALLY HEARING THE BAND.
.PP
With the click's antenna lifted, a max-hold of 902 to 928 no longer
finds only 927.2 and its own crystal.  It finds landings scattered
across the band \- 912.0 at \-93 and 925.6 at \-94, which are within a
megahertz of where the tinySA saw the hopper in the same minutes, and a
dozen more from six to nine dB over the median.
.PP
And the control holds up, which is what makes it worth writing down.
The same sweep above the antenna's range against the same sweep inside
it:
.DS
.CW "  934-952 above the band   28 ch, median -111,  0 over median+6"
.CW "  902-920 in band          28 ch, median -108,  7 over median+6, best +13"
.DE
Nothing out of band, seven of twenty-eight in it.  So the structure is
the air and not the receiver, and this part is now hearing the ISM band
it could not hear an hour ago for want of an antenna a foot higher.
.PP
A tool bug fell out of it, and it had been quietly halving every sweep.
.I bandhold.py
reads the reply ctl() slices at its marker, which is right for a verb
printing a line or two and wrong for one printing sixty-three: the
window scrolls, the marker leaves the top of it, the slice comes back
empty and that chunk is lost without any sign of failure.  A 131-channel
sweep reported five channels \- the last chunk only \- twice, and read
as a quiet band.  It scans the whole window now and filters by the
range it asked for, so an earlier chunk cannot be counted twice.
.PP
CABLED, AND WHAT TWO INSTRUMENTS CAN AND CANNOT SAY ABOUT EACH OTHER.
.PP
With the generator cabled straight into the click, the path is proved
by a matrix rather than by a level.  Generator on each of three
frequencies, receiver tuned to each of the three:
.DS
.CW "              rx@905   rx@915   rx@925"
.CW "  gen@905        -76     -120      -91"
.CW "  gen@915       -120      -76      -90"
.CW "  gen@925       -120     -119      -77"
.CW "  gen OFF       -119     -119      -90"
.DE
A diagonal of \-76, \-76, \-77 against a floor of \-119 everywhere else.
Signal appears only where the receiver is tuned to the generator, which
no amount of broadband leakage can imitate.
.PP
The level scale: stepped \-52 to \-76dBm in fours the receiver reads
\-68, \-72, \-76, \-79, \-83, \-89, \-89, a least-squares slope of 0.93.
Above about \-50 it saturates flat at \-65 to \-68 however hard it is
driven.  With the generator off and the cable on it reads \-119, eight
dB below what the antenna gives it.
.PP
The frequency scale, measured from the filter's own edges rather than
from a peak, because the top is flat: half-power points either side,
interpolated, midpoint taken.
.DS
.CW "  gen 915MHz   centre error -2917Hz (-3.19ppm)  width 25.8kHz"
.CW "  gen 915MHz   centre error -2917Hz (-3.19ppm)  width 25.8kHz"
.CW "  gen 910MHz   centre error -2917Hz (-3.21ppm)  width 25.8kHz"
.DE
The 25.8kHz measured against the 25.0 asked is what says the method is
sound; a number that arrives with its own check is worth more than a
number.
.PP
AND NEITHER OF THOSE SAYS WHICH INSTRUMENT IS WRONG.  Two instruments
compared against each other give their difference and nothing else.
The 2.9kHz is the disagreement between a CC1120's 32MHz crystal and a
tinySA's reference; the 0.93 slope is the disagreement between the
part's RSSI and the instrument's attenuator; and no arrangement of the
two can attribute either.  Nor can the constant \-2917Hz at both 910
and 915 be read as a fixed offset rather than a ppm error: 3.2ppm would
differ by 16Hz between those two, and this measurement resolves about a
kilohertz.
.PP
What would attribute it is a third reference that is traceable, and
there is one on this bench already.  A cellular downlink carrier is
frequency-locked to about 50 parts per billion, which is a hundred
times better than either instrument here, and 869 to 894MHz is full of
them and reachable by both.  Measuring one with each says which of the
two is off and by how much, which is the only way this question has an
answer.
.PP
ONE ABSOLUTE FREQUENCY, MEASURED AGAINST NIST BY EAR.
.PP
The two instruments disagree by 2917Hz at 915MHz, which is 3.19ppm, and
no comparison between them can say which is wrong.  A third reference
was wanted and three were tried.
.PP
Cellular fails on this bench.  A GSM BCCH would serve \- continuous, on
a 200kHz raster, base stations held to 50 parts per billion \- but
averaged over six sweeps 869 to 894MHz is flat at \-86 to \-88.5dBm, two
dB across twenty-five megahertz.  Weak wideband LTE and bursts caught
one sweep in twenty, and a frequency cannot be measured from a burst.
.PP
WWV fails for a better reason.  With a real HF antenna on it the tinySA
hears the band \- 207 bins more than 15dB over the floor across 0.5 to
30MHz, and the CB channels at \-32dBm \- but at 10MHz, with the
resolution bandwidth narrowed to 100 and then 30Hz, there is no carrier
at all: a broad two-kilohertz hump of equal bins at \-70.5 against a
\-91 floor.  An FT-891 hears WWV there easily.  That is not a
calibration difference, it is thirty to forty dB of sensitivity between
a spectrum analyser and a communications receiver, and it is why the
analyser is the wrong instrument for a weak standard.
.PP
Worth keeping from the attempt: the earlier readings were taken at a
3kHz resolution bandwidth, which smears a carrier into its sidebands
and made a \+902Hz feature look like a 90ppm error.  A sweep's point
spacing is not its resolution.
.PP
And the CB grid gives a bound rather than an answer.  The strongest
carrier sits 56Hz from its 10kHz raster point, 2.1ppm, so the tinySA's
HF reference is good to a few parts per million and is certainly not 90
\- but CB transmitters are held only to 50ppm by rule, so the reference
is looser than the question.
.PP
The FT-891 settles its own case, by ear and without any of this.  Tuned
in CW and zero-beaten against WWV on 10MHz it reads 10.000010: ten
hertz high, 1.0ppm, traceable, because NIST's contribution is a
millionth of it.  That is the first absolute frequency this bench has
measured, and it is smaller than the 3.19ppm the other two disagree by
\- so that disagreement is real rather than something both instruments'
specifications allow.
.PP
What it does not do is attribute it.  The FT-891 stops at 56MHz and
cannot hear 915, so the calibration has to be carried across: zero-beat
a strong CB carrier with the FT-891 to learn its true frequency to a
part per million, compare that with the tinySA's 27.1199MHz reading to
get the tinySA's error at HF, and only then does the 2917Hz at 915
divide between the two.  The step that is still assumed is that the
tinySA's error is the same on both of its synthesis paths.
.PP
BOTH OF THEM, IN OPPOSITE DIRECTIONS, WHICH IS WHY COMPARING THEM COULD
NOT WORK.
.PP
The chain closes, and every link is a measurement rather than a
datasheet.
.IP \(bu
NIST transmits WWV on 10.000000MHz, held to about one part in ten to
the twelfth.
.IP \(bu
The FT-891 zero-beats it in CW at a displayed 10.000010, so its display
reads ten hertz high: \+1.00ppm.
.IP \(bu
The tinySA generates a nominal 10.100000 and the FT-891 zero-beats that
at 10.100030.  Taking the radio's own \+10.1Hz out, the true output is
10.1000199, so the tinySA generates \+19.9Hz high: \+1.97ppm.
.IP \(bu
At 915MHz the tinySA's nominal 915.000000 is therefore really
915.001803, and this receiver measured that carrier's centre at
914.997083 by its filter's half-power edges.  So the CC1120 reads 4.72
kilohertz low: \-5.16ppm.
.PP
A 32MHz crystal on a click board at 5ppm and an uncalibrated instrument
at 2ppm are both ordinary; what was not ordinary was the belief that
one of them had to be right.  The 2917Hz they disagreed by at 915 was
the sum of two errors of opposite sign, and no arrangement of the two
could ever have divided it.
.PP
The tinySA's frequency correction has never been set \-
.CW freq_corr
reads 0 ppb, factory default \- so \-1970ppb is what it wants, and the
915MHz measurements inherit it because generator and receiver share one
crystal.
.PP
Two assumptions are still in this and should be said.  That the
tinySA's error is the same at 10MHz and at 915MHz, which holds only
because both use its low path \- "mode output" and "mode low output"
turned out to be the same command on this firmware.  And that the
FT-891's 1ppm at 10MHz carries to 10.1MHz, which is a tenth of a hertz
of extrapolation and safe.
.PP
The correction is applied and verified.
.CW "freq_corr -1970"
went in, the same zero beat was taken again, and it now reads
10.100010 \- which is the FT-891's own \+1ppm and nothing else.  The
sign was not guessed: the generator was left running so the
measurement could be repeated, and a wrong sign would have moved it to
10.100050.
.PP
The direct confirmation of the CC1120 against the corrected generator
does NOT reproduce, and that is recorded rather than hidden.  Three
attempts give centre errors of \+41 and \+24.7ppm with filter widths of
5.5 and 5.8kHz, where the filter is 25kHz and the earlier clean runs
measured 25.8.  The profiles are strong readings scattered across
frequencies that should be at the floor, with no flat top anywhere \-
not a filter response at all, so the bracket has nothing to bracket.
.PP
The likeliest cause is the source.  915MHz is on this instrument's low
output path, which is specified to a few hundred megahertz, so what
arrives may be a harmonic or an alias carrying spurs rather than a
clean carrier.  Which puts a caveat on the earlier 915MHz work too: it
was clean and thrice reproduced, but it used the same out-of-band
source, and a source that can scatter spurs today could have done so
then.
.PP
Cabled again and in the receiver's linear region, the profile comes
back clean and the source convicts itself.  Half-power edges at \-15.6
and \+10.7kHz give a width of 26.3kHz against the 25.0 asked, and a
centre of \-2437Hz.  But at \+40 and \+45kHz sit two products at
\-61dBm \- sixteen dB STRONGER than the wanted carrier at \-77.  A
generator whose spurs beat its signal by sixteen dB is not a frequency
reference.
.PP
And it does not track its own correction.  freq_corr moved the 10.1MHz
output by 20Hz, which is 1.97ppm and was confirmed by ear.  The same
correction should move a 915MHz output by 1.8kHz; the measured centre
moved from \-2917 to \-2437, which is 480Hz.  A 10MHz output that obeys
the reference and a 915MHz output that does not is what a harmonic or
an alias looks like, and it is the second independent sign that this
path is not producing 915MHz the way it produces 10.
.PP
So the \-5.16ppm for the CC1120 is withdrawn to a range.  Against the
uncorrected source it computed to \-5.16; against the corrected one the
same measurement gives \-2.66; the two cannot both be right and the
source is the reason.  What the CC1120's crystal actually is, this
bench cannot say closer than "a few parts per million low", and closing
it needs a source at 915MHz that is in specification \- which is a
purchase, not a measurement.
.PP
FIXED, AND THE FIX MEASURED.
.PP
The source was the first thing wrong and the instrument's own command
set had the answer.
.CW output
takes
.CW on|off|normal|mixer ,
and at 915MHz those are not alike:
.CW normal
gives a clean carrier with the floor either side,
.CW mixer
puts a spur 15dB over it at \+30kHz, and whatever the default was is
worse than both.  Driven at
.CW "output normal"
the profile has a flat top and a floor, which is what a filter response
is supposed to look like.
.PP
The analysis was the second.  A spur cannot be a filter top \- one or
two bins is a spike, a 25kHz filter occupies many \- so
.I tools/radio/centre.py
median filters over five points before bracketing, which leaves a
plateau standing and removes anything narrower than the answer.  Before
that, the strongest bin was taken as the peak and a 25kHz filter came
out 4.6kHz wide and 24ppm off.
.PP
With both fixed the measurement is reproducible and self-checking:
\-3250Hz at 915MHz, \-3250 at 910, width 25.5kHz against the 25.0
asked, three runs identical.  That is \-3.55ppm and it is this board's
crystal.
.PP
And it is corrected.  cc1120.c computes FREQ from a nominal 32MHz, so a
crystal a few parts per million out tunes the part the same amount out
and reads its own error back as the air's.  A
.CW ppm
ctl verb moves the divisor; the default is zero, because every crystal
differs and a number copied from this board would be a guess wearing a
measurement's clothes.  For this one it is
.CW "ppm -3550" ,
and with it set the same measurement gives \+233Hz, \+0.26ppm, inside
what a 4kHz grid can resolve.  Fourteen times better.
.PP
The sign was wrong first and that was worth having.  Applied backwards
it took \-3250 to \-6200 rather than towards zero, which is what an
inverted sign always looks like and is the cheapest test there is.  It
also says something physical: the carrier appears BELOW the frequency
commanded, so the part tunes above what it is told, so this crystal
runs fast.
.PP
And it survives a reset.  The correction is a property of the crystal
soldered to this click, not of the driver, so it is declared where the
board's other specifics are declared \- beside
.CW gpio ,
.CW irq
and
.CW led
on Spidev \- and the driver takes it when it allocates.  Taken
explicitly and not left to the allocator: that struct is malloc'd and
its fields are set by hand, so a correction relying on malloc having
zeroed would be a correction of whatever was in that memory.  Zero
stays the default and boards that have measured theirs say so.
.CW ppm
reads \-3550 ppb at boot now with nobody typing it.
.PP
Which retires something worth noticing about everything above: every
hunt in this file before today was made with this receiver tuned 3.25
kilohertz off where it said it was.
.PP
AND THE FIRST BIN OF EVERY SWEEP WAS A PHANTOM.
.PP
With the antenna back on, two sweeps put a strong carrier at 906.000MHz
\- \-78 and \-77dBm, thirty dB over the median, in both.  That is what a
real transmitter looks like.  It was the first bin of both sweeps.
.PP
Swept from 902 instead, so that 906.000 falls in the middle, it reads
\-94: nothing.  And 902.000, now the first bin, reads thirteen dB over
the median in its place.  The elevation belongs to the position, not
the frequency.
.PP
.B hold
called setfreq and sampled immediately.  setfreq strobes a VCO
calibration and the AGC restarts from wherever the last frequency left
it, and RSSI_VALID comes up before either has finished \- and the first
step of every pass follows the largest jump there is, from the top of
the previous pass back to the bottom.  Two milliseconds and the first
reading discarded fixes it: 906.000 and 902.000 both drop out of their
sweeps' results entirely, and what remains \- 906.8, 912.0, 904.6 \-
moves between sweeps, which is the hopper.
.PP
Every band sweep in this file was taken with that phantom in it.
.PP
What made all of it possible was an ear.  Every instrument here reads
back its own opinion; only a zero beat against NIST reads back the
truth, and no part of this bench could do that except a radio and a
person listening to it.
.PP
WHAT IS ACTUALLY ON THIS BAND, WITH THE CONTROLS TO SAY SO.
.PP
Thirty sweeps of 902 to 928MHz with the calibrated instrument:
.DS
.CW "     at MHz    width    peak    mean    p-m   seen"
.CW "   909.4699     231k   -71.0   -92.2   21.1   1/30"
.CW "   919.1982     174k   -78.0   -93.0   15.1   1/30"
.CW "   915.7238     405k   -78.0   -92.7   14.7   1/30"
.CW "   905.0690     116k   -81.0   -93.4   12.3   1/30"
.CW "   903.2160     174k   -82.0   -92.1   10.1   1/30"
.DE
Every one wide, strong, twenty dB over its own mean, and seen in
exactly one sweep of thirty.  A continuous carrier would be thirty of
thirty with its peak at its mean.  That is one frequency hopper and
nothing else in the band clears the floor.
.PP
Zero span on 909.470 for 150 seconds, which listens for 2.8 of them,
catches two bursts: 3267us at \-61.5dBm and 1933us at \-66.0, against a
\-93 floor.  Dwelling sees them ten dB stronger than sweeping past
does, so the thing is close.  The same measurement on 924.000, which
the survey puts at the floor, catches nothing in a comparable 2.2
seconds.
.PP
So: a frequency-hopping device, dwell of two to three and a bit
milliseconds, roughly 100 to 200kHz occupied per hop, spread over at
least 903 to 919MHz, strong enough to be in this building, and any one
channel busy about two parts in a thousand.  A dwell of 2.6ms sits well
inside what 15.247 allows, and says it is a fast hopper rather than a
metering system parked for tens of milliseconds a channel.
.PP
What it is NOT is measurable by this receiver.  Camped on 909.470 with
carrier sense at \-98, the CC1120 gave four crossings in twenty seconds
against the control's one, and then zero on a repeat \- and the lengths
it reported, 177 and 354us, are the histogram's own powers of two
rather than a dwell.  A \-71dBm hop arriving ten to twenty dB down
through the click's antenna, lasting two milliseconds, is past what
that antenna can deliver.  The analyser measured it because it hears
better, not because it is cleverer.
.PP
THE OTHER THREE BANDS THIS PART CAN REACH.
.PP
A CC1120 covers 164-192, 274-320, 410-480 and 820-960MHz, and only the
last had ever been looked at here.  Twenty sweeps each of the other
two, with the antenna that can reach them:
.DS
.CW "  305-325MHz   312.3051  401k  -76.4  3/20"
.CW "               311.3697  178k  -76.9  2/20"
.CW "               313.5969  134k  -77.3  1/20"
.CW "  425-445MHz   440.1002   44k  -63.6  1/20"
.CW "               440.6347   44k  -63.6  1/20"
.CW "               431.7706  223k  -80.0  3/20"
.DE
440.1002 and 440.6347 are the strongest signals this bench has found
anywhere \- thirty dB over their own mean and only 44kHz wide, which is
narrowband and is the 70cm repeater sub-band.  The cluster around 312
is wide and unidentified.
.PP
This receiver tunes to 440 and its floor there is \-118, as good as at
915, so the band is reachable; it heard nothing in a two-second probe,
which is what a signal present in one sweep of twenty does to a
two-second probe.  A hundred and forty seconds of zero span caught none
either.
.PP
And the decodability is the point rather than the level.  An amateur
repeater carrying analog FM voice cannot be demodulated by this part at
all \- it slices FSK, it does not detect FM audio.  A repeater carrying
DMR could be: DMR is 4-level FSK at 4800 baud in 12.5kHz and this part
does 4-FSK.  Which of the two these are is exactly what could not be
established, because telling them apart wants the TDMA structure and
that wants catching one.
.PP
So the survey is finished and the answer to "is there anything else
worth caring about" is: one hopper that cannot be followed without its
sequence, one unidentified cluster at 312, and two strong narrowband
signals at 440 that are either undecodable by construction or
decodable and unconfirmed.  None of them is a transmitter that will
send this receiver a packet.
.PP
None of that is an identification, and an attempt at one ran into
something better worth having.
.PP
The modem registers are settable now and their formulas are checked
rather than copied.  Deviation is
.I "(256 + DEV_M) 2^DEV_E fxosc / 2^24" ,
which for what TI's table leaves says 3998Hz \- so a 2-FSK carrier
should show two tones 7996Hz apart, and on the tinySA, with the board
sending random data at 915MHz, they are 8.20kHz apart.  Receive
bandwidth is
.I "fxosc / (decfact DEC_M 8)" ,
which for the table's 0x08 gives 25kHz, the figure TI publishes for
this configuration.  Both read back off the part, beside the symbol
rate, so nothing here reports what it meant to set.
.PP
Then the test: 802.15.4g mode 1 at 908.6MHz \- 50000 symbols a
second, 12.5kHz deviation, 100kHz bandwidth, sync word 0x904E, which
is that PHY's start-of-frame delimiter \- chosen because the occupied
clusters in 902-928 sit near the 902.2 + 0.4n grid that plan uses and
because a CC1120 is a part built for it.  Nothing.  No packets, no CRC
errors, and the packet sync pin never once asserted in six seconds.
.PP
That result is not usable, because the positive control fails.  Making
the sync threshold as permissive as the part allows does not produce a
single assertion either, so there is no demonstration that this
receiver can detect a sync word from anything at all \- and a
negative from an instrument that has never been shown to give a
positive says nothing about the air.
.PP
What it did find is why.  SYNC_CFG1's top three bits are SYNC_MODE and
TI's table leaves them zero, which means no sync word: the packet
engine was never told what a packet starts with.  This driver has
never received a packet on silicon and could not have, and everything
else \- the interrupt, the queue, the counters, the two files \- was
in place and waiting.  It is set to 16 bits at init now.
.PP
A positive control does not have to be hardware, and half of one was
free.  Two qemu instances, each with a modelled CC1120, joined by a
socket:
.PP
.EX
	; cat /dev/radio0/data
	radio-carried-this
.EE
.PP
\- the first packet this device has ever carried, out of
.CW /dev/radio0/data
on a machine that did not send it.  It is
.CW tools/radio/twoboards.sh
and it passes.
.PP
What that settles and what it does not.  It exercises the transmit
FIFO and strobe, and on the far side the interrupt, NUM_RXBYTES, the
FIFO read, the header this device prepends, the queue and the
counters: the whole of #W's packet path.  It does not exercise sync
word detection or anything else in the radio, because the model hands
whole packets across a netdev and never reads SYNC_CFG1.
.PP
So the silence on the air is now known not to be the interrupt, the
FIFO, the queue or the counters.  It is the RF half \- the sync word,
the deviation, the bandwidth, the rate, or there being nothing there
\- and telling those apart still wants a transmitter under this
bench's control that is on the air rather than on a socket.  A second
ccRF click is the cheapest.
.PP
A RETRACTION, and the method that earned it.  It was written here and
in a commit that a 64-bit division in a ctl verb that never ran
stopped this kernel booting \- "after the conf line, before the first
process, with the tail of that line still in the console queue" \-
and that it was reproduced three resets each way.  It is not true.
Put back, the same arithmetic boots on the part and under qemu and
runs commands at the prompt.
.PP
What was really being read was a screen captured while the conf line
was still printing.  The console is watched through screen(1)'s
hardcopy, which writes out whatever is in the window at that instant,
and a boot caught mid-line looks exactly like a boot that stopped
mid-line.  The same mistake happened again later and was caught that
time only because the next command's error message gave the machine
away as alive.  Two false diagnoses of a dead board from the same
method, and the correction is cheap: ask the machine to do something
and see whether it answers, rather than looking at what it last
printed.
.PP
The same afternoon produced a real version of that fault and it is
worth keeping separate.  This board's console drops characters from a
line typed faster than it echoes, which tools/f407/console.py has
known about for the real serial port since it cost a boot there.  It
applies to qemu too, where the host writes a whole line into the pipe
at once: a 59-character command came back as
.CW /dev/radioecho ,
the tail of one line run into the next, and the shell hung on it.
Every long command sent to either machine has been at risk of that,
and the fix is the one console.py already uses \- hold the ctl file
open with cat and type short lines into it.
.PP
One more thing that check is worth keeping for.  Run first with
mcast=, the two instances came up, the sender reported "sent 1", the
receiver reported "recv 0" and its receive FIFO was empty.  That reads
exactly like a driver that cannot receive, and it was two qemu
instances that had never been connected to each other.  The same shape
as everything else in this document: an instrument that was not
measuring what it appeared to be measuring.  A duty cycle and a burst length
are consistent with far too much, and the one thing that would settle
it has not been tried: configure the packet engine for a candidate --
rate, deviation, receive bandwidth, sync word, CRC -- and count the
packets that pass CRC.  A CRC-valid packet is proof and nothing short
of it is.  Of those, only the symbol rate is settable from the ctl
file today; the rest are still whatever TI's table left.
.PP
Trying to measure the occupied bandwidth with the narrow receiver
instead did not work: a scan across 908.0 to 909.6 at 100kHz steps and
60ms a step came back flat at \-109 to \-114dBm, because the signal
is not there most of the time and a single dwell per step catches the
quiet.  It wants a max hold over many passes, which is what
survey.py does on the instrument and what the board does not do yet.
.PP
What that period means is not established.  It is the receiver's
recovered symbol rate as much as the transmitter's, and this driver
has never set the data rate registers, so it is running on whatever
TI's table and the part's reset values leave.
.IP "4.  An FT-891, or anything with a CAT port.  Done, for receive." 6
This is no longer a compiled argument.  The set is driven from emu
over its own USB port \- a CP2105's Enhanced Com Port, 4800 8N2 \-
through
.CW #W/radio0/ctl ,
and
.CW #W/radio0/stats
reads the frequency, mode, transmit state, S meter and power back out
of the radio rather than out of the driver.  14.074MHz in DATA-U, set
from a shell and confirmed by the set's own display and its own CAT
replies.  What has not been done is keying it: nothing here has put
that radio on the air, so
.CW ptt
and
.CW power
are still only what the manual says.
.PP
It cost an afternoon to a thing that is worth stating once more here
because it is invisible from every layer above: the FT-891's menu
05-08 CAT RTS is ENABLE from the factory, and the set then refuses to
send replies while the PC asserts RTS.  Commands work throughout \-
the VFO follows every one of them \- so the symptom is a radio that
obeys and never speaks, which reads as a broken host driver.  It is
not.
.PP
What this settles is the question the file was written to ask.  #W
needed exactly one change to carry a radio that is not a CC1120: a
driver declaring no payload serves no
.CW data
and no
.CW pkt .
Nothing else in the device, and nothing in
.I lora (3),
.I ax25 (3)
or
.I kiss (3),
knew the difference.
.IP "5.  The one redirection.  Done." 6
This board spawned one process for a shell redirection in a boot and
wedged on the second, which is why every experiment above cost a reset
and why there is a host tool to type at the console.
.PP
The diagnosis written here before was wrong, and worth recording as
wrong: it said smalloc()'s unbounded retry over a pool that could not
give a 4096-byte kernel stack.  Under qemu with the CC1120 model
fitted, what actually happens is that the first redirection forks
twice and gets two stacks, and the third fork faults with SP at
0x0ffffd90 \- below the bottom of CCM \- after which the fault handler
faults on the same stack and the core locks up saying nothing.  The
retry loop is real and was reached only when KSTACK was raised to 8192
and no stack could be had at all.
.PP
Nothing frees a kernel stack: a dead proc goes back on the free list
with its stack attached.  So the total is the same however they are
allocated, and the only thing that varies is whether the request is
made late, out of a fragmented pool, at a fork \- which is where the
shell is when it opens a file with ">".  They are all taken at boot
now, in one piece, before the pools exist.  Five redirections and two
reads in one boot, measured.
.PP
The pool split went back to 50/49/1 with it.  53/46 existed only to
make that one fork work and cost ls(1) and a worse out-of-memory to do
it.
.PP
Two things are deliberately not on this list.  Making the CC1120 talk
to an amateur station is not possible with this part \- it does 2-FSK
and the bands stop at 960MHz, so APRS on 144MHz and anything on HF
need a different click; the FT-891 reaches HF but has no payload file,
because the audio is on a socket at the back of the set and not in
this device.  What would carry data over it is a modem on that audio,
which is a different piece of work and is not pretended at here.  And decoding what is in
870-889MHz is not a goal: the survey found it, both instruments agree
it is there, and identifying a TDMA system at a few hundred
microseconds a burst is a different project from making a radio work.
.IP "6.  Stop typing at a shell.  Done, on silicon." 6
Item 5 made one redirection work and the second one survivable.  It did
not make the shell a reasonable thing to drive a radio with, because
the cost is in what a shell is: a command is a process and a
redirection is an open, so
.PP
.EX
	echo rssioffset -90 >/dev/radio0/ctl
.EE
.PP
forks twice to write eleven bytes, and
.B tools/radio/board.py
had to grow a held-open
.B "cat >file"
to get round it \- along with a comment explaining that inside such a
.I cat
a liveness marker cannot be sent, because it would be written to the
ctl file rather than run.  That is the shape of the problem: the only
way to stop forking was to give up being able to ask whether the board
was still alive.
.PP
.IR Lil (1)
is the answer taken: an interpreted subset of Limbo, in which a file is
opened once, held in a variable, and written to as often as one likes.
The defect
.B board.py
works around does not arise, because holding the file is a variable and
writing to it is an ordinary statement, so a marker can still be
printed between two writes.
.PP
Limbo's syntax rather than a Forth's or a Tcl's, so that what is typed
at a console and what is compiled into a
.B .dis
look alike.  Three kinds of value \- integer, string, open file \-
because holding a descriptor across statements is the entire purpose.
No syntax tree: a
.B while
remembers the source text of its condition and body and re-scans them,
which is slow and small.  12447 bytes at
.BR DISWORD=4 ,
against 41629 for
.BR sh.dis ,
and in flash rather than the pool because it is in
.BR XIPDIS .
.PP
Selection is by file and not by conditional compilation: a board carries
it because its config names it.  It is beside
.I sh
and not instead of it, and the
.B init
section still names
.BR armv7minit ,
so a fault in it leaves something to look at the board with.
.PP
What is measured, under qemu with the CC1120 model: it loads from flash,
prints its banner and runs statements, and its allocation is flat \-
four twenty-iteration loops with
.B /dev/memory
read between them left the heap's cursize unmoved at 50048 bytes and its
live count at 459, allocations and frees tracking each other exactly.
.PP
Three bugs in it were found by review and not by testing, which is worth
recording because the tests had all passed.
.B expr 's
second argument is a precedence level and the statement loop passed it a
position; both are
.BR int ,
so it compiled silently and re-parsed from the start of the line, making
.B "print(\\*qa\\*q); print(\\*qb\\*q)"
print
.I a
twice and
.I b
never.  Every test had dodged it because the second statement on a line
was always an assignment, which happens to slice.  The statement that
runs twice in real use is
.BR "write(ctl, ...)" .
.B close
was a builtin that closed nothing and said it had, because Limbo shuts a
file when the last reference goes and the reference that matters is in
the variable table, which a builtin cannot reach.  And an argument that
failed was still passed, so
.B "write(ctl, read(f, 8))"
with a failing read wrote the string
.B nil
to the ctl file.
.PP
One thing reported here earlier was wrong and is withdrawn.  On the
strength of a compiled Limbo loop whose body was only
.B "t := s[1:]"
growing a column of
.B /dev/memory
by one per iteration, I said no Dis heap allocation in this tree is ever
reclaimed.  That column counts allocations made, not objects alive, and
the one beside it counts frees; on the board they track each other and
the live figure does not move.  What is true is narrower: under the
.I host
.IR emu (1)
that loop freed 15 times in 20000 allocations and died having extended
the arena rather than collected.  So a memory measurement taken under
the host
.I emu
is not evidence about the board, which is exactly where I took it.
.PP
And one real limit, which is the board's and not
.IR lil 's:
.B dir
on a large directory exhausts the heap.  There are about 40310 bytes
free at a prompt and
.B sys->dirread
on
.B /dis
wants more than that.  The same kernel fails the same way under the
shell \-
.B "ls /dis"
gives
.BR "out of memory: heap" ,
and
.B "ls /dev"
after it kills the shell outright \- and this board's configuration file
has had
.B "ls /dis | wc -l"
written in it as the marginal case for some time.  The difference is
what happens afterwards:
.I lil
reported the failure and kept its prompt, where the shell died and took
the console with it, after which nothing drains the console queue.
.PP
What is left on this item.  The comparison in
.B tools/radio/lilvsh.sh
writes the same ctl line the same number of times at the same spacing
through each of the two, so that the claim is a measurement and not an
argument from how it is built; the shell run is the control, and if it
survives too then forking was never the limit here.  After that,
.B board.py
still speaks shell \-
.BR "echo <mark>" ,
.BR "cat >file" ,
.B "bind -a"
\- and has to be taught the other language; and an init that loads
.I lil
instead of
.I sh
is a one-line change to a new file in
.BR os/inferno/init/ ,
named from the config's
.B init
section, which is worth making only once the board has been driven
through
.I lil
for a while.
.PP
.B "The premise of this item was falsified by the measurement written to test it, and what follows replaces it."
.PP
.B tools/radio/lilvsh.sh
writes the same ctl line the same number of times at the same spacing
through the shell and through
.IR lil ,
and reports which way it went.  Ninety writes of
.B "rssioffset -90"
two seconds apart, paced one character at a time, on the current kernel
under qemu:
.DS
.CW "                  live heap      allocations"
.CW "sh    before             358"
.CW "      after              363             12665"
.CW "lil   before             455"
.CW "      after              462              4610"
.DE
.PP
Both survived.  The shell did not die, its live heap did not move, and
forking ninety times at that rate is not the limit.  The failure this
item was written around \-
.B "no procs for kproc"
in the board's configuration file, and
.BR board.py 's
monitor killing the shell in a few minutes \- predates
.B KSTACKPREALLOC
in
.BR mem.h ,
which takes every kernel stack in one piece at boot so that a fork cannot
fail for want of one.  It does not reproduce.
.PP
So the fork-cost argument for
.I lil
is withdrawn.  What the run does establish is narrower and still worth
having: neither leaks, and
.I lil
costs 51 allocations per ctl write where the shell costs 141.
.PP
And three things measured this session do justify it, all of them about
the shell dying and taking the console with it rather than about the cost
of a fork.
.IP \(bu 3
A directory read.
.B "ls /dis"
gives
.BR "out of memory: heap" ,
and
.B "ls /dev"
attempted after it kills the shell outright with
.BR "[Sh] Broken" ,
after which nothing drains the console queue and every character typed
allocates a block nobody frees \- which is the state that ends at
.B "allocb: no memory"
and needs the reset button.
.I Lil
reaches the same ceiling, because
.B sys->dirread
on
.B /dis
wants more than the 40310 bytes free at a prompt, but it reports the
failure and keeps its prompt.
.IP \(bu 3
A held-open file.
.BR board.py 's
own comment records that inside a
.B "cat >file"
a liveness marker cannot be sent, because it would be written to the ctl
file rather than run: the only way to stop forking was to give up asking
whether the board was alive.  Everything downstream of that \- inferring
liveness from whether a reply repeated, counting echoes that come back
from the uart interrupt handler long after the shell is dead \- exists to
guess at what a marker would have said outright.
.B LilStream
in
.B board.py
asks it instead, and
.B LilStream.alive()
is a capability
.B Stream
structurally cannot have.
.IP \(bu 3
A dropped character.  A line typed faster than the console echoes is
echoed in full and delivered short, because
.B kbdputc()
echoes and queues separately.
.I Lil
stays on its continuation prompt, which says what happened; the shell
gives a parse error.  This cost a wasted run here before the harness was
made to pace its input, and it is why
.B lilvsh.sh
does.
.PP
The lesson to keep is about the record and not about the shell.  Two of
the three things this item was built on \- that no Dis allocation is
reclaimed, and that a shell cannot survive repeated ctl writes \- were
inherited from notes that were true when written and are not true now,
and both fell to a measurement on the machine rather than a better
reading of the notes.
.IP "7.  A calibration program on the board, in Limbo.  Done, on silicon." 6
Everything items 1, 2 and 3 measured was driven from the host: a Python
script typing at a console, one
.B ctl
write per line, reading the stat file back between them.  That is the
right way to find a bug and the wrong way to own a measurement, for three
reasons that are all about where the numbers come from.
.IP \(bu 3
The host sets the pace, so the two ends have to be kept in step by
whatever is typing at them.  Every ladder measured so far has had the
transmitter's step and the receiver's reading joined up by the script
that drove both, which means a dropped console line silently attributes a
reading to the wrong step.  The fix is in the packet:
.B "put the step in the payload"
and the receiver needs no synchronisation at all, because every packet
says which step it belongs to.
.IP \(bu 3
The stat file gives one
.B last
RSSI per read, so a step gets one sample however many packets it sent.
.B #W/radio0/pkt
gives the twelve-byte header with every packet \- length, RSSI, SNR,
flags and arrival tick, out of the same queue entry \- so a step gets a
mean and a spread, and the CRC flag per packet rather than a counter
difference.
.IP \(bu 3
The packet error rate has to be counted where the packets are.  Reading
.B recv
before and after a step measures what arrived minus what arrived, and
cannot tell a lost packet from one that arrived late; a sequence number in
the payload can.
.PP
So:
.I radiocal (1),
one program with two roles.
.DS
.CW "radiocal -t [-n per-step] [-s step] [-r rate]"
.CW "radiocal -r [-o table]"
.DE
The transmitter walks PA_CFG2's PA_POWER_RAMP down its range, writing each
value through
.B ctl
and reading it back before sending anything \- a step whose register did
not take is not a step \- and sends
.I per-step
packets at each, each carrying the ramp value and a sequence number.  The
receiver holds
.B pkt
open for the whole run, decodes the header, and tabulates per step: how
many of the sequence arrived, how many are missing, and the mean, least
and greatest RSSI.  It prints the table and the least-squares slope of
RSSI against the datasheet's
.CW "(PA_POWER_RAMP + 1)/2 - 18"
dBm.
.PP
.B "What it can and cannot settle, which has to be in the program's own output."
It measures the product of two things: how accurately the ramp field
steps and how accurately this receiver's RSSI reports a change.  A slope
of one means both are right or both are wrong by reciprocal amounts, and
it cannot separate them.  It is worth having because the tinySA's own
attenuator \- a real one, stepping a real generator cabled into the click
\- already gave 0.93 over 24dB, so a figure near that from an entirely
different ladder is two independent instruments agreeing, and a figure
far from it says one of them is wrong.
.B "It gives no offset:"
free space between two antennas is an unknown loss, and that is still
what item 2's second half is blocked on.
.PP
And it is the first thing on this bench that wants
.I lil (1)
or a compiled program rather than a shell for a reason that is not about
heap: a ladder is a loop with a held-open descriptor in it, which is
exactly what item 6 was built for.
.PP
.B "Measured from the host first, as the thing the program has to reproduce."
tools/radio/paladder.py drives the same ladder through two consoles, five
packets a step, and is the control the Limbo version is checked against.
.IP "8.  Calibrations that belong to a radio and survive a reboot.  Done, on silicon." 6
Asked for directly, with the question "is ndb the right place?".  The
answer is that the
.I format
is right, the directory is not, and the hard part is neither: it is the
key.
.PP
.B "What has to be stored."
Three numbers per radio, all measured and none derivable: the crystal
error in parts per billion, the RSSI offset in dB, and the carrier sense
threshold in dBm.  A fourth now exists and is worth keeping beside them,
the RSSI slope from item 7.
.PP
.B "Why a file at all, and why this was a bug before it was a feature."
.CW spistm32f4.c
carries
.CW ".ppb = -3550," 
with a comment saying it was measured on this board and not taken from
anywhere, which was exactly right when there was one board.  There are
two now and the second wants +60300, so that line is wrong on half the
bench and
.B "no single image can be right for both."
Either every board gets its own kernel \- a flash cycle per measurement,
and an image that is silently wrong on the board next door \- or the
image carries the calibrations for every board it knows and each board
picks its own.
.PP
.B "The key, which is the part that is not obvious."
Picking its own needs an identity, and every identity a board could be
told is circular: the thing that would tell it is the thing that needs
to know.  Nor can it be the radio's: a CC1120 answers PARTNUMBER 0x48
and PARTVERSION 0x21 and has no serial number, so two ccRF clicks are
indistinguishable to software.  What does have one is the microcontroller
\- RM0090 39.1, a 96-bit factory serial at 0x1fff7a10, read-only, which
no reflash and no empty flash can change.  That is now at
.B #P/uid
as twenty-four hex digits, and the two boards here read
.CW 2037303959315008002f0022
and
.CW 203730395931500800300022 .
.B "The calibration is keyed on the board and not on the click,"
which is a deliberate approximation and a wrong one if a click is ever
moved between boards: the crystal belongs to the click.  It is right for
this bench, where each click stays in its board, and the entry carries a
.CW click=
attribute so that a move is recordable rather than silent.
.PP
.B "The format is attrdb(6), and the place is beside ndb rather than in it."
.I Ndb (6)
is the attribute database for
.I network
configuration and
.CW /lib/ndb/local
names the files that make up that one logical database.  A crystal error
is not network data and putting it there would make every program that
opens
.CW /lib/ndb/local
read it.  But the format is exactly right \- entries of attribute/value
pairs, one entry to a thing, read by
.I attrdb (2)
which is already in this tree \- and the mechanism for a second database
is the same mechanism.  So
.CW /lib/radio :
.DS
.CW "radio=cc1120 uid=2037303959315008002f0022"
.CW "	board=clicker2 click=ccrf2 name=board1"
.CW "	ppb=-3550 rssioffset=-102 csthr=-90"
.CW "	rssislope=0.930 slopesource=tinysa-attenuator"
.CW ""
.CW "radio=cc1120 uid=203730395931500800300022"
.CW "	board=clicker2 click=ccrf2 name=board2"
.CW "	ppb=60300 rssioffset=-102 csthr=-90"
.DE
.PP
.B "And a program to apply it:"
.I radiocfg (1),
which reads
.B #P/uid ,
finds the entry whose
.CW uid
matches, and writes the
.B ppm ,
.B rssioffset
and
.B csthr
lines to the radio's
.BR ctl .
It reports what it applied and what the file did not have, because a
calibration silently not applied is the failure mode that matters: it
looks exactly like a calibration applied wrongly.  A board with no entry
is not an error \- it says so and leaves the driver's defaults \- and a
board whose entry exists but whose uid it cannot read is an error,
because then it does not know whose numbers it would be using.
.PP
.B "What persistent means here, in two stages, and the first is not the second."
.IP \(bu 3
.B "Stage one, which is what this item builds."
The file is in the board's root, which is devroot served read-only out of
flash, so it is written at build time and is persistent across every
reboot and every power cycle.  One image is then correct on both boards.
What it is not is writable by the board: a new measurement means an edit
and a reflash.
.IP \(bu 3
.B "Stage two, which is a separate piece of work."
A board that has just measured its own crystal should be able to write
the answer down.  That wants a writable flash region \- the image ends
well short of the bootloader's sector at 0xe0000 and the F407 has a
megabyte, so there are whole 128K sectors spare \- exposed as a device
and carrying one small attrdb file.  Flash on this part erases by sector
and writes by word, so the thing on it wants to be a log of entries
rather than a file edited in place: append the new reading, and the
reader takes the last entry for a uid.  That is a filesystem question and
it belongs with
.I xip (1)
rather than here.
.IP "9.  AX.25 between the two boards, over the CC1120 on silicon.  Done, except the error-rate bullet." 6
Asked for directly.
.I doc/ax25-plan.ms
has all five of its items marked Done, and every one of them was measured
on two
.CW mps2-an386
over a socket pair with the SX1276 model \- the address field and UI
frames, SABM/UA/DISC/DM, I/RR/REJ and the sequence numbers, RNR and the
window, and digipeaters.  None of it has ever carried a frame over a
radio.
.PP
That was not an oversight: until item 3 was answered this morning, no
packet had crossed between two CC1120s at all, so there was nothing for
.B #a
to attach to.  There is now, and the thing to measure is what changes
when the packet device underneath is real:
.IP \(bu 3
.B "The payload budget."
.I Ax25 (3)
republishes
.CW iounit
less its header, and the numbers in
.I doc/ax25-plan.ms
\- 239 with no path, 225 with two digipeaters \- are the SX1276's 255.  A
CC1120's is 125, so the same arithmetic gives 109 and 95, and the plan's
claim that the sizes come from
.CW sys->iounit
rather than from a constant is a claim this measures.
.IP \(bu 3
.B "The timers."
T1 and T2 were chosen against a LoRa model whose transmit at SF12 is over
two minutes.  A CC1120 at 1200 symbols a second sends a hundred-byte
frame in under a second, so the defaults are either fine or pointlessly
long, and which is a measurement.
.IP \(bu 3
.B "T2, which has never been shown to be worth anything."
The plan records that T2 was credited with fixing a link and then
measured to make no difference once the model's own collision bug was
fixed, and says plainly that nothing has yet shown what it is worth.  Two
half-duplex radios on one channel is the case it was written for, and
this is the first chance to find out.
.IP \(bu 3
.B "And whether the state machine survives a real error rate."
Every frame of every earlier run arrived.  Over the air at the bottom of
item 7's ladder the error rate is not zero, and REJ, RNR and the
retransmission counter have never been exercised by anything but a
deliberate test.
.PP
The order is the plan's own: UI frames first, because a beacon is a UI
frame and needs no state machine, then the connected-mode handshake, then
data through a window.
.PP
.B "The second board arrived, and is flashed."
Two clicker 2s with ccRF clicks now, which is the transmitter item 3 has
been waiting for.  What is done and what is not:
.IP \(bu 3
The new board is programmed, twice, with the kernel this tree builds.
Both times the bootloader answered
.B "McuType STM32F4XX" ,
.B "DevDsc 'clicker 2 for STM32'" ,
wrote through to 0xe0000 \- the ceiling
.I bin2ihex
is given, because the HID bootloader occupies the last 128K sector from
there \- and rebooted.
.IP \(bu 3
It runs the image.  No HID device at 0x1234/0x0001 persists after a
reset, so it leaves the bootloader rather than sitting in it, and the
image is the same one the first board runs.
.IP \(bu 3
It says nothing on its console.  Its console is an RS232 click into a
PL2303, where the first board's is a USB UART click, and nothing arrives
on either device node the PL2303 presents.
.PP
The kernel is not the variable, and
.I otherusarts()
is why that can now be said.  It was written for exactly this case \-
its own comment says "so that a board whose UART click is in the other
socket is not mistaken for a board that never booted" \- and it had
never been called.  It is called now, so the kernel writes its banner on
USART2/PD5, which is mikroBUS 1, and a raw line naming the socket on
USART3/PD8, which is mikroBUS 2, and on UART4/PA0, the pad.  Whichever
socket a click sits in, something is transmitted at 115200.  So socket
confusion on its own can no longer explain total silence, and what is
left is the signal path.
.PP
Which is where an RS232 click differs from a USB UART click, and the
difference is the whole of it.  The click carries a MAX3232 and puts
true RS-232 on its connector: plus or minus five to twelve volts, and
inverted.  A USB-to-UART cable expects TTL, and an RS-232 idle is a
negative voltage a TTL input reads as a permanent break, which is
silence and not garbage.  If the adapter is instead a real USB-to-DB9
RS-232 one then the levels are right and both ends are DTE, so a
straight cable puts transmit against transmit and a null modem is
wanted.  Neither can be told from the other in software.
.PP
The cheapest test that settles it is a swap: a known-good TTL USB UART
adapter, of the kind the first board uses, onto the new board's mikroBUS
1 in place of the RS232 click.  If the board prints its banner then the
flash and the kernel are proven and the fault is entirely in the RS232
path; and with
.I otherusarts()
in, any working adapter now also names the socket it is in.
.PP
A method note, because it cost three of the user's button presses.  I
first answered "is anything alive on this port" by opening it and
listening, which cannot answer it: a board at a shell prompt says
nothing until spoken to, so a passive listen only catches output that
lands inside its window, which means a reset pressed at the right
moment.  That listener reported zero bytes on seven ports across three
resets, and I was about to read a wiring fault out of it.  Pointed at a
.I qemu
.B "-serial pty"
carrying a kernel that was certainly printing, it reported zero bytes
there too.  The instrument was measuring the wrong thing and every
negative it had produced meant nothing.
.B tools/f407/probeport.py
pokes the port instead \- a newline for a prompt, then a command whose
output is a token \- and is validated against that same pty, where it
must see the token and does.  It also tells apart the case this tree has
been bitten by before: the token seen once is the uart interrupt
handler's echo, which comes back long after the shell is dead, and twice
is the shell running what was typed.
.PP
.B "A beacon, so that item 3 does not need the second board's console."
.I "os/inferno/init/armv7mbeacon.b"
configures the radio and transmits
.B INFERNO-BEACON
every two seconds without being told to, so a board carrying it is
useful with no working console at all \- which is what the second board
has.  Chosen by
.B "mk INIT=armv7mbeacon" ,
so a board carries a shell or carries this and which one is a property of
the image, the only thing establishable about a board that says nothing.
.PP
.B tools/radio/beacontest.sh
runs it under qemu against a shell kernel over a socket, with the control
that decides whether the positive means anything: the same receiver, the
same settings, the same duration, no beacon started.  It passed \- and
the number was wrong.  One packet received out of about twenty-five sent.
.PP
The driver's counters localised it, which is what they are for.
.B "recv 1, crcerr 0, rxoverflow 0"
\- so nothing failed CRC and no queue dropped anything.  Then
.B NUM_RXBYTES
read
.B 0x0f
\- a length byte and the fourteen-byte payload \- and stayed there across
six readings three seconds apart while the beacon transmitted.  The part
was holding a whole packet and nobody had been told, which points at one
thing only: the interrupt.
.PP
And it was the model, not the driver.
.I hw/ssi/cc1120.c
raised PKT_SYNC_RXTX on a received packet and never lowered it, so the
second packet set a pin that was already high; the stm32f407 asks EXTI
for a rising edge, so it got one interrupt per boot.
.B tools/qemu-patches/0051
lowers it when the FIFO drains, which is where 0044 put the queue flush
for the same reason.
.B "recv 1"
became
.B "recv 19"
over the same interval with the control still at zero.
.PP
That direction is worth noting because it has gone the other way here
twice.  The driver does re-strobe SRX after reading a packet, and a real
part lowers that pin at the end of a packet by itself, so silicon was
never subject to this and nothing measured on the air is invalidated by
it.  What is invalidated is anything concluded from
.I qemu
about receiving more than one packet, which until now nothing had tried.
.PP
The measurement that found it \- reading NUM_RXBYTES while holding the
data file open for reading \- is not expressible inside
.BR "cat /dev/radio0/data" ,
because the cat owns the console and every line typed is data.  It was
made in
.IR lil (1),
holding ctl and data in two variables.  That is the second thing
.I lil
has been needed for and the first that found a bug with it.
.PP
A build trap, met on the way and worth writing down because it could
cost a flash cycle.
.I mk
has no dependency on
.BR INIT ,
so building with the override and then building without it silently kept
the beacon init: the generated
.I stm32f407.prog.s
still named
.B armv7mbeacon.dis
and the image was byte identical to the beacon one.  Deleting the
generated
.B .s
is not enough either, since
.I mk
short-circuits on the existing
.BR .t ;
both have to go.  Check which init an image carries by grepping the
generated
.BR prog.s ,
never by having built without the override.
.PP
.B "The second board is beaconing, and the lamp settled the socket question."
Flashed with
.I armv7mbeacon
it blinks steadily, and because the lamp hangs off the radio's own
.I Spidev
and the beacon exits before reaching it if
.B /dev/radio0/ctl
cannot be opened, a blink says the CC1120 was found, the ctl file opened
and the loop is turning.
.PP
That also answers, by deduction rather than by the argument made earlier
in this document, where the clicks are.
.I cc1120init
looks on SPI2, which is the pinout of a ccRF click in mikroBUS 2, and the
part was found \- so the ccRF click is in mikroBUS 2 and the RS232 click
is in mikroBUS 1, which is exactly where the console's USART2 on PD5 and
PD6 is.  The console click is in the right socket.  Its silence is
therefore the RS232 electrical path and nothing to do with which socket
anything is in.
.PP
What is still not working is the air.  The other board, whose console
does work, was configured to match \- 915MHz, 9600, deviation 19958, bw
50000, csthr -104 \- and its own
.B probe
of the band reports
.B "floor -107 peak -104 duty 0% bursts 0"
over 800ms, twice.
.B probe
is a raw RSSI sweep, so it would see a carrier whatever the sync word or
the rate; nothing is radiating.
.PP
And the driver is not the reason.  The same silicon transmits from the
console:
.B "echo BOARD1-TEST >/dev/radio0/data"
gives
.BR "sent 1" ,
.BR "lasttx staged 13" ,
.B "marc 0x40"
and
.BR "txtrace 1 0 0 0 2 0" ,
so the packet transmit path works on this hardware.  What is not known is
whether the beacon board reaches it.
.PP
The lamp could not say, because the first version of it flipped once a
frame regardless of what
.I write
returned \- so a blink meant the loop was turning and nothing more, which
is precisely the question that was open.  It now flips only on a
successful write and sits solid on a failing one, solid rather than dark
because dark is what a board that never booted looks like.
.PP
.B "The second board is not calibrated, and one image cannot calibrate two boards."
.B .ppb
is
.B -3550
in
.IR spistm32f4.c 's
.I Spidev
initialiser, and its comment says "measured on this board" \- which was
the first one, against a generator zero-beat to WWV.  Both boards are
built from the same config, so the second is corrected by the first
one's crystal error.
.PP
That is the right shape and the wrong place.  A
.I Spidev
carrying
.B ppb
is per-board information held as data, which is how this tree is meant
to differ between boards; but the data lives in a source file shared by
every board built from that config, and nothing distinguishes two
physical boards of the same type.  The
.B ppm
ctl verb sets it at runtime, so the answer is to correct each board when
it is driven rather than to build an image per board \- which also means
a board with no working console cannot be corrected at all until it has
one.
.PP
It does not explain the current silence, and the arithmetic is worth
writing down so it is not reached for again.  3550ppb at 915MHz is
3249Hz.  If the second board's crystal erred the opposite way by as much
again the total would be about 6.5kHz, and the receiving board listens
with
.BR "bw 50000" .
Worst-case spread on a cheap 32MHz part is perhaps twenty parts per
million, or 18kHz, still inside a 50kHz filter \- and
.B probe
measures raw RSSI across that filter, so it would register a carrier
several kilohertz off without trouble.
.B "peak -104, duty 0%"
is no energy, not mistuned energy.
.PP
.B "RETRACTION: the lamp deduction above was a misread LED, and everything drawn from it is withdrawn."
.PP
The board shows two lamps and I was told one blinked and one was solid.
I took the blinking one for the beacon's and concluded that the CC1120
had been found, that the ctl file had opened, that the loop was turning,
and \- from
.I cc1120init
looking on SPI2 \- that the ccRF click must therefore be in mikroBUS 2
and the RS232 click in mikroBUS 1.  A chain of four claims on one
unidentified LED.
.PP
It was settled on the board whose console works, which costs nothing:
.B "echo led off >/dev/radio0/ctl"
darkens the
.I right
lamp.  So PE12, which
.I spiled
drives and which the beacon's
.B led
verb moves, is the right one \- and on the second board the right lamp
has been solid in both images.  The beacon's lamp has never moved at
all.  The blinking one is LD2, the heartbeat
.I idlehands()
gives it, and its rate changed between the two images because the second
does eight ctl writes a frame where the first did one, so the kernel
idles differently.  That change is what made the misreading look
confirmed.
.PP
What is actually established is much less.  The board runs a kernel, and
nothing else.  A solid PE12 is where
.I archstm32f407.c
leaves it at boot, so the beacon has not reached the point of moving it,
which means it exited before its loop \- and the three ways it can do
that are that
.B /dev/radio0/ctl
would not open, that a configuration write failed, or that
.B /dev/radio0/data
would not open.  All three print to a console nobody can read.
.PP
And there is a floor under how much any of this can say, which is worth
naming because it shaped the whole attempt: the lamp is reached through
the radio's own ctl file, so a board that cannot find its radio cannot
use the lamp to report that.  The indicator is downstream of the thing
most likely to have failed.  An LED reachable without the radio \- from
.IR archstm32f407.c 's
.I ledpin
through
.BR #P ,
say \- would not have that defect.
.PP
The likeliest reading of all the evidence together is that the two
clicks are in the opposite sockets to the ones this kernel expects.
.I cc1120init
looks on SPI2, which is mikroBUS 2; a ccRF click in mikroBUS 1 would not
be found, which leaves no
.B /dev/radio0
and a beacon that exits at once with the lamp untouched.  The console is
USART2 on PD5 and PD6, which is mikroBUS 1; an RS232 click in mikroBUS 2
would never carry it.  One swap accounts for both symptoms.  It does not
account for
.IR otherusarts ()
writing to USART3 on PD8 \- mikroBUS 2 \- and that not arriving either,
so either the RS232 path has its own fault as well or that line is being
lost for the same electrical reason as everything else.
.PP
The test is to exchange the two clicks and reset.  Nothing in software
can distinguish these cases, and no more should be deduced from a lamp
until it has been.
.PP
.B "Sockets were swapped, and both boards now work individually."
The clicks were in each other's sockets, which is what the retraction
above guessed from the symptoms and could not prove.  With them
exchanged the second board's console came up on the RS232 click, and it
says everything that was invisible before:
.DS
.CW "cc1120 mikrobus2: CC1120 rev 0x21, listening"
.CW "armv7m beacon init"
.CW "beacon: configured"
.CW "ARMV7M-BEACON-OK"
.CW "beacon: 0 frames"
.DE
.PP
and then 15, 30, 45 frames with no error line, which is the thing that
matters: a failing write prints
.B "beacon: frame N:"
and its error, and none appeared.  So the radio is found, the part is
configured, and frames are going out.  The RS232 path was never at fault
\- the console was simply wired to the wrong socket, and
.IR otherusarts ()
writes its line once at boot, long before any of my probes, so that
silence was never evidence either.
.PP
The receiving board still hears nothing:
.B "recv 0"
and
.B "peak -100 duty 0% bursts 0"
against a floor of -104.  And the arithmetic now says where to look,
because the transmit power is not what it could be.  The driver writes
.B "PA_CFG2 0x4f"
where reset is
.BR 0x7f ;
by the register's formula, output is (PA_POWER_RAMP+1)/2 - 18 dBm, so
.B 0x7f
is the +14dBm this file's comment records and
.B 0x4f
is
.BR -10dBm .
At half a metre and 915MHz, which is 25.6dB of free space:
.DS
.CW "both antennas fitted     -10 -25.6 -3.5 -3.5   about  -43dBm"
.CW "one antenna missing                            about  -78dBm"
.CW "neither fitted                                 about -115dBm"
.DE
.PP
A W3312 is 45 per cent efficient, which is the -3.5 each.  The first two
cases are far above a -98 threshold and would show bursts; the third is
under the floor, which is what is measured.  So the question is whether
each ccRF click has its antenna on \- and the comment in
.I cc1120.c
records that every measurement in it was made on "a clicker 2 with a
ccRF click and a Pulse W3312 on it", while the antenna spent part of
this session on the tinySA instead.
.PP
Worth keeping separately: -10dBm is 24dB below what this part will do,
and nothing in the tree says why
.B 0x4f
rather than
.BR 0x7f .
It is inside Part 15 either way at these duty cycles.  If the link turns
out marginal with antennas on, that register is 24dB of headroom nobody
is using.
.PP
.B "The beacon radiates, measured on the tinySA, and the receiving board is the deaf one."
Max-held sweeps of 914.7-915.3MHz with the beacon running catch
something at -58 to -64dBm against a held floor near -110.  The apparent
frequency scatters across the span, 914.91 to 915.25, which is what a
swept measurement does to a transient: a 12ms burst appears wherever the
sweep happened to be, not where the signal is.
.PP
A count of bursts is the wrong measure, and its control said so.
Counting sweeps whose peak stood 15dB over their own floor gave 3 of 12
at 915.0 and
.I "12 of 12"
at both 920.3 and 908.3 \- the controls beating the target, because
those bands carry the FHSS device this document found earlier and the
floor moves under them.  A criterion the control satisfies better than
the target measures nothing.
.PP
The level is what discriminates: 915.0 peaked at -64dBm in that run and
-58 in the one before, where 920.3 peaked at -95.7 and 908.3 at -85.7.
Twenty to thirty decibels over the neighbouring bands, at the frequency
the beacon is set to.  Taken with the beacon's own console \- 15, 30, 45
frames and no error line, where a failed write prints one \- the
transmitting half of item 3 is done.
.PP
So the receiving board is the deaf one.  It reports
.B "peak -100"
against a floor of -104 while an instrument a similar distance away
hears the same transmitter at -58.  Forty decibels is about what an
antenna is worth, and the Gabil QRP is on the tinySA.  The thing to try
is an antenna on the receiving board's ccRF click.
.PP
.B "Roles swapped, and the receive path localised: the receiver is saturated."
Both antennas are on, and swapping which board transmits removes every
per-board explanation.  What is now measured, in both directions:
.IP \(bu 3
Transmit works on both.  The first board keyed and swept by a tinySA
gives -41dBm against a -106 floor, 65dB up, with its 2-FSK tones
separating as the deviation is swept.  The second board, beaconing, is
seen at -58 to -64dBm.  Both report
.B "marc 0x40"
and
.B "left 0"
\- the part finished the transmit and emptied its FIFO.
.IP \(bu 3
The receive front end works.  With the first board keyed, the second
board's own
.B probe
of 915MHz went from
.B "floor -104 peak -100 duty 0%"
to
.BR "floor -81 peak -64 duty 92% bursts 24" .
Forty decibels, from the receiver's own RSSI, through its own antenna.
.IP \(bu 3
And sync never fires.  With the first board transmitting packets in a
loop, the second board's detector pins read: carrier sense
.BR "100% high" ,
PQT_REACHED
.B "7566 of 1712056 samples"
\- so a preamble is occasionally recognised \- and PKT_SYNC_RXTX
.B "0 of 1720911" .
.B recv
and
.B crcerr
both stay at zero, so not even a corrupted packet arrives.
.PP
Two things were tried and did not fix it, and both are worth recording
because the first looked certain.  Both boards had
.BR "sync 0xaaaa 16" ,
which is the pattern a preamble is made of \- a receiver hunting 0xAAAA
inside a run of 0xAA has no bit boundary to lock to, and that setting is
a holdover from the generator experiments, where an FM tone was an
alternating symbol and 0xaaaa was the only thing to hunt for.  Setting
both to
.B 0x930b
changed nothing.  Nor did resetting both radios to the driver's own
register table and changing only the frequency \- rate 1200, deviation
3997, bw 10000, which is a sane modulation index of 6.7 inside its
filter.
.PP
What the last run showed instead is
.BR "rssi -8" .
Against a quiet floor of -104 that is some ninety-six decibels up, and
while the absolute calibration of this number is an unverified -102
offset taken from a TI example, the relative figure is not in doubt.
The part is overloaded.  Its own datasheet RSSI saturates above about
-65dBm, which this bench measured earlier, so the number may not even
mean -8 \- but a receiver that far into saturation does not demodulate,
and that accounts for every symptom at once: carrier sense pinned high,
a preamble detector that cannot work, and a sync word never found.
.PP
Two radios a few centimetres apart with antennas on is too close.  The
thing to try is metres rather than centimetres, or an attenuator.
.PP
A method note, because it cost two invalid measurements.  Driving two
boards through two
.IR screen (1)
sessions is fine; driving one board from two processes at once is not.
A transmit loop stuffing characters into the first board's session while
a configuration script stuffed into the same session produced
.B "cho INFEeRcNhOo- BIENAFCEORNN O>-/BdEeAvC/ONra"
on its console, so the board was not transmitting what it was asked for
and the reads came back empty.  One writer per console, and read the
console to check it when a reply is missing rather than assuming the
command arrived.
.PP
.B "RETRACTION: the receiver was not saturated.  The -8dBm was the reset verb lying."
.PP
.B "rssi -8"
was read with nothing transmitting at all, which is the check that should
have been made before anything was concluded from it.  The cause was the
.B reset
verb: it strobed SRES and stopped, SRES puts every register back to the
part's own default, and AGC_GAIN_ADJUST went to zero while
.IR cc1120stat ()
went on subtracting the software offset of -102 this board carries.
Ninety-four decibels of bookkeeping and no radio involved.
.PP
So two of the measurements above are void.  The board-to-board test "at
the driver's defaults" was run on a receiver whose AGC was not configured
at all, and the saturation reading was an artefact.  The boards were moved
apart on the strength of it, which was wasted effort.
.PP
What survives from that run is the part that did not depend on the
reset: transmit works both ways, measured on an instrument; the receive
front end works, measured by the receiver's own probe going 40dB with a
real transmitter keyed; and with packets in the air carrier sense reads
100 per cent, PQT_REACHED 7566 of 1712056 samples and PKT_SYNC_RXTX 0 of
1720911.  Those were taken before any reset and stand.
.PP
.I ccapply ()
now holds everything that follows an SRES and the reset verb calls it, so
the driver and the part cannot disagree again.  The frequency is kept
rather than returned to Deffreq, and a reset whose settings do not read
back reports an error instead of success.
.PP
The lesson is the one this document has had to write three times today,
and the third instance is the worst because the instrument was this
tree's own code: read the quiet baseline of a measurement before reading
anything into its value.  A passive port listener was believed until it
reported nothing from a qemu pty that was certainly printing; an LED was
believed until the lamp was identified on a board whose console worked;
and an RSSI was believed until it was read with the transmitter off.
.PP
.B "Board 2's console was unplugged, not dead, and the distance is now too great."
Two corrections to the section above.  Board 2 was never wedged \- its
UART came off when the boards were moved, so the console echoed nothing
and every figure read from it was
.IR screen (1)
scrollback.  Reconnected, it answers and is healthy: a clean boot at
.BR "freq 868000000" ,
.BR "rssi -103" ,
.BR "pktcfg0 0x20 pktlen 125" .
The
.B "rssi -8"
and
.B "pktcfg0 0x00 pktlen 3"
were history, as was the saturation reading drawn from them.
.PP
.B tools/radio/boardcmd.py
exists so this cannot recur: it types at a board through its screen
session and refuses to report anything unless a fresh marker comes back
.I twice
\- once is the uart interrupt handler, which answers long after the Dis
shell has gone \- and it marks again afterwards, so a board that dies
partway cannot have its last replies believed.  It reported BOARD-DEAD
for board 2 and "alive before and after" for board 1, which was the first
trustworthy statement about either in half an hour.
.PP
With both boards verified alive and configured identically \- 915MHz,
rate 1200, deviation 3997, bw 25000, sync 0x930b, csthr -90, both quiet
at
.B "rssi -107"
\- board 1 transmitted 79 packets, each with
.B "marc 0x40"
and
.BR "left 0" ,
its counter going 130 to 209.  Board 2 detected nothing at all:
.BR "floor -110 peak -107 duty 0% bursts 0" ,
and every detector pin at zero.
.PP
That is the distance and not a fault.  Moved apart, the received level
fell from the -64dBm measured when they were close to below -107, which
is over forty decibels and about what a hundredfold change in separation
costs.  So the close measurement is the one that matters, and it stands:
a strong signal present, carrier sense at 100 per cent, PQT_REACHED on
7566 of 1712056 samples, PKT_SYNC_RXTX on none of 1720911.
.PP
Worth recording against the withdrawn saturation claim: -64dBm is about
where this part's RSSI
.I reporting
saturates, which this bench measured long ago, but it is nowhere near
where the receiver itself overloads.  A -64dBm signal should demodulate
cleanly.  It did not.
.PP
What the test wants is tens of centimetres \- strong enough to be well
over the floor, far enough to be an ordinary signal.  Centimetres was
never the problem and metres is too many.
.PP
.B "At rate 1200 the part never enters TX, and the driver reports success anyway."
Setting
.B "rate 1200"
with
.B "deviation 3997"
and
.B "bw 25000"
\- which is the driver's own register table, reached by resetting the
part \- leaves it unable to transmit.  84 packets were written to
.BR /dev/radio0/data ,
the
.B sent
counter followed them, every one reported
.B "marc 0x40"
and
.BR "left 0" ,
and a tinySA swept across 914.8-915.2MHz ten times saw nothing: strongest
-96.3dBm against a floor of -114, not one sweep twenty decibels over it.
The same board keyed with
.B "carrier on"
gives -41dBm, so it is not the antenna or the instrument.
.PP
.B txtrace
says where it stops.  The driver samples the part's state through the
transmit sequence, and at rate 9600 it reads
.B "1 0 0 0 2 0"
\- RX, idle after SIDLE, idle after the FIFO flush, then
.B 2
for TX.  At rate 1200 it reads
.B "1 0 0 0 4 0" :
.B 4
is CALIBRATE.  The part goes into calibration on its way to TX and comes
back out to IDLE without ever transmitting.
.PP
.B "marc 0x40"
is not evidence against that.  MARC_STATUS1 is cleared by being read, so
the driver reads it once and keeps it; a 0x40 can be left over from the
last transmit that did work.  A driver that counts
.B sent
for a packet the part never put on the air is reporting its own
intentions.
.PP
This invalidated a run of measurements before the tinySA caught it: the
board-to-board tests at the driver's defaults were made against a silent
transmitter, and the receiver's reporting nothing was correct.
.PP
Not yet diagnosed.  What is known is that 9600/20000/50000 radiates and
1200/3997/25000 does not, so the fault is in what the rate, deviation and
bandwidth registers become at the low rate rather than in the transmit
path itself.
.PP
.B "And the signal has to be strong enough for a negative to mean anything."
With the boards close the receiver saw
.B "floor -81 peak -64"
\- seventeen decibels of margin \- and sync never fired, which is a
result.  Brought near again it sees
.B "floor -108 peak -105 duty 5% bursts 5" :
three decibels, at which nothing could demodulate and a silent sync word
says nothing at all.  Carrier sense reads 87 per cent and PQT_REACHED
3693 of 1712104 samples there, which is a receiver chewing on noise just
above its own floor with
.B "csthr -104"
set.
.PP
So the measurement wants the earlier geometry back \- whatever gave
-64dBm, which was centimetres \- and a stated received level beside every
future reading of the sync pin.  A sync failure at 3dB SNR and one at
17dB are different claims.
.PP
.B "And the reset bug had crippled the transmitter too, which accounts for the missing forty decibels."
Board 1 at 9600/19958/50000 \- the settings that radiated at -58 to
-64dBm earlier in the day \- now reads
.B "txtrace 1 0 0 0 4 0"
where it used to read
.BR "1 0 0 0 2 0" .
The 2 is TX and the 4 is CALIBRATE: the part goes into calibration and
returns to IDLE without transmitting, and
.B sent
counts every packet anyway.  A tinySA sweep agrees, finding -102.8dBm
against a floor of -116 where the same board keyed gives -41.
.PP
The cause is the
.B reset
verb again.  Sixteen of the registers in this driver's table are the
synthesiser's and the amplifier's analogue configuration \- FS_DIG1 and
FS_DIG0, FS_CAL0, FS_DIVTWO, FS_DSM0, FS_DVC0, FS_PFD, FS_PRE,
FS_REG_DIV_CML, FS_SPARE, XOSC5, XOSC3, XOSC1, PA_CFG1 and PA_CFG0 \- and
the comment beside them records what the part does without them: "the
only thing on the air is 755.902MHz at -31dBm ... in the same bin whether
the part is told 868, 902 or 830".  SRES puts every one of them back to
the part's default, the old reset verb reapplied nothing, and board 1 is
still running the kernel with that bug.  Its AGC and packet registers
were put back by hand because they are reachable from the ctl file; these
are not.
.PP
So one bug produced both of today's false conclusions.  Cleared AGC on
the second board gave an RSSI of -8 and a saturated front end that was
not there; cleared FS and XOSC on the first gave a transmitter that
reported success and radiated nothing, against which the receiver was
measured four times.
.PP
Both boards need a boot to clear it \- cc1120init() writes the whole
table \- and the kernel with
.IR ccapply ()
in it will not do this again.  The second board already has it.  Until
then nothing measured about the receive path means anything, including
every reading of the sync pin taken after the reset: the strong-signal
case that localised the fault to sync detection was taken BEFORE it, and
that one stands.
.PP
.B "Both ends verified, and the loss is in the path between them."
After board 1's boot restored the register table its transmitter works
again:
.B "txtrace 1 0 0 0 2 0"
with the 2 for TX where the crippled part read 4 for CALIBRATE, and
.IR txpin (1)
reports
.B "PKT_SYNC_RXTX 100% high"
while the carrier is up \- the part's own transmit pin, measured at the
transmitter.
.PP
Board 2 is alive by
.BR boardcmd.py 's
marker, configured to match, and quiet at
.BR "floor -107 peak -103" .
Its own quiet baseline already carries
.B "duty 6% bursts 12"
from the band's FHSS traffic with
.B "csthr -104"
set, which is why a burst count means nothing here without that baseline
beside it.
.PP
With board 1 keyed, board 2 reads
.B "peak -101"
and
.BR "peak -103" .
Indistinguishable from its own silence.  The same pair, earlier in the
day, read
.B "floor -81 peak -64 duty 92%"
under the same test.
.PP
So roughly forty decibels have gone out of the air path while both ends
measure correctly at their own terminals.  The boards were moved twice
between those readings, and one cable \- board 2's UART \- is already
known to have come off in the process, so a disturbed antenna connection
is the first thing to look at rather than anything in the radio.
.PP
The tinySA, which would settle it from outside, has stopped answering on
either
.B /dev/cu.usbmodem*
after working earlier; it wanted a reboot once already today.
.PP
.B "SYNC_THR, and a received packet that was noise."
The driver's table sets
.B "SYNC_CFG1 0x0b" ,
whose low five bits are
.B SYNC_THR
= 11, and the
.B sync
ctl verb preserves those bits when it sets the mode \- so the threshold
is never changed from the table's.  This bench had already found
empirically that sync asserts at 30 and not below, which is recorded
earlier in this document as "recv 3, crcerr 3 at SYNC_THR 30".
.PP
Writing
.B "reg 0x08 0x5e"
\- mode 2, threshold 30 \- produced the first
.B recv
this pairing has ever shown.  It is not a received packet.
.B lastrx
gives
.DS
.CW "16 bytes: 21 03 10 0a 1a 94 49 04 95 20 05 9c 33 4a a2 12"
.DE
where INFERNO-BEACON is 49 4e 46 45 52 4e 4f 2d 42 45 41 43 4f 4e, and
the packet's own RSSI reads
.B "last -106"
\- the noise floor.  One such event in seventy seconds.  Threshold 30 is
maximally permissive and syncs on noise; that is what it did.
.PP
So the earlier "recv 3, crcerr 3 at SYNC_THR 30" in this document should
be read the same way unless its payloads were checked, and there is no
note that they were.  A
.B recv
with a garbage payload at the noise floor is a detector firing on
nothing, and counting it as reception is how a receive path gets
believed before it works.
.PP
What is actually blocking remains the level.  At +14dBm \- PA_CFG2 raised
from the table's 0x4f, which is -10dBm, to 0x7f \- the receiver's carrier
sense duty went from 6 to 41 per cent and its burst count from 12 to 21,
so more energy is arriving; but the reported peak did not move from -103
against a floor of -108.  Twenty-four decibels of transmit power that
does not appear in the received level is not a level measurement one can
reason from, and this board's RSSI offset is an unverified -102 taken
from a TI example.
.PP
Which leaves the tinySA as the only instrument that can say what is on
the air, and it has stopped answering on either
.B /dev/cu.usbmodem*
after working earlier today.  Until it is back the link cannot be
measured, only guessed at, and this document has enough guesses in it.
.PP
.B "Board 1 is not radiating, and two independent receivers agree."
With the tinySA back, board 1 was keyed and swept over 914.9-915.1MHz at
10kHz resolution.  Nothing: peaks of -103 to -112dBm against a floor of
-122, at a different frequency every sweep, which is noise and not a
carrier.  The same board keyed earlier today read -41dBm.
.PP
Its own account of itself is that it is transmitting.
.B txtrace
reads
.B "1 0 0 0 2 0"
with the 2 for TX,
.IR txpin (1)
reports
.B "PKT_SYNC_RXTX 100% high"
and
.B "CRC_OK 100% high"
while the carrier is up, and
.B sent
counts every packet.
.PP
PA_CFG2 is not the cause.  It was raised to 0x7f for +14dBm and put back
to the table's 0x4f for -10dBm, and both read back correctly and both
radiated nothing.
.PP
And the instrument is not the cause, which is the part that was checked
against known references rather than assumed.  The tinySA hears the
440.1MHz repeater this document surveyed at -71.2dBm where the survey
recorded -63.6, FM broadcast at -64.7, and 902-928 at -85.9.  Its floor
of -122 at 10kHz resolution is lower than the -114 it showed at 30kHz
earlier, which is the resolution bandwidth and not a disconnected
antenna.
.PP
So a working receiver with a working antenna, standing next to a
transmitter that says it is transmitting, hears nothing; and the other
board hears nothing either.  Two independent receivers and one
transmitter that believes itself.  That points at board 1's own antenna
connection, and nothing else fits: a radio reports the state of its
registers and its state machine, neither of which knows whether the
connector has anything on it.
.PP
It was radiating -41dBm this morning, so whatever changed happened during
the moving \- which has already cost one UART cable and sent two
conclusions wrong.
.PP
.B "RETRACTION: board 1's transmitter works.  I measured a gap and called it dead."
Cabled straight to the tinySA, with the carrier turned on by hand and
.I held
across the sweep:
.DS
.CW "PEAK -29.9 dBm at 914.99711 MHz   (-2.90 kHz from 915.000)"
.CW "PEAK -30.4 dBm at 914.99666 MHz   (-3.34 kHz)"
.DE
against a baseline, cabled and unkeyed, of
.BR "floor -136 peak -105" .
Seventy-five decibels of carrier.  The transmitter is not dead and never
was.
.PP
The error was mine and was in the timing.
.IR txpin (1)
keys the part, runs a ladder of four pin reads, and unkeys; its
carrier-on window is however long that ladder takes, and I started a
sweep forty-six seconds in and assumed the two overlapped.  They did
not.  The sweep measured the part before or after the carrier, read
-105.9dBm, matched the unkeyed baseline exactly, and I wrote that up as
two independent receivers agreeing that nothing was on the air.
.PP
The lesson is the session's, again: the control has to be held, not
inferred.  Turning the carrier on with its own ctl write, sweeping, and
turning it off is unambiguous; sleeping into somebody else's window is
not.  And when a measurement exactly equals its own baseline, that is as
likely to mean the stimulus was absent as that the response was.
.PP
So the transmitter radiates -30dBm into a cable at PA_CFG2 0x4f, which
is -10dBm at the pin with the tinySA's low-input attenuation between.
What remains unexplained is the over-the-air link: board 2 hears nothing
from a transmitter now known to work, and the tinySA on its own antenna
heard nothing from it either, while hearing a 440MHz repeater and FM
broadcast perfectly.  That is an antenna-path question on the
transmitting side and it is still open.
.PP
One number from this is worth keeping and is provisional: the carrier sits
2.9 to 3.3kHz low, about -3.2ppm, with this board's -3550ppb correction
already applied.  That is close to the -3250Hz this document records as
the error BEFORE correction, which would mean the correction is not
reaching the part \- but the tinySA has been reset twice this evening and
its own -1970ppb
.B freq_corr
may not have survived, which would account for most of it.  The
instrument has to be recalibrated against WWV before this figure means
anything.
.PP
.B "The packets are on the cable, modulated, at -32dBm."
Max-held over eight sweeps of 914.9-915.1MHz at 10kHz resolution while
board 1 sent packets into the cable:
.DS
.CW "held floor -129.4      held peak -31.9 dBm"
.CW "  +8.2 kHz  -31.9        -7.3 kHz  -32.4"
.CW "  +9.6 kHz  -33.4        -9.1 kHz  -33.4"
.CW " +12.2 kHz  -36.9       -13.1 kHz  -41.9"
.DE
Symmetric about 915.000 with energy out to about thirteen kilohertz.  So
the transmit chain including the modulator works, and the whole of board
1 is now accounted for: registers, state machine, carrier and modulated
packets.
.PP
What this is NOT is a deviation measurement, and the difference matters.
The peaks sit near plus and minus eight kilohertz where a deviation of
19958Hz would put two tones twenty kilohertz out; but the payload is
ASCII, and the spectrum of 2-FSK carrying text is not the two-line
spectrum that alternating symbols give.  Nothing here says the deviation
is wrong.
.PP
It does cast doubt backwards, though.
.B "carrier on"
produced a
.I single
peak at 914.997MHz, so it is an unmodulated carrier \- and the
.B spectrum
mode of
.IR txpin (1)
keys exactly that and then looks for "two tones, 2*dev apart", taking the
strongest bin and the strongest bin far enough from it.  On an
unmodulated carrier the second of those is whatever noise peak happens to
be outside the guard, so the table of deviation errors this document
carries from that run \- +20.5, -53.1, -6.3, +12.2, -2.1 per cent \-
measures the noise floor's shape and not the part.  It should not be
relied on.
.PP
So both boards are now proven at their own connectors: board 1
transmits modulated packets, board 2's front end and RSSI respond to a
real transmitter, and neither can hear the other over the air.  The two
remaining candidates are the antenna path on the transmitting side, and
board 2's demodulator and sync detection, and they can be separated: the
tinySA's generator can be cabled into board 2 at a known level, which is
what
.IR txpin (1)'s
.B link
mode was written for and the only way board 2's receive path has ever had
a controlled stimulus.
.PP
.B "The tinySA on this bench cannot generate 915MHz, which caps what the generator test can prove."
Asked what modes it has, the instrument answers
.DS
.CW "usage: mode [low] input|output"
.DE
\- so there is no high-band generator on it, and
.B "mode output"
is
.B "mode low output"
exactly as this document's earlier correction said.  Its low-band output
does not reach 915MHz: commanded to
.B "level -10"
and cabled straight into board 2, it raises that receiver's floor from
-122 to -107 and its peak to -105.  Fifteen decibels, where ninety-five
would be expected.  What arrives is a harmonic or leakage, not the
commanded signal.
.PP
So the level column of
.B tools/radio/rxtest.py
means nothing on this bench and only its on/off control carries
information.  The receiver showed PQT_REACHED and PKT_SYNC_RXTX at zero
per cent at every commanded level from -50 to -10dBm, with the generator
on and with it off \- and at an arriving level of -105dBm, with
.B "bw 50000"
and
.BR "rate 9600" ,
that is at or under this part's sensitivity.  Nothing can be concluded
from it.  The preamble registers were checked and are right:
PREAMBLE_CFG1 reads 0x14, four bytes of 0xAA, and PREAMBLE_CFG0 reads
0x2a with PQT enabled.
.PP
What remains is the one configuration that removes every unmeasured
quantity: board 1's SMA cabled directly to board 2's.  Board 1 is proven
to put a modulated packet at -32dBm into a cable and an unmodulated
carrier at -30dBm within 3kHz of 915.000; board 2 is proven to respond to
energy at its own connector.  Cabling them together leaves no antenna, no
path loss and no instrument in the way.
.PP
The level is safe and worth stating because this document has been wrong
about saturation once already.  PA_CFG2 at the table's 0x4f is -10dBm at
the pin, and a CC1120's receiver takes about +10dBm before it is at risk
\- twenty decibels of margin.  The AGC covers the range easily; the
"saturation" this document withdrew was a cleared AGC register and not a
real overload, and -10dBm cabled is an ordinary strong signal.
.PP
If board 2 syncs on that, the receive path works and every negative on
this bench has been the antenna path.  If it does not sync on a -10dBm
cabled 2-FSK packet from a part that is proven to be transmitting one,
the receive path is broken and that is plan item 3's answer.
.PP
.B "Board 1 radiates; board 2's antenna path does not receive.  That is the whole of what is left."
Measured with the carrier turned on by its own ctl write and
.I held
across the sweeps, off before and off again after, on a tinySA whose
antenna was first checked against known references \- the 440MHz
repeater at -79.2dBm and the FM band at -47.7:
.DS
.CW "carrier OFF        floor -121.9   peak -103.4  (random bin, noise)"
.CW "carrier ON held    floor -114.9   PEAK  -48.9  at 914.99755 MHz"
.CW "carrier ON held    floor -115.4   PEAK  -48.4  at 915.00379 MHz"
.CW "carrier OFF again  floor -122.4   peak -102.9  (random bin, noise)"
.DE
Fifty-five decibels, appearing on command and going away on command,
within four kilohertz of where it was told to be.  Board 1's transmitter
and its antenna both work.
.PP
Board 2, antenna fitted, probing the same frequency while that carrier
was held, read
.B "floor -108 peak -101 duty 1% bursts 3"
against its own idle
.BR "floor -108 peak -100 duty 1% bursts 2" .
No change at all.
.PP
So the four links in the chain now stand as:
.IP \(bu 3
board 1's transmitter: proven, -32dBm modulated packets and a -30dBm
carrier into a cable.
.IP \(bu 3
board 1's antenna path: proven, +55dB over the air to a verified
receiver.
.IP \(bu 3
board 2's receiver at its own connector: proven, a cabled generator
raising its floor fifteen decibels.
.IP \(bu 3
board 2's antenna path: FAILS.  A signal a third receiver hears at
-48dBm produces nothing measurable.
.PP
That is a u.FL connector, the pigtail, or the antenna on board 2's ccRF
click, and it is the only unverified element remaining.  Everything this
document has chased today \- saturation, calibration, sync thresholds,
preamble registers, the sockets, the reset verb \- sat downstream of it.
.PP
Two of those were real and are fixed:
.B reset
reapplies the register table now, and the driver counts
.B sent
for packets the part never radiated, which
.B txtrace
exposes.  The rest were instruments believed without a baseline.
.PP
.B "The antenna swap cleared the antenna and the pigtail, and left board 2's receiver itself."
With board 1's known-good antenna assembly moved onto board 2 and the
carrier held off, on and off again:
.DS
.CW "board2  carrier OFF        floor -108  peak -101"
.CW "board2  carrier ON held    floor -108  peak -101"
.CW "board2  carrier OFF again  floor -108  peak -101"
.DE
Zero decibels, from an antenna that had just delivered +55dB to a tinySA.
.PP
And a pattern across the whole day's figures is now worth stating,
because it was visible all along and was not looked at: board 2's probe
peak has read between -100 and -105 in
.I every
condition recorded \- idle, with a generator cabled into it, with board 1
at -10dBm, with board 1 at +14dBm, over the air and on a cable.  It has
never moved.  Its floor has moved, once, from -122 to -107 when a
generator was cabled on.  A number that does not respond to a
twenty-four decibel change in stimulus is not measuring the stimulus.
.PP
So "board 2 hears nothing" may be "board 2's RSSI is pinned near -102 and
cannot report what it hears", and those are different faults with
different fixes.  The driver's own
.B rssioffset
is an unverified -102 taken from a TI example, and -102 is suspiciously
close to where this number sits.
.PP
What separates them is the detector pins rather than the number:
PKT_SYNC_RXTX and PQT_REACHED come from the part's own logic and not from
the RSSI arithmetic.  Both have read zero throughout, which is consistent
with either.  What has not been tried is carrier sense with a threshold
set well ABOVE the pinned value \- if the pin still asserts with
.B csthr
at -60, the part is hearing something the arithmetic is hiding; if it
goes quiet, the part is genuinely deaf.  That is one ctl write and it has
not been done.
.PP
.B "ITEM 3, ANSWERED: with 50dB of margin and a verified transmitter, board 2 receives no packet at all."
Everything in the earlier attempts was confounded by level or by a
configuration that had silently changed.  This measurement verifies
board 2's frequency immediately before and after every reading, holds
board 1's carrier by its own ctl write, and brackets it with the carrier
off on both sides.
.PP
Board 1 at +14dBm \- PA_CFG2 0x7f, the 24dB the driver's table has never
used:
.DS
.CW "                   floor  peak  duty   rssi"
.CW "carrier OFF         -109   -95    0%   -106"
.CW "carrier ON held      -69   -57   96%    -61"
.CW "carrier OFF again   -110  -106    9%   -107"
.DE
Thirty-eight decibels, on command and off command, with the frequency
read back as 915000000 at every step.  Board 2 hears the carrier at
-57dBm, about fifty decibels over its own floor.
.PP
Then ten packets, written one at a time to
.B /dev/radio0/data
on board 1, which is proven to reach TX and reports
.B "marc 0x40"
and
.B "left 0"
for each:
.DS
.CW "recv 0   crcerr 0   lastrx none"
.DE
Not one packet.  Not one CRC error.
.B lastrx
has never held anything.
.PP
That is the answer.  The receive path does not detect a packet from a real
CC1120 transmitter with fifty decibels of margin, at a matched rate,
deviation, bandwidth and sync word, with carrier sense asserting 96 per
cent of the time.  Every earlier negative on this bench was taken without
a known transmitter or without a known level; this one has both, measured,
with the stimulus switched on and off inside the same minute.
.PP
What this does NOT yet say is why.  The candidates still standing, in the
order they should be tried, all now testable because the signal is ample:
.IP \(bu 3
SYNC_THR.  The driver's table leaves it at 11 and no ctl verb changes it;
30 syncs on noise.  With fifty decibels of margin the useful range between
them can be swept for the first time, and the payload checked against
INFERNO-BEACON rather than counted.
.IP \(bu 3
The sync word's bit order or endianness.  Board 1 writes 0x930b into
SYNC15_0 and board 2 hunts the same registers, so a transmitter and
receiver that disagree about bit order would both be "correct" and never
match.  That has never been checked against a third party.
.IP \(bu 3
The preamble length.  PREAMBLE_CFG1 reads 0x14, four bytes of 0xAA, which
is TI's reset value and short; PQT has been seen to fire only occasionally
even with a strong signal.
.PP
.B "RETRACTION: the SYNC_THR sweep is void past threshold 14."
Board 2's console ends at
.B "reg 0x08 0x4e"
\- threshold 14 \- with no panic and no further output, so it stopped
running commands there and the rows for 17, 20, 23, 26 and 30 are one
stale
.B stats
read repeated.  That is why every row was identical, and why "SYNC_THR is
ruled out" cannot be said: only 11 and 14 were measured.
.PP
That is the third result thrown away for the same reason, after a
.B csthr
sweep taken while the board had silently rebooted onto 868MHz and a
saturation reading that was a cleared AGC register.  In each case a
one-off script read the screen without checking the board was still
running what was typed at it, and the stale text parsed cleanly into
numbers.
.PP
.B tools/radio/twoboard.py
now holds the discipline where it cannot be skipped: every
.I read
is bracketed by liveness marks and raises rather than returning,
.I expect
voids a measurement whose registers no longer hold what they were set to,
and
.I reaches_tx
reads txtrace element 4 because the driver counts
.B sent
whether or not the part entered TX.
.PP
What survives of the evening, measured with the frequency verified at
every step and the carrier held: board 2 hears board 1's carrier at
-57dBm, fifty decibels over its floor, and receives no packet at all \-
.BR "recv 0, crcerr 0, lastrx none" .
That stands.  Which thresholds, if any, change it is now an open question
again.
.PP
.B "Two driver defects from the day's measurements, fixed."
.IP \(bu 3
.IR cc1120send ()
counted
.B nsent
whatever the part did.
.B txtrace[4]
is the state it settled into after STX and the driver read it, printed it
and ignored it, so a part that went into CALIBRATE and returned to IDLE
without reaching TX reported a successful send \- counter, MARC_STATUS1
and the write's return value all agreeing.  84 packets were written that
way while a tinySA saw nothing on the channel.  A write that did not
reach the air now fails and increments
.BR txnever .
.IP \(bu 3
Rejecting anything-but-TX was the first attempt and broke every transmit
under
.IR qemu ,
whose model transmits inside the strobe and is back in IDLE before that
loop looks.  The three states are 2 for TX on working silicon, 4 for
CALIBRATE on the fault, and 0 for the model, so CALIBRATE alone is
rejected.
.IP \(bu 3
SYNC_THR could not be set at all.  The table leaves it at 11 and the
.B sync
verb preserves the low five bits when it writes SYNC_MODE, so the only
way to change it was a raw
.B "reg 0x08"
write with the mode bits worked out by hand.
.B "syncthr 0..31"
now does it with the range checked.
.PP
Verified under qemu, and
.B twoboards.sh
still passes both halves.
.PP
.B "Two of the three candidates for the sync failure, examined."
The sync word's bit order is
.I correct
and that candidate is closed by review: a sixteen-bit word goes to SYNC1
and SYNC0, which is what SYNC_MODE 2 reads, with the most significant
byte in SYNC1, and the mode is written into bits 7:5.
.PP
The third is a real gap and is not closed.
.B PREAMBLE_CFG1
is never written by this driver \- it is in neither table and no verb
touches it \- so the preamble length is whatever the part's reset default
is.  That is the same class of defect as the two already found here,
SYNC_MODE left at zero and a sync word written to registers the part was
not reading, and in both cases the reason was trusting a reset value.
Changing it wants SWRU295E open at the NUM_PREAMBLE encoding rather than
a recollection of it; decoding a bit field from memory is how the sync
bug happened.
.PP
Also unexamined, and the more likely of the two: the driver's
.BR rate ,
.B deviation
and
.B bw
verbs write three registers and leave the dependent demodulator settings
\- AGC_CFG1 and AGC_CFG0, AGC_REF, DCFILT_CFG, IQIC \- at the table's
values, which were computed for the part's 1200-baud default.  SmartRF
Studio emits those as a group for a given rate.  Nothing in
.I qemu
models any of them, which is why
.B twoboards.sh
passes while silicon does not, and the plan's own earlier note that the
model "does not exercise the radio itself" is the same point.
.PP
.B "SYNC_THR and the rate hypothesis are both ruled out, properly this time."
Swept with
.B tools/radio/twoboard.py
\- every read bracketed by liveness marks, the frequency asserted before
and after each row, and the transmitter checked to reach TX by
.B txtrace
element 4 rather than by its
.B sent
counter:
.DS
.CW "SYNC_THR   8 11 14 17 20 23 26 29 31"
.CW "recv       0  0  0  0  0  0  0  0  0"
.CW "crcerr     0  0  0  0  0  0  0  0  0"
.DE
And the dependent-register hypothesis fails too.  Run at the part's own
native configuration \- rate 1200, deviation 3997, bandwidth 25000, which
is what the AGC, DCFILT and IQIC values in
.I cc1120cfg[]
were computed for and therefore the one self-consistent setting \- the
result is identical to the 9600/20000/50000 used all day:
.B "recv 0, crcerr 0"
with
.B "txtrace 1 0 0 0 2 0"
in both, so the part reached TX each time.
.PP
.B "And both parts are configured alike, byte for byte."
Read off the silicon rather than from the table:
.DS
.CW "              board1   board2"
.CW "PREAMBLE_CFG1   0x14     0x14    (a preamble IS sent)"
.CW "PREAMBLE_CFG0   0x2a     0x2a    (PQT enabled)"
.CW "SYNC_CFG1       0x4b     0x4b"
.CW "PKT_CFG2        0x04     0x04"
.CW "PKT_CFG1        0x05     0x05"
.CW "PKT_CFG0        0x20     0x20    (variable length)"
.CW "MDMCFG1         0x46     0x46"
.CW "MDMCFG0         0x05     0x05"
.DE
So the failure is not an asymmetry between the two parts, and the
preamble is not absent.
.PP
That read found one real bug, which is committed: PKT_CFG1's bit 0 is
APPEND_STATUS, so the part appends two bytes to every received packet,
and the receive path read the payload and stopped \- leaving them for the
next packet's read to take one as its length.  It needs two received
packets to show, so this bench could never have seen it.
.PP
What is left to try, and the only one of the three candidates still
standing: the driver has
.B "serial on"
for the part's transparent mode, where the packet engine is out of the
path and the demodulated bits come out on a pin, and it has
.BR gcapture ,
.B ghist
and
.B runs
to sample that pin.  A locked 2-FSK receiver fed an alternating preamble
should show runs clustered at one symbol period \- 104us at 9600 baud,
833us at 1200 \- and a receiver that is not locking should show short
random runs.  That distinguishes "the demodulator never recovers bits"
from "it recovers them and the packet engine rejects them", which is the
question everything else has failed to settle.
.PP
.B "Transparent mode's serial outputs are dead on both parts, and that blocks the last diagnostic."
The verbs engage the mode:
.B "serial on"
moves PKT_CFG2 from 0x04 to 0x07, MDMCFG0 from 0x05 to 0x0d with
TRANSPARENT_MODE_EN set, and IOCFG3 from 0x11 to 0x09, all three
restoring on
.BR "serial off" ,
and the verb strobes SFRX and SRX so the part is receiving.
.PP
The pin does not move.  Over 256817 samples at 1.227us, with the far
board idle and again with it transmitting continuous random data at
+14dBm:
.DS
.CW "SERIAL_RX  (0x09)    0 of 256817 high"
.CW "SERIAL_CLK (0x08)    0 of 256824 high"
.DE
SERIAL_CLK is the recovered bit clock and should run at the symbol rate
whatever the data is.
.PP
The controls say this is not a broken board.  The same pin on the same
board, selected to carrier sense, reads
.B "99% high, 252992 of 254224"
\- so the GPIO, the sampler and the console path all work.  And the other
board behaves identically, SERIAL_RX 0 of 256804 and SERIAL_CLK 0 of
256810, so two parts fail the same way.  TRANSPARENT_INTFACT is not it
either: MDMCFG0 bits 5:4 swept through 0x0d, 0x1d, 0x2d and 0x3d with an
RX strobe after each gave 0 per cent every time.
.PP
The hypothesis to check first, and the reason this waits for SWRU295E:
that the part routes SERIAL_CLK and SERIAL_RX only to particular GPIOs,
and that GPIO3 \- the one a ccRF click wires to the MCU, and so the only
one this driver can read \- is not among them.  That would make these
verbs unusable on this board by construction rather than by
misconfiguration.  Guessing a GPIO mapping from recollection is how the
sync-word bug happened.
.PP
.B "The two crystals are 64ppm apart, which is wider than the receive filter -- and compensating it does not fix reception."
Measured by keying each board in turn into the same tinySA in one
session, so the instrument's own error cancels in the difference, and
with both boards carrying the same -3550ppb so the difference is purely
their crystals:
.DS
.CW "board 1  commanded 915.000000  carrier 915.019581  (+19581 Hz)"
.CW "board 2  commanded 915.000000  carrier 914.960906  (-39094 Hz)"
.CW "difference                                -58675 Hz = -64.13 ppm"
.DE
Repeatable \- a wide pass at 30kHz resolution and a narrow one at 3kHz
agree for both boards, and the levels, -43 and -55dBm, match what each
board has measured at before, so neither peak is an interferer.
.PP
Sixty-four parts per million is far outside what two identical clicks
should show, and 58.7kHz is wider than the 50kHz receive filter.  That
looked like the whole answer: a signal outside the passband would leave
RSSI and carrier sense responding to the energy, PQT firing on the skirt
and sync never firing, which is the pattern recorded exactly \- and it
would explain the 1200-baud case failing worse with its 25kHz filter.
.PP
It is not the answer.  Tuning board 2 up by the measured offset, so its
passband centres on board 1's actual carrier, changes nothing:
.B "recv 0"
and
.B "crcerr 0"
at 915.000000, at the compensated 915.058675, and at 915.040000 half way
between.
.PP
Two things are known now that were not.  The crystals really are 64ppm
apart, which settles the calibration question: the
.B .ppb
of -3550 in
.I spistm32f4.c
is board 1's and is wrong for board 2 by about that much, and no single
image can be right for both \- the
.B ppm
verb exists and each board should be corrected when it is driven.  And
the frequency offset is not what stops the receiver, because the receiver
still receives nothing with the signal centred in its filter.
.PP
At 915MHz one part per million is 915Hz, so 64ppm is 58.7kHz and a 50kHz
filter is plus or minus 25.
.PP
.B "Board 2 calibrated, and the strongest form of item 3's answer."
The crystal error derived from the two-board difference, then applied and
measured:
.DS
.CW "ppb -3550 (board 1's)   carrier 914.961024 MHz  (-38976 Hz)"
.CW "ppb +60300 (measured)   carrier 915.019822 MHz  (+19822 Hz)"
.CW "                        moved   +58798 Hz"
.DE
against a prediction of +58442, so the arithmetic and the part agree to
within 356Hz.  Board 1 reads 915.019581 on the same instrument, so
correctly calibrated the two are
.B "241 Hz"
apart.
.PP
So
.B .ppb
= -3550 in
.I spistm32f4.c
is board 1's, is wrong for board 2 by 64ppm, and no one image can be
right for both.  The
.B ppm
verb sets it at runtime and that is where it belongs.  Uncorrected, the
pair cannot hear each other even in principle: 64ppm is 58.7kHz and the
filter is 50.
.PP
And with board 2 on its own correction, the carriers 241 Hz apart, both
at rate 9600, deviation 19958, bw 50000, sync 0x930b, csthr -104,
SYNC_CFG1 0x4b, board 1 at +14dBm and confirmed to reach TX:
.DS
.CW "recv +0   crcerr +0   rssi -16   lastrx none"
.DE
Ten packets, and an RSSI of -16dBm is some eighty-five decibels over this
receiver's own floor.
.PP
.B "Level is eliminated.  Frequency is eliminated."
With SYNC_THR over 8 to 31, the rate and bandwidth dependents at the
part's own self-consistent setting, the sync word's bit order by review,
and any asymmetry by reading eight registers off each part, what is left
is the demodulator's own output \- and that is exactly what transparent
mode will not show on either part.
.PP
.B "SWRU295E settled it: SYNC_MODE was in the wrong register, and the spare bits were PQT_GATING_EN."
The user guide is on this machine and the register tables say:
.DS
.CW "SYNC_CFG1 (0x08)   7 RESERVED7"
.CW "                   6 PQT_GATING_EN"
.CW "                   5 RESERVED5"
.CW "                 4:0 SYNC_THR          reset 0x0A"
.CW "SYNC_CFG0 (0x09)  7:5 unused"
.CW "                 4:2 SYNC_MODE         reset 101b"
.CW "                 1:0 SYNC_NUM_ERROR    reset 11b"
.DE
This driver wrote SYNC_MODE into SYNC_CFG1 bits 7:5.  Two faults from one
write, and between them they account for every negative in this
document.
.PP
SYNC_MODE was never set.  It stayed at 101b, which the encoding gives as
thirty-two bits from SYNC31_0, so the part has been hunting a
thirty-two-bit word while the driver wrote sixteen into SYNC1 and SYNC0
and left SYNC3 and SYNC2 at whatever they held.
.PP
And mode 2 shifted up by five is 0x40, which is PQT_GATING_EN.  Asking
for a sixteen-bit sync word turned on, in the guide's words, "the
demodulator will not start to look for a sync word before a preamble is
detected".  PQT_REACHED asserts on about two tenths of one per cent of
samples here, so sync search was gated behind a detector that almost
never fires.  It is cleared explicitly now.
.PP
Confirmed correct against the same tables, so that these are closed and
not merely unexamined: SYNC3 is 0x04 through SYNC0 at 0x07, and mode 010
is "16 bits [SYNC15_8: SYNC7_0]", which is SYNC1 and SYNC0 \- where the
driver writes a sixteen-bit word.  The word placement was always right;
only the mode was misplaced.  SYNC_THR is SYNC_CFG1 4:0 and a sync word
is accepted when its qualifier is below SYNC_THR/2, so a higher
threshold is more permissive \- which is what this bench found
empirically and is now confirmed.
.PP
.B PREAMBLE_CFG1
closes too, and is not a fault.  Its reset 0x14 decodes as NUM_PREAMBLE
0101, which the table gives as
.I three
bytes \- not the four guessed at earlier \- with PREAMBLE_WORD 00, which
is 0xAA.  So a preamble is sent and the driver's never writing the
register was harmless.
.PP
And the transparent-mode dead end was one by construction: "if sync word
detection is enabled (SYNC_MODE != 000) the serial clock will not be
output on the GPIO before a sync word is transmitted/received".  The
serial pins sit downstream of sync detection, so they could never have
shown why sync was failing.  That is the third indicator this session
that was downstream of the fault it was being read for, after the lamp
behind the radio's ctl file and the RSSI behind a cleared AGC.
.PP
.B "The SYNC_MODE fix was necessary and is not sufficient."
Both boards flashed with it and verified from their own registers:
.DS
.CW "              SYNC3 SYNC2 SYNC1 SYNC0  CFG1  CFG0  PRE1  PRE0"
.CW "board 1        0x93  0x0b  0x93  0x0b  0x0b  0x0b  0x14  0x2a"
.CW "board 2        0x93  0x0b  0x93  0x0b  0x0b  0x0b  0x14  0x2a"
.DE
SYNC_CFG0 0x0b is SYNC_MODE 010, sixteen bits, with SYNC_NUM_ERROR
disabled; SYNC_CFG1 0x0b is SYNC_THR 11 with PQT_GATING_EN clear.  Byte
for byte identical, and both correct for the first time.
.PP
Before the fix board 2 read SYNC_CFG0 0x17 and SYNC_CFG1 0x4b \-
SYNC_MODE 101, thirty-two bits, and PQT gating on \- which is the fault
exactly as SWRU295E predicted it, seen in silicon rather than inferred.
.PP
And the link still does not work.  With board 2 on its own +60300ppb so
the carriers sit 241 Hz apart, both at 9600/19958/50000, board 1 at
+14dBm and confirmed to reach TX by
.BR "txtrace 1 0 0 0 2 0" :
.DS
.CW "recv +0   crcerr +0   rxoverflow 0   rssi -19   lastrx none"
.DE
An RSSI of -19dBm is about eighty-seven decibels over this receiver's own
floor.  Eight packets, nothing received, not one CRC error.
.PP
So two registers that were provably wrong are now provably right and the
symptom is unchanged.  That is worth stating plainly rather than leaving
the fix looking like a solution: it was a real bug, found from the
datasheet after four candidates had been eliminated, and it was not this
one.
.PP
One earlier result is void and should be redone now rather than trusted:
the trial at the part's own 1200-baud configuration, which was meant to
test whether the AGC, DCFILT and IQIC values suit the rate, was run while
SYNC_MODE was still at thirty-two bits.  It could not have received
anything whatever the demodulator was doing.
.PP
.B "Board 2's console input is intermittent, and it is not the board."
Twice today board 2 has stopped running what is typed at it while its
output stayed perfectly readable \- a clean boot log ending at a prompt,
no panic, no
.BR Broken ,
no
.BR "allocb: no memory" .
Both times a fresh marker came back
.I zero
times, which means nothing typed is arriving at all rather than that a
shell has died: an echo would make it one.
.PP
So the host-to-board direction of the RS232 path fails and recovers.
A reset does not address it and was tried on the first occurrence, on my
diagnosis, before the marker count was being reported; the tooling now
distinguishes the two cases and says which.
.PP
It also accounts for several of the day's "board 2 died" events, and for
why the 1200-baud trial could not be redone: the test needs both consoles
for the few minutes it takes to configure two radios and send a handful
of packets.
.PP
.B "The 1200-baud trial, redone validly: the demodulator dependents are eliminated too."
The earlier run was void because SYNC_MODE was still at thirty-two bits.
Repeated with both boards correct, board 2 on its own +60300ppb, and
board 1 at +14dBm:
.DS
.CW "both at 1200/3997/25000     recv +0  crcerr +0  rssi -21"
.CW "both at 9600/19958/50000    recv +0  crcerr +0  rssi -19"
.DE
An RSSI of -21dBm is some eighty-five decibels over this receiver's floor.
So the AGC, DCFILT and IQIC values suiting the rate is not the
explanation either: the part's own self-consistent configuration fails
exactly as the experimental one does.
.PP
What has now been eliminated, each with the frequency asserted before and
after and the transmitter checked to reach TX: signal level, carrier
frequency, SYNC_THR over its whole range, the sync word's bit order, the
sync word's length and mode, PQT gating, the rate and bandwidth
dependents, asymmetry between the parts, and the GPIO selection the
receive interrupt depends on \- IOCFG3 read 0x06 on both boards through
the last rounds.
.PP
A latent bug found while checking that last one and fixed:
.B "serial off"
set IOCFG3 to carrier sense rather than restoring PKT_SYNC_RXTX, so after
any use of transparent mode the packet interrupt could not fire and
.B recv
would stay at zero until a reboot.  It did not affect the measurements
above, which were taken after reboots, but only by luck.
.NH 1
Item 3 answered: a packet crosses, and the fault was an interrupt edge
.PP
.B "Ten packets sent, ten received, payload intact."
.DS
.CW "recv 10  crcerr 0  rxoverflow 0  last -41dBm"
.CW "intr high 10 low 10"
.CW "lastrx 8 bytes: 61 62 63 64 65 66 67 68"
.DE
which is
.CW abcdefgh ,
what
.B "txtest 8"
sends.  That is item 3: receive a packet that somebody else sent, on
silicon, between two clicker 2 boards with ccRF clicks.
.PP
.B "The fault was four lines in a board file, and the receiver had been working the whole time."
GPIO3 carries PKT_SYNC_RXTX and SWRU295E table 10 says what that is in
RX: "asserted when sync word has been received and de-asserted at the end
of the packet".  Two edges, and they are not interchangeable.  The rising
edge is the sync word \- at that instant the payload has not been
transmitted yet, let alone demodulated, and the FIFO is empty.  The
falling edge is the end of the packet, and it is the only moment at which
the packet is complete and can be read.
.PP
.CW os/inferno/stm32f407/spistm32f4.c
set
.CW EXTI_RTSR
and nothing else.  So
.CW cc1120interrupt ()
was called at every sync word, read NUM_RXBYTES, found it empty and
returned; the end-of-packet edge was never delivered and the packet was
never read.
.PP
.B "What the receiver's own registers said before the fix," with ten
packets sent from the other board:
.DS
.CW "MARC_STATUS1  0x80   RX finished successfully (a packet is"
.CW "                     in the RX FIFO ready to be read)"
.CW "MODEM_STATUS1 0xe1   SYNC_FOUND set, against 0x61 before"
.CW "NUM_RXBYTES   0x0b   1 length + 8 payload + 2 status"
.CW "recv          0"
.DE
The part had heard it, found its sync word, checked its CRC and put it in
the FIFO.  Every candidate eliminated over the last two days \- level,
frequency, SYNC_THR, the sync word's order and length and mode, PQT
gating, the rate and bandwidth dependents, asymmetry between the parts \-
was eliminated correctly.  None of them was ever the fault.
.PP
.B "Why none of the instruments could see it."
Everything the driver reports about reception is downstream of that
interrupt arriving.
.B recv
is incremented inside
.CW cc1120interrupt (),
so
.B "recv 0"
cannot distinguish a receiver that heard nothing from one that heard
everything and was never told.  Nor can
.B crcerr ,
or
.B rxoverflow ,
or
.B lastrx .
Six measurements over two days asked the question through that counter
and all six got the same answer for two different reasons.
.PP
The fix for that is in this commit too and is the more reusable half:
.B stats
now reports
.CW "intr high N low N" ,
the edges actually delivered to the MCU, counted at the top of
.CW cc1120interrupt ()
before any SPI and split by the level of the pin that raised them.  High
is a sync word, with nothing complete to read; low is an end of packet,
with something.  Those two numbers are upstream of
.B recv
and they say immediately which of the two faults is present: before the
change
.B low
was zero, after it ten.
.PP
.B "The negative control, and it is in the log."
The first attempt at this measurement was void \- the board had just been
flashed, which leaves it on its boot default of 868MHz, while the other
transmitted on 915.  Both counters stayed at zero and the live RSSI read
-108.  They do not count noise.
.PP
.B "Why every emulated test passed."
The qemu model raises the pin once the packet is in its FIFO and never
lowers it (tools/qemu-patches/0051), so there the rising edge does carry
data.
.I tools/radio/twoboards.sh
passed before this change and passes after it \- RADIO-RX-OK and
RADIO-SYNC-OK \- because an unused falling edge costs nothing.  A model is
a model of what somebody thought the part did, and
.I silicfg.sh
was built to separate the driver's software path from the part's
configuration precisely because that gap was suspected; it was in the
board file, which neither test touches.
.PP
.B "And the lesson that generalises past this part."
The thing that finally answered it was not a better radio measurement.
It was reading the receiver's own status registers \- MODEM_STATUS1,
MARC_STATUS1, NUM_RXBYTES \- rather than the driver's counters, because
the part reports what it did and the driver reports what it was told
about.  Those three registers were readable from a shell prompt through
the existing
.B regx
verb the whole time.
.PP
.B "Transparent mode, explained and fixed by the same datasheet."
MDMCFG1.FIFO_EN: "specifies if data to/from modem will be passed through
the FIFOs or directly to the serial pin", 0 being "data in/out through
the serial pin(s) (the FIFOs are bypassed)" and 1 "data in/out through the
FIFOs".  Its reset is 1 and this driver never wrote the register, so the
demodulator's output went where it always goes and GPIO3 had nothing to
carry whatever PKT_FORMAT and TRANSPARENT_MODE_EN said.  That is the whole
of the 405000 samples at one level across all four TRANSPARENT_INTFACT
settings, which had been put down to the click wiring GPIO3 and the mode
perhaps delivering on another pin.
.B "serial on"
now clears FIFO_EN and
.B "serial off"
restores it \- and restoring it matters as much, because with FIFO_EN
clear nothing reaches the RX FIFO at all.
.PP
.B "Both directions, forty packets each, every one received."
With both boards carrying the same kernel:
.DS
.CW "board1 -> board2   sent 40 recv 40 intr high 40 low 40"
.CW "                   crcerr 0 rxoverflow 0 last -41dBm"
.CW "board2 -> board1   sent 40 recv 40 intr high 40 low 40"
.CW "                   crcerr 0 rxoverflow 0 last -45dBm"
.DE
and
.B lastrx
on each side reads
.CW "8 bytes: 61 62 63 64 65 66 67 68" .
The edge counters account for every packet in both directions.
.PP
The levels, measured while the transmitter is actually keyed rather than
seconds after it stopped \- the live RSSI in the stat file is read at the
moment the file is read, which is what made an earlier reading of -108
mean nothing:
.DS
.CW "board1 keyed:  board2 sees -41dBm,  unkeyed -106"
.CW "board2 keyed:  board1 sees -45dBm,  unkeyed -109"
.DE
Sixty-odd decibels each way.
.PP
One earlier run is superseded rather than explained.  Before board 2 was
reflashed, with the fix on board 1 only and board 2 transmitting from the
kernel it had been carrying, board 1 took no interrupts at all \-
.CW "intr high 0 low 0" .
Board 2 was reflashed before this measurement and that configuration no
longer exists to re-ask, so what was different about it is not known;
what is known is that on the same kernel both directions carry every
packet.
.PP
.B "Item 6 on silicon: lil holds a descriptor across forty writes, and the shell's failure mode is real."
.I tools/radio/lilsilicon.py
runs on an stm32f407 with the Dis pool it really has, and
.B Lil
in
.I tools/radio/twoboard.py
keeps the marker rule in lil's own language \- a
.B print
between two writes, which is precisely what a shell's
.B "cat >file"
cannot do, because the marker would go into the file instead of being
run.
.DS
.CW "40 of 40 markers came back twice while the file stayed open"
.CW "the radio, read through lil: rssi -89 offset -90"
.CW "dir(\(dq/dis\(dq) returned, and lil still has its prompt"
.DE
The offset is the check that the forty writes were not merely accepted:
it boots at -102 and reads -90 afterwards.
.PP
.B "And the first attempt failed in a way worth keeping."
Typed at a console that had been in use for a long session \- dozens of
.B cat
and
.B echo
redirections \- the shell could not load
.I lil
at all:
.DS
.CW "; lil"
.CW "[Sh] Broken: \(dqout of memory: heap\(dq at 0x0 pid 4"
.DE
and that killed the shell and left the console undrained, which is the
state that ends at the reset button.  From a fresh boot the same command
works, with 38109 bytes free in the heap pool at the prompt.  So the
ceiling is real and it is the shell's accumulated heap and not
.IR lil 's
size: the thing item 6 was written around still happens, just not for the
reason it was written around.
.PP
The board was reset from its own console rather than by hand \- ^R twice
running, which
.I os/inferno/port/devuart.c
handles in the uart receive interrupt precisely because that is the last
thing working on a board in this state.  The same escape is how both
boards were put into their bootloader to be flashed for this item and the
last, with no button pressed.
.PP
.B "The cost, measured on silicon rather than on the model."
The same forty ctl writes through each, on the same board, through the
same console, with
.B /dev/memory
read before and after:
.DS
.CW "                     allocations   per write   live heap"
.CW "sh   echo ... >ctl         +5856       146.4          +1"
.CW "lil  one descriptor         +340         8.5           0"
.DE
Seventeen to one, and
.I lil 's
figure is the pessimistic one: its forty writes each had a
.B print
of a liveness marker between them, which is forty extra statements the
shell's forty redirections cannot have at all.  Per statement rather than
per write it is about four.
.PP
Both survive, which is the same answer the model gave; what the model got
wrong was the size of the difference.  Under qemu
.I lilvsh.sh
measured 141 allocations per redirection against 51, and on silicon it is
146 against 8.5 \- the shell's number carries over almost exactly and
.IR lil 's
is six times better than the model made it look.  A model of a console
and a pool is not a console and a pool.
.PP
.B "Transparent mode works on silicon, and it is not the detector it was wanted as."
With
.B MDMCFG1.FIFO_EN
cleared, the three registers read back off the part each time, and the
keyed and unkeyed cases alternated four times:
.DS
.CW "mode off            0.0% high, the pin parked"
.CW "mode on, quiet      49.0 to 52.5% high, 1613 runs in 2s"
.CW "mode on, keyed      46.8 to 47.4% high, 1206 runs in 2s"
.DE
So the pin moves, where before the fix it did not move at all \- half a
second, 405000 samples, one level, at all four TRANSPARENT_INTFACT
settings and with SERIAL_CLK tried on two other pins.
.B "The earlier conclusion that what this board could not rule out was the pin is retracted: the pin was never the problem."
.PP
But the two sets overlap, and the run lengths pile into the same
512-sample bin either way \- 610 to 632 microseconds against the 833 a
1200-symbol second gives.  The slicer has no squelch, so with nothing
arriving it slices noise into roughly random bits at roughly half duty,
which is what it does with a random-data carrier too.  The keyed set is
tighter and has fewer and longer runs, 1206 against 1613, which is the
shape real data would have; four readings four points apart is a hint and
not a detector.  So "noise has no such pile", written here and in
.IR radio (3),
is false on this bench and is withdrawn.
.PP
.B "Two method failures in getting that number, both of the same kind."
First,
.B gread
right after
.B "serial on"
can read 0.0 per cent, and one run gave 0.0 quiet against 52.2 keyed \-
which reads as a clean detection and is settling.  The next run gave 43.1
against 46.6.
.B "A reading that exactly equals a degenerate baseline is as likely to mean the instrument was not ready as that the channel was empty,"
which is rule 2 of this bench written down again in a new disguise.  The
script now alternates four times.
.PP
Second, the histogram parser looked for two bare columns where the driver
prints
.CW "<bin>: low <n> high <n>" ,
matched nothing, and reported "runs 0" for a pin
.B gread
had just measured as 52 per cent high.  A parser that cannot fail to
match is one more instrument that lies by agreeing with the hypothesis,
and it agreed with this one for two whole runs.
.PP
.B "And a flash that reports success is not evidence that the board runs what was flashed."
Both boards were reflashed for this and both clients printed McuType,
EraseBlock, BootStart and exited zero \- and board 2 was still running the
previous kernel, which the harness caught because it asserts the register
the new kernel writes:
.B "serial on"
left
.B MDMCFG1
at 0x46.  That is not a part refusing the write, which was checked
separately \-
.CW "reg 0x12 0x06"
takes and sticks at a prompt.  Reflashing that board alone put the new
kernel on it and
.B "serial on"
then read 0x06.
.B "The only evidence that a flash took is behaviour that only the new kernel has;"
tools/radio now has that check as part of the measurement rather than as
a thing to remember.
.PP
.B "Item 7 done on silicon: radiocal(1) measures the slope off the two boards themselves."
Forty packets over eight rungs, every one received, nothing lost and no
CRC error:
.DS
.CW "ramp  nominal   got lost crcerr   RSSI mean least most"
.CW "  63   +14.0      5    0      0     -30  -31  -30"
.CW "  55   +10.0      5    0      0     -33  -33  -33"
.CW "  47    +6.0      5    0      0     -37  -37  -37"
.CW "  39    +2.0      5    0      0     -41  -41  -41"
.CW "  31    -2.0      5    0      0     -45  -45  -45"
.CW "  23    -6.0      5    0      0     -48  -49  -48"
.CW "  15   -10.0      5    0      0     -53  -53  -53"
.CW "   7   -14.0      5    0      0     -56  -56  -56"
.CW ""
.CW "slope 0.949 dB of RSSI per dB of transmitter, over 8 rungs"
.DE
.PP
.B "Three independent ladders now, and they agree."
The tinySA's attenuator, cabled into the click, gave 0.930 over 24dB.
.I paladder.py ,
driving the same PA field from the host and reading one
.B last
RSSI per rung, gave 0.935 over 24dB.
.I Radiocal
on the boards, reading every packet's own RSSI out of
.B pkt 's
header, gives 0.949 over 28dB.  A real attenuator stepping a real
generator and a transmitter's own power field, measured through two
different paths, land within two per cent of each other \- which is as
close to separating the two factors as this bench can get.
.B "An earlier version of this sentence ended \(dqwithout the u.FL adapter item 2 wants\(dq, and that was a stale claim repeated:"
see item 2, where the generator has in fact been cabled into the click.
What separating them actually wants is a source whose absolute level is
accurate at 915MHz.
.PP
The spread within a rung is nought to one decibel, which is this
receiver's repeatability, and it is only visible because
.B pkt
carries an RSSI per packet.  The stat file's
.B last
gives one sample a rung and cannot show it.
.PP
What the ladder does not reach: ramp 0, which the datasheet calls
-17.5dBm, is below the bottom of this run and
.I paladder.py
took 0 of 5 there with the RSSI one rung up still at -45dBm, sixty
decibels over the floor.  So that is not sensitivity, and what ramp 0
actually does to the amplifier is not known.
.PP
.B "Item 8's first stage done: the boards calibrate themselves and then talk."
.I Tools/radio/calibratedlink.py ,
with both boards reset first so the reading is the kernel's default and
not what a previous run left:
.DS
.CW "before, from a fresh boot: board1 ppb -3550, board2 ppb -3550"
.CW "  the same figure on both, which is the bug: it is board 1's"
.CW "  board1 radiocfg: ppm -3550  rssioffset -102  csthr -90"
.CW "  board2 radiocfg: ppm 60300  rssioffset -102  csthr -90"
.CW "after:  board1 ppb -3550, board2 ppb 60300"
.CW "  the two differ by 63850 ppb, the 64ppm the crystals are apart"
.CW ""
.CW "board2 recv +10 of 10  crcerr +0  last -53 dBm"
.CW "board2 lastrx: 8 bytes: 61 62 63 64 65 66 67 68"
.DE
and the host wrote no correction to either board: the same frequency
string to both, and the 64ppm came off
.B /lib/radio
by way of each board's own
.BR #P/uid .
.PP
Two things that had to be fixed to get there, both the same shape as the
morning's.
.B ppb
is in the stat file now, because the
.B ppm
verb prints on the console and a Dis program cannot read that, so
.I radiocfg
had no way to check that the figure it applied was the figure in force.
.B "Anything this driver can be told, it has to be able to say back"
\- which is the third time today that rule has come up, after PA_CFG2 and
after the interrupt counters.
.PP
And the first version of
.I calibratedlink.py
printed
.CW "board2 ppb 60300 (both the kernel's default, which is board 1's)"
on a board that had been given 60300 by a
.I radiocfg
five minutes earlier.
.B "A test that asserts the thing it exists to demonstrate is not a test."
It resets both boards now, and voids the run if they do not boot holding
the same figure \- because if they did, the kernel would not be carrying
one correction for two boards and there would be nothing to show.
.PP
.B "What stage one is not."
.B /lib/radio
is in devroot, served read-only out of flash, so a new measurement is an
edit and a reflash.
.I Radiocal
measures and prints; nothing writes it down.  That is stage two and it
wants a writable flash sector.
.PP
.B "Item 9's first step: an AX.25 UI frame crosses the CC1120 on silicon."
.DS
.CW "board1  RAWSENT N0CALL-7>KA9Q-1 28 bytes"
.CW "board2  RAW N0CALL-7>KA9Q-1 UI pid 0xf0 info over-the-air"
.DE
by
.IR tools/radio/ax25silicon.py ,
with each board calibrated from its own
.B /lib/radio
entry and the host writing no correction.  The addresses, the UI control
byte, PID 0xf0 and the information field all came back.
.PP
It is
.I ax25raw (1)
on both ends, which is the point: it assembles the bytes from the
specification and writes them to
.BR /dev/radio0/data ,
so what crossed is an AX.25 frame and not this tree agreeing with
itself.
.I Ax25chk (1)
checks
.I ax25 (3)
against
.I ax25 (3)
and cannot catch an address field that no TNC would accept.
.PP
.B "And the first run of it was wrong in a way worth recording."
It reported that board 2 decoded nothing, and what board 2 had actually
printed was
.CW "ax25raw: RUNT 8 bytes"
\- an
.CW abcdefgh
left in
.BR #W/radio0 's
queue by the ten
.B txtest
packets of the previous measurement.
.CW "hear 1"
took that one and exited before the frame arrived.
.B "A receive queue outlives the program that filled it,"
which makes it a stale instrument like any other, and the tool resets
both boards now.
.PP
.B "Item 9's second step: the payload budget, and the claim it tests."
.DS
.CW "ax25up: /dev/radio0/data iounit 125"
.CW "ax25up: #a/0/data iounit 109      (no path)"
.CW "ax25up: #a/0/data iounit 95       (via WIDE1-1,WIDE2-1)"
.DE
.I Doc/ax25-plan.ms
records those as 239 and 225, which are an SX1276's 255 less 16 and less
30, and says the sizes come out of
.CW sys->iounit
rather than out of a constant in a test.
.B "That claim was testable only here,"
because this is the first packet device under
.B #a
whose payload is not 255 \- and it holds: the same code gives 109 and 95
off a carrier of 125.
.PP
.B "And the place it was not true was the test."
.I Ax25chk (1)
had
.CW "Nodigi: con 239"
and
.CW "Twodigi: con 225"
in it, so both of its
.B iounit
checks would have failed against a device that was right.  It computes
them from the carrier it attached now; the arithmetic stays, because that
is what is being checked, and what goes is the assumption about what it
is applied to.
.PP
.B "Two board limits found on the way, and neither is the radio's."
.IP \(bu 3
.B #a
starts three kprocs the moment a device is attached \- ax25recv,
ax25send, ax25tick \- and
.CW NPROC
was five.
.CW "ax25chk setup"
got as far as
.CW "addr-accepted ok"
and then
.CW "no procs for kproc" ,
taking the console with it.  Seven works and
.B "nine does not:"
at nine the board boots to a prompt and the first command gives
.CW "[String] Broken: \(dqout of memory: heap\(dq" ,
because KSTACKPREALLOC takes 36864 bytes of stacks out of 159744 and the
heap cannot run
.I echo
in what is left.
.IP \(bu 3
.B "And ax25chk still does not run on this board,"
at seven or at nine: it is 7737 bytes of instruction array with
twenty-odd checks and 239-byte buffers, and it dies with
.CW "out of memory: heap"
after attaching.  So
.I ax25up (1)
is the four lines of it that are a measurement rather than a self-test,
at 2351 bytes, and that is what produced the numbers above.
.PP
.B "One thing the error messages cannot say."
The path verb is
.B via
and the first version of
.I ax25up
wrote
.BR digipath ,
which came back
.CW "bad arg in system call"
\- the same refusal an unknown verb and a bad argument both give.  An
error that cannot distinguish a wrong name from a wrong value costs a
build and a flash cycle on a board.
.PP
.B "Two corrections and a thing left unmeasured, before any of this is repeated."
.IP \(bu 3
.B "Board 2's state is not known and no two-board measurement should be repeated until it is."
Its console input is dead again \- output readable, nothing typed
arriving, the adapter fault recorded above \- so ^R^R cannot reach it and
it cannot be reset without the button.  Worse, it was flashed several
times during the window when two stale
.I mikroe-uhb
clients were racing for the bootloader, so which image landed on it is
unknown.  The results above stand, because each was verified by
behaviour at the time it was taken \-
.CW "ppb 60300"
read back off the part, ten packets of ten received \- but
.IR calibratedlink.py ,
.IR ax25silicon.py ,
.I radiocalsilicon.py
and
.I paladder.py
will all now fail or answer staleley against it.  It wants a physical
reset and a
.I flashverify.sh
run before anything two-board is measured again.
.IP \(bu 3
.B "The spawned-reader anomaly is explained and was never a spawn."
It is written up above as unexplained; it is the three-times-fast guest
clock, and
.IR radiocal 's
own comment now says so.
.IP \(bu 3
.B "Ramp 0 has never been visited by radiocal."
.CW "-f 63 -l 0 -s 8"
stops at 7, so the table above covers +14 down to -14 and not the
-17.5dBm the datasheet gives for ramp 0 \- where
.I paladder.py
took 0 of 5 with the rung above still at -45dBm, sixty decibels over the
floor.  That is the one unexplained thing left in item 7 and one
.CW "radiocal -t -f 0 -l 0"
would settle whether ramp 0 disables the amplifier or does something
else.
.PP
.B "NPROC 7 costs the one redirection, and lil(1) is the way out."
Item 5 of this plan is "the one redirection, Done", and the board's
configuration file records at length how
.CW main_pool_pcnt
and
.CW heap_pool_pcnt
were chosen to make
.CW "echo rssioffset -90 >/dev/radio0/ctl"
work.
.B "Seven kernel processes takes it back."
From a fresh boot, with the pool figures identical to what five gave \-
they are ceilings and do not move \-
.DS
.CW "; echo reg 0x2b 0x40 >/dev/radio0/ctl"
.CW "[Sh] Broken: \(dqout of memory: main\(dq at 0x0 pid 1"
.DE
because the 8192 bytes the two extra stacks take are out of the arena
the fork wanted.
.PP
So this board can have
.B #a
or it can have
.BR > ,
and not both \- which is exactly the problem
.I lil (1)
was built for and the first time the case for it has been anything but
an argument.  A ctl write through
.I lil
is not a fork: the file is opened once into a variable and written to as
a statement.
.B "Item 6 is what makes item 9 possible on this board,"
and the fork-cost argument for
.I lil
\- withdrawn earlier in this document because ninety redirections two
seconds apart did not kill the shell \- comes back in a different and
sharper form: it is not that forking is slow, it is that on a board with
.B #a
attached there is no memory to fork with at all.
.PP
.B "Both boards now want the reset button, and the mechanism is worth stating exactly."
.CW exit ()
in
.I os/inferno/armv7m/main.c
branches on its argument: with zero it calls
.CW archreboot (),
which is a real reset, and with anything else it prints "Hit the reset
button", runs
.CW chandevshutdown ()
and spins.
.B "^R^R calls exit(0), so it reboots \- but only while the kernel is alive."
Once a panic has taken the other branch the console devices are already
shut down and nothing typed arrives at all, which is what both boards
read as now:
.CW live ()
sees the marker zero times, not once, so it is not the shell that is
gone but the uart handler that was echoing after it.
.PP
The route in is the one this document already describes and it was walked
again here: the shell dies, nothing drains the console queue, every
character typed allocates a block nobody frees, and the end of that is a
panic.  What is new is only that
.B "^R^R cannot rescue a board that has reached it,"
which
.I os/inferno/port/devuart.c
says in its own comment \- "it is not a general rescue" \- and which is
worth having measured rather than inferred.
.PP
Everything above was taken before that and each result was verified at
the time.  Nothing two-board can be repeated until both boards have been
reset by hand and reflashed with
.IR tools/f407/flashverify.sh ,
which is what proves which image is on them.
.PP
.B "NPROC is back at five, and seven was not a trade."
The entry above says seven costs the one redirection.  It costs more than
that, and the thing that showed it is
.I lil (1)
\- the program the entry had just named as the way out.  At seven:
.DS
.CW "; lil"
.CW "[Sh] Broken: \(dqout of memory: heap\(dq at 0x0 pid 3"
.CW "lil: little Limbo.  x := e; x = e; if(e){} else {} ..."
.CW "; print(\(dqhello\(dq)"
.CW "sh: /dis/lil.dis: exception: out of memory: main"
.DE
.B "lil prints its banner and then dies before it runs a statement."
So both of the things items 5 and 6 are about are gone, and seven is not
a board that does one thing at a cost; it is a board that does one thing
and nothing else.  All three, measured:
.DS
.CW "5   shell, redirections and lil all work.  #a cannot start:"
.CW "    \(dqno procs for kproc\(dq."
.CW "7   #a starts.  A redirection gives \(dqout of memory: main\(dq from"
.CW "    a fresh boot and lil dies after its banner."
.CW "9   the board reaches a prompt and the first command fails,"
.CW "    \(dq[String] Broken: out of memory: heap\(dq -- even echo."
.DE
Verified back at five on the board:
.CW "procinit conf.nproc 5"
and the one redirection works.
.PP
.B "A banner is not a running interpreter,"
and this is the second time today that distinction has decided a
question.  The console showed
.I lil 's
banner, which is a reason to think it started;
.CW Lil.live ()
in
.I tools/radio/twoboard.py
asks for a marker back
.I twice
and saw it once, which is the same rule that separates this console's
uart-interrupt echo from a shell that is running commands.  The banner is
printed before the first statement is read, so it is the echo of the
module loading and not evidence that it can do anything.
.PP
.B "And so the way to have #a on this board is not more processes: it is not to run a shell."
An init that attaches
.B #a
and does the work itself needs no fork and no second module in the pool,
and
.I os/inferno/init/armv7mbeacon.b
already does exactly that for the radio.  That is what item 9's remaining
steps want.
.PP
.B "Ramp 0 narrowed: the part transmits there."
Every value tried reaches TX with
.B txnever
at zero, read off the part itself:
.DS
.CW "ramp  PA_CFG2  power    txtrace          after STX"
.CW "   0  0x40     -17.5    1 0 0 0 2 0      TX"
.CW "   1  0x41     -17.0    1 0 0 0 2 0      TX"
.CW "   3  0x43     -16.0    1 0 0 0 2 0      TX"
.CW "   7  0x47     -14.0    1 0 0 0 2 0      TX"
.CW "  15  0x4f     -10.0    1 0 0 0 2 0      TX"
.DE
So the 0 of 5
.I paladder.py
took at ramp 0 is not the amplifier being disabled and not the part
refusing: the digital half works at every rung.  What is left is what the
amplifier actually radiates there, and the formula
.CW "(PA_POWER_RAMP + 1)/2 - 18"
is nominal \- the bottom of the field need not be linear.  Settling that
needs an instrument on the output, or board 2 back so the link can be
re-run at ramp 0.  Neither is available now.
.PP
.B "And the qualifier that belongs on all of it: from a fresh boot."
At five,
.I lil
runs statements and holds a descriptor across writes:
.DS
.CW "fresh boot"
.CW "  lil runs statements"
.CW "  ctl held open"
.CW "  0x40 -> pacfg2 0x40 ramp 0 power -17.5"
.CW "  0x41 -> pacfg2 0x41 ramp 1 power -17.0"
.CW "  0x43 -> pacfg2 0x43 ramp 3 power -16.0"
.CW "  0x47 -> pacfg2 0x47 ramp 7 power -14.0"
.CW "  0x4f -> pacfg2 0x4f ramp 15 power -10.0"
.CW "LIL-FRESH 5 of 5 ctl writes through one descriptor"
.DE
each one read back off the part.  But the same thing attempted after a
session of shell commands \- five stat reads and ten redirections, each a
fork \- gives
.CW "sh: /dis/lil.dis: exception: out of memory: heap"
on the
.I first
write.
.B "The heap does not come back,"
which is the ceiling this document already records for the shell and
which applies to
.I lil
as well: what
.I lil
avoids is the per-write fork, not the pool.  Every figure measured
through either of them has to say whether the board had just booted, and
the ones above do.
.PP
.B "Item 9's third step: a station with no shell on it, and what that cost to learn."
.I Os/inferno/init/armv7max25.b
is an init that applies this board's own calibration, attaches the radio
to
.B #a
by descriptor, takes its callsign and the station it addresses out of
.BR /lib/radio ,
and then beacons UI frames and prints what arrives.  Two of them under
qemu, by
.IR tools/radio/ax25inittest.sh :
.DS
.CW "instance a: #a up, carrier 125, ax25 109"
.CW "instance b: #a up, carrier 125, ax25 109"
.CW "instance a heard the other through #a: INFERNO-AX25"
.CW "instance b heard the other through #a: INFERNO-AX25"
.CW "control: alone, it came up and heard nothing"
.CW "AX25INITTEST-OK"
.DE
and the control matters: a lone instance must come up, beacon and hear
nothing, or "heard" is not coming from a packet.
.PP
.B "THE CLAIM IN THE ENTRY ABOVE WAS HALF WRONG AND IS CORRECTED."
It said the way to have
.B #a
on this board is not to run a shell.  An init does remove the heap
pressure \- no fork, no second module in the pool \- and it does
.I not
remove the process pressure:
.DS
.CW "NPROC 5, no shell:  \(dqno procs for kproc\(dq, repeating"
.CW "NPROC 7, no shell:  ARMV7M-AX25-UP, beacons, both hear"
.DE
Three kprocs is three slots whatever else is running.  So seven is right
for a station image and wrong for a shell image, and which image a board
carries is already selected by file \-
.CW "mk INIT=armv7max25" .
What is not selected that way is
.CW NPROC ,
because it is a constant in a header both images share; it belongs in
the config's data section beside
.CW main_pool_pcnt ,
which is how this tree picks a per-board value without a conditional.
Until it is there, a station image is built by editing one line of
.IR mem.h ,
and that is written in
.I mem.h
rather than left to be discovered.
.PP
.B "Three things found building it, each of which looked like something else."
.IP \(bu 3
.B "A guest reading its own serial number died."
.CW "bus fault ... bfar 1fff7a18"
in the init, which is the three-word read of the unique device ID.  The
F405 SoC in qemu maps flash, SRAM, CCM and the backup SRAM and nothing
else, so the whole system memory region at 0x1fff0000 is absent.  On
silicon the same code reads both boards' serials, so the driver was
right and the model had nothing there.
.I Tools/qemu-patches/0053
maps it, with the twelve bytes coming from a property so that two guests
can be told apart \- two that always answered alike could not exercise
the check a two-board harness makes with the serial.
.IP \(bu 3
.B "A bind that half worked."
.CW "sys->bind(\(dq#a\(dq, \(dq/net\(dq)"
succeeds and puts the device's files at
.BR /net/ctl ,
so the init then failed with
.CW "/net/ax25/ctl: file does not exist"
having attached the device perfectly.
.I Ax25 (3)'s
synopsis is
.CW "bind '#a' /net/ax25" ,
and the device paths need no bind at all, which is what
.I ax25chk (1)
and
.I ax25up (1)
use.
.IP \(bu 3
.B "Two stations beaconing at each other and hearing nothing."
133 frames out of one and 120 out of the other, both up, both with the
right payload budget, and neither heard one.
.B #a
matches an incoming frame against a conversation by the frame's
.I source ,
and both were addressing
.B QST
with the same callsign, so nothing matched.  Who a station addresses is a
fact about a bench rather than about a program, so it is a
.B peer
attribute in
.B /lib/radio
beside the callsign \- and that is also the test of the qemu serials,
since each guest finds the other's callsign only by looking itself up.
.PP
.B "And the reader is a library now."
.I Appl/lib/radiocal.b ,
behind
.IR module/radiocal.m ,
is the parser that was measured on silicon, lifted out of
.I radiocfg (1)
rather than rewritten.  Two callers \- a command at a prompt and an init
on a board that cannot run one \- and a format deserves one reader.
Checked by giving both the five cases the copy passed, including two
negative controls: byte-identical answers, with the one intended
difference that a malformed pair is now reported by
.I radiocal
rather than by
.IR radiocfg ,
which is accurate.
.PP
.B "The number is config data now, and the station runs on silicon."
.CW NPROC
was a constant in each armv7m board's
.IR mem.h ,
and
.CW "conf.nproc = NPROC"
in
.I os/inferno/armv7m/main.c
was its only user.  It is
.CW nprocwanted
in the config's
.B code
section now, beside
.CW main_pool_pcnt ,
which is how this tree picks a per-board value without a conditional \-
and the reason it had to move is that one board has two images wanting
different numbers.  All four armv7m boards keep the value their header
had: mps2 and teensy41 sixteen, nucleof303 eight, stm32f407 five.
.PP
.B "Shown to be the source, which is the part that matters."
Compiling with the same numbers it already had would prove nothing, so
the config was changed and the kernel followed: with
.CW "nprocwanted = 7"
the board boots
.CW "procinit conf.nproc 7" ,
and mps2 with its own sixteen boots sixteen in the same build.
.PP
.B "And the station on silicon,"
board 1 with
.CW "mk INIT=armv7max25"
and seven:
.DS
.CW "armv7m ax25 init"
.CW "ax25init: uid 2037303959315008002f0022"
.CW "ax25init: ppm -3550"
.CW "ax25init: carrier iounit 125"
.CW "ax25init: addr N0CALL-1"
.CW "ax25init: attached fd 4"
.CW "ax25init: conversation 0"
.CW "ax25init: addressing N0CALL-2"
.CW "ax25init: ax25 iounit 109, which is the carrier's 125 less 16"
.CW "ARMV7M-AX25-UP"
.CW "ax25init: beacon 1 ... beacon 25"
.DE
with
.CW "kstack high water 2424 of 4096" .
Everything in there except the two iounits came out of
.B /lib/radio
by way of the serial the part itself holds: the crystal correction, the
callsign, and the station it addresses.  It hears nothing, because the
station it addresses is board 2 and board 2's console is dead so it
cannot be flashed.
.PP
.B "There is no second config file and the reason is worth writing down."
The config format has no include \-
.I os/inferno/port/mkdevlist
reads sections and nothing else \- so a station config would be three
hundred duplicated lines that drift.  So a station image is two edits,
.CW "mk INIT=armv7max25"
and
.CW "nprocwanted = 7" ,
and
.I tools/f407/flashverify.sh
refuses the half of them:
.DS
.CW "flashverify: the board says kerndate 1790900496, nproc 5"
.CW "FLASHVERIFY-FAILED this init needs nproc 7 and the image has 5."
.CW "Set nprocwanted in os/inferno/stm32f407/stm32f407 and build"
.CW "again: at 5 the station reaches \(dqaddr\(dq and then \(dqno procs for"
.CW "kproc\(dq forever, which looks like a board that booted."
.DE
It also greps the generated
.I prog.s
and fails if the image does not carry the init it was asked for, because
mk has no dependency on a variable and building without the override
silently reverts a station image to the shell one.
.PP
The committed default is five and the shell init, because that is the
image a person uses and the one every tool in
.I tools/radio
drives.
.PP
.B "Item 9 is done: two real stations hear each other over the air through #a."
Both boards running
.I os/inferno/init/armv7max25.b
with no shell on either, and
.I tools/radio/ax25twosilicon.py
typing nothing at all \- it reads two consoles:
.DS
.CW "board1 uid 2037303959315008002f0022 ppm -3550"
.CW "       N0CALL-1 addressing N0CALL-2  carrier 125  ax25 109"
.CW "board2 uid 203730395931500800300022 ppm 60300"
.CW "       N0CALL-2 addressing N0CALL-1  carrier 125  ax25 109"
.CW "each addresses the other, corrections differ by 63850 ppb"
.CW ""
.CW "board1 sent 38, heard 19: INFERNO-AX25"
.CW "board2 sent 65, heard 18: INFERNO-AX25"
.CW "AX25TWOSILICON-OK both heard the other through #a"
.DE
Everything in those two lines except the iounits came out of
.B /lib/radio
by the serial each part holds: the crystal correction, the callsign, and
the station it addresses.
.PP
.B "And the radio's own counters say where the losses are, which is the point of putting them there."
.DS
.CW "board1: recv 43 crcerr 0 | heard 43"
.CW "board2: recv 61 crcerr 0 | heard 61"
.DE
.B "Heard equals recv on both, exactly."
So nothing is lost between the part and
.BR #a :
every packet the radio queued was matched to a conversation and handed
up, and no packet failed a CRC.  What is lost is on the air, which is two
half-duplex radios beaconing on one channel with no carrier sense \- and
that is item 9's fourth bullet, the first time this bench has had two
transmitters at once.
.PP
.B "A LIMBO REFERENCE DIES AT ITS LAST USE, NOT AT THE END OF ITS SCOPE, and that blocked this for an afternoon."
The first version of the init held its conversation's ctl file in a local
of
.CW init (),
which then runs forever \- so the variable is in scope for the life of
the station.  It is not
.I live
for it: nothing reads it after the last
.CW fprint ,
so the reference is dropped there,
.B #a
sees the conversation's ctl closed, and the conversation stops being
matched against incoming frames.  The data file, already open, goes on
transmitting perfectly.
.PP
A station that sends and never hears, with every visible thing right.
Measured by single-variable experiment on silicon, the other board
beaconing at it throughout:
.DS
.CW "without the reference kept:        53 beacons out, 0 heard"
.CW "with it, and nothing else changed: 30 out, 29 heard"
.DE
.B "That is the whole difference,"
and it was worth two builds and two flash cycles to know rather than
assume: the same run also had a
.CW "heard 1: ''"
in it \- a zero-length read counted as a frame \- and an attempt at a
two-conversation arrangement, either of which could have been credited.
.PP
.B "The two-conversation attempt is recorded because it looked like the fix."
.I Ax25chk (1)
connects in its
.B send
and announces in its
.BR recv ,
so the obvious reading is one conversation for each.  In one program that
is worse: with both open, a frame from the peer still matches the
.I connected
one, which is more specific than an announcer, so it lands on the
conversation the beacon loop writes to and nobody reads it.  Two
instances under qemu beaconed 130 and 118 frames and neither heard one.
An announcer is for a station that does not know who will call it; this
one does, because
.B /lib/radio
told it.
.PP
.B "A connected link between the two boards, and the error path is unreachable on this bench."
Item 9's last bullet.  The role is data \- a
.B role
attribute in
.B /lib/radio
saying
.B caller
or
.BR answerer ,
because a link has one of each and which board is which is a bench fact.
Absent, a station beacons UI frames, which needs no state machine and no
peer to answer, so that stays the default.
.PP
On silicon, board 1 calling and board 2 answering:
.DS
.CW "caller:   linked to N0CALL-2 on #a/0, iounit 109 of 125"
.CW "answerer: N0CALL-2 announced, waiting for N0CALL-1"
.CW "          accepted on #a/1"
.CW "          link 96: INFERNO-AX25-95"
.CW "caller:   sent 95, state connected retransmitted 0 rejin 0"
.CW "          rejout 0, radio sent/recv 96 recv 95 crcerr 0"
.DE
So SABM and UA crossed the air, ninety-six numbered I frames arrived in
order, and the ninety-five the radio received are the answerer's
acknowledgements.
.B "Nothing was retransmitted and nothing was rejected."
.PP
.B "WHICH IS A NEGATIVE, AND THE REASON IS STRUCTURAL RATHER THAN LUCKY."
UI mode on the same two boards lost heavily \- heard equalled the radio's
recv exactly on both and both were well below what the other sent \-
because both stations beacon on their own clock and collide.  A connected
link does not: only the caller sends data and the answerer sends
acknowledgements, so two half-duplex radios take turns by construction.
That is the case T2 was written for, and it is still unproven, now for a
better reason than before.
.PP
.B "And the error path stays unreachable at any transmit power."
A
.B txramp
attribute was added for exactly this \- a station's power belongs to it
like its callsign, and it is the one knob that can make a link lossy on
purpose.  At the bottom of the range the link is still perfect:
.DS
.CW "ax25init: pa 0x40 ramp 0 power -17.5dBm"
.CW "answerer took 96 frames, retransmitted 0 rejin 0 rejout 0"
.DE
the power read back off the part and not merely written.  Two boards a
few inches apart have sixty-odd decibels of margin and thirty-one and a
half decibels of attenuator does not spend it.  REJ, RNR and the
retransmission counter want either the boards separated or an attenuator
in the path, and neither is available here.
.PP
.B "One correction that follows from it."
.I Paladder.py
took 0 of 5 at
.B PA_CFG2
0x40 and this document called that unexplained, with the part known to
reach TX there.  A connected link at that same setting carries ninety-six
of ninety-six.
.B "So ramp 0 radiates usably and the earlier 0 of 5 was not the amplifier."
What it was is still not known; it is a single five-packet reading and
the thing it was taken with is not what is in front of me now.
.PP
.B "Two bugs found writing it."
.CW status ()
tested
.CW "ln[0:9] == \(dqreceived \(dq"
behind a guard of
.CW "len ln > 5" ,
which is a bounds error on any shorter line \- and the status file has
.CW "window 4"
and
.CW "n2 10"
in it.  The caller linked up, sent four frames the answerer received, and
died on the fifth, which from the far end is a link that stopped.  A
prefix test written out by hand five times with its own length guard each
time got it wrong once; it is one function now.
.PP
And the power was first read back by appending it to the radio line,
which ran past the width
.I screen 's
hardcopy keeps and was invisible \- so a read-back that had worked all
along read as one that had not.  It is a line of its own.
.PP
.B "Item 8's second stage done: a board can write down what it measured."
.B #P/cal ,
in
.IR os/inferno/stm32f407/calstm32f4.c ,
and the loop closed on silicon by
.IR tools/radio/calstore.py :
.DS
.CW "the store: used 0, free 16384"
.CW "  before: ppm        -3550   from /lib/radio"
.CW "appended 95 bytes: used 0 -> 95"
.CW "after a reset: used 95, unchanged"
.CW "  after:  ppm        -3551   from #P/cal"
.CW "CALSTORE-OK"
.DE
The last two lines are the only part that is not true of any file: a
figure in the store overrides the same figure in the image, and
.I radiocfg (1)
says which source each one came from, because a number from the file and
the same number from the store mean different things.
.PP
.B "This plan asked for a spare 128K sector and the part has none."
Measured against RM0090 table 5 with the image this tree builds: sectors
0 to 9 are all image, the image ends inside sector 10 at 0x080d9118, and
sector 11 is the HID bootloader, which is the only way back into the
board.
.B "What is spare is the tail of sector 10, and it has never been written, so it is still erased."
.PP
That suits the job better than a sector would.  Flash programming turns
ones into zeroes, so appending to erased flash needs no erase \- no
sector-erase driver, no wear levelling, and no window in which a power
cut leaves the store erased rather than merely old.  The end of the log
is the first 0xff byte: the content is
.IR attrdb (6)
text, which never contains one, so the store needs no header, no length
field and no superblock, and a reader that knows nothing about the device
can tell written from unwritten by looking.
.PP
.B "A reflash erases it, and that is the consequence rather than a defect."
The store is the tail of the sector the image ends in, so a new image
erases it; the run above started at
.CW "used 0"
on a board that had records in it before the rebuild.  A figure worth
keeping belongs in
.B /lib/radio
eventually and the store is what carries it until then.  The build is
what stops an image growing into it:
.I bin2ihex
is given the store's base, 901120, instead of the bootloader's 917504,
so an image that would overlap fails to convert.
.PP
.B "Two things it refuses, and both were exercised."
A write past the end \-
.CW "cal: 16384 bytes written of 16384, 28 more will not fit"
\- because silently truncating a calibration is worse than not storing
it.  And it reads back every byte it wrote and errors if the flash
disagrees, which is how a run under qemu reports honestly that nothing
happened:
.CW "cal: wrote 0x72 at offset 0 and it reads 0xff" ,
the model's flash being a read-only region.
.PP
.B "And a qemu gap that made the store read full on an empty board."
A rom region is zero filled and flash comes out of the factory all ones,
so everything outside what the loader wrote read 0x00 under qemu and
0xff on silicon \-
.CW "used 16384 free 0"
on a board that had never written a byte.
.I Tools/qemu-patches/0054
fills it before the kernel is loaded.  The write path stays silicon only,
because the region is still read-only there, and the driver's read-back
is what makes that visible rather than silent.
.PP
.B "One bug of my own, caught by the negative control."
Reading two sources means combining two results, and the first version
did it by comparing error strings: "noentry" from the file and an open
failure from the store matched no branch and came out nil, so a board in
neither source was reported as found with every figure absent \- which is
a calibrated board with no calibration.  It is a found flag now.  The
control that caught it is the one that asks what happens for a uid
nothing has heard of.
.PP
.B "Every transmit here has always gone through carrier sense, and a refusal was counted as a send."
SWRU295E 6.11: "when an STX or SFSTXON command strobe is given while
CC112X is in the RX state, the TX or FSTXON state is only entered if the
clear channel requirements are fulfilled (CCA_STATUS is asserted).
Otherwise, the chip will remain in RX."  This driver's table sets
.B PKT_CFG2 's
CCA_MODE to 001, clear when RSSI is below the carrier sense threshold,
and
.CW cc1120send ()
strobes STX from RX.
.B "So TX on CCA is not a feature anybody turned on here: it is what every transmit has been doing."
.PP
And a refused transmit leaves the part in RX, which the send path let
through: the packet was staged, the strobe was given, nothing went on the
air, and
.B sent
counted it.
.B "The same bug as the CALIBRATE one, in the same place, found the same way"
\- from the datasheet rather than from a symptom.  1 is RX and is
distinguishable from 2, which is silicon transmitting, and from 0, which
is the qemu model that transmits inside the strobe; so the check costs
the model nothing and
.I twoboards.sh
still passes both halves.  A busy channel is the ordinary thing a shared
channel does rather than a fault, so it has its own counter,
.B ccabusy
in the stat file, and its own errstr, and a caller that wants to retry can
tell it from a crippled synthesiser.
.PP
A
.B cca
verb sets CCA_MODE, and it exists as the control for a measurement rather
than as something to tune:
.B "how much carrier sense costs cannot be asked without being able to turn it off."
.CW "cca off"
is mode 000, always clear, a transmitter that talks over anybody.
.PP
.B "Measured, and it refuses nothing on this bench."
.DS
.CW "cca rssi  mode 1   40 of 40 radiated arrived, 0 deferred"
.CW "cca off   mode 0   40 of 40 radiated arrived, 0 deferred"
.DE
twenty from each board in each mode, interleaved.
.B "And this test does not contend, which is its limit and not its result."
.I Twoboard 's
.CW read ()
brackets every line with liveness marks, so each
.B txtest
is some twenty seconds after the last and the channel is quiet between
them.  What it measures is a transmitter with the channel to itself, in
both modes, which is the control.
.PP
So it does not settle whether this afternoon's UI-mode loss was refused
transmits.
.B "That wants both boards transmitting on their own clocks with no host pacing,"
which is
.I os/inferno/init/armv7max25.b
with no
.B role
in its entry, and
.B ccabusy
is what would report it.  Until that is run, the UI-mode loss has one
explanation fewer than it did and no new one.
.PP
.B "The contending measurement was not taken, and the reason is the bench."
Both boards would have to run
.I armv7max25
with no
.B role
in their entries, and board 2 refused three flashes in a row \- each time
with a bootloader answering and a client printing its whole summary, and
each time the board still running the image it had before:
.DS
.CW "flashverify: the image carries from ../init/armv7max25.dis"
.CW "flashverify: built, kerndate 1790943155"
.CW "McuType: 'STM32F4XX'   BootStart: 0xe0000"
.CW "flashverify: the board says kerndate 1790943023, nproc 5"
.CW "FLASHVERIFY-FAILED built 1790943155, the board is running 1790943023"
.DE
and neither board changed, checked on both consoles afterwards.  So this
is not the stale-client race found earlier in the day \- there were no
stale clients, and that race would have written the wrong image rather
than none.
.PP
.B "What is worth keeping is that the failure is visible at all."
Before
.I flashverify.sh
this would have been a measurement taken against the previous image and
believed, which is what happened three times earlier today before the
cause was found.  The guard reads the board's own boot line back and
refuses, so a bench that will not take a flash says so instead of
answering with yesterday's kernel.
.PP
Board 2's console input has been the unreliable thing on this bench all
along \- it has failed and recovered several times, output readable and
nothing typed arriving \- and ^R^R is how the bootloader is entered, so a
board whose input is intermittent is a board whose flashing is
intermittent.  Both boards are on verified images and the question stands
where it was.
.PP
.B "The offset is obtainable with what is on this bench, by substitution."
This document said for a day that it wants a connector, and before that
that it wants a calibrated generator.  It wants neither.
.PP
What it wants is a known level at the receiver's input, and the
instrument here that can be trusted for a level at 915MHz is the tinySA's
.IR input ,
not its output.
.I Tools/tinysa/README
has said so all along \- "a tinySA ULTRA at 100kHz resolution bandwidth
and no input attenuation is a calibrated receiver, while the CC1120's
RSSI is its own AGC's estimate with the manufacturer's reference offset
applied and no calibration of this board at all" \- and above 800MHz
.CW sweep ()
turns ultra mode on, which is the specified path for the input.  The
generator's problem is the opposite and has no such escape: its low
output path stops at 800MHz and there is no ultra mode for an output.
.PP
.B "So the trusted instrument is a receiver, and the method is substitution."
.DS
.CW "leg A   board 1 -> cable -> tinySA input: the TRUE power"
.CW "        at the cable's far end"
.CW "leg B   board 1 -> the SAME cable -> board 2's u.FL:"
.CW "        board 2's RSSI"
.DE
The cable's loss, its connectors and the transmitter's own uncalibrated
output are identical in both legs and cancel.  What is left is the
difference, which is how much this receiver's RSSI is out \- and that is
the offset.
.B "No generator is involved at all;"
the source is one of the boards, and it does not matter that its absolute
output is unknown, because leg A measures it.
.PP
.I Tools/radio/offset.py
is that, in two commands because the cable has to be moved between the
legs and nothing here can move it.  Leg A writes what it measured to a
file and leg B reads it back, so halves taken minutes apart are still
valid \- nothing in between changes \- while halves taken at different PA
settings are not, and the file carries the settings so leg B refuses when
they differ.  It voids a leg A peak less than fifteen decibels over the
floor, because that is not a carrier, and a leg B reading with
RSSI_VALID clear.
.PP
.B "And it will not key more than -10dBm into the instrument."
A tinySA's input is rated about +10 and this part will do +14, so the
ladder stops at PA_POWER_RAMP 15, which the datasheet's formula makes
-10dBm: twenty decibels of margin, and the tool refuses a higher rung
rather than leaving that to be remembered.
.PP
.B "What it needs that cannot be done from here:"
the cable from board 1 to the tinySA's input for leg A, and then the same
cable to board 2's u.FL for leg B.  Both legs run unattended once the
cable is where they need it.
.PP
.B "And the check for whether it is there earned its place on the first run."
Nothing else in the tool can tell a cabled input from an antenna, and a
leg A taken over the air produces perfectly plausible numbers and a wrong
offset \- which is the one failure this measurement exists to avoid.  The
level discriminates by tens of decibels, so leg A refuses a peak more
than twelve decibels under the nominal.  Run with the tinySA on its
antenna, which is where it was:
.DS
.CW "ramp 15  nominal -10.0  tinySA peak -55.81  floor -118.31"
.CW "VOID: -55.8 dBm is 45.8 below the nominal -10.0."
.CW "That is a radiated path, not a cable"
.DE
.B "Without that check this would have reported an offset of about 46 decibels,"
which is the path loss between two antennas and not the receiver's error
\- the exact mistake the whole substitution is built to avoid, made at
the first opportunity.
.PP
.B "Leg A taken, and three things learned getting it."
With the cable on the tinySA's input,
.CW "offset.py sa cabled"
gives
.CW "ramp 0  peak -78.69 dBm at 914993764, floor -119.19"
\- forty decibels over the instrument's floor, and inside the range where
this receiver is linear.  That is the true power at the cable's far end
and it is written down for leg B.
.PP
.B "One rung, because the carrier verb does not ladder."
The run started as five rungs and read
.B "exactly -30.19 dBm at ramps 3, 7, 11, 15 and 31"
\- five transmit powers spanning fourteen and a half decibels of nominal
\- then -78.69 at ramp 0.  So the carrier responds to
.B PA_POWER_RAMP
by forty-eight decibels between 0 and 3 and is flat across everything
above it.
.PP
.B "It is not the instrument,"
which was the first thing suspected.  Its own input attenuator was swept
0 to 30dB on the low path against FM broadcast and the reported level
moved less than two decibels \- which is a calibrated analyser behaving
correctly, because the level it reports is meant to be independent of its
attenuator.  (That also showed the cable was really on the input: FM
peaked at -100dBm, which is a cabled input and not an antenna.)  And
.I paladder.py
got a clean ladder over the same ramp range, -19 to -45dBm across 63 down
to 7, using
.I packets
rather than the carrier verb.
.B "So the carrier verb's random and infinite-length mode does not reproduce the power ladder that packet transmission does,"
which is a finding about the driver and not about this measurement.
.PP
.B "And an invented threshold refused good data twice."
.I Offset.py
began by refusing a leg A more than twelve decibels under the nominal, on
the reasoning that a cable cannot lose that much.  It refused a genuinely
cabled path at 20.8dB \- real loss in the pigtail, its connectors and a
transmitter under its datasheet figure.  Widened to forty, it refused
ramp 0 at 61.2dB, where most of the shortfall is the amplifier and not
the path.
.PP
The premise was wrong both times.
.B "A substitution cancels everything common to its two legs"
\- the cable, the connectors, and the transmitter's own uncalibrated
output \- so what the nominal says is irrelevant to the result, and a
threshold against it is a threshold against something the method does not
depend on.  The loss is reported now and judged not at all.  What knows
whether the cable is on is whoever moved it, which is why the subcommand
takes
.B cabled
and records it; what is checked instead is everything that can be, which
is that the peak is a carrier and not noise, that no two rungs read
alike, that the part holds the ramp it was given, and that leg B's RSSI
is valid.
.PP
.B "The shared-node arrangement: tried five times, coherent once, and that once was the outlier."
With board 2's u.FL cabled to the tinySA's input the cable has replaced
board 2's antenna, so it looked like one transmission line with the
receiver at one end and a calibrated instrument at the other \- both
reading the same node, with nothing to move between readings.
.I Tools/radio/offsetnode.py
is that.
.PP
.B "Its own control refutes it."
If the two really share a node then keying the transmitter moves both by
the same amount, and mostly it does not:
.DS
.CW "ramp 15   tinySA risen +14.00   board2 risen +41"
.DE
twenty-seven decibels apart, which is board 2 hearing board 1 through its
own board and package rather than through its antenna connector, with the
cable carrying almost none of it.  One run did have both rises agreeing
\- +23.5 against +21, and +16.5 against +15, giving an offset within two
decibels of the figure already in the driver \- and the three runs after
it found no rung where both heard the same carrier at all.
.B "One of five is an outlier and not a measurement,"
and the equal-rise check is what tells them apart.  It was not in the
first version, which is why that version printed "AGC_GAIN_ADJUST wants
about -101 where it holds -102" from a premise its own data falsified.
.PP
.B "Nothing is concluded about the offset from any of this."
The figures that appeared \- -101, -104, and a -58 from the run before
the quiet baseline existed \- are each from an arrangement later shown
unsound, and none is carried forward.  What is worth keeping is the three
controls that caught them: the quiet baseline on both instruments, the
requirement that each rise by ten decibels, and the requirement that the
two rises agree.
.PP
.B "The cable topology, worked out rather than assumed."
With one SMA-to-u.FL lead the ends are fixed \- u.FL to a board, SMA to
the instrument \- so each leg of the substitution is individually
possible and no pair of them shares a cable:
.DS
.CW "board1 u.FL -> lead -> tinySA SMA       leg A, works"
.CW "tinySA gen  -> lead -> board2 u.FL      leg B, works"
.CW "board1 u.FL -> lead -> board2 u.FL      wants u.FL both ends"
.DE
and leg A wants u.FL at the source while leg B wants SMA at it, so they
cannot be the same lead.
.B "u.FL-to-u.FL leads have been bought and can be tried next."
.PP
With one, the two legs are
.I tools/radio/offset.py
as written: board 1 into the instrument, then board 1 into board 2.  The
transmitter's uncalibrated output cancels, which is what removes the need
for a calibrated source.
.B "The cable does not cancel,"
because the two legs use different leads \- one u.FL-to-SMA and one
u.FL-to-u.FL \- so the result carries the difference of their losses,
which for two short pigtails is of order a decibel.  That is the
uncertainty of the answer and it is worth having: the figure in the
driver now is TI's example and not a measurement of anything.
.PP
.B "Leg B banked over a u.FL-to-u.FL cable, and a correction about what a cable is for."
.DS
.CW "ramp 0   nominal -17.5   board2 quiet -124  keyed -80  risen +44"
.DE
Board 2 hears it forty-four decibels over its own floor and reads -80dBm,
which is inside the range where this receiver is linear.  That is half
the substitution and it is written down; leg A wants board 1's u.FL on
the tinySA's input, and either leg may now run first \- requiring leg A
first meant the half that happened to be cabled right had to wait for the
other, and on this bench the cabling arrives in whatever order it
arrives.
.PP
.B "A CABLE MAKES THE CHANNEL LESS LOSSY, NOT MORE, which is the opposite of what was said here."
A pigtail costs a decibel or two where a few inches of air cost twenty or
thirty.  So a conducted link has
.I more
margin, every rung lands higher, and the error path is further away:
.DS
.CW "ramp  nominal   at board2    the receiver's state"
.CW "  63   +14.0    +12.0 dBm    saturated, and at the part's max"
.CW "  31    -2.0     -4.0 dBm    saturated"
.CW "  15   -10.0    -12.0 dBm    saturated"
.CW "   1   -17.0    -19.0 dBm    saturated"
.CW "   0   -17.5    -80.0 dBm    linear, and measured -80"
.DE
saturated meaning above the -50dBm knee this document already records,
where the receiver reads a flat -65 to -68 however hard it is driven.
.PP
.B "So ramp 0 is the only rung a cable can put in the linear range,"
which is the rung both legs used \- and it is only there because its
output collapses some forty-eight decibels, measured on the instrument.
The saturation knee itself, the receiver's sensitivity, and the packet
error path all want attenuation that neither the PA's range nor a pigtail
provides.
.B "Item 9's error-rate bullet is therefore no closer with a cable than without one,"
and the thing it wants is a step attenuator.
.PP
.B "And +14dBm conducted is at this part's absolute maximum input,"
so the ladder must not be walked from the top into a cabled receiver.
That is the same constraint already written down for the tinySA's input
and it applies to the other board for the same reason.
.PP
.B "Five flashes that reported success and changed nothing, and the cause was this script's own use."
Board 2 refused five in a row today: a bootloader answered,
.I mikroe-uhb
printed McuType and BootStart,
.B "the client exited zero,"
and the board went on running the image it had.
.I Flashverify.sh
caught every one by reading the board's own boot line back, which is what
it is for, and what it could not say was where the fault was.
.PP
.B "It was not the board, and it was not the hex."
Checked in turn: ^R^R resets board 2 and it reboots and prints a fresh
banner, so the console path works; no 1234:0001 device is present between
flashes, so nothing is lingering; and the port-to-board mapping is right,
proved by
.B #P/uid
rather than by the ports \-
.CW 2037303959315008002f0022
on the USB UART and
.CW 203730395931500800300022
on the PL2303, which is what
.B /lib/radio
says they are.
.B "That is what #P/uid is for and it is the only identity on this bench that a re-enumeration cannot move."
.PP
What it was:
.B "two of this script's own runs overlapping."
It is started in the background, a second invocation clears the first
one's client \- mid-write, with a board in its bootloader \- and whichever
client is alive when a bootloader next appears writes whatever hex it was
given, which may be several builds old.  Board 1 ended the day running
.CW 1790943023 ,
which is the image built for board 2 the previous evening, and board 1
had been verified on
.CW 1790942893
an hour earlier.
.PP
.B "So clearing stale clients at startup was the wrong fix for the right problem,"
which is the lesson: it addressed the symptom I had seen \- somebody
else's orphan \- and not the mechanism, which is that two runs of one
script must not exist.  There is a lock now, taken before anything is
built, and the clearing below it is meaningful again because with one run
at a time anything alive really is an orphan.
.PP
Both boards are on
.CW 1790943023
with the shell init and five processes, which is a committed build and a
working bench; what was being attempted when this started \- the station
image in UI mode on both, to tell collision loss from path loss \- is not
done.
.NH 1
The other half of the flashing fault: a build that could not convert and said nothing
.LP
.B "The lock was necessary and it was not sufficient."
With it held, one run at a time, board 2 took a shell image and reported
the new stamp \-
.CW "kerndate 1791074738, nproc 5" \-
and then refused the station image three more times in exactly the same
way: a bootloader answered,
.I mikroe-uhb
printed
.CW McuType
and exited zero, and the board came up on the image it already had.
Which killed the overlap as the whole explanation, because there was
nothing left to overlap with.
.PP
.B "The hex was older than the kernel beside it."
The kernel was stamped 20:49 and the hex 20:45.  Running the conversion
by hand said why in one line:
.DS
.CW "bin2ihex: istm32f407 is 914264 bytes; the limit is 901120"
.DE
The station image does not fit.  That is
.I bin2ihex
doing its job \- the ceiling is the calibration store's base, and an
image that reached past it would overwrite what a board had measured
about itself \- and the refusal was correct every time.
.PP
.B "What was wrong was that nothing downstream could tell."
Two faults, and both of them are mine.
.IP 1.
The conversion was the second half of the link recipe, with a
.I cp
after it.
.B "A recipe's status is its last command's,"
so when
.I bin2ihex
refused, the
.I cp
succeeded and mk reported a build.
.B KERNDATE
went by in the output as usual.
.IP 2.
Nothing depended on the hex, so mk had no reason to make one: the thing
it was asked for \- the kernel \- was up to date.  A hex missing or
older than the kernel beside it was never anybody's business.
.LP
And
.I flashverify.sh
built
.B istm32f407
and flashed
.BR istm32f407.hex ,
which are two different files, and read one thing out of the build
output \- the stamp \- with a
.I sed
that cannot fail.
.PP
.B "So five flashes had two causes and I found the first one and stopped."
The overlap was real and the lock was right; it was also the cause I
could see, and finding it closed the question before the second cause
was reached.  The tell was there in the first log I kept \- the client
wrote every block and exited zero \- and the thing I did not do was ask
what it had been given to write.
.B "A build log grepped for the line you want cannot report the line you did not expect."
.PP
.B "The fixes, in the tool and not the caller."
The hex is its own target now, depending on the kernel, so asking for it
rebuilds it whenever the kernel is newer; its recipe removes the old hex
.I before
converting and copies only on success, so a refusal leaves no hex at all
rather than the last one that worked \- a missing file stops a flashing
tool at its first argument and an old one gets written to a board.  That
the
.I "&&"
is load-bearing was checked rather than assumed: this mk feeds a whole
recipe to one shell, and without it the
.I cp
of the stale hex still ran.
.PP
The stamp is written down beside the image as
.BR istm32f407.date ,
from the same recipe that compiled it in, because
.B KERNDATE
is a fresh integer every link and appears nowhere afterwards but the
boot line.  Scraping it from build output works only on a build that
relinked, and
.B "the build that matters most is the one right after a refused conversion,"
where the kernel is already current and only the hex is remade: then the
stamp came out empty and
.I flashverify.sh
announced that the stamp could not be checked and flashed anyway.  It
reads the file now and insists on it.
.NH 2
And the image was made to fit, which is one list per init
.LP
The station image was 13144 bytes over.  The reason it is bigger at all
is that
.B armv7max25.dis
is 19440 bytes more decoded than
.B armv7minit.dis
is, and the reason there is no room for that is the calibration store:
the ceiling went from 917504 to 901120 when the store was sited below
the bootloader, and the shell image had 6296 bytes to spare.
.PP
.B "The lever is XIPMODS, and the measurement is in the generated prog.s."
Every module in the root carries a decoded instruction array in flash so
that
.I libinterp/load.c
does not build one in RAM \- on this board that is the difference between
having a shell and not.  Per module, measured:
.DS
.CW "sh.dis        77458"
.CW "lil.dis       26185"
.CW "sh/std.dis    25107"
.CW "sed.dis       22701"
.CW "osinit.dis    12960"
.CW "...           347190 for the whole list"
.DE
.PP
.B "A station runs none of them."
.B Armv7max25.b
loads
.I Sys ,
which is built in, and
.I Radiocal ,
which is
.BR /dis/lib/radiocal.dis .
It runs no commands because it runs no shell: at
.B "nproc 7"
the three kprocs
.B #a
starts and a shell will not both fit, and a station whose job is a link
does not need a prompt.  So the station's list is one module, 9999
bytes, and the image went from 914264 to
.B 581672
\- 319448 under the ceiling, with the shell image byte-identical at
894824.
.PP
.B "Which list is used is selected by file and not by a conditional."
.B xipdis-armv7minit
and
.B xipdis-armv7max25
sit beside the config and the mkfile includes the one named after the
init it is building.  They are not copies of each other: a module is in
a list because that image's init runs it.  And a module left out is
still in the root as its raw
.B .dis
and still not runnable here \- loading
.B sh.dis
asks malloc for 73536 bytes against 147456 in the whole board \- so the
station image carries a shell it cannot run, which both files say.
.PP
.B "The include is a pipe include, and that was tested before anything was written to depend on it."
.I "<xipdis-$INIT"
does not work: this mk does not expand a variable in an include
filename, it looks for a file called
.CW "xipdis-$INIT" ,
and \- worse \-
.B "it warns that the file is missing and carries on with XIPDIS empty."
.I "<| cat xipdis-$INIT"
expands it and stops with
.CW "bad include program status"
when the file is not there.  There is deliberately no default: a new
init has to say what it runs, because this board has already spent a day
on a build that silently reverted to the shell image.
.NH 2
Flashed, and the station's calibration is part of flashed
.LP
Board 2, first run after the fixes:
.DS
.CW "flashverify: built, kerndate 1791075602"
.CW "flashverify: the board says kerndate 1791075602, nproc 7"
.CW "flashverify: ax25init: uid 203730395931500800300022"
.CW "flashverify: ax25init: ppm 60300"
.DE
.PP
The last line is a new check and it belongs there.
.B Armv7max25
soft-fails every calibration path on purpose \- it prints why and carries
on, because a station that will not start is no better than one on the
wrong frequency \- but these two boards are 64ppm apart, which at 915MHz
is about 59kHz, and at 1200-baud 2-FSK that is no link at all.  A
station running the driver's defaults boots clean, prints its address,
beacons, hears nothing, and
.B "looks exactly like a path that does not close,"
which is the one thing a cabled run exists to rule out.  So the applied
figure is checked as part of the flash rather than noticed afterwards.
.NH 1
Conducted, over the u.FL cable: the path is seven decibels and the delivery rate is not a property of it
.LP
Both boards on the station init, cabled u.FL to u.FL, nothing typed at
either console, both transmitting at the driver's default
.CW "PA_CFG2 0x4f"
\- ramp 15, which is -10dBm, and which is also the figure this bench
settled on as safe into a cabled receiver.
.PP
.B "First, the path, because that is a measurement and not a cable being plugged in."
Two clicks sitting inches apart hear each other through the air whether
anything is fitted between their u.FL ports or not, so "conducted" is a
claim about where the energy went.
.B "I wrote it into this plan before taking it,"
on the strength of the cable, and the station printed nothing that could
have told me either way.  It does now:
.B last
on the rssi line is the RSSI of the last packet the part received, and
against a -10dBm transmitter it reads
.DS
.CW "board1: last -17dBm   (board2 -> board1, 7dB)"
.CW "board2: last -12dBm   (board1 -> board2, 2dB)"
.DE
Two and seven decibels, steady over an hour.  Free space between two
bare u.FL ports at a few inches is twenty or thirty, so
.B "the cable is carrying it,"
in both directions, and the two legs differ by five decibels because
connectors and matching are not symmetric.
.PP
.B "Second, the delivery rate, which came out three different ways under one arrangement."
Three windows, same boards, same cable, same power, nothing touched
between them:
.DS
.CW "window of 180s   board1 sent 43, board2 heard 24    56%"
.CW "                 board2 sent 43, board1 heard 25    58%"
.CW "window of 180s   board1 sent 45, board2 recv  0      0%"
.CW "                 board2 sent 40, board1 recv  0      0%"
.CW "five of 120s     board1 sent 145, board2 recv 140   97%"
.CW "                 board2 sent 140, board1 recv 145  100%"
.DE
.B "Zero CRC errors in every one of them."
A path does not do that: a marginal path corrupts frames and reports it,
and a seven-decibel path does not lose any.  So the frames that went
missing were never demodulated, and on a cable the only thing that stops
a frame being demodulated is a receiver that was not listening.
.PP
.B "The fault is a latched FIFO error, and the state field named it in one read."
.CW "state 0x06"
with
.CW "marc 0x0a"
is RX_FIFO_ERR.  One missed receive interrupt fills the RX FIFO; an
overflowed FIFO puts the part in that state; and in that state the part
does nothing \- no sync, so no PKT_SYNC_RXTX edge, so
.I cc1120interrupt
is never called again.
.B "The only recovery the driver had was at the top of cc1120interrupt,"
which is to say the recovery was reachable only by the event the fault
suppresses.
.PP
It is worse than deaf.  Twenty-two consecutive samples of
.CW "state 0x06 marc 0x0a"
while the station's
.B sent
counter climbed past a hundred more transmits and
.B recv
stayed frozen at 169, with
.B txstaged
reading 0 every time: the part refuses the TX FIFO as well, so
.B "every one of those sent frames was staged into a part that radiated nothing."
.I Sent
counts what the driver handed over.
.PP
.B "And the unconditional SRX after every transmit does not clear it,"
which is measured and not recalled \- a hundred-odd transmits, each one
ending in
.CW "strobe(rr, Srx)" ,
and the part still in state 6.  The exit is SIDLE and a flush.
.NH 2
The phase explanation, which was arithmetically right and was not the cause
.LP
Before the state field existed I wrote this into the plan: the beacon
period is four seconds, a thirty-five byte frame at 1200 baud is 233ms,
the two crystals are 64ppm apart, so the phase slides 256 microseconds
per beacon and takes 910 beacons \- about an hour \- for a colliding
phase to slide clear.  A window shorter than that measures one phase and
reports it as the delivery rate, which fitted 0%, 56% and 100% an hour
apart exactly.
.PP
.B "Its own experiment refuted it."
.I Tools/radio/phasetrials.py
resets one station, which draws a fresh phase, and measures.  Eight
trials:
.DS
.CW "trial   b1->b2      b2->b1      crc"
.CW "  1-8    0/15-20  0%   0/15  0%    0"
.DE
Flat.  Not a spread.  Two fresh resets at 0% had already made it
improbable \- random phase collides about six per cent of the time, so
two in a row is one chance in two hundred and fifty \- and eight settles
it.  The reason is that
.B "resetting the other board cannot unlatch this one:"
board 1 was in state 6 for the whole run and every trial measured the
same stuck part.
.PP
.B "The arithmetic is still correct and it is still the mechanism that will matter"
once two stations share a channel and neither is broken.  It was not what
was happening.  What it was is above, and the thing that found it was
printing the part's own state \- not another counter downstream of the
fault.  That rule has now cost this bench two days twice.
.NH 2
The instruments, three of which were wrong before any of this read true
.LP
.B "A counter read out of a rolling window is not a counter."
The first two measurements counted
.CW "ax25init: beacon N"
and
.CW "ax25init: heard N:"
lines out of screen's hardcopy, which is a fixed-size window: across a
reboot and a scroll the last visible index went 69 to 0 and the run
reported
.B "-164% delivered."
The driver's own
.B sent
and
.B recv
are cumulative since boot and the newest periodic line always carries
their current value whatever has scrolled away above it, so every figure
in this section is read from those.
.PP
.B "A console line has a width."
The first version of the station's report put everything on one line, at
about 130 characters, and the hardcopy cut it mid-word in the middle of
.CW ccamode .
A regex for
.CW "ccabusy N ccamode N"
then matched nothing and the run reported no CCA figures at all, which
reads as the driver not having them.  Three short lines now.
.PP
.B "And a port is not a board."
Flashing board 1 meant running
.I lsof
over the ttys, finding screen sessions on two PL2303 adapters, and
deciding one of them was board 1.  It is the Raspberry Pi 3B \- its
console is sdio, WIFI-JOINED and drawink \- and a flash was pointed at
it.  Nothing was written, because no STM32 bootloader can appear on a Pi;
what surfaced instead was that
.I flashverify.sh
waits forever for one, because
.I open_dev
in mikroe-uhb loops until a 1234:0001 appears.  Fifteen minutes with an
empty log and the lock held.
.PP
.I Ax25twosilicon.py
finds the boards by the serial each one prints now, mapped through
.B /lib/radio
by the same key the boards themselves use.
.B "The uid is the only identity on this bench that cannot be confused with another board's,"
and what it protects against turned out not to be an adapter being
swapped but me reading the wrong row of an lsof.
.NH 1
The fix: drain the FIFO, clear the latch, and a watchdog for the station that never transmits
.LP
Three pieces, and the order they were found in is the reverse of the
order they matter in.
.PP
.B "rxarm, which clears the latch."
Every
.I "back to listening"
in the driver was a bare
.CW "strobe(rr, Srx)" ,
and SRX from an error state is ignored \- measured, a hundred-odd
transmits each ending in one with the part still in state 6.  The exit is
SIDLE and a flush.
.I Rxarm
does that and is used at every such site: after a transmit, after reading
a packet out of the FIFO, in the
.B freq
verb, and in the
.B rx
verb, which is what somebody types at a stuck receiver and which a bare
SRX made useless.  The latch is also cleared at the
.I top
of the transmit path, before the idle-flush-fill sequence, because a part
in RX_FIFO_ERR refuses the TX FIFO too \-
.B txstaged
reads 0 \- so otherwise the frame that triggered the recovery is the one
frame lost to it.
.PP
.B "The sites that already strobed SFRX before SRX were left alone,"
which is the only reason this was four edits and not nine: the
.B serial
and
.B "carrier off"
verbs were already doing the right thing for their own reasons.
.PP
.B "A clock watchdog, because every one of those sites is reached by transmitting or by a ctl write."
A part that latches while its only reader is blocked in a read stays
latched for ever, and that is not hypothetical: it is the answerer in a
connected link, which announces and then does not transmit at all until
it has accepted.  One connected attempt over the cable had the caller
reach
.B Sconn
while the answerer never printed
.BR accepted ,
which is the shape of exactly that.
.PP
The clock interrupt is safe for it here and the reason was already
written down in
.BR spistm32f4.c :
the bus lock is an
.I ilock
because the bus is touched from the EXTI handler as well as from a
process.  So a process holding it has interrupts masked and the tick
cannot fire inside its sequence, and the tick holding it cannot be
interrupted by the packet handler.  Nothing in it sleeps; a state read is
two SPI bytes, once a second.  It acts on the two FIFO error states and
nothing else \- IDLE, TX, CALIBRATE and the transparent and carrier modes
are states something asked for, and a watchdog that decided what the
part ought to be doing would be a second driver.
.PP
.B "And draining the FIFO, which is the cause the other two were curing."
.I Cc1120interrupt
read one packet and returned.
.B "An EXTI pending bit coalesces edges:"
two packets arriving between the handler's runs raise one interrupt, so
one was read and the other stayed in the FIFO.  Interrupts are masked for
as long as anything holds the bus ilock \- the
.B capture
verb holds it for up to 2000ms \- so this happens for real.  The residue
only grows; four thirty-five byte frames fill the part's 128-byte RX
FIFO; and then it latches and stops raising the edge that would have
cleared it.
.PP
The handler drains now, bounded at four, which is the FIFO.
.B "Drain then wait, never wait then consume one"
\- a rule this kernel already learned under a different device, and one
that was not applied here because the fault it causes does not look like
a FIFO problem.  It looks like a radio link that does not close.
.NH 2
What the fix is verified to do, and the cause claim I had to withdraw
.LP
.B "What is solid."
The latch is real and the part names it:
.CW "state 0x06"
with
.CW "marc 0x0a" ,
twenty-two consecutive samples of it while
.B sent
climbed past a hundred more transmits,
.B recv
frozen at 169 and
.B txstaged
reading 0.  Before the fix that was the end of the link.  After it,
.B fifoerr
counts up and the link keeps carrying frames: one station read
.CW "fifoerr 10"
within a few minutes, every one cleared, still in
.CW "state 0x01"
and still receiving.
.B "A permanent death became a counted, self-clearing event."
.PP
And the watchdog is wired, which is a separate question from whether it
finds anything:
.B "watch 0 is equally what a watchdog that found no fault says and what one that was never added to the clock list says,"
so it counts its looks too.  They climb about once a second, with zero
finds \- the transmit path gets there first on a station that beacons,
which is the division the two were written for.
.PP
.B "What I withdraw: that coalesced interrupt edges were the cause."
The story was that an EXTI pending bit coalesces edges, so a packet
arriving while interrupts are masked leaves a residue that grows until
four frames fill the FIFO.
.B "The edge counters refute it."
.B Nintrlow
on one station read 29 against a peer that had sent 15 frames, and 61
against 45:
.B "there are more edges than packets, not fewer."
Which is what the pin being called PKT_SYNC_RXTX should have suggested \-
it asserts for the part's own transmits as well.  No edge is being
missed.
.PP
.B "And the drain loop is not shown to help."
One fifteen-minute run of the gated build read
.CW "fifoerr 0"
on both boards with thirty frames of thirty delivered each way, which I
was about to write up as a three-point result against the ungated build's
.CW "fifoerr 25"
and the undrained build's dozen.
.B "Then the same build, with one more line printed by the init, was back to fourteen."
One quiet window is not a fix, and the control for "did the drain remove
the cause" is the same build measured again \- which is the rule this
bench already has written down twice.
.PP
So the loop stays, because reading one frame out of a FIFO holding two is
wrong on its own terms, and it is a correctness fix and not a cure.
.B "The ungated version WAS harmful and that number stands:"
.CW "fifoerr 25"
over 85 beacons with 29 frames received, because reading a length byte
for a frame whose payload has not arrived underflows the FIFO into the
very state the drain was supposed to prevent.
.PP
.B "The cause of the overflow was open when this was written and the next section answers it."
What was known about it at this point: not missed edges, not the path,
not collisions or beacon phase, and it recurred within minutes on a link
carrying a frame every four seconds.  That last fact is the one that
mattered \- it is the rate at which the station reads the stat file.
.NH 2
The cause, and it was the stat file
.LP
.B "Reading the stat file was corrupting the receiver."
.I Cc1120stat
hoisted five values under the bus lock and then left four more in the
.I snprint
argument list \-
.IR readrate (),
.IR readdev (),
.IR readbw ()
and
.CW "rd(rr, Rpktcfg2)" .
An argument is evaluated where it is written, which is after
.CW "s->unlock(s)" :
.B "seven register reads on an unlocked bus,"
three in readrate, two in readdev, one in readbw and one for PKT_CFG2.
.I Cc1120caps
had the same shape with six.
.PP
The bus lock is an
.I ilock
precisely because the EXTI handler touches the same bus \-
.B spistm32f4.c
says so in as many words \- so with it released the packet interrupt can
fire between an
.IR rd ()'s
.CW select(1)
and its
.CW select(0) ,
assert chip select again and push its own FIFO burst into a half-finished
register read.
.B "Two command streams on one bus, and the one that loses is a FIFO read with a pointer in it."
.PP
.B "The station reads that file every five beacons,"
which is the rate at which
.B fifoerr
accrued.
.NH 2
Measured, with the control this time
.LP
Same init, same report rate, same cable, same power \- the comparison
being against the run immediately before it rather than against a
remembered good one, which is the mistake that cost the last attempt:
.DS
.CW "reads after the unlock   fifoerr 14 and 14   delivery about 30%"
.CW "reads under the lock     fifoerr  0 and  0   35/35 and 35/35"
.DE
Eight samples over a quarter of an hour, both parts in
.CW "state 0x01"
throughout, every frame delivered in both directions.
.PP
.B "And the edge arithmetic confirms it exactly."
Board 1 counted 70 falling edges for 35 transmits and 35 receptions.
PKT_SYNC_RXTX asserts for this part's own transmits as well as for
received packets \- it is named RXTX \- so 35 plus 35 is 70, and
.B "nothing was missed and nothing was spurious."
Which is also the last word on the coalesced-edge story: there was never
a residue to accumulate.
.PP
.B "This was found by reading the function, not by the bench."
No counter in the driver can see it, because the fault is the driver
corrupting its own bus traffic; every number downstream reads like a
radio problem.  What the bench did was refuse the two wrong
explanations \- the path, by measuring it at seven decibels, and the
beacon phase, by eight resets that all read zero \- and hold the
question open until the code was read.
.NH 2
And the connected link over the cable, which is the case the watchdog was written for
.LP
The answerer announces and then transmits nothing until it has accepted,
so it is the station that cannot reach the recovery in
.IR rxarm .
One attempt before any of this was fixed had the caller reach
.B Sconn
while the answerer never printed
.BR accepted .
With the bus-lock fix in, roles back in
.B /lib/radio
and both boards reflashed:
.DS
.CW "answerer: link 35: INFERNO-AX25-34"
.CW "          state connected vr 3 received 35"
.CW "          retransmitted 0 rejin 0 rejout 0"
.CW "caller:   sent 35, state connected vs 3 va 2"
.CW "          retransmitted 0 rejin 0 rejout 0"
.CW "          radio sent/recv 36 recv 35 crcerr 0"
.CW "          fifoerr 0  watch 0 of 146"
.DE
SABM and UA crossed, thirty-five numbered I frames arrived in order, the
thirty-five the caller's radio received are the answerer's
acknowledgements, and
.B "nothing was retransmitted and nothing was rejected."
.PP
.B "What that does and does not show."
It shows the arrangement that failed now works, with the answerer being
exactly the receive-only case.  It does not show that the earlier failure
was the FIFO latch, because that run was not instrumented to say so \-
the station had no
.B state
field then, which is the whole reason it was added.
.NH 1
A full-size frame was never transmitted: the wait was 500ms and the airtime is 733
.PP
.B "This is the fault that cost the Styx multi-frame read, and it was in the transmitter."
.CW cc1120send
waited
.B Txwaitms
\- 500 milliseconds, one constant for every frame at every bit rate \-
for the part to leave TX.  At 1200 baud a byte on the air is eight bits,
so 500ms is about seventy-four bytes.
.B "A longer frame was abandoned in the middle of transmitting."
.PP
Measured, 109 bytes of payload against 40:
.DS
.CW "txtest 109 staged 110 trace 2 0 0 0 2 2 left 20 marc 0x00"
.CW "txtest  40 staged  41 trace 5 0 0 0 2 0 left  0 marc 0x40"
.DE
Twenty bytes still in the FIFO; MARC_STATUS1 never reaching the 0x40
that means the transmit finished;
.B txtimeout
counting up \- and then the code below strobes SRX, which aborts what
was still going out.  The far end sees
.B "no end-of-packet edge at all:"
.CW "recv 0 crcerr 0 intr high 0 low 0" .
.B "A truncated frame is not a corrupt frame, it is silence."
.PP
.B "Why nothing had noticed in two days of using this radio."
Everything this bench had ever sent was small: a beacon is twelve bytes,
an AX.25 test payload sixteen, a Styx Tversion nineteen.  All of them fit
in 500ms and all of them worked, through a thousand numbered frames and
a mounted filesystem.
.B "The first thing to want a full-size frame was a Styx read of a 273-byte file,"
which is three frames at the information field's 109 \- and it failed
differently on different runs, because an abort lands in a different
place each time.
.PP
The bound is the airtime now: the payload, the length byte, the two CRC
bytes and sixteen more for preamble and sync, at eight bits a byte and
.B symrate
symbols a second, doubled because it is a bound and not a schedule, and
floored at the old constant so no frame gets less time than it used to.
At 1200 baud a 109-byte frame gets 1716ms against 853 of airtime; at
38400 it gets 63 against 27.
.NH 2
Verified, and with a burst verb that did not exist
.PP
.CW "txtest len n"
sends n frames back to back from inside the driver, which is a question
this bench could not ask: two commands typed at a prompt are
milliseconds apart, and a window of AX.25 I frames has no gap at all.
.DS
.CW "len  burst   sent  received  crcerr"
.CW "109  x1        1         1       0"
.CW "109  x2        2         2       0"
.CW "109  x3        3         3       0"
.CW "109  x4        4         4       0"
.CW "109  x8        8         8       0"
.DE
Full-size frames cross, in bursts up to twice the window, with no CRC
errors.
.B "Before the fix a single one of them never completed."
.PP
.B "AND ONE OF THOSE NUMBERS WAS MINE, NOT THE RADIO'S."
An earlier run of the same table read
.CW "x8 -> 0"
and I wrote it down as a limit.  It was the harness: eight 125-byte
frames are 8.3 seconds of airtime at 1200 baud and the script slept
eleven before reading the counters, which is too close to the margin.
With twenty it reads 8 of 8.
.B "A burst of n frames needs n times the frame airtime before a counter means anything,"
and at this bit rate that is about a second a frame.
.NH 2
What is still in the way of the multi-frame read, and it is memory again
.PP
With full-size frames crossing, the 273-byte read still does not
complete.  The satellite says why:
.DS
.CW "no free Blocks"
.CW "iallocb: no memory 0/40960"
.DE
.B "The 0 is the interesting figure."
It is
.B ialloc.bytes ,
the interrupt-time allocation outstanding, and it is zero \- so the
budget is not the limit and the main pool simply could not give the
radio a Block to receive into.  Which is the same wall
.I exportfs
hit at 8216 bytes, reached from the other side: a satellite running
.I export ,
a pipe, two relay processes,
.CW #a
with three kprocs and a radio has a main pool that is full when a frame
arrives.
.PP
So the remaining work is a budget rather than a protocol, and the
consumers are known and countable: devmnt's queue of ten messages,
.IR exportfs 's
buffer per outstanding request, the two pipe queues, and the
retransmission copies
.CW #a
keeps for an unacknowledged window.
.NH 1
Styx over an encrypted link, on two boards, and where it stops
.PP
6 October 2026, both boards on one build of
.BR armv7mstyx :
the satellite N0CALL-2 announcing on
.BR #a/0 ,
the ground N0CALL-1 calling it, iounit 109 of a carrier's 125.
.DS
.CW "sat: styx: ssl sha/rc4_256 on #D/0, and the secret is a"
.CW "     constant in this file rather than a key"
.CW "sat: ARMV7M-STYX-EXPORTING"
.CW "gnd: ARMV7M-STYX-SSL"
.CW "gnd: ARMV7M-STYX-MOUNTED"
.CW "gnd: styx: down: ax25: no answer"
.DE
.B "The mount completes over an encrypted link over the radio, and then the first read after it gets no answer."
Steps 5 and 6 are half done on hardware: a namespace crosses the air
with RC4 under it and no IP anywhere, and nothing can be read from it.
.NH 2
What the byte accounting says, once the instrument was fixed
.PP
.DS
.CW "ground sent   41  48  53"
.CW "satellite got 41  48  53"
.CW "satellite sent 41  42"
.CW "ground got     41  42"
.DE
.B "Nothing is lost on the air."
Every frame arrived at its full length; the exchange is Tversion,
Rversion, Tattach, Rattach, Twalk \- and then the satellite, having
taken the Twalk intact, writes nothing back and prints no error.
.PP
.B "And all three messages are under 109 bytes, so the segmentation is not involved at all."
Whatever this is, it is above the relay.
.PP
.B "The first instrument said otherwise and was wrong,"
which is worth recording because it invented the symptom being hunted.
It deduped console lines by their text, which is sound within one run
because the relay prints a running total and no two of its lines are
alike \- and unsound across runs.  The satellite had hours of its
previous session in the window, so every new line matching an old one
was suppressed, and the byte accounting read as if frames had gone
missing.  It resets both boards at the start now, satellite first.
.NH 2
The pool is not the cause, on the evidence
.PP
The obvious suspicion, given that this image's process count and pool
split were both set by exactly this failure before \- "the failure lands
on the third Styx message" \- is memory, and a
.I smalloc
that waits for ever is silent by design, which is what "took the
message and wrote nothing back" looks like.  The satellite's own print
before exporting says otherwise:
.DS
.CW "  cursize   maxsize     arena                            free"
.CW "    41536    118178     42176    678  404  12   76626  main"
.CW "    20544     39925     20544    573  394  17   19365  heap"
.DE
.B "main has 76 kilobytes it has not used and 118 it may grow into."
That is not starvation, so the theory is dropped rather than carried.
.NH 2
And it is not a timeout, it is a kernel wedge
.PP
The ground's
.CW "ax25: no answer"
reads like the satellite being slow or busy.  It is not.
.B "The satellite's console stops mid-run and nothing typed at it arrives afterwards:"
a liveness marker stuffed into its window comes back zero times, which
says the host-to-board direction is dead rather than that the shell is
gone.  The two control-Rs that drop this board into its bootloader are
handled in
.IR devuart 's
receive interrupt, so they cannot work either \-
.B "a flash attempt gave up after six resets with no bootloader."
Only the button helps, and somebody has to be in the room.
.PP
The last thing it printed, twice over two runs, is the frame that
carried the Twalk:
.DS
.CW "styx: down 53 off the air (142 so far)"
.DE
and then nothing.  The ground end is unharmed \- it echoes, and on
reboot it says
.CW "connect N0CALL-2: ax25: connection refused or no answer" ,
which is the correct report about a peer that is not there.
.PP
.B "That makes two hard wedges of this kernel in one day with the same signature:"
console dead mid-line, receive interrupt gone, reset button the only
way back.  The first was a write to
.B #P/imu.ctl
and was never explained, and the image that did it no longer exists.
.B "This one is reproducible,"
which is worth more than the first was: it happens at the same message
every time, on a build that is in the tree, with one switch that turns
it on and off.
.PP
.B "And the control was taken: ssl is implicated."
Both boards reflashed from one build with
.B Usessl
at zero \- satellite 1791329464, ground 1791329511, the same kernel in
every other respect \- and the run completes:
.DS
.CW "sat: ARMV7M-STYX-NOSSL-BYCHOICE"
.CW "gnd: ARMV7M-STYX-NOSSL-BYCHOICE"
.CW "gnd: styx: down 109 off the air (359 so far)"
.CW "gnd: styx: down 109 off the air (468 so far)"
.CW "gnd: styx: the satellite says battery 3302"
.CW "gnd: ARMV7M-STYX-READ-OK"
.DE
.B "A file read off a satellite over a radio, with the segmentation working:"
two consecutive 109-byte frames are one Styx message larger than a
frame, arriving and being put back together.
.PP
So with ssl the satellite wedges on the third message, and without it
the same two boards on the same build mount and read.
.B "That is one variable and one difference,"
which is what the earlier version of this section could not claim
because the only passing run had been on a different kernel.
.B "Usessl stays at zero,"
because a setting that costs a trip across the room on every boot is
not a default.
.NH 2
A cause found by reading, and withdrawn by reading further
.PP
.I Protect ()
returned
.CW c.dfd
and let
.CW c
go.
.B "A Limbo reference dies at its LAST USE, not at the end of the scope,"
so
.CW c.cfd
\- the ssl connection's CONTROL channel \- was released there, while the
data channel went to
.CW sys->export ()
and carried on being used.
.I Relay (),
twenty lines further down the same file, keeps its pipe end in a global
for exactly this reason and says so, citing a
.B #a
control reference that lapsed, went on TRANSMITTING and stopped
receiving.
.B "The same mistake one function apart."
.PP
It is kept in a global now, which removes a real class of bug and costs
nothing.
.B "And it is NOT the explanation for the wedge."
.PP
.I Devssl
reference counts.
.I Sslopen
does
.CW s->ref++
for each of
.BR ctl ,
.BR data ,
.B secretin
and
.BR secretout ,
and
.I sslclose
frees the
.I Dstate
only when the count reaches zero \- emu's copy of the device is
identical.
.B "Dropping the control channel takes the count from two to one:"
nothing is freed, nothing dangles, and the data channel goes on
working.
.PP
.B "So the wedge is unexplained, and the first account of it in this document was wrong."
It was written confidently, with the supporting note one function away
in the same file, and it did not survive twenty lines of the device it
accused.
.B "The theory was abandoned by READING THE DEVICE rather than by another trip to the bench,"
which is the cheaper order and was available before the claim was made
rather than after.
.PP
And then measured, which is cheaper still than being sure.
.IR Styxseg (1)
gained
.B -D
to drop the connection on purpose, reproducing the caller's mistake
under a host emu:
.DS
.CW "kept:    STYXSEG-OK 270 to 271 over 109-byte frames"
.CW "dropped: STYXSEG-OK 270 to 271 over 109-byte frames"
.DE
.B "Identical.  Dropping the connection is harmless, as the reference count says it must be."
.NH 2
And the harness cannot reproduce the wedge, which is itself a result
.PP
.B -D
reproduces the caller's mistake and not its consequence: under emu the
mount completes and the reads pass.  So whatever wedges the satellite is
not in
.I exportfs ,
.I devmnt
or the
.I devssl
LOGIC \- all three are the same source under emu \- and is in something
the host does not have.
.B "That leaves the kernel's own build of the device, #a underneath it, and this part's memory and timing."
A list of three is a better place to start than a list of everything,
and it was arrived at without a board.
.NH 2
Two more suspects killed by reading, before they cost a board
.PP
.B "The kernel's devssl is not meaningfully different from emu's."
164 lines differ and nearly all of them are includes, integer types and
whitespace.  The one addition that runs on every open publishes an
.I iounit
on the data channel,
.CW "s->c->iounit - Maxsslhdr" ,
and it depends on the control channel having been given the transport
before
.B data
is opened \-
.B appl/lib/ssl.b
does exactly that, with a comment saying why.  Sound, and not the wedge.
.PP
.B "And devssl does not ask its transport for 64K of memory,"
which is what
.CW "ensure(): bread(s->c, Maxdmsg, 0)"
with
.CW "Maxdmsg = 1<<16"
looks like on a part whose main pool is eighty kilobytes.
.I Qbread
takes a block off the queue and splits it if it is longer than the
count; it never allocates the count.
.B "That mattered because the shape fitted:"
an
.I allocb
of 65536 would fail, failure panics, and
.B "a panic on this board spins with interrupts off and the console FIFO loses the message"
\- console dead, no control-R, reset button, which is the signature
exactly.  It is not what happens, and reading
.B qio.c
cost a minute where the bench would have cost an afternoon.
.PP
.B "The satellite's devssl never touches #a either,"
which narrows it further than the list above.
.I Protect ()
pushes ssl onto the STYX end of the relay's pipe, so the device's
transport is a pipe on the board exactly as it is under emu; the relay's
two processes carry bytes between the pipe's other end and
.BR #a .
So the device-to-transport path is identical to the one that passes
under emu, and what is left is the relay, #a, the part, and this board's
memory and timing.

.NH 2
What is left to chase, and the part that is not the caller's fault
.PP
.B "A device that can be wedged by anything a program does to a file descriptor is a kernel fault,"
whatever the program did.  The signature is the thing to chase: console
dead mid-line, the receive interrupt gone, the two control-Rs that
reach the bootloader unable to run, and only the button left.  Twice in
one day, on a write to
.B #P/imu.ctl
in the morning and on the third Styx message of an ssl'd mount in the
evening, and
.B "the second is reproducible,"
which the first never was.
.PP
What the next session has that this one did not: a switch
.RB ( Usessl ,
defaulting to zero so no board boots into the wedge), a control run
still to take with it at zero on this same kernel, and a host harness
.RI ( styxseg (1)
with
.BR -D )
that reproduces the dropped connection under emu, where a wedge costs a
process instead of a walk across the room.
.NH 2
And the control run then showed the real shape of the two-byte fault
.PP
The same run went on to
.IR bigread (),
and it is worth a section because the frame accounting is complete on
both sides:
.DS
.CW "sat: styx: up 284 from the pipe (534 so far)"
.CW "sat: styx: up   109 onto the air"
.CW "sat: styx: up   109 onto the air"
.CW "sat: styx: up    66 onto the air"
.CW "sat: styx: down: ax25: no answer"
.CW ""
.CW "gnd: styx: down 109 off the air (359 so far)"
.CW "gnd: styx: down 109 off the air (468 so far)"
.DE
.B "The satellite sent all three frames.  The ground received the first two and never the third."
.PP
So it is not two bytes.
.B "It is the TAIL FRAME of a chopped message not arriving,"
and the 273-against-271 this document has carried for weeks was the same
fault wearing a milder appearance on an older kernel.
.PP
.B "And this is the ssl-OFF run, so ssl has nothing to do with it."
Two faults have been separated that had looked like one: ssl wedges the
satellite's kernel on the third message, and the segmentation loses the
last frame of a multi-frame reply.  They were chased together because
both end in
.CW "ax25: no answer" .
.NH 2
Why the session then ends, which is a second thing
.PP
The satellite's T1 expires waiting for an acknowledgement the ground
cannot send, its read of
.B #a
returns an error, and
.I down ()
RETURNS \- which kills that direction of the relay and ends the session.
.B "So one lost frame ends a conversation that AX.25 exists to recover."
Whether the relay should give up there is a policy question and is not
settled here; what is settled is that it gives up without saying
anything useful.
.PP
.B "It prints the device's own counters now, at every point either relay direction dies."
The run above could not say whether the driver had seen a partial
payload, because
.B rxpartial
and the rest are printed by
.IR bigread (),
which never ran: the relay returned first.
.B "A failure that reports nothing costs a bench session to re-create; one that prints the numbers costs a scroll back."
.NH 2
The counters, and the end that cannot print them
.PP
At the moment the satellite's relay died:
.DS
.CW "sat: sent 42 recv 13"
.CW "sat: ccabusy 0 ccamode 1 fifoerr 0 watch 0 of 80"
.CW "sat: rxstall 0 rxpartial 0"
.DE
.B "The sender is spotless."
It transmitted all three frames, never deferred for a busy channel, and
its own receiver reports no FIFO error, no stall and no partial payload.
.PP
.B "And the ground's numbers are not there, which is the instrument's fault and not the board's."
.I Counters ()
prints where a relay direction DIES, and that is the TRANSMITTING end:
its T1 expires waiting for an acknowledgement and its read of
.B #a
fails.  The receiver that missed the frame does not fail.  It sits in
.CW sys->read
waiting for the rest of a Styx message that is never coming, with no
timeout anywhere in the mount driver to rescue it \-
.B "the end that loses a frame is the end that goes quiet, not the end that errors."
.PP
.I Bigread ()
spawns a watchdog now: thirty seconds, then the counters, whether or not
the read ever returns.  If it completed they are a second sample and
cost a few lines; if it did not they are the only account of the
receiver there will be.
.PP
.B "What the sender's zeros already rule out"
is worth keeping separate from what the receiver's will say.  No
.B ccabusy
means the third frame was not deferred for a busy channel before it went
out.  No
.B fifoerr
or
.B rxstall
on the sender means its own receive path was not in a recovery state
that might have swallowed the acknowledgement.  So the frame was keyed,
and what happened to it is a question for the other end.
.NH 2
The receiver's numbers, and the frame the driver threw away itself
.PP
The run after that one had the watchdog
.IR bigread ()
spawns, and it printed what the section above could not get:
.DS
.CW "gnd: rxstall 0 rxpartial 1"
.DE
.B "The ground's driver saw the third frame's length byte and did not deliver the frame."
.B rxpartial
is incremented in one place, where
.B NUM_RXBYTES
says the FIFO holds fewer bytes than the length byte just read from it
claimed, and what the driver did there was flush the FIFO and count the
loss.
.PP
So the tail frame was not lost on the air.
.B "It reached the part, and the driver destroyed it."
.PP
The reason it had to is in the shape of the part: the length byte comes
off the front of the packet and
.B "cannot be pushed back."
Having read it, a driver that finds the payload short has three
choices \- read bytes the FIFO has not got, which underflows the part
and lands it in RX_FIFO_ERR; deliver a frame padded with rubbish; or
throw the frame away.  It chose the third, which is the only safe one of
those three, and
.B "on the older kernel there was no check at all,"
which is how 273 bytes became 271: it read past the end.
.NH 2
A fourth choice, which is to keep the length
.PP
.B "The length byte can be kept in the driver instead of in the FIFO."
.B rxpend
holds it, the drain loop's first act is to look there, and a frame whose
payload has not arrived is finished on a later pass rather than flushed.
That is the same shape as the loop around it \- come back when there is
more \- and it needs three things that are each worth stating, because
each of them is a way to make the receiver worse:
.IP \(bu
.B "A giveup."
A length left pending for ever blocks every later frame, because the
next packet's bytes would be read as this one's payload.
.I Cc1120tick ()
tries the drain first on every one of its once-a-second passes and gives
up after three seconds, which is past generous: a full 125-byte payload
is 0.83 seconds of air at 1200 baud.
.IP \(bu
.B "A flush clears it."
.I Rxarm ()
does, and so does the watchdog's own error branch, which strobes for
itself and does not come through
.IR rxarm ().
A FIFO error during a pended frame that left the length behind would
make the next packet's bytes be read as this one's payload \- the exact
corruption the whole change exists to prevent.
.IP \(bu
.B "The arithmetic differs between the two cases."
NUM_RXBYTES includes the length byte on the ordinary path and does not
on the resumed one, so every gate that compares them has a
.CW "pended? 0: 1"
in it.
.B rxunder
counts a payload read past the end of the FIFO and should be 0 by
construction; a reading above zero means those three places have drifted
apart.
.NH 2
Which is not yet shown to deliver a frame, and that distinction matters
.PP
.B bigread ()
completed on the next run, 273 bytes twice and identical, where the run
before it timed out; and three runs in a row have completed since.  The
tail frame arrived:
.DS
.CW "gnd: styx: down 109 off the air (359 so far)"
.CW "gnd: styx: down 109 off the air (468 so far)"
.CW "gnd: styx: down  66 off the air (534 so far)"
.DE
.PP
.B "But it arrived eleven seconds after it was sent, which is a retransmission and not a resume."
A counter was added to settle it \-
.B resume ,
the number of pended frames whose payload turned up and were read out \-
and
.B "it reads 0 on every live run."
.PP
So the honest account is narrower than the result looks.  What is
established is that
.B "the driver no longer flushes a FIFO it is only looking at mid-packet,"
and the frame then survives in the part long enough for AX.25 to
recover it.  What is
.I not
established is that the keep-and-resume path has ever delivered
anything.
.PP
The partials that have been seen since are a different animal, and the
stat line now says so:
.DS
.CW "rxstall 2 rxpartial 2 resume 0 rxstale 2 (14 of 82) rxunder 0"
.DE
Two frames given up on, the last of them a length byte of 82 with 14
payload bytes still in the FIFO three seconds later, and
.B "rxstall 2 against rxpartial 2 says both were found by the once-a-second stall detector"
rather than by a packet's own interrupt.  A FIFO frozen at 15 bytes is a
truncated transmission, which both behaviours handle.  The original
fault had
.B "rxstall 0 rxpartial 1" :
an edge-driven partial, a different population, and
.B "it has not recurred since the change went in."
.NH 2
So the comparison is an instrument and not an argument
.PP
.B "Running the old behaviour from an OLD KERNEL compares every other difference between two builds at the same time,"
which is how this bench has produced three confident wrong findings
already.  So the old behaviour is a
.B pend
verb on
.BR #W/ctl ,
defaulting to 1, and a
.B pend
key in
.I /lib/radio
that the station writes at boot and prints.  One build, one line of
data, and both boards print which arm they are in so a half-armed run
cannot be scored as a clean one.
.PP
.B tools/radio/pendtrial.py
alternates the arms rather than blocking them, because the bench drifts:
six runs of one followed by six of the other attributes the afternoon to
the change.  And it says which rows could have shown anything \- a run
whose only partials came from the stall detector did not meet the fault,
so
.B "a table that reads three-for-three against three-for-three is inconclusive and the harness prints that it is"
rather than leaving the reader to notice.
.NH 2
And the two bytes the part appends, which were never being read at all
.PP
Reading
.IR rd ()
settled a question the counters had been arguing about.
.B "It asserts chip select, reads one register and deasserts it."
The receive path asked it for PKT_CFG1
.B "in the middle of the FIFO burst read,"
which ends the burst \- so the two bytes clocked after it went out with
CS HIGH.  The part ignored them.
.B "They were never popped off the FIFO,"
and what landed in
.B rxstatus
was whatever MISO was floating at.
.PP
.B "Nothing reads rxstatus, so nothing acted on the rubbish,"
and that is how the block survived a commit which said it had stopped
the next packet's read from taking one of those bytes for its length.
It had not: every packet left a pair behind.
.PP
The register is read before the burst now, and
.B status
counts the frames whose two bytes were really taken.  The first live
reading answered what the datasheet could not:
.DS
.CW "status 26 crcbad 0"
.DE
.B "Twenty-six frames, every one of them appending, every CRC good."
So this part does append, the orphan pair was real on every packet, and
the CRC verdict is now the hardware's rather than a guess from a length
byte that looked wrong.
.PP
.B "The rejection is per frame and not per driver,"
which is the one way this change could have lost frames: once the part
has appended once, a later frame whose status bytes had not yet been
clocked in would be judged on a zeroed
.B rxstatus
with CRC_OK clear, and a good frame freed and counted as a CRC failure.
.B "A new way to lose frames, inside the change that was about not losing them."
It is gated on a local flag set where the bytes are read.
.PP
.B "And this is why the trial has to be run again on one frozen build."
These three changes went in while the first was being measured, and a
table whose first row came from a different kernel compares two things
at once \- which is the fault
.IR pendtrial (1)
exists to avoid.
.NH 1
THE FLUSH WAS SWITCHING THE RECEIVER OFF
.PP
.B "The trial ran, and then it ran again, and the second run said the first conclusion was wrong."
.NH 2
What the controlled comparison showed
.PP
Three pairs, alternating, one kernel image, the arm a line in
.I /lib/radio
that both boards print at boot:
.DS
.CW "1 pend=1  bigread OK   rxstall 2 rxpartial 2 resume 0 rxstale 2 (16 of 82)"
.CW "1 pend=0  bigread NO   rxstall 0 rxpartial 1 resume 0 rxstale 0"
.CW "2 pend=1  bigread OK   rxstall 2 rxpartial 2 resume 0 rxstale 2 (17 of 82)"
.CW "2 pend=0  bigread NO   rxstall 0 rxpartial 1 resume 0 rxstale 0"
.CW "3 pend=1  bigread OK   rxstall 2 rxpartial 2 resume 0 rxstale 2 (12 of 82)"
.CW "3 pend=0  bigread NO   rxstall 0 rxpartial 1 resume 0 rxstale 0"
.CW ""
.CW "pend=1 3 of 3 bigreads completed (3 of 3 runs had both boards in the arm)"
.CW "pend=0 0 of 3 bigreads completed (3 of 3 runs had both boards in the arm)"
.DE
.B "Three for three against nought for three, and every control row carries the original fault's exact accounting."
.PP
Which looked like the answer and was not.  The control rows say
something sharper than "a frame was lost", and it is in the numbers
beside the partial.  At the thirty-second mark the ground had
.DS
.CW "sent 14 recv 14"
.CW "crcerr 0  fifoerr 0  rxoverflow 0  rxstall 0  rxpartial 1"
.DE
and at seventy-four seconds the satellite had
.B "sent 42" .
.B "The satellite transmitted forty-two frames and the ground's receive count never moved past fourteen,"
with no CRC error, no FIFO error, no overflow and no stall.
.B "The receiver did not lose one frame.  It went deaf at the partial and never came back."
.NH 2
And the stat file named the state
.PP
One run in the failing arm with
.BR state ,
.B "fifo rx"
and
.B "intr high"
passed through the watcher:
.DS
.CW "state 0x00"
.CW "fifo rx 0 tx 15"
.CW "intr high 29 low 29"
.DE
.B "IDLE."
An empty receive FIFO, the packet-interrupt count stopped dead at
twenty-nine, and the part parked.
.PP
.B "SFRX is legal only in IDLE and RX_FIFO_ERR"
(SWRU295E, SFRX).  Five sites in the receive path strobed it straight
out of RX \- the bad length byte, the flush on a short payload, the
underrun guard, the
.I iallocb
failure and a ctl verb \- and the part's answer was to go to IDLE and
stay there.  The
.B SRX
that followed did not stick.
.PP
.I Rxarm ()
has always done it in the right order, SIDLE first, and has always
worked \-
.B "because it is only ever called from RX_FIFO_ERR, where SFRX was legal to begin with."
That is why FIFO-error recovery was sound while every other error exit
in the same function killed the station.
.NH 2
Which makes the pend change a refinement and not the fix
.PP
With one legal flush helper in front of all five sites, and the OLD
flush-on-partial still selected by
.BR "pend 0" :
.DS
.CW "state 0x01  sent 24 recv 26  rxpartial 2  intr high 51 low 51"
.CW "styx: 273 bytes over the radio, twice"
.CW "ARMV7M-STYX-BIGREAD-OK"
.DE
.B "Two frames flushed, both recovered by AX.25, and the read completed."
.PP
So the honest account is the opposite of the one three commits were
written around.
.B "Flushing a half-read frame is survivable; the link layer is for exactly that."
What killed the session was the flush leaving the part switched off, and
.B "a receiver switched off by its own error handler reports nothing"
\- which is why this read for weeks as a frame lost on the air.
.PP
.B resume
still reads 0 on every run, and that was the clue.  Keeping the length
byte has never delivered a frame; what it did was avoid the illegal
strobe by not flushing at all.  The three-for-three against
nought-for-three was real and the mechanism behind it was not what the
arms were named for.
.NH 2
And then the part said what it was doing, and it was transmitting
.PP
The flush waits for IDLE before it strobes SFRX, and the wait never
ended: sixteen polls was not enough, and
.B "raising it to 256 did not help either."
Which was the clue.  A counter was added for what the part reports
instead of IDLE, and it reported
.DS
.CW "notidle 2 idlepoll 256 said 0x20"
.DE
.B "0x20 is state 2.  TRANSMIT."
.PP
So the receive path was draining the RX FIFO while the station was
talking, and
.B "PKT_SYNC_RXTX is named RXTX because it asserts for this part's own transmits as well as for receptions."
The edge counters said so long ago \- 70 falling edges for 35 transmits
and 35 receptions, which this document wrote down as the refutation of
a different theory and then did not follow.
.B "The handler runs while the station is talking, and nothing in it ever checked."
.PP
That one number is the whole chain.  NUM_RXBYTES read during a transmit
is not a count of anything; the drain loop took what came back for a
length byte, found the payload short, called it a partial and strobed
SFRX from TX; and SFRX outside IDLE or RX_FIFO_ERR parks the part.
.B "A bogus length, an illegal flush, and a receiver switched off for the rest of the session with every error counter at zero."
.PP
It also explains a number this document has printed three times without
explaining:
.B "the stale length was 82 in every single run,"
with the bytes-arrived figure varying.
.B "82 is a byte of the station's own outgoing frame,"
and the traffic is deterministic, so it was the same byte every time.
.NH 2
The gate, and the size of what it was catching
.PP
The drain now runs only when the part is in RX or IDLE \- IDLE because
a received packet can be sitting in the FIFO with the part already out
of RX \- and the watchdog will not sample NUM_RXBYTES outside those
states either, because a number taken during a transmit cannot be
compared with the next one.
.DS
.CW "state 0x01  sent 24 recv 26  rxpartial 2  rxstall 0"
.CW "status 26 crcbad 0 notidle 0 idlepoll 2 said 0x00"
.CW "txskip 78"
.CW "ARMV7M-STYX-BIGREAD-OK"
.DE
.B "Seventy-eight times in twenty-eight seconds the handler had been reading the RX FIFO while the part was transmitting."
And with that gated,
.B "the flush reaches IDLE in two polls"
\- so the 256-poll failure was never a slow part, and
.B Rxidlepoll
is 32 now, which is the measurement with room and bounded on purpose:
if IDLE ever needs more, the premise is wrong again and
.B notidle
is how it says so.
.PP
.B rxpartial
is still 2, so there are genuine mid-packet looks as well, and this run
had the OLD flush-on-partial selected: both were flushed, both were
recovered by AX.25, and the read completed.
.NH 2
And with the real fault gone, the trial answers a smaller question
.PP
The same three pairs, same harness, on the fixed driver:
.DS
.CW "1 pend=1  OK  rxstall 5 rxpartial 3 resume 3 rxstale 0"
.CW "1 pend=0  OK  rxstall 1 rxpartial 2 resume 0 rxstale 0"
.CW "2 pend=1  OK  rxstall 4 rxpartial 2 resume 1 rxstale 1 (67 of 82)"
.CW "2 pend=0  OK  rxstall 0 rxpartial 2 resume 0 rxstale 0"
.CW "3 pend=1  OK  rxstall 3 rxpartial 2 resume 1 rxstale 1 (15 of 82)"
.CW "3 pend=0  OK  rxstall 2 rxpartial 2 resume 0 rxstale 0"
.CW ""
.CW "pend=1 3 of 3 bigreads completed"
.CW "pend=0 3 of 3 bigreads completed"
.DE
.B "Three for three both ways."
So keeping the length byte is not what makes a session survive; the
state gate and the legal flush are.
.PP
.B "And resume is no longer 0."
It reads 3, 1 and 1 \- five frames across three runs whose payload
turned up and were read out, where the other arm flushed six and made
AX.25 pay for them.
.B "That is the whole measured value of pending: a retransmission saved, five times in three runs,"
and it is why
.B "pend 1"
stays the default.
.PP
It also explains why
.B resume
read 0 on every run before the gate.
.B "The partials were not frames."
They were bytes read out of the RX FIFO during the station's own
transmission, so there was never a payload coming to finish them \- the
counter was telling the truth about a mechanism that had nothing real to
work on.
.PP
.B "What is left, and it is bounded:"
the stale length is still 82, now with the gate in and the bytes-arrived
figure varying \- 67 of 82 and 15 of 82.  With transmit excluded that is
a real 82-byte frame whose reception stops part way, once a run, and
AX.25 recovers it.
.B "It is no longer a candidate for anything that has been chased in this document,"
and it wants its own measurement rather than a theory.
.NH 1
THE SSL WEDGE IS NOT A WEDGE
.PP
.B "Nothing is wedged, and the claim that a device can be wedged by anything a program does to a file descriptor is withdrawn."
.PP
With the receive path fixed and the ssl arm turned into data \- an
.B ssl
key in
.I /lib/radio
beside
.BR pend ,
for the same reason: a constant made the two arms two builds \- the run
stopped after one message, exactly as before.  Then the satellite's
console was read directly instead of through the watcher:
.DS
.CW "ARMV7M-STYX-EXPORTING"
.CW "exportproc 7: waiting for memory (406) for request"
.CW "styx: down 41 off the air (41 so far)"
.CW "arena too large: main size 1366 cursize 42752 arenasize 117056"
.CW "        maxsize 118178, alloc = 3776 pc=0x80211e3"
.CW "exportproc 7: waiting for memory (406) for request"
.CW "exportproc 7: waiting for memory (406) for request"
.DE
.B "It is out of memory."
.I Exportfs
cannot get the 406 bytes a Styx request needs,
.B main 's
arena is at 117056 of a 118178 maximum, and it says so
.B "in an unbounded loop."
.PP
That loop is the symptom that was read as a wedge.
.B "At console speed an unbounded print monopolises the uart,"
so the console appears to stop mid-line and the two control-Rs that
reach the bootloader \- handled in the uart receive interrupt \- never
get a turn.
.B "The receive interrupt was not gone.  It was starved."
.PP
And the ground was never wedged at all.  Its console:
.DS
.CW "styx: up 41 from the pipe (41 so far)"
.CW "styx: up   41 onto the air"
.CW "kstack high water 2468 of 4096"
.DE
Sitting in
.CW sys->mount
waiting for a Tversion reply the satellite cannot build, with no
timeout in the mount driver to rescue it \-
.B "the same shape as the lost frame: the end that cannot answer is the end that goes quiet."
.NH 2
And the watcher could not have told me
.PP
.B tools/radio/twostyx.py
filtered for
.BR smalloc ,
.B "no free Blocks" ,
.B panic
and
.BR exceeded .
.B "The board says \(lqwaiting for memory\(rq and \(lqarena too large\(rq, which matched none of them."
So an afternoon's worth of theories about devssl reference counts, the
part, and this board's timing were built on a run whose own explanation
was on the console and filtered out.
.B "A watcher that filters for the failures you expect cannot report the one you did not."
Both strings are in it now, and so is
.B "kstack high water" .
.NH 2
What the memory question actually is
.PP
.B "#D costs 26480 bytes"
and the station's pool has about 118K.  Three numbers are worth having
before anything is changed:
.IP \(bu
.B "A process slot is 4096 bytes of kernel stack taken before main can have any"
\- twelve of them is 49152 \- and the station's own high water is
.B "2468 of 4096" .
That is measured on the paths this workload takes and not on the
deepest one that exists, so it is a candidate and not a licence.
.IP \(bu
.B Styxrpc
is 406, which is
.B "Ax25window * (Ccpayload - Ax25hdr) - Maxsslrec" ,
and
.I exportfs
starts an
.I exslave
kproc per request, each wanting one.
.IP \(bu
What devssl allocates per connection, which is four channels' worth of
reference on one
.BR #D/0 .
.PP
.B "None of those is a guess that can be made from here,"
and the board will answer all three.
.NH 2
And the mechanism I gave for it was wrong, one commit later
.PP
.B "The print is not unbounded and the console is not starved."
.B Exportproc 's
retry loop in
.B os/inferno/port/exportfs.c
sleeps 100 milliseconds and prints every six hundredth pass \-
.B "once a minute, for the ten minutes it retries"
\- and the satellite's whole scrollback holds
.B two
of those lines.  I read repetition in a
.I screen
window as a loop and wrote a mechanism around it.
.PP
.B "There is stronger evidence against it than the count."
.I Flashverify
succeeded on both boards immediately after the first ssl run, and
reaching the bootloader needs the two control-Rs that are handled in
the uart receive interrupt.
.B "The board was never unreachable."
.PP
So what is established about the ssl arm is:
.IP \(bu
the satellite's main pool cannot satisfy a 1366-byte allocation with
.B #D
pushed, with arenasize 117056 against a maxsize of 118178;
.IP \(bu
.I exportproc
retries for ten minutes and gives up;
.IP \(bu
the mounting end blocks in
.CW sys->mount
for ever, the mount driver having no timeout;
.IP \(bu
and the board stays reachable throughout.
.PP
.B "The \(lqconsole dead mid-line, only the reset button\(rq symptom is NOT reproduced on this kernel and its cause is unknown."
It is a separate observation from a different build and it should not be
attached to this one.
.B "That is twice in one session that a confident mechanism has had to be withdrawn,"
and both times the counter-evidence was already in output I had read.
.NH 2
The pool was at a ceiling it had never reached
.PP
.B "#c/poolhist was made to report how much of the pool its walk actually saw,"
because
.I histone
breaks out of a chunk on an unrecognised magic without saying so, and a
report that stops early reads exactly like a pool that is nearly empty.
With that in, the satellite with ssl on said:
.DS
.CW "styx: pool    41856   118178    42496   681   403   12   76306 main"
.CW "pool main: live 41856 in 278 blocks, free 1920 in 4, headers 4448"
.CW "  chunks 12 span 44544 covered 43776 truncated 0"
.CW "arena too large: main size 1366 cursize 43072 arenasize 117056"
.CW "        maxsize 118178, alloc = 3776"
.DE
.B "Twelve brks, twelve chunks, 44544 bytes of actual arena -- and an arenasize of 117056."
The walk was complete,
.B truncated
read 0, so the gap is not an instrument that gave up.
.PP
.I Poolalloc ()
raises
.B arenasize
before it asks for the memory, and the failure path puts back
.B nbrk
and
.B "not arenasize" :
.DS
.CW "	t = xalloclargest(alloc);"
.CW "	if(t == nil) {"
.CW "		p->nbrk--;"
.CW "		iunlock(&p->l);"
.CW "		return nil;"
.CW "	}"
.DE
.B "So every FAILED extension charged the pool permanently for memory it never received,"
and once that fiction reached
.BR maxsize ,
the pool refused to grow at a ceiling it had not reached.
.B "nbrk agreeing with the chunk count is what showed arenasize to be the liar."
One line puts it back.
.PP
.B "And the ssl arm still does not fit,"
which is the honest outcome: with the false ceiling gone the
.B "arena too large"
message is gone too, and the allocation now fails because
.I xalloclargest
genuinely returns nothing.  At boot this part has 159744 bytes free in
two holes, 65536 of CCM and 94208 of SRAM; twelve process slots take
49152 before
.B main
can have any, and the pools hold 69568 between them.
.B "The fix removed a false ceiling; it did not create memory."
.NH 2
And exposing xsummary hung the board, which was my own instrument
.PP
.B #c/xalloc
was added beside
.B #c/memory
so the hole table could be read at the moment of a failure rather than
only at boot.  The first station to read it
.B "stopped printing and stopped answering the two control-Rs,"
and
.I flashverify
then failed with "no bootloader appeared after six resets" against a
console that said nothing at all.
.PP
.I Xsummary ()
walked
.B xlists.flist
and
.B xlists.table
.B "with no lock,"
while every mutator in
.B os/inferno/port/xalloc.c
holds
.BR ilock(&xlists) .
That was survivable while
.I xinit
and the panic paths were the only callers, because nothing else was
running.  Reachable from a program it is not: a walk of a list being
relinked goes wherever a half-updated
.B h->link
points, including round for ever, inside the kernel, with the console
part way through a line.
.PP
It takes a bounded snapshot under the lock and prints afterwards now.
.B "The board needs its reset button before the measurement can be taken,"
which is a person in the room, and the lesson is the cheaper half:
.B "an instrument added to a shared kernel path inherits that path's locking, and this one did not ask."
