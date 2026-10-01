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
checksum(b: array of byte, skip: int): (int, int)
{
	Base: con 65521;		# largest prime below 2^16
	a := 1;
	c := 0;
	for(i := 0; i < len b; i++){
		#
		# The four bytes at skip read as zero.  Adler still has to
		# STEP over them -- a zero byte changes c -- so they are
		# summed as zero rather than passed over.
		#
		v := 0;
		if(skip < 0 || i < skip || i >= skip + 4)
			v = int b[i];
		a = (a + v) % Base;
		c = (c + a) % Base;
	}
	return (a, c);
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
	# Bounded by the block, and this cap is NOT how the bound is
	# enforced -- Fs.commit is, by carrying what does not fit into the
	# next commit.
	#
	# The comment here used to say that refusing was honest where
	# truncating would not be, and then truncated: everything past
	# entry 504 was dropped, so a commit that freed more blocks than
	# that -- removing a file of more than about 2MB does it -- leaked
	# every one of them permanently, and efsck reported them as "marked
	# used and not reached (not an error)".  A comment claiming the
	# opposite of the code is worse than no comment.
	#
	# It stays as a last line of defence, because writing past the end
	# of the block would be worse, and it is now unreachable.
	#
	if(np > maxpending())
		np = maxpending();
	put4(b, 56, np);
	for(i := 0; i < np; i++)
		put8(b, Sopend + i * 8, s.pendingfree[i]);
	(a, c) := checksum(b, Socksum);
	put2(b, Socksum, c);
	put2(b, Socksum + 2, a);
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
	(a, c) := checksum(b, Socksum);
	if(c != get2(b, Socksum) || a != get2(b, Socksum + 2))
		return (nil, sys->sprint("superblock checksum %ux %ux, want %ux %ux",
			c, a, get2(b, Socksum), get2(b, Socksum + 2)));
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
		#
		# OPEN an existing one, and only create what is not there.
		#
		# The target of a real mkfs is a partition, and create on a
		# device is at best meaningless and at worst destructive.
		# Trying open first means mkefs on the board addresses the
		# card through the same path as everything else, and mkefs
		# on a host image still makes the image.
		#
		fd = sys->open(name, mode);
		if(fd == nil)
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
	#
	# Again, every field, and the two that look like they must already
	# be zero are the ones that matter.
	#
	# nwrite and failafter are the crash harness's write injection, and
	# on this VM a "ref Dev" hands them whatever was in that memory.
	# A fresh mkefs of a 32769-block image printed
	#
	#	mkefs: injected write failure at write 540620344 (block 4)
	#
	# and left an image with no superblock -- a program that has no
	# injection flag, refusing its own write, for a reason that reads
	# as a bug in the free map it was writing at the time.  This was
	# latent long before the map changed: every run of every efs
	# program has been one stale word away from it, and the crash
	# harness passed 16 of 16 because it sets failafter explicitly.
	#
	# See Fs.mount for the same rule and the probe that established it.
	#
	d := ref Dev;
	d.fd = fd;
	d.start = startsect * big Sectorsz;
	d.nblocks = nblocks;
	d.name = name;
	d.nwrite = 0;
	d.failafter = 0;
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
	(a, c) := checksum(b, Nocksum);
	put2(b, Nocksum, c);
	put2(b, Nocksum + 2, a);
	return (b, nil);
}

Node.unpack(b: array of byte): (ref Node, string)
{
	if(len b != Blocksize)
		return (nil, sys->sprint("node is %d bytes", len b));
	(a, c) := checksum(b, Nocksum);
	if(c != get2(b, Nocksum) || a != get2(b, Nocksum + 2))
		return (nil, sys->sprint("node checksum %ux %ux, want %ux %ux",
			c, a, get2(b, Nocksum), get2(b, Nocksum + 2)));
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
		v := b[o:o+vl];
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

ngroups(nblocks: big): int
{
	return int ((nblocks + big (Bitsperblk - 1)) / big Bitsperblk);
}

maxpending(): int
{
	return (Blocksize - Sopend) / 8;
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
#
# Can the tree this superblock names be reached at all?
#
# Two superblocks exist so that a commit interrupted part way through can
# be fallen back from -- Fs.alloc says exactly that: "a crash part way
# through a commit must be able to fall back".  Nothing provided the
# fallback.  Fs.mount chose the higher-generation READABLE SUPERBLOCK and
# never asked whether the tree that superblock names could be read, so a
# superblock whose tree was incomplete was preferred over an older one
# whose tree was whole, and the older one was never reached.
#
# That is not hypothetical.  A Pi 3B came up with:
#
#	efs: /n/dos/efs.img: 16384 blocks, generation 978 from superblock 1
#	efs: mount /n/efs: node checksum 1000 1, want 0 0
#
# and efsck on the same image found block 6521 reading back as 4096 zero
# bytes while the live superblock's tree still named it, plus two more
# blocks the committed free map called free.  Generation 977, in the
# other slot, was never tried.
#
# WHAT THIS CHECKS, AND WHAT IT DOES NOT.  It reads the free map index
# and unpacks the tree root: the spine mount itself needs.  It is NOT a
# proof that the whole tree is sound -- that is efsck's job and it costs
# a pass over every block, some 40 seconds on the board's 64MB image,
# which is not something to put in front of every mount.  So this
# catches a superblock whose own root or free map did not land, and a
# deeper hole still surfaces later as it did above.  Saying so here
# matters more than the check does: a cheap check that reads like a
# guarantee is how the next person stops running efsck.
#
spineok(d: ref Dev, s: ref Super): string
{
	if(s.freeroot != Nilblk){
		(nil, fe) := d.rdblk(s.freeroot);
		if(fe != nil)
			return sys->sprint("free map index: %s", fe);
	}
	if(s.treeroot != Nilblk){
		(b, te) := d.rdblk(s.treeroot);
		if(te != nil)
			return sys->sprint("tree root: %s", te);
		(nil, ue) := Node.unpack(b);
		if(ue != nil)
			return sys->sprint("tree root: %s", ue);
	}
	return nil;
}

Fs.mount(name: string, startsect: big): (ref Fs, string)
{
	return Fs.mountsuper(name, startsect, -1);
}

Fs.mountsuper(name: string, startsect: big, want: int): (ref Fs, string)
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
	#
	# Forced: take the one asked for and say nothing about the other.
	# A caller that names a superblock is diagnosing, and silently
	# giving it the good one would destroy the only measurement it
	# came for.
	#
	if(want == 0 || want == 1){
		if(want == 0)
			live = s0;
		else
			live = s1;
		which = want;
		if(live == nil)
			return (nil, sys->sprint("superblock %d is unreadable", want));
	}else{
		if(live == nil)
			return (nil, "neither superblock is good");
		#
		# Prefer the newer, but only if its tree is there.  The
		# older one is tried second and ONLY on a real fallback,
		# so "generation N from superblock W" in efs(1)'s banner
		# still says which one is in use.
		#
		if((se := spineok(d, live)) != nil){
			other := s1;
			oth := 1;
			if(which == 1){
				other = s0;
				oth = 0;
			}
			if(other == nil)
				return (nil, sys->sprint(
					"superblock %d (generation %bd) has no tree (%s), and superblock %d is unreadable",
					which, live.gen, se, oth));
			if((oe := spineok(d, other)) != nil)
				return (nil, sys->sprint(
					"neither tree can be reached: superblock %d (generation %bd) %s, superblock %d (generation %bd) %s",
					which, live.gen, se, oth, other.gen, oe));
			sys->fprint(sys->fildes(2),
				"efs: %s: superblock %d (generation %bd) has no tree (%s); falling back to superblock %d (generation %bd)\n",
				name, which, live.gen, se, oth, other.gen);
			live = other;
			which = oth;
		}
	}
	if(devblocks > big 0 && live.nblocks > devblocks)
		return (nil, sys->sprint("superblock claims %bd blocks, device holds %bd",
			live.nblocks, devblocks));
	#
	# EVERY field, explicitly, including the ones that look like they
	# are already zero.
	#
	# "ref Fs" does NOT reliably zero an adt's scalar fields in this
	# implementation.  A probe that printed f.cursor at this point read
	# 0, 0 and then 18193664 over three otherwise identical runs, and
	# the third one sent the allocator to block 18193664 of a
	# 256-block filesystem.  It is the same rule as array[N] holding
	# stale data -- which this tree has already been bitten by and
	# written down -- and it applies to a ref adt as well: pointer
	# fields must be zeroed because the collector walks them, and
	# nothing else must be.
	#
	# The symptom was a filesystem that wrote correctly two runs out of
	# three and failed the third with a block number nowhere near the
	# device, which reads exactly like a bug in the new free map.
	#
	f := ref Fs;
	f.d = d;
	f.d.nblocks = live.nblocks;
	f.s = live;
	f.which = which;
	f.bmindex = nil;
	f.groups = nil;
	f.gdirty = nil;
	f.repl = nil;
	f.idxblk = Nilblk;
	f.cursor = 0;
	f.cblk = nil;
	f.cnode = nil;
	f.cnext = 0;
	f.freed = nil;
	f.dirty = 0;
	return (f, nil);
}

readsuper(d: ref Dev, n: big): (ref Super, string)
{
	(b, e) := d.rdblk(n);
	if(e != nil)
		return (nil, e);
	return Super.unpack(b);
}

#
# One decoded node, from the cache if it is there.
#
# Node.unpack is the most expensive thing this library does per call: it
# allocates a Node, an entry array and a COPY of every entry's value,
# because an entry that pointed into the block buffer would be a window
# on whatever that buffer held next.  mprof put 1.15MB of a 2.4MB
# workload on it, and it was being paid more than once for the same
# block -- Fs.replace walks to the leaf through pathto, which unpacks
# every node on the way down, and then unpacks the leaf again.
#
# The cache is correct because of the format, not in spite of it: no
# committed block is ever overwritten, so within a transaction a block
# number names one set of bytes.  Commit empties it, because after a
# commit a block on the freed list can be handed out again and the same
# number would name something else.
#
Ncache: con 8;
Fs.getnode(f: self ref Fs, n: big): (ref Node, string)
{
	if(f.cblk == nil){
		f.cblk = array[Ncache] of {* => Nilblk};
		f.cnode = array[Ncache] of ref Node;
		f.cnext = 0;
	}
	for(i := 0; i < Ncache; i++)
		if(f.cblk[i] == n)
			return (f.cnode[i], nil);
	(b, e) := f.d.rdblk(n);
	if(e != nil)
		return (nil, e);
	(nd, ue) := Node.unpack(b);
	if(ue != nil)
		return (nil, ue);
	f.cblk[f.cnext] = n;
	f.cnode[f.cnext] = nd;
	f.cnext = (f.cnext + 1) % Ncache;
	return (nd, nil);
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
	if(f.bmindex != nil)
		return nil;
	ng := ngroups(f.s.nblocks);
	(b, e) := f.d.rdblk(f.s.freeroot);
	if(e != nil)
		return e;
	f.bmindex = array[ng] of big;
	for(g := 0; g < ng; g++)
		f.bmindex[g] = get8(b, g * 8);
	f.groups = array[ng] of array of byte;
	f.gdirty = array[ng] of {* => 0};
	f.repl = array[ng] of {* => Nilblk};
	f.idxblk = Nilblk;
	#
	# f.cursor is deliberately NOT reset here.  The map is re-read
	# every commit, and starting the search at block 0 each time
	# would put the O(nblocks) scan back, once per transaction
	# instead of once per allocation.
	#
	#
	# Fold in what the last commit freed.  Before the map was grouped
	# this was guarded by "n < Blocksize * 8" and anything above that
	# was silently dropped -- a permanent leak, with no error, that
	# efsck could not see because efsck only ever looked at one block
	# of map either.  Now the group is looked up, and a block number
	# outside the filesystem is a fault rather than a shrug.
	#
	for(i := 0; i < len f.s.pendingfree; i++){
		n := f.s.pendingfree[i];
		if(n < big 0 || n >= f.s.nblocks)
			return sys->sprint("pendingfree holds block %bd, outside the filesystem", n);
		if((e = f.bmset(int n, 0)) != nil)
			return e;
	}
	f.s.pendingfree = array[0] of big;
	#
	# f.freed and f.dirty are NOT cleared here.  They are set by
	# Fs.mount and cleared by Fs.commit, and a commit that could not fit
	# its whole freed list leaves the remainder on f.freed for this
	# transaction to carry -- clearing it here would drop exactly the
	# blocks the carry exists to save.
	#
	return nil;
}

#
# One group of the free map, read on demand.
#
# What comes back is the COMMITTED group when it is first wanted and the
# in-memory copy ever after, which is what makes a transaction's own
# allocations visible to itself.  A group block number of Nilblk means
# mkefs never wrote that group, which cannot happen and is reported
# rather than turned into a block of zeros -- a block of zeros here reads
# as 32768 free blocks and would hand out the whole filesystem twice.
#
Fs.group(f: self ref Fs, g: int): (array of byte, string)
{
	if(g < 0 || g >= len f.bmindex)
		return (nil, sys->sprint("free map group %d does not exist", g));
	if(f.groups[g] != nil)
		return (f.groups[g], nil);
	if(f.bmindex[g] == Nilblk)
		return (nil, sys->sprint("free map group %d has no block", g));
	(b, e) := f.d.rdblk(f.bmindex[g]);
	if(e != nil)
		return (nil, e);
	f.groups[g] = b;
	return (b, nil);
}

Fs.bmget(f: self ref Fs, n: int): (int, string)
{
	(b, e) := f.group(n / Bitsperblk);
	if(e != nil)
		return (0, sys->sprint("block %d: %s", n, e));
	return (bitget(b, n % Bitsperblk), nil);
}

Fs.bmset(f: self ref Fs, n: int, v: int): string
{
	g := n / Bitsperblk;
	(b, e) := f.group(g);
	if(e != nil)
		return sys->sprint("block %d: %s", n, e);
	bitset(b, n % Bitsperblk, v);
	f.gdirty[g] = 1;
	return nil;
}

#
# One free block.
#
# Block 0 is a superblock and the last block is the other one, so
# neither is ever a candidate; the map has them set and this trusts it
# rather than special-casing them, because a map that disagrees is a bug
# worth hitting here and not somewhere quieter.
#
# The search starts where the last one stopped and wraps once.  From
# block 0 every time it is O(nblocks) per allocation, which nobody
# noticed while a filesystem was one group of 32768 blocks and which is
# 230 group reads per allocation at 29GB.
#
Fs.alloc(f: self ref Fs): (big, string)
{
	if((e := f.writable()) != nil)
		return (big -1, e);
	nb := int f.s.nblocks;
	for(k := 0; k < nb; k++){
		i := f.cursor + k;
		if(i >= nb)
			i -= nb;
		(u, ue) := f.bmget(i);
		if(ue != nil)
			return (big -1, ue);
		if(!u){
			if((e = f.bmset(i, 1)) != nil)
				return (big -1, e);
			f.cursor = i + 1;
			if(f.cursor >= nb)
				f.cursor = 0;
			f.dirty = 1;
			return (big i, nil);
		}
	}
	return (big -1, "filesystem is full");
}

#
# The margin to keep for deletes, in blocks.
#
# It has to cover one copy-on-write path rewrite plus the group and index
# blocks a commit allocates.  A path is as deep as the tree, and the tree
# is only as deep as the filesystem is large, so Nreserve is an upper
# bound rather than a figure every filesystem must pay: on a small image a
# flat Nreserve would be most of it, and the first version of this change
# left a 64-block image unable to hold a single file.  An eighth, capped
# at Nreserve and floored at four, keeps small images usable and large
# ones safe.
#
Fs.reserve(f: self ref Fs): int
{
	r := int f.s.nblocks / 8;
	if(r > Nreserve)
		r = Nreserve;
	if(r < 4)
		r = 4;
	return r;
}

#
# How many blocks are free, counted no further than want.
#
# This exists so that something which adds to the filesystem can be
# refused while there is still room to delete.  A delete allocates --
# removing a key rewrites the copy-on-write path to it, and Fs.free gives
# the old blocks back only to the next transaction -- so a filesystem
# allowed to reach zero free blocks cannot be emptied again.
#
# It stops at want, so the cost is the size of the reserve and not the
# size of the filesystem, and it leaves f.cursor alone: this is a
# question, not an allocation.
#
#
# The hash a directory entry's key carries.
#
# One copy, in the library, because there were two -- see module/efs.m.
#
namehash(s: string): big
{
	M64: con big 16r7fffffffffffffff;
	h := big 16rcbf29ce484222325;
	b := array of byte s;
	for(i := 0; i < len b; i++){
		h = h ^ big int b[i];
		h = h * big 16r100000001b3;
	}
	return h & M64;
}

Fs.headroom(f: self ref Fs, want: int): (int, string)
{
	#
	# The write side has to be up before a bit can be read: bmget goes
	# through the free map index that writable() loads, and without it
	# every block reads as "free map group 0 does not exist".  It is
	# idempotent, and anything that asks about headroom is about to
	# write anyway.
	#
	if((we := f.writable()) != nil)
		return (0, we);
	nb := int f.s.nblocks;
	got := 0;
	for(k := 0; k < nb && got < want; k++){
		i := f.cursor + k;
		if(i >= nb)
			i -= nb;
		(u, ue) := f.bmget(i);
		if(ue != nil)
			return (got, ue);
		if(!u)
			got++;
	}
	return (got, nil);
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
	#
	# Allocate the map's own new blocks, to a fixpoint.
	#
	# Every group whose bits changed needs a new block, and allocating
	# that block sets a bit, which may dirty a group that was not in
	# the write set, which needs a new block of its own.  So: go round
	# assigning a replacement to every dirty group without one, and to
	# the index, until a pass assigns none.
	#
	# It TERMINATES, and the reason is worth writing down rather than
	# re-deriving: inside a transaction allocation only ever SETS bits
	# -- frees go to pendingfree and are not folded in until the next
	# transaction begins -- so the set of dirty groups only grows, and
	# it is bounded by the number of groups.  Each pass either enlarges
	# the set of groups holding a replacement or ends the loop.
	#
	ng := len f.bmindex;
	for(;;){
		changed := 0;
		for(g := 0; g < ng; g++)
			if(f.gdirty[g] && f.repl[g] == Nilblk){
				(n, ae) := f.alloc();
				if(ae != nil)
					return ae;
				f.repl[g] = n;
				f.free(f.bmindex[g]);
				changed = 1;
			}
		if(f.idxblk == Nilblk){
			(n, ae) := f.alloc();
			if(ae != nil)
				return ae;
			f.idxblk = n;
			f.free(f.s.freeroot);
			changed = 1;
		}
		if(!changed)
			break;
	}

	#
	# Now write them.  Each group block records itself as in use before
	# it is written -- alloc did that -- or the map that comes back
	# from a crash describes a filesystem in which the map is free.
	#
	for(g := 0; g < ng; g++)
		if(f.repl[g] != Nilblk){
			if((e := f.d.wrblk(f.repl[g], f.groups[g])) != nil)
				return e;
			f.bmindex[g] = f.repl[g];
		}
	idx := array[Blocksize] of {* => byte 0};
	for(g = 0; g < ng; g++)
		put8(idx, g * 8, f.bmindex[g]);
	if((e := f.d.wrblk(f.idxblk, idx)) != nil)
		return e;
	f.s.freeroot = f.idxblk;

	#
	# The freed list into the superblock -- and what does not fit stays
	# on the list for the next commit rather than being dropped.
	#
	# A superblock holds 504 of them.  Removing a file of more than
	# about 2MB frees more than that, and the excess used to vanish
	# inside Super.pack: those blocks stayed marked used in the map with
	# nothing pointing at them, for ever, and the only report was
	# efsck's "marked used and not reached", which is documented there
	# as not an error because pendingfree legitimately produces it.
	#
	# Carrying the remainder is safe in the direction that matters: a
	# block still on the list is still marked used, so nothing hands it
	# out, and it becomes free one commit later than it might have.  The
	# filesystem stays dirty so that the next commit actually runs.
	#
	np := 0;
	for(l := f.freed; l != nil; l = tl l)
		np++;
	keep: list of big;
	if(np > maxpending()){
		i := 0;
		nl: list of big;
		for(l = f.freed; l != nil; l = tl l)
			if(i++ < maxpending())
				nl = hd l :: nl;
			else
				keep = hd l :: keep;
		f.freed = nl;
		np = maxpending();
	}
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
	f.freed = keep;
	f.dirty = keep != nil;
	f.bmindex = nil;	# re-read next time, folding pendingfree in
	f.cblk = nil;		# a freed block can come back under a new name
	f.cnode = nil;
	f.groups = nil;
	f.gdirty = nil;
	f.repl = nil;
	return nil;
}
