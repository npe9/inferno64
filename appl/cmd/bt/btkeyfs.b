implement Btkeyfs;

#
# btkeyfs: the bonds, served.
#
# A long term key is not part of a controller.  It outlives the
# btfs that made it, it belongs to the pair of devices rather than
# to the radio the pairing happened to go through, and it is the one
# thing in the stack that must not be readable by everything that can
# see a radio.  So it is not a file btfs writes; it is a service btfs
# is a client of, and the only interface to it is the same one
# everything else here has: open, read, write.
#
#	/net/btkeys/ctl		bond ... / forget ... / sync
#	/net/btkeys/bonds	one line per bond
#
# A sibling of /net/bt and not a directory inside it: btfs mounts on
# /net/bt with MREPL, so anything mounted underneath first would go
# when it did.
#
# The lines are the format smp(2) parses and prints, so there is one
# parser for the wire, for the file, and for this, and no second one
# to drift.
#
# btfs reaches this over Styx -- which is to say over a channel -- and
# holds no key file of its own when it does.  That is the seam: the
# store is a process, what crosses to it is messages, and a second
# btfs on a second set of radios shares the same bonds by mounting the
# same service rather than by racing for the same file.
#
# On 9front this is one C program over lib9p serving the same names.
#

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Fid, Navigator, Navop: import styxservers;
	Enotfound, Eperm, Ebadarg: import styxservers;
	nametree: Nametree;
	Tree: import nametree;
include "bt.m";
	bt: Bt;
	hci: Hci;
	l2cap: L2cap;
	smp: Smp;
	Bond: import smp;

Btkeyfs: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Qroot, Qctl, Qbonds: con big iota;

mtpt:	con "/net/btkeys";

srv:	ref Styxserver;
tree:	ref Tree;

#
# the bonds, and the one lock over them.  Every reader and every
# writer is a Styx request answered in this process or in one spawned
# from it, and both the list and the file behind it move together, so
# one lock covers both rather than one each with an order to remember.
#
bonds:	list of ref Bond;
lock:	chan of int;
keyfile: string;

#
# who the files belong to.  btfs's own files are owned by "bt" and
# carry their permissions in the other bits, because everything about
# a radio is public; a key is not, so these are 0600 and the owner has
# to be the user who started the service or nobody can open them.
#
owner:	string;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	if(styx == nil)
		fail(sprint("cannot load %s: %r", Styx->PATH));
	styx->init();
	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil)
		fail(sprint("cannot load %s: %r", Styxservers->PATH));
	styxservers->init(styx);
	nametree = load Nametree Nametree->PATH;
	if(nametree == nil)
		fail(sprint("cannot load %s: %r", Nametree->PATH));
	nametree->init();
	arg := load Arg Arg->PATH;
	if(arg == nil)
		fail(sprint("cannot load %s: %r", Arg->PATH));
	bt = load Bt Bt->PATH;
	if(bt == nil)
		fail(sprint("cannot load %s: %r", Bt->PATH));
	bt->init();

	mnt := mtpt;
	arg->init(argv);
	arg->setusage("btkeyfs [-m mountpoint] [-f keyfile]");
	while((c := arg->opt()) != 0)
		case c {
		'm' =>	mnt = arg->arg();
		'f' =>	keyfile = arg->arg();
		* =>	arg->usage();
		}
	if(arg->argv() != nil)
		arg->usage();

	#
	# the whole stack is loaded for one thing: smp's Bond, so that
	# what is written down here and what pairing produced are the
	# same text run through the same code.  None of it touches a
	# controller; hci and l2cap are loaded because smp's init asks
	# for them.
	#
	hci = load Hci Hci->PATH;
	l2cap = load L2cap L2cap->PATH;
	smp = load Smp Smp->PATH;
	if(hci == nil || l2cap == nil || smp == nil)
		fail(sprint("cannot load the stack: %r"));
	if((e := hci->init(bt)) != nil)
		fail("hci: " + e);
	if((e = l2cap->init(bt, hci)) != nil)
		fail("l2cap: " + e);
	if((e = smp->init(bt, hci, l2cap)) != nil)
		fail("smp: " + e);

	owner = trim(readfile("/dev/user"));
	if(owner == nil)
		fail("cannot read /dev/user, so nothing could be given an owner");

	lock = chan[1] of int;
	lock <-= 1;

	navops: chan of ref Navop;
	(tree, navops) = nametree->start();
	nav := Navigator.new(navops);
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		fail(sprint("pipe: %r"));
	tchan: chan of ref Tmsg;
	(tchan, srv) = Styxserver.new(fds[0], nav, Qroot);
	srv.replychan = chan of ref Rmsg;
	spawn replier(srv.replychan);

	tree.create(Qroot, dir(".", Qroot, Sys->DMDIR|8r700, Sys->QTDIR));
	#
	# 0600 on both: a bond is a secret, and the whole point of
	# taking it out of btfs is that the radio being readable does
	# not make the key readable.
	#
	tree.create(Qroot, dir("ctl", Qctl, 8r600, Sys->QTFILE));
	tree.create(Qroot, dir("bonds", Qbonds, 8r400, Sys->QTFILE));

	readkeys();

	spawn serve(tchan);
	if(sys->mount(fds[1], nil, mnt, Sys->MREPL, nil) < 0)
		fail(sprint("mount %s: %r", mnt));
	sys->print("btkeyfs: serving %s\n", mnt);
}

replier(c: chan of ref Rmsg)
{
	for(;;){
		m := <-c;
		if(m == nil)
			return;
		srv.replydirect(m);
	}
}

dir(name: string, q: big, mode, qtype: int): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = d.gid = owner;
	d.qid.path = q;
	d.qid.qtype = qtype;
	d.mode = mode;
	d.mtime = d.atime = daytime();
	d.length = big 0;
	return d;
}

daytime(): int
{
	return int (sys->millisec() / 1000);
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

trim(s: string): string
{
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == ' '))
		s = s[0:len s - 1];
	return s;
}

serve(tchan: chan of ref Tmsg)
{
	for(;;){
		gm := <-tchan;
		if(gm == nil){
			tree.quit();
			exit;
		}
		pick m := gm {
		Readerror =>
			sys->fprint(sys->fildes(2), "btkeyfs: %s\n", m.error);
			tree.quit();
			exit;
		Read =>
			doread(m);
		Write =>
			dowrite(m);
		* =>
			srv.default(gm);
		}
	}
}

doread(m: ref Tmsg.Read)
{
	f := srv.getfid(m.fid);
	if(f == nil){
		srv.reply(ref Rmsg.Error(m.tag, Enotfound));
		return;
	}
	if(f.qtype & Sys->QTDIR){
		srv.default(m);
		return;
	}
	case int f.path {
	int Qbonds =>
		srv.reply(styxservers->readstr(m, bondtext()));
	int Qctl =>
		srv.reply(styxservers->readstr(m, ""));
	* =>
		srv.reply(ref Rmsg.Error(m.tag, Enotfound));
	}
}

dowrite(m: ref Tmsg.Write)
{
	f := srv.getfid(m.fid);
	if(f == nil){
		srv.reply(ref Rmsg.Error(m.tag, Enotfound));
		return;
	}
	if(f.path != Qctl){
		srv.reply(ref Rmsg.Error(m.tag, Eperm));
		return;
	}
	e := ctl(string m.data);
	if(e != nil){
		srv.reply(ref Rmsg.Error(m.tag, e));
		return;
	}
	srv.reply(ref Rmsg.Write(m.tag, len m.data));
}

#
# One write is one command.  A bond is given as the line the bonds
# file would show, so what a client read back it can write here
# unchanged; that is what makes copying a key store a cat away.
#
# This runs in the server process rather than in one spawned for it,
# unlike btfs, where a slow device must not stop the file server.
# There is no device here: what a command waits on is the store, and
# every request waits on the store, so answering one somewhere else
# would buy nothing and would let two writes from one client be
# applied in the other order.
#
ctl(s: string): string
{
	(n, f) := sys->tokenize(s, " \t\r\n");
	if(n == 0)
		return nil;
	case hd f {
	"bond" =>
		if(n < 3)
			return "usage: bond addr type [key value ...]";
		b := smp->parse(join(tl f));
		if(b == nil || len b.ltk == 0)
			return "bond: no key in that line";
		add(b);
	"forget" =>
		#
		# forget names a peer, and optionally the controller the
		# bond was made on: the same peer may be bonded to two
		# radios, and forgetting it on one is not forgetting it
		# on the other.
		#
		if(n < 2)
			return "usage: forget addr [on local]";
		addr := hd tl f;
		local := "";
		g := tl tl f;
		if(g != nil && hd g == "on" && tl g != nil)
			local = hd tl g;
		if(!forget(addr, local))
			return "no such bond";
	"sync" =>
		<-lock;
		writekeys(bondtext0());
		lock <-= 1;
	* =>
		return "unknown control message";
	}
	return nil;
}

join(f: list of string): string
{
	s := "";
	for(; f != nil; f = tl f){
		if(s != nil)
			s += " ";
		s += hd f;
	}
	return s;
}

#
# A bond replaces the one for the same peer on the same controller.
# Two radios bonded to one peer are two bonds and both are kept: the
# peripheral stores this side's identity address with the key, so the
# key agreed with one radio is not a key on the other.
#
add(b: ref Bond)
{
	<-lock;
	nl: list of ref Bond;
	for(l := bonds; l != nil; l = tl l){
		o := hd l;
		if(o.addr != b.addr || o.local != b.local)
			nl = o :: nl;
	}
	bonds = b :: rev(nl);
	writekeys(bondtext0());
	lock <-= 1;
}

forget(addr, local: string): int
{
	<-lock;
	nl: list of ref Bond;
	found := 0;
	for(l := bonds; l != nil; l = tl l){
		o := hd l;
		if(o.addr == addr && (local == "" || o.local == local)){
			found = 1;
			continue;
		}
		nl = o :: nl;
	}
	if(found){
		bonds = rev(nl);
		writekeys(bondtext0());
	}
	lock <-= 1;
	return found;
}

rev(l: list of ref Bond): list of ref Bond
{
	r: list of ref Bond;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

bondtext(): string
{
	<-lock;
	s := bondtext0();
	lock <-= 1;
	return s;
}

# with the lock already held
bondtext0(): string
{
	s := "";
	for(l := bonds; l != nil; l = tl l)
		s += (hd l).text() + "\n";
	return s;
}

readkeys()
{
	if(keyfile == nil)
		return;
	fd := sys->open(keyfile, Sys->OREAD);
	if(fd == nil){
		#
		# no key file yet is the ordinary first run and says
		# nothing.  One that is there and will not open is every
		# bond silently gone, which is worth a line.
		#
		(ok, nil) := sys->stat(keyfile);
		if(ok == 0)
			sys->fprint(sys->fildes(2),
				"btkeyfs: cannot read %s, so no bond is loaded: %r\n", keyfile);
		return;
	}
	buf := array[8192] of byte;
	s := "";
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[0:n];
	}
	(nil, lines) := sys->tokenize(s, "\n");
	nl: list of ref Bond;
	for(; lines != nil; lines = tl lines){
		b := smp->parse(hd lines);
		if(b != nil)
			nl = b :: nl;
	}
	bonds = rev(nl);
}

# with the lock already held
writekeys(s: string)
{
	if(keyfile == nil)
		return;
	#
	# truncate what is there rather than making it again: create on
	# an existing file is a create, and a store written 0600 by one
	# user cannot be created a second time by another.  It also
	# leaves whatever mode the file was given alone, which is the
	# administrator's business and not this program's.
	#
	fd := sys->open(keyfile, Sys->OWRITE|Sys->OTRUNC);
	if(fd == nil)
		fd = sys->create(keyfile, Sys->OWRITE, 8r600);
	if(fd == nil){
		# a bond that was not written down is a bond that will
		# not be there next time; say so rather than losing it
		# quietly
		sys->fprint(sys->fildes(2), "btkeyfs: cannot write %s: %r\n", keyfile);
		return;
	}
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		sys->fprint(sys->fildes(2), "btkeyfs: writing %s: %r\n", keyfile);
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "btkeyfs: %s\n", s);
	raise "fail:" + s;
}
