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
.CW "data + bss                       52508"
.CW "Proc array (8 x 2740)            21920"
.CW "pid hash table                     128"
.CW "main pool in use                 78208"
.CW "heap pool in use                  3840"
.CW "                                ------"
.CW "                                156604"
.DE
The first line is 77364 less the 24856 of string literals that
.CW tl\ -t
now puts in flash; see
.I "Strings to flash"
below.  That is 60% of 262144, leaving about 105K for a Limbo program.  So the
answer is yes, with the cuts above \- and with one configuration change
the arithmetic forces:
.CW main_pool_pcnt
and friends are percentages of the memory left after the kernel, and
40/40/20 of the roughly 188K remaining gives the main pool a 75K
ceiling, under the 78K it is measured to need.  The three armv7m boards
now carry 70/25/5, which is the same arithmetic run on measurements
rather than on a guess.  From
.CW #c/memory
on
.CW mps2
at a prompt, after
.I fptest
and an
.I ls (1):
.DS
.CW "            in use     arena high water"
.CW "main        367104            398848"
.CW "heap         73728            106240"
.CW "image            0                 0"
.DE
Heap is a fifth of main, so 25 against 70 leaves it room it has never
used.  Image is zero and has never been anything else on a board with no
draw device and no segments, but it cannot be zero in the percentages:
.CW poolsize()
asks that pool for its whole arena in one contiguous piece at boot and
panics if it cannot have it, so its share is a boot-time requirement as
well as a ceiling.  5% of 188K is 9K, which is both allocatable and not
worth arguing about.  These are ceilings, not reservations \- the pools
grow lazily \- so raising main costs nothing until it is used, and what
40/40/20 was costing was the ceiling itself.
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
with the 80K of headroom above to hold it.
.PP
That is the verdict against
.I this
loader, which decodes every module into the heap, and it should not be
read as a verdict on execute in place.  With the code in flash the
shell's own mutable state is about eight kilobytes, and it fits; the
next section does that arithmetic.  Which is exactly the shape
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
.NH 2
What the shell would cost if the code were in flash
.PP
The 260992 figure above is what the shell costs
.I this
loader, which decodes a module into the heap.  It is not what the shell
has to cost.  Execute in place done properly means the code stays in
flash and only the mutable per-instance state is in RAM, so the number
worth having is how that 260992 divides.
.PP
Measured on
.CW mps2
by reading
.CW #c/memory
from the init program at three points: before
.CW "load Shell \"/dis/sh.dis\"" ,
after it with nothing yet run, and at the prompt with the shell's own
dependencies in.
.DS
.CW "                        main      heap"
.CW "before the load       195328      4096"
.CW "after the load        303488     39296"
.CW "at the prompt         400384     72320"
.DE
So loading the module is 108160 of main and 35200 of heap, and running
it is another 96896 and 33024.  (This run has
.CW KSTACK
at its default 16K, which is why main starts higher than the 158208 in
the section above.)
.PP
Against that, the immutable part.  From the Dis headers at
.CW DISWORD=4 :
.DS
.CW "              Inst(12B)   dsize     ss"
.CW "sh.dis            73332    2360   2240"
.CW "sh/std.dis        23604     864   1920"
.CW "lib/bufio.dis      9348      56    960"
.DE
.CW isize * sizeof(Inst)
is 106284 bytes across the three, and it is read-only once relocated:
.CW libinterp/load.c:/^brpatch
rewrites branch targets at load time and after that
.CW libinterp/xec.c
only ever reads
.CW m->prog
\- it sets
.CW R.PC
from it and fetches through it, and never assigns into an
.CW Inst .
(The writes to
.CW ip->reg
in
.CW libinterp/das-386.c
and
.CW das-amd64.c
are the x86 disassembler's own
.CW Instr ,
a different type in files no ARM board links.  A JIT would be different:
these boards run with
.CW cflag
0.)
.PP
What must be in RAM per instance is
.CW dsize ,
the module data segment, and
.CW ss ,
the stack extent
.CW libinterp/stack.c:/^newstack
allocates \- 4600 bytes for
.CW sh ,
2784 for
.CW std ,
1016 for
.CW bufio ,
8400 for all three.  That is the real answer to "only load its stack and
frame pointer": on this target the mutable state of the shell is about
eight kilobytes against a hundred and six of code.
.NH 3
The heap becomes the problem
.PP
Which leaves the third term, and it is the one that does not move.  The
heap pool goes from 4096 to 72320, and 35200 of that is charged while
.CW sh.dis
is merely being loaded, before a line of it runs: those are the
.CW String
and array constants in its data segment, which
.CW parsemod()
builds as real Dis heap objects.  They cannot be put in flash as they
stand, because every Dis heap object carries a
.CW Heap
header
.CW ( include/interp.h )
whose
.CW ref
is written by reference counting and whose
.CW color
is written by the collector's
.CW Setmark .
There is no immortal or static convention in this tree to exempt them \-
no reserved
.CW ref
or
.CW color
that
.CW destroy()
and the collector both skip \- so a constant string in flash would fault
on the first mark.  Adding one is a real piece of work in
.CW libinterp/heap.c
and the collector, and it is what the remaining 35200 waits on.
.NH 3
The budget again, with the code in flash
.PP
Minimal configuration, the two debug arrays out,
.CW kmesg
at 2K,
.CW KSTACK
4K,
.CW NPROC
8, and modules pre-decoded into flash:
.DS
.CW "kernel data + bss                52508"
.CW "Proc array + pid hash            22048"
.CW "kernel pool floor, no modules    78208"
.CW "shell MP + stacks                 8400"
.CW "Dis heap objects                 68224"
.CW "                                ------"
.CW "                                229388"
.DE
262144 is the budget, so that is a shell fitting with about thirty-two
kilobytes to spare \- where against today's loader it overruns the whole
budget by itself.  That is the case for doing this, and it is the
answer: the shell does not have to load.
.PP
Two honest qualifications.  The last line is the measured heap at a
prompt, and 35200 of it is load-time constants that only the immortal-
object change above would move to flash; without that change the figure
stands as RAM.  And the main-side residue is not fully itemised: of the
205056 bytes main grows between the first and last measurement, 106284
is the
.CW Inst
arrays, and the rest is type, link, import and handler tables \- mostly
immutable, so mostly flash-able \- together with the
.CW Prog ,
.CW Chan
and
.CW Osenv
structures and the 16K kernel stacks of the processes the shell starts,
which are not.  The table above credits the flash-able part and keeps
the kernel pool floor as measured, which is the right side to err on but
is not the same as having measured a pre-decoded kernel, because there
is not one yet.
.NH 2
Is 229388 the floor?  No, and here is what is left in it
.PP
Categorising the whole of the minimal kernel's 181848 of
.CW data
plus
.CW bss ,
every byte accounted:
.DS
.CW "  90112  debug arrays (freehist + track)"
.CW "  48164  everything else"
.CW "  24856  C string literals (.string)"
.CW "  16420  kmesg log buffer"
.CW "   1584  Dis module tables"
.CW "    712  root filesystem"
.DE
The third line is the one not yet counted anywhere above, and it is the
same problem as the root file system: 24856 bytes of C string literals \-
print formats, error messages, device names \- that the Plan 9 linkers
put in the data segment, so
.CW os/inferno/armv7m/l.s:/^_datacopy
copies them into RAM although nothing ever writes one.  This one is now
built; see
.I "Strings to flash"
below.
.PP
Below that the items are small and there is no third big one:
.CW mntalloc
8248,
.CW cmsdkuart
4416, the 4096 boot stack, the 4096
.CW Mach ,
.CW xlists
2600, then nothing above 2112.
.PP
.CW sizeof(Proc)
being 2740 is worth one look, since the
.CW Proc
array is
.CW NPROC
of them.  What is big inside it is fixed-size arrays sized by constants
in
.CW os/inferno/port/portdat.h :
.CW "Label errlab[NERR]"
with
.CW NERR
64,
.CW errbuf0
and
.CW errbuf1
at
.CW ERRMAX
each,
.CW "genbuf[128]" ,
and
.CW "note[NNOTE]" .
A board that will never nest 64
.CW waserror()
levels can cut
.CW NERR
and
.CW NNOTE ,
and the saving multiplies by
.CW NPROC .
.PP
Both of those are now built \-
.CW NERR
against
.CW NPROC
above, and the Dis heap is measured rather than estimated below \- so
what remains is named in
.I "Where this stands" .
.NH 3
The part that is not understood
.PP
The honest gap is the kernel pool floor: 78208 bytes in 343 allocations
with the minimal configuration and nothing loaded but a 512-byte init.
Four kernel stacks at
.CW KSTACK
4K are 16384 of it.  The other 62K is not itemised \- it is
.CW Chan ,
.CW Osenv ,
.CW Pgrp
and the rest of the namespace, the device reset and init allocations, the
osinit module, and the pools' own per-block headers and quanta rounding
.CW ( os/inferno/port/alloc.c:/^poolalloc
rounds every request up by
.CW BHDRSIZE
and the pool quantum, which over 343 blocks is not nothing).  It is now
the largest single term in the budget and the only one nobody has looked
inside.  Anything further than the 190K above should start there rather
than with more trimming of what is already measured.
.NH 2
Could the interpreter just run the packed form?
.PP
It is the obvious question, since the decode is what costs the RAM, and
the answer is yes but you would not want to on this hardware.  Worth
writing down either way, because the reason is not the one you would
guess: the interpreter already decodes every instruction, every time it
executes it.
.CW libinterp/xec.c:2439
is
.DS
.CW "dec[R.PC->add]();"
.CW "op = R.PC->op;"
.CW "R.PC++;"
.CW "optab[op]();"
.DE
.CW dec[]
is a table generated by
.CW libinterp/decgen.c
into
.CW libinterp/dec.c ,
indexed by the instruction's addressing-mode byte, whose job is to set
.CW R.s ,
.CW R.d
and
.CW R.m
before the opcode handler runs.  So a per-instruction decode step is not
a new cost to be introduced; it is already there.  What
.CW parsemod()
does at load time is only to widen the operands to fixed fields, 12
bytes per instruction on a 32-bit target against a measured 6.8 average
packed.
.PP
Three things would have to change, and none is deep:
.IP 1.
.CW R.PC
is an
.CW Inst*
throughout, and the interpreter does arithmetic on it
.CW ( R.PC-R.M->prog
for the program counter,
.CW "R.PC = R.M->prog + d"
for a jump).  It becomes a byte pointer.  Broad, mechanical.
.IP 2.
The generated
.CW dec
functions hand out addresses
.I inside
the instruction \-
.CW D02
is
.CW "R.d = (uchar*)&R.PC->d.imm" .
A packed operand is one, two or four bytes, sign-extended, and not
aligned, so there is no word in the stream to point at; those modes have
to decode into a scratch word in
.CW R
instead.  That is a change to
.CW decgen.c ,
which generates all of them, rather than to each.
.IP 3.
The real one: branch targets.
.CW parsemod() 's
.CW DST(AIMM)
case runs
.CW brpatch() ,
which turns a branch's instruction
.I index
into an absolute
.CW Inst*
.CW ( ip->d.imm
.CW = "(intptr)&m->prog[ip->d.imm] ).
Packed instructions are variable length, so an index is no longer
something you can turn into an address by multiplying.  Either the
format grows byte-relative branches \- a Dis change, and
.CW limbo
with it \- or the module carries an index-to-offset table, which at two
bytes per instruction is 12222 bytes for
.CW sh.dis
against the 73332 the
.CW Inst
array costs, and which is immutable and so can itself live in flash.
.PP
So it is buildable.  It is also the wrong trade here.
.CW teensy41
has eight megabytes of flash against one of RAM, and pre-decoding into
flash at build time gets the
.I same
RAM saving \- the whole
.CW Inst
array \- for no interpreter change at all and no loss of speed, paying
only 1.76 times the packed size in the memory there is most of.
Interpreting the packed form buys smaller flash and costs interpreter
work on every instruction for the life of the system.
.PP
Where it does win is the case this branch started from and has not
reached: a real execute-in-place file system in memory-mapped NOR flash,
with modules written to it after the kernel was built.  Those cannot be
pre-decoded at build time, so today they would be decoded into the heap
on load and the execute-in-place property lost for exactly the bytes
that matter.  There the choice is packed interpretation or decoding once
at install time and storing the wide form in flash \- which keeps full
speed and zero RAM at the cost of writing flash when a module is
installed, and is probably the better of the two.
.PP
One thing to check before any of this, and it applies to pre-decoding
into flash just as much: whether an immediate can ever be an instruction's
.I destination
rather than a source.
.CW D02
sets
.CW R.d
to point into the instruction and
.CW "R.m = R.d" ,
and
.CW brpatch()
returns success without patching for any op that is not a branch, so
nothing in the loader forbids it.  If the Limbo compiler never emits
such a form the question is moot; if it does, that instruction would be
written through, and code in flash would fault where code in the heap
silently modified itself.  Not established either way here.
.NH 1
The tradespace
.PP
Everything above measured one system.  What follows is the space of
things that could be done to it, because the choices are not
independent and the cheap ones are not the interesting ones.
.PP
A loaded module costs RAM in three separate buckets, and they behave
differently, which is what makes this a tradespace rather than a list:
.IP \(bu
.B Code.
The decoded
.CW Inst
array, 1.76 times the packed file on a 32-bit target, 106284 bytes for
.CW sh ,
.CW sh/std
and
.CW lib/bufio .
Immutable once relocated.
.IP \(bu
.B Metadata.
Type, link, import and handler tables and the
.CW Module .
Mostly immutable, not separately measured; it is most of the difference
between the 205056 main grows and the 106284 the
.CW Inst
arrays account for.
.IP \(bu
.B Mutable state.
The
.CW dsize
data segment and the
.CW ss
stack extent, 8400 bytes for those three modules, plus Dis heap objects,
68224 at a prompt of which 35200 are load-time constants.
.PP
Only the third bucket has to be in RAM, and only two thirds of that.
.NH 2
The cheap cuts, which are not choices
.PP
These are measured, carry no design risk, and none of them interacts
with anything below.  Do them whatever else happens.
.DS
.CW "drop freehist + track            -90112   bss"
.CW "kmesg 16420 -> 2048              -14372   bss"
.CW "KSTACK 16K -> 4K                 -12288   per proc"
.CW "NPROC -> 8                        -2740   per proc dropped"
.CW "pool split 40/40/20 -> 60/25/15        0   enabling, not saving"
.DE
.CW KSTACK
at 4K is verified to boot to a shell, and four procs hold stacks at a
prompt, so that line is 49152 as measured.  The pool split saves nothing
but a part this size does not work without it: the percentages are of
what is left after the kernel, and 40% of the remainder is under what
the main pool is measured to need, while the image pool measures zero in
use.
.NH 2
The real choice: where the code lives
.PP
Five positions, and the columns are what distinguishes them.
"Runtime" means whether it works for a module written to the board after
the kernel was built, which is the case an execute-in-place file system
exists for.
.DS
.CW "                     RAM saved   flash    work            speed  runtime"
.CW "0 decode to heap             -       -    none              1.0      yes"
.CW "A read-only data       165260   +same    linker/mkroot      1.0      n/a"
.CW "B pre-decode, build    106284   +1.76x   trivial            1.0       no"
.CW "C pre-decode, install  106284   +1.76x   small + writer     1.0      yes"
.CW "D interpret packed     106284   +0/2B    decgen + branches  <1.0     yes"
.CW "N compile to flash    106284+   +2-4x    port comp-arm.c   >>1.0      no"
.DE
.IP A
The root file system and the C string literals, 140404 and 24856 on
.CW teensy41 ,
both read-only, both copied into RAM today by
.CW os/inferno/armv7m/l.s:/^_datacopy .
One mechanism fixes both and it is not in the interpreter at all.
Nothing else here is as cheap per byte.
.IP B
Emit the decoded
.CW Inst
array, tables and relocations into the image at build time and point
.CW m->prog
at flash.  No interpreter change.  The arithmetic that rejected this for
.CW raspi3b
inverts here: pre-decoding costs flash and saves RAM, and
.CW teensy41
has eight megabytes of the former and one of the latter.
.IP C
The same, done when a module is installed to flash rather than when the
kernel is built, which is what makes it work for modules that arrive
later.  Costs a flash writer and an erase-block dance; keeps full speed
and zero RAM.
.IP D
Interpret the packed form.  Cheaper in flash than B or C and the only
option that needs no wide form anywhere, but it charges operand decoding
on every instruction forever and needs the branch-target problem solved
\- byte-relative branches in the format, or a 2-byte-per-instruction
index table, 12222 for
.CW sh.dis .
.IP N
Skip the interpreter: compile Limbo to Thumb ahead of time into flash.
.CW libinterp/comp-thumb.c
is a deliberate 34-line stub, and its own comment gives the reason \- a
JIT would put generated code in RAM, "competing with the heap for the
scarcest thing on the board".  Ahead of time into flash inverts that
exactly.
.CW libinterp/comp-arm.c
is 2280 lines of working ARM code generator to model it on, but ARMv7-M
is Thumb-2 only, so this is a real port and not a recompile.  It buys
the code bucket
.I and
the interpreter's dispatch, and it gives up what Dis is for: one
portable, verifiable object form.
.NH 2
Orthogonal to all five
.PP
.B "Immortal heap objects."
35200 of the 68224 heap is
.CW String
and array constants
.CW parsemod()
builds from a module's data segment before a line of it runs.  They
cannot go in flash while every Dis heap object's
.CW Heap
header carries a
.CW ref
that reference counting writes and a
.CW color
that
.CW Setmark
writes.  A reserved value that
.CW destroy()
and the collector both skip would move them.  This composes with any of
0 to N and is the second largest single win after the code itself.
.PP
.B "A smaller program."
.CW sh
and
.CW sh/std
are 96936 of the 106284.  Whatever happens to the code bucket, a
purpose-built module in place of the shell is the largest single lever
on this board, and it is the only one that needs no kernel work at all.
.NH 2
What to do, in order
.IP 1.
The cheap cuts.  Measured, no risk, and they are the difference between
890K and roughly 580K on
.CW teensy41 .
.IP 2.
A, the read-only move.
.B "Half done" :
the built-in root now goes in the text segment and stays in flash, which
takes
.CW teensy41 's
data plus bss from 417216 bytes to 277552 \- a saving of
.B 139664 ,
the bundled root to within the padding \- while its text grows from
392176 to 540472, into flash it has eight megabytes of.
.CW utils/data2s/data2s.c
grew
.CW -t ,
which emits
.CW WORD
lines under a
.CW TEXT
symbol instead of
.CW DATA
lines under a
.CW GLOBL ,
the same thing
.CW os/inferno/armv7m/l.s
already did for its vector table;
.CW mkroot
passes it when a board sets
.CW ROOTINTEXT ;
and
.CW devroot.c
masked the low bit of the pointer, because a reference to a text symbol
on an ARM target carries the Thumb bit and the bytes start at the even
address.  That last one announced itself as a panic of "bad magic"
loading
.CW /osinit.dis
on the first boot after the change.
.IP
That masking is gone.  Once
.CW RODATA
existed \- see
.I "Naming a table read-only"
below \-
.CW data2s\ -t
had no reason to emit a
.CW TEXT
symbol at all: it emits the same
.CW DATA
lines as without
.CW -t
and puts
.CW RODATA
on the
.CW GLOBL ,
so the root is data that happens to live in the text segment and its
address is its address.
.CW devroot.c
uses
.CW rootdata[p].ptr
directly again.  The byte-packing caveat goes with it \- there is no
longer a word to pack, so nothing here is endianness-dependent \- and a
linker that does not know
.CW RODATA
ignores the flag and lays the symbol out in the data segment, which is
the behaviour without
.CW -t .
Same data and bss on all three boards, a few bytes less text, and
.CW "cat /dis/init"
reads a built-in file.
.IP
.CW mps2
boots with the root in text and
.I fptest (1)
is still 25 of 25 there, which is what proves the mechanism though it
gains no RAM, having no flash.
.CW nucleof303
comes out 288 bytes worse, bundling only 512 bytes of root against the
per-symbol padding \- an honest non-result for a board with no userland.
It was opt-in because
.CW virt
(riscv64) stopped booting with the root in text: no output at all, not
even its banner, where the same kernel with the root in data reached an
interactive shell.  The guess recorded here was
.CW mmuinit 's
mapping, on the grounds that the board has an MMU and its text grew by
some 450K.  The guess was wrong, and the answer turned out to be the
.CW TEXT
emission itself \- see
.I "The other two linkers"
below.  It is no longer opt-out for anyone: with
.CW RODATA ,
.CW virt
boots with its root in the text segment and 590856 bytes off its RAM.
.IP
.B "Strings to flash."
The other half is the C string literals.  Same reasoning, different
source: they come from the compiler, not from
.CW mkroot ,
so the root change does not reach them.  It turns out
.CW tl
already has the feature, under
.CW -t :
.CW utils/tl/pass.c
retypes a string constant's symbol to
.CW SSTRING ,
.CW utils/tl/span.c
gives it an address past the end of the instruction stream, and
.CW utils/tl/asm.c
writes it as
.CW 'T'
in the symbol table.  It had never been used on this target and did not
work.  Three faults, each of which had to be fixed before the next was
visible:
.IP \(bu
.CW asm.c
zero-fills the text segment out to
.CW etext
after the last instruction, and only then runs the loop that writes the
strings \- which by that point starts at
.CW etext
and writes nothing.  Every string read as zeroes; the board died before
its first character of output.  Fixed by having
.CW span.c
record where the string block starts
.CW ( strbase )
and padding only that far.
.CW 5l ,
which has no such fill loop, does not have this bug.
.IP \(bu
.CW thumbaclass
in
.CW utils/tl/thumb.c
has cases for
.CW STEXT ,
.CW SLEAF
and
.CW SCONST
but none for
.CW SSTRING ,
so every string pointer fell through to the default and was relocated as
.CW "s->value + INITDAT" \-
a flash address biased by the RAM base.  The same gap is in
.CW aclass
in
.CW span.c ,
where
.CW SSTRING
was instead grouped with
.CW STEXT
and so would have taken a Thumb bit and a function-pointer thunk.  A
string is data that happens to live in the text segment: it gets
neither.
.IP \(bu
.CW pass.c
moved any symbol with a
.CW D_SCONST
initialiser, and
.CW sextern()
in the compiler emits a plain
.CW "char x[] = \(fm...\(fm;"
that way too, under the user's own symbol.  That array is writable, and
moving it to flash would lose every write to it in silence.  Restricted
to
.CW .string ,
which is the name
.CW utils/cc/lex.c
gives the compiler's own per-file literal pool.  No kernel symbol was
being wrongly moved \- all 78 that move on
.CW teensy41
are
.CW .string \-
so the restriction costs nothing and removes the trap.
.IP
With
.CW "-t"
in
.CW LDFLAGS
for the
.CW os-thumb
target, measured as
.CW "data + bss" :
.DS
.CW "               before     after    saved"
.CW "teensy41       160824    130312    30512"
.CW "nucleof303      74696     49096    25600"
.CW "mps2           162904    132400    30504"
.DE
On
.CW nucleof303
that is a third of the board's remaining RAM, and its data segment more
than halves, 50304 to 24704.
.CW mps2
gains nothing real, having no flash, but it is where the result is
checked:
.I fptest (1)
is 25 of 25 and
.I cvtchk (1)
is clean on both the M4 and the M7 bench, and every diagnostic quoted in
this document is itself a string literal now read from flash.
.NH 3
Naming a table read-only, for what comes next
.PP
.CW -t
moves the compiler's literal pool and nothing else, which is right for
what it is but is not a mechanism anything else can use.  The next item
on the list \- pre-decoded
.CW Inst
arrays \- needs a way to say that one named table belongs in the text
segment, and it needs a reference to that table's own address to come
out exactly right, since a branch target in a decoded
.CW Inst
is a pointer into the array itself.
.PP
The assembler already had the syntax.
.CW utils/5a/a.y
accepts a flags field on
.CW GLOBL
and has for as long as this tree has existed;
.CW utils/tl/obj.c
threw it away.  It is now read, with the value the Go toolchain uses for
the same thing, and a symbol that asks for it is laid out with the
strings:
.DS
.CW "GLOBL	tab(SB), RODATA, $16"
.CW "DATA	tab+4(SB)/4, $tab+12(SB)"
.DE
Linked into
.CW mps2
and read back at boot, that table lands at
.CW 0xd5710 ,
inside the text segment, and the self-reference reads
.CW 0xd571c :
base plus twelve, even, no Thumb bit.  The same word written as
.CW "WORD $sym(SB)"
inside a
.CW TEXT
block \- which is how the root file system is emitted \- comes back
.CW 0xd5719
instead, because a reference to a text symbol is a reference to code.
The root can mask that off at its one site;
.CW Inst
branch targets could not.  So this is the placement the pre-decoded
modules will use, and the
.CW SSTRING
relocation it depends on is the one fixed above.
.PP
Unlike
.CW -t
this is not a policy applied to a program, so it is honoured whether
.CW -t
was given or not, and the layout pass that places these symbols now runs
unconditionally \- it does nothing when there are none.  Linking
.CW teensy41
with the old and the new
.CW tl ,
both with and without
.CW -t ,
gives byte-identical images.
.PP
That last check is weaker than it looks and needs one more, because
.CW mps2 's
text segment is ZBT SRAM: a write to a string literal succeeds there in
silence, where on
.CW teensy41 's
memory-mapped flash it would not.  So the test has to be whether the
text segment is written at all, and QEMU can answer that from outside
the kernel.  Boot, run
.I fptest ,
.I cvtchk ,
.CW "ls /dis"
and
.CW "cat /dev/memory" ,
then from the monitor
.DS
.CW "(qemu) pmemsave 0 0xd68b0 \(fmtext.bin\(fm"
.DE
and compare with the first
.CW 0xd68b0
bytes of
.CW imps2 :
byte for byte identical.  Nothing in that workload writes its own text.
That is not a proof for paths it does not exercise, so the pattern that
would break it was looked for as well \-
.CW tokenize() ,
.CW getfields()
and the rest write their argument in place, and a literal passed to one
would now be a write to flash.  Every call in the port and
.CW armv7m
directories takes a buffer that came from a control message or a
.CW kstrdup ,
including
.CW devether.c:/nopt\ =\ tokenize ,
which tokenises the copy and not the configuration string.  None takes a
literal.
.IP 3.
B, for modules built into the image.  Small change, full RAM win, and it
is where the execute-in-place property finally reaches the code rather
than only the file.
.B "Begun."
.CW utils/dis2s
lays out at build time the
.CW Inst
array that
.CW libinterp/load.c:/^parsemod
would otherwise build in RAM at every load, as a
.CW RODATA
symbol the linker puts in the text segment, with each branch target
written
.CW "$<sym>prog+<12*target>(SB)"
and left for the linker \- so nothing in the tool has to know where the
array will land.
.CW parsemod
looks the module up by what it is loaded as and by the length of the
file it was built from, and on a match points
.CW m->prog
at the image and walks the instruction stream into a scratch
.CW Inst
whose contents are thrown away, since the stream still has to be walked
to leave the data segment in the right place.
.CW freemod
does not free an array it does not own.
.PP
.CW mps2
carries one module so far,
.CW /osinit.dis ,
which is the right one to start with because it loads at boot on every
board and a failure is immediately visible.  It does:
.DS
.CW "XIPMOD /osinit.dis nprog 55 prog d4fb0"
.DE
with
.CW 0xd4fb0
inside the text segment, and the main pool at a prompt goes from 367104
to 366336 \- 768 bytes, being 55 instructions at twelve plus the
allocator's header, which is the whole of what that module's
.CW Inst
array used to cost.  A 55-instruction module is a demonstration and not
a saving, so the modules a shell prompt actually loads went in next.
Which those are was traced rather than guessed, by printing every path
.CW parsemod
is given: nine of them, being
.CW /osinit.dis ,
.CW sh.dis ,
.CW ls.dis
and the six library modules under
.CW /dis/lib
that those two pull in, 110616 bytes of
.CW Inst
between them.  With all nine built in, from
.CW #c/memory
on
.CW mps2 :
.DS
.CW "                      before     after"
.CW "main, at a prompt     349952    248832"
.CW "main, after ls        367104    265216"
.CW "arena high water      398848    287488"
.CW "kernel text           878704    989720"
.CW "kernel data + bss     132400    132568"
.DE
101888 bytes of RAM for 111016 of flash, which on a part with megabytes
of flash and a couple of hundred kilobytes of SRAM is the trade this
whole document is about.  The 168 bytes of data are the table itself,
nine entries and a pointer.  The shell runs from flash:
.I fptest (1)
is 25 of 25,
.I cvtchk (1)
is clean and
.I ls (1)
works, on the M7 and the M4 bench both.
.CW teensy41
carries the same nine, going from 571152 of text to 682144 against its
eight megabytes of flash.
.PP
A module that is in the list but is not the module the root carries is
simply not matched \- the length of the file it was built from is part
of the match \- so getting the list wrong loses the saving rather than
running the wrong code.
.PP
Two checks, because running a shell exercises a few hundred of
.CW sh.dis 's
6111 instructions and says nothing about the rest.  The first is that
the emitter agrees with the interpreter.  The decode loop still runs in
the execute-in-place case, into a scratch
.CW Inst ,
so the two can be compared where they are both in hand: with
.CW brpatch
run on the scratch copy, whose
.CW &m->prog[target]
is the flash entry,
.CW memcmp
against the built-in array is exact \-
.CW sizeof(Inst)
is 12 with no padding and the loop clears every field it does not set.
Nine modules, 9218 instructions, no mismatch.  That is every instruction
of every module checked against what
.CW parsemod
would have built, rather than the fraction a shell session happens to
execute, and it is what makes a hand-written mirror of the decode
acceptable.
.PP
The second is that nothing writes its own text, checked the same way as
for the string literals but now over 989720 bytes that include the nine
instruction arrays:
.DS
.CW "(qemu) pmemsave 0 0xf1a18 \(fmtext.bin\(fm"
.DE
after a shell,
.I ls ,
.I fptest
and
.I cvtchk ,
compared against
.CW imps2 :
identical.  Nothing patches a Dis instruction at runtime, which a grep
for
.CW m->prog[
could not have settled, since the dump does not care how a write would
have arrived.
.PP
The type descriptors go the same way.  A
.CW Type
is a size, a pointer count and a pointer map, none of which depends on
the instance, plus two function pointers that
.CW parsemod
always fills with the same values \-
.CW freeheap
and
.CW markheap ,
which the linker resolves in the emitted assembler, with the Thumb bit,
which is what a function pointer wants on this target \- and two more
that
.CW dtype
leaves nil.  What stops it being laid in flash outright is the
reference count, which is the one mutable field.
.PP
So a
.CW Type
whose count is
.CW Timmortal
is one the kernel does not own: never counted, never freed.  Every
reference to a count now goes through
.CW typeinc()
and
.CW typedec()
rather than touching
.CW ref
directly \- 23 sites across seven files in
.CW libinterp ,
because an
.CW AINC
on one of these is a write to flash that is dropped or faults.
.CW typedec()
answers what a decrement would have left, so a caller can go on asking
whether it holds the last reference; for an immortal
.CW Type
the answer is always no.
.PP
.CW parsemod
takes the array from the image when the module matches, and checks
every descriptor against the file as it walks the stream: size, pointer
count and map.  That is not a separate test, it is the load path, and it
was confirmed to work by changing one byte of one map in one of the 214
descriptors
.CW mps2
carries, which gives
.DS
.CW "panic: loading \(fm/osinit.dis\(fm: built-in type"
.CW "	descriptor mismatch"
.DE
From
.CW #c/memory
and
.CW #c/poolhist :
.DS
.CW "                      before     after"
.CW "main, at a prompt     109184     97152"
.CW "main, after ls        128704    114688"
.CW "dtype                  16448      4544"
.CW "live blocks              1041       849"
.CW "block headers           20820     16980"
.CW "teensy41 text          682368    690720"
.DE
8352 bytes of flash for 14016 of RAM.  Eight rounds of
.I ls (1),
4201 allocations and 3352 frees, then
.I fptest (1)
and
.I cvtchk (1):
clean on the M7 and the M4 bench.
.PP
One bug is worth recording because of how it presented.  Routing the 23
sites was done by substitution, and the substitution rewrote the body of
.CW typeinc()
itself into a call to
.CW typeinc() .
The result was unbounded recursion, which ran off the end of the kernel
stack and into whatever followed it, and what reached the console was
.DS
.CW "qemu: fatal: Lockup: can't escalate 3 to HardFault"
.DE
with a program counter in the middle of the emitted data and a link
register inside
.CW print .
Neither was the fault: the first exception was an undefined instruction,
which
.CW "qemu -d int"
shows as exception 6, and the second was
.CW print
being called from the fault handler to report the first.  The register
dump belongs to the second fault and says nothing about the first.  What
found it was
.CW "-d int,cpu" ,
whose program counter for the first exception landed two bytes before
.CW dtype ,
with
.CW 0x40000000
in a register \- inside
.CW typedec ,
which is where the recursion was.
.PP
What is not done: the link tables and the exception handlers still parse
into RAM.
.IP 4.
The immortal-object change, which is what is left of the heap.
.IP 5.
C, and only if modules really do have to arrive after the build \- which
is the case a flash file system exists to serve, so probably yes,
eventually.  D instead of C only if flash turns out to be the scarce
side, which on none of these three boards is it.
.IP 6.
N only for speed, never for space, and not before someone wants Limbo
fast on a Cortex-M more than they want it portable.
.NH 2
The pool floor, measured rather than guessed
.PP
With the instruction arrays out of RAM, what is left was read from
.CW #c/poolhist
rather than estimated, after a shell and an
.I ls (1):
264704 bytes live in 1327 blocks, and the histogram is the finding.
.DS
.CW "  <=128   1258 blocks   161024 bytes"
.CW "  <=8192    12 blocks    73600 bytes"
.DE
1258 blocks charged exactly 128 bytes each, to the byte.  The pools
round every request up to
.CW quanta+1
.CW ( poolalloc ),
and
.CW quanta
was 127 on every target.  The largest single caller was
.CW dtype ,
at 70016 bytes for 547 Dis type descriptors of about forty bytes apiece.
.PP
127 is the right answer for a 64-bit target and twice what a 32-bit one
needs.  The quantum is also the smallest block a pool hands out, and the
smallest block has to be one that still works once it is freed:
.CW Bhdr 's
fixed fields, the five-pointer union it uses on the free lists, and a
.CW Btail .
Asked of the compiler rather than counted by hand \-
.CW BHDRSIZE
is 20,
.CW sizeof(Bhdr)
36 and
.CW sizeof(Btail)
4 \- that is 40 bytes on this target, so 64 is the power of two above
it and the quantum is 63.  On a 64-bit target the same three come to 80
and the answer stays 128.  The quantum now follows
.CW sizeof(void*) ,
and the invariant is checked at compile time by dividing by it, so a
target that breaks it does not build; that was confirmed by breaking it
on purpose, which gives
.CW "alloc.c:61 divide check" .
.PP
On
.CW mps2 ,
from
.CW #c/memory :
.DS
.CW "                      before     after"
.CW "main, at a prompt     248832    170688"
.CW "main, after ls        265216    204544"
.CW "heap, at a prompt      71808     56512"
.CW "dtype                  70016     35072"
.DE
Nothing else changed, and nothing else had to: this is the same
allocation pattern charged what it costs.  Fifteen rounds of
.I ls
over three directories \- 11341 allocations and 10011 frees \- leave
the pool at 186304 live in 1332 blocks with no fault and no corruption,
and
.I fptest (1)
and
.I cvtchk (1)
are clean on the M7 and the M4 bench.
.NH 2
The per-proc instruction trace, which was in every Prog
.PP
With the quantum corrected,
.CW #c/poolhist
still showed twelve blocks of about six kilobytes each, 73280 bytes, and
.CW addprog
holding 36800 of it.  The reason is in
.CW Prog :
.DS
.CW "	} wmtrace[256];"
.DE
a ring of the last 256 Dis instructions the proc dispatched \- pc, op,
frame pointer, module and the three decoded operands, 28 bytes an entry
\- which is 7168 bytes in every
.CW Prog ,
recorded unconditionally, seven stores per instruction interpreted.  It
is a diagnostic from the
.CW wm.dis
hunt and its comment says so.
.PP
Same treatment as
.CW freehist
and
.CW track :
the buffer is allocated rather than held inline, and
.CW wmtracesize
says how many entries a proc gets, with zero meaning the buffer is not
allocated and nothing is recorded.  The armv7m boards set it to zero
beside the other two.  From
.CW #c/memory
on
.CW mps2 :
.DS
.CW "                      before     after"
.CW "main, at a prompt     170688    127680"
.CW "main, after ls        204544    147200"
.DE
.PP
Checking a diagnostic that is switched off is worth more than it sounds,
because a switched-off feature that has been broken looks exactly like
one that is working.  Building
.CW mps2
with
.CW wmtracesize
left at its default and dumping the ring from
.CW xec
after two hundred instructions printed nothing at all \- the buffer was
nil.  The allocation had been put in
.CW addprog ,
which is not where a Dis proc is made:
.CW newprog
is, and it allocates the
.CW Prog
and its
.CW Osenv
in one block.  With the allocation there too, and the buffer freed in
.CW delprog ,
the same test prints what it should:
.DS
.CW "wmtrace (last 200 instructions dispatched ...):"
.CW "  [0] pc=11 op=41 fp=1a6370 ... path=/dis/lib/readdir.dis"
.DE
descending through the ring with the module paths resolved.  The
measurement above would have been the same either way, which is the
point.
.PP
Against where this document started, the main pool after an
.I ls
has gone 367104, then 265216 with the instruction arrays in flash,
204544 with the quantum corrected, and 147200 with the trace off.  Eight
more rounds of
.I ls
\- 5164 allocations, 3832 frees \- leave it at 136064 live with no
fault, and
.I fptest (1)
and
.I cvtchk (1)
are clean on the M7 and the M4 bench.
.NH 2
One frame type per builtin function, of which twenty are distinct
.PP
With the instruction arrays in flash, the quantum corrected and the
trace gone,
.CW dtype
was the largest item left: 35072 bytes in 548 live
.CW Type s.
The nine pre-decoded modules declare 214 of those between them.  The
other 334 come from one place,
.CW libinterp/runt.c:/^builtinmod ,
which calls
.CW dtype
once per exported function of every builtin module \- the frame
descriptor for a call into C.  On a kernel carrying
.CW sys ,
.CW keyring ,
.CW crypt
and
.CW math
that is 334 allocations of about forty bytes, charged 64 each.
.PP
A frame descriptor is a size, a pointer count and a pointer map, and
most builtins have the same shape: of the 334, about twenty are
distinct.  They are now shared.  Sharing is safe here in a way it would
not be for a Dis module's own types \- a
.CW Type
is a pure descriptor, nothing compares one by identity, the reference
count is kept correct, and
.CW destroylinks()
never frees these at all, because a builtin module is never unloaded.
They have always lived for the life of the kernel; there are now twenty
of them rather than 334.
.PP
Counted rather than assumed: the call was instrumented before the change
and reported 558 calls, 10 frees, 548 live at the first prompt, and 35
more created and 35 freed on each
.I ls (1)
\- so no leak, and the 334 really are permanent.  After the change, from
.CW #c/memory
and
.CW #c/poolhist
on
.CW mps2 :
.DS
.CW "                      before     after"
.CW "main, at a prompt     127680    109184"
.CW "main, after ls        147200    128704"
.CW "dtype                  35072     16448"
.CW "live blocks              1327      1041"
.CW "block headers           26540     20820"
.DE
286 fewer blocks, which is the 334 collapsing to about fifty once the
.CW sys
table's larger maps are counted.
.PP
The check that matters is the pointer map, because a shared descriptor
with the wrong map would not fail loudly \- it would make the garbage
collector mark the wrong words.  Ten rounds of
.I ls (1)
over four directories, 5603 allocations and 4562 frees, with
.I fptest (1)
and
.I cvtchk (1)
after them: clean, on the M7 and the M4 bench.  That exercises
.CW sys
and
.CW math
builtins heavily and the
.CW string
and
.CW bufio
modules through them;
.CW keyring
and
.CW crypt
are linked into this board but nothing in its root reaches them, so they
are shared on the same argument and not on the same evidence.
.NH 2
The Proc array, which is not pool memory and so was never in the figures
.PP
.CW procinit
takes
.CW conf.nproc*sizeof(Proc)
from
.CW xalloc ,
not from a pool, so none of the
.CW #c/memory
numbers above ever included it.  On
.CW mps2
that was 64 procs of 2740 bytes: 175360 bytes, more than the whole main
pool at a prompt.
.PP
Two measurements.  How many are used, counted at every
.CW newproc
without ever decrementing, so it is an upper bound: five, over a shell,
background jobs,
.I fptest (1)
and
.I cvtchk (1).
Kernel procs are not what a shell's background jobs create \- those are
.CW Prog s
\- so five is the device set, not the workload.  And how deep
.CW waserror()
nests, since
.CW Proc.errlab
is
.CW NERR
.CW Label s
at eight bytes each: eight, over the same workload plus failing opens.
.PP
So
.CW NPROC
is 16 on
.CW mps2
and
.CW teensy41 ,
three times what was measured, and
.CW NERR
is 24, also three times, which a board now sets in its
.CW mem.h
the way it already sets
.CW KMESGSIZE .
.CW sizeof(Proc)
goes 2740 to 2420, checked with the compiler rather than counted.
.DS
.CW "               before    after     saved"
.CW "mps2           175360    38720    136640"
.CW "teensy41        87680    38720     48960"
.CW "nucleof303      21920    19360      2560"
.DE
.CW nucleof303
keeps 8 procs, which it already had.  Heavy concurrency \- four
.I ls (1)
at once, repeatedly \- brings no
.CW newproc
failure, and
.I fptest (1)
is 25 of 25 and
.I cvtchk (1)
clean on the M7 and the M4 bench.
.PP
.CW NNOTE
is left alone.  It is 5 notes of 132 bytes in every
.CW Proc
and reducing it would save 396 more, but nothing in these workloads
posts a note, so there is no measurement to size it by and a dropped
note is a lost kill.
.NH 2
The kernel stacks, which cannot be cut
.PP
With the frame types shared,
.CW newproc
is the largest single allocation left: 20800 bytes, being five kernel
stacks of
.CW KSTACK
4096 plus their block headers.  4096 is already down from the 16384 this
document started with, and the obvious next step is 2048.  It is not
available.
.PP
Measured by filling each stack with a pattern at
.CW newproc
and reporting the deepest byte disturbed:
.DS
.CW "pid 1  used 2704 of 4096  (interp)"
.CW "pid 3  used 2524 of 4096  (dis)"
.CW "pid 4  used 2148 of 4096  (dis)"
.CW "pid 2  used  272 of 4096  (closeproc)"
.DE
over a shell, three nested
.I sh (1)s,
a pipeline,
.I ls (1),
.I fptest (1)
and
.I cvtchk (1).
The interpreter proc peaks a little over 2700 bytes, which leaves about
1300 of headroom in 4096 and none at all in 2048.  So
.CW KSTACK
stays at 4096, and the 16K to 4K cut made earlier was closer to the edge
than it looked.
.PP
The honest caveat is that a watermark measures the paths that ran.  1300
bytes is not a lot of margin for one that did not, and the parts this is
for have no memory protection to catch an overflow \- it would land in
whatever the allocator put below the stack.  That is an argument for
measuring it again on the real board with its own drivers in the way,
not for cutting it further.
.NH 2
The hosted build, which had not linked
.PP
.CW emu
links
.CW libinterp
too, and on this branch it had not linked at all: the allocator and
garbage-collector checks added during the
.CW wm.dis
hunt call
.CW dumpstack()
and
.CW printfreehist() ,
which every kernel has \-
.CW dumpstack
per machine in its
.CW trap.c ,
.CW printfreehist
in
.CW os/inferno/port/alloc.c
\- and which a hosted process has neither of.  Nothing that links
.CW libinterp
could link.  Both now have honest stubs in
.CW emu/port
saying there is nothing to report, and
.I emu (1)
runs a shell again.
.PP
That matters beyond tidiness: it is the only way to check that portable
changes made for these boards have not broken the 64-bit path, and the
.CW Timmortal
work is portable code.  It has not:
.CW libinterp
builds for
.CW arm64
and
.CW emu
runs.  It does print
.DS
.CW "marklist: bad container ... ref 0 color 2"
.DE
on some runs, which is the Dis heap tracker from that same hunt and is
not this work: four runs in ten with the change and four in ten without
it, on the same workload.  It is left as found and named here so the
next person does not attribute it.
.NH 2
The other two linkers, and what the riscv64 failure actually was
.PP
.CW RODATA
was added to
.CW tl
for the pre-decoded modules, but there is nothing thumb-specific about
it, and two other targets in this tree can be booted here:
.CW raspi3b
(aarch64,
.CW 7l )
and
.CW virt
(riscv64,
.CW jl ).
Both linkers already had the
.CW SSTRING
type, the placement loop and the
.CW datblk
case, and neither had
.CW tl 's
zero-fill bug \- that one was
.CW tl 's
alone.  So each needed the same four small changes:
.CW rodata
on
.CW Sym ,
.CW RODATA
read from
.CW GLOBL
in
.CW obj.c ,
the retype in
.CW pass.c ,
and the placement loop made unconditional.
.PP
With that,
.CW ROOTINTEXT
works on both.  Measured as
.CW "data + bss" :
.DS
.CW "            root in data   root in text     saved"
.CW "virt              976168         385312    590856"
.CW "raspi3b          5041896        4566456    475440"
.DE
.CW virt
reaches an interactive shell and prints
.CW VIRT-OK ,
.CW ROOT-APPS-OK
and
.CW ROOT-CMDS-OK ;
.CW raspi3b
reaches a shell and runs its own probes.
.PP
So the riscv64 failure this document recorded as not root-caused was not
the MMU.  It was the
.CW TEXT
symbol:
.CW data2s\ -t
used to emit the root as code, and a reference to a text symbol is not
an address to read bytes from on every target the way it is on ARM after
masking.  Emitting the same bytes as
.CW DATA
under a
.CW RODATA
.CW GLOBL ,
which is what the boards do now, boots on all five.
.PP
The string constants go too.  Both linkers had the same unrestricted
.CW -t
that
.CW tl
had \- any symbol with a
.CW D_SCONST
initialiser, which includes a writable
.CW "char x[] = \(fm...\(fm"
\- so all three are now restricted to
.CW .string
first.  Neither board's link rule used
.CW $LDFLAGS
at all, which is why adding
.CW -t
to the target's mkfile did nothing until the rule was fixed to pass it,
the way the thumb boards already do.  With both:
.DS
.CW "            root only   and strings     saved"
.CW "virt           385312        330984     54328"
.CW "raspi3b       4566456       4505656     60800"
.DE
.CW virt
still reaches an interactive shell with its three markers;
.CW raspi3b
still boots and runs its probes;
.CW mangopi ,
which uses
.CW 5l
and passes no
.CW -t ,
still links.
.PP
One thing cost an hour and is worth writing down.  Adding the flag
looked like it had no effect on
.CW virt :
the generated assembler had
.CW RODATA
on 63 symbols, the segment sizes did not move a byte, and a temporary
print in
.CW jl
showed every one of 2590
.CW GLOBL s
arriving with the same
.CW reg
value \- including symbols that were never marked.  The reason was not
in the linker at all.  The riscv object suffix is
.CW .j ,
and the stale
.CW virt.root.j
was being relinked because the rebuild had deleted
.CW virt.root.o ,
which does not exist.  The uniform
.CW reg
value was the tell: a flag that is being read would differ between
symbols that carry it and symbols that do not.
.NH 2
Can an instruction be its own destination?  Settled
.PP
.CW doc/pycubed-plan.ms
raised one thing to settle before any code runs from flash, and the
.CW Inst
arrays above shipped without settling it.
.CW libinterp/dec.c 's
.CW D02
sets
.DS
.CW "	R.d = (uchar*)&R.PC->d.imm;"
.CW "	R.m = R.d;"
.DE
\- the destination is the immediate inside the instruction \- and
.CW brpatch()
does not forbid that form for a non-branch opcode.  An opcode that
writes its result would write its own instruction.  With the array in
RAM that works and nobody notices.  With it in flash the write is
dropped or faults, and
.CW mps2
would not catch it either, because
.CW mps2 's
text is SRAM: the write would succeed there and fail only on the board
this is for.
.PP
So every Dis module in the tree was scanned: 552 of them, decoding each
instruction stream the way
.CW parsemod
does.  4886 instructions do have a non-branch immediate destination, and
they are all array indexing \-
.CW IINDB
2903,
.CW IINDX
1866,
.CW IINDL
105,
.CW IINDF
12.  Every one of the 4886 carries an
.CW AXINF
middle operand, so
.CW R.m
is a frame slot and never aliases
.CW R.d ,
and those opcodes read the immediate
.CW ( "i = W(d)" )
rather than writing it.  With no middle operand: zero, in 552 modules.
.PP
That is an empirical property of what
.CW limbo
emits, not a guarantee about what it could emit, so it is now a
build-time refusal:
.CW utils/dis2s
will not lay out a module containing a non-branch immediate destination
with no middle operand, and says why.  All nine modules
.CW mps2
and
.CW teensy41
carry pass it.
.NH 2
#pragma rodata, for the C tables that are never written
.PP
.CW -t
moves the compiler's string pool and
.CW RODATA
moves what assembler asks for it, but a C table has no way to ask.  The
largest single item in
.CW teensy41 's
data segment was one of those:
.DS
.CW "  40000  smallprimes   (libsec/smallprimetest.c)"
.CW "   8248  mntalloc      (bss)"
.CW "   4416  lpuartuart"
.CW "   4096  sbox          (libsec/blowfish.c)"
.CW "   3420  Keyringmodtab (generated)"
.CW "   2520  roottab"
.CW "   2484  Mathmodtab    (generated)"
.CW "   2048  spbox         (libsec/des.c)"
.DE
40000 bytes of prime table is 39% of that board's data segment, and it
is a table of constants.
.PP
So the compiler can be told:
.DS
.CW "#pragma rodata smallprimes"
.DE
.CW utils/cc
records it on the
.CW Sym
and
.CW utils/tc 's
.CW gpseudo()
puts
.CW RODATA
on the symbol's
.CW GLOBL ,
which the linker already knows what to do with.  It is an assertion by
the programmer and not something the compiler checks \- kencc does not
track
.CW const ,
and a write to one of these is dropped or faults rather than diagnosed
\- so it is for tables, not for anything a program assigns to.  A
compiler that does not know the pragma ignores it.
.PP
Four marked:
.CW smallprimes ,
.CW sbox ,
.CW spbox ,
and the
.CW Runtab
tables, which are generated, so
.CW limbo/stubs.c
emits the pragma with them.
.CW "data + bss" :
.DS
.CW "              before     after     saved"
.CW "mps2          132656     76400     56256"
.CW "teensy41      130568     74312     56256"
.CW "nucleof303     49112     47528      1584"
.DE
.CW nucleof303
gains only
.CW Sysmodtab ,
having no
.CW keyring ,
.CW crypt
or
.CW math .
.PP
And the check found a bug that had been there all along.  Dumping the
text segment after a workload and comparing it with the image \- the
same recipe as for the string literals \- came back with exactly one
byte different:
.DS
.CW "image: 40000000 0003b131 0003c445 ..."
.CW "run  : 40000001 0003b131 0003c445 ..."
.DE
the low byte of an immortal
.CW Type 's
reference count, on
.CW /osinit.dis 's
data-segment descriptor.  Something had incremented it.
.PP
The 23 sites routed through
.CW typeinc()
were found by grepping
.CW libinterp
for
.CW AINC(&t->ref) .
The one that was missed is in
.CW os/inferno/port/dis.c 's
.CW schedmod() ,
it is spelled
.CW t->ref++ ,
and it is not in
.CW libinterp
at all.  Two more like it turned up once the spelling was included:
.CW os/inferno/port/devsrv.c
and, in
.CW AINC
form,
.CW emu/port/dis.c
and
.CW emu/port/devsrv.c .
All four now call
.CW typeinc() .
.PP
.CW 7c
and
.CW jc
take the pragma too, since the same four tables are in every kernel that
links
.CW libsec .
.CW "data + bss" ,
on top of the root and string moves:
.DS
.CW "              before     after     saved"
.CW "virt          330984    258200     72784"
.CW "raspi3b      4505656   4436168     69488"
.DE
.CW virt
still reaches an interactive shell with its three markers and
.CW raspi3b
still boots.
.PP
Those two figures were first written down as 64048 and 60736, measured
before every affected library had actually been recompiled.  That is
worth a paragraph, because it wasted an hour and will do so again.
.CW mk
decides an archive is up to date by comparing the source against the
.I member
inside the
.CW .a ,
so deleting the object files and rebuilding does nothing: it prints
.CW "mk: 'install' is up to date"
and re-archives what it already has.  Deleting the
.CW .a
is not enough either, because then it re-archives the stale objects
beside it.  Both have to go, and for every target separately \-
.CW .t ,
.CW .7
and
.CW .j
live in the same source directory.  Every "no change" in this section
was that, twice.
.PP
This is the failure mode the bench cannot see.
.CW mps2 's
text is SRAM, so the increment succeeded and nothing went wrong; on
.CW teensy41 's
flash it would have been dropped, which is also harmless, but only by
luck \- the invariant was being violated either way and no test would
have said so.  What said so was comparing a megabyte of text against
the file it was built from.  It is now byte-identical over all 1054496
of it, including
.CW smallprimes ,
the nine instruction arrays and all 214 type descriptors.
.NH 2
Honouring const, under -r
.PP
The pragma names a table.  A great many tables already say the same
thing in C and are ignored: kencc parses
.CW const
and does nothing with it.
.CW libsec/aes.c
alone has ten \-
.CW Te0
through
.CW Te4 ,
.CW Td0
through
.CW Td4
and
.CW rcon ,
all
.CW "static const" .
.PP
So the front end can read it:
.CW utils/cc/dcl.c 's
.CW xdecl()
sets the same flag the pragma sets when the declared type is
const-qualified, which for
.CW "static const u32 Te0[256]"
means the array's element type, not the array.  No back-end change: the
line that emits
.CW RODATA
was already there.  On
.CW mps2
and
.CW teensy41
that is another 14056 bytes of
.CW "data + bss" ,
and on
.CW nucleof303 ,
which links less of libsec, 264.
.PP
Under
.CW -r
and not by default, because it is not safe everywhere.  With it on for
every target,
.CW libmath
and
.CW libkern
stop compiling for aarch64 and riscv64:
.DS
.CW "tanh: imm out of range"
.CW "(956)	MOVD	tiny<>+0(SB),F4"
.CW "dtoa: offset out of range: 192078"
.CW "(2274)	FMOVD	bigtens<>+32(SB),F2"
.DE
Those targets reach a static with an offset from a base register whose
range does not extend to the text segment, and a file-scope
.CW const
double is exactly what that addressing mode is for.  Thumb addresses
data absolutely and does not care, so
.CW mkfiles/mkfile-os-thumb
passes
.CW -r
and the others do not.  The pragma has no such trouble only because it
is applied to four named tables that were checked to link.
.PP
One bug of mine is worth recording.  The pragma commit added a field to
.CW Sym
and
.CW utils/cc/lex.c 's
.CW syminit()
clears every field of a new one by hand \- it does not
.CW memset
\- so the new field was whatever
.CW mysbrk
last left there.  Symbols were being moved to read-only memory at
random.  It presented as the aarch64 and riscv64 failures above
appearing and disappearing between builds, which is what sent me looking
for a target-specific cause when the cause was an uninitialised byte.
The thumb figures did not change once it was fixed, so they were not an
artifact, but they could have been.
.NH 2
A file system in flash, which is what this was for
.PP
The built-in root answers
.CW Dev.xip ,
but it is compiled into the kernel: changing a file means relinking.
The thing the branch was asked for is a file system that is not part of
the image \- written into a board's spare flash, served where it lies,
with a Dis module in it executed in place.
.PP
.CW os/inferno/port/devflash.c
is that, as
.CW #G
.CW ( F
and
.CW f
are taken).  A board sets
.CW flashbase
and
.CW flashlen
before
.CW chandevreset() ,
zero meaning it has none, so a kernel can carry the driver and a board
need not have the memory.  The format is what
.CW utils/mkflashfs
writes:
.DS
.CW "  0   8   \(fmflashfs\(fm"
.CW "  8   4   version"
.CW " 12   4   nfile"
.CW " 16   4   total length"
.CW " 24  nfile*64  the directory"
.CW " ...  the file data, each 4-aligned"
.DE
One flat directory, every file's bytes contiguous and word-aligned,
which is the whole of what execute-in-place demands.  Anything wanting a
tree mounts several.
.PP
The header is checked once at attach, not per access: every entry has to
lie inside the image, so nothing below bounds-checks again and a region
that is not one of these is refused rather than served as an empty
directory.  Confirmed by pointing
.CW flashbase
four bytes into the image, which gives
.DS
.CW "ls: #G: bad flash file system magic"
.DE
.PP
.CW mps2
has no flash, so its image is a
.CW RODATA
blob linked into the text segment \- which is what a memory-mapped NOR
window is as far as the device can tell, and it means the code is
exercised on the only board that can be run.  Two modules,
.CW echo.dis
and
.CW cat.dis .
It works:
.DS
.CW "; ls -l \(fm#G\(fm"
.CW "--r--r--r-- G 0 inferno inferno 707 ... #G/cat.dis"
.CW "--r--r--r-- G 0 inferno inferno 433 ... #G/echo.dis"
.CW "; bind -b \(fm#G\(fm /dis"
.CW "; echo hello-from-flash"
.CW "hello-from-flash"
.DE
and with a temporary print in
.CW readmod ,
that
.I echo
reports
.DS
.CW "XIPREAD /dis/echo.dis at 83b20 len 433"
.DE
against a
.CW flashfscode
of
.CW 0x83a88 :
offset 152, which is the 24-byte header plus two 64-byte entries
exactly.  The module was not copied.  It was run out of the image.
.PP
The kernel grows 2880 bytes of text and 104 of data for the driver and
the two modules; a board with real flash pays neither.
.NH 2
Where this stands
.PP
Everything below is measured, on
.CW mps2
because it is the board that can be run, with a shell and an
.I ls (1)
loaded.  The first column is where this document began; the second is
the tree as it is now.
.DS
.CW "                        was        is    saved"
.CW "kernel data + bss    162904     62344   100560"
.CW "Proc array           175360     38720   136640"
.CW "main pool            367104    113472   253632"
.CW "heap pool             73728     56832    16896"
.CW "                     ------    ------   ------"
.CW "                     779096    271368   507728"
.DE
.CW "kernel text"
went 848200 to 1068552 over the same span, which is the price: 220352
bytes of flash bought 507728 of RAM.  On
.CW mps2 ,
whose text is SRAM, that is not a win at all \- it is the bench, not
the target.  On
.CW teensy41 ,
with eight megabytes of flash and a few hundred kilobytes of SRAM, it
is the whole point: 761016 of text against 60256 of data and bss and a
38720-byte
.CW Proc
array.
.PP
The pool figures are
.CW mps2 's
device set, which is the one the other two boards are configured
against, so they carry over; the text and data figures are each board's
own.
.CW nucleof303
is 282224 of text against 47264 of data and bss, which fits both its
512K of flash and its 64K of SRAM, with a 19360-byte
.CW Proc
array on top \- and a pool floor that still leaves no room for Limbo,
which its NOTE says.
.NH 2
What is in the Dis heap, and what stops the next step
.PP
The remaining item on this document's own list was the load-time Dis
constants to flash behind an immortal-object convention, estimated at
35200 of the heap.  The estimate does not survive measurement.
.PP
Heap allocations were not attributable, because
.CW nheap()
and its siblings call
.CW poolalloc(heapmem, ...)
without a
.CW setmalloctag ,
so every one of them reported an allocating pc of zero.  Tagging them
temporarily and reading
.CW #c/poolhist
after a shell and an
.I ls (1),
of 56896 bytes live in 357 blocks:
.DS
.CW "  20416  newstring"
.CW "  17728  newaz"
.CW "   3264  linkmod    (module data, per instance)"
.CW "   3008  parsemod   (origmp, the master copy)"
.CW "   3008  arraycpy"
.CW "   2496  mklinkmod  (Modlink)"
.CW "   2368  cons"
.DE
So the heap is Dis strings and arrays, and the module data segments \-
the thing the estimate was about \- are 3008 bytes of master copies and
3264 of instances.  Every module the nine carry declares a data segment
between 24 and 2360 bytes; 3368 for all nine together.  There is no
35200 of load-time constants to move.
.PP
What is left is 38144 of strings and arrays that the shell makes while
it runs, and a fraction of that which module loading makes and never
writes.  Separating the two needs the caller of
.CW newstring ,
not
.CW newstring
itself, so it is not measured here.
.PP
And there is an obstacle worth naming before anyone tries, because it is
not the one the reference count was.  A
.CW Type
went to flash once its count was handled, because the count was the only
field written.  A
.CW Heap
is different:
.DS
.CW "	int	color;"
.DE
the garbage collector writes it on every mark.  An immortal heap object
in flash would have to be one the collector never touches at all \-
recognised and skipped, not coloured \- which is a change to the
collector rather than a convention on a field.  That is why this item is
separate from the
.CW Type
one and why it is not attempted here on the strength of an estimate that
measurement does not support.
.PP
One more thing found while looking:
.CW reallocpc
in
.CW Bhdr
.CW ( include/pool.h )
is written by
.CW setrealloctag
and read only by
.CW getrealloctag ,
which nothing in this tree calls.  It is four bytes in every block
header, and dropping it would take
.CW BHDRSIZE
from 20 to 16 and let about one request in sixteen fall into a smaller
quantum \- roughly 4800 bytes on
.CW mps2 .
It is not done, because
.CW include/pool.h
is shared with
.CW os/osprey
and
.CW os/9front ,
and neither can be booted from here to check it.
.NH 2
What gates any of it
.PP
The kernel pool floor: 78208 bytes in 343 allocations with the minimal
configuration and a 512-byte init, of which 16384 is four kernel stacks
and the other 62K has never been looked at.  It is larger than the code
bucket this whole document is about.  Every number above is arithmetic
on top of it, so it is the next thing to measure rather than the next
thing to optimise.
.NH 1
A candidate board: Olimex ESP32-P4-PC
.PP
Raised as a target, so assessed rather than started.  An Espressif
ESP32-P4NRW32: dual-core 32-bit RISC-V at 400MHz, 768K of on-chip SRAM,
32M of in-package PSRAM, 16M of external SPI flash, with Ethernet
10/100 MAC and PHY, USB, MIPI CSI and DSI, HDMI, microSD and audio, and
no Wi-Fi or Bluetooth on the part.
.NH 2
What it does to the premise
.PP
It ends the capacity argument.  This document's measured figures are
about 890K of RAM as the tree stands and roughly 580K after the cheap
cuts, against 768K of on-chip SRAM: so the trimmed configuration fits in
SRAM and the untrimmed one does not, and 32M of PSRAM makes either of
them trivially comfortable.  Nothing above about fitting in 256K applies
to this board.
.PP
What execute in place becomes here is a locality argument instead.  The
ESP32 parts map external SPI flash into the address space through a
cache, which is exactly the directly-addressable window
.CW Dev.xip
was written for, and the mutable working set this document measures is
small \- 8400 bytes of module data segments and stacks for a shell's
three modules.  Code behind the flash instruction cache and that working
set in fast on-chip SRAM, with PSRAM not holding code it need not hold,
is a better use of the hierarchy than decoding everything into PSRAM.
That is reasoning from the memory hierarchy; the SRAM-against-PSRAM
latency difference has not been measured here.
.PP
The architecture is the best fit in the tree.
.CW os/inferno/virt32
is a working RV32 port \- an interactive shell under
.CW qemu-system-riscv32 ,
per
.CW doc/inferno-ports.ms
\- on the zc/za/zl toolchain, with
.CW os/inferno/riscv
as the shared family directory beside it.
.CW DISWORD
is 4, so the 1.76 decoded-to-packed ratio measured above is the relevant
one and the
.CW dis32
tree is the right one.
.NH 2
Two walls, both verified here
.PP
.B "No double precision."
The HP cores are RV32IMAFC: single-precision FPU, no D extension.  And
.CW zc
emits D instructions \- checked directly, compiling
.CW "double add(double a, double b) { return a*b + a/b; }"
with
.CW "zc -S"
gives
.CW MOVD ,
.CW MULD ,
.CW DIVD ,
.CW ADDD .
The gradation matters more than the headline: an unexecuted illegal
instruction does not fault, so a console shell would plausibly boot,
.CW libinterp 's
real arithmetic and libmath would fault when called, and
.CW canontod()
in
.CW libinterp/load.c
would break at load on any module carrying a real constant, because even
moving a double is a D-extension load.
.PP
Two routes.  Trap and emulate, on the software floating point already in
.CW os/inferno/port/fpi.c
and
.CW fpimem.c ,
modelled on
.CW os/inferno/pc/fpi387.c ,
which is their only consumer in this tree \- there is no
.CW fpiarm.c
here despite
.CW os/inferno/nucleof303/NOTE
referring to one.  Or a soft-double mode in
.CW zc ,
emitting calls where it now emits D.
.CW AGENTS.md 's
"fix the tool, not the caller" favours the compiler, and the choice
turns on whether real arithmetic has to be fast.
.PP
.B "No emulator."
Espressif's QEMU fork models ESP32, ESP32-S3, ESP32-C3 and ESP32-C6, not
the P4.  So this would be bring-up against real hardware with no test
bench, which is the
.CW os/inferno/teensy41
situation and the reason that board has never been run.  Writing it
blind would produce another directory of unverified code, so it wants
the board in hand first.
.NH 2
What the work would be
.PP
Not the peripherals.  The gating work is the boot path: the ESP32 boot
ROM hand-off, the image format its second stage expects, and setting up
the flash cache and its MMU so that text executes from flash at all \-
which is also what makes
.CW Dev.xip
over a flash window meaningful on this part rather than decorative.
Then the interrupt controller and a timer.  The interrupt path is worth
naming as an unknown: these parts use an Espressif interrupt matrix
rather than a standard RISC-V PLIC and CLINT, which is recollection here
and not something checked against the technical reference manual.
.PP
The asset is that none of the processor work is new:
.CW virt32
already boots RV32 Inferno to a shell through zc/za/zl, and
.CW os/inferno/riscv
already holds the shared RISC-V code a second board would read.
.NH 1
Nanosatellites, and whether any of this is for them
.PP
Raised as a domain: the CubeSat and femtosatellite work out of Zac
Manchester's group.  There are two very different targets in it and the
answers are not the same.
.PP
The
.B Sprite
femtosatellites from KickSat are a single small board with an MSP430
class part, memory in the tens of kilobytes.  That is orders of
magnitude below anything in this document; the minimal kernel measured
above is 156604 bytes and the interpreter alone does not fit.  Not a
candidate, and no amount of the work listed here changes that.
.PP
.B PyCubed
is the interesting one \- the open-source CubeSat flight computer
Manchester co-authored with Holliday and others, flown on KickSat-2 and
used since on V-R3X and after.  It is an ATSAMD51: a Cortex-M4F, up to
1M of flash and up to 256K of SRAM, both with ECC, programmed entirely
in CircuitPython.
.NH 2
It lands exactly on the boundary this document measured
.PP
The 256K budget above was not chosen with this board in mind and comes
out at 156604 bytes for a minimal kernel plus a purpose-built Dis
program.  On a 256K variant that fits with about 100K spare; on a 192K
one it leaves about 35K.  So the conclusion is the same as before and
now it is about a real board: a kernel and one purpose-built module,
never the shell, which costs 260992 by itself.
.NH 2
What actually blocks it is the floating point
.PP
The Cortex-M4 has FPv4-SP and no double precision, and
.CW utils/tl/thumb.c
gives every
.CW F
register a
.CW D
register, so
.CW "tl -M -F"
names every function that would fault \- the Dis interpreter's real
arithmetic and all of libmath.  That is the same wall
.CW os/inferno/nucleof303/NOTE
records, and the same class as the one verified above for RV32 on the
ESP32-P4.
.PP
On a microcontroller doing serial console work it is a footnote.  On a
satellite flight computer it is the whole thing: attitude
determination, orbit propagation and the convex and trajectory
optimisation that is this group's actual research are floating point
from end to end.  So for this domain software double precision is not
an item on a list, it is the first item, and nothing else is worth
doing before it.
.NH 2
Where execute in place earns its place here, and where it does not
.PP
Not capacity.  The honest argument in this domain is immutability: the
decoded
.CW Inst
array is a large, long-lived, execution-critical structure sitting in
writable memory \- 106284 bytes for three modules \- and in flash it can
be checksummed, cannot be scribbled by a wild pointer or a stack that
ran past its extent, and does not consume the SRAM budget at all.  The
pure single-event-upset form of that argument is weaker than it first
looks, because this part has ECC on both its SRAM and its flash; what
survives is that the decoded form is 1.76 times the packed one, so a
system that decodes into RAM spends 1.76 times the exposed, writable
footprint for the same program.
.PP
The stronger case for Inferno on a constellation is not this branch at
all.  It is Styx: per-node namespaces and one file interface over an
unreliable crosslink is what the system was designed for, and a
formation of satellites talking to each other is the case it was
designed for.  A CircuitPython board gives you a language runtime and
no distributed story.  That is the argument worth making, and execute in
place is only what makes the interpreter small enough to be in the
conversation.
.NH 2
What is true today
.PP
CircuitPython on PyCubed has flight heritage and published radiation
test results.  Inferno on a Cortex-M has never run on real silicon in
this tree:
.CW os/inferno/teensy41
is written and unverified for want of a board or an emulator, and
.CW os/inferno/nucleof303
does not fit.  So this is a research direction and not a substitution,
and the ordering is: software double precision, then the cheap cuts and
the read-only move, then a board that has actually been booted.
.NH 1
PyCubed in Limbo: what it would take
.PP
Read the sources rather than the paper:
.CW github.com/pycubed/firmware
for the board definition and
.CW github.com/pycubed/software
for the flight code, mainboard-v05.
.NH 2
The hardware, from its own board file
.PP
.CW pycubedv05_build/mpconfigboard.mk
names the part:
.CW SAMD51J19A .
A Cortex-M4F at 120MHz with 512K of internal flash and 192K of SRAM,
and
.CW mpconfigboard.h
adds 8192 bytes of internal NVM, a W25Q80DV \- one megabyte of external
QSPI NOR \- carrying the filesystem, a crystal, I2C on PB13/PB12, SPI on
PA13/PA12/PA14, UART on PB02/PB03, and the board's own lines: SD_CS,
RELAY_A, BURN1, BURN2, EN_RF, BATTERY and L1PROG on the ADC, VBUS_RST,
NEOPIXEL.  On the buses hang an RFM9x LoRa radio, a BMX160 IMU, a
bq25883 charger, an adm1176 power monitor, a GPS on the UART and an SD
card.
.PP
The part that matters for this document: the SAMD51's QSPI supports
execute in place, mapping that external NOR into the address space.
That is the best hardware match for
.CW Dev.xip
of anything assessed here, and the architecture falls straight out of
it \- kernel text in the 512K of internal flash, against the 245192 this
tree's nearest Cortex-M4 kernel
.CW ( os/inferno/nucleof303 ,
its own configuration) actually measures; the pre-decoded Dis modules
and the root in the megabyte of QSPI window; and the 192K of SRAM for
data, bss, pools and the mutable module state.  Nothing about that is
contrived.  It is what the part is built for.
.NH 2
The budget, which is tighter than the 256K section
.PP
156604 against 192K: about 35K left for the flight software's own data.
That already includes the string-literal move, which is built.  That is real
but it is not comfortable, and the risk is named elsewhere in this
document \- the 78208 pool floor was measured on
.CW mps2 's
device set, and this board wants SPI, I2C, ADC, SD and QSPI on top of
it.  The 62K of that floor nobody has looked inside is, for this board
specifically, the difference between fitting and not.  It stops being a
general loose end and becomes the gating measurement.
.NH 2
What porting the software actually involves
.PP
The flight code is about 3200 lines of Python, and it divides in a way
that favours the port more than a line count suggests.
.IP \(bu
.B "The scheduler disappears."
.CW lib/tasko
is some five hundred lines of cooperative event loop, managed resources
and a managed SPI wrapper, and it exists because CircuitPython is
single-threaded.  Inferno has processes and channels.  That code is
deleted, not ported.
.IP \(bu
.B "The drivers stay in C."
An earlier version of this section said the opposite \- that RFM9x,
BMX160, bq25883 and adm1176, about 2090 lines of register poking over
SPI and I2C, should become Limbo programs over the bus device files,
keeping the memory safety CircuitPython gives them.  That was wrong on
this board, and wrong about what this tree does.  Three reasons, in
increasing order of how much they settle it.
.IP
First, it is not the convention.  Every register-level driver in this
tree is C in the kernel with a device-table entry, and the Limbo drivers
that do exist sit on top of one:
.CW appl/cmd/usb/usbd.b
enumerates over
.CW os/inferno/port/devusb.c ,
and
.CW appl/cmd/usb/etherusb.b
runs a NIC over the same C driver.  Nothing in
.CW appl
pokes an I2C or SPI register.  The split Inferno actually draws is
controller in C, protocol and policy in Limbo.
.IP
Second, interrupts.  The RFM9x's DIO0 is an interrupt line and the
radio wants interrupt-driven receive.  Only the kernel can take an
interrupt; a Limbo process can wait on a device file but cannot be the
handler.  So at least the interrupt half has to be C whatever else
happens.
.IP
Third, and this is the one that decides it: on this board a Limbo driver
is
.I RAM
and a C driver is
.I flash .
A driver in C is text, and text lives in the 512K of internal flash
whose kernel occupant measures 245192 \- there is room, and the RAM cost
is only its own data.  For scale, the whole of
.CW mps2 's
UART driver is 5704 bytes of text.  A driver in Limbo is a Dis module,
and its decoded
.CW Inst
array is in SRAM.  Measured across four Limbo programs in this tree
.CW ( usbd.b ,
.CW etherusb.b ,
.CW dhcp.b ,
.CW styx.b )
a Limbo source line costs 12 to 17 bytes of packed
.CW .dis ,
about 14 on average; at 1.76 for the decode, 2090 lines is some 29K of
.CW .dis
and 51K of
.CW Inst
in RAM \- and that assumes Limbo matches Python line for line, which for
a statically typed language it will not.  Against the roughly 35K of
headroom this board has, moving the drivers into Limbo does not fit, and
leaving them in C costs the scarcest memory nothing.
.IP
Which also makes the port more attractive rather than less: C drivers
are text in flash, which is exactly what the execute-in-place
arrangement above already handles.  What belongs in Limbo is the half of
.CW lib/pycubed.py
that is policy rather than registers \- the state machine, the beacon
schedule, telemetry formatting, logging \- plus whatever mission code
sits on it.  That is the part that gains from a safe language and from
being restartable without taking the radio down with it.
.IP \(bu
.B "The board layer is the real work."
.CW lib/pycubed.py
is 447 lines of Python standing on CircuitPython's
.CW digitalio ,
.CW analogio ,
.CW busio ,
.CW sdcardio ,
.CW pwmio ,
.CW storage
and
.CW microcontroller.nvm .
Each of those is a kernel driver that has to exist first.
.PP
The kernel side is less than it sounds, because the core is done:
.CW os/inferno/armv7m
already has the vectors, exception path, spl, SysTick and the exclusive
monitor, and
.CW os/inferno/nucleof303
is already a Cortex-M4 board beside it.  What is genuinely new is the
SAMD51 itself \- its clock tree, the SERCOM instances that become the
UART, SPI and I2C, the QSPI controller and its XIP window, the ADC, the
timers behind PWM, the watchdog and the internal NVM.  Models for every
one of those exist in the tree
.CW ( uartstm32.c ,
.CW i2cbcm.c ,
.CW spibcm.c ,
.CW gpiobcm.c ,
.CW pwmbcm.c ,
.CW pmbcm.c ,
and
.CW devsd.c
with
.CW sdmmc.c
and
.CW pmmc.c
for the card), and
.CW os/inferno/riscv/spisifive.c
already knows a memory-mapped flash XIP path exists and deliberately
declines it, which is the nearest thing to precedent for wiring one up.
.NH 2
The precondition
.PP
Software double precision, and here it is not an ordering preference but
the thing the port stands on.  On a console board the FPv4-SP gap is a
footnote because a shell is integer and string work.  This board's
software is floating point throughout \- battery voltages, charge
current, IMU rates, attitude \- so there is no useful subset of PyCubed
that avoids it.
.PP
And the emulator cannot help with precisely this.  The ARMv7-M core is
proven under QEMU through
.CW os/inferno/mps2 ,
but that is a Cortex-M7, which has double precision; the Cortex-M4F
difference from it is the FPU.  So the one thing that blocks this board
is the one thing the emulated board cannot test.  That, and not the
driver count, is why nothing is started here.
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
