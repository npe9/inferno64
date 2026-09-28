implement Efsdump;

#
# efsdump -- print an efs filesystem's on-disk structures.
#
#	efsdump [-s startsector] file
#
# The second opinion.  Milestone 2 of doc/efs-plan.ms is "make an image,
# print it back", and the check is that what this prints matches what
# mkefs was told to write -- so this program decodes the disk and does
# not share a line of decision-making with the one that wrote it beyond
# the format library they both use.
#
# It reads.  It never writes, and it never repairs.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "efs.m";
	efs: Efs;
	Dev, Super, Node, Ent, Key, Inode: import efs;

Efsdump: module {
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

stderr: ref Sys->FD;

fail(s: string)
{
	sys->fprint(stderr, "efsdump: %s\n", s);
	raise "fail:error";
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	efs = load Efs Efs->PATH;
	if(efs == nil)
		fail(sys->sprint("cannot load %s: %r", Efs->PATH));
	efs->init();

	arg := load Arg Arg->PATH;
	if(arg == nil)
		fail(sys->sprint("cannot load %s: %r", Arg->PATH));
	arg->init(argv);
	arg->setusage("efsdump [-s startsector] file");
	startsect := big 0;
	while((c := arg->opt()) != 0)
		case c {
		's' =>	startsect = big arg->earg();
		* =>	arg->usage();
		}
	argv = arg->argv();
	if(argv == nil)
		arg->usage();
	name := hd argv;

	#
	# Opened with nblocks 0, meaning "no bound yet": the size is a
	# thing the superblock claims and this program is here to report
	# what is on the disk, not to assume it.
	#
	(d, e) := Dev.open(name, startsect, big 0, 0);
	if(e != nil)
		fail(e);

	#
	# How big the device is, asked of the device.
	#
	# Superblock 1 lives in the LAST block, so finding it needs a block
	# count -- and taking that from superblock 0 would mean that a
	# corrupt superblock 0 hides the spare that exists precisely for
	# that case.  The size is a property of the device and the device
	# can be asked: a file has a length and a partition has a size.
	# The superblock's own nblocks is then a claim to be checked
	# against it, not the only source.
	#
	devblocks := big 0;
	(ok, dir) := sys->fstat(d.fd);
	if(ok >= 0)
		devblocks = dir.length / big Efs->Blocksize;

	(s0, e0) := readsuper(d, big 0);
	sys->print("superblock 0 (block 0):\n");
	if(s0 == nil)
		sys->print("\tunreadable: %s\n", e0);
	else
		printsuper(s0);

	nb := devblocks;
	if(s0 != nil){
		nb = s0.nblocks;
		if(devblocks > big 0 && devblocks != nb)
			sys->print("note: superblock says %bd blocks, the device holds %bd\n",
				nb, devblocks);
	}
	if(nb == big 0)
		fail("superblock 0 is unreadable and the device has no size to fall back on");
	b1 := efs->superblk(nb, 1);
	(s1, e1) := readsuper(d, b1);
	sys->print("superblock 1 (block %bd):\n", b1);
	if(s1 == nil)
		sys->print("\tunreadable: %s\n", e1);
	else
		printsuper(s1);

	#
	# Which one mount would take, and say why.  This is the whole of
	# recovery, so it is worth printing rather than leaving the reader
	# to work out.
	#
	live := s0;
	which := 0;
	if(s0 == nil || (s1 != nil && s1.gen > s0.gen)){
		live = s1;
		which = 1;
	}
	if(live == nil){
		sys->print("mount would FAIL: neither superblock is good\n");
		return;
	}
	sys->print("mount would take superblock %d, generation %bd\n",
		which, live.gen);

	d.nblocks = live.nblocks;

	sys->print("tree root (block %bd):\n", live.treeroot);
	(tb, ne) := d.rdblk(live.treeroot);
	if(ne != nil)
		sys->print("\tunreadable: %s\n", ne);
	else{
		(n, pe) := Node.unpack(tb);
		if(n == nil)
			sys->print("\tundecodable: %s\n", pe);
		else
			printnode(n);
	}

	#
	# The free map: an index block of block numbers, then a bitmap
	# block per 32768 blocks.  Every group is counted; the blocks in
	# use are shown for the first only, because a 29GB filesystem has
	# 230 groups and the interesting one is where the metadata lives.
	#
	ng := efs->ngroups(live.nblocks);
	sys->print("free map index (block %bd), %d group(s):\n", live.freeroot, ng);
	(ib, ie) := d.rdblk(live.freeroot);
	if(ie != nil){
		sys->print("\tunreadable: %s\n", ie);
		return;
	}
	total := 0;
	for(g := 0; g < ng; g++){
		gb := efs->get8(ib, g * 8);
		(fb, fe) := d.rdblk(gb);
		if(fe != nil){
			sys->print("\tgroup %d at block %bd unreadable: %s\n", g, gb, fe);
			continue;
		}
		lo := big g * big Efs->Bitsperblk;
		hi := lo + big Efs->Bitsperblk;
		if(hi > live.nblocks)
			hi = live.nblocks;
		u := printbitmap(fb, g, lo, hi, g == 0);
		total += u;
	}
	sys->print("\t%d block(s) marked in use over the whole map\n", total);
}

readsuper(d: ref Dev, n: big): (ref Super, string)
{
	(b, e) := d.rdblk(n);
	if(e != nil)
		return (nil, e);
	return Super.unpack(b);
}

printsuper(s: ref Super)
{
	sys->print("\tversion %d blocksize %d generation %bd\n",
		s.version, s.blocksize, s.gen);
	sys->print("\tnblocks %bd treeroot %bd freeroot %bd nextino %bd\n",
		s.nblocks, s.treeroot, s.freeroot, s.nextino);
	sys->print("\tpendingfree %d\n", len s.pendingfree);
	for(i := 0; i < len s.pendingfree; i++)
		sys->print("\t\t%bd\n", s.pendingfree[i]);
}

printnode(n: ref Node)
{
	t := "leaf";
	if(n.ntype == Efs->Ninterior)
		t = "interior";
	sys->print("\t%s, level %d, %d entr(ies)\n", t, n.level, len n.ents);
	for(i := 0; i < len n.ents; i++){
		e := n.ents[i];
		sys->print("\t\t%s %d bytes", e.key.text(), len e.val);
		if(e.key.ktype == Efs->Kinode){
			(ino, ie) := Inode.unpack(e.val);
			if(ino == nil)
				sys->print(" -- undecodable: %s", ie);
			else
				sys->print(" mode %uo nlink %d length %bd uid %s gid %s",
					ino.mode, ino.nlink, ino.length,
					ino.uid, ino.gid);
		}
		sys->print("\n");
	}
}

#
# One group of the map.  Returns how many blocks in it are in use, and
# names them only when asked -- the caller asks for group 0 -- because a
# whole card's worth of groups would bury the numbers that matter.
#
printbitmap(b: array of byte, g: int, lo: big, hi: big, detail: int): int
{
	#
	# Count all of them, and show the LOWEST eight.
	#
	# This walked downwards and kept the first eight it met -- which
	# are the highest -- then printed them in ascending order with an
	# ellipsis after, so a nine-block filesystem reported "1 2 3 4 5 6
	# 7 255 ..." and block 0 vanished.  It read as a prefix and was a
	# suffix.  Walking upwards and stopping at eight is what it says it
	# does.
	#
	used := 0;
	nshow := 0;
	show: list of big;
	for(i := lo; i < hi; i++)
		if(efs->bitget(b, int (i - lo))){
			used++;
			if(nshow < 8){
				show = i :: show;
				nshow++;
			}
		}
	sys->print("\tgroup %d covers blocks %bd..%bd; %d marked in use\n",
		g, lo, hi - big 1, used);
	if(!detail)
		return used;
	first: list of big;
	for(; show != nil; show = tl show)
		first = hd show :: first;
	s := "\t\tin use:";
	for(l := first; l != nil; l = tl l)
		s += sys->sprint(" %bd", hd l);
	if(used > 8)
		s += " ...";
	sys->print("%s\n", s);
	return used;
}
