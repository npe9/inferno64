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
Phase 0: software double precision.  Precondition, not step one
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
.IP 2.
A QSPI driver that exposes the memory-mapped window, and
.CW Dev.xip
over it, so a module in external NOR is read where it lies.  The
mechanism already exists and is verified
.CW ( os/inferno/port/devroot.c ,
this branch); this is a second provider for it.
.CW os/inferno/riscv/spisifive.c
is the nearest precedent, and it deliberately declines the XIP path,
with a comment saying so.
.IP 3.
Pre-decode the
.CW Inst
arrays and tables into the QSPI window at build time and point
.CW m->prog
at flash.  No interpreter change.  One thing to settle first, and it
applies to any flash-resident code: whether an immediate can ever be an
instruction's destination rather than a source \-
.CW libinterp/dec.c 's
.CW D02
points
.CW R.d
into the instruction, and
.CW brpatch()
does not forbid it for a non-branch op.  If
.CW limbo
never emits that form the question is moot; if it does, flash-resident
code faults where heap-resident code silently modified itself.
.NH 1
Phase 4: the flight software, in Limbo
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
The one figure that decides it
.PP
78208 bytes, the kernel pool floor.  It is
.B measured
\- on
.CW mps2
with a minimal configuration and a 512-byte init, nothing else loaded \-
and 16384 of it is four 4K kernel stacks.  The other 62K has never been
looked inside: it is
.CW Chan ,
.CW Osenv ,
.CW Pgrp
and the namespace, each device's reset and init, the osinit module, and
the pools' own per-block headers and quanta rounding.
.PP
It is the largest single term in the table, larger than the
.CW Inst
arrays this plan is mostly about, and this board needs more devices than
the configuration it was measured on \- SPI, I2C, ADC, SD, QSPI and the
four bus drivers on top of nine.  So it could as easily be 90K as 70K,
and that is a 20K swing on a budget with 2884 bytes of slack.
.PP
Measure it before phase 1.  A size histogram of the minimal
configuration's 343 pool allocations is a day's work and it decides
whether this plan's last phase is arithmetic or wishful.
.NH 1
Order, and what each phase proves
.IP 0.
Soft double in
.CW tc ,
verified by
.I fptest (1)
going from a usage fault to
.CW FPTEST-OK
on
.CW mps2-an386 ,
with
.CW mps2-an500
as the oracle.  No hardware.  Without it there is no flight software.
.IP 0a.
The pool-floor histogram.  Cheap, and it either confirms the budget or
changes the plan.
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
