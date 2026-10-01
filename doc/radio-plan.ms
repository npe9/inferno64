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
.IP "2.  Calibrate it against a source, not a datasheet.  Unblocked, and half of it is still not possible." 6
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
RSSI \- and not the offset.  The offset wants a cable from the
generator to the click's u.FL, which wants an adapter this bench does
not have.  The slope is worth having on its own and needs only an
antenna on the generator connector.
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
.IP "6.  Stop typing at a shell.  Built, measured under qemu, not yet on silicon." 6
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
