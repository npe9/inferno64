implement Mkefs;

#
# mkefs -- make an efs filesystem.
#
#	mkefs [-s startsector] [-n nblocks] file
#
# A separate program that runs once.  There is no ream flag on the
# server and no filesystem made as a side effect of mounting one: a
# board that boots and finds no filesystem says so.  doc/efs-plan.ms
# gives the reason -- reaming at boot is a test, not storage, and this
# board has never had a filesystem of its own that survived a reboot.
#
# What it writes, and nothing more:
#
#	block 0		 superblock, generation 1
#	block 1		 the free map's index block
#	block 2..	 one bitmap block per 32768 blocks, then file
#			 data, then the metadata tree
#	block nblocks-1	 the second superblock, generation 0
#
# With -a it copies files from the host into the root directory, which
# is what gives the read-only server something to serve.
#
# The tree is BULK LOADED: every key/value pair is collected, sorted
# once, and the leaves and the levels above them are filled in order.
# An offline builder knows all its keys in advance, so it has no use for
# the split-on-insert machinery a server needs, and writing that
# machinery here would mean writing it twice and trusting the copy that
# is exercised least.
#
# The second superblock is written OLDER on purpose.  Mount takes the
# higher generation that checksums, so a fresh filesystem has exactly
# one live state and the spare slot is the one the first commit will
# overwrite.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "daytime.m";
	daytime: Daytime;
include "efs.m";
	efs: Efs;
	Dev, Super, Node, Ent, Key, Inode: import efs;

Mkefs: module {
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Rootino:	con big 1;
Sbindex:	con big 1;	# block holding the free map's index

dev:	ref Dev;
nextblk: big;
limit:	big;

stderr: ref Sys->FD;

fail(s: string)
{
	sys->fprint(stderr, "mkefs: %s\n", s);
	raise "fail:error";
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	daytime = load Daytime Daytime->PATH;
	efs = load Efs Efs->PATH;
	if(efs == nil)
		fail(sys->sprint("cannot load %s: %r", Efs->PATH));
	efs->init();

	arg := load Arg Arg->PATH;
	if(arg == nil)
		fail(sys->sprint("cannot load %s: %r", Arg->PATH));
	arg->init(argv);
	arg->setusage("mkefs [-s startsector] [-n nblocks] [-a file]... image");
	startsect := big 0;
	nblocks := big 0;
	add: list of string;
	while((c := arg->opt()) != 0)
		case c {
		's' =>	startsect = big arg->earg();
		'n' =>	nblocks = big arg->earg();
		'a' =>	add = arg->earg() :: add;
		* =>	arg->usage();
		}
	argv = arg->argv();
	if(argv == nil)
		arg->usage();
	name := hd argv;

	#
	# The smallest legal filesystem is five blocks: two superblocks, an
	# index block, one bitmap block and a tree root.  The format
	# assumes no minimum size beyond that, so the 7MB gap below the
	# firmware's partition can hold one.
	#
	if(nblocks == big 0)
		fail("say how many blocks with -n");
	if(nblocks < big 5)
		fail(sys->sprint("%bd blocks is too few; five is the minimum",
			nblocks));
	#
	# The index block holds one block number per group, so 512 groups
	# of 32768 blocks is the ceiling: 64GB.  Past that the format needs
	# a second level of index and this refuses rather than writing a
	# map it knows is short.
	#
	if(nblocks > big Efs->Maxblocks)
		fail(sys->sprint("%bd blocks is more than the %d this format indexes (64GB)",
			nblocks, Efs->Maxblocks));

	#
	# Say exactly which sectors will be written, before writing any.
	#
	# On this board the filesystem lives above the firmware's FAT32,
	# which ends at sector 1064960, and a mistake in this arithmetic
	# overwrites the partition the board boots from.  Printing the
	# range is cheap and it is checkable by the person running it.
	#
	sys->print("mkefs: %s: sectors %bd..%bd (%bd blocks of %d)\n",
		name, startsect, startsect + nblocks * big Efs->Blksectors - big 1,
		nblocks, Efs->Blocksize);

	(d, e) := Dev.open(name, startsect, nblocks, 1);
	if(e != nil)
		fail(e);

	now := 0;
	if(daytime != nil)
		now = daytime->now();

	#
	# The root directory.  nlink 2: itself and its own dot entry, the
	# ordinary convention.
	#
	ino := ref Inode;
	ino.mode = 8r40775;
	ino.nlink = 2;
	ino.length = big 0;
	ino.atime = now;
	ino.mtime = now;
	ino.uid = "inferno";
	ino.gid = "inferno";

	#
	# Allocation while building: block 0 is the superblock, block 1 the
	# free map's index, blocks 2..1+ng its bitmaps, the last is the
	# spare superblock, and everything else is handed out in order from
	# there upward.  In order because a builder that writes its blocks
	# in ascending order is kind to a
	# card that erases in large units, and because it makes the image
	# the same every time, which makes a diff between two runs mean
	# something.
	#
	dev = d;
	nextblk = big 2 + big efs->ngroups(nblocks);
	limit = nblocks - big 1;

	ents := array[1] of Ent;
	ents[0] = Ent(Key(Rootino, Efs->Kinode, big 0), ino.pack());
	nextino := Rootino + big 1;

	for(l := add; l != nil; l = tl l){
		(es, ni) := addfile(hd l, nextino, now);
		nextino = ni;
		t := array[len ents + len es] of Ent;
		t[0:] = ents;
		t[len ents:] = es;
		ents = t;
	}
	sortents(ents);

	treeroot := buildtree(ents);

	#
	# The free map, written LAST, because it must record every block
	# the build used and the build does not know that until it is done.
	#
	# Block 1 is the index and blocks 2..1+ng are the groups, reserved
	# before the tree was built so that their numbers are known while
	# they are being filled in.  Everything from 0 to nextblk-1 is in
	# use by construction -- that is what allocating in ascending order
	# buys -- plus the spare superblock at the end.
	#
	ng := efs->ngroups(nblocks);
	idx := array[Efs->Blocksize] of {* => byte 0};
	for(g := 0; g < ng; g++){
		bm := array[Efs->Blocksize] of {* => byte 0};
		lo := big g * big Efs->Bitsperblk;
		for(b := lo; b < lo + big Efs->Bitsperblk && b < nblocks; b++)
			if(b < nextblk || b == nblocks - big 1)
				efs->bitset(bm, int (b - lo), 1);
		gb := Sbindex + big 1 + big g;
		if((e = d.wrblk(gb, bm)) != nil)
			fail(e);
		efs->put8(idx, g * 8, gb);
	}
	if((e = d.wrblk(Sbindex, idx)) != nil)
		fail(e);

	s := ref Super;
	s.version = Efs->Version;
	s.blocksize = Efs->Blocksize;
	s.nblocks = nblocks;
	s.treeroot = treeroot;
	s.freeroot = Sbindex;
	s.nextino = nextino;
	s.pendingfree = array[0] of big;

	#
	# The spare slot first and older, then the live one.  Written in
	# that order so that a mkefs interrupted between the two leaves a
	# filesystem that does not mount rather than one that mounts and
	# lies.
	#
	s.gen = big 0;
	if((e = d.wrblk(efs->superblk(nblocks, 1), s.pack())) != nil)
		fail(e);
	s.gen = big 1;
	if((e = d.wrblk(efs->superblk(nblocks, 0), s.pack())) != nil)
		fail(e);

	sys->print("mkefs: %s: %bd blocks of %d, root inode %bd, tree at %bd, free map index at %bd over %d group(s), %bd used\n",
		name, nblocks, Efs->Blocksize, Rootino, treeroot, Sbindex,
		efs->ngroups(nblocks), nextblk);
}

#
# One block out of the pool, in ascending order.
#
alloc(): big
{
	if(nextblk >= limit)
		fail(sys->sprint("out of blocks at %bd", nextblk));
	b := nextblk;
	nextblk++;
	return b;
}

#
# Copy one host file into the image, returning the entries it needs in
# the tree and the next free inode number.
#
# Data blocks are whole blocks, the last one zero filled: the inode's
# length is what says where the file really ends, and a reader that
# trusts the block instead of the length is a reader that will one day
# hand back somebody else's bytes.
#
addfile(path: string, ino: big, now: int): (array of Ent, big)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		fail(sys->sprint("open %s: %r", path));
	(ok, dir) := sys->fstat(fd);
	if(ok < 0)
		fail(sys->sprint("stat %s: %r", path));
	name := dir.name;

	ents: list of Ent;
	buf := array[Efs->Blocksize] of byte;
	off := big 0;
	total := big 0;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n < 0)
			fail(sys->sprint("read %s: %r", path));
		if(n == 0)
			break;
		for(i := n; i < Efs->Blocksize; i++)
			buf[i] = byte 0;
		b := alloc();
		if((e := dev.wrblk(b, buf)) != nil)
			fail(e);
		#
		# An extent: the block number and how many bytes of it this
		# file uses.  Eight bytes and four, and the block number is
		# the one 64-bit type -- never two halves in two fields,
		# which is the mistake FAT32 makes and this tree has fixed
		# three times.
		#
		v := array[12] of byte;
		efs->put8(v, 0, b);
		efs->put4(v, 8, n);
		ents = Ent(Key(ino, Efs->Kextent, off), v) :: ents;
		off++;
		total += big n;
	}
	fd = nil;

	i := ref Inode;
	i.mode = 8r664;
	i.nlink = 1;
	i.length = total;
	i.atime = now;
	i.mtime = now;
	i.uid = "inferno";
	i.gid = "inferno";
	ents = Ent(Key(ino, Efs->Kinode, big 0), i.pack()) :: ents;

	#
	# The directory entry, in the ROOT directory's key space.  The
	# offset is a hash of the name; the name itself is in the value,
	# because a key is fixed width and a name is not.
	#
	dv := array[8 + 2 + len array of byte name] of byte;
	efs->put8(dv, 0, ino);
	nb := array of byte name;
	efs->put2(dv, 8, len nb);
	dv[10:] = nb;
	ents = Ent(Key(Rootino, Efs->Kdentry, efs->namehash(name)), dv) :: ents;

	a := array[len ents] of Ent;
	k := 0;
	for(; ents != nil; ents = tl ents)
		a[k++] = hd ents;
	return (a, ino + big 1);
}


#
# Insertion sort by key.  The lists here are tens of entries, not
# millions, and a sort whose behaviour is obvious is worth more than one
# that is fast on inputs this program will never see.
#
sortents(a: array of Ent)
{
	for(i := 1; i < len a; i++){
		e := a[i];
		j := i - 1;
		while(j >= 0 && a[j].key.cmp(e.key) > 0){
			a[j+1] = a[j];
			j--;
		}
		a[j+1] = e;
	}
}

#
# Bulk load: fill leaves in key order, then build each level above from
# the first key of every block below, until one block holds the level.
#
buildtree(ents: array of Ent): big
{
	(blocks, keys) := fill(ents, Efs->Nleaf, 0);
	level := 1;
	while(len blocks > 1){
		up := array[len blocks] of Ent;
		for(i := 0; i < len blocks; i++){
			v := array[8] of byte;
			efs->put8(v, 0, blocks[i]);
			up[i] = Ent(keys[i], v);
		}
		(blocks, keys) = fill(up, Efs->Ninterior, level);
		level++;
		if(level > 16)
			fail("tree got deeper than 16 levels");
	}
	return blocks[0];
}

#
# One level: pack entries into blocks, in order, and say which block
# each went to and what its first key was.
#
fill(ents: array of Ent, ntype: int, level: int): (array of big, array of Key)
{
	blocks: list of big;
	keys: list of Key;
	nb := 0;
	i := 0;
	while(i < len ents || (nb == 0 && len ents == 0)){
		n := ref Node;
		n.ntype = ntype;
		n.level = level;
		#
		# Take entries until the next will not fit.  The arithmetic
		# lives in the library, in entsize and noderoom, so that
		# this and the server's writeents cannot disagree about it.
		#
		last := i;
		room := efs->noderoom();
		for(j := i; j < len ents; j++){
			c := efs->entsize(ents[j]);
			if(c > room)
				break;
			room -= c;
			last = j + 1;
		}
		if(last == i && i < len ents)
			fail(sys->sprint("entry %d does not fit in a block on its own", i));
		n.ents = ents[i:last];
		(b, pe) := n.pack();
		if(pe != nil)
			fail(pe);
		blk := alloc();
		if((e := dev.wrblk(blk, b)) != nil)
			fail(e);
		blocks = blk :: blocks;
		if(len n.ents > 0)
			keys = n.ents[0].key :: keys;
		else
			keys = Key(big 0, 0, big 0) :: keys;
		nb++;
		i = last;
		if(len ents == 0)
			break;
	}
	ba := array[nb] of big;
	ka := array[nb] of Key;
	k := nb - 1;
	for(; blocks != nil; blocks = tl blocks){
		ba[k] = hd blocks;
		ka[k] = hd keys;
		keys = tl keys;
		k--;
	}
	return (ba, ka);
}
