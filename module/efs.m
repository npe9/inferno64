#
# efs: the on-disk format, as a module both the writer and the reader
# use.
#
# The point of putting it here rather than in each program is that
# mkefs and efsdump must not be able to disagree about the format.  If
# they each carried their own idea of where a field lives, dump printing
# back what mkfs wrote would prove nothing -- which is exactly the check
# milestone 2 of doc/efs-plan.ms asks for.
#
# doc/efs-format.ms is the specification.  Where a constant here has a
# reason, the reason is there and not repeated.
#
Efs: module
{
	PATH:	con "/dis/lib/efs.dis";

	Blocksize:	con 4096;	# eight 512-byte sectors
	Sectorsz:	con 512;
	Blksectors:	con Blocksize / Sectorsz;
	Keysz:		con 17;		# inode[8] type[1] offset[8]
	Magicsz:	con 8;
	Magic:		con "efs-0001";	# Magicsz bytes exactly
	#
	# Version 2 moved the free map from a single block to a block of
	# block numbers, so freeroot no longer means what it meant.  An
	# image made by version 1 mounts nowhere: Super.unpack refuses on
	# the version, which is the point of having the field.  There is no
	# upgrade path and none is wanted -- the only version 1 images that
	# exist are test images and none holds anything.
	#
	Version:	con 2;

	#
	# The free map's geometry.
	#
	# One bit per block, so a 4KB block covers 32768 blocks, and the
	# INDEX block holds 4096/8 = 512 of those, which is 16,777,216
	# blocks or 64GB.  Both numbers are here because mkefs, the
	# allocator, efsck and efsdump all need them and a filesystem
	# whose four programs disagree about where a bit lives is not
	# worth debugging.
	#
	Bitsperblk:	con Blocksize * 8;
	Maxgroups:	con Blocksize / 8;
	Maxblocks:	con Maxgroups * Bitsperblk;

	#
	# An absent block pointer is all ones, NOT zero, because block 0 is
	# a real block -- it holds a superblock.  Limbo's big is a signed
	# 64-bit integer, so all-ones is -1, and that is the value to
	# compare against; it writes out as ff..ff.
	#
	Nilblk:		con big -1;

	#
	# Blocks kept back from anything that adds to the filesystem.
	#
	# A delete has to ALLOCATE in order to commit: efs is copy on write,
	# so removing a key rewrites the path to it, and Fs.free defers the
	# blocks it gives up to the NEXT transaction.  A filesystem with no
	# free blocks therefore cannot be emptied -- rm returns "filesystem
	# is full" and there is no way back.  Creates and writes are refused
	# while the margin is thin and deletes are not, so there is always
	# room to delete.  Nreserve covers one path rewrite (Maxdepth) and
	# the group and index blocks a commit needs, with room over.
	#
	Nreserve:	con 24;

	# key types
	Kinode, Kdentry, Kextent: con iota;

	#
	# A device: a file or a partition, addressed in blocks relative to
	# the start of the filesystem.  The sector arithmetic lives here
	# and nowhere else, so a partition at sector 1064960 and an image
	# file at 0 give the same block numbers to everything above.
	#
	Dev: adt {
		fd:	ref Sys->FD;
		start:	big;		# byte offset of block 0
		nblocks: big;
		name:	string;
		#
		# Write injection, for the crash harness.  failafter 0 means
		# never fail; otherwise every write after the first
		# "failafter" of them is refused.  It lives in the Dev
		# because that is the one place a block leaves this program,
		# so a workload cannot get a write past it by accident.
		#
		nwrite:	int;
		failafter: int;

		open:	fn(name: string, startsect: big, nblocks: big,
				create: int): (ref Dev, string);
		rdblk:	fn(d: self ref Dev, n: big): (array of byte, string);
		wrblk:	fn(d: self ref Dev, n: big, b: array of byte): string;
	};

	Super: adt {
		gen:		big;
		nblocks:	big;
		blocksize:	int;
		version:	int;
		treeroot:	big;
		freeroot:	big;
		nextino:	big;
		pendingfree:	array of big;

		pack:	fn(s: self ref Super): array of byte;
		unpack:	fn(b: array of byte): (ref Super, string);
	};

	# node types
	Nleaf, Ninterior: con iota;

	#
	# A key: 17 bytes, compared as bytes, big endian so that a byte
	# comparison IS the numeric order and no comparison function can
	# disagree with the sort order it was given.
	#
	Key: adt {
		ino:	big;
		ktype:	int;
		off:	big;

		pack:	fn(k: self Key, b: array of byte, o: int);
		unpack:	fn(b: array of byte, o: int): Key;
		cmp:	fn(k: self Key, j: Key): int;
		text:	fn(k: self Key): string;
	};

	Inode: adt {
		mode:	int;
		nlink:	int;
		length:	big;
		atime:	int;
		mtime:	int;
		uid:	string;
		gid:	string;

		pack:	fn(i: self ref Inode): array of byte;
		unpack:	fn(b: array of byte): (ref Inode, string);
	};

	#
	# One tree block, parsed.  The entries own their bytes: they are
	# copies, not slices of the block buffer.  That is the format's
	# first non-negotiable rule, and it is the bug that emptied this
	# board's kernel twice.
	#
	Ent: adt {
		key:	Key;
		val:	array of byte;
	};

	Node: adt {
		ntype:	int;
		level:	int;
		ents:	array of Ent;

		pack:	fn(n: self ref Node): (array of byte, string);
		unpack:	fn(b: array of byte): (ref Node, string);
	};

	#
	# A mounted filesystem, read side.
	#
	# Lookup descends; range collects every entry for one inode and
	# key type, which is how a directory is listed and how a file's
	# extents are found.  Collecting into an array rather than handing
	# back an iterator is a deliberate limit: it is simple, it is
	# enough for the directories this board will hold, and a directory
	# large enough for it to matter is a reason to write the iterator
	# then rather than to carry one now.
	#
	Fs: adt {
		d:	ref Dev;
		s:	ref Super;
		which:	int;		# which superblock was taken

		#
		# The write side, and the free map it allocates from.
		#
		# bmindex is the index block read into memory: one block
		# number per group of 32768 blocks.  Group bitmaps are read
		# only when a bit in them is wanted, because a 29GB
		# filesystem has 230 of them and a commit touches one or
		# two.  groups[g] is nil until then.
		#
		# repl[g] is the block this transaction will write group g
		# to, or Nilblk while the group is unchanged; idxblk is the
		# same for the index.  cursor is where the next allocation
		# starts looking, so that filling a filesystem is not
		# quadratic in the number of blocks.
		#
		bmindex: array of big;
		groups:	array of array of byte;
		gdirty:	array of int;
		repl:	array of big;
		idxblk:	big;
		cursor:	int;
		#
		# A few decoded nodes, by block number.
		#
		# Safe because of the format's own rule: a committed block is
		# never written again, so a block number identifies its
		# contents for as long as the transaction lasts.  Cleared by
		# commit, because after one a freed block can be handed out
		# again and the number would name something else.
		#
		cblk:	array of big;
		cnode:	array of ref Node;
		cnext:	int;
		#
		# And a few RAW blocks, under the decoded cache.
		#
		# Interior nodes are navigated in their packed bytes rather
		# than decoded -- two thirds of every entry this library used
		# to decode was in an interior node, decoded only to choose
		# one child of it (doc/open-issues-plan.ms B1).  Navigating
		# needs the bytes, so the bytes are what is cached, and
		# getnode() reads through here too so a block fetched once is
		# fetched once however it is then used.
		#
		rblk:	array of big;
		rraw:	array of array of byte;
		rnext:	int;
		freed:	list of big;	# freed by the transaction in hand
		dirty:	int;

		mount:	fn(name: string, startsect: big): (ref Fs, string);
		#
		# mount, but naming the superblock: 0 or 1 takes that one
		# whatever its generation, and -1 is what mount passes.
		# Forcing it is a diagnostic -- it is the only way to ask
		# whether the OTHER superblock is sound when the live one is
		# not, which is the question the two of them exist to answer.
		#
		mountsuper: fn(name: string, startsect: big, which: int):
				(ref Fs, string);
		rawblk:	fn(f: self ref Fs, n: big): (array of byte, string);
		writable: fn(f: self ref Fs): string;
		group:	fn(f: self ref Fs, g: int): (array of byte, string);
		bmget:	fn(f: self ref Fs, n: int): (int, string);
		bmset:	fn(f: self ref Fs, n: int, v: int): string;
		alloc:	fn(f: self ref Fs): (big, string);
		headroom: fn(f: self ref Fs, want: int): (int, string);
		reserve: fn(f: self ref Fs): int;
		free:	fn(f: self ref Fs, n: big);
		insert:	fn(f: self ref Fs, k: Key, v: array of byte): string;
		delete:	fn(f: self ref Fs, k: Key): string;
		commit:	fn(f: self ref Fs): string;
		pathto:	fn(f: self ref Fs, k: Key): (array of big, array of int, string);
		replace: fn(f: self ref Fs, k: Key, v: array of byte, ins: int): string;
		writeents: fn(f: self ref Fs, ents: array of Ent, ntype: int,
				level: int): (array of big, array of Key, string);
		fixup:	fn(f: self ref Fs, blks: array of big, idx: array of int,
				depth: int, kids: array of big,
				kkeys: array of Key): string;
		getnode: fn(f: self ref Fs, n: big): (ref Node, string);
		leaffor: fn(f: self ref Fs, k: Key): (ref Node, string);
		get:	fn(f: self ref Fs, k: Key): (array of byte, string);
		range:	fn(f: self ref Fs, ino: big, ktype: int):
				(array of Ent, string);
		nextleaf: fn(f: self ref Fs, blks: array of big,
				idx: array of int): int;
	};

	#
	# How much of a block an entry costs, and how much a block holds.
	#
	# One place, used by everything that fills a node, because the
	# alternative -- asking Node.pack whether a trial set fits -- packs
	# the whole block once per candidate entry.  That is quadratic in
	# both time and allocation, with a 4KB array per iteration, and it
	# exhausted a 32MB heap on a workload whose live data was a few
	# hundred kilobytes.
	#
	Nodehdr:	con 8;		# type, level, nents, checksum
	entsize:	fn(e: Ent): int;
	noderoom:	fn(): int;

	bitset:		fn(b: array of byte, i: int, v: int);
	bitget:		fn(b: array of byte, i: int): int;

	#
	# How many group bitmaps a filesystem of this many blocks needs.
	# Not (nblocks + Bitsperblk - 1) / Bitsperblk written out four
	# times, because it was, and one of the four rounded down.
	#
	ngroups:	fn(nblocks: big): int;
	#
	# The hash a directory entry's key carries, so that a name can be
	# looked up without scanning.
	#
	# It lives here because it was written out twice, in disk/efs.b and
	# in disk/mkefs.b, and a divergence between those two would make
	# every name in an image mkefs populated unfindable by the server --
	# silently, since the dentry still holds the name and ls still lists
	# it.  That is exactly the symptom the kencc big-literal bug produced,
	# and it took three sessions to recognise; one way of causing it is
	# enough.
	#
	namehash:	fn(s: string): big;

	#
	# How many freed blocks one superblock can carry.  Commit must not
	# build a longer list than this; see the note there.
	#
	maxpending:	fn(): int;

	init:		fn();
	#
	# The checksum, as its two 16-bit halves, NEVER joined into one
	# 32-bit value.
	#
	# It used to be carried as a big, because Limbo's int is 32 bits to
	# the compiler and 64 at runtime here, so a computed 0xffffffff and
	# a literal "int 16rffffffff" print alike and compare unequal, and a
	# checksum that differs between the host and the board is worse than
	# none.  A big holds all 32 bits with no sign games -- and allocates,
	# every time, on a path taken for every block packed and every block
	# read.  mprof put 1.46MB of a 2.83MB workload on the single line
	# that made one.
	#
	# Adler-32's halves are each below 65521, so neither has a sign
	# problem in an int of any width, and the on-disk bytes are exactly
	# what (c<<16)|a used to write big endian: c then a, two bytes each.
	# The 32-bit value was never needed for anything except being
	# awkward.
	#
	# skip is a byte offset whose four bytes are read as zero, which is
	# how a block is verified against the sum stored inside it.  It used
	# to be done by copying the whole 4KB block and zeroing the field in
	# the copy: one 4096-byte allocation per block read.
	#
	checksum:	fn(b: array of byte, skip: int): (int, int);
	get2:		fn(b: array of byte, o: int): int;
	get4:		fn(b: array of byte, o: int): int;
	get8:		fn(b: array of byte, o: int): big;
	put2:		fn(b: array of byte, o: int, v: int);
	put4:		fn(b: array of byte, o: int, v: int);
	put8:		fn(b: array of byte, o: int, v: big);
	superblk:	fn(nblocks: big, which: int): big;
};
