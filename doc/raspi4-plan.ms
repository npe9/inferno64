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
Nine peripherals QEMU does not map here, and six of them are ours
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
.NH 1
What is left
.IP \(bu
Map the eight peripherals above for bcm2838 in QEMU, which is the
codesign half, and re-enable their drivers and markers one at a time.
.IP \(bu
An RNG200 driver, and a QEMU model for it, since none exists.
.IP \(bu
emmc2, which is genuinely new on this board: a second SDHCI at
EMMC2_OFFSET sharing INTID 158 with the Arasan through an or-gate.
.IP \(bu
The USB and SD paths, which should carry over unchanged \- the DWC2 and
both SD controllers are in the common realize \- once the boot reaches
them.
.IP \(bu
A root file list and init module of its own; it currently borrows
raspi3binit, which is right while the marker suite is the same one.
