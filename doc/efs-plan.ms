.TL
A filesystem for the card the board boots from
.AU
.PP
This is a plan for
.I efs ,
an embedded filesystem for the Raspberry Pi 3B's SD card, to replace
.I kfs
as the thing the board keeps its own files in.  It says what the card
actually is, what the format should be, what order to build it in, and
which checks make each step believable.  Nothing in it is implemented
yet; where it states a fact about the hardware or about the existing
code, that fact was measured or read in this tree and is marked as such.
.NH 1
Why replace kfs
.PP
.I Kfs
works.  It reams a partition and serves it, and on this board it does
that at every boot \(em
.CW SD-FS-CREATE-OK
is a real marker from real silicon.  The argument for replacing it is
not that it is broken but that it is the wrong shape for this machine.
.IP 1.
.B "It is a 1990s design for a disk that stays powered."
.CW appl/cmd/disk/kfs.b
is 3852 lines of Limbo (kfs64.b another 4212) carrying a cache/worm
split this board does not have, a user table it invents at ream time,
and a check pass that walks the whole filesystem.  Its recovery story
is that check pass.
.IP 2.
.B "This board loses power constantly, and not politely."
Its way out of
.CW exit()
is the PM watchdog.  During this port's bring-up the power was pulled
or the watchdog fired dozens of times a day, several times in the
middle of a write to the card.  A filesystem here is judged on what it
does after that, not on throughput.
.IP 3.
.B "The failure that matters is the quiet one."
Both times this board went dark after a reboot, its card still mounted
and still listed.  A
.I kernel8.img
with the whole cluster chain and a length of zero reads as a file; the
firmware simply loads nothing.  What is wanted is a format in which an
interrupted write cannot produce a tree that mounts and lies \(em where
the last committed state is the only state there is.
.IP 4.
.B "Reaming at boot is not a filesystem."
.CW raspi3binit.b
starts
.CW "kfs -r"
on a scratch partition every boot, which is a test, not storage.  The
board has never had a filesystem of its own that survived a reboot.
.NH 1
What the card actually is
.PP
Measured on the board, not assumed.
.IP \(bu
30228480 sectors of 512 bytes, and the last sector reads while the one
past it does not \(em
.CW SD-CAP-OK ,
so the claimed capacity is the real one.
.IP \(bu
The firmware's FAT32 partition starts at sector 16384 and runs 1048576
sectors (512MB), ending at 1064960.  Everything above that, some 29GB,
is unallocated.  The gap below it \(em sectors 2048 to 16383 \(em is
where
.I kfs
is reamed today, and is only 7MB.
.IP \(bu
The controller is the Arasan SDHCI, polled, no DMA.  Multi-block reads
and writes work and are checked at every boot against the same block
read alone
.CW ( SD-MULTI-OK ).
Writes are verified by a ctl command that restores the sector it wrote.
.IP \(bu
.CW devsd 's
.CW part
ctl command names a region of the device and needs no partition table
entry, so
.I efs
can be given sectors 1064960 to 30228479 without touching the MBR the
firmware reads.  That is the partition to use: the 7MB gap is too small
to be a root and too close to the firmware's own data to be worth the
risk.
.IP \(bu
.CW devsd
stages unaligned reads and writes (it divides by
.CW unit->secsize
and reads the partial sector), so byte-offset I/O works.  It is still
whole blocks that make transfers cheap on a polled controller, and the
format should never issue anything smaller than a block.
.NH 1
Shape: a Limbo Styx server, not a kernel device
.PP
.I Efs
is a Limbo program serving Styx on its standard input, started the way
.I kfs
and
.I dossrv
are started, and shipped in the kernel's root beside them.  It is not a
kernel device, at least not first, and the reason is testing rather
than taste.
.PP
Every bug found in
.I dossrv
during this port was found by running the same
.CW .dis
under
.I emu
on the build host, against an image in a file, with
.I fsck_msdos
as an outside opinion.  The one bug the host could not reproduce \(em a
length read out of a sector buffer that had since been handed to
another sector \(em was the one that emptied the board's kernel on
every update and left it dark twice.  It became reproducible in seconds
the moment the host image was given the shape of the real card.  A
server that runs as the same binary on the host and on the board is
worth more than one that is slightly faster on the board.
.PP
The device is a file:
.CW "efs -f /dev/sdM0/efs -m /n/efs"
on the board,
.CW "efs -f /tmp/efs.img -m /n/efs"
on the host, exactly as
.I dossrv
takes
.CW -f
and
.CW -m .
.NH 1
On-disk format
.PP
Copy on write, and no in-place mutation of metadata.  The design to
read first is
.I gefs
on 9front; take its ideas and not its format, because matching a format
means matching its bugs as well as its virtues.
.IP \(bu
.B Blocks
of 4KB (eight sectors), the unit of allocation and of every transfer.
Nothing smaller ever goes to the card.
.IP \(bu
.B "Two superblocks"
at fixed offsets, each carrying a generation number, the root of the
metadata tree, the free-space root, and a checksum over itself.  Mount
reads both and takes the newer one that checksums.  That is the whole
of recovery.
.IP \(bu
.B "A copy-on-write B-tree"
for metadata, keyed by (inode number, offset), holding inode records and
directory entries and block pointers.  Nothing in the tree is ever
overwritten: a change writes new blocks up the spine and ends in a new
root.
.IP \(bu
.B "A commit"
is: write the data and metadata blocks, barrier, write the superblock
with the new root and the next generation.  Until that last write, the
old tree is the filesystem.  After it, the new one is.  There is no
third state.
.IP \(bu
.B "Free space"
as a copy-on-write bitmap or an allocation log replayed at mount; either
way it is part of the committed state, not a thing rebuilt by a check
pass.  Blocks freed by a commit are not reusable until the commit after
it, or a crash mid-commit can scribble on the tree it is meant to be
able to fall back to.
.PP
Two rules go into the format document because both were real bugs in
this tree, and a format that does not forbid them will grow them again.
.IP 1.
.B "A record read from a block is copied out of it."
.CW Dosdir.arr2Dd
in
.I dossrv
builds a structure whose fields are
.I slices
of the sector buffer, and a Limbo slice shares the array it came from.
A directory entry was therefore a window on a buffer, valid only while
that buffer held that sector, and a length carried across a
.CW putsect
was four bytes of whatever sector next took the buffer.  In
.I efs
a block buffer is parsed into a value and the value owns its bytes.
.IP 2.
.B "A block number is one width everywhere."
FAT32 keeps the top half of a start cluster in a different field from
the bottom half, and this tree has now fixed that truncation three
times, in
.I rename ,
in
.I mkdentry
and in
.I mkdir .
.I Efs
has one block number type, 64 bits, read and written by one pair of
functions, and no code anywhere is allowed to assemble one from halves.
.NH 1
Interfaces
.IP \(bu
.B Qids:
inode number in the path, plus a generation counter so a removed file's
number cannot come back silently as the same qid.  The qid does not
change across a rename \(em a rename is a key change in the tree, not
the rewrite of an entry.
.IP \(bu
.B "Names and permissions:"
uid and gid as strings in the inode, mode and times as ordinary fields.
No separate user table to lose, which is one of the things
.I kfs
invents at ream time.
.IP \(bu
.B Mkfs
is a separate program and runs once.  There is no ream flag on the
server and no filesystem created as a side effect of mounting one.  A
board that boots and finds no filesystem says so.
.IP \(bu
.B "A dump program"
that walks the on-disk structures and prints them, and an
.B fsck
that walks the tree and the free map and disagrees loudly.  Both run on
the host against an image file.
.NH 1
Milestones
.PP
Each one ends in something that can be run, and nothing is called done
on a claim.
.IP "1." 5
.B "The format, written down."
One page: block layout, superblock fields, key encoding, the commit
rule, and the two rules above.  Before any code, because a format
settled in code is a format nobody can review.
.IP "2." 5
.B "mkfs and dump on the host."
Make an image, print it back.  The check is that dump's output matches
what mkfs was told to write.
.IP "3." 5
.B "A read-only server."
Attach, walk, open, read, stat, and directory listing.  Tested under
.I emu
against an image mkfs made, with dump as the second opinion.
.IP "4." 5
.B "Writes."
Create, write, truncate, remove and rename.
.B "Rename lands here, not last:"
it is where
.I dossrv
failed, and it is what
.I kupdate
does to the kernel on every update.
.IP "5." 5
.B "Commit and recovery."
The superblock flip, and a crash harness: a device wrapper that fails
every write after the Nth, driven across N so that every write in a
workload is a crash point.  After each, the image must mount and hold
exactly the last committed state, and fsck must be silent.
.B "This is the milestone that justifies the project."
Without it
.I efs
is no better than
.I kfs
and should not replace it.
.IP "6." 5
.B "A stress program and a harness,"
in the shape of
.I fatstress (1)
and
.CW tests/dossrv-stress.sh :
write, read back, rename, rename onto an existing name, remove,
directories, and a file held open across a rename.  Several images, and
one of them shaped like the real thing.
.IP "7." 5
.B "On the board."
Partition sectors 1064960 upward, mount at boot, markers
.CW EFS-OK ,
.CW EFS-WRITE-OK ,
.CW EFS-RENAME-OK
and
.CW EFS-CRASH-OK
so
.CW tools/boardsuite
baselines cover it.  Then serve it as the root with the kernel's own
root as the fallback.  Only then does the
.I kfs
ream leave
.CW raspi3binit.b ,
and
.I kfs
stays in the tree as something to compare against.
.NH 1
How the checks are kept honest
.PP
Three rules, each of which this port learned by breaking them.
.IP \(bu
.B "An empty image proves nothing."
Every filesystem the FAT stress test had \(em FAT16, FAT32 with files
above cluster 65535, FAT32 with 4KB clusters \(em passed against a
server that corrupted the board's card on every boot.  What it took was
an image shaped like the real partition: sixty long-named files and a
hundred megabytes in them.  The
.I efs
harness gets a case shaped like the card from the first day, and the
shape is written down as part of the test, not left to whatever the
host happened to have.
.IP \(bu
.B "Every check is falsified once."
A check is only a check if it has been seen to fail.  Reintroduce the
bug it was written for, watch it fail, put the fix back.  The busy-image
case above was confirmed this way against the old server; the directory
case must be too.
.IP \(bu
.B "An outside opinion where one exists."
.I Fsck_msdos
found things in the card that reading the files back through
.I dossrv
never would.
.I Efs
has no outside fsck, so its own fsck is written by the milestone before
the writes land, and the crash harness is the outside opinion: it knows
nothing about the tree except that mounting must give back the last
commit.
.NH 1
What this is not
.IP \(bu
.B "Not a FAT variant."
The firmware's partition stays FAT and
.I dossrv
stays the tool for it.  The firmware reads that partition and nothing
this tree writes can change what it expects.
.IP \(bu
.B "Not a kernel device."
Not first, and not until the server has been in use long enough to be
boring.  A kernel filesystem cannot be run under
.I emu
against an image file, and that is the property that found every bug so
far.
.IP \(bu
.B "Not a format with a ream at boot,"
and not one that needs a check pass to be trusted.  If recovery is not
the superblock flip, the design is wrong.
.NH 1
Open questions
.IP \(bu
Block size.  4KB is eight sectors and a comfortable B-tree node; 8KB
halves the tree depth and doubles the write amplification of a small
change.  Decide by measuring on the board, with the polled controller,
not on the host.
.IP \(bu
Whether the free map is a bitmap or a log.  A 29GB partition of 4KB
blocks is about 7.6M blocks, so a bitmap is about a megabyte \(em small
enough to hold, large enough that writing it on every commit is
wasteful.  A log with periodic checkpoints is the likely answer and the
more complicated one.
.IP \(bu
Whether data is copy-on-write as well as metadata.  It is simpler if it
is, and it costs a full block write for a one-byte change.
.IP \(bu
Checksums on every block, or only on the superblock.  The SD card has
its own ECC and this board has no memory errors anyone has seen, but a
checksum is what turns "the tree is wrong" into "this block is wrong",
and that is the difference between debugging and guessing.
.IP \(bu
Whether
.I efs
should be able to serve the 7MB gap as well, for a small filesystem that
exists before the big partition is set up.  Probably yes, and it costs
nothing if the format does not assume a minimum size.
