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
	Version:	con 1;

	#
	# An absent block pointer is all ones, NOT zero, because block 0 is
	# a real block -- it holds a superblock.  Limbo's big is a signed
	# 64-bit integer, so all-ones is -1, and that is the value to
	# compare against; it writes out as ff..ff.
	#
	Nilblk:		con big -1;

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

		mount:	fn(name: string, startsect: big): (ref Fs, string);
		getnode: fn(f: self ref Fs, n: big): (ref Node, string);
		leaffor: fn(f: self ref Fs, k: Key): (ref Node, string);
		get:	fn(f: self ref Fs, k: Key): (array of byte, string);
		range:	fn(f: self ref Fs, ino: big, ktype: int):
				(array of Ent, string);
	};

	bitset:		fn(b: array of byte, i: int, v: int);
	bitget:		fn(b: array of byte, i: int): int;

	init:		fn();
	#
	# The checksum is a 32-bit value and it is carried as big, not int.
	# Limbo's int is 32 bits to the compiler and 64 at runtime in this
	# implementation, so a computed 0xffffffff and a literal
	# "int 16rffffffff" print alike and compare unequal.  A checksum
	# that differs between the host and the board is worse than none,
	# so the type that holds all 32 bits without sign games holds it,
	# and get4b/put4b move it.
	#
	checksum:	fn(b: array of byte): big;
	get4b:		fn(b: array of byte, o: int): big;
	put4b:		fn(b: array of byte, o: int, v: big);
	get2:		fn(b: array of byte, o: int): int;
	get4:		fn(b: array of byte, o: int): int;
	get8:		fn(b: array of byte, o: int): big;
	put2:		fn(b: array of byte, o: int, v: int);
	put4:		fn(b: array of byte, o: int, v: int);
	put8:		fn(b: array of byte, o: int, v: big);
	superblk:	fn(nblocks: big, which: int): big;
};
