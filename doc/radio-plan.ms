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
over it \- are not done.
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
.IP "2.  Calibrate it against a source, not a datasheet." 6
\-102 is the figure TI's examples use and it is not a measurement of
this board.  The tinySA has a signal generator in it \- "mode output"
\- so a known level at a known frequency into the click's antenna
gives the offset this board actually wants.  That is the difference
between an RSSI and a number.
.IP "3.  Receive a packet that somebody else sent." 6
The transmitter is proven against an instrument and the receiver is
proven against an instrument, and neither has yet carried a packet on
silicon.  There is one CC1120 here, so this needs either a second one
or a transmitter already on the air.  Wireless M-Bus at 868.95MHz is
the second: it is what this chip family exists for, TI publishes the
register set for mode T and mode C, and a meter is a transmitter that
does not need arranging.  The band survey says whether one is in
range before any of it is written.
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
