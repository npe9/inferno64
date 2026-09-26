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
#	block 1		 the metadata tree root: one leaf, holding the
#			 root directory's inode record
#	block 2		 the free bitmap's first block
#	block nblocks-1	 the second superblock, generation 0
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
Sbroot:		con big 1;	# block holding the tree root
Sbbitmap:	con big 2;	# block holding the first bitmap block

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
	arg->setusage("mkefs [-s startsector] [-n nblocks] file");
	startsect := big 0;
	nblocks := big 0;
	while((c := arg->opt()) != 0)
		case c {
		's' =>	startsect = big arg->earg();
		'n' =>	nblocks = big arg->earg();
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

	root := ref Node;
	root.ntype = Efs->Nleaf;
	root.level = 0;
	root.ents = array[1] of Ent;
	root.ents[0] = Ent(Key(Rootino, Efs->Kinode, big 0), ino.pack());
	(rb, re) := root.pack();
	if(re != nil)
		fail(re);
	if((e = d.wrblk(Sbroot, rb)) != nil)
		fail(e);

	#
	# The free bitmap's first block, with the four blocks this program
	# has used marked in use.  One bit per block, so a 4KB bitmap block
	# covers 32768 blocks; a filesystem larger than that has more
	# bitmap blocks, and allocating them is the server's business and
	# not this program's.
	#
	bm := array[Efs->Blocksize] of {* => byte 0};
	efs->bitset(bm, 0, 1);				# superblock 0
	efs->bitset(bm, int Sbroot, 1);			# tree root
	efs->bitset(bm, int Sbbitmap, 1);		# this block
	last := nblocks - big 1;
	if(last < big (Efs->Blocksize * 8))
		efs->bitset(bm, int last, 1);		# superblock 1
	if((e = d.wrblk(Sbbitmap, bm)) != nil)
		fail(e);

	s := ref Super;
	s.version = Efs->Version;
	s.blocksize = Efs->Blocksize;
	s.nblocks = nblocks;
	s.treeroot = Sbroot;
	s.freeroot = Sbbitmap;
	s.nextino = Rootino + big 1;
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

	sys->print("mkefs: %s: %bd blocks of %d, root inode %bd, tree at %bd, bitmap at %bd\n",
		name, nblocks, Efs->Blocksize, Rootino, Sbroot, Sbbitmap);
}
