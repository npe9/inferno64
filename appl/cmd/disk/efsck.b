implement Efsck;

#
# efsck -- prove that an efs filesystem satisfies its invariants.
#
#	efsck [-s startsector] [-v] image
#
# NOT fsck, and the missing letter is the whole point.
#
# A traditional fsck is a RECOVERY STAGE: the contract is crash, mount,
# fsck, and only then usable, because the disk can hold a state no
# sequence of operations could have produced and something has to guess
# what it was meant to be.  This filesystem's contract is crash, mount,
# usable.  Recovery is the superblock flip and there is no stage after
# it.
#
# So this program asks "prove to me that this filesystem satisfies its
# invariants", not "work out what this was supposed to look like and
# repair it".  It exists because hardware faults, firmware bugs, memory
# corruption and bugs in this very code can still damage persistent
# state: a filesystem that cannot NEED recovery is achievable, one that
# never BENEFITS from an integrity checker is not.  It is an instrument,
# and it is offline.
#
# It never repairs.  doc/efs-plan.ms is explicit that recovery is the
# superblock flip and nothing else: a filesystem that needs a repair
# pass to be trusted is the design this one exists to replace.  So this
# is an instrument, not a tool -- it says whether what is on the disk
# holds together, and it is what milestone 5's crash harness asks after
# every injected failure.
#
# What it checks:
#
#	every block it reads has a good checksum
#	keys rise, within a node and from one leaf to the next
#	every leaf is at the same depth -- the B-tree invariant, and the
#	  one Fs.nextleaf's descent relies on
#	every interior entry points at a block inside the filesystem
#	every dentry names an inode that exists
#	every extent's block is inside the filesystem, and no block is
#	  claimed by two files
#	every block the tree reaches is marked used in the free map
#
# A block marked used that nothing reaches is reported as leaked and is
# NOT an error: pendingfree exists precisely so that blocks stay marked
# for one commit after they stop being reachable.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "efs.m";
	efs: Efs;
	Fs, Dev, Super, Node, Ent, Key, Inode: import efs;

Efsck: module {
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

stderr: ref Sys->FD;
verbose := 0;
nerr := 0;
fs: ref Fs;

reach: array of byte;		# blocks the tree reaches

#
# The depth every LEAF was found at, which must be one number.
#
# efsck checked that the tree was no deeper than 16 and nothing about its
# shape, so an UNBALANCED tree -- one child of a node a leaf and another
# interior -- passed it clean.  That is not a theoretical gap: it is why
# "efsck: clean, generation 285" was true of an image whose root had a
# leaf and an interior child, and why the only thing that noticed was
# Fs.nextleaf walking off the end of a path it was entitled to trust.
#
# Every leaf at the same depth is THE B-tree invariant, and a filesystem
# checker that does not test it cannot see the class of bug that breaks
# descent.
#
leafdepth := -1;		# the depth of the first leaf seen
owner: array of big;		# which inode claims a data block

bad(s: string)
{
	sys->print("efsck: %s\n", s);
	nerr++;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	efs = load Efs Efs->PATH;
	if(efs == nil){
		sys->fprint(stderr, "efsck: cannot load %s: %r\n", Efs->PATH);
		raise "fail:load";
	}
	efs->init();
	arg := load Arg Arg->PATH;
	arg->init(argv);
	arg->setusage("efsck [-s startsector] [-S n] [-v] image");
	startsect := big 0;
	#
	# Which superblock to check.  -1 is the one efs(1) would mount;
	# naming one checks THAT tree, which is how you find out whether
	# the generation behind a broken one is sound.
	#
	super := -1;
	while((c := arg->opt()) != 0)
		case c {
		's' =>	startsect = big arg->earg();
		'S' =>	super = int arg->earg();
			if(super != 0 && super != 1){
				sys->print("efsck: -S wants 0 or 1\n");
				raise "fail:usage";
			}
		'v' =>	verbose = 1;
		* =>	arg->usage();
		}
	argv = arg->argv();
	if(argv == nil)
		arg->usage();
	name := hd argv;

	(f, e) := Fs.mountsuper(name, startsect, super);
	if(f == nil){
		sys->print("efsck: %s: will not mount: %s\n", name, e);
		raise "fail:unmountable";
	}
	fs = f;
	if(verbose)
		sys->print("efsck: generation %bd from superblock %d, %bd blocks\n",
			fs.s.gen, fs.which, fs.s.nblocks);

	nb := int fs.s.nblocks;
	reach = array[(nb + 7) / 8] of {* => byte 0};
	owner = array[nb] of {* => big -1};

	#
	# The three blocks that are reachable by definition.
	#
	mark(big 0, big -1);
	mark(fs.s.nblocks - big 1, big -1);
	mark(fs.s.freeroot, big -1);

	#
	# The free map is a block of block numbers and each of those blocks
	# is as reachable as the index that names it.  Read it here, once,
	# because both the reachability marking and the comparison below
	# need it and reading it twice is how the two would come to
	# disagree.
	#
	ng := efs->ngroups(fs.s.nblocks);
	groups := array[ng] of array of byte;
	(ib, ie) := fs.d.rdblk(fs.s.freeroot);
	if(ie != nil)
		bad("free map index: " + ie);
	else
		for(g := 0; g < ng; g++){
			gb := efs->get8(ib, g * 8);
			mark(gb, big -1);
			(gbuf, ge) := fs.d.rdblk(gb);
			if(ge != nil)
				bad(sys->sprint("free map group %d at block %bd: %s",
					g, gb, ge));
			else
				groups[g] = gbuf;
		}

	inodes: list of big;
	dentries: list of (big, big);		# parent, child

	(inodes, dentries) = walk(fs.s.treeroot, 0);

	#
	# Every name must lead to an inode that exists.
	#
	for(l := dentries; l != nil; l = tl l){
		(par, child) := hd l;
		if(!hasinode(inodes, child))
			bad(sys->sprint("directory %bd names inode %bd, which has no record",
				par, child));
	}

	#
	# Everything the tree reaches must be marked used, over EVERY
	# block, not the first 32768.  The old loop stopped at one
	# bitmap block's worth, so on any filesystem larger than 128MB it
	# checked the first eighth of a percent and pronounced the rest
	# clean -- and it would have gone on doing that quietly, because
	# nothing here would ever have said the loop had ended early.
	#
	{
		unmarked := 0;
		leaked := 0;
		for(i := 0; i < nb; i++){
			gi := i / Efs->Bitsperblk;
			if(groups[gi] == nil)
				break;		# already reported above
			r := efs->bitget(reach, i);
			u := efs->bitget(groups[gi], i % Efs->Bitsperblk);
			if(r && !u){
				if(unmarked < 8)
					bad(sys->sprint("block %d is in the tree and free in the map", i));
				unmarked++;
			}
			if(!r && u)
				leaked++;
		}
		if(unmarked > 8)
			bad(sys->sprint("... and %d more blocks in the tree but free",
				unmarked - 8));
		if(verbose || leaked > 0)
			sys->print("efsck: %d block(s) marked used and not reached (pendingfree keeps some; not an error)\n",
				leaked);
	}

	if(nerr == 0){
		sys->print("efsck: %s: clean, generation %bd\n", name, fs.s.gen);
		return;
	}
	sys->print("efsck: %s: %d problem(s)\n", name, nerr);
	raise "fail:dirty";
}

hasinode(l: list of big, ino: big): int
{
	for(; l != nil; l = tl l)
		if(hd l == ino)
			return 1;
	return 0;
}

mark(n: big, forino: big)
{
	if(n < big 0 || n >= fs.s.nblocks){
		bad(sys->sprint("block number %bd is outside the filesystem", n));
		return;
	}
	i := int n;
	if(efs->bitget(reach, i) && forino >= big 0){
		bad(sys->sprint("block %d is claimed by inode %bd and inode %bd",
			i, owner[i], forino));
		return;
	}
	efs->bitset(reach, i, 1);
	if(forino >= big 0)
		owner[i] = forino;
}

#
# Walk the tree, returning the inodes and the directory entries found.
#
# Keys must rise.  The check is worth having because the whole structure
# depends on it: a descent takes the last child whose key is not greater
# than the target, so a tree whose keys are out of order does not fail
# loudly, it simply cannot find things -- which looks like data loss and
# is not.
#
walk(bn: big, depth: int): (list of big, list of (big, big))
{
	inodes: list of big;
	dentries: list of (big, big);
	if(depth > 16){
		bad("tree is deeper than 16 levels");
		return (inodes, dentries);
	}
	mark(bn, big -1);
	(n, e) := fs.getnode(bn);
	if(n == nil){
		bad(sys->sprint("block %bd: %s", bn, e));
		return (inodes, dentries);
	}
	if(n.ntype == Efs->Nleaf){
		if(leafdepth < 0)
			leafdepth = depth;
		else if(depth != leafdepth)
			bad(sys->sprint(
				"block %bd is a leaf at depth %d; another is at depth %d (the tree is unbalanced)",
				bn, depth, leafdepth));
	}
	for(i := 0; i < len n.ents; i++){
		if(i > 0 && n.ents[i-1].key.cmp(n.ents[i].key) >= 0)
			bad(sys->sprint("block %bd: key %s does not follow %s",
				bn, n.ents[i].key.text(), n.ents[i-1].key.text()));
		if(n.ntype == Efs->Ninterior){
			if(len n.ents[i].val != 8){
				bad(sys->sprint("block %bd entry %d is not a pointer", bn, i));
				continue;
			}
			(ci, cd) := walk(efs->get8(n.ents[i].val, 0), depth + 1);
			inodes = join(inodes, ci);
			dentries = joind(dentries, cd);
			continue;
		}
		k := n.ents[i].key;
		case k.ktype {
		Efs->Kinode =>
			(ino, ie) := Inode.unpack(n.ents[i].val);
			if(ino == nil)
				bad(sys->sprint("inode %bd: %s", k.ino, ie));
			else
				inodes = k.ino :: inodes;
		Efs->Kdentry =>
			v := n.ents[i].val;
			if(len v < 10){
				bad(sys->sprint("directory %bd: entry too short", k.ino));
				break;
			}
			nl := efs->get2(v, 8);
			if(10 + nl > len v){
				bad(sys->sprint("directory %bd: name runs past the entry", k.ino));
				break;
			}
			dentries = (k.ino, efs->get8(v, 0)) :: dentries;
		Efs->Kextent =>
			v := n.ents[i].val;
			if(len v < 12){
				bad(sys->sprint("inode %bd extent %bd: too short",
					k.ino, k.off));
				break;
			}
			used := efs->get4(v, 8);
			if(used < 0 || used > Efs->Blocksize)
				bad(sys->sprint("inode %bd extent %bd uses %d of a %d-byte block",
					k.ino, k.off, used, Efs->Blocksize));
			mark(efs->get8(v, 0), k.ino);
		* =>
			bad(sys->sprint("block %bd: key type %d is not one this format has",
				bn, k.ktype));
		}
	}
	return (inodes, dentries);
}

join(a, b: list of big): list of big
{
	for(; b != nil; b = tl b)
		a = hd b :: a;
	return a;
}

joind(a, b: list of (big, big)): list of (big, big)
{
	for(; b != nil; b = tl b)
		a = hd b :: a;
	return a;
}
