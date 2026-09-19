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
Phase 4: the flight software, in Limbo.  Begun, and measured
.PP
The mission logic is ported and runs.  What is in the tree:
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
.CW "  RTC             #r devrtc"
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
.NH 2
What that leaves not free, which is four bytes
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
What is left is a size.  That header leaves, in the driver's own words,
252 bytes of payload.  And
.CW os/inferno/port/devmnt.c:195
is
.DS
.CW "if(f.msize<256 || f.msize>1024*1024)"
.CW "	error(\(dqnonsense value of msize in fversion\(dq);"
.DE
so the smallest Styx message size a mount will negotiate is 256.  Four
bytes over.  That is the whole of the gap between what the radio carries
and what Styx needs, and it has three answers rather than a project:
drop the RadioHead header and use the SX127x's own framing, which gives
255; segment a Styx message across two packets in the radio device; or
lower that floor, which is a constant with no derivation behind it in a
kernel where
.CW IOHDRSZ
is 24, so a 256-byte message carries 232 bytes of data and a 240-byte
one would carry 216.  Deciding which needs the board.  None of them is
a command table, a packet format, an authorisation scheme and an
.CW exec () .
.PP
Also not free, and unchanged from the earlier sections: the four bus
drivers, and the LED, burn wires and ADC, for which Inferno has no
device class \- which is what
.CW #P
and
.CW addarchfile ()
are now here for.
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
.CW #r
.CW devrtc ,
.CW /dev/time ,
.CW /dis/lib/daytime.dis
and
.CW timers.dis .
The GPS discipline of the clock remains mission code; the clock does
not.
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
