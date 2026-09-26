implement Efsfs;

#
# efs -- serve an efs filesystem.
#
#	efs [-a|-b] [-s startsector] -f device mountpoint
#
# READ ONLY, for now.  Milestone 3 of doc/efs-plan.ms is attach, walk,
# open, read, stat and directory listing; writes are milestone 4 and
# this refuses them rather than pretending.
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
include "efs.m";
	efs: Efs;
	Fs, Dev, Super, Node, Ent, Key, Inode: import efs;

Efsfs: module {
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

fs: ref Fs;
stderr: ref Sys->FD;

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
Eronly:  con "efs is read-only until milestone 4";

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

	arg := load Arg Arg->PATH;
	if(arg == nil)
		fail(sys->sprint("cannot load %s: %r", Arg->PATH));
	arg->init(argv);
	arg->setusage("efs [-a|-b] [-s startsector] -f device mountpoint");
	flags := Sys->MREPL;
	startsect := big 0;
	device := "";
	while((o := arg->opt()) != 0)
		case o {
		'a' =>	flags = Sys->MAFTER;
		'b' =>	flags = Sys->MBEFORE;
		's' =>	startsect = big arg->earg();
		'f' =>	device = arg->earg();
		'D' =>	styxservers->traceset(1);
		* =>	arg->usage();
		}
	argv = arg->argv();
	if(device == "" || len argv != 1)
		arg->usage();
	mountpt := hd argv;
	arg = nil;

	(f, e) := Fs.mount(device, startsect);
	if(f == nil)
		fail(sys->sprint("%s: %s", device, e));
	fs = f;
	sys->fprint(stderr,
		"efs: %s: %bd blocks, generation %bd from superblock %d\n",
		device, fs.s.nblocks, fs.s.gen, fs.which);

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		fail(sys->sprint("pipe: %r"));

	navops := chan of ref Navop;
	spawn navigator(navops);

	(tchan, srv) := Styxserver.new(fds[0], Navigator.new(navops), Rootino);
	fds[0] = nil;

	pidc := chan of int;
	spawn server(tchan, srv, pidc, navops);
	<-pidc;

	if(sys->mount(fds[1], nil, mountpt, flags, nil) < 0)
		fail(sys->sprint("mount %s: %r", mountpt));
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
	(ents, e) := fs.range(parent, Efs->Kdentry);
	if(e != nil)
		return (nil, e);
	for(i := 0; i < len ents; i++){
		(ino, nm, de) := dentry(ents[i].val);
		if(de != nil)
			return (nil, de);
		if(nm == name){
			remember(ino, nm);
			return dirof(ino);
		}
	}
	return (nil, Styxservers->Enotfound);
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

server(tchan: chan of ref Styx->Tmsg, srv: ref Styxserver,
	pidc: chan of int, navops: chan of ref Navop)
{
	pidc <-= sys->pctl(0, nil);
	for(;;){
		gm := <-tchan;
		if(gm == nil)
			break;
		pick m := gm {
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
			srv.reply(ref Rmsg.Error(m.tag, Eronly));
		Create =>
			srv.reply(ref Rmsg.Error(m.tag, Eronly));
		Remove =>
			srv.reply(ref Rmsg.Error(m.tag, Eronly));
		Wstat =>
			srv.reply(ref Rmsg.Error(m.tag, Eronly));
		* =>
			srv.default(gm);
		}
	}
	navops <-= nil;
}
