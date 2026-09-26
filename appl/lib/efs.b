implement Efs;

#
# efs: the on-disk format.  doc/efs-format.ms is the specification.
#
include "sys.m";
	sys: Sys;
include "efs.m";

init()
{
	sys = load Sys Sys->PATH;
}

#
# Integers on disk are BIG endian, all of them, and they go through
# these six functions and no others.
#
# This is the format's second non-negotiable rule in force: a block
# number is one width everywhere, read and written by one pair of
# functions.  FAT32 keeps the halves of a start cluster in different
# fields and this tree has fixed that truncation three times.  Nothing
# here assembles a number from halves.
#
get2(b: array of byte, o: int): int
{
	return (int b[o] << 8) | int b[o+1];
}

get4(b: array of byte, o: int): int
{
	return (int b[o] << 24) | (int b[o+1] << 16) |
		(int b[o+2] << 8) | int b[o+3];
}

get8(b: array of byte, o: int): big
{
	v := big 0;
	for(i := 0; i < 8; i++)
		v = (v << 8) | big int b[o+i];
	return v;
}

put2(b: array of byte, o: int, v: int)
{
	b[o] = byte (v >> 8);
	b[o+1] = byte v;
}

put4(b: array of byte, o: int, v: int)
{
	b[o] = byte (v >> 24);
	b[o+1] = byte (v >> 16);
	b[o+2] = byte (v >> 8);
	b[o+3] = byte v;
}

put8(b: array of byte, o: int, v: big)
{
	for(i := 0; i < 8; i++)
		b[o+i] = byte int ((v >> ((7 - i) * 8)) & big 16rff);
}

#
# Where the two superblocks live: block 0 and the last block.
#
# Not 0 and 1.  A card erases in units far larger than 4KB, so two
# adjacent blocks are plausibly inside one erase block and a single
# failed erase would take both copies of the only structure that makes
# recovery possible.
#
superblk(nblocks: big, which: int): big
{
	if(which == 0)
		return big 0;
	return nblocks - big 1;
}

#
# A checksum, not a hash: it is here to say WHICH block is wrong, not to
# resist anybody.  FNV-1a over the block, which is a few instructions a
# byte and needs no table.
#
# int is 64 bits at runtime in this implementation, so the accumulator is
# masked back to 32 bits at every step rather than at the end; otherwise
# the value depends on the word size of whoever computed it, and a
# checksum that differs between the host and the board is worse than
# none.
#
checksum(b: array of byte): big
{
	M32: con big 16rffffffff;
	h := big 16r811c9dc5;
	for(i := 0; i < len b; i++){
		h = (h ^ big int b[i]) & M32;
		h = (h * big 16r01000193) & M32;
	}
	return h;
}

#
# A 32-bit field held in a big, for the checksum.  See the note in
# efs.m: converting between int and big for a value with bit 31 set is
# where this implementation's int width stops being an implementation
# detail.
#
get4b(b: array of byte, o: int): big
{
	v := big 0;
	for(i := 0; i < 4; i++)
		v = (v << 8) | big int b[o+i];
	return v;
}

put4b(b: array of byte, o: int, v: big)
{
	for(i := 0; i < 4; i++)
		b[o+i] = byte int ((v >> ((3 - i) * 8)) & big 16rff);
}

#
# The superblock, packed into one block.
#
# Layout, byte offsets, from doc/efs-format.ms:
#
#	 0	magic, 8 bytes
#	 8	version, 4
#	12	blocksize, 4
#	16	generation, 8
#	24	nblocks, 8
#	32	treeroot, 8
#	40	freeroot, 8
#	48	nextino, 8
#	56	npendingfree, 4
#	60	checksum, 4		(computed with this field zero)
#	64	pendingfree[], 8 each
#
Socksum: con 60;
Sopend: con 64;

Super.pack(s: self ref Super): array of byte
{
	b := array[Blocksize] of {* => byte 0};
	b[0:] = array of byte Magic;
	put4(b, 8, s.version);
	put4(b, 12, s.blocksize);
	put8(b, 16, s.gen);
	put8(b, 24, s.nblocks);
	put8(b, 32, s.treeroot);
	put8(b, 40, s.freeroot);
	put8(b, 48, s.nextino);
	np := len s.pendingfree;
	#
	# Bounded by the block, and the format says an overlong list spills
	# to a block of its own.  Nothing generates one yet, so refusing is
	# honest where silently truncating would not be.
	#
	if(Sopend + np * 8 > Blocksize)
		np = (Blocksize - Sopend) / 8;
	put4(b, 56, np);
	for(i := 0; i < np; i++)
		put8(b, Sopend + i * 8, s.pendingfree[i]);
	put4b(b, Socksum, checksum(b));
	return b;
}

Super.unpack(b: array of byte): (ref Super, string)
{
	if(len b != Blocksize)
		return (nil, sys->sprint("superblock is %d bytes, want %d",
			len b, Blocksize));
	if(string b[0:Magicsz] != Magic)
		return (nil, "not an efs filesystem (bad magic)");
	#
	# Check the sum before believing any other field, and check it the
	# way it was made: over the whole block with the sum itself zero.
	#
	want := get4b(b, Socksum);
	c := array[Blocksize] of byte;
	c[0:] = b;
	put4b(c, Socksum, big 0);
	got := checksum(c);
	if(got != want)
		return (nil, sys->sprint("superblock checksum %bux, want %bux",
			got, want));
	s := ref Super;
	s.version = get4(b, 8);
	s.blocksize = get4(b, 12);
	s.gen = get8(b, 16);
	s.nblocks = get8(b, 24);
	s.treeroot = get8(b, 32);
	s.freeroot = get8(b, 40);
	s.nextino = get8(b, 48);
	if(s.version != Version)
		return (nil, sys->sprint("version %d, this is version %d",
			s.version, Version));
	if(s.blocksize != Blocksize)
		return (nil, sys->sprint("block size %d, this build uses %d",
			s.blocksize, Blocksize));
	np := get4(b, 56);
	if(np < 0 || Sopend + np * 8 > Blocksize)
		return (nil, sys->sprint("pendingfree count %d does not fit", np));
	s.pendingfree = array[np] of big;
	for(i := 0; i < np; i++)
		s.pendingfree[i] = get8(b, Sopend + i * 8);
	return (s, nil);
}

#
# The device.  Block numbers are relative to the start of the
# filesystem, and the conversion to a byte offset happens here and
# nowhere else.
#
Dev.open(name: string, startsect: big, nblocks: big, create: int): (ref Dev, string)
{
	mode := Sys->ORDWR;
	fd: ref Sys->FD;
	if(create){
		fd = sys->create(name, mode, 8r666);
		if(fd == nil)
			return (nil, sys->sprint("create %s: %r", name));
	}else{
		fd = sys->open(name, mode);
		if(fd == nil){
			fd = sys->open(name, Sys->OREAD);
			if(fd == nil)
				return (nil, sys->sprint("open %s: %r", name));
		}
	}
	d := ref Dev;
	d.fd = fd;
	d.start = startsect * big Sectorsz;
	d.nblocks = nblocks;
	d.name = name;
	return (d, nil);
}

Dev.rdblk(d: self ref Dev, n: big): (array of byte, string)
{
	if(n < big 0 || (d.nblocks > big 0 && n >= d.nblocks))
		return (nil, sys->sprint("block %bd outside %bd", n, d.nblocks));
	b := array[Blocksize] of byte;
	o := d.start + n * big Blocksize;
	nr := sys->pread(d.fd, b, Blocksize, o);
	if(nr != Blocksize)
		return (nil, sys->sprint("read block %bd at %bd: %r", n, o));
	return (b, nil);
}

Dev.wrblk(d: self ref Dev, n: big, b: array of byte): string
{
	if(len b != Blocksize)
		return sys->sprint("write block %bd: %d bytes, want %d",
			n, len b, Blocksize);
	if(n < big 0 || (d.nblocks > big 0 && n >= d.nblocks))
		return sys->sprint("block %bd outside %bd", n, d.nblocks);
	o := d.start + n * big Blocksize;
	if(sys->pwrite(d.fd, b, Blocksize, o) != Blocksize)
		return sys->sprint("write block %bd at %bd: %r", n, o);
	return nil;
}

#
# Keys.
#
Key.pack(k: self Key, b: array of byte, o: int)
{
	put8(b, o, k.ino);
	b[o+8] = byte k.ktype;
	put8(b, o+9, k.off);
}

Key.unpack(b: array of byte, o: int): Key
{
	return Key(get8(b, o), int b[o+8], get8(b, o+9));
}

Key.cmp(k: self Key, j: Key): int
{
	if(k.ino < j.ino)
		return -1;
	if(k.ino > j.ino)
		return 1;
	if(k.ktype != j.ktype)
		return k.ktype - j.ktype;
	if(k.off < j.off)
		return -1;
	if(k.off > j.off)
		return 1;
	return 0;
}

Key.text(k: self Key): string
{
	t := "?";
	case k.ktype {
	Kinode =>	t = "inode";
	Kdentry =>	t = "dentry";
	Kextent =>	t = "extent";
	}
	return sys->sprint("(%bd %s %bd)", k.ino, t, k.off);
}

#
# An inode record.
#
#	 0	mode, 4
#	 4	nlink, 4
#	 8	length, 8
#	16	atime, 4
#	20	mtime, 4
#	24	uid length, 2
#	26	uid
#	..	gid length, 2
#	..	gid
#
# uid and gid are strings in the record, so there is no user table to
# lose -- which is one of the things kfs invents at ream time.
#
Inode.pack(i: self ref Inode): array of byte
{
	u := array of byte i.uid;
	g := array of byte i.gid;
	b := array[28 + len u + len g] of {* => byte 0};
	put4(b, 0, i.mode);
	put4(b, 4, i.nlink);
	put8(b, 8, i.length);
	put4(b, 16, i.atime);
	put4(b, 20, i.mtime);
	put2(b, 24, len u);
	b[26:] = u;
	put2(b, 26 + len u, len g);
	b[28 + len u:] = g;
	return b;
}

Inode.unpack(b: array of byte): (ref Inode, string)
{
	if(len b < 28)
		return (nil, sys->sprint("inode record is %d bytes", len b));
	i := ref Inode;
	i.mode = get4(b, 0);
	i.nlink = get4(b, 4);
	i.length = get8(b, 8);
	i.atime = get4(b, 16);
	i.mtime = get4(b, 20);
	nu := get2(b, 24);
	if(26 + nu + 2 > len b)
		return (nil, "inode record: uid runs past the end");
	i.uid = string b[26:26+nu];
	ng := get2(b, 26 + nu);
	if(28 + nu + ng > len b)
		return (nil, "inode record: gid runs past the end");
	i.gid = string b[28+nu:28+nu+ng];
	return (i, nil);
}

#
# A tree block.
#
#	0	type, 1
#	1	level, 1
#	2	nents, 2
#	4	checksum, 4	(computed with this field zero)
#	8	entries: key[17] vallen[2] value
#
Nocksum: con 4;
Noents: con 8;

Node.pack(n: self ref Node): (array of byte, string)
{
	b := array[Blocksize] of {* => byte 0};
	b[0] = byte n.ntype;
	b[1] = byte n.level;
	put2(b, 2, len n.ents);
	o := Noents;
	for(i := 0; i < len n.ents; i++){
		e := n.ents[i];
		if(o + Keysz + 2 + len e.val > Blocksize)
			return (nil, sys->sprint("node: entry %d does not fit", i));
		e.key.pack(b, o);
		o += Keysz;
		put2(b, o, len e.val);
		o += 2;
		b[o:] = e.val;
		o += len e.val;
	}
	put4b(b, Nocksum, checksum(b));
	return (b, nil);
}

Node.unpack(b: array of byte): (ref Node, string)
{
	if(len b != Blocksize)
		return (nil, sys->sprint("node is %d bytes", len b));
	want := get4b(b, Nocksum);
	c := array[Blocksize] of byte;
	c[0:] = b;
	put4b(c, Nocksum, big 0);
	got := checksum(c);
	if(got != want)
		return (nil, sys->sprint("node checksum %bux, want %bux", got, want));
	n := ref Node;
	n.ntype = int b[0];
	n.level = int b[1];
	ne := get2(b, 2);
	if(ne < 0)
		return (nil, "node: negative entry count");
	n.ents = array[ne] of Ent;
	o := Noents;
	for(i := 0; i < ne; i++){
		if(o + Keysz + 2 > Blocksize)
			return (nil, sys->sprint("node: entry %d header past the end", i));
		k := Key.unpack(b, o);
		o += Keysz;
		vl := get2(b, o);
		o += 2;
		if(vl < 0 || o + vl > Blocksize)
			return (nil, sys->sprint("node: entry %d value past the end", i));
		#
		# COPIED, not sliced.  A Limbo slice shares the array it came
		# from, so an entry that pointed into this buffer would be a
		# window on whatever block the buffer next held.
		#
		v := array[vl] of byte;
		v[0:] = b[o:o+vl];
		o += vl;
		n.ents[i] = Ent(k, v);
	}
	return (n, nil);
}

bitset(b: array of byte, i: int, v: int)
{
	m := byte (1 << (i & 7));
	if(v)
		b[i >> 3] |= m;
	else
		b[i >> 3] &= ~m;
}

bitget(b: array of byte, i: int): int
{
	if((int b[i >> 3] & (1 << (i & 7))) != 0)
		return 1;
	return 0;
}
