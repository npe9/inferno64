implement Efsfs;

#
# efs -- serve an efs filesystem.
#
#	efs [-a|-b] [-s startsector] -f device mountpoint
#
# Milestones 3 and 4 of doc/efs-plan.ms: attach, walk, open, read, stat
# and directory listing, then create, write, truncate, remove and
# rename.
#
# Every modifying operation ends in a commit, which is a handful of
# block writes and a superblock.  That is slow and it is the point: the
# commit rule is what the whole format is for, and a server that batched
# operations would be testing something other than the rule.  Batching
# is an optimisation to make once there is a crash harness to keep it
# honest.
#
# It is a Limbo program serving Styx, not a kernel device, and the
# reason is testing rather than taste: the same .dis runs under emu on
# the build host against an image file and on the board against a
# partition.  Every bug found in dossrv during this port was found that
# way, and the one the host could not reproduce was the one that emptied
# the board's kernel.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Fid, Navop, Navigator: import styxservers;
include "arg.m";
include "daytime.m";
	daytime: Daytime;
include "efs.m";
	efs: Efs;
	Fs, Dev, Super, Node, Ent, Key, Inode: import efs;

Efsfs: module {
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

fs: ref Fs;
stderr: ref Sys->FD;
wdebug := 0;
failafter := 0;

#
# Inode number to name.
#
# The inode record does not hold a name and must not: a name lives in
# the parent's directory entry, which is what makes a rename a key
# change rather than a rewrite, and what would make a hard link
# ambiguous.  But Styx wants a name in every Dir, including one produced
# by a stat of a qid.
#
# Every qid this server hands out was reached through a walk or a
# readdir, and both of those know the name, so it is remembered here as
# they go.  A miss is reported as such rather than guessed at.
#
names := array[64] of list of (big, string);

remember(ino: big, name: string)
{
	h := int (ino % big len names);
	for(l := names[h]; l != nil; l = tl l){
		(i, nil) := hd l;
		if(i == ino)
			return;
	}
	names[h] = (ino, name) :: names[h];
}

#
# Drop what is known about an inode, so a rename replaces a name rather
# than shadowing it with a second entry.
#
forget(ino: big)
{
	h := int (ino % big len names);
	keep: list of (big, string);
	for(l := names[h]; l != nil; l = tl l){
		(i, nm) := hd l;
		if(i != ino)
			keep = (i, nm) :: keep;
	}
	names[h] = keep;
}

#
# And the same for the parent cache.
#
# There was no counterpart to forget() for parents, and remove() pruned
# neither table, so every file ever deleted left a (child, parent) tuple
# and a (ino, name) tuple behind.  Inode numbers are never reused --
# nextino only increments -- so those entries can never match anything
# again: they are dead weight that grows for the filesystem's whole life.
# With 64 buckets the chains that remember(), nameof() and parentof()
# walk on every operation grow with it, so it cost time as well as heap.
#
forgetparent(child: big)
{
	h := int (child % big len parents);
	keep: list of (big, big);
	for(l := parents[h]; l != nil; l = tl l){
		(c, pa) := hd l;
		if(c != child)
			keep = (c, pa) :: keep;
	}
	parents[h] = keep;
}

nameof(ino: big): string
{
	if(ino == Rootino)
		return "/";
	h := int (ino % big len names);
	for(l := names[h]; l != nil; l = tl l){
		(i, n) := hd l;
		if(i == ino)
			return n;
	}
	return "?";
}

Rootino: con big 1;

fail(s: string)
{
	sys->fprint(stderr, "efs: %s\n", s);
	raise "fail:error";
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	sys->pctl(Sys->NEWPGRP, nil);
	styx = load Styx Styx->PATH;
	if(styx == nil)
		fail(sys->sprint("cannot load %s: %r", Styx->PATH));
	styx->init();
	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil)
		fail(sys->sprint("cannot load %s: %r", Styxservers->PATH));
	styxservers->init(styx);
	efs = load Efs Efs->PATH;
	if(efs == nil)
		fail(sys->sprint("cannot load %s: %r", Efs->PATH));
	efs->init();
	daytime = load Daytime Daytime->PATH;

	arg := load Arg Arg->PATH;
	if(arg == nil)
		fail(sys->sprint("cannot load %s: %r", Arg->PATH));
	arg->init(argv);
	arg->setusage("efs [-a|-b] [-s startsector] [-C block] [-S n] -f device mountpoint");
	flags := Sys->MREPL;
	startsect := big 0;
	device := "";
	cursor := 0;
	#
	# Which superblock to mount: -1 is "the newer one whose tree is
	# there", which is what everything but a diagnosis wants.
	#
	super := -1;
	while((o := arg->opt()) != 0)
		case o {
		'a' =>	flags = Sys->MAFTER;
		'b' =>	flags = Sys->MBEFORE;
		's' =>	startsect = big arg->earg();
		'f' =>	device = arg->earg();
		'D' =>	styxservers->traceset(1);
		'W' =>	wdebug = 1;
		'F' =>	failafter = int arg->earg();
		#
		# Where the allocator starts looking.  An INSTRUMENT, and
		# what it is for is the only way to reach the second and
		# later blocks of the free map without first writing 128MB.
		#
		# A filesystem larger than 32768 blocks has more than one
		# bitmap block, and an empty one allocates from block 4
		# upward, so nothing above group 0 is ever touched until the
		# first 128MB are full.  Every test would pass on a
		# multi-group filesystem while exercising a single group,
		# which is the same nothing that "the FAT stress test passed
		# against a server that corrupted the card" was.
		#
		# What it does not prove: that the allocator REACHES the
		# high groups by filling the low ones.  It sets the starting
		# point; the scan, the wrap and the group arithmetic from
		# there are the real code.
		#
		'C' =>	cursor = int arg->earg();
		#
		# Mount a NAMED superblock, generation regardless.
		#
		# This is how you ask the question the two superblocks exist
		# to answer: the live one's tree is broken -- is the other
		# one's sound?  Without it there was no way to ask.  A
		# mount-write-unmount cycle commits twice, so the live slot
		# cannot even be moved by hand to find out.
		#
		'S' =>	super = int arg->earg();
			if(super != 0 && super != 1){
				sys->fprint(stderr, "efs: -S wants 0 or 1\n");
				raise "fail:usage";
			}
		* =>	arg->usage();
		}
	argv = arg->argv();
	if(device == "" || len argv != 1)
		arg->usage();
	mountpt := hd argv;
	arg = nil;

	(f, e) := Fs.mountsuper(device, startsect, super);
	if(f == nil)
		fail(sys->sprint("%s: %s", device, e));
	fs = f;
	fs.d.failafter = failafter;
	fs.cursor = cursor;
	sys->fprint(stderr,
		"efs: %s: %bd blocks, generation %bd from superblock %d\n",
		device, fs.s.nblocks, fs.s.gen, fs.which);

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		fail(sys->sprint("pipe: %r"));

	#
	# EVERYTHING on the server side is descended from ONE process that
	# takes its own namespace first, and it does so before the mount.
	#
	# Without this the server never exits and neither does emu.  A
	# spawned process SHARES the namespace it was spawned from, so once
	# /n/client is mounted every server-side process is holding a
	# reference to the mount whose pipe it is reading: the shell exits,
	# its namespace goes, the mount does not, the pipe never reaches
	# EOF, <-tchan never returns nil, and emu waits for a process that
	# is waiting for it.  A namespace COPIED before the mount does not
	# contain it, so the shell is the only holder and dropping it closes
	# the pipe.
	#
	# It has to be one root process and not a pctl in each, which was
	# the first fix and left about one run in sixty hanging.  Styxserver.new
	# spawns a reader of its own, and forking the namespace in the
	# processes this file can see does nothing about the one it cannot:
	# built out here it would share the shell's namespace and hold the
	# mount open by itself.  Built inside serve(), everything descends
	# from the copy.
	#
	# This was costing every efs test its whole timeout.  Nothing
	# noticed because the suites piped emu's output through grep and
	# never looked at its exit status, so "timeout 150" read as "took
	# 150 seconds" -- which is why a 16-point crash harness took an hour
	# for six seconds of work.
	#
	pidc := chan of int;
	spawn serve(fds[0], pidc);
	fds[0] = nil;
	<-pidc;

	#
	# MCREATE, because this server implements create and a mount
	# without it refuses creation at the mount point before the
	# server ever sees the request.
	#
	if(sys->mount(fds[1], nil, mountpt, flags|Sys->MCREATE, nil) < 0)
		fail(sys->sprint("mount %s: %r", mountpt));
	#
	# Drop this end of the pipe HERE, not whenever the collector gets
	# round to the array holding it.
	#
	# The mount has its own reference; this one is the caller's, and
	# while it lives the pipe cannot reach EOF, so the server cannot
	# exit and neither can emu.  Leaving it to init() returning is
	# leaving it to the collector, and that showed as about one run in
	# twenty hanging at a random crash point with efsck reporting the
	# image clean -- a server still running after all its work was done.
	#
	fds[1] = nil;
}

#
# An inode as a Dir.
#
dirof(ino: big): (ref Sys->Dir, string)
{
	(v, e) := fs.get(Key(ino, Efs->Kinode, big 0));
	if(e != nil)
		return (nil, e);
	if(v == nil)
		return (nil, sys->sprint("no inode %bd", ino));
	(i, ie) := Inode.unpack(v);
	if(i == nil)
		return (nil, ie);
	d := ref sys->zerodir;
	d.name = nameof(ino);
	d.uid = i.uid;
	d.gid = i.gid;
	d.muid = i.uid;
	d.qid.path = ino;
	d.qid.vers = 0;
	d.mode = i.mode & 8r777;
	if(i.mode & Sys->DMDIR || (i.mode & 8r170000) == 8r40000){
		d.mode |= Sys->DMDIR;
		d.qid.qtype = Sys->QTDIR;
		d.length = big 0;
	}else{
		d.qid.qtype = Sys->QTFILE;
		d.length = i.length;
	}
	d.atime = i.atime;
	d.mtime = i.mtime;
	return (d, nil);
}

#
# A directory entry's value: child inode, name length, name.
#
dentry(v: array of byte): (big, string, string)
{
	if(len v < 10)
		return (big 0, nil, "directory entry is too short");
	ino := efs->get8(v, 0);
	n := efs->get2(v, 8);
	if(10 + n > len v)
		return (big 0, nil, "directory entry name runs past the end");
	return (ino, string v[10:10+n], nil);
}

#
# Find a directory entry BY NAME, in one descent instead of a scan.
#
# A dentry's key is Key(dir, Kdentry, namehash(name)) -- adddentry() has
# always built it that way -- so the name IS the key and there is no
# reason to read the directory to find one entry.  walkto(), create() and
# the rename in wstat() each used to call fs.range() and scan what came
# back, which is O(entries) in block reads on every path element of every
# operation; doc/open-issues-plan.ms B1a is the measurement.
#
# Returns (ino, name-found-there, nil).  ino < 0 means the key is absent.
#
# THE NAME AT THE KEY IS RETURNED RATHER THAN COMPARED HERE, and the
# callers must look at it, because the key is a 63-bit hash and two names
# can share one.  The tree holds ONE entry per key -- Fs.replace replaces
# a key it finds rather than chaining -- so "the key exists" does not mean
# "this name exists", and a caller that assumes it does either finds the
# wrong file or destroys one.  See create() for the half of that which was
# a bug.
#
dlook(dir: big, name: string): (big, string, string)
{
	(v, e) := fs.get(Key(dir, Efs->Kdentry, efs->namehash(name)));
	if(e != nil)
		return (big -1, nil, e);
	if(v == nil)
		return (big -1, nil, nil);
	(ino, nm, de) := dentry(v);
	if(de != nil)
		return (big -1, nil, de);
	return (ino, nm, nil);
}

navigator(navops: chan of ref Navop)
{
	for(;;){
		navop := <-navops;
		if(navop == nil)
			break;
		pick n := navop {
		Stat =>
			(d, e) := dirof(n.path);
			n.reply <-= (d, e);
		Walk =>
			n.reply <-= walkto(n.path, n.name);
		Readdir =>
			readdir(n);
		}
	}
}

walkto(parent: big, name: string): (ref Sys->Dir, string)
{
	if(name == ".")
		return dirof(parent);
	#
	# ".." is not resolved here.  The tree has no parent pointer -- a
	# child does not know its directory -- and styxservers walks ".."
	# itself from the fid's own path, so answering it wrongly would be
	# worse than leaving it alone.
	#
	(ino, nm, e) := dlook(parent, name);
	if(e != nil)
		return (nil, e);
	#
	# nm != name is a hash collision: some other name occupies this
	# key, so the name asked for is not in this directory.
	#
	if(ino < big 0 || nm != name)
		return (nil, Styxservers->Enotfound);
	remember(ino, nm);
	rememberparent(ino, parent);
	return dirof(ino);
}

readdir(n: ref Navop.Readdir)
{
	(ents, e) := fs.range(n.path, Efs->Kdentry);
	if(e != nil){
		n.reply <-= (nil, e);
		n.reply <-= (nil, nil);
		return;
	}
	#
	# Entries come out of the tree in key order, which is name-hash
	# order and not alphabetical.  Styx does not promise an order, and
	# inventing one here would mean holding the whole directory to sort
	# it; what matters is that the order is STABLE between reads, and
	# key order is.
	#
	for(i := n.offset; i < len ents && i < n.offset + n.count; i++){
		(ino, nm, de) := dentry(ents[i].val);
		if(de != nil)
			break;
		remember(ino, nm);
		rememberparent(ino, n.path);
		(d, derr) := dirof(ino);
		if(derr != nil)
			break;
		n.reply <-= (d, nil);
	}
	n.reply <-= (nil, nil);
}

#
# Read from a file.
#
# The inode's length is what says where the file ends.  An extent
# records how many bytes of its block the file uses, and the block is
# whole and zero filled beyond that -- so a reader that returns the
# block instead of respecting the length hands back whatever the
# builder left there.
#
readfile(ino: big, offset: big, count: int): (array of byte, string)
{
	(v, e) := fs.get(Key(ino, Efs->Kinode, big 0));
	if(e != nil)
		return (nil, e);
	if(v == nil)
		return (nil, sys->sprint("no inode %bd", ino));
	(i, ie) := Inode.unpack(v);
	if(i == nil)
		return (nil, ie);
	if(offset >= i.length)
		return (array[0] of byte, nil);
	if(big count > i.length - offset)
		count = int (i.length - offset);
	out := array[count] of byte;
	got := 0;
	while(got < count){
		o := offset + big got;
		blk := o / big Efs->Blocksize;
		within := int (o % big Efs->Blocksize);
		(ev, ee) := fs.get(Key(ino, Efs->Kextent, blk));
		if(ee != nil)
			return (nil, ee);
		if(ev == nil || len ev < 12)
			#
			# A hole.  Nothing makes one yet, and reading zeroes
			# is what a hole means, so this fills rather than
			# failing.
			#
			return (out[0:got], nil);
		bn := efs->get8(ev, 0);
		used := efs->get4(ev, 8);
		(b, be) := fs.d.rdblk(bn);
		if(be != nil)
			return (nil, be);
		n := used - within;
		if(n > count - got)
			n = count - got;
		if(n <= 0)
			break;
		out[got:] = b[within:within+n];
		got += n;
	}
	return (out[0:got], nil);
}

#
# The root of the server side: its own namespace, then everything else
# built inside it.  See the note at the spawn.
#
serve(fd: ref Sys->FD, pidc: chan of int)
{
	sys->pctl(Sys->FORKNS, nil);
	navops := chan of ref Navop;
	spawn navigator(navops);
	(tchan, srv) := Styxserver.new(fd, Navigator.new(navops), Rootino);
	pidc <-= sys->pctl(0, nil);
	server(tchan, srv, navops);
}

server(tchan: chan of ref Styx->Tmsg, srv: ref Styxserver,
	navops: chan of ref Navop)
{
	for(;;){
		gm := <-tchan;
		if(gm == nil){
			#
			# THE CONNECTION WENT AWAY, and a create is no longer
			# durable at its own reply -- the clunk that follows
			# makes it so.  A client that creates a file and
			# disconnects without clunking sends no clunk, so
			# without this the file is simply lost, which it was
			# not before creates were deferred.  Nothing is left
			# to report an error to, so it goes to stderr.
			#
			if(fs.dirty)
				if((he := fs.commit()) != nil)
					sys->fprint(sys->fildes(2),
						"efs: commit on hangup: %s\n", he);
			break;
		}
		pick m := gm {
		Open =>
			#
			# Truncation arrives as a MODE BIT on the open, not
			# as a wstat with length 0 -- which is why "> file"
			# left a file its old size while wstat's truncate
			# worked perfectly.
			#
			f := srv.getfid(m.fid);
			if(f != nil && (m.mode & Sys->OTRUNC) &&
			    (f.qtype & Sys->QTDIR) == 0){
				e := truncate(f.path);
				if(e == nil)
					e = fs.commit();
				if(e != nil){
					srv.reply(ref Rmsg.Error(m.tag, e));
					continue;
				}
			}
			srv.default(m);
		Read =>
			f := srv.getfid(m.fid);
			if(f == nil || f.isopen == 0){
				srv.default(m);
				continue;
			}
			if(f.qtype & Sys->QTDIR){
				srv.default(m);
				continue;
			}
			(b, e) := readfile(f.path, m.offset, m.count);
			if(e != nil)
				srv.reply(ref Rmsg.Error(m.tag, e));
			else
				srv.reply(ref Rmsg.Read(m.tag, b));
		#
		# Everything that would change the filesystem is refused by
		# name, so that a caller is told this server is read only
		# rather than being given a generic error to puzzle over.
		# Milestone 4 is where these grow bodies.
		#
		Write =>
			f := srv.getfid(m.fid);
			if(f == nil || f.isopen == 0 || (f.qtype & Sys->QTDIR)){
				srv.default(m);
				continue;
			}
			e := room();
			if(e == nil)
				e = writefile(f.path, m.offset, m.data);
			if(e == nil){
				markdirty(m.fid);
				wpending += len m.data;
				if(wpending >= Wbatch){
					e = fs.commit();
					wpending = 0;
				}
			}
			if(e != nil)
				srv.reply(ref Rmsg.Error(m.tag, e));
			else
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
		Create =>
			f := srv.getfid(m.fid);
			if(f == nil || (f.qtype & Sys->QTDIR) == 0){
				srv.default(m);
				continue;
			}
			if((re := room()) != nil){
				srv.reply(ref Rmsg.Error(m.tag, re));
				continue;
			}
			(d, e) := create(f.path, m.name, m.perm, m.mode);
			#
			# A create does NOT commit.  The clunk that must
			# follow does, and marking the fid here is what tells
			# it to -- see the dirty-fid list above.
			#
			# Deferring it was reverted once, because it made
			# efs-write report 228 leaked blocks and efs-stress
			# hang.  Both were real and neither was this code: the
			# leak figure was a test that encoded a commit count,
			# and the hang was Fs.commit running with no free map
			# in memory, which the deferral exposed rather than
			# caused.  Fixed in appl/lib/efs.b; see
			# doc/open-issues-plan.ms B1e.
			#
			if(e == nil)
				markdirty(m.fid);
			if(e != nil){
				srv.reply(ref Rmsg.Error(m.tag, e));
				continue;
			}
			f.open(m.mode, d.qid);
			f.path = d.qid.path;
			f.qtype = d.qid.qtype;
			srv.reply(ref Rmsg.Create(m.tag, d.qid, 0));
		Remove =>
			f := srv.getfid(m.fid);
			if(f == nil){
				srv.default(m);
				continue;
			}
			e := remove(f.path);
			takedirty(m.fid);
			if(e == nil)
				e = fs.commit();
			srv.delfid(f);
			if(e != nil)
				srv.reply(ref Rmsg.Error(m.tag, e));
			else
				srv.reply(ref Rmsg.Remove(m.tag));
		Wstat =>
			f := srv.getfid(m.fid);
			if(f == nil){
				srv.default(m);
				continue;
			}
			e := wstat(f.path, m.stat);
			if(e == nil)
				e = fs.commit();
			if(e != nil)
				srv.reply(ref Rmsg.Error(m.tag, e));
			else
				srv.reply(ref Rmsg.Wstat(m.tag));
		Clunk =>
			#
			# Where a write's transaction is closed.  srv.clunk()
			# releases the fid and this replies, because the
			# default handler would reply before the commit and
			# tell the client the file was closed while it was
			# not yet on the medium.
			#
			#
			# Commit FIRST, then release the fid.  srv.clunk()
			# replies by itself, so replying here as well would
			# put two Rmsgs on one tag -- and committing after it
			# would tell the client the file was closed while it
			# was not yet on the medium.
			#
			e: string;
			mine := takedirty(m.fid);
			if(fs.dirty && (mine || dirtyfid == nil)){
				e = fs.commit();
				wpending = 0;
			}
			if(e != nil){
				#
				# A clunk releases the fid whatever happens --
				# 9P has no way to say "still open" -- so drop
				# it and report the commit failure.
				#
				cf := srv.getfid(m.fid);
				if(cf != nil)
					srv.delfid(cf);
				srv.reply(ref Rmsg.Error(m.tag, e));
			}else
				srv.clunk(m);
		* =>
			srv.default(gm);
		}
	}
	navops <-= nil;
}

#
# Cut a file back to a length.
#
# Extents past the new end go and their blocks are freed; the one that
# straddles it is trimmed by its length field and its block is left
# alone, because the length is what says where a file ends.  The inode's
# length is set by the caller, which is the only place that knows
# whether this is a truncate or part of something larger.
#
#
# WHEN TO COMMIT A WRITE.
#
# Every Styx Write used to commit, which is the strongest thing a
# filesystem can promise and the most expensive thing this one can do.  A
# commit is a path rewrite plus the free map plus the superblock -- 7.8
# blocks, measured -- so a file written in 8KB messages paid 7.8 blocks of
# metadata for every 2 blocks of data.  Copying this board's own kernel
# image into efs, 2548632 bytes, cost 13MB of writes and 3253 write
# operations for 622 blocks of data: 5.1x write amplification and 5.2
# write operations per block of file.  On an SD card, which charges per
# operation and not per byte, that is the whole cost of a kernel update.
#
# So a write now leaves the transaction open and Clunk commits it.  A file
# is durable when it is closed, which is what dossrv does here ("every
# clunk syncs") and what a filesystem is normally taken to mean.  The
# contract in man/4/efs is unchanged and was never per-operation: it is
# that the image holds "exactly the last committed state", and it still
# does -- there is simply less of it after a crash in the middle of a file
# that was never closed.
#
# BOUNDED, because an open transaction cannot grow without limit.  Blocks
# freed inside it are not reusable until the commit after it, so a
# transaction that writes K blocks holds K blocks out of circulation; let
# K run and a long write fills a filesystem that had room.  Committing
# every Wbatch bytes bounds it at 32 blocks, which is above the reserve
# and far below any filesystem worth using, and leaves the existing
# room() gate's arithmetic valid.
#
# Remove, Wstat and a truncating Open still commit immediately.  They are
# cheap and rare, and keeping the strong guarantee where it costs nothing
# is worth more than the consistency of having one rule.
#
# CREATE NO LONGER DOES.  It is the one metadata operation that is
# neither rare nor standalone -- every file written passes through it,
# and the clunk that must follow was committing a second time for the
# same file.  So a create is durable at the clunk of the fid that made
# it, like the write, and the hangup path above commits for a client
# that disconnects without clunking at all.
#
Wbatch: con 32 * Efs->Blocksize;
wpending := 0;			# bytes written since the last commit

#
# WHICH FIDS HAVE DIRTIED THE FILESYSTEM.
#
# A clunk is where an uncommitted change is made durable, and the first
# version of that committed on EVERY clunk while the filesystem was
# dirty.  That is correct and it bought nothing: "echo x > f" clunks two
# fids -- the directory walked to, and the file created -- so deferring
# the create's commit to the clunk simply moved one commit and left the
# count at two per file.  Measured by generation number, which counts
# commits exactly and is medium-independent: 60 files cost generation
# 122 either way.
#
# So a clunk commits when THAT fid is the one that dirtied something, or
# when no fid is holding a dirty change any more.  The second half is
# the backstop: it catches dirt from a fid that has already gone, and
# without it a change could sit uncommitted until the next write
# batch.  Between the two, the directory's clunk never commits -- if it
# arrives first the file's fid is still on this list, and if it arrives
# last the file's clunk has already committed and nothing is dirty.
#
dirtyfid: list of int;

markdirty(fid: int)
{
	for(l := dirtyfid; l != nil; l = tl l)
		if(hd l == fid)
			return;
	dirtyfid = fid :: dirtyfid;
}

#
# Was this fid dirty?  Takes it off the list either way, because the
# caller is done with it.
#
takedirty(fid: int): int
{
	found := 0;
	nl: list of int;
	for(l := dirtyfid; l != nil; l = tl l)
		if(hd l == fid)
			found = 1;
		else
			nl = hd l :: nl;
	dirtyfid = nl;
	return found;
}


#
# Refuse an operation that would add to the filesystem unless the reserve
# would survive it.
#
# Twice the reserve: once for what this operation is about to spend, once
# for the margin that has to be left so a delete can still commit after.
# Deletes and truncates do not come through here, which is the point --
# they are what the margin is being kept for.
#
room(): string
{
	want := 2 * fs.reserve();
	(got, e) := fs.headroom(want);
	if(e != nil)
		return e;
	if(got < want)
		return "filesystem is full";
	return nil;
}

trimto(ino: big, i: ref Inode, length: big): string
{
	(ents, re) := fs.range(ino, Efs->Kextent);
	if(re != nil)
		return re;
	for(j := 0; j < len ents; j++){
		start := ents[j].key.off * big Efs->Blocksize;
		if(start >= length){
			if(len ents[j].val >= 12)
				fs.free(efs->get8(ents[j].val, 0));
			if((e := fs.delete(ents[j].key)) != nil)
				return e;
		}else if(start + big Efs->Blocksize > length){
			nv := array[12] of byte;
			nv[0:] = ents[j].val[0:8];
			efs->put4(nv, 8, int (length - start));
			if((e := fs.insert(ents[j].key, nv)) != nil)
				return e;
		}
	}
	i.length = length;
	return nil;
}

truncate(ino: big): string
{
	(v, e) := fs.get(Key(ino, Efs->Kinode, big 0));
	if(e != nil)
		return e;
	if(v == nil)
		return sys->sprint("no inode %bd", ino);
	(i, ie) := Inode.unpack(v);
	if(i == nil)
		return ie;
	if(i.length == big 0)
		return nil;
	if((e = trimto(ino, i, big 0)) != nil)
		return e;
	return fs.insert(Key(ino, Efs->Kinode, big 0), i.pack());
}

#
# Is a wstat field the "do not change" sentinel?
#
# Styx sends all-ones, and the trap is that all-ones arrives as
# 0xffffffff while Limbo's ~0 is -1.  Limbo's int is 32 bits to the
# compiler and 64 at runtime in this implementation, so those two are
# the same bits and different numbers, and "stat.mode != ~0" -- which is
# what every other server in this tree writes, and what this wrote --
# quietly passes.  The mode then goes through "& 0777" and a rename sets
# the file to 0777.
#
# Tested both ways rather than cleverly, because the clever version is
# what is already wrong.
#
unchanged(v: int): int
{
	if(v == ~0)
		return 1;
	return big v == big 16rffffffff;
}

#
# The parent of an inode, and its name in that parent.
#
# The tree has no parent pointer -- a child does not know its directory
# -- so this is a search of the directories the server has seen.  It is
# kept for remove and for rename, which need to take a name out of a
# directory, and it is honest about its cost: a scan of one directory,
# the one the caller already walked through.
#
parents := array[64] of list of (big, big);	# child -> parent

rememberparent(child: big, parent: big)
{
	h := int (child % big len parents);
	for(l := parents[h]; l != nil; l = tl l){
		(c, nil) := hd l;
		if(c == child)
			return;
	}
	parents[h] = (child, parent) :: parents[h];
}

parentof(child: big): big
{
	h := int (child % big len parents);
	for(l := parents[h]; l != nil; l = tl l){
		(c, p) := hd l;
		if(c == child)
			return p;
	}
	return big -1;
}

#
# Make a file in a directory.
#
create(dir: big, name: string, perm: int, nil: int): (ref Sys->Dir, string)
{
	if(name == "" || name == "." || name == "..")
		return (nil, "bad name");
	#
	# Refuse a duplicate, and refuse a COLLISION.
	#
	# This used to read the whole directory and scan it for the name,
	# with a comment saying "a second dentry with the same name hashes
	# to the same key and a bucket holds collisions".  There is no
	# bucket: Fs.replace, given a key it already holds, REPLACES it.
	# So a create whose name hashed onto an existing DIFFERENT name
	# passed this check, reached fs.insert, and silently replaced that
	# file's directory entry -- the file vanished from the directory
	# with no error and its inode and blocks leaked.
	#
	# Demonstrated rather than reasoned: with namehash narrowed to 8
	# bits so a collision is reachable, creating "b" and then "ga"
	# (both hash to 165) left only "ga", and "cat b" said the file did
	# not exist.  At the real 63 bits a directory needs on the order of
	# 2**31 names for this to be likely, which is why it had never been
	# seen -- but silent is silent.
	#
	# One descent now, and the two cases are distinguished: the same
	# name is "file already exists", a different name at the same key
	# is refused as what it is.  Refusing is the only honest answer
	# while one key holds one entry; making it work needs a format that
	# chains them, which is a version bump and not this.
	#
	(xino, xnm, re) := dlook(dir, name);
	if(re != nil)
		return (nil, re);
	if(xino >= big 0){
		if(xnm == name)
			return (nil, "file already exists");
		return (nil, sys->sprint(
			"name hash collision with %#q; efs holds one entry per key",
			xnm));
	}

	ino := fs.s.nextino;
	fs.s.nextino++;

	now := 0;
	if(daytime != nil)
		now = daytime->now();
	ni := ref Inode;
	ni.mode = perm & 8r777;
	if(perm & Sys->DMDIR)
		ni.mode |= 8r40000;
	ni.nlink = 1;
	ni.length = big 0;
	ni.atime = now;
	ni.mtime = now;
	ni.uid = "inferno";
	ni.gid = "inferno";
	e := fs.insert(Key(ino, Efs->Kinode, big 0), ni.pack());
	if(e != nil)
		return (nil, e);
	if((e = adddentry(dir, name, ino)) != nil)
		return (nil, e);
	remember(ino, name);
	rememberparent(ino, dir);
	return dirof(ino);
}

adddentry(dir: big, name: string, ino: big): string
{
	nb := array of byte name;
	v := array[10 + len nb] of byte;
	efs->put8(v, 0, ino);
	efs->put2(v, 8, len nb);
	v[10:] = nb;
	return fs.insert(Key(dir, Efs->Kdentry, efs->namehash(name)), v);
}


#
# Write into a file, block by block.
#
# A partial block is read, patched and written to a NEW block: no
# committed data block is ever modified, so a crash in the middle leaves
# the old block still intact and still the one the old tree points at.
#
writefile(ino: big, offset: big, data: array of byte): string
{
	(v, e) := fs.get(Key(ino, Efs->Kinode, big 0));
	if(e != nil)
		return e;
	if(v == nil)
		return sys->sprint("no inode %bd", ino);
	(i, ie) := Inode.unpack(v);
	if(i == nil)
		return ie;

	done := 0;
	while(done < len data){
		o := offset + big done;
		blk := o / big Efs->Blocksize;
		within := int (o % big Efs->Blocksize);
		n := Efs->Blocksize - within;
		if(n > len data - done)
			n = len data - done;

		buf := array[Efs->Blocksize] of {* => byte 0};
		used := 0;
		(ev, ee) := fs.get(Key(ino, Efs->Kextent, blk));
		if(ee != nil)
			return ee;
		if(ev != nil && len ev >= 12){
			ob := efs->get8(ev, 0);
			used = efs->get4(ev, 8);
			(b, be) := fs.d.rdblk(ob);
			if(be != nil)
				return be;
			buf[0:] = b;
			fs.free(ob);
		}
		buf[within:] = data[done:done+n];
		if(within + n > used)
			used = within + n;
		(nb, ae) := fs.alloc();
		if(ae != nil)
			return ae;
		if((we := fs.d.wrblk(nb, buf)) != nil)
			return we;
		nv := array[12] of byte;
		efs->put8(nv, 0, nb);
		efs->put4(nv, 8, used);
		if((e = fs.insert(Key(ino, Efs->Kextent, blk), nv)) != nil)
			return e;
		done += n;
	}
	if(offset + big len data > i.length){
		i.length = offset + big len data;
		if((e = fs.insert(Key(ino, Efs->Kinode, big 0), i.pack())) != nil)
			return e;
	}
	return nil;
}

#
# Remove a file: its extents, its inode, and its name in its parent.
#
# The order matters only for what a crash leaves behind, and normally it
# does not matter at all: none of it is visible until the commit, and the
# commit publishes all of it or none.
#
# The exception is a filesystem too tight to finish in one transaction --
# see the commit inside the extent loop, which trades that atomicity for
# being able to delete at all.
#
remove(ino: big): string
{
	if(ino == Rootino)
		return "cannot remove the root";
	(ents, e) := fs.range(ino, Efs->Kextent);
	if(e != nil)
		return e;
	for(i := 0; i < len ents; i++){
		if(len ents[i].val >= 12)
			fs.free(efs->get8(ents[i].val, 0));
		if((e = fs.delete(ents[i].key)) != nil)
			return e;
		#
		# Commit part-way, but only once there is no longer room to
		# finish.
		#
		# A delete ALLOCATES: each key rewrites the copy-on-write
		# path down to it, and Fs.free hands the old blocks back only
		# to the NEXT transaction.  So a file of many extents can need
		# more blocks than are free and fail with "filesystem is full"
		# on a filesystem it is in the middle of emptying -- which is
		# how a full efs became impossible to empty.  Committing here
		# releases what has been freed so far so the rest can proceed.
		#
		# What it costs is the atomicity promised above: a crash in
		# the middle leaves the file shorter rather than untouched.
		# That is the same state a truncate leaves, so it is a legal
		# file and not a corrupt one, and it is paid only on a
		# filesystem tight enough that the alternative is not
		# finishing at all.
		#
		r := fs.reserve();
		(got, he) := fs.headroom(r);
		if(he != nil)
			return he;
		if(got < r && (e = fs.commit()) != nil)
			return e;
	}
	#
	# A directory must be empty.  Checked after the extents because a
	# directory has none, so the scan above costs nothing for one.
	#
	(kids, ke) := fs.range(ino, Efs->Kdentry);
	if(ke != nil)
		return ke;
	if(len kids > 0)
		return "directory not empty";
	if((e = fs.delete(Key(ino, Efs->Kinode, big 0))) != nil)
		return e;

	#
	# The inode is gone, so drop what the caches said about it, on both
	# exits: nothing can name it again.
	#
	par := parentof(ino);
	forget(ino);
	forgetparent(ino);
	if(par < big 0)
		return nil;		# never walked to; nothing names it here
	return deldentry(par, ino);
}

deldentry(dir: big, ino: big): string
{
	(ents, e) := fs.range(dir, Efs->Kdentry);
	if(e != nil)
		return e;
	for(i := 0; i < len ents; i++){
		(ci, nil, de) := dentry(ents[i].val);
		if(de == nil && ci == ino)
			return fs.delete(ents[i].key);
	}
	return nil;
}

#
# wstat, which is where rename lives.
#
# A rename is a KEY CHANGE and not the rewrite of an entry: the old
# name's directory entry goes, a new one arrives, and the file's inode
# -- and so its qid -- is untouched.  That is the property dossrv did
# not have, and it is what kupdate does to this board's kernel on every
# update.
#
wstat(ino: big, stat: Sys->Dir): string
{
	(v, e) := fs.get(Key(ino, Efs->Kinode, big 0));
	if(e != nil)
		return e;
	if(v == nil)
		return sys->sprint("no inode %bd", ino);
	(i, ie) := Inode.unpack(v);
	if(i == nil)
		return ie;

	changed := 0;
	if(wdebug)
		sys->fprint(stderr, "efs: wstat ino %bd name %q mode %#ux mtime %d length %bd\n",
			ino, stat.name, stat.mode, stat.mtime, stat.length);
	if(stat.name != nil && stat.name != ""){
		par := parentof(ino);
		if(par < big 0)
			return "cannot rename: this server has not seen the directory";
		#
		# Same two cases as create(), and for the same reason.
		#
		(rino, rnm, re) := dlook(par, stat.name);
		if(re != nil)
			return re;
		if(rino >= big 0){
			if(rnm == stat.name)
				return "file already exists";
			return sys->sprint(
				"name hash collision with %#q; efs holds one entry per key",
				rnm);
		}
		if((e = deldentry(par, ino)) != nil)
			return e;
		if((e = adddentry(par, stat.name, ino)) != nil)
			return e;
		#
		# Just remember it.  This also added the entry a second
		# time, unconditionally, so every rename grew the cache by
		# a cell, a tuple and a string that nothing would ever
		# remove -- and remember() already skips a name it holds.
		#
		forget(ino);
		remember(ino, stat.name);
		changed = 1;
	}
	#
	# Truncate.  Extents past the new length go, and the last one is
	# trimmed by its length field; the block itself is left as it is,
	# because the length is what says where the file ends.
	#
	if(stat.length != big -1 && stat.length != i.length){
		if((e = trimto(ino, i, stat.length)) != nil)
			return e;
		changed = 1;
	}
	if(!unchanged(stat.mode) && (stat.mode & 8r777) != (i.mode & 8r777)){
		i.mode = (i.mode & ~8r777) | (stat.mode & 8r777);
		changed = 1;
	}
	if(!unchanged(stat.mtime)){
		i.mtime = stat.mtime;
		changed = 1;
	}
	if(!changed)
		return nil;
	return fs.insert(Key(ino, Efs->Kinode, big 0), i.pack());
}
