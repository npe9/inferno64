.TL
efs: the on-disk format
.AU
.PP
This is milestone 1 of
.CW doc/efs-plan.ms :
the format written down before there is code, because a format settled in
code is a format nobody can review.  It fixes block layout, the
superblocks, the key encoding, and the commit rule, and it closes the
five questions that plan left open.  Where a number here came from a
measurement on the board, it says so.
.NH 1
Units and addressing
.PP
A
.B block
is 4096 bytes, eight 512-byte sectors.  It is the unit of allocation and
of every transfer; nothing smaller is ever written to the card.
.PP
Block numbers are
.B "relative to the start of the filesystem" ,
not to the start of the card, and block 0 is the first block of the
filesystem.  A server given a partition and a server given an image file
must compute the same block numbers, or every check that compares them is
worthless.  So:
.DS
.CW
byte offset of block n, within the file or partition = n * 4096
.R
.DE
and the sector arithmetic appears exactly once, in whatever opens the
device:
.DS
.CW
sector of block n = (partition start) + 8n
.R
.DE
On this board the intended partition begins at sector 1064960 \(em
immediately above the firmware's FAT32 \(em so block 0 is sector 1064960
and block 1 is 1064968.  For a host image the partition start is 0.
Nothing above the device layer knows either number.
.PP
A block number is a
.B "64-bit unsigned integer" ,
one type, read and written by one pair of functions.  Block number 0 is a
valid block (it holds a superblock, below), so
.B "the null pointer is not 0" :
an absent pointer is all-ones,
.CW 16rffffffffffffffff .
This is stated because the alternative \(em reserving 0 \(em invites the
reader to test a pointer for truth, and a format should not have two
spellings for nothing.
.NH 1
Superblocks
.PP
Two, and
.B "as far apart as the filesystem allows:"
block 0 and the last block.  Not blocks 0 and 1.  A card erases in units
far larger than 4KB, so two adjacent blocks are plausibly in one erase
block and a single failed erase would take both copies of the only
structure that makes recovery possible.
.PP
Each superblock is one block, and holds:
.IP \(bu
.B magic ,
8 bytes, a constant identifying the format.
.IP \(bu
.B version ,
4 bytes.  A server that does not recognise it refuses to mount and says
so; it does not guess.
.IP \(bu
.B generation ,
8 bytes, increasing by one per commit.  This is the only thing that
orders the two superblocks.
.IP \(bu
.B blocksize ,
4 bytes, and
.B nblocks ,
8 bytes, the size of the filesystem in blocks.  Written by mkfs and
never changed.  A server that finds the device smaller than
.I nblocks
refuses to mount.
.IP \(bu
.B treeroot ,
8 bytes, the block number of the root of the metadata tree.
.IP \(bu
.B freeroot ,
8 bytes, the root of the free-space tree.
.IP \(bu
.B nextino ,
8 bytes, the next inode number to hand out.  Inode numbers are never
reused; see qids, below.
.IP \(bu
.B pendingfree ,
a list of block numbers freed by the commit that wrote this superblock,
and not reusable until the commit after it.  Bounded, and when it does
not fit it spills to a block whose number is recorded here instead.
.IP \(bu
.B checksum ,
4 bytes, over the whole block with this field taken as zero.
.PP
.B "Where the spare is, without trusting the first."
Superblock 1 is in the last block, so finding it needs a block count
\(em and taking that count from superblock 0 would mean a corrupt
superblock 0 hides the copy that exists for exactly that case.  The size
is a property of the device and the device can be asked: a file has a
length, a partition has a size.
.B "A reader gets the block count from the device and treats"
.I nblocks
.B "in the superblock as a claim to check against it,"
not as the only source.  This was found by writing the corruption test
before believing the design, and it is the kind of circularity that only
shows up when the thing it protects against actually happens.
.PP
.B Mount
reads both superblocks, discards any that fails its checksum or magic,
and takes the one with the higher generation.
.B "That is the whole of recovery."
There is no check pass, no replay, and no repair step.  If neither
superblock is good the filesystem does not mount, and that is the correct
outcome: a filesystem that mounts and lies is the failure this format
exists to prevent.
.PP
.B "The contract, stated so that it can be held to."
A traditional filesystem's contract is
.DS
.CW
crash -> mount -> fsck -> usable
.R
.DE
and it needs the third step because the disk can hold a state that no
sequence of operations could have produced.  Rename
.CW a
to
.CW b
in place and there are four writes \(em remove an entry, add an entry,
update an inode, change the free map \(em and power can leave any prefix
of them on the disk.  Something then has to guess what was meant.
.PP
This format's contract is
.DS
.CW
crash -> mount -> usable
.R
.DE
because there is no state between two commits.  Every block committed is
immutable; a change writes new blocks and ends in one superblock write;
and the two superblocks each carry a generation and a checksum, so even a
torn write to the newer one is harmless \(em mount validates both and
takes the highest that checksums.
.PP
.B "Which is why the checker is called"
.CW efsck
.B "and not"
.CW fsck .
It is not a recovery stage and nothing in the mount path calls it.  It
asks "prove to me that this filesystem satisfies its invariants", and it
exists because hardware faults, firmware bugs, memory corruption and bugs
in this very code can still damage persistent state.  A filesystem that
cannot
.I need
recovery is achievable; one that never
.I benefits
from an integrity checker is not.  If the crash harness ever has to run
.CW efsck
.I before
an image is usable, the design has failed and no amount of checking will
repair that.
.NH 1
The metadata tree
.PP
One copy-on-write B-tree holds everything about the filesystem's
contents.  Nothing in it is ever overwritten in place: a change writes
new blocks from the leaf up the spine and ends in a new root.
.PP
Keys are
.B "17 bytes, compared as bytes:"
.DS
.CW
inode   8 bytes, big endian
type    1 byte
offset  8 bytes, big endian
.R
.DE
Big endian so that a byte comparison
.I is
the numeric order, and no comparison function can disagree with the
sort order it was given.  Three types:
.IP \(bu
.B 0, inode.
Offset zero.  The value is the inode record: mode, nlink, length, the
three times, and uid and gid
.I "as strings" .
There is no user table; see the plan's note on what
.I kfs
invents at ream time.
.IP \(bu
.B "1, directory entry."
The key's inode is the
.I directory's
inode; the offset is a hash of the entry's name.  The value carries the
name in full and the child's inode number, and a bucket holds however
many entries collide.  The name is in the value and never in the key,
because a key must be fixed width and a name is not.
.IP \(bu
.B "2, data extent."
The offset is the file offset, block-aligned.  The value is a block
number and a length.
.PP
A file's data blocks are reached through type 2 and are themselves
copy-on-write: a write allocates a new block, writes it, and replaces the
extent.  No committed data block is ever modified.
.NH 1
Free space
.PP
The free map is
.B "a copy-on-write bitmap, indexed" ,
not a monolithic bitmap and not a log.  One bit per block; a 4KB bitmap
block covers 32768 blocks, which is 128MB of filesystem; and the
superblock's
.I freeroot
names an
.B "index block"
of 512 block numbers, one per group of 32768.  That is 16,777,216 blocks,
or 64GB, which is more than this card and less than forever: past it the
index needs a second level, and every program refuses rather than writing
a map it knows is short.
.PP
The reason for indexing rather than one flat map is arithmetic.  A 29GB
partition of 4KB blocks is about 7.6M blocks, so a whole bitmap is about
950KB; writing that on every commit costs about 160ms at the 5-6MB/s
this board's block layer was measured to do, which is not a commit, it is
a stall.  Indexed, a commit rewrites only the bitmap blocks whose bits
changed \(em a handful \(em plus the one index block above them.  A log
with checkpoints would also avoid the 950KB, at the price of a replay at
mount, and replay at mount is the thing this format is trying not to
have.
.PP
This section said
.B "held in the tree"
until the map was built, and the index block is a deliberate departure
from it.  The stated reason was never "in the tree" for its own sake, it
was the 950KB, and an index block buys that in full.  What it avoids is
a recursion: bitmap blocks kept as keyed records in the B-tree are
allocated from the very map they describe, so updating the map allocates
tree nodes, which dirties more of the map, which allocates more nodes.
That converges, and it is the kind of thing that converges in testing and
not on the card.  The one subsystem whose entire claim is that a crash
never needs repair is the wrong place to put it.  The allocator is
therefore outside the tree entirely, and the fixpoint that remains \(em
allocating the replacement bitmap blocks can itself dirty another group
\(em is bounded by the group count and terminates because allocation
inside a transaction only ever sets bits.
.PP
.B "Blocks freed by a commit are not allocatable until the commit after
.B "it."
They are listed in
.I pendingfree
in the superblock that freed them, and folded into the bitmap by the next
commit.  Without this rule a crash part way through a commit can scribble
on the tree that commit was meant to be able to fall back to, which
defeats the whole design.
.NH 1
The commit rule
.PP
A commit is:
.IP "1." 4
Write every new data and metadata block.  These are all blocks that
nothing committed points at, so their contents cannot matter to a reader
of the current filesystem.
.IP "2." 4
Wait for those writes to
.I complete .
.IP "3." 4
Write one superblock \(em the one whose generation is now the older \(em
with the new roots and generation+1.
.PP
Until step 3 lands, the old tree is the filesystem.  After it, the new one
is.
.B "There is no third state."
.PP
.B "What step 2 means on this hardware,"
because milestone 5's crash harness will be tested against this sentence
and not against an intention.  The SDHOST driver is synchronous: a write
returns when the card has acknowledged it and the driver has waited out
the card's program time.  So "wait for completion" is
.I "issue the superblock write only after every other write call has
.I returned ,
and no cache-flush command is involved because none is issued.  This
relies on the card not reordering acknowledged writes in an internal
cache.  That is an assumption about the card, it is written here as an
assumption, and the crash harness is what will hold it to account \(em a
card that reorders will show up as a mount that finds a new-generation
superblock pointing at blocks that were never written, which fsck will
say loudly.
.NH 1
Two rules that are not negotiable
.PP
Both were real bugs in this tree, and a format that does not forbid them
will grow them again.
.IP "1." 4
.B "A record read from a block is copied out of it."
.CW Dosdir.arr2Dd
in
.I dossrv
built a structure whose fields were slices of the sector buffer, and a
Limbo slice shares the array it came from \(em so a directory entry was a
window on a buffer, valid only while that buffer held that sector.  A
length carried across a
.CW putsect
was four bytes of whatever sector next took the buffer.  That emptied
this board's kernel on every update and left it dark twice.  In
.I efs
a block buffer is parsed into a value and the value owns its bytes.
.IP "2." 4
.B "A block number is one width everywhere."
FAT32 keeps the halves of a start cluster in different fields and this
tree has fixed that truncation three times, in
.I rename ,
in
.I mkdentry
and in
.I mkdir .
.I Efs
has one 64-bit block number type, one pair of functions that read and
write it, and no code anywhere may assemble one from halves.
.NH 1
Qids
.PP
The qid path is the inode number.  The qid version is an inode
generation counter, so a removed file's number cannot come back silently
as the same qid \(em and since
.I nextino
never goes backwards, it will not come back at all.  A rename does not
change a qid: a rename is a key change in the tree, not the rewrite of an
entry.
.NH 1
The five questions the plan left open, closed
.IP \(bu
.B "Block size: 4KB."
The plan said to decide by measuring on the board with the polled
controller rather than reasoning about tree depth.  Measured: 100
write-and-verify cycles of 4KB took 1.580s and 100 of 8KB took 1.744s, so
the extra 4KB costs 1.65ms and the per-operation fixed cost dominates
\(em which on its own argues that a bigger block is nearly free.  It is
not chosen, because the thing 8KB was supposed to buy does not exist at
this size: with a fanout of a couple of hundred keys per node, 7.6M
blocks is three levels deep at 4KB and three at 8KB.  There is nothing to
buy with a doubled write amplification on every small change, so 4KB.
.IP \(bu
.B "Free map: a copy-on-write bitmap under an index block."
Reasoned above; a whole-bitmap write is 160ms a commit, a log's price is
a replay at mount, and putting the map in the tree makes the allocator
recursive.
.IP \(bu
.B "Data is copy-on-write too."
It costs a full block write for a one-byte change, and it is what makes
the commit rule true of data and not only of metadata.  A format where
committed data can be modified in place has a third state after a crash,
which is exactly what this is for.
.IP \(bu
.B "Checksums on every block, not only the superblock."
Four bytes in 4096 is a tenth of a percent of the space and a checksum is
what turns "the tree is wrong" into "this block is wrong".  This port has
spent enough days on the first kind of sentence.
.IP \(bu
.B "The format assumes no minimum size,"
so the 7MB gap below the FAT partition \(em sectors 2048 to 16383, where
.I kfs
is reamed today \(em can hold a small
.I efs
as well.  A filesystem of a few blocks is legal: two superblocks, an
index block, one bitmap block and a root.
.NH 1
What is not decided here
.PP
The B-tree node layout, the allocator's policy, and the hash used for
directory entries.  They are implementation, they do not change what is
on the card in a way another program must agree with, and milestone 2
.CW ( mkfs
and
.I dump
on the host) is where they get written and where
.I dump
becomes the second opinion that keeps them honest.
.NH 1
Where efs is today
.PP
Written and tested, on the host under
.I emu :
.I mkefs ,
the server, writes, truncate, remove, rename,
.I efsck ,
.I efsdump ,
a crash harness that fails every write in turn, a stress run under
.IR fatstress ,
and a free map of more than one group.  Six suites,
.CW tests/efs-*.sh .
.PP
Not yet done, and named here so that nothing reads as finished that is
not:
.IP \(bu
.B "It has never run on the board."
Everything above is
.I emu
on the host against an image file.  The binaries are in the kernel and
the partition arithmetic is printed, but no
.I efs
has been made on the card.
.IP \(bu
.B "Nothing boots from it."
.I kfs
is still what
.CW raspi3binit.b
reams, and it stays in the tree to compare against.
.IP \(bu
.B "The allocation rate is high."
A workload with a few hundred kilobytes of live data needs a 256MB Dis
heap.  That is garbage and not a leak \(em
.CW /dev/memheap
showed the live count falling from 41516 to 5835 inside one run \(em but
it is still a rate worth reducing, and on a board with 1GB it will
matter before it matters here.
.IP \(bu
.B "A checksum cannot tell a block from another copy of itself."
Every block has one and it is checked on read, but it is computed over
that block's own bytes and recorded nowhere else, so an internally
consistent block passes even when it is the wrong block or an old version
of the right one.  Data blocks have none at all.  The fix is the
parent-records-child arrangement the FS-PI work above describes \(em
block number in the node header, child checksum in the interior entry,
data checksum in the extent record, root checksum in the superblock \(em
which is a version bump and is not done.
.IP \(bu
.B "Past 64GB the index needs a second level."
Refused, not truncated.
