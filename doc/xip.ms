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
Measured across the 47 files the
.CW raspi3b
configuration bundles, by reading
.CW isize
out of each Dis header and multiplying:
.DS
.CW "decoded Inst arrays   1448568 bytes"
.CW "packed .dis files      475093 bytes"
.CW "ratio                    3.05"
.DE
The largest single module is
.CW /dis/disk/kfs64.dis :
65595 bytes on disk, 8820 instructions, 211680 bytes of
.CW Inst .
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
That is where a loaded module's memory actually is: 3.05 times the packed
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
RAM here.  Pre-decoding would cost image bytes for all 47 bundled modules
whether or not they are ever loaded, while saving heap only for the ones
that are \- and a boot to a shell loads ten.  It is a net loss on this
board, and the 3.05 ratio is what makes it one rather than a wash.
.PP
That is a finding, not a gap.  The work pays where the image is not RAM:
a board whose filesystem lives in memory-mapped ROM or NOR flash, where
the pre-decoded structures sit in flash and never occupy RAM at all.
There the same change removes the whole 3.05x from the heap and costs
nothing that was RAM to begin with.  The
.CW xip
method added here is the interface it would be built on, and
.CW Flash.xip
in
.CW os/inferno/port/flashif.h
\- already meaning "executing in place from this part, do not put it in
query mode" \- is the vocabulary the device side would use.
.NH 1
What is left
.IP 1.
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
.IP 2.
Pre-decoded modules in that window, per the section above \- gated on
item 1, and worth it only there.
.IP 3.
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
