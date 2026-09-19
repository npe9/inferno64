.TL
Standing the independence checks up: what it takes, measured
.AU
.PP
.CW doc/radio-evidence.ms
says which independent checks are worth running and in what order.  This
says how to run them, with the unknowns that decide the cost checked on
this machine rather than guessed at.  It is the operational half; read
that one first for why.
.NH 1
What was unknown, and what the answers cost
.PP
Four things decided whether E1 and E2 are a day or a fortnight.  All
four are now
.B measured .
.IP \(bu
.B "No Zephyr toolchain is installed, and none is needed."
There is no Zephyr SDK and no
.CW west ,
but
.CW arm-none-eabi-gcc
14.3.1,
.CW cmake
4.1.2 and
.CW dtc
1.7.2 are all here, and
.CW boards/arm/mps2/mps2_an385.yaml
lists
.CW gnuarmemb
beside
.CW zephyr
under
.CW toolchain .
So the 2GB SDK download is not on the path:
.CW ZEPHYR_TOOLCHAIN_VARIANT=gnuarmemb
with
.CW GNUARMEMB_TOOLCHAIN_PATH
at the Homebrew toolchain builds this board.
.IP \(bu
.B "west installs on this Python."
3.14.7 is newer than Zephyr documents, and
.CW "pip install west"
in a virtualenv gives 1.5.0 without complaint.  The virtualenv keeps it
out of the system Python, which matters because none of this should
become a dependency of the Inferno tree.
.IP \(bu
.B "Semtech's driver needs one DIO line, not six."
This was the big one.
.CW dts/bindings/lora/semtech,sx127x-base.yaml
says
.CW dio-gpios
is required and is "up to six pins", which read like four more lines to
model.  The driver says otherwise:
.CW drivers/lora/loramac-node/sx127x.c
takes the length from the devicetree
.CW ( SX127X_DIO_GPIO_LEN )
and guards everything past the first with
.CW "#if SX127X_DIO_GPIO_LEN(0) >= 2" .
One entry is a legal binding.
.IP \(bu
.B "It does need a reset line, unconditionally."
.CW reset_gpios
is not guarded:
.CW sx127x.c:596
configures it and
.CW :602
drives the reset sequence before anything else happens.  The model has
no reset input, so that is the one thing E2 must add to it.
.PP
The estimate in
.CW doc/radio-evidence.ms
was that E2 "begins by adding DIO1, 2, 3 and 5 and a reset line".  Three
quarters of that is not needed.  What is left is a reset input, which is
twenty lines.
.NH 1
E1.  Zephyr's GPIO tests against patch 0027
.PP
.CW tests/drivers/gpio/gpio_basic_api
is the check, and its README names the one thing that makes it awkward:
.DS
.CW "This application tests the GPIO subsystem using a"
.CW "hardware configuration where two GPIOs are directly"
.CW "wired together."
.DE
and a board without that wiring fails with
.CW "output pin not wired to input pin?" .
So E1 is three pieces.
.IP "E1.1" 8
.B "A loopback in the board model."
A fourth QEMU patch wiring
.CW gpio0
output 2 to
.CW gpio0
input 3 \- the pins the test's own overlays use \- behind a
.CW gpio-loopback=on
machine property, so that no existing MPS2 configuration moves and the
radio property stays independent of it.  Ten lines beside the radio
wiring already in
.CW hw/arm/mps2.c .
.IP
The loopback is a fixture and should be labelled one.  What is not a
fixture is the driver at the other end of it: output drive, input read,
edge and level interrupts are Zephyr's code exercising the model, and
the model's register map came from Zephyr's header.  That is the loop
closing.
.IP "E1.2" 8
.B "An overlay for the board."
.CW tests/drivers/gpio/gpio_basic_api/boards/mps2_an385.overlay ,
naming
.CW gpio0
pins 2 and 3 through the test's own
.CW test-gpio-basic-api
binding.  Copy the shape from
.CW arduino_D2D3.overlay .
.IP "E1.3" 8
.B "Build and run against the patched binary, not Zephyr's."
No QEMU integration is needed: build the ELF and run it under the QEMU
in
.CW tools/qemu-patches .
.DS
.CW "west build -b mps2/an385 \e"
.CW "  tests/drivers/gpio/gpio_basic_api"
.CW "qemu-system-arm -M mps2-an385,gpio-loopback=on \e"
.CW "  -nographic -kernel build/zephyr/zephyr.elf"
.DE
.PP
.B "What E1 proves, and the thing worth checking twice."
Run it on a
.I stock
v10.1.3 as well.  The board's own yaml claims
.CW gpio
support under
.CW qemu ,
and with the block created by
.CW create_unimplemented_device ()
that claim cannot ever have been true.  If the test passes patched and
fails stock, patch 0027 is an upstream fix and the series should say so.
If it passes on stock too, something is wrong with the experiment and it
is worth finding out what before trusting E2.
.NH 1
E2.  Semtech's driver against the SX1276 model
.IP "E2.1" 8
.B "A reset input on the model."
.CW qdev_init_gpio_in_named (dev,
.CW "..., \(dqreset\(dq, 1)" ,
and asserting it runs the same path
.CW sx1276_reset ()
already has.  The SX1276's
.CW NRESET
is active low and held for 100us, released, then 5ms before the part is
ready; the model can ignore both times or honour them, and honouring
them is better, because a driver that does not wait is a driver that
will fail on hardware.
.IP "E2.2" 8
.B "An overlay putting the part on the bus."
A
.CW arm,pl022
node at 0x40026000 \- Zephyr has
.CW drivers/spi/spi_pl022.c ,
so that half is theirs too \- with an
.CW sx127x
child carrying
.CW cs-gpios
on
.CW gpio0
pin 0,
.CW reset-gpios
on a pin the board patch wires to the new reset input, and
.CW dio-gpios
with the single entry the driver's own guards permit, on
.CW gpio0
pin 1 where DIO0 already lands.
.IP "E2.3" 8
.B "Run samples/drivers/lora/send and receive."
With
.CW CONFIG_LORA=y
and the
.CW loramac-node
module, which
.CW west update
pulls.
.PP
.B "The outcome is a list, not a verdict."
Their driver is LoRaWAN-oriented and will reach for registers this model
does not carry, for channel activity detection, for the other DIO
mappings, possibly for FSK.  Every such reach is a place where
.CW os/inferno/port/sx127x.c
has been agreeing with a model that agreed with it.  Write the list
down; it is the deliverable.  A run that reaches the version check and
one transmit is already a real signal, and a run that completes is more
than was expected.
.NH 1
What this does not become
.PP
Zephyr is a tool here and not a dependency.  It lives in a virtualenv
and a scratch directory, nothing in the Inferno tree refers to it, and
what comes back into the tree is three things: a fourth QEMU patch for
the loopback, whatever E2's list forces into
.CW hw/ssi/sx1276.c ,
and a paragraph in
.CW tools/qemu-patches/README
recording that 0027 and 0028 have been driven by somebody else's code.
If that paragraph cannot be written honestly, the checks failed and
.CW doc/radio-evidence.ms
says what follows from that.
.NH 1
Order, with the reason
.PP
E1 before E2 because it is smaller, because it shares the overlay
machinery, and because a GPIO model that cannot pass Zephyr's own GPIO
tests would make E2 uninterpretable \- the SX1276 reaches its driver
through that GPIO, so a fault in 0027 would look like a fault in 0028.
.PP
Then the cheap ones from
.CW doc/radio-evidence.ms
that need no Zephyr at all: ssl(3) over
.CW /dev/radio0/data ,
and Styx over that with the message size actually watched.  Those close
out an argument the rest of the tree has been making on credit.
