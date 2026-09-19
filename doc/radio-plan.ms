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
.IP "R1.1" 8
.B "hw/ssi: model the Semtech SX1276."
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
