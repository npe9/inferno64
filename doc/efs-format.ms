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
.B "a copy-on-write bitmap held in the tree" ,
not a monolithic bitmap and not a log.  One bit per block; a 4KB bitmap
block covers 32768 blocks, which is 128MB of filesystem.
.PP
The reason is arithmetic.  A 29GB partition of 4KB blocks is about 7.6M
blocks, so a whole bitmap is about 950KB; writing that on every commit
costs about 160ms at the 5-6MB/s this board's block layer was measured
to do, which is not a commit, it is a stall.  Held in the tree, a commit
rewrites only the bitmap blocks whose bits changed \(em a handful \(em
plus their spine.  A log with checkpoints would also avoid the 950KB, at
the price of a replay at mount, and replay at mount is the thing this
format is trying not to have.
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
.B "Free map: a copy-on-write bitmap in the tree."
Reasoned above; a whole-bitmap write is 160ms a commit, and a log's
price is a replay at mount.
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
as well.  A filesystem of a few blocks is legal: two superblocks, a root,
and a bitmap block.
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
