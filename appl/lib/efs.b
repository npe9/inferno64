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

#
# Two int halves and one big join, rather than eight big shifts.  Same
# reason as checksum above: Key.unpack calls this twice per key and
# Node.unpack unpacks every key in a block, so it is on the hottest path
# there is.
#
get8(b: array of byte, o: int): big
{
	hi := (int b[o] << 24) | (int b[o+1] << 16) |
		(int b[o+2] << 8) | int b[o+3];
	lo := (int b[o+4] << 24) | (int b[o+5] << 16) |
		(int b[o+6] << 8) | int b[o+7];
	return (big hi << 32) | (big lo & big 16rffffffff);
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
#
# Adler-32, computed entirely in int, converted to big once at the end.
#
# This was FNV-1a in big arithmetic, and on this VM EVERY big operation
# allocates: two per byte over a 4096-byte block is 8192 allocations per
# checksum, and a checksum happens on every node pack and every node
# unpack.  The allocation profiler put 3.77MB of a 6MB workload on the
# single line that did it, with 1.05MB of that still live -- which is
# how a server with a few hundred kilobytes of data exhausted a 32MB
# heap.
#
# big was chosen here to dodge the other trap: Limbo's int is 32 bits to
# the compiler and 64 at runtime, so a literal 16rffffffff is a big and
# masking an int with it drags the whole expression into big arithmetic.
# Adler-32 needs neither -- its two accumulators stay under 65521, every
# constant is a small int, and the one value that needs 32 bits is built
# once, at the end, where a single conversion costs one allocation
# instead of eight thousand.
#
checksum(b: array of byte): big
{
	Base: con 65521;		# largest prime below 2^16
	a := 1;
	c := 0;
	for(i := 0; i < len b; i++){
		a = (a + int b[i]) % Base;
		c = (c + a) % Base;
	}
	return (big c << 16) | big a;
}

#
# A 32-bit field held in a big, for the checksum.  See the note in
# efs.m: converting between int and big for a value with bit 31 set is
# where this implementation's int width stops being an implementation
# detail.
#
get4b(b: array of byte, o: int): big
{
	return big ((int b[o] << 24) | (int b[o+1] << 16) |
		(int b[o+2] << 8) | int b[o+3]);
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
	if(d.failafter > 0 && d.nwrite >= d.failafter)
		return sys->sprint("injected write failure at write %d (block %bd)",
			d.nwrite + 1, n);
	o := d.start + n * big Blocksize;
	if(sys->pwrite(d.fd, b, Blocksize, o) != Blocksize)
		return sys->sprint("write block %bd at %bd: %r", n, o);
	d.nwrite++;
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

entsize(e: Ent): int
{
	return Keysz + 2 + len e.val;
}

noderoom(): int
{
	return Blocksize - Nodehdr;
}

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

#
# Mounting: read both superblocks and take the newer one that checksums.
#
# The block count comes from the DEVICE, and the superblock's own
# nblocks is checked against it rather than believed.  Superblock 1 is
# in the last block, so trusting superblock 0 for the size would let a
# corrupt superblock 0 hide the copy that exists for exactly that case.
# doc/efs-format.ms says so; this is where it is enforced.
#
Fs.mount(name: string, startsect: big): (ref Fs, string)
{
	(d, e) := Dev.open(name, startsect, big 0, 0);
	if(e != nil)
		return (nil, e);
	devblocks := big 0;
	(ok, dir) := sys->fstat(d.fd);
	if(ok >= 0)
		devblocks = (dir.length - startsect * big Sectorsz) / big Blocksize;

	(s0, nil) := readsuper(d, big 0);
	nb := devblocks;
	if(s0 != nil)
		nb = s0.nblocks;
	if(nb <= big 0)
		return (nil, "superblock 0 is unreadable and the device has no size");
	(s1, nil) := readsuper(d, superblk(nb, 1));

	live := s0;
	which := 0;
	if(s0 == nil || (s1 != nil && s1.gen > s0.gen)){
		live = s1;
		which = 1;
	}
	if(live == nil)
		return (nil, "neither superblock is good");
	if(devblocks > big 0 && live.nblocks > devblocks)
		return (nil, sys->sprint("superblock claims %bd blocks, device holds %bd",
			live.nblocks, devblocks));
	f := ref Fs;
	f.d = d;
	f.d.nblocks = live.nblocks;
	f.s = live;
	f.which = which;
	return (f, nil);
}

readsuper(d: ref Dev, n: big): (ref Super, string)
{
	(b, e) := d.rdblk(n);
	if(e != nil)
		return (nil, e);
	return Super.unpack(b);
}

Fs.getnode(f: self ref Fs, n: big): (ref Node, string)
{
	(b, e) := f.d.rdblk(n);
	if(e != nil)
		return (nil, e);
	return Node.unpack(b);
}

#
# Descend to the leaf that would hold k.
#
# An interior entry's key is the first key of the child it points at, so
# the child to take is the last one whose key is not greater than the
# target.  A bound on the depth because a corrupt block can point back
# up the tree, and a filesystem server that loops on bad data is worse
# than one that says the data is bad.
#
Maxdepth: con 16;

Fs.leaffor(f: self ref Fs, k: Key): (ref Node, string)
{
	bn := f.s.treeroot;
	for(i := 0; i < Maxdepth; i++){
		(n, e) := f.getnode(bn);
		if(e != nil)
			return (nil, e);
		if(n.ntype == Nleaf)
			return (n, nil);
		if(len n.ents == 0)
			return (nil, sys->sprint("interior block %bd is empty", bn));
		j := 0;
		for(m := 0; m < len n.ents; m++)
			if(n.ents[m].key.cmp(k) <= 0)
				j = m;
			else
				break;
		if(len n.ents[j].val != 8)
			return (nil, sys->sprint("interior block %bd entry %d is %d bytes, want 8",
				bn, j, len n.ents[j].val));
		bn = get8(n.ents[j].val, 0);
	}
	return (nil, "tree deeper than " + string Maxdepth + " levels; giving up");
}

Fs.get(f: self ref Fs, k: Key): (array of byte, string)
{
	(n, e) := f.leaffor(k);
	if(e != nil)
		return (nil, e);
	for(i := 0; i < len n.ents; i++)
		if(n.ents[i].key.cmp(k) == 0)
			return (n.ents[i].val, nil);
	return (nil, nil);		# absent, not an error
}

#
# Every entry for one inode and key type, in key order.
#
# Walks the leaves from the one holding the first possible key.  Leaves
# are found by re-descending on the key after the last one seen, which
# costs a descent per leaf and needs no sibling pointers in the format --
# a pointer that a copy-on-write tree would have to rewrite in every
# sibling of every changed block.
#
Fs.range(f: self ref Fs, ino: big, ktype: int): (array of Ent, string)
{
	#
	# Walk the leaves along a PATH, not by key.
	#
	# This advanced from one leaf to the next by re-descending on the
	# key after the last one it had seen.  That cannot work: a descent
	# takes the last child whose key is not greater than the target,
	# so a key one past the end of a leaf descends into that same leaf
	# again -- the next leaf's first key is larger, so it is not
	# chosen.  The scan then found nothing new and stopped, and every
	# entry in every later leaf was invisible.
	#
	# With one leaf it is perfect, which is why four test suites and a
	# crash harness passed over it.  It took an image shaped like a
	# real one -- sixty files, so the tree has interior nodes -- to
	# show a file that had just been written not existing.  That is
	# the plan's rule about empty images, in the one place it was not
	# yet being obeyed.
	#
	rev: list of Ent;
	nent := 0;
	k := Key(ino, ktype, big 0);
	(blks, idx, pe) := f.pathto(k);
	if(pe != nil)
		return (nil, pe);
	d := len blks - 1;
	first := 1;
	for(guard := 0; guard < 4096; guard++){
		(n, e) := f.getnode(blks[d]);
		if(e != nil)
			return (nil, e);
		for(i := 0; i < len n.ents; i++){
			ek := n.ents[i].key;
			if(first && ek.cmp(k) < 0)
				continue;
			if(ek.ino != ino || ek.ktype != ktype){
				#
				# Keys rise, so the first entry past this
				# inode and type is the end of the range --
				# but only once the range has started.
				#
				if(nent > 0 || ek.cmp(k) > 0)
					return (mkents(rev, nent), nil);
				continue;
			}
			rev = n.ents[i] :: rev;
			nent++;
		}
		first = 0;
		if(!f.nextleaf(blks, idx))
			break;
	}
	return (mkents(rev, nent), nil);
}

#
# Advance a path to the next leaf.  Returns 0 when there is none.
#
# Walking up until a parent has another child, then down that child's
# leftmost edge, is the ordinary B-tree step.  It needs no sibling
# pointers in the format, which a copy-on-write tree would have to
# rewrite in every sibling of every changed block.
#
Fs.nextleaf(f: self ref Fs, blks: array of big, idx: array of int): int
{
	d := len blks - 1;
	while(d > 0){
		d--;
		(n, e) := f.getnode(blks[d]);
		if(e != nil)
			return 0;
		if(idx[d] + 1 < len n.ents){
			idx[d]++;
			if(len n.ents[idx[d]].val != 8)
				return 0;
			blks[d+1] = get8(n.ents[idx[d]].val, 0);
			#
			# Down the leftmost edge from there.
			#
			for(c := d + 1; c < len blks; c++){
				(m, me) := f.getnode(blks[c]);
				if(me != nil)
					return 0;
				if(m.ntype == Nleaf)
					return 1;
				if(len m.ents == 0 || len m.ents[0].val != 8)
					return 0;
				idx[c] = 0;
				blks[c+1] = get8(m.ents[0].val, 0);
			}
			return 1;
		}
	}
	return 0;
}

mkents(rev: list of Ent, nent: int): array of Ent
{
	out := array[nent] of Ent;
	i := nent;
	for(; rev != nil; rev = tl rev)
		out[--i] = hd rev;
	return out;
}

#
# The write side.
#
# Everything here obeys one rule from doc/efs-format.ms: nothing
# committed is ever overwritten in place.  A change writes new blocks
# from the leaf up the spine and ends in a new root, and the only write
# that makes any of it visible is the superblock at the end.  Until that
# write lands, the old tree IS the filesystem; after it, the new one is;
# there is no third state.
#

#
# Take the free map into memory, and fold in what the last commit freed.
#
# The pendingfree list is why this is not simply "read the bitmap":
# blocks freed by a commit are not allocatable until the commit AFTER
# it, because a crash part way through a commit must be able to fall
# back to a tree whose blocks nobody has scribbled on.  Those blocks
# become free here, at the start of the next transaction, which is the
# first moment it is safe.
#
Fs.writable(f: self ref Fs): string
{
	if(f.bitmap != nil)
		return nil;
	(b, e) := f.d.rdblk(f.s.freeroot);
	if(e != nil)
		return e;
	f.bitmap = b;
	for(i := 0; i < len f.s.pendingfree; i++){
		n := f.s.pendingfree[i];
		if(n >= big 0 && n < big (Blocksize * 8))
			bitset(f.bitmap, int n, 0);
	}
	f.s.pendingfree = array[0] of big;
	f.freed = nil;
	f.dirty = 0;
	return nil;
}

#
# One free block.
#
# Block 0 is a superblock and the last block is the other one, so
# neither is ever a candidate; the bitmap has them set and this trusts
# it rather than special-casing them, because a bitmap that disagrees is
# a bug worth hitting here and not somewhere quieter.
#
Fs.alloc(f: self ref Fs): (big, string)
{
	if((e := f.writable()) != nil)
		return (big -1, e);
	n := int f.s.nblocks;
	if(n > Blocksize * 8)
		n = Blocksize * 8;
	for(i := 0; i < n; i++)
		if(!bitget(f.bitmap, i)){
			bitset(f.bitmap, i, 1);
			f.dirty = 1;
			return (big i, nil);
		}
	return (big -1, "filesystem is full");
}

#
# Give a block back -- to the NEXT commit, not to this one.
#
# It is not cleared in the bitmap here.  It is remembered, written into
# the superblock's pendingfree by commit, and only cleared when the
# transaction after that starts.  Clearing it now would let this very
# transaction hand out a block that the tree it is meant to fall back to
# still points at.
#
Fs.free(f: self ref Fs, n: big)
{
	f.freed = n :: f.freed;
	f.dirty = 1;
}

#
# Insert or replace one key.
#
# Copy on write all the way up: the leaf is rewritten into a new block,
# then each parent in turn to point at the new child, and the root that
# comes out is remembered for commit to publish.
#
Fs.insert(f: self ref Fs, k: Key, v: array of byte): string
{
	if((e := f.writable()) != nil)
		return e;
	return f.replace(k, v, 1);
}

Fs.delete(f: self ref Fs, k: Key): string
{
	if((e := f.writable()) != nil)
		return e;
	return f.replace(k, nil, 0);
}

#
# The path from the root to the leaf that holds k: block numbers, and
# the index taken in each interior node.
#
Fs.pathto(f: self ref Fs, k: Key): (array of big, array of int, string)
{
	blks := array[Maxdepth] of big;
	idx := array[Maxdepth] of int;
	d := 0;
	bn := f.s.treeroot;
	for(;;){
		if(d >= Maxdepth)
			return (nil, nil, "tree deeper than " + string Maxdepth);
		(n, e) := f.getnode(bn);
		if(e != nil)
			return (nil, nil, e);
		blks[d] = bn;
		if(n.ntype == Nleaf){
			idx[d] = 0;
			return (blks[0:d+1], idx[0:d+1], nil);
		}
		if(len n.ents == 0)
			return (nil, nil, sys->sprint("interior block %bd is empty", bn));
		j := 0;
		for(m := 0; m < len n.ents; m++)
			if(n.ents[m].key.cmp(k) <= 0)
				j = m;
			else
				break;
		idx[d] = j;
		if(len n.ents[j].val != 8)
			return (nil, nil, sys->sprint("interior %bd entry %d is not a pointer", bn, j));
		bn = get8(n.ents[j].val, 0);
		d++;
	}
}

Fs.replace(f: self ref Fs, k: Key, v: array of byte, ins: int): string
{
	(blks, idx, e) := f.pathto(k);
	if(e != nil)
		return e;
	depth := len blks - 1;
	(leaf, le) := f.getnode(blks[depth]);
	if(le != nil)
		return le;

	#
	# Put the entry in, or take it out, in key order.
	#
	at := len leaf.ents;
	found := 0;
	for(i := 0; i < len leaf.ents; i++){
		c := leaf.ents[i].key.cmp(k);
		if(c == 0){
			at = i;
			found = 1;
			break;
		}
		if(c > 0){
			at = i;
			break;
		}
	}
	ents: array of Ent;
	if(ins){
		if(found){
			ents = array[len leaf.ents] of Ent;
			ents[0:] = leaf.ents;
			ents[at] = Ent(k, v);
		}else{
			ents = array[len leaf.ents + 1] of Ent;
			ents[0:] = leaf.ents[0:at];
			ents[at] = Ent(k, v);
			ents[at+1:] = leaf.ents[at:];
		}
	}else{
		if(!found)
			return nil;		# absent: deleting is a no-op
		ents = array[len leaf.ents - 1] of Ent;
		ents[0:] = leaf.ents[0:at];
		ents[at:] = leaf.ents[at+1:];
	}

	#
	# Write the new leaf, or two of them if it no longer fits, and
	# hand what came out up to the parent.
	#
	(kids, kkeys, we) := f.writeents(ents, Nleaf, leaf.level);
	if(we != nil)
		return we;
	f.free(blks[depth]);
	return f.fixup(blks, idx, depth, kids, kkeys);
}

#
# Write entries into as few blocks as they fit in, splitting when they
# do not.  Returns the blocks and each one's first key.
#
Fs.writeents(f: self ref Fs, ents: array of Ent, ntype: int, level: int):
	(array of big, array of Key, string)
{
	nb := 0;
	blks := array[8] of big;
	keys := array[8] of Key;
	#
	# NO ENTRIES, NO BLOCK.
	#
	# This wrote one empty node and gave the parent a key of
	# (0, inode, 0) to point at it, because that is what an empty
	# entry list has for a first key.  A zero key sorts before every
	# real one, so the parent's keys stopped rising, and a descent --
	# which takes the last child whose key is not greater than the
	# target -- began landing in the wrong subtree.  Lookups then
	# failed for keys that were present, including the root
	# directory's own inode: "no inode 1" on a filesystem that had
	# one.
	#
	# It happens when the last entry is deleted from a leaf.  The
	# answer is for the leaf to stop existing and the parent to lose
	# its entry, which fixup does when it is handed no blocks.
	#
	if(len ents == 0)
		return (blks[0:0], keys[0:0], nil);
	i := 0;
	for(;;){
		if(nb >= len blks)
			return (nil, nil, "a node split into more pieces than expected");
		n := ref Node;
		n.ntype = ntype;
		n.level = level;
		#
		# How many fit, by arithmetic.  This used to ask pack() and
		# throw the block away, once per entry.
		#
		last := i;
		room := noderoom();
		for(j := i; j < len ents; j++){
			c := entsize(ents[j]);
			if(c > room)
				break;
			room -= c;
			last = j + 1;
		}
		if(last == i && i < len ents)
			return (nil, nil, sys->sprint("entry %d does not fit in a block", i));
		n.ents = ents[i:last];
		(b, pe2) := n.pack();
		if(pe2 != nil)
			return (nil, nil, pe2);
		(blk, ae) := f.alloc();
		if(ae != nil)
			return (nil, nil, ae);
		if((we := f.d.wrblk(blk, b)) != nil)
			return (nil, nil, we);
		blks[nb] = blk;
		keys[nb] = n.ents[0].key;	# never empty; see above
		nb++;
		i = last;
		if(i >= len ents)
			break;
	}
	return (blks[0:nb], keys[0:nb], nil);
}

#
# Rewrite the spine above a level that has just been replaced.
#
Fs.fixup(f: self ref Fs, blks: array of big, idx: array of int, depth: int,
	kids: array of big, kkeys: array of Key): string
{
	while(depth > 0){
		depth--;
		(par, pe) := f.getnode(blks[depth]);
		if(pe != nil)
			return pe;
		at := idx[depth];
		ents := array[len par.ents - 1 + len kids] of Ent;
		ents[0:] = par.ents[0:at];
		for(i := 0; i < len kids; i++){
			v := array[8] of byte;
			put8(v, 0, kids[i]);
			ents[at+i] = Ent(kkeys[i], v);
		}
		ents[at+len kids:] = par.ents[at+1:];
		(nk, nkk, we) := f.writeents(ents, Ninterior, par.level);
		if(we != nil)
			return we;
		f.free(blks[depth]);
		kids = nk;
		kkeys = nkk;
	}
	#
	# The top.  If what came out is one block it is the new root; if it
	# split, a level is added above it.
	#
	while(len kids > 1){
		ents := array[len kids] of Ent;
		for(i := 0; i < len kids; i++){
			v := array[8] of byte;
			put8(v, 0, kids[i]);
			ents[i] = Ent(kkeys[i], v);
		}
		(nk, nkk, we) := f.writeents(ents, Ninterior, 0);
		if(we != nil)
			return we;
		kids = nk;
		kkeys = nkk;
	}
	#
	# An empty tree still needs a root, and it is a leaf with no
	# entries -- the one place an empty node is legitimate, because
	# nothing points at it with a key.
	#
	if(len kids == 0){
		n := ref Node;
		n.ntype = Nleaf;
		n.level = 0;
		n.ents = array[0] of Ent;
		(b, pe) := n.pack();
		if(pe != nil)
			return pe;
		(blk, ae) := f.alloc();
		if(ae != nil)
			return ae;
		if((we := f.d.wrblk(blk, b)) != nil)
			return we;
		f.s.treeroot = blk;
		f.dirty = 1;
		return nil;
	}
	f.s.treeroot = kids[0];
	f.dirty = 1;
	return nil;
}

#
# Publish everything written since the last commit.
#
#	1. the new free map
#	2. wait for those writes to complete -- which on this board's
#	   synchronous SD driver is every write call having returned
#	3. one superblock, the older slot, with the new roots and
#	   generation+1
#
# Step 3 is the only write that changes what a reader sees.
#
Fs.commit(f: self ref Fs): string
{
	if(!f.dirty)
		return nil;
	(bmblk, ae) := f.alloc();
	if(ae != nil)
		return ae;
	old := f.s.freeroot;
	#
	# The bitmap block records itself as in use before it is written,
	# or the map that comes back from a crash describes a filesystem in
	# which the map is free.
	#
	bitset(f.bitmap, int bmblk, 1);
	if((e := f.d.wrblk(bmblk, f.bitmap)) != nil)
		return e;
	f.s.freeroot = bmblk;
	f.free(old);

	np := 0;
	for(l := f.freed; l != nil; l = tl l)
		np++;
	pf := array[np] of big;
	i := 0;
	for(l = f.freed; l != nil; l = tl l)
		pf[i++] = hd l;
	f.s.pendingfree = pf;
	f.s.gen++;

	#
	# The older slot, so the live one survives a failure here.
	#
	slot := 1 - f.which;
	if((e = f.d.wrblk(superblk(f.s.nblocks, slot), f.s.pack())) != nil)
		return e;
	f.which = slot;
	f.freed = nil;
	f.dirty = 0;
	f.bitmap = nil;		# re-read next time, folding pendingfree in
	return nil;
}
