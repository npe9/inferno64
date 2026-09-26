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
#	block 1		 the free bitmap's first block
#	block 2..	 file data, then the metadata tree
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
Sbbitmap:	con big 1;	# block holding the first bitmap block

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
	# The smallest legal filesystem is four blocks: two superblocks, a
	# tree root and a bitmap block.  The format assumes no minimum size
	# beyond that, so the 7MB gap below the firmware's partition can
	# hold one.
	#
	if(nblocks == big 0)
		fail("say how many blocks with -n");
	if(nblocks < big 4)
		fail(sys->sprint("%bd blocks is too few; four is the minimum",
			nblocks));

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
	# Allocation while building: blocks 0 and 1 are the superblock and
	# the bitmap, the last is the spare superblock, and everything
	# else is handed out in order from 2 upward.  In order because a
	# builder that writes its blocks in ascending order is kind to a
	# card that erases in large units, and because it makes the image
	# the same every time, which makes a diff between two runs mean
	# something.
	#
	dev = d;
	nextblk = big 2;
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
	# The free bitmap, written LAST, because it must record every block
	# the build used and the build does not know that until it is done.
	# One bit per block, so a 4KB bitmap block covers 32768 blocks; a
	# filesystem larger than that needs more of them, and this program
	# refuses rather than writing a map it knows is short.
	#
	if(nblocks > big (Efs->Blocksize * 8))
		fail(sys->sprint("%bd blocks needs more than one bitmap block, which this does not write yet",
			nblocks));
	bm := array[Efs->Blocksize] of {* => byte 0};
	efs->bitset(bm, 0, 1);				# superblock 0
	efs->bitset(bm, int Sbbitmap, 1);		# the bitmap itself
	for(b := big 2; b < nextblk; b++)
		efs->bitset(bm, int b, 1);		# data and tree
	efs->bitset(bm, int (nblocks - big 1), 1);	# superblock 1
	if((e = d.wrblk(Sbbitmap, bm)) != nil)
		fail(e);

	s := ref Super;
	s.version = Efs->Version;
	s.blocksize = Efs->Blocksize;
	s.nblocks = nblocks;
	s.treeroot = treeroot;
	s.freeroot = Sbbitmap;
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

	sys->print("mkefs: %s: %bd blocks of %d, root inode %bd, tree at %bd, bitmap at %bd, %bd used\n",
		name, nblocks, Efs->Blocksize, Rootino, treeroot, Sbbitmap,
		nextblk);
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
	ents = Ent(Key(Rootino, Efs->Kdentry, namehash(name)), dv) :: ents;

	a := array[len ents] of Ent;
	k := 0;
	for(; ents != nil; ents = tl ents)
		a[k++] = hd ents;
	return (a, ino + big 1);
}

#
# The name hash.  FNV-1a again, folded into the key's 64-bit offset.
#
# Collisions are legal: the format says a bucket holds however many
# entries collide, and the name in the value is what settles which is
# which.  Nothing here depends on the hash being good, only on it being
# the same in every program that reads the filesystem -- which is why it
# is written once, here, and the server calls it rather than having its
# own.
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
