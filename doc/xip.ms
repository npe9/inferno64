.TL
Execute in place: running Limbo from a filesystem that is not RAM
.AU
.PP
This branch is about one question: when Inferno loads a Dis module out of
a filesystem whose bytes the processor can already address \- the root
filesystem linked into the kernel image, or a filesystem in memory-mapped
ROM or NOR flash \- how much of it can be used where it lies instead of
being copied into the heap first?  The answer turns out to be
"the file, yes; the decoded program, no, and not on this board", and the
measurements that settle the second half are the useful part of this
document.  The branch is based on
.CW raspi3b-port
and targets the same board: Raspberry Pi 3 Model B, one kernel image,
tested under
.CW qemu-system-aarch64 " -M raspi3b" .
.NH 1
What a Dis module costs to load
.PP
.CW readmod()
in
.CW libinterp/readmod.c
had one way to load a module: open the file, stat it,
.CW malloc
a buffer of the file's length,
.CW kread
the whole file into it, hand the buffer to
.CW parsemod() ,
free the buffer.
.CW parsemod()
in
.CW libinterp/load.c
walks those bytes and builds the
.CW Module :
an
.CW Inst
array decoded from the packed instruction stream, the type descriptors,
the link and import tables, the exception handlers, and the module data
segment.
.PP
So there are two distinct memory costs, and they behave differently.
The buffer is transient \- it is freed the moment
.CW parsemod()
returns, which is also the proof that nothing the module keeps points
into it.  The
.CW Module
is permanent, for as long as the module stays loaded, and the
.CW Inst
array dominates it:
.CW Inst
is a fixed 24 bytes per instruction on a 64-bit target
.CW (op ,
.CW add ,
.CW reg ,
then two
.CW Adr
words), against a variable-length packed encoding in the file.
.PP
Measured across the 45 Dis modules the
.CW raspi3b
configuration bundles, by reading
.CW isize
out of each Dis header and multiplying:
.DS
.CW "decoded Inst arrays   1449912 bytes"
.CW "packed .dis files      467362 bytes"
.CW "ratio                    3.10"
.DE
The largest single module is
.CW /dis/disk/kfs64.dis :
65595 bytes on disk, 8820 instructions, 211680 bytes of
.CW Inst .
.PP
An earlier version of this document said 47 files, 475093 packed bytes
and a ratio of 3.05.  That was wrong, and the way it was wrong is worth
recording because it is a trap for anyone repeating the measurement.
The board's
.CW root
section bundles 47 regular files, but two of them \-
.CW /dis/init
and
.CW /dis/shutdown
\- are
.CW #!/dis/sh
shell scripts, not Dis modules.  The script reading the headers parsed
them anyway: the first byte of
.CW #
is 35, which
.CW operand()
happily accepts, and the
.CW isize
it then read out of ASCII text came back sign-extended and negative, so
the two files subtracted from the decoded total while adding their 7731
bytes to the packed one \- pushing the ratio down in both directions at
once.  The script now checks for
.CW XMAGIC
or
.CW SMAGIC
and skips anything else, which is what it should have done first.  The
figures above are from that version over the 45 files that really are
modules.
.PP
Nothing measured on the booted kernel is affected: those numbers come
from
.CW #c/memory ,
not from this script.
.NH 1
The read path: done, and verified
.PP
The transient buffer is pure waste whenever the file's bytes are already
addressable, and for the built-in root they always are.
.CW os/inferno/port/mkroot
walks the
.CW root
section of the board's configuration file and emits each listed file
through
.CW utils/data2s/data2s.c
as an initialised array linked into the kernel image;
.CW os/inferno/port/devroot.c:/^rootread
serves reads as a
.CW memmove
out of exactly that array.  Contiguous, addressable, never rewritten
.CW ( rootwrite
is
.CW Eperm ).
.PP
.CW Dev
(in
.CW os/inferno/port/portdat.h )
therefore grows one optional method:
.DS
.CW "void*	(*xip)(Chan*, u32*);"
.DE
It returns a pointer to the whole of an open file's contents and sets the
length, or nil to decline.  Declining is the normal case and the only
honest answer for a device that would have to read, map or copy anything,
which is every device in this kernel but
.CW devroot
\- so the slot is left unset and callers test it.  That is the
configuration mechanism: a device table entry and a runtime check, no
switch in a configuration file and no conditional compilation, per
.CW AGENTS.md .
.PP
The contract is the subtle part, and it is written down beside the
method.  The memory must stay valid, and its contents unchanged, for the
life of the kernel and not merely the life of the channel, because
.CW readmod()
closes the file and goes on reading through the pointer.  A filesystem in
the kernel image can promise that, and so can one in memory-mapped ROM or
NOR flash.  That is the whole intended set, and a device that cannot
promise it declines.
.PP
.CW kxip()
in
.CW os/inferno/port/sysfile.c
reaches the method through a descriptor, the way the rest of the
.CW k*
interface in
.CW include/kernel.h
does.  Emu's, in
.CW emu/port/sysfile.c ,
returns nil and says why: its files are the host's, reached through
.CW read (2),
so no address holds their contents.  That side compiles clean but cannot
be linked or run here, for a reason that has nothing to do with this
work \- see the last section.
.PP
Handing
.CW parsemod()
kernel memory rather than a heap buffer is safe for the reason the old
code already asserted by freeing the buffer immediately.  That was
checked here rather than assumed:
.CW parsemod()
only advances through the bytes, and the signature path it takes first
only reads too \-
.CW verifysigner()
copies out through
.CW os/inferno/port/devsign.c:/^vs ,
and
.CW mustbesigned()
ignores the pointer entirely.  The length now arrives from the device
beside the pointer and must agree with the length stat reported;
.CW devroot
sets both from one generated symbol per file, and on any disagreement
.CW readmod()
reads the file rather than trust either number, because
.CW parsemod()
derives every bound it enforces from that length.  The "data segment
string out of range" fault recorded in
.CW libinterp/load.c
was exactly that going wrong once already.
.NH 2
What it measures
.PP
Read from
.CW #c/memory
at an interactive shell, same kernel built with and without the change:
.DS
.CW "                    without        with"
.CW "at an interactive shell"
.CW "  main nalloc          7332        7322"
.CW "  main nfree           5659        5649"
.CW "  main hw           1526272     1524864"
.CW "  main cursize      1384064     1385088"
.CW "after loading /dis/disk/kfs64.dis"
.CW "  main nalloc          7914        7900"
.CW "  main hw           1722112     1710720"
.DE
At the shell, ten fewer allocations and ten fewer frees: one pair per
module loaded out of the built-in root.  Peak main-pool use falls 1408
bytes, which is small because
.CW hw
is a monotonic peak that early boot has already set elsewhere, and the
ten modules a boot loads are small.
.PP
Forcing the largest bundled module to load is what makes the peak move.
.CW /dis/disk/kfs64.dis
is 65595 bytes, and loading it from the shell widens the gap from 1408
bytes to
.B 11392 :
that is the transient buffer showing up in the peak, where it could not
before.  It is not the whole 65595, because the peak at that moment is
set by the buffer and the 211680-byte
.CW Inst
array together, and the pool grows in
.CW brk
chunks rather than by the byte.  11392 is what the measurement gives and
so 11392 is what is claimed.
.PP
Absolute counts vary a little between boots \- DHCP and USB enumeration
do not allocate identically every time, and an earlier pair of runs read
7326 against 7316.  The
.I difference
is stable at ten at the shell and fourteen after the extra load, because
it is one allocation per module load and nothing else.
.PP
Resident main-pool use is 1024 bytes
.I higher .
That is not a leak and not a regression to chase: the buffer this change
removes was freed as soon as it was parsed, so it never sat in the steady
state at all, and what moved is allocation pattern.  What the change
actually buys is the transient, the copy, and the
.CW malloc / free
pair, once per load.  On a board with real memory-mapped flash it buys
more, because there the file's bytes are not in RAM to begin with.
.NH 2
Both boards, and the stale link that nearly hid the result
.PP
The change touches code every
.CW os/inferno
board links \-
.CW port/portdat.h ,
.CW port/devroot.c ,
.CW port/sysfile.c
\- and
.CW libinterp/readmod.c ,
which every target compiles.  Built and booted on a second board for
that reason:
.CW os/inferno/virt ,
riscv64, through
.CW "jc / jl"
rather than
.CW "7c / 7l" ,
chosen because
.CW doc/inferno-ports.ms
catalogues a run of "long is 32 bits" wide-constant bugs on exactly that
path and a new
.CW u32 *
out-parameter is that shape.  It links and reaches an interactive shell
under
.CW "qemu-system-riscv64 -M virt" ,
with the board's own
.CW DIS-STRESS-OK
module-loading stress test passing.  Its
.CW CMD-STRESS-FAIL " and " HEAVY-FAIL
are unrelated: neither
.CW mv.dis
nor
.CW tkclient
is in that board's
.CW root
section, and that boot mounts nothing else, so "file does not exist" is
the right answer.
.PP
Worth recording that the hazard the
.CW os/inferno/raspi3b/mkfile
comment warns about bit again while measuring this.  Rebuilding after
swapping
.CW readmod.c
recompiled the file and refreshed
.CW libinterp.a
but did not relink the kernel, so two images built from different
sources came out byte-for-byte identical.  Caught by comparing them,
which is the only reason the numbers above are from a pair that really
differ; both were rebuilt with
.CW iraspi3b
removed first, and the relink confirmed in the build log before either
was booted.  Any future before-and-after on this board should do the
same rather than trust an incremental
.CW mk .
.NH 2
The fallback, verified separately
.PP
A boot reaching a shell does not exercise the nil case, because every
module a
.CW raspi3b
boot loads comes from
.CW devroot .
Tested by giving QEMU an SD card holding a FAT partition with
.CW date.dis
on it \- a module deliberately
.I not
in the board's
.CW root
section \- which the init mounts at
.CW /n/dos
through
.CW dossrv .
Loading it from the shell reaches
.CW devmnt ,
whose
.CW xip
slot is unset, so
.CW kxip()
returns nil and the original copying path runs.
.CW /n/dos/date.dis
printed
.CW "Thu Jan 01 00:00:00 GMT 1970" .
One command exercised both paths: the module itself came over Styx, and
its dependency
.CW /dis/lib/daytime.dis
came from the XIP root.
.NH 1
The decoded program: measured, and deliberately not done here
.PP
The obvious next step is to remove the other cost too \- generate the
decoded
.CW Inst
array, type descriptors, link and import tables and string constants into
the kernel image at build time, and have
.CW load()
return a
.CW Module
pointing at const data with only the per-instance data segment allocated.
That is where a loaded module's memory actually is: 3.10 times the packed
file, permanent rather than transient.
.PP
It should not be done on this board, and the reason is arithmetic rather
than taste.  The VideoCore firmware loads
.CW kernel8.img
byte-for-byte into RAM at
.CW 0x80000 ;
the SD card is not addressable, and there is no memory-mapped NOR flash
on a Pi 3B.  So the kernel image
.I is
RAM here.  Pre-decoding would cost image bytes for all 45 bundled modules
whether or not they are ever loaded, while saving heap only for the ones
that are \- and a boot to a shell loads ten.  It is a net loss on this
board, and the 3.10 ratio is what makes it one rather than a wash.
.PP
That is a finding, not a gap.  The work pays where the image is not RAM:
a board whose filesystem lives in memory-mapped ROM or NOR flash, where
the pre-decoded structures sit in flash and never occupy RAM at all.
There the same change removes the whole 3.10x from the heap and costs
nothing that was RAM to begin with.  The
.CW xip
method added here is the interface it would be built on, and
.CW Flash.xip
in
.CW os/inferno/port/flashif.h
\- already meaning "executing in place from this part, do not put it in
query mode" \- is the vocabulary the device side would use.
.NH 1
On a microcontroller: what it costs, and why the root file system is in
the wrong memory
.PP
This is the case the mechanism was built for, so it is worth the
numbers.  There are three ARMv7-M boards in the tree already
.CW ( os/inferno/mps2 ,
.CW os/inferno/teensy41 ,
.CW os/inferno/nucleof303 ;
see
.CW doc/armv7m-ports.ms )
and two of them are the interesting ones:
.CW teensy41
is a genuine execute-in-place board, an i.MX RT1062 whose text is linked
into FlexSPI NOR at
.CW 0x60002000
and read from there, and
.CW mps2
is the only one with an emulator, which makes it the only one that can
be measured running.
.CW mps2
has no flash at all \- it is 8M of SRAM and its text lives in RAM too \-
so it is the bench, not the model.
.PP
Sizes are from the linker, relinking each kernel with
.CW "tl -H2"
to get a header to read
.CW "text / data / bss"
out of; the
.CW -H4
image these boards actually flash is headerless.  All three built with
.CW DISWORD=4
against a
.CW dis32
tree:
.DS
.CW "                   nucleof303   teensy41       mps2"
.CW "bundled modules             0         32         61"
.CW "text (flash)           245192     392176     391184"
.CW "data                    50000     271480     581912"
.CW "bss                    128840     145736     144968"
.CW "RAM at boot          178840     417216     726880"
.CW "part RAM                81920    1048576    8388608"
.DE
.PP
And running, which only
.CW mps2
can do \- booted under
.CW "qemu-system-arm -M mps2-an500" ,
at an interactive shell, from
.CW #c/memory :
.DS
.CW "main pool in use   399104   (high water 399872)"
.CW "heap pool in use    71808"
.CW "image pool in use       0"
.DE
So a Cortex-M7 running a Limbo shell wants about 471K of pool on top of
its
.CW "data + bss" .
On
.CW mps2
that totals about 1.14M of RAM.
.NH 2
The root file system is in the data segment
.PP
Here is the part that matters for execute in place, and it is a gap in
what this branch has done rather than a success of it.
.CW utils/data2s/data2s.c
emits each bundled file as
.CW DATA
and
.CW GLOBL
\- initialised data \- so the root file system lands in the data
segment.  On these boards the data segment is not where it is stored:
.CW os/inferno/armv7m/l.s:/^_datacopy
copies it out of the image at
.CW etext
into
.CW bdata..edata
before anything reads a variable.  The root file system therefore costs
flash for the initialiser
.I and
an equal amount of RAM for the live copy, which is exactly backwards for
a part whose whole point is that flash is directly readable.
.PP
How much:
.CW mps2
bundles 447361 bytes of root and
.CW teensy41
140404, against data segments of 581912 and 271480.  Subtract and the
non-root data is 134551 and 131076 \- the same kernel either side of a
3475-byte configuration difference, which is the arithmetic confirming
that the root file system is all of the rest of it.  So the root is 62%
of
.CW mps2 's
RAM at boot and 34% of
.CW teensy41 's.
.PP
The consequence for this branch is blunt:
.CW rootxip()
on one of these boards hands back a pointer into the RAM copy.  The
loader change is doing what it claims \- no second copy into the heap \-
but on a microcontroller the file is already in RAM by then, and the
saving that matters has not been taken.  The missing piece is emitting
the root into the text or a read-only section so it stays in flash and
.CW _datacopy
never touches it; then
.CW rootxip()
returns a flash address and the file never occupies RAM at all.  That is
a change to
.CW data2s ,
.CW mkroot
and the linkers, not to anything this branch touched, and it is item 1
below.
.NH 2
Two walls that are not the file system
.PP
.B "A 64K debug ring."
.CW os/inferno/port/alloc.c
holds
.CW "static struct {...} freehist[4096]" ,
whose comment reads "4096 entries is 64KiB, trivial next to this port's
pool sizes" \- true of pc64, where it was added, and not of a
microcontroller.  Measured by rebuilding
.CW nucleof303
with
.CW NFREEHIST
set to 1: bss falls from 128840 to 63304, exactly 65536 bytes.  On an
80K part that ring is the whole of the SRAM.  It is marked pc64-only and
temporary in the source, and it is in every board's bss.
.PP
It also means
.CW os/inferno/nucleof303/NOTE
is out of date.  It records text 259416, data 50368, bss 38560 and so
88928 of RAM; the same configuration built now is text 245192, data
50000, bss 128840 and 178840 of RAM.  Text and data barely moved, bss
more than trebled, and 65536 of that is this ring.  The NOTE's
conclusion is unchanged \- the board does not fit \- but it now misses by
twice as much.
.PP
.B "Cortex-M4 has no double precision."
FPv4-SP is single precision only and
.CW utils/tl/thumb.c
gives every
.CW F
register a
.CW D
register, so
.CW "tl -M -F"
names every function that would fault: the Dis interpreter's real
arithmetic and all of libmath.  This is not a memory problem and more
RAM does not fix it; it wants software double precision.  Cortex-M7 is
fine \-
.CW doc/armv7m-ports.ms
records every line of
.I fptest (1)
passing there.  For "small microcontroller" in the M0/M3/M4 sense this
is the harder of the two walls.
.NH 2
The budget
.PP
Taking
.CW teensy41
as the model, since it is the one that really executes in place, and the
.CW mps2
pool measurement for what running costs:
.DS
.CW "flash   text 392176 + root 140404      ~ 533K of 8M"
.CW "RAM     data+bss 417216                  today"
.CW "        less root in flash    276812"
.CW "        less the freehist ring ~211K"
.CW "        plus pools at a shell  ~471K"
.DE
About 890K of RAM as the tree stands, against the megabyte the part has;
about 680K with the root file system in flash and the debug ring out.
So a megabyte of RAM and a Cortex-M7 is the realistic floor for a Limbo
userland, half a megabyte would need work beyond this, and the 64K to
80K class is out of reach for reasons that start with the interpreter
and not with the file system.
.PP
None of the
.CW teensy41
figures are from a running board: there is no emulator for an i.MX
RT1062 and none of this tree's Cortex-M work has been on real silicon.
They are link-time sizes plus a pool measurement taken on
.CW mps2 .
.NH 2
Fitting 256K
.PP
Asked directly: what would have to change to run in a quarter of a
megabyte.  On a part with no MMU it is all one flat SRAM, so the budget
is
.CW data
plus
.CW bss
plus whatever
.CW xalloc
hands out \- and the pools come from
.CW xalloc
too
.CW ( os/inferno/port/alloc.c:/^poolalloc
grows by calling it), as does the
.CW Proc
array
.CW ( os/inferno/port/proc.c:/^procinit ).
262144 bytes has to cover all of it.
.PP
Struct sizes on this target, from
.CW "tc -S"
on a probe compiled with the board's own headers:
.CW sizeof(Proc)
is 2740,
.CW sizeof(Chan)
300,
.CW sizeof(Osenv)
328,
.CW sizeof(Mach)
152.  The
.CW Proc
array is
.CW NPROC
of those, xalloc'd at boot: 175360 bytes at
.CW mps2 's
.CW NPROC
of 64, 21920 at
.CW nucleof303 's
8.
.NH 3
What the measurements say has to go
.PP
A deliberately minimal configuration was built and run to find the
floor: the device and library set from
.CW nucleof303 ,
which is the smallest that links, on
.CW mps2 ,
which is the only board with an emulator, with a root file system of
mount points and
.CW /osinit.dis
and nothing else, and
.CW KSTACK
cut from 16K to 4K.  It reaches its init and reports, from
.CW #c/memory
before anything else is loaded:
.DS
.CW "                    full mps2   minimal"
.CW "text                  391184    244800"
.CW "data                  581912     50192"
.CW "bss                   144968    131656"
.CW "main pool in use      158208     78208"
.CW "heap pool in use        3840      3840"
.DE
Dropping the devices
.CW ( ssl ,
.CW cap ,
.CW kprof ),
the Dis modules past
.CW sys
and the 61-file root halves the pool floor and takes the data segment
down by an order of magnitude.  Losing the
.CW crypt
and
.CW math
module tables is what stops libsec's prime tables being linked \- the
40000-byte
.CW smallprimes
in
.CW libsec/smallprimetest.c
is simply absent from the minimal image, so that one is a configuration
change and not source work.
.PP
What is left in the minimal
.CW data + bss
of 181848 is, in order, two debug arrays and a log buffer:
.CW freehist
65536,
.CW track
24576,
.CW kmesg
16420, then
.CW mntalloc
8248 and nothing else above 4416.
.CW freehist
is
.CW os/inferno/port/alloc.c 's
free-history ring and
.CW track
is
.CW libinterp/heap.c 's
.CW "Trackslot track[1024]" ,
both pc64 debugging instrumentation, both marked temporary where they
are declared, and together 90112 bytes \- half the minimal data and bss.
.CW freehist 's
cost was measured rather than computed, by rebuilding with
.CW NFREEHIST
at 1 and watching bss fall from 128840 to 63304.
.NH 3
The budget that results
.PP
Minimal configuration, the two debug arrays out,
.CW kmesg
cut to 2K,
.CW KSTACK
at 4K and
.CW NPROC
at 8:
.DS
.CW "data + bss                       77364"
.CW "Proc array (8 x 2740)            21920"
.CW "pid hash table                     128"
.CW "main pool in use                 78208"
.CW "heap pool in use                  3840"
.CW "                                ------"
.CW "                                181460"
.DE
That is 69% of 262144, leaving about 80K for a Limbo program.  So the
answer is yes, with the cuts above \- and with one configuration change
the arithmetic forces:
.CW main_pool_pcnt
and friends are percentages of the memory left after the kernel, and
40/40/20 of the roughly 163K remaining gives the main pool a 65K
ceiling, under the 78K it is measured to need.  The image pool is
measured at zero in use on these boards, so something like 60/25/15 is
what a part this size wants.
.NH 3
What 256K costs you: the shell
.PP
This is the part that matters more than any of the savings.  Measured on
.CW mps2 ,
the main and heap pools hold 162048 bytes before
.CW /dis/sh.dis
is loaded and 423040 after it and the shell's own dependencies are in.
The shell costs
.B 260992
bytes \- more than the entire budget being discussed.
.PP
It is not close, and no trimming reaches it: at
.CW DISWORD=4
an
.CW Inst
is 12 bytes rather than 24, so the decoded-to-packed ratio on this
target is 1.76 rather than the 3.10 measured for the 64-bit boards, and
.CW sh.dis
still decodes to 73332 bytes of
.CW Inst
with
.CW sh/std.dis
another 23604.  A quarter of a megabyte therefore does not buy Inferno
with a smaller heap; it buys a kernel plus one purpose-built Dis program
as
.CW /osinit.dis ,
with the 80K of headroom above to hold it.  Which is exactly the shape
.CW os/inferno/nucleof303 's
configuration already has, and the reason that configuration has no
Limbo userland in it.
.PP
Two things this does not fix.  A Cortex-M4 still cannot do the
interpreter's real arithmetic or link libmath, for the FPv4-SP reason
above, whatever the memory.  And none of these numbers come from a
256K part: they are a minimal configuration measured on an 8M board
under QEMU, with the
.CW Proc
array and the pool ceilings computed rather than observed at that size.
The pool figures are
.I in use ,
and a pool's xalloc'd chunk is at least that and rounded up.
.NH 1
What is left
.IP 1.
Emit the built-in root read-only, so it stays in flash.  This is the one
that turns the mechanism from working into paying, and the Cortex-M
section above is why: today
.CW utils/data2s/data2s.c
emits
.CW "DATA / GLOBL" ,
the root lands in the data segment, and on a board that executes out of
flash it is copied into RAM before anything runs \- so
.CW rootxip()
hands back a RAM address and the file occupies RAM whether or not it is
ever loaded.  Emitting it into the text or a read-only section instead
makes
.CW rootxip()
return a flash address and takes the file out of RAM entirely: 140404
bytes on
.CW teensy41 ,
447361 on
.CW mps2 .
It touches
.CW data2s ,
.CW os/inferno/port/mkroot
and the linkers' segment handling, none of which this branch changed,
and it wants checking on every board that bundles a root, not just the
ARMv7-M ones.
.IP 2.
A filesystem device over a memory-mapped flash or ROM window,
implementing
.CW Dev.xip
from a region rather than from the kernel image.  This is the piece that
makes the mechanism pay rather than merely work, and it needs a board
with such a window;
.CW -M raspi3b
has none, so it cannot be tested here.  QEMU's
.CW -M virt
does model pflash, and
.CW os/inferno/virtarm64
is the board that could carry it.
.IP 3.
Pre-decoded modules in that window, per the section above \- gated on
item 2, and worth it only there.
.IP 4.
.CW Dev.xip
on the flash and NAND filesystem devices already in
.CW os/inferno/port
.CW ( devflash.c ,
.CW devftl.c ,
.CW devlogfs.c )
where the underlying part is addressable, which for NAND and for serial
flash it is not.
.NH 1
Unrelated breakage found on the way
.PP
Two things in the tree are broken independently of this work, found while
bootstrapping it, and neither is caused by or fixed on this branch.
.IP \(bu
Emu does not link.
.CW libinterp/xec.c
calls
.CW printfreehist()
and
.CW libinterp/gc.c " and " heap.c
call
.CW dumpstack() ,
but the first is defined only in
.CW os/inferno/port/alloc.c
and the second only in each board's
.CW trap.c ,
so the hosted build has neither.  Present at this branch's starting
point; the call came in with commit
.CW 64ba3371 .
The emu side of this change is therefore compile-verified only:
.CW emu/port/sysfile.c
and
.CW emu/port/fns.h
compile clean, and the build gets as far as linking
.CW emu
before failing on those two symbols out of
.CW libinterp.a .
It is also why the nil-\c
.CW xip
path was verified against
.CW devmnt
on the booted kernel rather than against emu, which would otherwise be
its natural test.
.IP \(bu
.CW appl/danby
does not build \-
.CW "mk: don't know how to make 'SYSMODULES'" .
Its mkfile includes both
.CW mkfiles/mkdis
and
.CW mkfiles/mksubdirs .
Also pre-existing:
.CW dis/danby
does not exist in
.CW raspi3b-port
either.
