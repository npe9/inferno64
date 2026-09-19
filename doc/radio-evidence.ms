.TL
Making the radio work relevant and right
.AU
.PP
The radio of
.CW doc/radio-plan.ms
runs: two emulated boards, a beacon sent and heard.  This is a plan for
the two things that are not settled by its running.
.IP \(bu
.B Right .
The QEMU model and the driver that talks to it were written by the same
hand in the same sitting.  A passing test can mean the model implements
the driver's mistake.
.IP \(bu
.B Relevant .
An MPS2 has no radio.  Everything above was measured against a fixture,
and a PyCubed is a different machine.
.PP
Neither is answered by more of the same, and the order between them is
not arbitrary: the independence work comes first, because it protects
the hardware work rather than running beside it.  The chip driver is
what carries to real silicon, and if Semtech's own driver shows the
model is wrong in a way this driver compensates for, then
.CW sx127x.c
is wrong too and anything built on it has to be done again.
.NH 1
Where the evidence actually stands
.PP
.CW tools/qemu-patches/README
sets three tiers, strongest first:
.CW hardware ,
.CW qemu ,
.CW qemu+patch .
Every claim this work has made is at the weakest of the three, and both
halves of it are ours:
.DS
.CW "  hw/ssi/sx1276.c          489   model"
.CW "  hw/gpio/cmsdk-ahb-gpio.c 350   model"
.CW "  os/inferno/port/sx127x.c 515   driver, carries over"
.CW "  os/inferno/port/devradio.c 280 device, carries over"
.CW "  os/inferno/mps2/spipl022.c 188 fixture, thrown away"
.DE
So 188 lines of 983 in the guest \- 19% \- are the part that does not
survive contact with a PyCubed, and that is the good news.  The bad news
is the 839 lines of model, which are not evidence about anything: they
are the thing the other 795 were checked against.
.PP
The point of what follows is to move named claims to named tiers.  A
table at the end says which step moves which.
.NH 1
Right: three independent checks
.NH 2
E1.  Zephyr's GPIO tests against the GPIO model
.PP
.CW tests/drivers/gpio/gpio_basic_api
on
.CW mps2/an385 ,
under the patched QEMU.  Zephyr's CMSDK GPIO driver is where the
register map in patch 0027 was checked, so running their tests against
it closes the loop: the model was written from their header, and now
their driver has to drive it.
.PP
There is a detail worth noticing.
.CW boards/arm/mps2/mps2_an385.yaml
lists
.CW gpio
under
.CW supported
and
.CW qemu
under
.CW simulation
\- but QEMU created the block with
.CW create_unimplemented_device () ,
so that support cannot ever have worked there.  If the tests pass on the
patched binary and fail on a stock one, that is worth saying in the
patch, because it makes 0027 an upstream fix rather than a local one.
.B "Cheap, and first."
.NH 2
E2.  Semtech's own driver against the SX1276 model
.PP
Zephyr carries
.CW drivers/lora/loramac-node/sx127x.c ,
which is Semtech's, written years before this and by people with the
part on the desk.  Pointing it at the model is the strongest
independence check available without hardware.
.PP
.B "The cost is known in advance rather than discovered."
.CW dts/bindings/lora/semtech,sx127x-base.yaml
requires
.CW reset-gpios ,
and
.CW dio-gpios
with "up to six pins that produce service interrupts from the modem".
The model has
.CW dio0
and
.CW dio4
and no reset input at all.  So E2 begins by adding DIO1, 2, 3 and 5 and
a reset line to
.CW hw/ssi/sx1276.c ,
and a devicetree overlay putting a
.CW arm,pl022
at 0x40026000 with an
.CW sx127x
child \- Zephyr has
.CW drivers/spi/spi_pl022.c
already, so the controller is theirs too.
.PP
.B "And the outcome is an enumeration, not a pass."
Their driver is LoRaWAN-oriented and will touch more of the part than
this one does \- FSK, channel activity detection, the other DIO
mappings, registers this model does not carry.  What E2 produces is a
list of what it touches that is not modelled, and every item on that
list is a place where this driver has been quietly agreeing with its own
model.  A run that reaches the version check and one transmit is already
a real signal.
.NH 2
E3.  A peer on the link that we did not write
.PP
QEMU's
.CW socket
netdev is length-prefixed frames over TCP, so a small host program can
join the same link and be the other station.  Give it RadioHead's
framing taken from RadioHead's source, or
.CW pycubed_rfm9x.py 's
logic taken from that file rather than from a reading of it.
.PP
This is the only one of the three that tests both axes at once.  It asks
whether the four-byte header this driver sends is the header the thing
it claims compatibility with actually expects \- which is relevance \-
against a peer written by someone else, which is rightness.  It is also
the only way to exercise
.CW send_with_ack
before there are two radios.
.NH 2
What would falsify the whole fixture
.PP
Worth writing down before anyone is invested.  If Semtech's driver
cannot be made to drive the model without changing the model to match
.I this
driver's assumptions, then the model is a mirror, E1 to E3 are
circular, and the right response is to stop spending on the fixture and
buy the part.  That is a real possible outcome of E2 and not a rhetorical
one.
.NH 1
Relevant: three steps toward a board
.NH 2
R1.  Time on the air
.PP
The model transmits in zero time.  Nothing above it can be trusted about
timing, and two specific things are untestable because of it:
.CW drop-pct
exists and has never been turned on, and
.CW pycubed_rfm9x 's
.CW ack_delay
is 0.2 seconds, which against an instantaneous channel means any timeout
passes for the wrong reason.
.PP
Time on air is a formula in the datasheet \- preamble, header, payload
symbols, from spreading factor, bandwidth, coding rate and length \- so
the model can compute it and hold the packet for that long with a timer,
setting TxDone when it really would have finished.  At SF7 and 125kHz a
short packet is tens of milliseconds, which is the difference between a
retry path that is exercised and one that is merely present.
.B "R1 comes before R2, and makes drop-pct worth setting."
.NH 2
R2.  Acknowledgement and retry
.PP
.B "This is the largest single gap between what exists and something a
.B "PyCubed could talk to."
.CW radio (3)
says it plainly:
.CW _RH_FLAGS_ACK
is never set and never waited for.  A PyCubed's ground exchange uses
.CW send_with_ack
with
.CW ack_retries
and
.CW ack_wait ,
so this driver can hear a beacon and cannot take part in the reliable
path at all.
.PP
It is the part of
.CW lib/pycubed_rfm9x.py
not yet ported, it belongs in
.CW sx127x.c
where the header already is, and with R1 and
.CW drop-pct
it can be tested rather than asserted.
.NH 2
R3.  A real SX1276
.PP
The cheapest real silicon is not a PyCubed.  It is an RFM9x on a
Raspberry Pi 3B, which is a board this tree already boots and already
has
.CW spibcm.c
and
.CW gpiobcm.c
for.  A
.CW Spidev
over those is perhaps a hundred lines, and it moves
.CW sx127x.c
from
.CW qemu+patch
to
.CW hardware
without a SAMD51 port existing.  Two of them is a real RF link; one of
them against a Feather running RadioHead is a real interop test.
.PP
.B "One blocker, found rather than assumed."
.CW gpiobcm.c
has
.CW gpiofsel ,
.CW gpiopull ,
.CW gpioout
and
.CW gpiolev
and no interrupt registration, and QEMU's
.CW hw/gpio/bcm2835_gpio.c
answers 0 for
.CW GPEDS ,
.CW GPREN ,
.CW GPFEN
and the rest \- marked "Not implemented" \- and has no
.CW sysbus_init_irq
at all.  So the Pi's edge detection is unmodelled, DIO0 has nowhere to
land, and developing the Pi driver under emulation first needs a fourth
QEMU patch.  Either write it, or go straight to hardware and debug there.
The plan should not pretend that choice does not exist.
.NH 2
Not doing: a SAMD51 in QEMU
.PP
Ruled out deliberately.  Modelling the clock tree, the SERCOMs, the NVIC
and the QSPI of a SAMD51 is more work than buying one, and it would
produce another fixture rather than evidence \- a second model written
by the same hand to be agreed with by the same driver.  If the goal is a
PyCubed, the shortest honest path to it is a part on a desk.
.NH 1
The claims this work has made and not tested
.PP
Separate from both axes, because these cost little and are what the
argument in
.CW doc/pycubed-plan.ms
rests on.
.IP \(bu
.B "ssl(3) over the radio."
.CW keyring->auth ()
then
.CW ssl->connect ()
and
.CW secret ()
on
.CW /dev/radio0/data ,
and a byte each way the other end can read only because it
authenticated.  Asserted throughout and never run.
.IP \(bu
.B "Styx over that, and the message size."
.CW sys->export ()
and a ground station reading
.CW /dev/battery
off the satellite.  This is the one that turns the msize question into a
printed number: the claim is that
.CW exportfs.c:806
adopts the
.CW iounit
of
.CW data
and negotiates 230-odd without being told, and nobody has watched it.
.IP \(bu
.B "More than two stations."
.CW "-netdev socket,mcast="
delivers nothing on this host with or without
.CW localaddr .
.CW docker/Qemu.Dockerfile
already builds a patched QEMU on Debian, so run the two-instance test
there.  If multicast works, a broadcast channel and a third station
become testable; if it does not, the plan should stop promising them.
.NH 1
What each step moves
.DS
.CW "claim                        now          after"
.CW "GPIO register map          qemu+patch    E1  qemu"
.CW "SX1276 register/FIFO/IRQ   qemu+patch    E2  qemu"
.CW "RadioHead header interop   untested      E3  qemu"
.CW "retry under loss           untested      R1+R2"
.CW "the chip driver            qemu+patch    R3  hardware"
.CW "ssl over the link          asserted      C1  qemu+patch"
.CW "Styx msize negotiation     asserted      C2  qemu+patch"
.CW "a third station            untestable    C3  or dropped"
.DE
E1 and E2 move claims from
.CW qemu+patch
to
.CW qemu
because after them the thing being agreed with is somebody else's
driver, not ours.  Only R3 reaches
.CW hardware ,
and only for the 515 lines that deserve to.
.NH 1
How, as opposed to whether
.PP
.CW doc/radio-evidence-howto.ms
is the operational half of this: the commands, the overlays, and the
four unknowns that decided whether E1 and E2 were a day or a fortnight,
all four checked on this machine.  Two of its findings change the sizing
above.  There is no Zephyr toolchain here and none is needed, because
.CW mps2_an385.yaml
lists
.CW gnuarmemb
and
.CW arm-none-eabi-gcc
is installed; and Semtech's driver needs one DIO line rather than six,
because it takes the count from the devicetree and guards everything
past the first with
.CW "#if SX127X_DIO_GPIO_LEN(0) >= 2" .
E2's cost to the model is a reset input and nothing else.
.NH 1
Order
.PP
E1, then E2, because E2 can invalidate everything downstream and is
therefore worth knowing early.  Then C1 and C2, which are cheap and
close out the argument the rest of the tree has been making.  Then R1
and R2, in that order for the reason given.  E3 any time after R2, since
that is when there is something for a peer to acknowledge.  R3 last,
because it is the one that costs money, and by then it is the only thing
left that can be learned any other way.
