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
Measured against kfs, at last
.PP
The section above argues for replacing kfs on shape and says plainly that
"a filesystem here is judged on what it does after that, not on
throughput."  That was the right argument and it left throughput
unanswered, because the only medium on this desk charges about 38.8ms for
one durable metadata update and buries both filesystems underneath itself.
.PP
.CW sdmem (3)
removes the medium \(em a block device in RAM, with the I/O counted by the
driver rather than by either filesystem, so neither is trusted to report
its own numbers.
.CW tests/fsbench
is the run: 300 creates into one directory, six rounds of fifty, each
filesystem reamed fresh on the same device in the same boot.
.P1
                        efs        kfs
total                 38.32 s    33.48 s
first fifty, each     128.7 ms    93.6 ms
last fifty, each      123.0 ms   137.2 ms
growth over 300        0.96x      1.47x
read ops               3084      18131
read sectors          24672      36262
write ops              3502       3000
write sectors         28016       6000
disk touched           12.8 MB     640 KB
.P2
.PP
.B "kfs wins the total, and efs wins the trend \(em and the crossing has happened by round five."
kfs is a third quicker on a directory of fifty and SLOWER per create than
efs on the last fifty of three hundred: 137.2ms against 123.0ms.  Its
per-create cost grows 1.47x across the run; efs's does not grow at all,
0.96x, which is flat within the rig's noise.  So which filesystem is
faster is a question about how many files are in a directory, and past
about two hundred and fifty the answer is efs.
.PP
.B "These figures replace an earlier table and are not comparable with it."
The same script on the same board in an earlier session gave 12.25s for
the efs arm against 38.32s here, 31.7ms a create against 128.7ms \(em
three times, on a workload that has since got cheaper in every counted
operation.  Which kernel was booted then was not recorded, so the
difference cannot be attributed and is not attributed.  What this board
was running for the table above IS recorded: four cores online with the
work on core 0, the Dis JIT on
.CW ( /dev/jit
reads 1), both arms in one boot.  An absolute number from a session that
did not write down its kernel is worth nothing; the ratio within one boot
is worth everything, which is the rule the next paragraph states and this
is the cost of having broken it once.
.PP
.B "The number that decides it on THIS board is read ops, and efs issues a sixth as many."
3084 against 18131, for two thirds the sectors read \(em kfs's blocks are
1KB and efs's are 4KB, so kfs issues six times as many transfers a
quarter the size.  A card charges per command far more than per byte: ten
FAT creates on this one measured 38.8ms each while it streams megabytes a
second.  So on the medium this board actually has, the four-fold
difference in operations is the one that shows, and it is the opposite
way round from the total above.
.PP
.B "And efs's costs are space and write amplification, which are real."
It wrote 4.7 times the sectors kfs did and touched 12.8MB of a 16MB disk
to hold three hundred tiny files, against kfs's 640KB.  That is copy on
write plus an allocator that sweeps forward rather than reusing: a
20-fold space amplification.  On flash the sweep is even wear and
welcome; on a small medium it means efs needs far more free space than its
data, and that belongs in the open questions below rather than being
discovered later.
.PP
.B "Why both arms must be in one script."
efs measured 31.7 to 41.9ms a create here and 17.2 to 32.8 in a run an
hour earlier, on the same kernel and the same workload.  The rig drifts,
which is already written down in this tree, so an absolute figure from one
session is worth little and a ratio measured in one boot is worth a lot.
.CW tests/fsbench
reams both filesystems on the same device in the same run for that reason.
.NH 1
Why this is kinder to the card than kfs is
.PP
Everything above is about sectors, which is the fiction the card sells.
Underneath is NAND behind a controller nobody here can see: erase blocks
far larger than a sector, a translation layer with its own map, and its
own idea of where a given sector lives this minute.  Three consequences
follow, none of them visible from a driver, and together they are the
other half of the argument for replacing
.I kfs
\(em the first half being what happens when the power goes.
.IP \(bu
.B "A small write is not a small write."
Changing 512 bytes inside an erase block costs the controller a read, a
merge, a write of the whole block somewhere else, and a map update.  The
cost is set by the erase block, not by what was asked for.
.IP \(bu
.B "The same address written over and over is the worst case there is."
Every rewrite is another erase-block cycle and another map update, and
the translation layer has nowhere to hide it.  A format with one hot
block is a format that wears one region of the card out and stalls on it
meanwhile.
.IP \(bu
.B "Large, aligned, sequential writes are what the part is built for."
An SD card is specified with an allocation unit, and writing whole
aligned units in order is the case its firmware is tuned for.  Anything
else is the slow path.
.PP
.B "Kfs is on the wrong side of all three, and the code says so."
.CW sdfs()
in
.CW os/inferno/init/raspi3binit.b
reams with no
.CW -b ,
so the
.CW "bufsize := 1024"
default at
.CW appl/cmd/disk/kfs.b:388
stands and the unit of every transfer is two sectors.  That alone is a
small-write format.  What makes it a hot-block format is
.CW "SUPERADDR = 1"
together with
.CW "sb.fbuf = p.iobuf[Super1size:]"
in
.CW superream :
the head of the free list lives
.I inside
the superblock's own buffer, so
.CW balloc
and
.CW addfree
dirty block 1 on every single allocation and every single free.  A run
that allocates a thousand blocks rewrites the same 1KB at the same
address a thousand times.
.PP
.B "FAT is not much better, and the card's own shape makes it legible."
A 512-byte FAT sector holds 128 FAT32 entries, and at 64 sectors to a
cluster each entry covers 32KB, so one FAT sector describes 4MB of file.
The 1536000-byte kernel that
.CW kupdate
writes is 47 clusters \(em all of them in one FAT sector, which the
allocation therefore walks 47 times.  Whether those reach the card as 47
writes or as one is a property of
.I dossrv 's
sector cache and not of the format; the format's part is that it gave
the allocator no choice but to keep going back to the same place.
.PP
.B "What efs does instead falls out of the commit rule."
Copy on write means no metadata block is ever updated in place: a change
writes new blocks into space nothing else is using and ends in a new
root.  There is no block 1, because there is no structure that every
allocation has to go back and edit.  Blocks are 4KB or 8KB and nothing
smaller is ever issued, so the card is never asked to merge a partial
one.  And a commit's writes are a batch that can be issued in address
order, which is the sequential case, rather than a scatter of updates
interleaved with the data.
.PP
One hot spot remains and should be stated rather than glossed: the
superblocks.  They are at fixed offsets and one of them is written on
every commit.  That is bounded at one block per commit instead of one
per allocation, and alternating between the two halves it again, but it
is the place where
.I efs
still writes the same address repeatedly and it is where to look first
if the card ever develops a slow region.
.PP
.B "Alignment, and one number that is already right."
The partition this plan picks starts at sector 1064960, which is
545259520 bytes, 520MB from the start of the card.  That is exactly 130
units of 4MB and 65 of 8MB, and it is
.I not
a multiple of 16MB.  So for the allocation-unit sizes these cards
usually carry, the partition begins on a unit boundary and a
power-of-two block size keeps every block inside one \(em which is worth
knowing before the number is chosen rather than after, because a
partition start that is off by a sector makes every aligned write in the
filesystem unaligned on the card.
.PP
.B "And one number nobody here has asked the card for."
The card will say.  ACMD13 returns a 64-byte SD Status whose AU_SIZE
field names the allocation unit the card wants writes aligned to, and it
is a data transfer like any other block read.
.CW os/inferno/raspi3b/sdemmcbcm.c
sends ten commands in all, and its only CMD55 \(em the escape that makes
the next one an application command \(em is the one prefixing ACMD41 in
the power-up loop.  So the board has never asked: every sentence above
about 4MB is about what such cards usually are and not about this one.  Reading SD Status and
printing it at boot beside the capacity is a small addition to a driver
that already does block reads, and it is what the block-size question at
the end of this plan should be decided against.  Until then the honest
statement is that the alignment arithmetic is right for an assumed unit.
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
Open questions, and the four that are now decided
.PP
.B "DECIDED, by measurement: the block size stays 4KB."
This asked to be settled "by measuring on the board, with the polled
controller, not on the host", so it was: both block sizes on the same
16MB disk through
.CW sdmem (3)
\(em 4000 blocks of 4KB against 2000 of 8KB \(em same workloads, same
boot, counters from the driver.
.P1
300 creates                4KB        8KB
time, free medium         32.9 s     39.0 s
read ops                   1644       1478
write ops                  2057       1982
sectors moved             29608      55360
disk touched              7044 KB   13488 KB

2.5MB written              4KB        8KB
time, free medium         11.3 s     11.8 s
read ops                    733        352
write ops                   745        356
sectors moved             11824      11328
time, delay 10ms          23.2 s     18.2 s
.P2
.PP
.B "8KB halves the operations of a large sequential write and doubles the amplification of everything else."
Both halves of that are in the table and both are large.  745 writes
become 356 for the same bytes, which on a medium charging per command is
1.27x measured; and 300 small files touch 13.5MB of a 16MB filesystem
instead of 7MB.
.PP
The second decides it.  This filesystem is small \(em the board's is 64MB
and the test images are 16 \(em and the section above on
.I kfs
already records that efs "needs far more free space than its data", so
doubling that is the one cost this format cannot afford.  A workload of
three hundred tiny files is also 19 per cent slower at 8KB on a free
medium, so the large-write advantage is not even general.
.PP
.B "And the large-write advantage is mostly NOT available any other way, which is worth being clear about."
Of the 389 transfers 8KB saves, about 311 are the 622 data blocks being
twice as big, and no knob reaches those.  The remaining 78 are commits:
the write batch is 32 BLOCKS, so 8KB batches 256KB against 4KB's 128KB,
and that part is a constant in
.CW disk/efs.b
rather than a property of the format.  So "8KB is faster on a big write"
is true and the format change is not the only way to get part of it.
.PP
.B "ASKED, and it does not reopen it \(em it closes it."
The thing that could have was the card's allocation unit: if a write
smaller than the AU costs a whole AU inside the card, the amplification
argument above is measuring the wrong thing.  ACMD13 reports it and
nothing on this board read it, so
.CW sdhostbcm.c
does now \(em
.CW "echo status >/dev/sdN0/ctl" :
.P1
sdhost au 9 (4096KB) eraseaus 1 erasetmo 3 speedclass 4
.P2
Six reads, six identical answers \(em and the first one after a boot
needs TWO attempts, because this controller loses SDHBCT writes, which
the driver already documents for block reads and already answers with a
bounded retry.  The attempt count is reported, so a retry that is always
needed stays distinguishable from one that is occasionally needed: cold
it is 2, and every call after a transfer is 1.  The allocation unit is FOUR MEGABYTES,
which is 1024 blocks of 4KB and 512 of 8KB.  Neither candidate is within
three orders of magnitude of it, so moving from 4KB to 8KB does not bring
a write any closer to the card's own granularity: it halves the number of
commands and doubles the bytes, and the AU is indifferent to both.
.PP
So the AU cannot be the tie-breaker this question hoped for, and the
measurement above stands on its own.  What the AU does say is that
sequential locality matters far more than block size on this card \(em
whether a write stays inside one 4MB unit \(em which is an allocator
question and not a format one, and is not something either block size
addresses.
.PP
.CW ERASE_SIZE
is one AU and
.CW ERASE_TIMEOUT
is 3, so erasing 4MB is budgeted at three seconds; nothing here issues an
erase, and that is the figure to weigh if anything ever should.  Speed
class 4 is Class 10.
.PP
.B "DECIDED: the free map is a bitmap, with groups."
One 4KB block covers 32768 blocks and the superblock names an index of up
to 512 of them, which is 64GB; past that the index would need a second
level and every program refuses rather than writing a map it knows is
short.  A log with checkpoints was the "likely answer" here and was not
needed: a commit writes only the groups whose bits changed, which is one
or two, so writing the map on every commit is not the waste this question
assumed.
.PP
.B "DECIDED: data is copy-on-write too."
It is simpler, it costs a full block write for a one-byte change, and
that cost is what the write batch and the dirty-node cache in
.CW doc/open-issues-plan.ms
B1f exist to amortise \(em measured at 1.17x write amplification for a
large sequential write, against 3.79x before that cache.
.PP
.B "DECIDED: a checksum on every block."
And it earned itself twice over.  It is what turned the board's
unmountable image into "block 6521 is wrong" rather than "the tree is
wrong", and it is what made a lost write diagnosable at all: 4096 zero
bytes give Adler
.CW "1000 1"
against stored
.CW "0 0" ,
which is the message both the board's failure and every injected one
print.  Where it is verified matters and is measured \(em once per block
READ, not once per block touched, 1.30x against 1.90x; see B1e.
.PP
.B "DECIDED: yes, it serves the small gap, because the format assumes no minimum size."
.CW Fs.reserve
is an eighth of the filesystem capped at 24 blocks and floored at 4,
which exists precisely because a flat reserve left a 64-block image
unable to hold one file.
.CW tests/efs-limits
holds the small end honest: 32767, 32768 and 32769 blocks, and a 4MiB
filesystem filled to 921 files.
