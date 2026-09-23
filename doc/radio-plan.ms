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
.IP "2.  Calibrate it against a source, not a datasheet.  Blocked on a connector." 6
\-102 is the figure TI's examples use and it is not a measurement of
this board.  The tinySA has a signal generator in it, so a known level
at a known frequency into the click's antenna gives the offset this
board actually wants.  That is the difference between an RSSI and a
number.
.PP
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
