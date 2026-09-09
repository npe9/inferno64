.TL
Inferno on the Raspberry Pi 4 (BCM2711)
.NH 1
Why this board is next
.PP
The port list in
.CW doc/inferno-ports.ms
gives
.CW raspi4b
four stars and names it first among the four machines that are real
parts rather than emulator targets \- the ones where QEMU is a stepping
stone and not the destination.  Two things settle it beyond the
ranking.
.PP
The first is reuse.  QEMU's Pi 4 SoC is the Pi 3's peripheral set at a
different base:
.CW hw/arm/bcm2838_peripherals.c
inherits from the same
.CW BCM_SOC_PERIPHERALS_BASE
and adds a second SD controller and its own GPIO.  So
.CW os/inferno/raspi4
starts as
.CW os/inferno/raspi3b
with
.CW BCMPERIPH
moved from 0x3f000000 to 0xfe000000, which the raspi3b header was
already written to allow \- every offset was derived from that constant
except UART0, which is derived here too.
.PP
The second is that the twenty patches in
.CW tools/qemu-patches
come with it.  The PL011 transmit FIFO and the truthful UART clock are
set in
.CW bcm_soc_peripherals_common_realize() ,
which
.CW bcm2838_peripherals_realize()
calls, so this board inherits both without a line of new QEMU.  That
was checked before the directory was created, not assumed.
.NH 1
What is different, and what it cost
.PP
.B "The peripheral base, which cost nothing."
0xfe000000 in place of 0x3f000000, one constant.
.PP
.B "The interrupt controller, which is the real change."
A Pi 3B's peripherals feed the legacy BCM controller and
.CW trap()
walks its three pending registers.  A Pi 4's are wired straight to a
GIC-400 \- a GICv2 \- as SPIs:
.CW bcm2838.c
connects uart0 to
.CW GIC_SPI_INTERRUPT_UART0
with nothing in between.  So the three-bank walk is gone and
.CW trap()
reads IAR and writes EOIR, with the GIC at 0xff841000 and 0xff842000.
The SPI numbers are their own map in
.CW io.h ,
taken from QEMU's own header and converted once: an input index n on
the GIC is SPI n, which is INTID 32+n.  The PL011 is 57 on a Pi 3 and
153 here.
.PP
One thing the raspi3b GIC code does not do and this must: write
.CW GICD_ITARGETSR
for SPIs.  virtarm64 gets away without it because
.CW "-M virt"
runs single-core here, so the reset value already names the only cpu.
This machine has four and QEMU refuses fewer, and an SPI whose target
byte is zero is enabled at the distributor and delivered to nobody.
.PP
.B "The page tables, which is where it first stopped."
raspi3b's L1 has two entries: 0-1GB through an L2, and 1-2GB as one
device block for the BCM2836 per-core registers.  That works because a
Pi 3's peripherals are at 0x3f000000, inside the first gigabyte.  A Pi
4's are at 0xfe000000 and its ARM control block, which holds the GIC,
at 0xff800000 \- both in the fourth gigabyte, neither reachable from a
table that stops at 2GB.  The MMU came on and the next peripheral touch
was a fault.  The L1 now maps 0-1GB as RAM through the L2, 1-2GB as RAM
(this board has 2GB and no per-core block there), and 3-4GB as one
device block covering the peripherals and the ARM control block
together.
.NH 1
What boots
.PP
All of it, to a shell, with thirty markers and no
.CW -NONE
or
.CW -FAIL :
.PP
.CW "AUX-OK AUXSPI-OK DISK-BLK-OK DISK-DOS-OK DISK-READ-OK DISK-WRITE-OK"
.br
.CW "DMA-OK DRAW-OK ETHER-DHCP-OK ETHERBIND-OK MBOX-OK OTP-OK RANDOM-OK"
.br
.CW "RASPI3B-OK RASPI3B-SH-OK SD-CAP-OK SD-FS-CREATE-OK SD-MULTIBLOCK-OK"
.br
.CW "SD-OK SD-WRITE-OK SDHCI-4BIT-OK SDHCI-CAP-OK SDHCI-HISPEED-ACCEPTED"
.br
.CW "SDHCI-MULTIBLOCK-OK SDHCI-OK SDHCI-SPEED-ACCEPTED SDHCI-WRITE-OK"
.br
.CW "SYSTMR-OK UART-PUTC-OK USB-OK"
.PP
23.9 seconds to the last marker, and QEMU logs no guest error.  USB
ethernet gets a DHCP lease, USB mass storage reads and writes a FAT16
image, both SD controllers pass the whole sequence including bus width,
high speed, multi-block and the capacity boundary, and the framebuffer
comes up at 640x480.  The eight markers this suite has that the Pi 3B's
has are exactly the eight peripherals QEMU does not map here.
.PP
.B "The last thing that was wrong was an interrupt number, and it did not fail."
.CW usbdwc.c
carried
.CW "USBIRQ = 9" ,
GPU IRQ 9, which is the Pi 3B's number for the same core.  Registering
it on a GIC-400 does not fail \- 9 is a perfectly legal INTID, an SGI
nobody raises \- so
.CW intrenable()
accepted the handler and the root port's connect-detect interrupt went
nowhere.  The port read back
.CW "hport0 0x1000" ,
power on and no device, and nothing enumerated, while
.CW "info usb"
in the QEMU monitor showed the hub and the network interface plainly
attached.  With
.CW "USBIRQ = IrqDwc2"
it reads
.CW 0x21001 ,
the same as the Pi 3B, and everything behind the hub appears.
.PP
That is the shape to expect from the rest of this port: a number that
means something different on the two machines, accepted silently by
both.
.NH 1
The boot, step by step
.PP
Console, MMU, GIC, and then, in order, on real BCM2711 addresses:
.CW "i2c: bsc0 at 0xfe205000" ,
.CW "spi: spi0 at 0xfe204000" ,
.CW "gpio at 0xfe200000" ,
.CW MBOX-OK ,
.CW "pm: watchdog at 0xfe100000" ,
.CW WDOG-PRESENT ,
.CW SYSTMR-OK ,
.CW OTP-OK
\- which reports
.CW "revision 0x00b03115" ,
the Pi 4 2GB board code, so the firmware interface agrees about which
machine this is \-
.CW DMA-OK
on channel 2 at 0xfe007200,
.CW AUX-OK
and
.CW AUXSPI-OK .
Then a synchronous external abort in the banner, which is the next
thing to chase.
.NH 1
Nine peripherals QEMU did not map here, and six of them were ours
.PP
This is the finding worth the most, and it is a codesign one.
.CW hw/arm/bcm2835_peripherals.c
has two realize functions: a common one every BCM SoC runs, and
.CW bcm2835_peripherals_realize() ,
which only the Pi 2 and Pi 3 machines run.  The Pi 4's realize calls
the common one.  So everything mapped by the Pi-3-specific realize is
absent on this machine:
.PP
.CW "ARMCTRL_TIMER0_1, BSC_SL, GPIO, I2S, MPHI, PWM, RNG, SMI, THERMAL" .
.PP
GPIO is not a gap \- bcm2838 maps its own.  The other eight are, and a
BCM2711 has every one of them in silicon.  This is the model being less
than the part, not the part being less than a Pi 3.
.PP
Six of the eight are models written for this port: PWM (0007), the ARM
timer (0009 and 0010), I2S (0011), SMI (0014) and the BSC slave (0015),
plus the thermal sensor which QEMU already had.  The work is to map
them for the Pi 4 as well, not to delete their drivers, and the drivers
are left in the tree untouched for that reason.  Only their calls are
out of
.CW main.c ,
with the reason written beside them.
.PP
The RNG is the one exception and needs a driver rather than a mapping:
a BCM2711 has a Broadcom RNG200 at that offset, a different block with
different registers, which QEMU models for no machine.  Driving the
BCM2835 driver at it is not a near-miss that reads zeroes, it is
.CW "esr 0x96000050"
at the first status read.
.PP
None of these fail quietly, which is worth saying because it is what
made them cheap to find: an unmapped offset in this window is a
synchronous external abort with the address in FAR, so each one names
itself in a trap dump on the next boot.
.PP
.B "Closed by patch 0021, for five of them plus MPHI."
The five a BCM2711 carries at the same offsets with the same
programming model \- PWM, I2S, SMI, the BSC slave and the ARM timer \-
moved to the base peripheral state and to the common realize, after the
I2C controllers because the BSC slave sits on BSC0's bus.  The Pi 4
suite goes from 30 markers to 35 with
.CW ARMTIMER-OK ,
.CW PWM-OK ,
.CW I2S-OK ,
.CW SMI-OK
and
.CW BSCSL-OK ,
each of which previously aborted; the Pi 3B is unchanged and
qtest-aarch64 stays 28 Ok, 0 Fail.
.PP
Two did not move, and the reasons are different from each other and
worth keeping apart.  The RNG is a Broadcom RNG200 on this part, a
different block with different registers that QEMU models for no
machine at all, so it needs a model and a driver rather than a mapping.
The thermal sensor is likewise a different block at a different address
on a BCM2711 \- moving
.CW bcm2835_thermal
would have asserted something untrue about the hardware in exchange for
a marker, which is the trade this document exists to refuse.
.PP
And the ARM timer is driven but its interrupt is not tested.  Its line
goes to the legacy controller, which QEMU maps on this machine and does
not wire to the GIC:
.CW bcm2838.c
defines
.CW GIC400_LEGACY_IRQ
and never uses it.  So
.CW ARMTIMER-OK
passes by polling and
.CW ARMTIMER-INTR-OK
is absent rather than failing.  Whether a real BCM2711 chains that
controller into the GIC, and on which line, is not something this
session established, so nothing was wired on a guess.
.NH 1
The card was on the wrong controller, in the model and in this port
.PP
.CW bcm2838
maps emmc2 at 0x340000, gives it
.CW sd-spec-version
3 and a capabilities register, and or-gates its interrupt with the
Arasan's.  Then it parents the card to the Arasan and never to emmc2,
so emmc2 was a controller fully present in the model and permanently
empty \- and this port, which inherited raspi3b's driver, talked to the
Arasan at 0xfe300000 and found a card there.
.PP
A BCM2711 does not put the microSD there.  It wires the slot to emmc2
on dedicated pins: that is what a Pi 4 boots from, and what Linux's
.CW bcm2711.dtsi
carries the card on,
.CW mmc@7e340000 .
GPIO 48-53, which raspi3b's driver muxes to move the card between
SDHOST and the Arasan, go to the header pins and to the SDIO the
wireless part sits on; they do not move the microSD at all.
.PP
So every SD marker this port was passing was passing against a
controller that has no card on the board.  Not a near-miss and not a
timing difference \- the driver would have found an empty slot on real
hardware and reported
.CW SDHCI-NONE .
That is the most expensive kind of divergence this document collects,
because nothing about it looks wrong until the board is on the desk.
.PP
Both ends are corrected.  Patch 0022 parents the card to emmc2 at
reset; the mux stays, because the pins and both controllers are real,
and now moves nothing.  The driver's base becomes EMMC2 and it stops
taking GPIO 48-53, which on this board would only steal pins from
whatever else is using them.  The whole SDHCI sequence then passes
against emmc2 \- bus width, high speed, multi-block, the capacity
boundary \- and SDHOST correctly reports
.CW SD-NONE ,
which is the right answer for a Pi 4 and not a failure.
.PP
Splitting the card off the Arasan splits the driver state with it.
.CW sdhcibcm.c
carried one static
.CW Ctlr
for both roles, which was right on a Pi 3B where both roles were the
same controller.  Here it is not:
.CW sdhcipnp()
sets that struct's base to EMMC2 at boot, so
.CW sdioinit() 's
own
.CW "if(c->r == nil)"
guard could no longer fire and the SDIO bring-up would have driven
emmc2 \- muxing GPIO 34-39 under a live card, and stepping on the
memory card's relative address on the way past.  Nothing caught it
because
.CW sdiocheck()
is behind
.CW -DSDIOTEST
and no build defines it, so this was a latent bug rather than an
observed one.  The SDIO role now has its own
.CW Ctlr ,
which is what two controllers on one board require; both compile
clean, with and without
.CW SDIOTEST .
.PP
.B "And that is why this board has its own init module."
.CW raspi4init.b
exists because of a real difference rather than for tidiness: the kfs
filesystem test reams a partition on the controller that has the card,
which is
.CW sdH0
here and
.CW sdM0
on a Pi 3B.  The board markers are
.CW RASPI4-OK
and
.CW RASPI4-SH-OK
so the two boards' logs cannot be confused for each other.
.NH 1
The RNG needed a model before it could need a driver
.PP
Of the nine peripherals the Pi 4's realize left unmapped, the RNG was
the one that could not be fixed by moving a mapping.  A BCM2711 does
not have the BCM2835 RNG.  It has a Broadcom RNG200 at the same offset,
a different block with a different register map, and QEMU modelled that
block for no machine at all \- so far from it that
.CW raspi4b.c
nops the
.CW brcm,bcm2711-rng200
node out of the device tree it is handed, with the comment
.CW "until they are implemented" .
.PP
So this one is a model as well as a driver.  Patch 0023 adds
.CW hw/misc/bcm2838_rng200.c
and maps it for bcm2838.  The register map and the bring-up sequence
are not recalled: they are taken from the driver Linux uses for this
block,
.CW drivers/char/hw_random/iproc-rng200.c ,
which is the published programming interface for it \-
.CW RNG_CTRL
at 0x00 with the enable in bit 0, both soft resets at 0x04 and 0x08,
.CW RNG_INT_STATUS
at 0x18, and a FIFO at 0x20 with its count at 0x24.  That mattered:
what was checked against the source contradicted what was remembered of
it, and three registers that had been about to be modelled from memory
are not in it at all.  Registers that driver does not name are not
modelled, and reads of them log rather than inventing a value.
.PP
.B "The FIFO is the part a driver has to get right."
This block will not give a word until the generator is enabled and the
count says one is there, and the model enforces both: an empty FIFO
reads back zero and says so in the guest-error log.  The BCM2835 model
is more forgiving than its own hardware here \- it hands out a word on
any read of the data register whatever the guest did to
.CW RNG_CTRL
\- so a driver that skipped the sequence would have passed on a Pi 3
and failed on the board.  That is the fifth audit category again: the
model was not asking the guest to be right about the hardware.
.PP
Which is why
.CW rng200check
starts with the negative half.  Before anything is written it reads the
count, and a non-zero count there is
.CW RNG-PREENABLE-FAIL
rather than a pass \- because reading distinct words after enabling
proves nothing on its own, a block that ignored
.CW RNG_CTRL
entirely would pass that too.  Only then does it run the documented
restart sequence, check the status is clean, read eight words and
require them distinct, and assert the reset to watch the count go back
to zero.
.PP
Two things in the model are inference rather than citation and are
labelled so in both the model and the driver: that clearing the enable
stops the FIFO refilling without discarding what is queued, and that a
soft reset holds the generator and empties it.  The driver depends on
neither, so neither can be checked against it.  The second earned its
place by failing first: with the reset modelled as emptying the FIFO
but not holding the generator, the count read back 16 immediately, and
the reset was unobservable.  A reset that a guest cannot see the effect
of is not a reset that has been modelled.
.PP
The interrupt, GIC SPI 125, is not driven.  The published interface has
status bits and no enable or mask register, so there is nothing to say
when the line should assert; the driver polls, as Linux's does.  For
the same reason the device-tree node stays on
.CW raspi4b.c 's
removal list: it declares an interrupt this model does not drive, and
there is no Linux guest here to test its return against.
.PP
.CW /dev/random
on this board now draws from the hardware rather than from
.CW randomvirtarm64.c 's
tick-seeded LCG, which its own comment calls smoke/dev only.  What that
proves under emulation is the plumbing, not the entropy: QEMU's
randomness is its host's.  That judgement still belongs to the silicon.
.NH 1
Where the suite stands
.PP
34 markers with a 16MB SD image, a FAT16 USB disk and USB ethernet, no
.CW -FAIL ,
and one guest-error log line, which is the deliberate out-of-spec read
of the RNG's data register before the generator is enabled.  Two
.CW -NONE ,
both of them correct answers rather than gaps:
.CW SD-NONE ,
because a Pi 4 has nothing on SDHOST, and
.CW USB-MOUSE-NONE ,
because no mouse was attached.
.PP
The Pi 3B suite has two markers this one does not, and each has its
own reason recorded above:
.CW THERM-OK
and
.CW ARMTIMER-INTR-OK .
.CW RNG-OK
was the third until the RNG200 was modelled and driven.
.NH 1
What is left
.IP \(bu
A thermal sensor: the BCM2711's is the AVS monitor, a different block
at a different address, and QEMU models it for no machine.
.IP \(bu
Settle whether the legacy interrupt controller chains into the GIC on
a real BCM2711, and on which line.  That is what
.CW ARMTIMER-INTR-OK
needs, and it is a hardware question rather than a modelling one.
.IP \(bu
The USB and SD paths, which should carry over unchanged \- the DWC2 and
both SD controllers are in the common realize \- once the boot reaches
them.
.IP \(bu
The Arasan, which on this board is the wireless part's SDIO rather
than a card controller \- the same Phase 6 that raspi3b is waiting on
hardware for.
