.TL
PyCubed in Inferno: an ordered plan, and what execute in place is worth
.AU
.PP
A plan for running Inferno on PyCubed \- Max Holliday's and Zac
Manchester's open-source CubeSat flight computer, flown on KickSat-2 \-
with the low-level work native in C and the flight software in Limbo.
Written from the sources
.CW ( github.com/pycubed/firmware
for the board,
.CW github.com/pycubed/software
and
.CW software_example_beepsat
for the flight code), and costed against measurements taken in this
tree.  Companion to
.CW doc/xip.ms ,
which has the execute-in-place mechanism and every memory figure quoted
here.
.PP
Numbers below are marked
.B measured
where they come from a build or a booted kernel in this tree, and
.B estimated
where they do not.  The distinction matters: the conclusion turns on one
figure nobody has measured.
.NH 1
The target
.PP
.CW pycubedv05_build/mpconfigboard.mk
names the part:
.CW SAMD51J19A .
A Cortex-M4F at 120MHz, 512K of internal flash, 192K of SRAM.
.CW mpconfigboard.h
adds 8192 bytes of internal NVM and a W25Q80DV \- a megabyte of external
QSPI NOR.  I2C on PB13/PB12, SPI on PA13/PA12/PA14, UART on PB02/PB03,
and the board's own lines: SD_CS, RELAY_A, BURN1, BURN2, EN_RF,
VBUS_RST, NEOPIXEL, with BATTERY and L1PROG on the ADC.  On the buses:
an RFM9x LoRa radio, a BMX160 IMU, a bq25883 charger, an adm1176 power
monitor, a GPS on the UART, an SD card.
.PP
The SAMD51's QSPI supports execute in place, mapping that external NOR
into the address space.  That is what makes this board the right one for
this work rather than merely a board that could run it.
.NH 1
Phase 0: software double precision.  Done
.PP
.B Done ,
by trap and emulate rather than the soft-double compiler mode this plan
first chose.
.I fptest (1)
passes all twenty-five lines on
.CW mps2-an386 ,
a Cortex-M4 with no double precision, exactly as on the Cortex-M7.  The
reason for the switch is better than the original reason for the other
route: the same kernel binary then runs on either core.  It is also much
the slower arrangement, a trap per double, and that is written down
beside the code.
.PP
The work is
.CW os/inferno/armv7m/fpiarmv7m.c
with
.CW fpregsave / fpregrestore
in
.CW l.s ,
and it is the whole of what follows in this section \- kept because the
reasoning about the two routes still applies to anyone who wants the
speed back.  One thing found on the way was not floating point at all:
this port's exception entry destroyed the interrupted code's R1 on every
exception, SysTick included, and
.CW doc/armv7m-ports.ms
has it.
.PP
The Cortex-M4F has FPv4-SP: single precision only.
.CW utils/tl/thumb.c
gives every
.CW F
register a
.CW D
register, so
.CW "tl -M -F"
names every function that would fault \- the Dis interpreter's real
arithmetic and all of libmath.  On a console board that is a footnote.
Here the flight software is floating point throughout: battery voltage,
charge current, IMU rates, attitude.  There is no useful subset that
avoids it.
.PP
Two routes.
.IP 1.
Emit calls instead of D instructions:
.CW utils/tc
grows a soft-double mode and a runtime library implements the
operations.
.CW AGENTS.md 's
"fix the tool, not the caller" points here, and it is the faster of the
two at run time.
.IP 2.
Trap and emulate, on the software floating point already in
.CW os/inferno/port/fpi.c
and
.CW fpimem.c ,
modelled on
.CW os/inferno/pc/fpi387.c ,
which is their only consumer in this tree.  Less compiler work, slower,
and it needs the M4's undefined-instruction path.
.PP
Take route 1.  The board is 120MHz and the attitude work is a real
workload, not a demonstration.
.PP
An earlier draft of this plan said this phase was the one place the
emulator could not help, on the grounds that the only emulated ARMv7-M
board here is a Cortex-M7 with double precision.  That was wrong, and
the experiment that disproves it is now in
.CW doc/armv7m-ports.ms :
QEMU's AN386 model is the same MPS2 with a Cortex-M4, same memory map
and same UART, so
.CW imps2
boots on it unchanged \-
.CW os/inferno/mps2/qemu-m4.sh
\- and
.I fptest (1)
takes a usage fault there on a
.CW VSUB.F64
while passing all twenty-five lines on the M7.
.PP
So this phase is fully developable without hardware, and it is the best
loop in the plan: write soft double in
.CW tc ,
run
.CW fptest
on
.CW mps2-an386
until the usage fault becomes
.CW FPTEST-OK ,
with the
.CW mps2-an500
run as the oracle for the answers.  Nothing about phase 0 waits for a
PyCubed board.
.PP
It also confirms something the plan asserted and could not show: a
console Cortex-M4 Inferno works today.  The kernel boots and a shell
runs on a core that cannot execute the double-precision instructions in
its own text, because an illegal instruction that is never executed
never faults.  Only real arithmetic is blocked, which is exactly why
this is a precondition for the flight software and not for the port.
.NH 1
Phase 1: the board
.PP
Less than it sounds, because the core is done.
.CW os/inferno/armv7m
already has the vector table, the exception path that builds a
.CW Ureg ,
.CW spl ,
SysTick, the exclusive monitor and the data-segment copy, all exercised
under QEMU; and
.CW os/inferno/nucleof303
is already a Cortex-M4 board beside it to copy the shape from.
.PP
A new
.CW os/inferno/samd51
holds what is genuinely the part: the GCLK/OSCCTRL/MCLK clock tree, NVIC
setup, the DSU and the bootloader hand-off, and
.CW mem.h
with the flash and SRAM map.
.CW KSTACK
starts at 4K \-
.B measured
to boot a shell on
.CW mps2
\- and
.CW NPROC
at 8.
.NH 1
Phase 2: the drivers, in C
.PP
In C, in the kernel, with device-table entries, because that is what
this tree does and because on this board it is also the only affordable
choice.  Every register-level driver in Inferno here is C; the Limbo
drivers that exist sit on top of one
.CW ( appl/cmd/usb/usbd.b
over
.CW os/inferno/port/devusb.c ).
Interrupts settle it independently: the RFM9x's DIO0 is an interrupt
line and only the kernel can be the handler.  And the memory settles it
again \- a C driver is text, which lives in flash; a Limbo driver is a
Dis module whose decoded
.CW Inst
array lives in SRAM.
.PP
What has to be written, with the tree's own model for each:
.IP \(bu
SERCOM as UART, SPI and I2C \- three instances of one peripheral.
.CW os/inferno/nucleof303/uartstm32.c
for the
.CW PhysUart
shape,
.CW os/inferno/raspi3b/spibcm.c
and
.CW i2cbcm.c
for the others.
.IP \(bu
GPIO, ADC, PWM, watchdog:
.CW gpiobcm.c ,
.CW pwmbcm.c ,
.CW pmbcm.c .
The ADC is battery voltage and charge current; PWM is the burn wires.
.IP \(bu
The four bus devices \- RFM9x, BMX160, bq25883, adm1176 \- which are
2091 lines of Python in PyCubed and become C here.  The radio is the
only one with an interrupt and the only one that needs a queue; the
other three are register reads on a schedule.
.IP \(bu
SD card:
.CW devsd.c
with
.CW sdmmc.c
and
.CW pmmc.c ,
already in the tree, over the SERCOM SPI.
.IP \(bu
The 8K internal NVM, as a small device, for the boot counters and flags
.CW lib/bitflags.py
keeps.
.IP \(bu
QSPI, which is phase 3.
.PP
Flash cost is not a constraint: the kernel text a comparable Cortex-M4
configuration
.B measures
is 245192
.CW ( os/inferno/nucleof303 ),
against 512K internal, and the drivers' text is
.B estimated
at some 25K on top.  What matters is their data and bss, which is
.B estimated
at 20K for the set \- for scale,
.CW mps2 's
one UART driver
.B measures
4416 bytes of data.
.NH 1
Phase 3: execute in place
.PP
Three pieces, in this order, all from
.CW doc/xip.ms :
.IP 1.
Emit the built-in root and the C string literals read-only, so they stay
in flash rather than being copied into SRAM by
.CW armv7m/l.s:/^_datacopy .
A change to
.CW utils/data2s/data2s.c ,
.CW os/inferno/port/mkroot
and the linkers' segment handling.
.B Done .
The root goes to text under
.CW ROOTINTEXT ;
the strings go under
.CW tl 's
.CW -t ,
after three bugs in that long-unused path were fixed.  Measured on
.CW teensy41 ,
30512 bytes of string literals and 139664 of root left RAM; on
.CW nucleof303 ,
25600 of strings.  See
.I "Strings to flash"
in
.CW doc/xip.ms .
.IP 2.
A QSPI driver that exposes the memory-mapped window, and
.CW Dev.xip
over it, so a module in external NOR is read where it lies.
.B "The file system half is done."
.CW os/inferno/port/devflash.c
serves a read-only file system out of addressable memory as
.CW #G ,
with
.CW Dev.xip
over it, and
.CW utils/mkflashfs
packs one.  A board points
.CW flashbase
and
.CW flashlen
at its window; on
.CW mps2 ,
which has no flash, the image is a
.CW RODATA
blob in the text segment and
.I echo (1)
runs from it without being copied.  What is left for this board is the
QSPI driver that makes the window appear \-
.CW os/inferno/riscv/spisifive.c
is the nearest precedent, and it deliberately declines the XIP path,
with a comment saying so \- and that needs the hardware.
.IP 3.
Pre-decode the
.CW Inst
arrays and tables into the QSPI window at build time and point
.CW m->prog
at flash.  No interpreter change.
.B "Done for the built-in root"
\- into the kernel's own text rather than a QSPI window, which is the
same mechanism with a different address:
.CW utils/dis2s
lays out the instruction arrays and the type descriptors, and
.CW mps2
and
.CW teensy41
carry nine modules including
.CW sh.dis .
The QSPI window is the remaining half, and it needs item 2.
.IP
The thing to settle first is settled.  Whether an immediate can be an
instruction's destination rather than a source: it can \-
.CW libinterp/dec.c 's
.CW D02
points
.CW R.d
into the instruction and
.CW brpatch()
does not forbid it \- and 4886 instructions across all 552 Dis modules
in the tree do exactly that.  All of them are array indexing
.CW ( IINDB ,
.CW IINDX ,
.CW IINDL ,
.CW IINDF )
with an
.CW AXINF
middle operand, so
.CW R.m
is a frame slot, never aliases
.CW R.d ,
and the immediate is read and not written.  With no middle operand:
zero.  It is a build-time refusal in
.CW dis2s
now rather than a property to rely on.  See
.CW doc/xip.ms .
.NH 1
Phase 4: the flight software, in Limbo.  Running on silicon
.PP
.B "It runs on a board, against a real radio and a real voltage."
Not a PyCubed \- that board is phases 1 and 2 and still needs buying \-
but a MikroElektronika clicker 2 for STM32 with a ccRF click, which is
the hardware
.CW doc/radio-plan.ms
spent its measurements on.  What it says for itself:
.DS
.CW "BEEPSAT-INIT-OK"
.CW "Beep-Sat, ported to Limbo"
.CW "hardware: stm32f407: battery real, from the part's VBAT channel"
.CW "BEEPSAT-RUNNING 4 tasks"
.CW "       vbatt | 3.30V < threshold 3.60V"
.CW "       vbatt | low battery detected"
.CW "        time | 20s since boot"
.CW "      beacon | sent 12 bytes"
.DE
.PP
.B "The 3.30V is a conversion, not a constant."
.I Adcbattmv ()
in
.CW os/inferno/stm32f407/adcstm32f4.c
reads the part's VBAT channel \- channel 18 through an internal
divide-by-two, RM0090 13.11 \- so a voltage this board actually has is
driving the mission's own low-battery policy path.
.B "That is the first time any of this software has reacted to a measurement."
.PP
.B "And the beacon leaves the board."
.CW "sent 12 bytes"
is a write the driver accepted, which is exactly the thing this bench has
learned not to believe, so it was checked at the other end.  A second
clicker 2 with the shell image, calibrated by
.I radiocfg (1)
and tuned to 915MHz, having transmitted nothing itself:
.DS
.CW "sent 0 recv 8   crcerr 0   last -17dBm"
.CW "lastrx 12 bytes: 48 65 6c 6c 6f 20 57 6f 72 6c 64 21"
.DE
Eight packets, one every thirty seconds, which is the beacon period; no
CRC errors; and the bytes are
.CW "Hello World!" ,
which is what
.CW beepsat.b 's
.I beacontask ()
writes.
.B "The payload and not the counter, because this part's sync detector fires on noise."
.PP
.B "What had to be added, and one of them was a real gap in the port."
.IP \(bu
.CW os/inferno/stm32f407/archfilespycubed.c ,
serving
.CW #P/{battery,imu,rgb,arch} ,
which is the boundary
.CW module/pycubedhw.m
defines.  The value of its
.B arch
file is saying which of the three are real: battery is; imu is invented,
there being no inertial part on a clicker 2, though mikroBUS 1 is empty
and
.CW #J
already enumerates whatever answers on I2C; and rgb is recorded rather
than displayed, deliberately, because this board has two LEDs and both
have owners \- LD1 is the radio's lamp and
.I idlehands ()
blinks LD2 \- and driving either from here would destroy a working
diagnostic to show a colour nobody is watching.
.IP \(bu
.B "The mission did not calibrate its radio,"
and that is the gap.  Nothing in it writes
.B freq
or
.BR ppm ,
so the radio sat at the driver's register-table defaults; with the two
clicker 2 crystals 64ppm apart \- 59kHz at 915MHz against a 25kHz filter
\- a beacon written, accepted by the driver and radiated into the wrong
place looks exactly like a radio that works.
.CW os/inferno/init/beepsatinit.b
applies it now, through the
.I Radiocal
library the AX.25 station already uses, and in the init rather than the
mission for the same reason: which crystal a board has is configuration.
.PP
What is in the tree:
.DS
.CW "  module/pycubed.m        the satellite state"
.CW "  module/pycubedhw.m      the hardware boundary"
.CW "  appl/pycubed/sat.b      the state server"
.CW "  appl/pycubed/beepsat.b  the tasks and cdh"
.CW "  appl/pycubed/hwstub.b   no hardware behind it"
.CW "  os/inferno/init/beepsatinit.b  boot into it"
.DE
523 lines of Limbo against the 540 lines of Python this part of
.CW software_example_beepsat/advanced
is
.CW ( main.py ,
.CW cdh.py ,
.CW Tasks/ ,
.CW lib/bitflags.py ).
.PP
What was ported and what was not, plainly.
.CW lib/tasko
is not ported: the four tasks are four processes with their own timers
and the state is a server answering on a channel, so the cooperative
scheduler, the managed-resource lock and the managed-SPI wrapper have
nothing left to do.  Neither is
.CW main.py 's
directory scan and its
.CW exec()
of each task file: the tasks are named in the source, so a typo is a
compile error rather than a task that silently never runs.
.CW debugcolor.py
is not ported, being ANSI colour for a terminal.  The four bus drivers
are phase 2 and are not here.
.NH 2
What a PyCubed has, and where each part lives in Inferno
.PP
From
.CW lib/pycubed.py ,
which is the file that touches all of it:
.DS
.CW "  RFM9x (SX127x) LoRa      SPI + 4 GPIO"
.CW "  micro-SD, FAT            SPI + 1 GPIO"
.CW "  BMX160 IMU               I2C"
.CW "  ADM1176 power monitor    I2C"
.CW "  BQ25883 USB charger      I2C"
.CW "  NeoPixel RGB LED         GPIO, one-wire timing"
.CW "  battery, charge current  ADC"
.CW "  burn wires x2            PWM"
.CW "  relay, VBUS reset, GPS   GPIO"
.CW "  GPS                      UART"
.CW "  NVM flags                MCU flash"
.CW "  watchdog, reset          MCU"
.DE
Where each goes, with what this tree already has:
.DS
.CW "  micro-SD, FAT   #S devsd + a controller driver,"
.CW "                  then dossrv for the FAT"
.CW "  LoRa radio      devether: a Medium at /net/ether0,"
.CW "                  IP over it"
.CW "  GPS             #t devuart"
.CW "  NVM flags       #F devflash, or devflashfs"
.CW "  reset           /dev/reboot in #c devcons"
.CW "  RTC             #r devrtc, but pc only so far"
.CW "  I2C sensors     #J devi2c for the bus, chip"
.CW "                  protocol above it"
.CW "  LED, burn wires, ADC   nothing"
.DE
The precedents are all here:
.CW devsd.c
with
.CW sdmmc.c ,
.CW sdspisifive.c
and
.CW raspi3b/sdhostbcm.c ;
.CW ethermedium.c
and
.CW pktmedium.c
under
.CW devether.c ;
.CW /dis/dossrv.dis
is already in
.CW mps2 's
root.
.PP
The last two lines are the finding.  Inferno has classes for storage,
networking, serial and display, and
.B nothing
for a sensor, a GPIO or an ADC on anything but a PC.
.CW os/inferno/raspi3b
carries
.CW i2cbcm.c ,
.CW spibcm.c ,
.CW gpiobcm.c ,
.CW pwmbcm.c
and
.CW thermbcm.c ,
all correct C, and its
.CW dev
section lists none of them: they are functions other C calls.
.CW thermbcm.c
reads the die temperature and no program outside the kernel can ever see
it, because there was nowhere to put it.  And
.CW devi2c.c
is in
.CW os/inferno/port
but its
.CW I2Cdev
header is only under
.CW os/osprey
and
.CW os/9front ,
so it does not build for Inferno as the tree stands.
.NH 2
The hardware boundary, which was wrong twice
.PP
First it was a module whose
.CW PATH
was a
.CW .dis ,
with
.CW battmv()
and
.CW radiosend()
as function calls.  A
.CW .dis
.CW PATH
can only be satisfied by a Limbo implementation, so the interface the
plan says C drivers will meet could not have been met by them.  Inferno
reaches hardware either through a device serving files
.CW ( appl/lib/daytime.b
reading
.CW /dev/time
is the pattern) or through a module implemented in C inside
.CW libinterp ,
declared
.CW "PATH: con \(fm$Name\(fm"
and listed in the conf's
.CW mod
section \- and that second one is for
.CW Math
and
.CW Keyring ,
not for device access.
.PP
Then it was
.CW sys->file2chan
over
.CW #s ,
which is how a Limbo
.I program
serves files and not how a
.I device
does.  Every reading left the kernel, went through
.CW #s
into another Dis process and came back: two scheduler switches and a
Chan round trip for a battery voltage, and 29504 bytes of pool for the
server.
.PP
Then it was a device called
.CW pycubed ,
.CW #H ,
holding four unrelated chips and named after a board.  That is not a
device class.  Inferno's answer to "this board has a register worth a
file" is
.CW addarchfile()
into
.CW #P ,
which
.CW os/inferno/pc/devarch.c
has had all along and which the ARMv7-M boards never got.
.PP
So
.CW os/inferno/armv7m/devarch.c
is that mechanism: the registry,
.CW addarchfile() ,
and the device that serves it, with the pc version's
.CW "iob, iow, iol and msr"
left behind because they are x86.
It was written into
.CW os/inferno/port
first, and that was wrong.  Every
.CW devarch.c
in the tree \(em
.CW os/inferno/pc ,
.CW os/inferno/pc64 ,
.CW os/9front/pc ,
.CW os/osprey/pc
\(em lives in a machine directory, and a portable one is not a shared
implementation but a second file of the same name defining the same
.CW archdevtab
and the same
.CW #P ,
which for a pc kernel is a collision rather than a choice.
.CW armv7m
is where mps2, teensy41 and nucleof303 already share
.CW l.s ,
.CW trap.c
and
.CW fpu.c ,
so it is where they share this; the declaration went with it, out of
.CW ../port/portfns.h
and into
.CW os/inferno/mps2/fns.h ,
spelled longhand the way
.CW os/inferno/pc/fns.h
spells it.
.CW os/inferno/mps2/archfiles.c
registers this board's, and there are no sensors on this board, so
.DS
.CW "; ls \(fm#P\(fm"
.CW "#P/arch"
.CW "#P/battery"
.CW "#P/imu"
.CW "#P/rgb"
.CW "; cat /dev/arch"
.CW "mps2: no sensors on this board, every reading is"
.CW "      invented"
.CW "; cat /dev/battery"
.CW "3960"
.DE
That is the right shape for the sensors and the LED.  It is
.I not
the shape for the radio or the SD card, and neither is stood in for: the
radio is a Medium under
.CW devether
and the card is
.CW devsd ,
both of which are drivers and not files to read.  The beacon task says
so rather than inventing traffic:
.DS
.CW "beacon | no radio on this board, nothing sent"
.DE
.NH 2
What it costs, which is the part that was an estimate
.PP
Static, from the
.CW .dis
headers, measured after the boundary was made right:
.DS
.CW "              .dis    Inst   data"
.CW "beepsat.dis   2657    4212    140"
.CW "hw.dis        1182    1980     84"
.CW "sat.dis        692     924    176"
.CW "              ----    ----   ----"
.CW "              4531    7116    400"
.DE
All of it flies.  What does not is C in the kernel, not Dis.
This document estimated 14900 bytes of
.CW .dis
for the mission, from 760 Limbo lines at 12 to 17 bytes a line.  The
port is 4531 bytes.  The estimate was high on both counts: the line
count counted Python that turned out not to need porting, and the bytes
per line, measured here at about 9, were taken from modules that do more
per line than mission logic does.
.PP
Running, from
.CW #c/memory
on
.CW mps2 ,
booted into the mission with no shell at all, forty seconds in:
.DS
.CW "  kernel data + bss     64920"
.CW "  Proc array            38720"
.CW "  main pool            109760"
.CW "  heap pool              9664"
.CW "                       ------"
.CW "                       223064"
.DE
against 255728 for the same kernel running a shell.
.PP
The three boundaries, measured the same way, are worth keeping side by
side, because most of the difference is the mechanism and not the
mission:
.DS
.CW "                    file2chan   #H dev   #P arch"
.CW "main pool              133248   114560    109760"
.CW "heap pool               23936    12608      9664"
.CW "kernel data + bss       62896    63272     64920"
.CW "                       ------   ------    ------"
.CW "                       258800   229160    223064"
.DE
The Limbo server cost 29640 more than a device.  Naming the device after
the board cost another 6096 over using the mechanism that was already
there, most of it the radio files that should never have existed.
.PP
That is the figure to carry forward, remembering that the four real
drivers will put their own code back in the kernel's text and their own
buffers in its pools.
.PP
Two honest qualifications.  This is
.CW mps2 's
device set, which is not minimal \- it carries
.CW ssl ,
.CW cap ,
.CW kprof ,
.CW keyring ,
.CW crypt ,
.CW math
and a 60-file root \- and the 256K budget elsewhere in this document
assumes the minimal one, which measured 156604.  And the four drivers
are absent: they will add their own code, their own buffers and their
own processes, and on the evidence of
.CW os/inferno/riscv/spisifive.c
and the uart drivers in this tree that is thousands of bytes each, not
hundreds.
.NH 1
Phase 4 detail: the flight software, in Limbo
.PP
The beepsat example is 3966 lines of Python and divides three ways.
.IP \(bu
.B "2091 lines become C" ,
phase 2: the four bus drivers.
.IP \(bu
.B "536 lines are deleted."
.CW lib/tasko
is a cooperative event loop, a managed-resource lock and a managed-SPI
wrapper, and it exists because CircuitPython is single-threaded.
Inferno has processes and channels.  This is the clearest gain in the
whole port: not ported, removed.  (A further 327 lines of its tests go
with it.)
.IP \(bu
.B "About 760 lines become Limbo:"
the mission logic
.CW ( main.py
68,
.CW cdh.py
58,
.CW Tasks/
346 \- beacon, battery, imu, blink, time), the policy half of
.CW lib/pycubed.py ,
and
.CW lib/bitflags.py
over the NVM device.
.PP
Two of those shrink once the link is the tree's rather than the
example's, for the reasons under
.I "What Inferno already answers"
below.
.CW cdh.py 's
58 lines are a pass-code, a dispatch table and two ways to run Python
sent from the ground; what replaces them is
.CW keyring->auth (),
.CW ssl->connect ()
and
.CW sys->export (),
which is setup rather than logic and has no per-command part to grow.
.CW lib/bitflags.py 's
masks and shifts become a file per flag.  The port in the tree still has
.CW cdh ()
in it, written as the Python writes it and labelled as the
demonstration it is, so that the two can be read against each other;
it is not what the finished thing should be.
.PP
Each
.CW Tasks/
entry becomes a process with its own channel rather than a coroutine
registered with a scheduler, which is a closer fit to what the code is
already trying to express.  The satellite state that
.CW lib/pycubed.py
holds as one object becomes a server with a file interface, so a task
can be restarted without taking the radio down with it.
.PP
.B Estimated
size:
.CW 760
lines of Python at a Limbo expansion of 1.4, and
.B measured
at 12 to 17 bytes of packed
.CW .dis
per Limbo line across
.CW usbd.b ,
.CW etherusb.b ,
.CW dhcp.b
and
.CW styx.b ,
gives about 14900 bytes for
.CW /osinit.dis .
Its library modules are
.B measured :
.DS
.CW "                 .dis     Inst   dsize    ss"
.CW "lib/bufio        4542     9348      56   960"
.CW "lib/string       5259    11292     168  1360"
.CW "lib/daytime      4778     8508     276   880"
.DE
.NH 1
What Inferno already answers, so it is not in the budget
.PP
Read against the tree rather than against the plan, a good deal of what
the beepsat example spends lines on is a thing Inferno has a mechanism
for, and some of those mechanisms are already linked into the
.CW mps2
kernel that boots here.  Those are not work.  What follows separates
them from what is, because the previous sections costed all of it.
.NH 2
The ground link, which is the large one
.PP
From
.CW advanced/cdh.py
and
.CW advanced/Tasks/beacon_task.py ,
read today: a ground packet is a four-byte authorisation code
.CW "b'p\exba\exb8C'" ,
then a two-byte command, then arguments.  Five commands:
.CW no-op ,
.CW hreset ,
.CW shutdown ,
.CW query
and
.CW exec_cmd .
.CW shutdown
checks a second four-byte constant,
.CW "b'\ex0b\exfdI\exec'" .
.CW query
is
.CW eval ()
of the argument and
.CW exec_cmd
is
.CW exec ()
of it.  The satellite listens for ten seconds after every beacon.
.PP
Both constants go over the air in clear, so one received packet is
enough to send any of the five, and two of the five run arbitrary Python
on the spacecraft.  That is not a criticism of a demonstration; it is
the reason the authentication question is worth answering with a
mechanism rather than with a constant.
.PP
Inferno's answer is not a better passcode.  It is that the link carries
Styx, that the link is authenticated and encrypted before any Styx
message crosses it, and that there is then no command table at all \-
the ground reads and writes files in a namespace the satellite chose to
export.
.CW hreset
is
.CW "echo reboot > /dev/reboot" ,
.CW query
is
.I cat
of the file that holds the reading, and
.CW exec_cmd
has no counterpart because what the ground may do is exactly what was
exported.  The authenticating step and the limiting step are the same
step.
.PP
The pieces are in this tree and in this kernel:
.DS
.CW "  keyring->auth(fd, info, setid)   module/keyring.m:242"
.CW "  ssl->connect(fd)                 man/2/security-ssl"
.CW "  #D/n/ctl: fd m                   man/3/ssl"
.CW "  exportfs, devmnt, devsrv         linked into mps2"
.CW "  $Keyring, $Crypt                 mod section; modchk(1)"
.CW "  libkeyring, libsec, libmp        lib section"
.CW "  /dis/lib/{ssl,auth,factotum}.dis  in the root"
.CW "  /dis/lib/styxservers.dis          in the root"
.CW "  /dis/auth/factotum.dis            in the root"
.DE
The load-bearing detail is that none of it requires IP.
.I Ssl (3)
is attached with
.CW "fd m" ,
a file descriptor number, and
.CW ssl->connect ()
takes a
.CW "ref Sys->FD" .
The device is a filter over whatever that descriptor is.  So a radio
that presents a file is enough: authenticate over it, push
.I ssl
onto it, serve the namespace through it.  No Ethernet medium, no IP
stack, no
.CW devip .
.CW $Keyring
and
.CW $Crypt
are already built into the
.CW mps2
kernel and
.I modchk (1)
says on a booted board that they answer, so the cost of this is a
.CW /dev/radio
and the mission code that opens it.
.PP
.B "This paragraph has now been run rather than argued."
Two
.CW mps2-an386
over a socket pair, with
.CW "radiostyx get dev/battery lora auth" :
.DS
.CW "  RADIOSTYX-LORA #L/0 addr 1"
.CW "  RADIOSTYX-PAYLOAD 251"
.CW "  RADIOSTYX-AUTH peer satellite secret 128"
.CW "  RADIOSTYX-SSL #D/0"
.CW "  RADIOSTYX-MSIZE 221 version 9P2000"
.CW "  RADIOSTYX-READ '3960"
.CW "  '"
.DE
and the satellite printing
.CW "peer ground"
for the same exchange.
.I Keyring (2)
proved each identity to the other over the radio and derived the key
.I ssl (3)
was given \(em not a constant in a program \(em and
.CW exportfs
settled on a message size nobody told it.  There is no
.CW devip
in that kernel.
.PP
Acknowledgement and retry are on for that, and have to be.  Both ends
of
.CW keyring->auth ()
send before either has received, so on a half-duplex radio their first
transmissions overlap and neither hears the other; carrier sense
cannot help two stations that start in the same instant.  It costs 15
and 17 transmissions for twelve messages.
.PP
The one thing that had to be fixed to get there was not in this tree.
The SX1276 model stopped its peer's queue the first time two stations
transmitted at once and never restarted it, so a symmetric protocol
could not get past its first exchange; see
.CW tools/qemu-patches/0037 .
Three changes were made to the guest to work around that before
anybody looked at the model, and all three were measuring it.
.NH 2
What that leaves not free, which is a message size
.PP
Styx assumes an ordered, reliable transport.
.I Ssl (3)
delimits messages and digests them \- it will refuse a corrupted read \-
but it does not resend one, so something under Styx has to.  The first
draft of this section said that was a reliable-datagram layer to be
written.  Reading
.CW lib/pycubed_rfm9x.py
says otherwise: the driver already carries one.  It is
RadioHead-compatible \- a four-byte header of destination, source,
identifier and flags,
.CW _RH_FLAGS_ACK
and
.CW _RH_FLAGS_RETRY ,
a sequence number, and
.CW send_with_ack ()
with
.CW ack_retries
and
.CW ack_wait .
Retransmission, ordering and addressing are there and are part of what
phase 2 ports to C anyway.
.PP
What is left is a size, and the first telling of it here was wrong.  It
said the gap was four bytes.  It is not, and the conclusion is different
too.
.PP
The RadioHead header leaves, in the driver's own words, 252 bytes of
payload.
.I Ssl (3)
then takes its own cut, which the first telling forgot:
.CW os/inferno/port/devssl.c:648
is
.CW "h = s.s->diglen + 2" ,
an SSLv2 record header of two bytes plus the digest, and
.CW ":654"
adds a third byte and padding when the cipher has a block length.  A
stream cipher does not \-
.CW encrypttab
gives
.CW rc4_256
a
.CW blocklen
of 1 against 8 for every DES variant \- so the honest figure for
.CW rc4_256
with
.CW sha1
is 2 + 20 = 22 bytes a message, and a packet carries 230 bytes of Styx.
.CW md5
would make it 234.  Dropping RadioHead for the SX127x's own framing
buys 3.  None of those reaches 256.
.PP
So the floor has to be dealt with rather than dodged \- and it turns out
to sit on only one side.
.CW os/inferno/port/devmnt.c:195
refuses an
.CW msize
below 256:
.DS
.CW "if(f.msize<256 || f.msize>1024*1024)"
.CW "	error(\(dqnonsense value of msize in fversion\(dq);"
.DE
That is
.I mount (2),
the kernel client.  The server does not agree with it.
.CW os/inferno/port/exportfs.c:808
refuses only below 64, and
.CW ":806"
is better than that:
.DS
.CW "if(iounit != 0 && iounit > 64 && iounit < r->msize)"
.CW "	r->msize = iounit;"
.DE
so a radio device reporting an
.CW iounit
of 230 makes the satellite's own server negotiate 230 without being
told.  And
.CW appl/lib/styx.b 's
.CW compatible ()
has no floor at all \- it takes the smaller of the two msizes and
returns it.
.PP
.B Measured ,
since this was written.
.CW os/inferno/radio/devradio.c
reports an
.CW iounit
of 251 \- 255 of FIFO less the four-byte RadioHead header \- and a
ground station asking for 8192 gets
.DS
.CW "RADIOSTYX-MSIZE 251 version 9P2000"
.CW "RADIOSTYX-READ '3960"
.CW "'"
.DE
which is
.CW /dev/battery
read off a satellite over the radio, with the message size settled by
the transport and nobody told to do it.  See
.I radiostyx (1).
.PP
Two corrections the measurement forced, neither of them on this list.
It did not work at first:
.CW exportfs.c 's
.CW exreadmsg ()
read the four-byte size field and then the rest, which is a byte-stream
reader, and a device that hands out one packet per read is right to
refuse a four-byte one.  It asks for a whole message first now.  And the
adoption does not survive
.I ssl (3):
.CW exportfs
reads the iounit of the file it was handed, which with
.I ssl
pushed on is the
.I ssl
device's and not the radio's, so the same exchange settles on 8192.
Styx over
.I ssl
over the radio does work, but the ground has to ask for a size the link
can carry rather than having one arrived at for it.
.PP
Which means the satellite needs no change.  The ground is the side that
has to give, and the ground is a workstation with none of the
constraints: either it speaks Styx from Limbo over
.CW styx.m
and
.CW styxservers.m ,
where there is no floor to hit, or its own
.CW devmnt
floor moves.  Neither is work on the spacecraft.
.PP
One caveat that comes with a 230-byte msize and is worth knowing before
it surprises someone: not every Styx message fits in it.  A
.CW Rstat
carries a
.CW Dir
with four strings in it and a
.CW Twalk
up to sixteen path elements, so long names and deep walks will not fit
and must be refused or split by the client.  Short names in the exported
namespace, and walking a few elements at a time, are the price of a
radio-sized message.
.NH 2
The rest of it, briefly
.PP
Each of these is a thing the Python spends lines on and Inferno spends
none.
.IP \(bu
.B "Task discovery."
.CW main.py
does
.CW "os.listdir('Tasks')"
and then
.CW exec ()
and
.CW eval ()
to import and instantiate each one.  Already not ported: the tasks are
named in the source, so a typo is a compile error rather than a task
that silently never runs.
.IP \(bu
.B "The scheduler."
.CW lib/tasko ,
536 lines plus 327 of tests, is a cooperative event loop with a
managed-resource lock and a managed-SPI wrapper, and it exists because
CircuitPython is single threaded.  Already removed: processes and
channels.
.IP \(bu
.B "Telemetry format."
The example beacons a string and would otherwise pack bytes by hand.
Here a reading is a file \-
.CW /dev/battery
answers
.CW 3960 ,
.CW /dev/imu
answers three lines \- and the ground reads the same files over the same
link, so there is no wire format to define, version, or keep in step
between the flight and ground software.  That much is already running.
.IP \(bu
.B "NVM flags."
.CW lib/bitflags.py
packs boot counters and flags into single NVM bytes with masks and
shifts, because the registers are scarce.  Over 8K of NVM a file per
flag is the Inferno idiom, and
.CW #F
.CW devflash
and
.CW devflashfs
with
.CW utils/mkflashfs
are in the tree.  The bit twiddling is not the mission's problem.
.IP \(bu
.B "Logging."
.CW lib/pycubed.py
mounts a
.CW VfsFat
at
.CW /sd ,
writes timestamped lines and makes numbered files.  The filesystem half
is
.CW #S
.CW devsd
with
.CW sdmmc.c
and
.CW /dis/dossrv.dis ,
which is already in
.CW mps2 's
root, and
.CW /dis/lib/bufio.dis
buffers.  What is free that is not obvious: the ground reads the logs
through the same authenticated namespace, so there is no
.I download
command and no file-transfer protocol.
.IP \(bu
.B "Time."
.CW /dev/time
in
.CW #c
.CW devcons ,
.CW /dis/lib/daytime.dis
and
.CW timers.dis ,
all of which
.CW mps2
has and
.CW pycubed/beepsat
already uses.  The battery-backed clock is not free: the only
.CW devrtc.c
in this tree is
.CW os/inferno/pc 's ,
which is the PC's CMOS clock, so a SAMD51 wants its own \- small, and
the same shape.  The GPS discipline of the clock is mission code either
way.
.IP \(bu
.B "Reset."
.CW timeout_handler ()
counts timeouts in NVM and soft-resets at 255.  The reset is
.CW /dev/reboot
in
.CW devcons ;
the counting stays mission code.
.PP
Software update is worth naming because it is the one place two of this
document's own answers pull against each other.  In Inferno the ground
writes a new
.CW .dis
into the satellite's file system over the authenticated link and the
next load picks it up \- no updater, no protocol.  But the whole point
of phase 3 is that a module's decoded
.CW Inst
array is laid out at build time and read in flash, so an uploaded module
is one that has to be decoded into SRAM instead, at the 1.76 ratio
measured in
.CW doc/xip.ms .
Uploading is therefore cheap and uploading
.I without
losing execute in place means re-packing the flash image, which is
.CW utils/mkflashfs
and
.CW utils/dis2s
run on the ground and the result written whole.  Neither is written
here; both are the tools that already exist, run somewhere else.
.NH 1
What execute in place is worth, in bytes
.PP
The whole point of the plan, so it gets its own arithmetic.  SRAM is the
binding resource: 192K, which is 196608 bytes.  Flash is not \- 512K
internal against 245192 of kernel text, and a megabyte of external QSPI
against something like 100K of root and pre-decoded modules.
.PP
The Limbo side, from the sizes above: 29479 bytes of packed
.CW .dis
in the root
.CW ( /osinit.dis
estimated at 14900, the three library modules measured at 14579), 58948
bytes of decoded
.CW Inst
(estimated 29800 for
.CW /osinit.dis
at the ratio the measured modules show, plus 29148 measured), and 7440
bytes of module data segments and stack extents, which are RAM either
way.
.DS
.CW "                              without XIP   with XIP"
.CW "kernel data+bss, less root          76652      76652"
.CW "  C string literals to flash            0     -24856"
.CW "  board drivers' data+bss (est)     20000      20000"
.CW "  root file system bytes            29479          0"
.CW "Proc array (NPROC 8) + pid hash     22048      22048"
.CW "pool: kernel floor                  78208      78208"
.CW "pool: decoded Inst arrays           58948          0"
.CW "pool: module data + stacks           7440       7440"
.CW "pool: Dis heap (est)                20000      20000"
.CW "                                   ------     ------"
.CW "                                   312775     199492"
.DE
.PP
.B "Execute in place saves 113283 bytes" :
24856 of string literals, 29479 of root file system, 58948 of decoded
.CW Inst .
Against 196608 of SRAM that is the difference between 159% of the board
and 101% of it \- between not close and one good measurement away.
.PP
It does not on its own close the gap.  What closes the last 2884 bytes
is any one of: the immortal-heap-object change, which would move the
load-time
.CW String
and array constants inside that 20000-byte heap estimate into flash too;
.CW NPROC
at 4 rather than 8, worth 10960; or the pool floor being smaller than
the figure used here.  Each is plausible and none is measured.
.NH 1
The figure that decided it, now measured
.PP
The pool floor was the gating item here: the largest single term in the
budget and the only one nobody had looked inside.
.CW #c/poolhist
now walks the pools block by block and totals the live bytes by size and
by the pc that asked for them
.CW ( os/inferno/port/alloc.c ).
.PP
Measured on
.CW mps2-an386 ,
stock configuration, before the shell is loaded \- which is the floor
this plan costed:
.DS
.CW "newproc   49536    kernel stacks, KSTACK 16K x three procs"
.CW "dtype     46080    Dis type descriptors"
.CW "addprog   22272    Prog structures"
.CW "newchan    5760    namespace"
.CW "qopen      2560"
.CW "strdup     1792"
.CW "newpath     768"
.DE
772 of the 810 live blocks are 128 bytes or less, 98816 bytes between
them, carrying 16200 bytes of block header.  At a shell the order swaps:
.CW dtype
70016 first,
.CW newproc
66048 second.
.PP
Three things follow, and two of them change this plan.
.IP \(bu
The stacks term is
.CW KSTACK ,
which the cheap cuts already halve twice over and which is verified to
boot at 4K.  Nothing new.
.IP \(bu
.CW dtype
is module type descriptors, built by
.CW parsemod
and immutable once built.  Pre-decoding into flash moves them as well as
the
.CW Inst
arrays, so execute in place is worth
.I more
than the 113283 bytes computed above \-
.CW doc/xip.ms
counted only the code.  How much more for this board's module set is not
measured; on
.CW mps2 's
it is 46080 bytes at the floor and 70016 at a shell, which is not a
rounding error.
.IP \(bu
Small blocks carry an 8% header tax that no trimming elsewhere removes.
.NH 2
And a correction the walk forces
.PP
The pools are charged their
.I arena ,
not their in-use figure.
.CW main
reads 194688 live with 329600 free beside it, so it had taken 524288
bytes from
.CW xalloc
\- exactly half a megabyte.  The budget above costs the pools at
.CW cursize
and so understates them.  On a part where
.CW main_pool_pcnt
and its fellows cap the arena, the cap is the number to count, which
makes the pool split in the cheap cuts a sizing decision rather than a
tidy-up.
.PP
That does not change the conclusion \- execute in place is still the
difference between not close and one measurement away \- but it does mean
the 199492 figure is a floor for the pool terms rather than an estimate
of them.
.NH 1
Order, and what each phase proves
.IP 0.
Software double precision.
.B Done :
.I fptest (1)
is
.CW FPTEST-OK
on
.CW mps2-an386 ,
by emulation from the fault rather than by a compiler mode.  No hardware
was needed.
.IP 0a.
The pool-floor histogram.
.B Done :
.CW #c/poolhist ,
and it changed the plan twice \- type descriptors join the
execute-in-place saving, and the pools are charged their arena rather
than their in-use figure.
.IP 1.
The
.CW samd51
board to a console.  Nothing here can be tested without the hardware,
which is the first point at which the board is required.
.IP 2.
The drivers, one at a time, each proved against the thing it drives:
the radio against a ground station, the IMU against gravity, the power
monitor against a known load.
.IP 3.
Execute in place, in its three pieces.  Each is measurable on any board
\- pieces 1 and 3 on
.CW mps2
under QEMU, before the hardware exists \- so this phase does not wait
for the board and should not.
.IP 4.
The Limbo flight software, against the drivers.
.PP
Phases 0, 0a and 3 need no PyCubed hardware and are where the work
should start \- and phase 0 now has a bench of its own, which it did not
when this plan was first written.  Phases 1, 2 and 4 need the board, and per
.CW AGENTS.md
writing them blind would produce another
.CW os/inferno/teensy41 :
a directory of code nobody can verify.
.NH 1
The three I2C parts, as drivers with scripted models behind them
.PP
A clicker 2 has none of the BMX160, ADM1176 or BQ25883 that phase 2
names, and the parts have not been bought.  So each is written as
.B "real I2C code that probes for its part, plus a scripted model that runs when none answers"
\- and the probe decides which.  One image works before and after the
parts arrive, which is the point of writing it that way round rather
than as a simulation to be replaced.
.PP
.B "Every file says which half is running,"
because a file that is both has to.  The register numbers are from the
datasheets and have never been read off a part on this bench.  Nothing
claims a part exists: the IMU refuses unless CHIP_ID reads 0xd8 and the
charger unless PART_INFO's PN field matches, so a wrong address or a
different Bosch part comes out as
.I "no part"
rather than as plausible numbers.  The ADM1176 has
.I no
identity register, which is the honest difficulty with it, and its probe
says it is
.B assuming
the part rather than claiming to have recognised one.
.NH 2
What the models do, and what they are for
.PP
.B "The pack counts down."
A millivolt per hundred milliamp-seconds, so 400mA walks it down
visibly:
.DS
.CW "source scripted   volts 4203   amps 397   charging 0"
.CW "...forty seconds later..."
.CW "source scripted   volts 3996   amps 403   charging 0"
.DE
Deliberately fast, and deliberately a ramp with noise rather than a
lithium curve \- no plateau, no knee, no internal resistance.
.B "Software tuned to its shape would be tuned to nothing."
What it is for is the threshold crossing: beepsat's vbatt task compares
against 3.6V, and this makes that comparison happen while somebody is
watching.
.PP
.B "The IMU turns, and the gravity vector sweeps because of it."
Still, and then tumbling:
.DS
.CW "mag 450 0 -4      gyro 6 -2 -4     accel 504 -9 876"
.CW "mag -100 437 6    gyro 12 -10 23   accel -105 -495 863"
.DE
Level reads 500 and 866 on x and z because the spin axis is tilted
thirty degrees first \- a spin about the axis gravity lies along
produces no sweep at all, which is true of the physics and useless as a
fixture.  The gyroscope reads the rate it was given, 7, -11 and 23
degrees a second, and every axis carries independent noise, because
.B "a reading without error is the one thing a real sensor never gives."
.PP
.B "The charger has all four states and a latching fault."
.DS
.CW "echo in on     ->  state fast    volts 3756 rising"
.CW "echo fault     ->  state fault   volts 3807 held"
.DE
Those are the transitions flight software gets wrong: input appearing
and disappearing as a satellite goes in and out of sun, a pack at
termination that must not read as discharging, and a fault that has to
be cleared rather than clearing itself.
.B "The path nobody can provoke is the path nobody has tested."
.PP
.B "One battery, one voltage."
.CW pwradm1176.c
owns the pack and
.CW chgbq25883.c
asks it to charge, so the charger making the voltage go up is one
decision applied in one place and the two files cannot disagree.
.NH 2
The line between a fixture and a lie
.PP
.CW #P/battery
is the file the mission reads, and it asks the pack
.I first
\- but the pack answers \-1 unless somebody has written
.CW "battery sim"
to
.CW #P/power.ctl .
So the default is the part's own VBAT channel, a real measurement, and a
simulated battery is something this board has to be
.I told
to report.  And
.CW #P/arch
says which is in force, in capitals when it is the simulation:
.DS
.CW "stm32f407: battery real, from the part's VBAT channel"
.CW "  ...after echo battery sim >#P/power.ctl..."
.CW "stm32f407: battery SCRIPTED, asked for with power.ctl"
.DE
with
.CW #P/battery
reading 3806 rather than the 3300 of the rail.
.B "A fixture that cannot be mistaken for a measurement is the whole of the difference,"
and it is one line of output rather than a convention anybody has to
remember.
.NH 2
The ctl files are dotted, which is a compromise
.PP
.CW imu.ctl
and not
.CW imu/ctl .
Every real device in this tree is a directory per instance with
.B ctl
inside it \-
.CW #W/radio0/ctl ,
.CW #a/N/ctl ,
.CW #J/i2c3/i2c.68.ctl
\- and that is the shape these want.
.I Addarchfile ()
cannot express it, because
.CW #P
is a flat table of board files, so they take the convention
.CW #J
uses for the same reason.
.B "The directory form is what a real driver should be"
\- a device of its own rather than three entries in
.CW #P
\- and that is the phase 2 this stands in for.
.NH 1
The satellite can be commanded, which it could not before
.PP
.B "cdh() had no caller."
It has been in
.CW beepsat.b
since the port, a pass-code and a dispatch table faithful to
.CW cdh.py ,
and nothing ever called it \- the Python polls the radio inside its
cooperative scheduler and there was no equivalent here.
.CW module/pycubedhw.m
said all along that the radio file reads as well as writes;
.CW hw.b
had no
.IR radiorecv ().
.B "So the satellite could beacon and could not be told anything,"
which is half a spacecraft.
.PP
It is a process of its own rather than a poll, because
.IR radiorecv ()
blocks and because that is what Inferno has instead of a scheduler \-
the same argument that deleted
.CW lib/tasko .
Five tasks now, not four.
.NH 2
And a way to key an exact payload, which a shell did not have
.PP
.B "Inferno strings are UTF-8,"
so
.I echo
of any byte above 0x7f emits two.  The first thing that wanted to send
the mission's four-byte pass-code from a prompt \- 70 ba b8 43 \- could
not, which left the command path untestable from the board that is meant
to do the commanding.  So the radio's
.B ctl
takes a payload as hex:
.DS
.CW "echo send 70 ba b8 43 51 55 >/dev/radio0/ctl"
.DE
That is the instrument's job rather than a test hook;
.B txtest
beside it sends a canned pattern of a given length, which answers a
different question.
.NH 2
Measured: a command and telemetry loop over two real radios
.PP
Ground station on one clicker 2 with the shell image, calibrated by
.I radiocfg (1)
and tuned to 915MHz; the mission on the other.  What the satellite said,
in the order the ground keyed them:
.DS
.CW "BEEPSAT-RUNNING 5 tasks"
.CW "cdh | bad pass-code"
.CW "cdh | short packet, not a command"
.CW "cdh | query: boots 1 errors 0 responses 0 minimum"
.CW "cdh | no-op"
.DE
.B "The two rejections are the control."
A ten-byte packet of ASCII reached
.IR cdh (),
passed the length check and failed the pass-code; a two-byte one was
refused for length; and then the same path accepted
.B QU
and answered with the satellite's own state, and
.B NO
and logged the no-op.  So the loop is
.B "beacon down, commands up,"
on real parts over a measured link.
.PP
.B "What this is not."
The pass-code is four constant bytes in clear and the original says so;
this port says so too.  The plan's answer is above, under
.I "What Inferno already answers"
\- the link should carry Styx authenticated with
.IR keyring->auth ()
and encrypted with
.IR ssl (3),
and then there is no command table at all: the ground reads and writes
files in a namespace the satellite exported, and
.B HR
is a write to
.B /dev/reboot
from the other end rather than a case in a switch.
.B "The receive path this adds is what that will sit on."
.NH 1
Styx over the radio: the link forms, the export serves, and the message size will not fit
.PP
.B "This is the first hard no on this bench that is arithmetic rather than a bug,"
and it is the measurement the plan asked for.
.CW os/inferno/init/armv7mstyx.b
is both ends \- the board whose
.B /lib/radio
role is
.B answerer
announces on
.CW #a ,
accepts, and hands the connected conversation to
.IR sys->export ();
the
.B caller
connects and mounts it.  Which end a board is comes out of its own
serial number, exactly as the AX.25 station roles do.
.PP
Both ends got further than anything before them:
.DS
.CW "satellite: accepted on #a/1, iounit 109 of a carrier's 125"
.CW "           ARMV7M-STYX-EXPORTING"
.CW "ground:    linked to N0CALL-2 on #a/0, iounit 109"
.CW "           styx: mount: nonsense value of msize in fversion"
.DE
.PP
.B "The chain of numbers, and every one of them is in a file in this tree."
The CC1120 carries a 125-byte packet.
.CW os/inferno/radio/devax25.c
takes sixteen of that for the address field, so a connected
conversation's information field is 109 \- and it
.I refuses
a longer write rather than segmenting it:
.DS
.CW "budget = ax25.iounit - hdrlen(cv);"
.CW "if(n > budget) error(\(dq... past the ... information field\(dq);"
.DE
.CW os/inferno/port/devmnt.c
clamps the Styx message size to the channel iounit and then rejects its
own clamped value:
.DS
.CW "if(f.msize<256 || f.msize>1024*1024)"
.CW "	error(\(dqnonsense value of msize in fversion\(dq);"
.DE
.B "109 against a floor of 256."
And the part cannot be made to cover it: even in the CC1120's
infinite-length mode a 255-byte packet leaves AX.25 with 239, which is
still short of 256.
.NH 2
The three ways through, and which one is the protocol
.IP 1.
.B "Segment below Styx, which is the missing layer and the right answer."
A reliable ordered byte stream over small frames is what segmentation is
for, and AX.25 2.2 has it: a Segmenter/Reassembler with a SEG field,
precisely so an information field smaller than a client wants is not the
client problem.
.CW #a
is ours, so this is buildable rather than a hope.  It also leaves
.I devmnt
alone, which matters because that file is every board.
.IP 2.
.B "Lower devmnt's floor."
One constant, and the honest objection is not that 256 is sacred but
that at 109 every Styx message has to fit, including a Tstat for a long
name, and the failure mode is a mount that works until a filename gets
longer.  It is also a port file: that change is on every board in the
tree to buy one radio a link.
.IP 3.
.B "Make the packet bigger."
Worth doing for its own sake \- the CC1120 can refill the FIFO during
transmission \- but it does not reach the floor on its own, so it is a
thing to want rather than a fix for this.
.PP
.B "What is left standing."
The link, the export and the role selection all work; the init is the
harness whichever of those three lands.  And the claim the plan made \-
that Styx over this radio needs no IP stack \- is not refuted: nothing
in the way is an address or a route.  It is one subtraction.
.NH 1
Styx over the radio works, and a multi-frame read is corrupted
.PP
.B "The ground station mounts the satellite and reads a file off it."
This is what the plan has called the whole argument since it was
written, and it is measured:
.DS
.CW "ARMV7M-STYX-MOUNTED"
.CW "styx: the satellite says battery 3300"
.CW "styx: the satellite says battery 3302"
.CW "styx: the satellite says battery 3304"
.DE
.CW /n/dev/battery
on the ground is
.CW #P/battery
on the satellite, which is a conversion of that part's own VBAT channel
\- so the number moves between reads because it is a measurement and not
a constant.  No IP stack, no addresses, no routes: an AX.25 conversation,
a pipe, and
.IR sys->export ().
.PP
The whole exchange is visible because the relay prints its first few
transfers each way:
.DS
.CW "Tversion 19   Rversion 19"
.CW "Tattach  26   Rattach  20"
.CW "Twalk    31   Rwalk    35"
.CW "Topen    12   Ropen    24"
.CW "Tread    23   Rread    16"
.CW "Tclunk   11   Rclunk    7"
.DE
.NH 2
Three walls, in the order they appeared
.IP 1.
.B "devmnt refuses a message size under 256"
and clamps what it asks for to the channel iounit, which on an AX.25
conversation here is 109.
.B "Cleared by putting a pipe between Styx and the radio:"
the pipe reports 65536, Styx talks to one end of it, and two processes
shuttle bytes between the other end and the conversation, chopping
writes into pieces the information field holds.  Segmentation in Dis
rather than in the device, which is where this tree puts userland \- and
sufficient rather than needing AX.25 2.2's SEG field, because the
conversation is already reliable and ordered and a Styx reader puts a
message back together by its length prefix.
.IP 2.
.B "exportfs wants 8216 bytes of main pool before any size is negotiated,"
and this board has about 80K of main pool in total:
.DS
.CW "exportproc 7: waiting for memory (8216) for request"
.CW "arena too large: main size 9176 cursize 38464"
.CW "  arenasize 79360 maxsize 81900, alloc = 9344"
.DE
It then retries for ten minutes and gives up, which from the far end is
a mount that never answers \- although its Tversion had already crossed
the air, nineteen bytes, logged at both ends.
.B "Cleared by making the figure a variable instead of a constant:"
.B exportmaxrpc
in
.CW exportfs.c
and
.B mntmaxrpc
and
.B mntqueuerpcs
in
.CW devmnt.c ,
set to 512 by this board in
.IR archreset ().
Not a conditional, because this tree does not conditionally compile, and
every board that says nothing gets what it had before.
.IP 3.
.B "The satellite has to be listening before the ground calls it."
Obvious afterwards; it cost two runs that read as a hung mount.
.NH 2
And the fault that is still open: a read bigger than one frame comes back wrong
.PP
.CW /n/dev/arch
is 273 bytes, which is three frames.  The first attempt printed it with
its first and last lines intact and the middle full of binary, and
.B "that appearance has two possible causes"
\- the relay rejoining the message wrongly, or the console mangling a
273-byte print while other processes were printing.  The content cannot
tell them apart, because this end does not know what the far end holds.
.PP
.B "Two reads can."
If the transfer is sound they are identical whatever the console then
does to them.  They are not:
.DS
.CW "styx: 273 bytes over the radio, twice"
.CW "styx: the two reads differ at byte 82, so the transfer"
.CW "      is corrupting data"
.DE
So it is the transfer and not the console, which is the opposite of what
the first appearance suggested.
.B "And byte 82 is before the first chop boundary at 109,"
which points away from the chopping and at something underneath it \- a
duplicated or reordered I frame would be the first thing to look at,
since a Styx reader counting a length prefix cannot tell wrong bytes
from right ones.
.PP
.B "What stands and what does not."
Single-frame Styx over this radio works and has been read twenty times
running.  Multi-frame does not, and the thing that says so is a control
rather than an inspection.
.NH 2
And the message size, made the window times the information field
.PP
512 was the first figure and it was round rather than right.
.B "The appropriate number is derived from the carrier,"
and every term is in a file in this tree:
.DS
.CW "  CC1120 FIFO 128 = 1 length + 125 payload + 2 CRC"
.CW "  so cc1120.c maxpayload 125, #W/radio0/data iounit 125"
.CW "  devax25.c address field (2+ndigi)*7+2 = 16"
.CW "  so a conversation's information field is 109"
.CW "  devax25.c Defk, the window, is 4"
.CW "  4 * 109 = 436"
.DE
A Styx message of exactly 436 is four I frames: no partial frame wasted,
and no acknowledgement wanted in the middle of one message.
.PP
.B "512 is not merely untidy, it is a second of silence per message."
It needs five frames, the fifth is outside the window, and
.I devax25
delays an acknowledgement by
.B Deft2
\- a thousand milliseconds, deliberately, because an RR sent sooner
lands on a transmitter that is still talking.  So every message over 436
bytes stalls in the middle of itself.
.PP
The board says what it got, rather than the figure being asserted here:
.DS
.CW "styx: the mount carries 412 bytes a message, so msize 436"
.CW "      over 109-byte frames: 4 frames, and the window is 4"
.DE
412 is 436 less the 24 bytes
.I exportfs
keeps for a header, and it is what Limbo sees as the atomic size of a
read or a write on
.BR /n .
.B "A digipeater would make this wrong"
\- each hop adds seven bytes to the address field, so one hop gives 102
and the figure should be 408 \- and that line is where it would show.
.PP
.B "And it changed the open fault's symptom, which is itself a finding."
At 512 a 273-byte read came back corrupted at byte 82.  At 436 the same
read does not come back at all.  Same code, same boards, one constant
different: so the multi-frame path is sensitive to how a message divides
into frames, which is a much narrower thing to go looking for than
\(dqsomething is wrong with the relay\(dq.
.NH 2
The multi-frame read completes, and what it cost to get there
.PP
.B "Three numbers, each measured, each wrong the first time."
.IP 1.
.B "The pool split."
50/49/1 is the shell image's, measured at a prompt where the Dis heap
holds the shell.  A satellite runs no shell and its heap is nearly idle
while main carries exportfs's buffer per request, two pipe queues, the
AX.25 retransmission window and every Block the radio receives into.
74/25/1, and it is per image now through
.B image-<init>
and
.CW -DMAINPCNT ,
like NPROC.
.IP 2.
.B "The process count, and a slot is not free."
.CW os/inferno/port/proc.c
does
.CW xalloc(conf.nproc*KSTACK) ,
so fourteen slots is 57344 bytes taken before the pools can grow into
what is left.  Ten was too few \- the satellite answered a Tversion and
then said
.CW "no procs for kproc"
at the Tattach, because
.I exportfs
starts an
.B exslave
per request whenever none is waiting.  Twelve.
.IP 3.
.B "And the shape of the memory, which is why fourteen was expensive."
The boot line says it:
.DS
.CW "6 holes free"
.CW "10000000 10010000 65536"
.CW "20008000 20020000 98304"
.DE
.B "Two non-contiguous regions,"
64K of core-coupled memory and 96K of SRAM, and a pool's arena cannot
span them.
.I Proc.c
puts the kernel stacks in the second \-
.CW "kernel stacks of 4096 at 0x20008010"
\- so every slot is 4096 bytes taken out of exactly what the pools have
left to grow into there.  main reached cursize 42176 against a maxsize of
121212 it could never approach, which is why the pool reported tens of
kilobytes free while
.I smalloc
sat waiting for 300 bytes.
.PP
.B "The instrument had a slot of its own, and now does not."
A process printing
.CW #c/memory
every twenty seconds cost 4096 bytes of the SRAM it was measuring.  It
reads once now, from the init's own process:
.B "an instrument that consumes what it measures is worth one reading rather than a stream."
.NH 2
Where it stands
.PP
.DS
.CW "ARMV7M-STYX-MOUNTED"
.CW "styx: the mount carries 412 bytes a message, so msize 436"
.CW "      over 109-byte frames: 4 frames, and the window is 4"
.CW "styx: the satellite says battery 3304"
.CW "styx: 273 bytes over the radio, twice"
.CW "styx: the two reads differ at byte 207"
.DE
.B "The 273-byte read completes now, twice, and the link survives it"
\- where before it hung and took the conversation down with it.  What
remains is that the two reads are not identical, and the satellite is
still saying
.CW "smalloc: 300 not available, waiting"
while it serves.
.B "A frame dropped because the pool was empty is the obvious candidate,"
and the figure to go after next is what holds main's 42176 bytes:
.CW #c/poolhist
is in this kernel for that, and is phase 0a of this plan.
.PP
.B "The three symptoms in order, since the sequence is the evidence:"
corrupt at byte 82 with msize 512; hanging at msize 436; completing and
corrupt at byte 207 with the pool and slots corrected.  Each change
moved it, which is what says the remaining fault is in the same place as
the last three.
.NH 2
Why smalloc blocking is fatal, and the question to ask next
.PP
.B "smalloc waits for ever by design."
.CW os/inferno/port/alloc.c
says so in as many words \- "this loop waits for ever by design, the
caller cannot be told no" \- and prints once per call rather than once
per retry.  So a 300-byte request the main pool cannot meet does not
fail: it blocks the process that made it, indefinitely.
.PP
That is why the stall takes the link with it.  The chain is
.B "pool cannot give 300 bytes \(-> a Styx server process blocks in smalloc \(-> no reply crosses the air \(-> T1 expires N2 times \(-> the conversation disconnects."
Every layer behaves correctly and the symptom appears at the far end as
a radio fault.
.PP
.B "The pc in that message is the caller,"
not smalloc's own frame \- the comment above it records being caught out
by exactly that once and fixing it.  Resolving it needs a symbol table
and the kernel is linked
.B -H4 ,
a raw image with no header, so
.I inm
cannot read it; relinking the same objects at the same addresses without
.B -H4
produces a file
.I inm
also declines, which is a tooling gap worth closing before the next
capture rather than during it.
.NH 2
The question, which is about where memory IS and not how much
.PP
.B "This part has two RAM regions and they are not interchangeable."
.DS
.CW "10000000 10010000 65536    core-coupled memory"
.CW "20008000 20020000 98304    SRAM"
.DE
.CW archstm32f407.c
gives the second to
.B conf.base1 ;
.I xinit
adds both as holes, sorted, with the core-coupled one first; and
.I procinit
then puts the kernel stacks at
.CW 0x20008010 ,
which is sixteen bytes into the SRAM one.
.B "So the stacks did not come from the region that is listed first,"
and the pools, which are built before
.I procinit
runs, have taken whatever they took before that.
.PP
Two things follow and both want reading rather than tuning.
.IP \(bu
.B "Why does a 49152-byte request go to SRAM when a 65536-byte hole is listed ahead of it?"
If it is best-fit rather than first-fit then the stacks are in the wrong
place for this board, and kernel stacks are exactly what core-coupled
memory is for \- never DMA'd, always hot.  Moving them there would hand
the whole SRAM region to the pools.
.IP \(bu
.B "Can main have a second arena in the other region?"
A pool with one arena is limited by one hole; a pool that can hold two
is limited by their sum.  main stops at cursize 42176, which is less
than either region, so whichever hole its arena is in has no room left
and the other is not being reached.
.PP
.B "What is NOT the answer, having each been measured:"
the message size (436 is the window times the information field), the
process count (twelve, counted against what exportfs and #a start), the
pool split (74/25/1, against a heap that uses 17152 of 40950), and the
pipe queue (tried, backed out, and refuted by the pool report showing a
contiguous-run failure rather than a shortage).
.NH 1
Attitude control, and the devices becoming a model
.PP
The IMU reported a tumble and nothing could act on it: the rate was
whatever
.B imu.ctl
was last told.
.B "A sensor nothing can act on is a fixture;"
a sensor whose reading responds to an actuator is a model, and that is
the difference between giving flight software numbers to read and giving
it something to control.
.PP
Three pieces, each measured:
.IP \(bu
.B "Magnetorquers at #P/torque,"
and the rate responds to them through T = m x B.
.IP \(bu
.B "B-dot in the mission,"
m = -k dB/dt, which is what CubeSats fly: no attitude estimate, no sun
sensor, no orbit model, no inertia tensor, only two magnetometer
readings and the interval between them.
.IP \(bu
.B "Solar input as a function of attitude,"
so the control has a consequence the battery file can report.
.NH 2
The model had to be rewritten, and the new one is simpler
.PP
The first version was an angle about one axis and a pair of sines.  It
was not merely crude \- the field responded only to rotation about z, so
B-dot could damp only z.
.B "A three-axis tumble fell to exactly 11.0 deg/s and stopped there,"
because two of the three rates moved nothing the magnetometer could see.
It reads as a controller that stalls.
.PP
The field, gravity and the sun are all fixed in the world; what turns is
the body.  So each of them obeys
.CW "dv/dt = -omega x v"
in the body frame \- three multiplies, no trigonometry, and responsive
to rotation about every axis because that is what a cross product does.
.B "Measured with it: 20.4 deg/s to 1.1 in about two hundred seconds, monotonic, no plateau."
.NH 2
Five faults, each of which looked like something else
.IP 1.
.B "The gyroscope reported whole degrees where the protocol says milli-units"
\- both halves of the driver \- so the scripted model added its noise,
documented as ten milli-units, to a value in degrees.  Ten DEGREES a
second on a rate of twenty: the first controller run read 14, 22, 26,
18, 28, 34 and looked like it did nothing while the rate moved
underneath it.
.IP 2.
.B "#P/imu.ctl showed stale state,"
because the model advanced only when
.B #P/imu
was read.  Probing the torque law through the ctl file showed a rate
that never moved: a model ignoring its actuator, and a model nobody had
advanced.
.IP 3.
.B "The gain was twenty-three times too big, which read as an inverted sign."
The rate rose monotonically.  The model was then tested on its own from
a prompt with a dipole worked out by hand, and damped \- 20000 to 18995,
18577, 18912, 18699, with a ripple because a fixed dipole gives a
sinusoidal torque as the body turns.  So the law was right and the loop
was overshooting between samples.
.IP 4.
.B "The deadband was set below what the loop can reach."
The rate decays cleanly and then plateaus at 0.86 deg/s, where integer
truncation stops the correction before the rate stops.  0.86 is a
detumble \- missions quote about a degree a second \- but a deadband
under a controller's own floor is a loop that never hands over, and the
sun task sat silently skipping every sample.
.IP 5.
.B "And the charger pushed a flag that went stale."
It evaluated "am I charging" when its own files were touched and stored
the answer where the answer was used.  The init writes
.B "in on"
to the charger and then
.B "volts 3700"
to the pack, so the charger decided while the pack was still at its 4200
default, concluded it was full, and set charging to zero.  Nothing
re-evaluated it.
.B "The sun-seeking controller then read \(dq0mA of 260\(dq on every sample for an hour, steering by a number no attitude could change."
Now the charger exports only what it knows \- input present, not faulted
\- and whether charging is happening is derived where the pack's voltage
is, every time the pack moves.
.NH 2
What it does, and the limit it has
.DS
.CW "detumble | rate 20.449 deg/s ... down to 1.099, monotonic"
.CW "detumble | settled, torquers off"
.CW "sun | 107mA of 260, turning 1, m 237 -439"
.CW "sun | 105mA of 260, turning -1, m -211 452"
.CW "sun | 121mA of 260, turning -1, m -17 498"
.CW "vbatt | 3.65V > threshold 3.60V"
.DE
.B "The battery fell to 3.18V while tumbling and recovered to about 3.63 once detumbled and steering."
The panel current responds to attitude and the controller reverses when
it falls, which is the hill-climb working on a real measurement.
.PP
.B "The limit is that it points about one axis only."
The dipole construction
.CW "m = c(By, -Bx, 0)"
gives a torque
.CW "Tz = c(Bx^2 + By^2)" ,
steady in sign however the body turns \- which is why it can point at
all, a FIXED dipole giving a sinusoidal torque that averages to nothing.
But one axis cannot bring an arbitrary sun direction onto a panel, so
the hunt settles at whatever the best reachable attitude is rather than
at full sun.  Three orthogonal laws would fix it and the geometry to do
it is already here.
.PP
.B "And two panels rather than one, which is a geometry and not a convenience."
One panel reads zero over a whole hemisphere, so a controller steering
by its current has no gradient for half of all attitudes \- which is
exactly what the first sun-seeking run did, turning one way for ever.
A 1U carries cells on several faces.
.NH 2
The allocator policy, which is about who asks rather than first or best
.PP
.I Xallocz
is
.B "first fit"
\- it walks the hole list and takes the first that fits.  That is right
when memory is one region and wrong when it is two of unequal size:
whatever asks first gets the big one.
.PP
On this part the hole list is ordered by address, so the core-coupled
64K at 0x10000000 comes before the 96K of SRAM at 0x20008000, and the
pools are built before
.IR procinit .
So main and the heap took the core-coupled region between them \- 37696
and 16896 \- and the kernel stacks took SRAM from its very start.
.B "main then could not find 300 bytes while reporting 83500 it could never reach,"
and
.I smalloc
blocked for ever, which took the AX.25 conversation down with it.
.PP
.B "The policy that matters is not first or best, it is who asks."
.IP \(bu
.B "Something that will come back for more wants the LARGEST hole."
A pool takes a chunk whenever it grows and is then capped by whatever
region that chunk came from, however much memory is elsewhere.
.I Poolalloc
uses
.I xalloclargest
now.
.IP \(bu
.B "Something fixed wants the SMALLEST that fits."
The kernel stacks are a fixed number of fixed-size blocks, allocated
once and never freed, and they are also what core-coupled memory is
for on a part that has it: never a DMA target, always hot.
.I Procinit
uses
.IR xallocsmallest .
.LP
Two entry points and no new rule for the callers that have been living
with first fit.
.PP
.B "Measured: the satellite now serves a mount with no smalloc wait and no Block starvation."
Neither
.CW "no free Blocks"
nor
.CW "smalloc: 300 not available"
appears at all, where both had been firing on every third Styx message.
.NH 2
And what is left of the multi-frame read
.PP
.DS
.CW "styx: 273 bytes over the radio, twice"
.CW "styx: the two reads are 273 and 271 bytes, so the"
.CW "      transfer is losing data"
.DE
.B "Two bytes short, which is a different fault from the three before it."
The sequence is worth keeping because each fix moved it: hanging at
msize 436; corrupt at byte 82 with msize 512; corrupt at byte 207 with
the pool split and slot count corrected; and now complete but two bytes
short with the allocator placing things where they fit.
.PP
.B "A short read is a narrower thing to chase than a corrupt one."
It says the message was framed correctly and that the count in the Rread
header disagreed with what arrived, so the next place to look is a
boundary \- the relay chops 284 bytes into 109, 109 and 66, and a loss
of exactly two at the end of that is the shape of an off-by-one paid
twice rather than of memory pressure.
.NH 1
Making the simulation accurate
.PP
The devices reacted to each other and that was enough to run a
controller.  It was not enough to tell whether the controller would
work, because every number it contended with was wrong in a way that
made the problem easier.
.B "A fixture that a controller passes is not a test of the controller."
.NH 2
What the model did not have
.IP \(bu
.B "No position, and so a field of constant magnitude."
A magnetic controller's whole difficulty is that the field varies by a
factor of two and sweeps twice an orbit.  The field here had neither:
one magnitude, one direction, rotating only because the body did.
.IP \(bu
.B "No sunlight geometry and no shadow."
A satellite is in eclipse for 38 per cent of a low orbit, which is the
term a power budget turns on, and the panels charged continuously.
.IP \(bu
.B "No inertia tensor in the integration that mattered."
.CW "omega x (I omega)"
was present and its unit conversion was taken from the rate update,
which has a different unit chain \- one power of the rate, not two.
.B "It was 17.45 times too small,"
and it is the one term that distinguishes this model from a scalar one:
at the default tumble the precession torque is two milli-newton-metres
against five micro of control authority.
.IP \(bu
.B "And two integer divisions that truncated to zero."
This is the one that matters most.
.NH 2
The torquers did nothing at all
.PP
The rate update is
.CW "T.dt.57296/(I.10^6)" .
A 0.2 A.m^2 dipole in the 250mG field at 500km is 4.9 micro-newton-
metres, which on a 3U's 0.0333 kg.m^2 axis over a ten-millisecond tick
is 0.086 milli-degrees a second \- and
.CW "(int)0.086"
is zero.
.B "At timescale 1 a commanded dipole had no effect whatsoever."
The quaternion update went the same way below about 1.2 deg/s.
.PP
.B "The 0.86 deg/s plateau this document called a controller's floor was that truncation."
It was reported as a measurement, and the deadband in
.B appl/pycubed/beepsat.b
was set to 1500 to clear it.  Both were artefacts of an integer
division.
.PP
The fix is to keep the remainder.  The quotient is applied, the
remainder carries, and over any number of steps the division is exact;
C truncates towards zero and takes the sign of the dividend from it, so
the identity
.CW "n == (n/d)*d + n%d"
holds for a deceleration as well as an acceleration.
.NH 2
The step is fixed in simulated time, not in reads
.PP
.B "A model that integrates over the interval between reads responds to being watched."
Euler integration is first order, so its answer depends on the step
length: at a tenth-second poll the step truncated to nothing, and at a
thirty-second gap it overshot.  Both were the same fault as the earlier
one where the model advanced only on a read, one level down.
.PP
So elapsed time accumulates in a backlog, whole steps of fifty
simulated milliseconds come out of it, and the remainder waits.  A
reader polling flat out and a reader polling once a second integrate
the identical trajectory and differ only in being up to one step
behind.  The backlog is reported in
.B #P/imu.ctl
beside
.B integrated ,
the simulated milliseconds the integrator has actually stepped, because
a model running behind real time has to say so.
.NH 2
A gap guard that stopped time
.PP
Both the orbit and the pack dropped any interval longer than sixty
seconds, commented as "the first call, or a long gap".  It did handle
the first call, where there is no previous tick to subtract.  It also
meant
.B "the orbit stopped whenever nothing read it for a minute,"
so the simulation was a function of being watched after all.  A flag
for the first call says what was meant; every interval after it is
integrated however long it is, which the closed-form position and the
coulomb count both support exactly.
.NH 2
What is modelled now, with its figures
.IP \(bu
.B "A circular orbit,"
500km by default: radius 6871km, period 5664 seconds.  Settable
altitude, inclination and beta angle at
.B #P/orbit.ctl .
.IP \(bu
.B "A tilted dipole field,"
.CW "B = B0 (Re/r)^3 [3(m.r)r - m]"
with the geomagnetic axis 11 degrees off the spin axis: 247mG at the
magnetic equator and 494 over the poles, sweeping twice an orbit.
.IP \(bu
.B "A sun at a settable beta angle and a cylindrical shadow."
A cylinder rather than a cone because the penumbra is a few seconds of
a 94-minute orbit.
.IP \(bu
.B "An attitude as a quaternion with a real inertia tensor,"
Euler's equations including the gyroscopic term, the magnetorquers and
the gravity gradient \(em about a hundredth of the torquers and the one
that never switches off.
.IP \(bu
.B "A battery that is a charge and a curve, not a voltage."
2600mAh counted in milliamp-seconds, an open-circuit curve with its
resolution at the knee, and 80 milliohms of internal resistance \- so
the pack reads differently in sun and in eclipse at the same state of
charge, which is why a naive low-voltage cutout trips on a battery that
is fine.
.LP
And a stated time scale, 1 to 200, on simulated time only.  A 3U with
0.2 A.m^2 torquers detumbles at 0.042 deg/s^2 about its low-inertia
axis and 0.0085 about the others, so twenty degrees a second takes
between eight and forty minutes.  That is the truth and it is not
watchable; fudging the inertia would make every number downstream
wrong.
.NH 2
The deadband is now untrustworthy and has been left alone
.PP
.B "Dtdeadband in appl/pycubed/beepsat.b is 1500 milli-degrees a second because of the truncation."
It was raised from 300 to clear a 0.86 deg/s plateau that was an
integer division, so the number has no physical justification left.
.PP
It has not been changed, and the reason is worth stating.  With the
gyroscopic term at its correct size the settling behaviour is a
different problem: at the default tumble the precession torque is about
four hundred times the control authority, so where a B-dot loop hands
over is a question about the real dynamics and not about arithmetic.
Answering it needs a detumble run with the corrected torque on a board.
.B "Guessing a new constant from a QEMU run would install a new artefact in place of the old one."
.NH 2
And the free body was gaining energy
.PP
The three checks above pass and the model was still wrong, in a way
none of them could see.
.B "Ask a torque-free tumble for the two things a free body keeps and it had kept neither: the kinetic energy grew 183 per cent and |I.omega| 89 per cent in 262 seconds of model time."
.PP
Euler's equations in the body frame are
.CW "I omega' = T - omega x (I omega)" ,
and
.B "explicit Euler on that is unconditionally unstable."
The free-body motion is a rotation of omega about the momentum axis, so
the cross term's eigenvalues are purely imaginary and
.CW "|1 + h.lambda|"
exceeds one for every step length: the amplitude grows by
.CW "sqrt(1 + (h.omega_n)^2)"
a step, which at a 3.9 second nutation period and a fifty-millisecond
step is 1.0032, and five thousand steps of that is not a satellite.
The quaternion was renormalised every step and so could not drift; the
RATE had nothing holding it.
.PP
.B "The cross term is an artefact of the frame."
In the inertial frame the equation is
.CW "L' = T" .
So the state is now the angular momentum, held inertially, and the body
rate is derived from it:
.DS
.CW "omega_body = I^-1 . R(q) . L_inertial"
.DE
There is no gyroscopic term to integrate and |L| is exactly constant
under zero torque \- not nearly, exactly, because the integrator never
touches it.  The precession is still there, because
.CW R(q)
is turning.  Energy then drifts only through the attitude integration.
.PP
.B "#P/imu.ctl reports the momentum,"
so a conservation check reads the invariant out of the model instead of
rebuilding it from the rate and its own copy of the inertia tensor \- a
check that recomputes an invariant from the numbers the model derives
is checking its own arithmetic.
.PP
And
.B "echo inertia ... >#P/imu.ctl"
keeps the momentum and lets the rate change, which is the only answer
that is not a lie: rebuilding L from the old rate would have the
satellite gain momentum because somebody edited a file.
.NH 2
And then the attitude step became the limiting error
.PP
With |L| exact, the next thing the conservation check saw was the
DERIVED body rate moving 5.7 per cent in twelve seconds of a
torque-free tumble.  Nothing was pushing and the momentum had not
changed, so the error was in the attitude: the first-order step
.CW "q += (1/2) q (0,omega) dt"
has an O(theta^2) error in the rotation's DIRECTION, and a tilted
attitude resolves a fixed L into the wrong body axes.
.PP
For a constant rate over the step the exact answer is a quaternion
multiply:
.DS
.CW "q' = q (cos(theta/2), sin(theta/2) omega/|omega|)"
.DE
and omega is constant over fifty milliseconds to far better than
anything else here.
The increment is built from the series directly: cos v = 1 - v^2/2 and
sin v = v(1 - v^2/6), with v the half angle.  What is left is a
systematic scale error on the rate of O(v^4), where Euler's error was a
random walk in the direction.
.PP
.B "And an earlier version of this renormalised that increment and said in a comment that doing so fixed the angle."
Half of that was wrong, which is worth recording because it reads
plausibly.
.B "Normalising scales the scalar and the vector parts equally, so the ratio between them \- which IS the angle \- does not move."
The construction
.CW "(1 - v^2/2, v)"
has an effective half angle of
.CW "atan(v/(1-v^2/2))" ,
which is
.CW "v + v^3/6" ,
and no amount of rescaling touches it; the extra term in the sine is
what fixes it.  What the normalisation did fix was the MAGNITUDE, which
the construction already leaves correct to v^4/8 \- two parts in a
thousand million at these step lengths \- so it was an integer square
root in the hot path for nothing, twice a step.
.PP
The attitude itself is still renormalised, because the increment is
applied in integers and the rounding is not a rotation, but to the
FIRST ORDER: with d = |q|^2 - Qscale^2 small the factor is
.CW "1 - d/(2 Qscale^2)" ,
and the square root is kept only for the case where something has gone
far enough wrong to need it.  A Newton loop of thirty 64-bit divisions,
four hundred times a read at the top time scale, is not what a
satellite's processor is for.
.PP
.B "And that was not enough, because omega is not constant either."
In body axes it precesses \- for a 3U at the default tumble at 0.34
radians a second, which is a degree in a fifty-millisecond step \- so
taking the rate at the START of the step lags the axis by half a degree
every step, and the lag is systematic: it migrated the momentum towards
the low-inertia axis.  The rate is now taken at the MIDDLE of the step,
by advancing a copy of the attitude half way and asking it.  Two
rotations a step, and the remainder is carried only on the real one.
.PP
Measured, same tumble and the same instrument, as the worst energy
drift of a torque-free run:
.DS
.CW "step     start-of-step omega    midpoint omega"
.CW "50ms           +39.68%             +0.29%"
.CW "10ms            +3.15%             +0.05%"
.CW " 2ms            +0.43%             +0.22%"
.DE
.B "A hundred and thirty-five times better at the default step,"
and omega_z \- which for Ixx = Iyy is a constant of the free motion \-
now holds to 0.5 per cent where it had moved 138.  The two-millisecond
row is worse than the ten because the integer quantisation of the
increment takes over when the step gets small; the step is settable
from
.B #P/imu.ctl
precisely so that this table can be made again.
.PP
.B "An error that does not fall when the step is halved is a bug, and one that does is convergence."
That is the whole reason the step is a variable: the first version of
this comparison slept a fixed sixty board-seconds for each step length
and the three rows covered 82, 41 and 16 seconds of MODEL time, because
at a short step one advance after a quiet period hits the cap on steps
per call and leaves the rest in the backlog.  Three different
experiments, compared as if they were one.
.NH 2
Three checks that were wrong about correct physics
.IP 1.
.B "The quaternion angle was computed without dividing by the scale twice."
A quaternion product of two 10000-scaled quaternions is 10^8-scaled,
and dividing by 10^4 once left a scalar part of about 10^4, which
.CW min (1.0, ...)
clamped to 1 and
.CW acos
turned into zero degrees.  It reported "turned 0.00 deg" for a
satellite that had turned 2593, which reads exactly like an integrator
that does nothing.
.IP 2.
.B "And it asked all three rate components to move."
The default tensor is axisymmetric \- Ixx = Iyy \- and for such a body
omega_z is a CONSTANT of the free motion while omega_x and omega_y
rotate about the symmetry axis.  The check was asking for something the
physics forbids and reported "the z rate moved 0" as a fault.  It now
asserts both: that x and y move and that z does not.
.IP 3.
.B "And it took the angle by acos, which is ill-conditioned exactly where the small angles are."
The derivative of
.CW acos
is
.CW "-1/sqrt(1-x^2)" ,
which at a 7.6 degree rotation is \-15, so the 1e-4 quantisation of a
quaternion stored as integers of ten thousand becomes 0.17 degrees of
noise on the answer.  Summed over nine samples that was 1.7 per cent of
a 1 deg/s measurement, and it read as a model turning slowly \- which
is exactly the fault the truncation had really caused earlier, so it was
the most plausible wrong answer available.  Taken by
.CW atan2
of the vector part against the scalar, which is well conditioned at
both ends, the same model gives 75.9 degrees of 75.9.
.LP
All three are the same mistake in different clothes \(em a test written
from the shape of the answer rather than from the physics \(em and all
three would have been published as model faults.
.B "The third is the worst of them, because it agreed with a fault that had genuinely existed."

.NH 2
And the pack was doing it too
.PP
The coulomb count is
.CW "(drain - solar) dt / HZ" ,
in milliamp-seconds from milliamp-ticks, and it divided and dropped the
remainder like the other two.
.B "At 450mA and a seven-tick interval the quotient is 31.5 and the half went every read,"
so a pack discharged more slowly the more often it was looked at \- the
observer-dependence again, one file over.  It carries now.
.PP
.B "That makes four places in three files where the same mistake was sitting,"
and the shape of it is always the same: a rate times an interval,
divided into a coarser unit, with nothing holding the remainder.
.NH 2
A check whose premise was never tested
.PP
The coulomb count failed at 21 per cent and
.B "it was the prediction that was wrong, not the counter."
The test commanded a 500mA drain and predicted the charge lost from the
NET current at the two endpoints \- but the panels make whatever the
attitude gives them, the satellite was tumbling, and the average over
the interval was nothing like the average of its ends.
.PP
The answer is not a better model of the panels in the test.  It is to
.B "measure in eclipse,"
where the only current is the one being commanded: at beta zero the
anti-sun point is half way round from the ascending node, the shadow
spans 136 degrees of the orbit and the measurement is 18, so starting
at mid-eclipse stays there throughout.  And the check now asserts that
the panels made nothing, rather than assuming it \-
.B "a premise that is not tested is not a premise."
.NH 2
What really bounds the time scale
.PP
.B #P/orbit.ctl
accepts a time scale up to 200 and that ceiling is about the
integration error.  It is not the limit that binds.
.PP
One
.I advance
may take at most
.I Maxsteps
steps, so a single read can integrate at most 4096 x 50ms = 204.8
SIMULATED SECONDS however long it has been since the last one.
.B "The time scale a reader actually gets is therefore 204800 divided by the milliseconds between its reads:"
a tenth-second poll sustains two thousand and a five-second gap
sustains forty.
.PP
.B tools/f407/simsoak.py
reads the five files every few seconds at timescale 200, which asks for
960 simulated seconds a read, and the backlog grows without bound.
That is not a fault \- it is the model saying it cannot keep up, which
is the whole reason the number is reported \- and the soak says so
rather than passing silently.
.B "The first version of that test asked only whether the backlog had QUADRUPLED, and so reported \(dqno growing backlog\(dq about one that had cleanly doubled."
It now measures at both time scales and requires the backlog to stay
bounded only at the one the model is supposed to sustain.
.PP
.B "And the second version of it ran both phases on one board,"
so the timescale-1 phase inherited a hundred and forty thousand seconds
of backlog from the stress phase and then measured that DRAINING.
"Not growing" was perfectly true and meant nothing.
.B "A phase that asks whether the model keeps up has to start from a model that is up to date,"
so each phase boots its own.
.PP
.B "\(dqstill\(dq now discards the backlog as well,"
which is a judgement and not a tidy-up: the verb means stop and be
level, and integrating forty hours of a state that has just been thrown
away is not keeping faith with time, it is spending it on nothing.  The
other verbs keep the backlog, because they change the state the model
is in rather than declaring where it starts from.
.NH 2
How it is checked
.PP
.B tools/f407/simcheck.py
drives a kernel under QEMU's netduinoplus2 and asserts the physics
against figures worked out independently of the code.  It is QEMU and
not a board on purpose: the first attempt at this hung a board with no
console and no response to the two control-Rs that reach the
bootloader, and a physical reset button is not always within reach.
.PP
.B "Two things it gets right that cost a measurement each."
The board's clock is not the host's \- under QEMU this kernel's tick
runs about seven times faster than wall time, so
.CW "sleep 30"
at its prompt returns in four and a half seconds.  Every elapsed time
in the checks therefore comes from the model's own counters:
.B integrated
in
.B #P/imu.ctl
and the orbit's closed-form
.BR phase .
Estimating it from host sleeps made a correct model look five times too
fast for an hour.  And a periodic quantity is sampled by SETTING the
phase rather than by letting the orbit run, so no sample interval
aliases against a clock ratio nobody controls.
.NH 1
Taking the radio out of the two-byte question
.PP
The multi-frame read above comes back two bytes short, and the path that
loses them has four things in it that could \- the relay in
.BR os/inferno/init/armv7mstyx.b ,
.IR devmnt 's
reassembly,
.IR devax25 's
connected mode, and the air.  A board is needed to exercise any of them.
.B "Three of the four can be taken out."
.PP
.B appl/cmd/styxseg.b
makes two pipes and two chopping processes, which is the same
bidirectional link with the same write limit the conversation has,
serves one end with
.I exportfs
and mounts the other with
.IR devmnt .
It runs under a host emu in a second.  It is not a model of the radio
and does not pretend to be: a pipe is ordered, reliable and never drops
a frame, which is exactly what the connected mode is supposed to
provide and what this therefore holds fixed.
.PP
.B "Measured, over 109-byte frames and identical on every read:"
every size from 1 to 600 bytes in steps of seven, three reads each, and
every size from 260 to 300 byte by byte \- which brackets the 273 of
.B #P/arch
exhaustively.  An exhaustive sweep of the whole range is the same test
with a stride of one and takes a quarter of an hour under emu; the
figures above are what has actually been run.
.PP
So the chopping and the reassembly do not lose data on their own, and
the two bytes are in
.I devax25
or on the air.
.B "That is a narrower thing to take to a board than it was,"
and it is as far as this goes without one.
.NH 2
The test was wrong first, in the usual way
.PP
It writes its own file of a size it chooses, and the first run of it was
pointed at
.B /dev/time
and reported the transfer corrupting data at byte 13 \- which it had
not; the clock had moved between the two reads.
.B "That is the sixth check in this work to have been wrong about correct behaviour,"
and the shape is the same as the others: a test written from the shape
of the answer rather than from the thing being measured.  A file whose
contents the test wrote cannot do that, and a size it chooses can be
swept until one of them loses bytes.
.NH 2
Two things it records rather than works around
.PP
.I "sys->fversion()"
will negotiate the board's 436-byte message size before the mount, and
then
.I mount
sends its own Tversion on the same connection, which 9P does not allow
on an established one: both ends wait and nothing is printed.  The flag
is kept, defaulting to off, so that nobody spends an afternoon
rediscovering that it hangs by construction.
.PP
Reaching that message size properly wants the transport to advertise a
small iounit, because that is what
.I devmnt
clamps to \- the same mechanism by which the conversation's 109 became
the msize in the first place.  A pipe's iounit is not settable, so the
host test runs at 8192 and the sizes of the MESSAGES are the same
either way: a 273-byte file is one Rread of 284 bytes in both.
.NH 2
And the instrument had a latent fault of its own
.PP
.I Slurpn
in the station init did ONE read and returned what came back.  That is
right for a device file inside one Styx message and silently wrong for
anything else, because a mounted read returns at most one message's
data \-
.B "so a file larger than that came back truncated, and two truncated reads compare equal."
The test would have passed over a transfer that lost the tail of every
message after the first.
.PP
.B #P/arch
is 273 bytes and the msize is 436, so one read did cover it and the
273-against-271 result stands.
.B "The instrument was right about that file by arithmetic rather than by construction,"
which is not a property to leave in place; it reads to end of file now.
.NH 2
And a candidate in the driver, with a counter to confirm it
.PP
With the chopping and the reassembly cleared, the receive path in
.B os/inferno/radio/cc1120.c
has a hole that would lose a pair of bytes.
.B "The payload read was not guarded by the available count."
It samples NUM_RXBYTES, breaks if the FIFO holds less than ONE byte,
then reads the length and that many more \- and nothing had said those
bytes existed.
.PP
The packet interrupt is suppressed on this board and the FIFO is drained
by a clock watchdog instead, so
.B "it is looked at mid-packet as a matter of course:"
at 1200 baud a 109-byte frame is 730 milliseconds in the air and the
watchdog runs many times inside that.  Reading past the end underflows
the part, which returns rubbish for the rest of the payload and leaves
the FIFO in RX_FIFO_ERR.
.PP
A packet the count does not cover is flushed and counted as
.B rxpartial
now rather than delivered.  Losing it costs an AX.25 retransmission,
which is what the connected mode is for; delivering it corrupt costs a
diagnosis.
.B "The counter is the point as much as the fix:"
if rxpartial climbs when the two bytes go missing, the diagnosis is
confirmed, and if it stays at zero the fault is elsewhere \- in the
device's framing or on the air.
.B "Neither can be tested without a board."
.PP
.B "It climbed, and the diagnosis was confirmed and then outgrown."
A ground station reported
.B "rxstall 0 rxpartial 1"
at the moment a 284-byte reply's third frame failed to arrive, so the
frame reached the part and the driver destroyed it.
.B "Flushing was the right answer to the wrong question:"
the length byte cannot be pushed back into the FIFO, but it can be kept
in the DRIVER, and the frame finished on a later pass instead of thrown
away.  The receive path does that now;
.B rxpartial
has stopped meaning "a frame was dropped" and means "a frame was held",
with
.B resume ,
.B rxstale
and
.B rxunder
beside it saying which of those ended well.  See
.IR radio (3)
and the end of
.B doc/radio-plan.ms .
.NH 2
A warning that had been there long enough to be scenery
.PP
.I kencc
had been printing "used and not set: first" about
.I cc1120ctl
on every build of this kernel.  Four blocks shadow that name and three
are properly guarded; the fourth, in the
.B gtrig
verb, assigns it only on the very first sample \- so a window that
captures NOTHING, an
.I ms
of zero or a pin that never moves inside it, reached the print without
it ever being assigned.
.PP
.B "\(dqgtrig 881000000 0\(dq reported \(dqruns 0 first high\(dq or \(dqfirst low\(dq depending on what was on the stack:"
an instrument making a claim about a pin it never read.  It starts at
\-1 and prints "none" now.
.PP
The other standing warning was a deliberate
.CW (void)
discard
.I kencc
will not accept.  The file compiles with no diagnostics at all, which is
the condition under which the next real one will be noticed.
.B "This one was not, for as long as it took to stop reading them."
.NH 1
And then on silicon
.PP
Every figure above was measured under QEMU, because the board that
would have carried them was hung with no console.  It was reset on 6
October 2026 and the satellite image flashed \- kerndate 1791322734,
nproc 12 \- and the mission ran.
.NH 2
The detumble, on real hardware, at timescale 1
.PP
.DS
.CW "beepsat: tumbling, as a deployed satellite is"
.CW "BEEPSAT-RUNNING 7 tasks"
.CW "detumble | rate 22.996 deg/s, dB/dt 46 -45 -30, m -59 58 39"
.CW "detumble | rate 22.600 deg/s, dB/dt -26 72 53, m 33 -93 -68"
.CW "detumble | rate 21.485 deg/s, dB/dt ..."
.CW "vbatt | 3.69V > threshold 3.60V"
.DE
.B "96 samples at the control loop's one-second period: 22.996 deg/s down to 21.485, a fall of 1.511 in 95 board-seconds."
That is
.B "0.0159 degrees a second squared,"
and 14 of the 95 samples rose, which is the ripple a fixed dipole gives
as the body turns past it.
.PP
.B "THIS IS THE REGIME THAT USED TO BE DEAD."
At timescale 1 the rate update was
.CW "T.dt.57296/(I.10^6)" ,
which for this dipole over a ten-millisecond tick is 0.086
milli-degrees a second and truncated to zero: the torquers had no
effect at all, and the only reason anything was ever seen to move was
the time scale multiplying the step.  On silicon, at timescale 1, with
the remainder carried, the rate comes down.
.PP
.B "And the figure is the right size."
The B-dot law commands about 130 milli-A.m^2 here, the field is about
250 milligauss, so the torque is 3.3 micro-newton-metres; the rate
reported is the largest component, which is about the low-inertia axis
at 0.0067 kg.m^2, so
.CW "m x B / I"
is 0.028 deg/s^2 at perfect alignment.  Measured 0.0159, which is 57
per cent of that \- and the law is not aligned with the easy axis, so
better than half of ideal is what it should be.  A figure within a
factor of two of the hand calculation, with the sign right and the
trend monotonic, is the model and the controller agreeing on hardware.
.PP
The sun-seeking task printed nothing, which is correct: it skips every
sample while the rate is above the deadband, and at 0.0159 deg/s^2 the
fall from 23 to 1.5 takes about twenty-two minutes.
.NH 2
And the physics, asserted on the board
.PP
.B tools/f407/boardsim.py
drives the simulated devices through the
.IR screen (1)
session that owns the board's console \- never by opening the device,
which wedges the adapter while screen holds it \- and asserts what
.B tools/f407/simcheck.py
asserts under QEMU.  Each check takes its elapsed time from the model's
own counters,
.B integrated
and the orbit's closed-form
.BR phase ,
because the arithmetic is the same on the board and the CLOCK is not.
.PP
.B "Eight for eight, and the figures agree with QEMU's:"
.DS
.CW "                     QEMU            silicon"
.CW "field round one orbit  246..415 mG     259..409 mG"
.CW "eclipse at beta 0      38% of 72       38% of 24"
.CW "spin 10 deg/s          0.0%            0.0%"
.CW "spin 1 deg/s           0.1%            0.0%"
.CW "free-body |L|          0.002%/242s     0.002%/76s"
.CW "free-body energy       1.226%/242s     0.347%/76s"
.CW "omega_z held           458 of 23030    126 of 23011"
.DE
.B "The 1 deg/s row is the one that matters:"
18.7 degrees where the rate asked for 18.8, in exactly the regime where
the quaternion update used to divide to zero and the satellite did not
turn at all.
.PP
The energy drift is smaller than QEMU's because the interval is \- 76
seconds of model time against 242 \- and the drift grows with it, so
these two numbers are consistent rather than an improvement.  Saying so
is the point: a figure that looks better for a reason that has nothing
to do with the thing being measured is the shape of a wrong conclusion.
.NH 2
And the sequence that hung the board does not any more
.PP
.CW "echo timescale 1 >orbit.ctl"
then
.CW "echo still >imu.ctl"
\- the exact pair that left the board with no console, no response to
the two control-Rs that reach the bootloader, and nothing but the reset
button \- runs on this kernel, with the board answering afterwards and
the whole of
.B #P/imu.ctl
printing.
.PP
.B "That is not a verified fix and should not be read as one."
The cause on the old image was never identified, the image that did it
no longer exists in that form, and this kernel differs from it in
several ways \- one of which is that
.I imuctlread
outgrew its 256-byte buffer, and a truncating
.I snprint
is a plausible candidate nobody has tied to the hang.
.B "What is true is that it no longer reproduces."
.NH 1
THE DEADBAND, MEASURED, AND WHY A CONSTANT IS THE WRONG SHAPE
.PP
.B "Dtdeadband was 1500 and unreachable, so sun() was dead code."
.I Suntask ()
gates on
.CW "rate >= Dtdeadband"
and
.IR detumbletask ()
stops commanding below the same number, so one constant decides both
whether the torquers ever switch off and whether pointing ever starts.
.NH 2
What the loop actually does
.PP
A 240-second run damps 23.0 deg/s to about 4.5 and then climbs again,
which looks like divergence and is not:
.B "dB/dt falls with the rate, so B-dot's authority falls with the very thing it is damping."
That band is the stretch of orbit where the field direction offers
nothing to push against.  Given a
.B "full orbit"
\- 6871 samples, about 114 minutes of model time \- it converges, and
the first measurement put the floor at 1504 to 1522 with
.B "settled, torquers off"
printed zero times.
.NH 2
And then three constants in a row, because the floor is not a number
.PP
.DS
.CW "deadband 1500   floors 1504, 1509          never reached"
.CW "deadband 1600   reached twice, floor 1776  missed once"
.CW "deadband 2000   reached twice, floor 2098  missed once"
.CW "deadband 3000   reached three times of three"
.DE
.B "The same third-run trajectory floored at 1776 against 1600 and at 2098 against 2000,"
and in both it never printed
.CW "detumbled at" ,
so the torquers never switched off and the deadband cannot have changed
that trajectory.
.B "The runs are simply not reproducible:"
each starts from its own attitude and momentum, and the floor spans at
least 1504 to 2098 \- forty per cent.
.PP
3000 reaches in three of three, with the handover firing 30, 52 and 60
times and
.I sun ()
issuing 171, 369 and 378 steering commands where it had issued none.
.B "It is a stopgap and the shape is wrong."
Three degrees a second is a loose detumble, and the reason it must be
loose is that
.B "an absolute rate cannot say \(lqthe loop has finished\(rq when the rate the loop can reach is not a constant."
The invariant is the
.I derivative
\- the rate having stopped falling \- and keying the handover on that is
a change to the controller rather than to a line.
.NH 2
Two faults found only because the handover started working
.PP
.B "sun() steered on a zero gradient for every eclipse."
.I Solar ()
returning 0 is legitimate \- eclipse is 38 per cent of the orbit at this
beta \- and the error check rejected only NEGATIVE, so the loop hunted
on no evidence, flipping direction and commanding five hundred units of
dipole.  On a satellite whose power budget is the reason the task
exists, that is the task spending what it is meant to collect.  It holds
the torquers off and says so once per eclipse now: 13, 20 and 22 times a
run.
.PP
.B "And the gate had no trace at all,"
so a task that was dead code and a task that was merely quiet looked
identical.  It prints once per transition \- not per sample, because
this loop runs forever and a line a sample is a denial of service on the
console.
.NH 2
The measurement that was wrong first, and how
.PP
.B "mk install in appl/pycubed builds /dis and not /dis32,"
and the stm32f407 root embeds
.B /dis32
because a Dis word is four bytes there.
.B "So three source edits in a row never reached the image."
What made it convincing was that
.B "settled"
went from 0 to 24 after the first of them \- and that was
.B "run-to-run variation on untouched code:"
five runs of the same binary gave 0, 0, 24, 20, 18.
.PP
.B "A string grep of the ELF is what caught it"
and is the only check that spans the whole build:
.DS
.CW "grep -ac \(dqno sunlight\(dq istm32f407"
.DE
The build is
.CW "mk DISROOT=dis32 DISWORD=4 install" ,
which
.I mkconfig
documents and nothing warns about.
.PP
One more counting error in the same stretch:
.CW "grep -c '0mA of'"
matches
.BR 90mA ,
.B 60mA
and
.BR 30mA ,
which invented an eclipse defect that was real but whose evidence was
not.  Anchor on the separator.
.NH 2
The derivative is necessary and not sufficient, which I had backwards
.PP
The section above argued that the handover should key on the rate having
stopped falling, because the floor varies forty per cent and a constant
cannot be right.
.B "Half of that was right."
The handover is a derivative test now \- twelve samples without twenty
milli-degrees of progress \- plus a rate the result must be below, and
the second is doing more work than the first.
.PP
One run, counting which of the two conditions holds the handover back:
.DS
.CW "converged 24"
.CW "stopped improving but held by the floor 68"
.CW "        the held ones at rates up to 8.235 deg/s"
.DE
.B "The stall test alone would have declared the satellite detumbled at eight degrees a second, sixty-eight times in one orbit and a half."
Because B-dot's authority collapses where the field direction gives it
nothing to push against, and
.B "that plateau is indistinguishable from convergence by derivative alone."
It is the same plateau the 240-second run mistook for divergence,
read a second way.
.PP
So
.B Dtdeadband
is load-bearing, not a sanity check, and it still has to sit above the
top of the measured 1504-to-2098 spread.  What the derivative buys is
the other half: it stops the loop commanding torque into a rate it has
stopped being able to improve, and it supplies the restart condition \-
a 400 milli-degree rise above where it settled \- that one threshold
could not express.
.PP
.B "Three of three runs now converge and hand over,"
including the trajectory that missed both 1600 and 2000, at 2.565, 2.998
and 2.473 deg/s \- different rates, which is the point \- with pointing
issuing 290, 211 and 295 steering commands and the eclipse hold firing
11, 15 and 12 times.
