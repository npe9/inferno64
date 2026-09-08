implement Btfs;

#
# btfs: the Bluetooth stack as a file system.
#
# Bluetooth's own structure is a hierarchy -- a controller, the
# devices it can see, the services each device has, the
# characteristics inside a service -- so it is served as one, and
# there is no other interface: no ioctls, no sockets, no bus.  What
# a program does with Bluetooth here is open, read and write files.
#
#	/net/bt/0/addr			the controller's address
#	/net/bt/0/version		what the controller says it is
#	/net/bt/0/state			up, scanning, how many devices
#	/net/bt/0/ctl			scan on, connect, pair, ...
#	/net/bt/0/bonds			the keys pairing produced
#	/net/bt/0/remote/AA1122334455/
#		addr type rssi name adv state ctl
#		gatt/<service>/<characteristic>
#		gatt/<service>/<characteristic>.notify
#
# Reading a characteristic reads it off the device.  Opening a
# .notify file subscribes to that characteristic and each read
# returns the next notification; closing it unsubscribes.
#
# Anything that takes time off the machine -- a connection, pairing,
# an ATT round trip -- is answered by its own process, so one slow
# device does not stop the file server.  Replies are marshalled
# through one process, which is what makes that safe.
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
	t: Bttransport;
	hci: Hci;
	l2cap: L2cap;
	att: Att;
	gatt: Gatt;
	gattsrv: Gattsrv;
	smp: Smp;
	sdp: Sdp;
	Rec, Elem: import sdp;
	rfcomm: Rfcomm;
	Dlc: import rfcomm;
	Adv, Conn: import Hci;
	Mux: import L2cap;
	Chan: import L2cap;
	Sess: import Att;
	Service, Char: import Gatt;
	Bond: import smp;

Btfs: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Kroot, Kctlr, Kaddr, Kver, Kctl, Kstate, Kscan, Kremotes, Kbonds, Kdident, Kinc,
	Kdev, Kdaddr, Kdtype, Kdrssi, Kdname, Kdadv, Kdstate, Kdctl,
	Kdgatt, Ksvc, Kchar, Kcnotify, Kdesc, Kdl2cap, Kcoc, Kdsdp, Ksdp,
	Kdrfcomm, Krfdir, Krfdata,
	Klocal, Klsvc, Klchar: con iota;

Qroot:	con big 0;

#
# An open LE credit-based channel and the file that is it.  It hangs
# off the device rather than off its gatt tree, because it is not part
# of the database: a device that says its services have moved has not
# said anything about a channel, and rediscovery leaves it alone.
#
Coc: adt {
	psm:	int;
	#
	# What the file is called.  It is the PSM for the first channel
	# to it and the PSM and a number for any after that: AVDTP
	# needs two channels to one PSM -- signalling and media -- so a
	# PSM is not a name, and one file per PSM was one channel a
	# client could reach and one it could not.
	#
	name:	string;
	c:	ref L2cap->Chan;
	q:	big;		# the file
};

#
# One RFCOMM serial port and the file that is it.  Like a
# credit-based channel it hangs off the device rather than off any
# tree: it is not part of what SDP said, and rediscovering the device
# says nothing about a port that is open.
#
Rf: adt {
	ch:	int;		# the server channel
	d:	ref Dlc;
	dq:	big;		# its directory
	q:	big;		# the data file
};

Cnode: adt {
	c:	ref Char;
	q:	big;		# the value file
	nq:	big;		# the notification stream
	notify:	chan of array of byte;
	subs:	int;
};

Dev: adt {
	r:	ref Radio;	# the controller it was heard on
	q:	big;		# its directory
	gq:	big;		# its gatt directory
	dir:	string;		# the name of that directory, which is the
				# identity address once one is known and the
				# advertised address until then
	addr:	array of byte;	# where it is answering now: for a device
				# using resolvable private addresses this is
				# the current one, and it changes underneath
	atype:	int;
	#
	# A Classic device.  It is in the same directory as the LE ones
	# because it is the same question -- what is out there -- but
	# almost nothing else about it is the same: its address is a
	# BD_ADDR and never rotates, so there is no identity to resolve;
	# it answered an inquiry rather than advertising; and paging it
	# needs what it answered with.
	#
	classic: int;
	class:	int;		# class of device
	psrm:	int;		# page scan repetition mode
	clock:	int;		# clock offset
	named:	int;		# has its name been asked for
	id:	array of byte;	# its identity address, from a bond, or nil
	idtype:	int;
	seen:	int;		# when its last advertisement arrived
	scv:	int;		# the Service Changed value handle, or 0
	sccccd:	int;		# the descriptor its subscription was written to
	name:	string;
	rssi:	int;
	adv:	array of byte;
	state:	string;
	conn:	ref Conn;
	mux:	ref Mux;
	sess:	ref Sess;
	chars:	list of ref Cnode;
	sq:	big;		# its sdp directory, or 0
	lq:	big;		# its l2cap directory, or 0
	cocs:	list of ref Coc;
	rfs:	list of ref Rf;
	rsess:	ref Rfcomm->Sess;	# the multiplexer, once one is up
	rq:	big;			# its rfcomm directory, or 0
	lock:	chan of int;
};

Node: adt {
	q:	big;
	kind:	int;
	rad:	ref Radio;	# for the controller's own files
	dev:	ref Dev;
	cn:	ref Cnode;
	name:	string;
	text:	string;	# what a Kinc file reads as
	coc:	ref Coc;
	rf:	ref Rf;
	lc:	ref Lchar;
	dh:	int;	# the handle a Kdesc file reads
};

#
# One characteristic of the database this side serves, and the file
# that is it.  Reading the file reads what a peer would read; writing
# it sets what a peer will read next.
#
Lchar: adt {
	r:	ref Radio;
	uuid:	string;
	vh:	int;		# the value's handle in the database
	q:	big;
};

srv:	ref Styxserver;
tree:	ref Tree;
# Nametree's Tree sends on one channel and reads its reply from
# another, both shared: two processes in it at once can take each
# other's answer.  btfs is in it from three -- the scanner making
# devices, a connection making a gatt tree, and a link going away
# taking one down -- so every call goes through this.
treelock:	chan of int;
nodes:	array of ref Node;
nextq:	int;
#
# One controller and everything that belongs to it alone: the radio
# itself, the devices it has heard, and the bonds made on it.  This
# used to be the program's own variables and /net/bt/0 had the 0
# written into it; a second radio had nowhere to go.
#
Radio: adt {
	n:	int;			# which /net/bt/N
	x:	ref Hci->Ctlr;
	t:	Bttransport;
	spec:	string;
	q:	big;			# its directory
	rq:	big;			# its remote directory
	scanning:	int;
	advertising:	int;
	advname:	string;		# what the advertisement says we are
	advset:		int;		# have the parameters been set
	db:	ref Gattsrv->Db;	# what a peer that connects here reads
	lq:	big;			# the local gatt directory, or 0
	svcs:	list of (string, big);	# service uuid to its directory
	lchars:	list of ref Lchar;	# what each local file is
	devs:	list of ref Dev;
	devlock:	chan of int;
	bonds:	list of ref Bond;
	bondlock:	chan of int;
	#
	# What the controller says came of authenticating a BR/EDR
	# link, and the lock that makes there be one at a time.  The
	# event names a handle this side may already have given up on,
	# so what identifies the answer is that there is only one
	# question outstanding.
	#
	authc:	chan of string;
	authlock:	chan of int;
	#
	# What this side offers a Classic peer: the service records an
	# SDP search answers with, and the serial ports they describe.
	# It is the Classic half of db above, and it is per radio for
	# the same reason: two radios are two devices.
	#
	sdpdb:	list of ref Rec;
	serials:	list of int;
};

radios:	list of ref Radio;
#
# devlock covers devs and the Dev fields the scanner writes.  bonds is
# a second shared list with a second set of writers -- pair() adding
# one, readkeys() loading them at startup -- and since a resolvable
# address is resolved by walking it, the scanning process reads it on
# every advertisement from a private address.  It gets its own lock
# rather than being folded into devlock, because pair() cannot hold
# devlock: it is reached through target(), which takes it.
#
# Order, where both are held: devlock then bondlock.  resolved() is
# the only place that does, and nothing takes devlock while holding
# bondlock.
#
#
# Where the bonds are kept.  There are two ways: a key file this
# process writes, which is what -k gives, and a key service this
# process is a client of, which is what -K gives.  The service is the
# better one -- the store outlives this btfs, two btfs on two sets of
# radios share it, and the keys are not readable by everything that
# can read a radio -- and the file is kept because a machine with no
# btkeyfs mounted still has to be able to pair.  Both hold the same
# text, so a key file is a key service's file and the other way round.
#
# Either way it holds every controller's bonds, each line saying which
# controller it was made on, so writing it is not one radio's business
# and takes a lock of its own.  Order: keylock, then a radio's
# bondlock.  Nothing takes keylock while holding a bondlock.
#
keylock:	chan of int;
keyfile:	string;
keysrv:		string;
#
# how long a device that is not answering stays in /net/bt/0/remote.  A
# scan in a room with a hundred devices in it fills the directory and
# the table behind it, and nothing here is interested in a device that
# stopped advertising a quarter of an hour ago.  0 keeps everything,
# which is what the -a flag is for when someone wants the old
# behaviour.
#
ageout:	int	= 300;

# how long the controller has to finish authenticating a BR/EDR link,
# which includes however long the peer takes to agree
Authwait:	con 30000;
Reapevery:	con 5;	# seconds between sweeps
mtpt:	con "/net/bt";

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	styx = load Styx Styx->PATH;
	styx->init();
	styxservers = load Styxservers Styxservers->PATH;
	styxservers->init(styx);
	nametree = load Nametree Nametree->PATH;
	nametree->init();

	bt = load Bt Bt->PATH;
	if(bt == nil)
		fail(sprint("cannot load %s: %r", Bt->PATH));
	bt->init();

	tpath := Bttransport->H4PATH;
	mnt := mtpt;

	arg->init(argv);
	arg->setusage("btfs [-u5] [-m mountpoint] [-k keyfile] [-K keydir] [-a seconds] [device ...]");
	usb := 0;
	h5 := 0;
	while((c := arg->opt()) != 0)
		case c {
		'u' =>	usb = 1;
		'5' =>	h5 = 1;
		'm' =>	mnt = arg->arg();
		'k' =>	keyfile = arg->arg();
		'K' =>	keysrv = arg->arg();
		'a' =>
			v := arg->arg();
			# 0 is a real answer -- keep everything -- so a
			# argument that is not a number must not quietly
			# become it
			if(!digits(v))
				arg->usage();
			ageout = int v;
		* =>	arg->usage();
		}
	specs := arg->argv();
	# both would be two stores holding the same bonds and disagreeing
	# about them the moment either is written without the other
	if(keyfile != nil && keysrv != nil)
		fail("-k and -K are two key stores: give one");
	if(usb)
		tpath = Bttransport->USBPATH;
	else if(h5)
		tpath = Bttransport->H5PATH;
	if(specs == nil && !usb)
		specs = "/dev/eia1!115200" :: nil;
	if(specs == nil)
		fail("no controller: say which device to open");

	hci = load Hci Hci->PATH;
	l2cap = load L2cap L2cap->PATH;
	att = load Att Att->PATH;
	gatt = load Gatt Gatt->PATH;
	gattsrv = load Gattsrv Gattsrv->PATH;
	smp = load Smp Smp->PATH;
	sdp = load Sdp Sdp->PATH;
	rfcomm = load Rfcomm Rfcomm->PATH;
	if(hci == nil || l2cap == nil || att == nil || gatt == nil
	|| gattsrv == nil || smp == nil || sdp == nil || rfcomm == nil)
		fail(sprint("cannot load the stack: %r"));

	if((e := hci->init(bt)) != nil)
		fail("hci: " + e);
	if((e = l2cap->init(bt, hci)) != nil)
		fail("l2cap: " + e);
	if((e = att->init(bt, l2cap)) != nil)
		fail("att: " + e);
	if((e = gatt->init(bt, att)) != nil)
		fail("gatt: " + e);
	if((e = gattsrv->init(bt, l2cap)) != nil)
		fail("gatt server: " + e);
	if((e = smp->init(bt, hci, l2cap)) != nil)
		fail("smp: " + e);
	if((e = sdp->init(bt, l2cap)) != nil)
		fail("sdp: " + e);
	if((e = rfcomm->init(bt, l2cap)) != nil)
		fail("rfcomm: " + e);

	keylock = chan[1] of int;
	keylock <-= 1;
	treelock = chan[1] of int;
	treelock <-= 1;
	nodes = array[64] of ref Node;
	# node 0 is the root of the served tree, so the first name
	# created below does not take its qid
	nodes[0] = ref Node(Qroot, Kroot, nil, nil, nil, ".", nil, nil, nil, nil, 0);
	nextq = 1;

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

	buildroot();

	#
	# One radio per device named on the command line.  Each gets its
	# own transport and its own controller: a second load of the
	# same module has its own module data, which is what makes two
	# radios in one program possible at all.
	#
	n := 0;
	rl: list of ref Radio;
	for(sl := specs; sl != nil; sl = tl sl){
		r := ref Radio;
		#
		# All of it, including the scalars that start at zero: a
		# ref adt's integer fields hold whatever was in the heap,
		# so a radio could otherwise begin believing it was
		# already scanning, or advertising, or that its
		# advertising parameters had been set.
		#
		r.n = n++;
		r.spec = hd sl;
		r.scanning = 0;
		r.advertising = 0;
		r.advset = 0;
		r.advname = nil;
		r.lq = big 0;
		r.q = big 0;
		r.rq = big 0;
		r.devs = nil;
		r.bonds = nil;
		r.svcs = nil;
		r.lchars = nil;
		r.devlock = chan[1] of int;
		r.devlock <-= 1;
		r.bondlock = chan[1] of int;
		r.bondlock <-= 1;
		r.authc = chan[1] of string;
		r.authlock = chan[1] of int;
		r.authlock <-= 1;
		r.sdpdb = nil;
		r.serials = nil;
		r.db = gattsrv->newdb();
		r.t = load Bttransport tpath;
		if(r.t == nil)
			fail(sprint("cannot load %s: %r", tpath));
		if((te := r.t->init(bt, r.spec)) != nil)
			fail(sprint("transport %s: %s", r.spec, te));
		(x, ce) := hci->start(r.t);
		if(ce != nil)
			fail(sprint("controller %s: %s", r.spec, ce));
		r.x = x;
		buildradio(r);
		rl = r :: rl;
	}
	# built head first, so put them back in the order they were given
	for(; rl != nil; rl = tl rl)
		radios = hd rl :: radios;

	readkeys();

	# no NEWPGRP: the mount below belongs in the name space of
	# whoever started btfs, not in a private one
	for(al := radios; al != nil; al = tl al){
		spawn advproc(hd al);
		spawn inqproc(hd al);
		spawn secproc(hd al);
		spawn inproc(hd al);
	}
	spawn reaper();
	spawn serve(tchan);

	if(sys->mount(fds[1], nil, mnt, Sys->MREPL, nil) < 0)
		fail(sprint("mount %s: %r", mnt));
	sys->print("btfs: serving %s\n", mnt);
}

#
# every reply goes out through this one process, so a process that
# answers a slow request can reply from wherever it is
#
replier(c: chan of ref Rmsg)
{
	for(;;){
		m := <-c;
		if(m == nil)
			return;
		srv.replydirect(m);
	}
}

#
# the fixed part of the name space
#
buildroot()
{
	create(Qroot, mkdir(".", Qroot));
}

#
# one controller's fixed files.  The number is the radio's, not a
# constant: /net/bt/0 and /net/bt/1 are two radios in one program
# rather than two programs.
#
buildradio(r: ref Radio)
{
	name := string r.n;
	r.q = newnode(Kctlr, r, nil, nil, name);
	create(Qroot, mkdir(name, r.q));
	mkf(r.q, "addr", Kaddr, 8r444, r);
	mkf(r.q, "version", Kver, 8r444, r);
	mkf(r.q, "state", Kstate, 8r444, r);
	mkf(r.q, "scan", Kscan, 8r444, r);
	mkf(r.q, "bonds", Kbonds, 8r444, r);
	mkf(r.q, "ctl", Kctl, 8r666, r);
	r.rq = newnode(Kremotes, r, nil, nil, "remote");
	create(r.q, mkdir("remote", r.rq));
}

newnode(kind: int, r: ref Radio, d: ref Dev, cn: ref Cnode, name: string): big
{
	if(nextq >= len nodes){
		a := array[2*len nodes] of ref Node;
		a[0:] = nodes;
		nodes = a;
	}
	q := big nextq;
	nodes[nextq] = ref Node(q, kind, r, d, cn, name, nil, nil, nil, nil, 0);
	nextq++;
	return q;
}

node(q: big): ref Node
{
	i := int q;
	if(i < 0 || i >= nextq)
		return nil;
	return nodes[i];
}

mkf(parent: big, name: string, kind, mode: int, r: ref Radio): big
{
	q := newnode(kind, r, nil, nil, name);
	create(parent, mkfile(name, q, mode));
	return q;
}

mkfd(parent: big, name: string, kind, mode: int, d: ref Dev, cn: ref Cnode): big
{
	q := newnode(kind, d.r, d, cn, name);
	create(parent, mkfile(name, q, mode));
	return q;
}

create(parent: big, d: Sys->Dir)
{
	<-treelock;
	tree.create(parent, d);
	treelock <-= 1;
}

#
# Removing a node takes it out of the node table as well as out of the
# tree.  A fid walked before the removal still names the qid, and node()
# is what turns that back into a Node: while the table kept the entry, a
# client holding a characteristic file open across a disconnect and a
# reconnect read through the old Cnode -- the old handle, on the new
# session, against a database the device may have rearranged in
# between.  It now finds nothing there and gets an error, which is what
# a file that has gone should do.
#
remove(q: big)
{
	<-treelock;
	tree.remove(q);
	treelock <-= 1;
	i := int q;
	if(i >= 0 && i < nextq)
		nodes[i] = nil;
}

mkdir(name: string, q: big): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = d.gid = "bt";
	d.qid.path = q;
	d.qid.qtype = Sys->QTDIR;
	d.mode = Sys->DMDIR | 8r555;
	d.mtime = d.atime = daytime();
	return d;
}

mkfile(name: string, q: big, mode: int): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = d.gid = "bt";
	d.qid.path = q;
	d.qid.qtype = Sys->QTFILE;
	d.mode = mode;
	d.mtime = d.atime = daytime();
	d.length = big 0;
	return d;
}

digits(s: string): int
{
	if(s == nil)
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return 1;
}

daytime(): int
{
	return int (sys->millisec() / 1000);
}

#
# advertising reports: a device appears the first time it is heard
#
#
# Devices that have stopped answering leave /net/bt/0/remote.  Without
# this a scan in a busy room fills the directory and the node table
# behind it and nothing ever comes back out.
#
# Three are kept whatever their age, and each for a reason worth
# stating rather than leaving to be read out of the condition:
#
#	a connected device, because it is plainly there and an
#	advertisement is not how it is being talked to;
#	a device with an identity from a bond, because a bond exists in
#	order to find that device again and forgetting it undoes the
#	work of pairing;
#	every device, while scanning is off, because then nothing is
#	arriving and age says nothing about whether a device is there.
#
reaper()
{
	for(;;){
		sys->sleep(Reapevery * 1000);
		if(ageout <= 0)
			continue;
		for(rl := radios; rl != nil; rl = tl rl)
			sweep(hd rl);
	}
}

sweep(r: ref Radio)
{
	if(!r.scanning)
		return;
	now := daytime();
	#
	# Taken in two parts, and the order matters both ways.
	# dropdev needs the device's own lock -- it takes the
	# gatt tree down, which connect() and rediscover() do
	# under that lock -- and connect() holds it for as long
	# as a connection attempt takes, which is twenty seconds
	# against a controller that never answers.  Waiting for
	# it with devlock held would stop the scanner and every
	# control write for that long, so the candidates are
	# taken out of devs under devlock, devlock is dropped,
	# and each is then waited for on its own.
	#
	# Nothing holds a device's lock and then asks for
	# devlock, so this order cannot deadlock: pair() is the
	# one place that wants both and it lets go of the
	# device's lock first.
	#
	<-r.devlock;
	keep: list of ref Dev;
	gone: list of ref Dev;
	for(l := r.devs; l != nil; l = tl l){
		d := hd l;
		if(d.conn != nil || d.id != nil || now - d.seen < ageout)
			keep = d :: keep;
		else
			gone = d :: gone;
	}
	r.devs = keep;
	r.devlock <-= 1;
	for(l = gone; l != nil; l = tl l){
		d := hd l;
		<-d.lock;
		#
		# it was chosen without its lock, so it may have
		# become something worth keeping while this was
		# waiting for it -- a connection that had not
		# finished when the sweep looked, or a bond that
		# has just given it an identity.  Put it back.
		#
		#
		# scanning is looked at again as well: it can be
		# turned off between the sweep choosing a device
		# and getting its lock, and "nothing is forgotten
		# while scanning is off" should be true rather
		# than nearly true.
		#
		if(d.conn != nil || d.id != nil || !r.scanning){
			d.lock <-= 1;
			<-r.devlock;
			r.devs = d :: r.devs;
			r.devlock <-= 1;
			continue;
		}
		sys->fprint(sys->fildes(2),
			"btfs: %s: not heard from for %ds, forgotten\n",
			d.dir, now - d.seen);
		dropdev(d);
		d.lock <-= 1;
	}
}

advproc(r: ref Radio)
{
	c := hci->advs(r.x);
	for(;;){
		a := <-c;
		if(a == nil)
			return;
		<-r.devlock;
		d := finddev(r, a.addr);
		if(d == nil)
			d = resolved(r, a.atype, a.addr);
		if(d == nil){
			d = newdev(r, bt->addrstr(a.addr), a.addr, a.atype);
			r.devs = d :: r.devs;
		}
		#
		# a device that rotates its address is the same device
		# and keeps its directory, but the address to connect to
		# is the one it is answering on now, not the one it was
		# first seen from.
		#
		d.addr = a.addr;
		d.rssi = a.rssi;
		d.atype = a.atype;
		d.seen = daytime();
		if(len a.data > 0)
			d.adv = a.data;
		nm := advname(a.data);
		if(nm != nil)
			d.name = nm;
		r.devlock <-= 1;
	}
}

#
# What an inquiry hears.  The shape is advproc's -- a channel of
# results, one device per result, the device table under its lock --
# and the differences are the Classic ones: an inquiry ends, which
# arrives as a nil; an address never rotates, so there is nothing to
# resolve; and a name is not in the result unless the device sent an
# extended inquiry response, so one that did not has to be asked, over
# a page, which cannot be done under the lock.
#
inqproc(r: ref Radio)
{
	c := hci->inqs(r.x);
	for(;;){
		q := <-c;
		if(q == nil)
			continue;	# the inquiry ended; the controller knows
		<-r.devlock;
		d := finddev(r, q.addr);
		if(d == nil){
			d = newdev(r, bt->addrstr(q.addr), q.addr, Bt->Apublic);
			d.classic = 1;
			r.devs = d :: r.devs;
		}
		d.classic = 1;
		d.class = q.class;
		d.psrm = q.psrm;
		d.clock = q.clock;
		d.rssi = q.rssi;
		d.seen = daytime();
		if(q.eir != nil){
			d.adv = q.eir;
			nm := advname(q.eir);
			if(nm != nil){
				d.name = nm;
				d.named = 1;
			}
		}
		ask := d.name == nil && !d.named;
		if(ask)
			d.named = 1;	# once, not once per result
		r.devlock <-= 1;
		if(ask)
			spawn nameproc(r, d);
	}
}

#
# Ask a Classic device its name.  It is a page and it takes time, so
# it is its own process and holds no lock while it waits; a device
# that will not answer is left with no name rather than with a wrong
# one, and named stops it being asked again on every inquiry result.
#
nameproc(r: ref Radio, d: ref Dev)
{
	(nm, e) := hci->remotename(r.x, d.addr, d.psrm, d.clock);
	if(e != nil || nm == nil)
		return;
	<-r.devlock;
	d.name = nm;
	r.devlock <-= 1;
}

finddev(r: ref Radio, addr: array of byte): ref Dev
{
	s := bt->addrstr(addr);
	for(l := r.devs; l != nil; l = tl l)
		if(bt->addrstr((hd l).addr) == s)
			return hd l;
	return nil;
}

#
# the path walk names a device by its directory, which is its identity
# address once there is a bond to give one -- not by whatever address
# it is advertising from this minute.
#
finddevstr(r: ref Radio, s: string): ref Dev
{
	for(l := r.devs; l != nil; l = tl l)
		if((hd l).dir == s)
			return hd l;
	return nil;
}

#
# A resolvable private address is a stranger until some bond's
# identity resolving key accounts for it.  Try every bond; a match
# names the device, and the device already has a directory under that
# name if it has ever been seen.  This is what makes a bond usable:
# without it a peripheral that rotates its address every fifteen
# minutes is a new device in /net/bt/0/remote every fifteen minutes
# and the keys stored against the old one are never reachable again.
#
resolved(r: ref Radio, atype: int, addr: array of byte): ref Dev
{
	if(!bt->resolvable(atype, addr))
		return nil;
	<-r.bondlock;
	bl := r.bonds;
	r.bondlock <-= 1;
	for(; bl != nil; bl = tl bl){
		b := hd bl;
		if(!smp->resolve(b, atype, addr))
			continue;
		id := bt->straddr(b.addr);
		if(id == nil)
			continue;
		for(l := r.devs; l != nil; l = tl l){
			d := hd l;
			if(d.id != nil && bt->addrstr(d.id) == b.addr)
				return d;
			#
			# the device is listed under its identity address
			# already -- it was heard from directly before, or
			# a saved key file gave the bond back after a
			# restart and nothing has set the identity on it
			# yet.  Adopt it; making a second directory of the
			# same name would be the bug.
			#
			if(d.dir == b.addr){
				d.id = id;
				d.idtype = b.atype;
				return d;
			}
		}
		#
		# resolved to a bond whose device is not in the table:
		# the directory is named by the identity, not by the
		# address it happens to be using.
		#
		d := newdev(r, b.addr, addr, atype);
		d.id = id;
		d.idtype = b.atype;
		r.devs = d :: r.devs;
		return d;
	}
	return nil;
}

newdev(r: ref Radio, name: string, addr: array of byte, atype: int): ref Dev
{
	d := ref Dev;
	d.r = r;
	d.dir = name;
	d.addr = addr;
	d.atype = atype;
	d.state = "seen";
	d.seen = daytime();
	# the rest of the scalars, for the reason above
	d.classic = 0;
	d.class = 0;
	d.psrm = 0;
	d.clock = 0;
	d.named = 0;
	d.scv = 0;
	d.sccccd = 0;
	d.idtype = 0;
	d.rssi = 0;
	d.id = nil;
	d.name = nil;
	d.adv = nil;
	d.conn = nil;
	d.mux = nil;
	d.sess = nil;
	d.chars = nil;
	d.cocs = nil;
	d.rfs = nil;
	d.rsess = nil;
	d.rq = big 0;
	d.lq = big 0;
	d.sq = big 0;
	d.gq = big 0;
	d.lock = chan[1] of int;
	d.lock <-= 1;
	d.q = newnode(Kdev, r, d, nil, name);
	create(r.rq, mkdir(name, d.q));
	mkfd(d.q, "addr", Kdaddr, 8r444, d, nil);
	mkfd(d.q, "identity", Kdident, 8r444, d, nil);
	mkfd(d.q, "type", Kdtype, 8r444, d, nil);
	mkfd(d.q, "rssi", Kdrssi, 8r444, d, nil);
	mkfd(d.q, "name", Kdname, 8r444, d, nil);
	mkfd(d.q, "adv", Kdadv, 8r444, d, nil);
	mkfd(d.q, "state", Kdstate, 8r444, d, nil);
	mkfd(d.q, "ctl", Kdctl, 8r666, d, nil);
	return d;
}

#
# the local name a device puts in its advertisement: AD type 9 is the
# complete one, 8 the shortened one
#
advname(a: array of byte): string
{
	i := 0;
	while(i < len a){
		l := int a[i];
		if(l == 0 || i + 1 + l > len a)
			break;
		ty := int a[i+1];
		if(ty == 16r09 || ty == 16r08)
			return string a[i+2:i+1+l];
		i += 1 + l;
	}
	return nil;
}

#
# the file server
#
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
			sys->fprint(sys->fildes(2), "btfs: %s\n", m.error);
			tree.quit();
			exit;
		Open =>
			doopen(m);
		Read =>
			doread(m);
		Write =>
			dowrite(m);
		Clunk =>
			doclunk(m);
		* =>
			srv.default(gm);
		}
	}
}

doopen(m: ref Tmsg.Open)
{
	f := srv.getfid(m.fid);
	if(f == nil){
		srv.reply(ref Rmsg.Error(m.tag, Enotfound));
		return;
	}
	n := node(f.path);
	if(n != nil && n.kind == Kcnotify){
		# opening the stream is what subscribes
		spawn subopen(m, n);
		return;
	}
	srv.default(m);
}

subopen(m: ref Tmsg.Open, n: ref Node)
{
	d := n.dev;
	<-d.lock;
	e := "";
	if(n.cn.subs == 0){
		if(d.sess == nil)
			e = "not connected";
		else
			e = gatt->subscribe(d.sess, n.cn.c, 1);
	}
	if(e == nil || e == "")
		n.cn.subs++;
	d.lock <-= 1;
	if(e != nil && e != ""){
		srv.reply(ref Rmsg.Error(m.tag, e));
		return;
	}
	srv.default(m);
}

doclunk(m: ref Tmsg.Clunk)
{
	f := srv.getfid(m.fid);
	if(f != nil && f.isopen){
		n := node(f.path);
		if(n != nil && n.kind == Kcnotify && n.cn.subs > 0){
			n.cn.subs--;
			if(n.cn.subs == 0 && n.dev.sess != nil)
				spawn unsub(n);
		}
	}
	srv.default(m);
}

unsub(n: ref Node)
{
	d := n.dev;
	<-d.lock;
	if(d.sess != nil)
		gatt->subscribe(d.sess, n.cn.c, 0);
	d.lock <-= 1;
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
	n := node(f.path);
	if(n == nil){
		srv.reply(ref Rmsg.Error(m.tag, Enotfound));
		return;
	}
	case n.kind {
	Kaddr =>
		srv.reply(styxservers->readstr(m, bt->addrstr(hci->localaddr(n.rad.x)) + "\n"));
	Kver =>
		srv.reply(styxservers->readstr(m, hci->localver(n.rad.x) + "\n"));
	Kstate =>
		srv.reply(styxservers->readstr(m, ctlrstate(n.rad)));
	Kscan =>
		s := "off\n";
		if(n.rad.scanning)
			s = "on\n";
		srv.reply(styxservers->readstr(m, s));
	Kbonds =>
		srv.reply(styxservers->readstr(m, bondtext(n.rad)));
	Kctl or Kdctl =>
		srv.reply(styxservers->readstr(m, ""));
	Kdaddr =>
		srv.reply(styxservers->readstr(m, bt->addrstr(n.dev.addr) + "\n"));
	Kdtype =>
		#
		# A Classic device has no LE address type: its address is
		# a BD_ADDR, which is what "classic" says.  The class of
		# device goes on the same line because it is the only
		# thing an inquiry says about what the device is.
		#
		if(n.dev.classic)
			srv.reply(styxservers->readstr(m,
				sprint("classic class %6.6ux\n", n.dev.class)));
		else
			srv.reply(styxservers->readstr(m, bt->atypestr(n.dev.atype) + "\n"));
	Kdident =>
		srv.reply(styxservers->readstr(m, identtext(n.dev)));
	Kinc or Ksdp =>
		srv.reply(styxservers->readstr(m, n.text));
	Kdrssi =>
		srv.reply(styxservers->readstr(m, sprint("%d\n", n.dev.rssi)));
	Kdname =>
		srv.reply(styxservers->readstr(m, n.dev.name + "\n"));
	Kdadv =>
		srv.reply(styxservers->readstr(m, bt->hex(n.dev.adv) + "\n"));
	Kdstate =>
		srv.reply(styxservers->readstr(m, devstate(n.dev)));
	Kchar =>
		spawn readchar(m, n);
	Kdesc =>
		spawn readdesc(m, n);
	Kcnotify =>
		spawn readnotify(m, n);
	Kcoc =>
		spawn readcoc(m, n);
	Krfdata =>
		spawn readrf(m, n);
	Klchar =>
		#
		# what a peer would read: the value in the database,
		# which is what this side last set or what a peer last
		# wrote
		#
		srv.reply(styxservers->readbytes(m, gattsrv->getval(n.rad.db, n.lc.vh)));
	* =>
		srv.reply(ref Rmsg.Error(m.tag, Enotfound));
	}
}

ctlrstate(r: ref Radio): string
{
	<-r.devlock;
	nd := len r.devs;
	r.devlock <-= 1;
	sc := "off";
	if(r.scanning)
		sc = "on";
	ad := "off";
	if(r.advertising)
		ad = "on";
	iq := "off";
	if(hci->inquiring(r.x))
		iq = "on";
	(sz, nb) := hci->aclmtu(r.x);
	s := sprint("addr %s scan %s inquiry %s advertise %s devices %d connections %d aclsize %d aclbufs %d",
		bt->addrstr(hci->localaddr(r.x)), sc, iq, ad, nd, len hci->conns(r.x), sz, nb);
	# only when there are any: a controller that has never sent one
	# has nothing to report, and the line is what btfs(4) describes
	if((n := hci->scodropped(r.x)) > 0)
		s += sprint(" scodropped %d", n);
	return s + "\n";
}

#
# the identity behind the address, when a bond has given one.  A
# device that has never paired has no identity to state, and one that
# is not using a private address is already answering on its own.
#
identtext(d: ref Dev): string
{
	if(d.id == nil)
		return "none\n";
	s := bt->addrstr(d.id) + " " + bt->atypestr(d.idtype);
	if(bt->resolvable(d.atype, d.addr))
		s += " resolved from " + bt->addrstr(d.addr);
	return s + "\n";
}

devstate(d: ref Dev): string
{
	s := d.state;
	if(d.conn == nil)
		s += sprint(", last heard from %ds ago", daytime() - d.seen);
	if(d.conn != nil){
		s = sprint("connected handle %d", d.conn.handle);
		if(d.conn.role == Hci->Rperipheral)
			s += " peripheral";	# the peer opened this one
		else
			s += " central";
		if(d.conn.encrypted)
			s += " encrypted";
		if(d.sess != nil)
			s += sprint(" mtu %d", d.sess.mtu);
		#
		# what the link is actually running at, which is not
		# what was asked for if the peer has since asked for
		# something else and this side agreed.  A BR/EDR link
		# has none of these -- they are the LE connection
		# parameters -- so it says what it is instead of three
		# zeroes that would read as a link running at nothing.
		#
		if(d.conn.classic)
			s += " br/edr";
		else
			s += sprint(" interval %d latency %d timeout %d",
				d.conn.interval, d.conn.latency, d.conn.timeout);
	}
	s += "\n";
	#
	# one line per open credit-based channel, with the sizes both
	# sides settled on: the MTU is the largest a read or a write may
	# be, and the MPS is what goes on the link at once.
	#
	for(l := d.cocs; l != nil; l = tl l){
		co := hd l;
		s += sprint("l2cap psm %#4.4ux cid %#4.4ux dcid %#4.4ux mtu %d mps %d dmtu %d dmps %d\n",
			co.psm, co.c.cid, co.c.dcid, co.c.mtu, co.c.mps, co.c.dmtu, co.c.dmps);
	}
	return s;
}

bondtext(r: ref Radio): string
{
	<-r.bondlock;
	s := bondtext0(r);
	r.bondlock <-= 1;
	return s;
}

# with the radio's bondlock already held
bondtext0(r: ref Radio): string
{
	s := "";
	for(l := r.bonds; l != nil; l = tl l)
		s += (hd l).text() + "\n";
	return s;
}

readchar(m: ref Tmsg.Read, n: ref Node)
{
	d := n.dev;
	<-d.lock;
	if(d.sess == nil){
		d.lock <-= 1;
		srv.reply(ref Rmsg.Error(m.tag, "not connected"));
		return;
	}
	(v, e) := gatt->read(d.sess, n.cn.c.vhandle);
	d.lock <-= 1;
	if(e != nil){
		srv.reply(ref Rmsg.Error(m.tag, e));
		return;
	}
	srv.reply(styxservers->readbytes(m, v));
}

#
# a descriptor.  It is read off the device by handle rather than
# through a Char, because a descriptor is not a characteristic: it has
# no properties, no notification and no value handle of its own.
#
readdesc(m: ref Tmsg.Read, n: ref Node)
{
	d := n.dev;
	<-d.lock;
	if(d.sess == nil){
		d.lock <-= 1;
		srv.reply(ref Rmsg.Error(m.tag, "not connected"));
		return;
	}
	(v, e) := gatt->read(d.sess, n.dh);
	d.lock <-= 1;
	if(e != nil){
		srv.reply(ref Rmsg.Error(m.tag, e));
		return;
	}
	srv.reply(styxservers->readbytes(m, v));
}

#
# a notification stream: each read is the next notification, and a
# read waits for one
#
#
# a stream, not a file: each read is the next notification whole, and
# the offset means nothing.  readbytes() would apply the offset and
# turn the second read into an end of file, which is what it did.
#
readnotify(m: ref Tmsg.Read, n: ref Node)
{
	v := <-n.cn.notify;
	if(v == nil){
		srv.reply(ref Rmsg.Read(m.tag, nil));
		return;
	}
	if(len v > m.count)
		v = v[0:m.count];
	srv.reply(ref Rmsg.Read(m.tag, v));
}

dowrite(m: ref Tmsg.Write)
{
	f := srv.getfid(m.fid);
	if(f == nil){
		srv.reply(ref Rmsg.Error(m.tag, Enotfound));
		return;
	}
	n := node(f.path);
	if(n == nil){
		srv.reply(ref Rmsg.Error(m.tag, Enotfound));
		return;
	}
	case n.kind {
	Kctl =>
		spawn ctlwrite(m, n.rad, nil, string m.data);
	Kdctl =>
		spawn ctlwrite(m, n.dev.r, n.dev, string m.data);
	Kchar =>
		spawn writechar(m, n);
	Kcoc =>
		spawn writecoc(m, n);
	Krfdata =>
		spawn writerf(m, n);
	Klchar =>
		spawn writelocal(m, n);
	* =>
		srv.reply(ref Rmsg.Error(m.tag, Eperm));
	}
}

writechar(m: ref Tmsg.Write, n: ref Node)
{
	d := n.dev;
	<-d.lock;
	if(d.sess == nil){
		d.lock <-= 1;
		srv.reply(ref Rmsg.Error(m.tag, "not connected"));
		return;
	}
	#
	# Which of the two writes this characteristic takes.  A
	# characteristic that has write without response and not write
	# must be written with a command: a Write Request to it is
	# answered by a real device with Write Not Permitted, and the
	# bench did not notice because the model this side was written
	# against took either.  Wireshark did.
	#
	e: string;
	if((n.cn.c.props & Gatt->Pwrite) == 0
	&& (n.cn.c.props & Gatt->Pwritenoresp) != 0)
		e = gatt->writecmd(d.sess, n.cn.c.vhandle, m.data);
	else
		e = gatt->write(d.sess, n.cn.c.vhandle, m.data);
	d.lock <-= 1;
	if(e != nil){
		srv.reply(ref Rmsg.Error(m.tag, e));
		return;
	}
	srv.reply(ref Rmsg.Write(m.tag, len m.data));
}

#
# the control commands.  A device's own ctl file takes the same
# words without the address.
#
ctlwrite(m: ref Tmsg.Write, r: ref Radio, d: ref Dev, s: string)
{
	(nil, f) := sys->tokenize(s, " \t\r\n");
	if(f == nil){
		srv.reply(ref Rmsg.Write(m.tag, len m.data));
		return;
	}
	cmd := hd f;
	f = tl f;
	e := "";
	case cmd {
	"scan" =>
		on := 1;
		if(f != nil && hd f == "off")
			on = 0;
		e = hci->lescan(r.x, on);
		if(e == nil)
			r.scanning = on;
	"connect" =>
		(dd, ee) := target(r, d, f);
		if(ee != nil)
			e = ee;
		else
			e = connect(dd);
	"disconnect" =>
		(dd, ee) := target(r, d, f);
		if(ee != nil)
			e = ee;
		else
			e = disconnect(dd);
	"pair" =>
		(dd, ee) := target(r, d, f);
		if(ee != nil)
			e = ee;
		else
			e = pair(dd);
	"params" =>
		#
		# ask for different connection parameters.  A peripheral
		# can only ask; the central is the side that can do it,
		# and this is the side that is the central.
		#
		# Written to the device's own ctl and not to the
		# controller's: every other verb there takes an address
		# and would leave four numbers behind it to be told apart
		# from an optional "random", which is a spelling nobody
		# should have to get right.
		#
		if(d == nil){
			e = "write params to the device's own ctl";
			break;
		}
		if(len4(f) != 4){
			e = "usage: params min max latency timeout";
			break;
		}
		<-d.lock;
		c := d.conn;
		d.lock <-= 1;
		if(c == nil)
			e = "not connected";
		else
			e = hci->leconnupdate(c, int hd f, int hd tl f,
				int hd tl tl f, int hd tl tl tl f);
	"l2cap" =>
		#
		# open an LE credit-based channel to a PSM.  On the
		# device's own ctl, like params, and for the same
		# reason: everything else there takes an address.
		#
		if(d == nil){
			e = "write l2cap to the device's own ctl";
			break;
		}
		if(f == nil){
			e = "usage: l2cap psm";
			break;
		}
		e = cocopen(d, hexnum(hd f));
	"rfcomm" =>
		#
		# open a serial port on a server channel, which is what
		# an sdp record's protocol descriptor list gives.  The
		# multiplexer under it is started on the first one and
		# shared by the rest.
		#
		if(d == nil){
			e = "write rfcomm to the device's own ctl";
			break;
		}
		if(f == nil || !digits(hd f)){
			e = "usage: rfcomm channel";
			break;
		}
		e = rfopen(d, int hd f);
	"unrfcomm" =>
		if(d == nil){
			e = "write unrfcomm to the device's own ctl";
			break;
		}
		if(f == nil || !digits(hd f)){
			e = "usage: unrfcomm channel";
			break;
		}
		e = rfclose(d, int hd f);
	"unl2cap" =>
		if(d == nil){
			e = "write unl2cap to the device's own ctl";
			break;
		}
		if(f == nil){
			e = "usage: unl2cap psm";
			break;
		}
		e = cocclose(d, hd f);
	"advertise" =>
		#
		# Be findable.  A peer that scans sees this side and can
		# open a link to it, which is the half of Bluetooth the
		# stack could not do at all before.
		#
		on := 1;
		if(f != nil && hd f == "off")
			on = 0;
		e = advertise(r, on);
	"inquiry" =>
		#
		# Not a scan.  The controller is told how long to
		# inquire for and says when it is done, so this starts
		# one and does not stay on; "inquiry off" cancels one
		# that is still running.
		#
		if(f == nil || (hd f != "on" && hd f != "off")){
			e = "usage: inquiry on|off";
			break;
		}
		e = hci->inquiry(r.x, hd f == "on");
	"serial" =>
		#
		# Offer a serial port over RFCOMM on that channel, and
		# publish the service record that says where it is.  A
		# peer then finds it the way anything Classic is found
		# rather than being told the number.
		#
		if(f == nil || !digits(hd f)){
			e = "usage: serial channel";
			break;
		}
		e = serial(r, int hd f);
	"advname" =>
		if(f == nil){
			e = "usage: advname name";
			break;
		}
		r.advname = hd f;
		#
		# A controller takes new advertising data while it is
		# advertising, so a name can be changed without stopping
		# and starting, and the peer sees the new one on the
		# next advertisement.
		#
		if(r.advertising)
			e = hci->leadvdata(r.x, addata(r));
	"service" =>
		#
		# Build the database this side serves.  A service, then
		# characteristics named with the service they belong to
		# -- explicitly, because two processes writing ctl would
		# otherwise interleave and a characteristic would land in
		# whichever service the other one named last.
		#
		if(f == nil){
			e = "usage: service uuid";
			break;
		}
		e = addservice(r, bt->lower(hd f));
	"characteristic" =>
		if(len4(f) < 3){
			e = "usage: characteristic service uuid rwn";
			break;
		}
		e = addcharacteristic(r, bt->lower(hd f), bt->lower(hd tl f),
			props(hd tl tl f));
	"debug" =>
		;
	* =>
		e = "unknown control message";
	}
	if(e != nil && e != ""){
		srv.reply(ref Rmsg.Error(m.tag, e));
		return;
	}
	srv.reply(ref Rmsg.Write(m.tag, len m.data));
}

len4(l: list of string): int
{
	n := 0;
	for(; l != nil && n < 5; l = tl l)
		n++;
	return n;
}

target(r: ref Radio, d: ref Dev, f: list of string): (ref Dev, string)
{
	if(d != nil)
		return (d, nil);
	if(f == nil)
		return (nil, "which device?");
	#
	# A directory is named by addrstr, which writes hexadecimal in
	# upper case, and this name comes from whatever the client
	# typed.  Put it through straddr and addrstr first, so a lower
	# case address neither misses the device that is already there
	# nor makes a second directory the scanner and the bonds -- both
	# of which spell it the other way -- would then fail to match.
	#
	addr := bt->straddr(hd f);
	if(addr == nil)
		return (nil, "not an address");
	a := bt->addrstr(addr);
	<-r.devlock;
	dd := finddevstr(r, a);
	if(dd == nil){
		atype := Bt->Apublic;
		if(tl f != nil && hd tl f == "random")
			atype = Bt->Arandom;
		dd = newdev(r, a, addr, atype);
		r.devs = dd :: r.devs;
	}
	r.devlock <-= 1;
	return (dd, nil);
}

#
# connect, then discover: the whole database becomes files
#
connect(d: ref Dev): string
{
	<-d.lock;
	if(d.conn != nil){
		d.lock <-= 1;
		return nil;
	}
	c: ref Conn;
	e: string;
	if(d.classic)
		(c, e) = hci->connect(d.r.x, d.addr, d.psrm, d.clock);
	else
		(c, e) = hci->leconnect(d.r.x, d.atype, d.addr);
	if(e != nil){
		d.lock <-= 1;
		return e;
	}
	d.conn = c;
	#
	# L2CAP runs on a BR/EDR link -- basic mode channels, opened
	# with the ctl file's l2cap verb -- and nothing above it does:
	# ATT is LE only, so there is no GATT tree to discover here.
	#
	if(d.classic){
		d.mux = l2cap->start(c);
		spawn watcher(d);
		#
		# and what it says it can do.  A device that will not
		# answer a service discovery search is still a connected
		# device: the link is up, and having nothing to say
		# about itself is a fact about the device rather than a
		# reason to refuse it.  So this is said and not
		# returned, and the device has no sdp directory.
		#
		if((se := sdpdiscover(d)) != nil)
			sys->fprint(sys->fildes(2), "btfs: %s: %s\n", d.dir, se);
		d.lock <-= 1;
		# and what a peer may ask of us on the same link
		spawn classicserve(d);
		return nil;
	}
	d.mux = l2cap->start(c);
	d.sess = att->start(d.mux);
	att->exchangemtu(d.sess, 247);
	spawn watcher(d);
	spawn notifier(d);
	e = discover(d);
	d.lock <-= 1;
	return e;
}

discover(d: ref Dev): string
{
	d.gq = newnode(Kdgatt, d.r, d, nil, "gatt");
	create(d.q, mkdir("gatt", d.gq));
	(svcs, e) := gatt->services(d.sess);
	if(e != nil)
		return e;
	#
	# The list is walked rather than iterated, because discovering a
	# service can add to it: an included service need not be a
	# primary one, and a secondary service appears nowhere else, so
	# its characteristics are reachable through the include or not
	# at all.  A service already in the tree is not added twice, and
	# that is also what stops two services that include each other
	# from being followed for ever.
	#
	done: list of (int, int);
	todo := svcs;
	while(todo != nil){
		s := hd todo;
		todo = tl todo;
		seen := 0;
		for(dl := done; dl != nil; dl = tl dl){
			(ds, de) := hd dl;
			if(ds == s.start && de == s.end)
				seen = 1;
		}
		if(seen)
			continue;
		done = (s.start, s.end) :: done;
		sq := newnode(Ksvc, d.r, d, nil, s.uuid);
		create(d.gq, mkdir(s.uuid, sq));
		(incs, ie) := gatt->includes(d.sess, s);
		if(ie == nil && incs != nil){
			inctext := "";
			for(il := incs; il != nil; il = tl il)
				inctext += sprint("%s %4.4ux %4.4ux\n",
					(hd il).uuid, (hd il).start, (hd il).end);
			iq := mkfd(sq, "included", Kinc, 8r444, d, nil);
			nodes[int iq].text = inctext;
			todo = appendsvcs(todo, incs);
		}
		(cs, ce) := gatt->chars(d.sess, s);
		if(ce != nil)
			continue;
		for(k := cs; k != nil; k = tl k){
			ch := hd k;
			gatt->descriptors(d.sess, ch);
			cn := ref Cnode(ch, big 0, big 0, chan[16] of array of byte, 0);
			mode := 8r444;
			if(ch.props & (Gatt->Pwrite|Gatt->Pwritenoresp))
				mode = 8r666;
			#
			# A service may hold the same UUID twice: HID over
			# GATT gives every report the same one and tells
			# them apart by a descriptor.  Two files of one
			# name is one file a client can reach and one it
			# cannot, so when a UUID occurs more than once
			# every one of them carries its value handle.  A
			# UUID that occurs once keeps its bare name, which
			# is what every name in this tree already is.
			#
			name := ch.uuid;
			if(dups(cs, ch.uuid) > 1)
				name = sprint("%s.%4.4ux", ch.uuid, ch.vhandle);
			cn.q = mkfd(sq, name, Kchar, mode, d, cn);
			if(ch.props & (Gatt->Pnotify|Gatt->Pindicate))
				cn.nq = mkfd(sq, name + ".notify", Kcnotify, 8r444, d, cn);
			#
			# and the descriptors, each named after the
			# characteristic it belongs to.  The client
			# configuration is left out: it is not a value to
			# be read, it is the subscription, and the .notify
			# file above is how this tree offers that.
			#
			for(desl := ch.descs; desl != nil; desl = tl desl){
				(dh, du) := hd desl;
				if(du == "2902")
					continue;
				dq := mkfd(sq, name + "." + du, Kdesc, 8r444, d, nil);
				nodes[int dq].dh = dh;
			}
			d.chars = cn :: d.chars;
			#
			# the device's own way of saying it has moved
			# things.  Subscribing is an ordinary indication
			# subscription; what it costs is one CCCD write
			# per connection to a device that has one.
			#
			#
			# the device's own way of saying it has moved
			# things.  The subscription belongs to the link,
			# not to this walk of the database, so a
			# rediscovery does not write the descriptor again
			# unless the descriptor itself has moved --
			# otherwise every indication would answer itself
			# with another write, and a device that took a
			# write for a change would never settle.
			#
			if(s.uuid == "1801" && ch.uuid == "2a05"){
				if(ch.cccd != 0 && ch.cccd == d.sccccd)
					d.scv = ch.vhandle;
				else if(gatt->subscribe(d.sess, ch, 1) == nil){
					d.scv = ch.vhandle;
					d.sccccd = ch.cccd;
				}
			}
		}
	}
	return nil;
}

#
# Offer a serial port on an RFCOMM server channel.  Two things happen:
# the channel is remembered so that a peer's session is answered on
# it, and a service record is published so that a peer can find it.
# Neither is any use without the other -- a port nobody can find, or a
# record for a port that does not answer -- so they are one verb.
#
serial(r: ref Radio, ch: int): string
{
	if(ch < 1 || ch > 30)
		return "a server channel is 1 to 30";
	for(l := r.serials; l != nil; l = tl l)
		if(hd l == ch)
			return sprint("channel %d is already offered", ch);
	r.serials = ch :: r.serials;
	r.sdpdb = serialrec(r, ch) :: r.sdpdb;
	return nil;
}

#
# The record for one serial port.  It says what it is, what it is
# called, and how it is reached: L2CAP to the RFCOMM PSM and then that
# server channel, which is the line a client reads the number out of.
#
serialrec(r: ref Radio, ch: int): ref Rec
{
	rec := ref Rec;
	#
	# Handles are given out here and never given out again, the
	# same rule the GATT database follows and for the same reason:
	# a peer that asked once may name what it found.
	#
	rec.handle = 16r10000 + len r.sdpdb;
	rec.attrs = nil;
	al: list of (int, ref Elem);
	al = (Sdp->Ahandle, sdp->uint(rec.handle, 4)) :: al;
	al = (Sdp->Aclasses, sdp->seq(sdp->uuidof("1101") :: nil)) :: al;
	al = (Sdp->Aprotos, sdp->seq(
		sdp->seq(sdp->uuidof("0100") :: sdp->uint(Rfcomm->Psm, 2) :: nil) ::
		sdp->seq(sdp->uuidof("0003") :: sdp->uint(ch, 1) :: nil) :: nil)) :: al;
	al = (Sdp->Abrowse, sdp->seq(sdp->uuidof(Sdp->Upublic) :: nil)) :: al;
	al = (Sdp->Aname, sdp->text(sprint("Serial Port %d", ch))) :: al;
	for(; al != nil; al = tl al)
		rec.attrs = hd al :: rec.attrs;
	return rec;
}

#
# The other half of a BR/EDR link: what a peer that opened it, or that
# this side opened, may ask of us.  One process per link, started when
# the link comes up.
#
# It answers service discovery from the radio's records, and hands a
# serial port to whoever opens one on a channel this side offers.
#
classicserve(d: ref Dev)
{
	<-d.lock;
	m := d.mux;
	r := d.r;
	d.lock <-= 1;
	if(m == nil)
		return;
	sc := l2cap->listen(m, Sdp->Psm);
	rc := l2cap->listen(m, Rfcomm->Psm);
	for(;;){
		alt {
		ch := <-sc =>
			if(ch == nil)
				return;
			spawn sdpserve(m, ch, r);
		ch := <-rc =>
			if(ch == nil)
				return;
			spawn rfserve(m, ch, r);
		}
	}
}

#
# Service discovery, answered from the radio's records.  One request
# is one answer and the channel is the peer's; when it goes, so does
# this.
#
sdpserve(m: ref Mux, ch: ref Chan, r: ref Radio)
{
	for(;;){
		(p, e) := l2cap->crecv(m, ch);
		if(e != nil)
			return;
		<-r.bondlock;
		db := r.sdpdb;
		r.bondlock <-= 1;
		a := sdp->answer(db, p);
		if(a == nil)
			continue;
		if(l2cap->csend(m, ch, a) != nil)
			return;
	}
}

#
# A serial port a peer opened.  The session is the peer's -- it sent
# the SABM on DLCI 0 -- so this takes it rather than starting it, and
# says which server channels it will answer on.
#
rfserve(m: ref Mux, ch: ref Chan, r: ref Radio)
{
	s := rfcomm->accept(m, ch);
	cs: list of chan of ref Dlc;
	<-r.bondlock;
	sl := r.serials;
	r.bondlock <-= 1;
	for(; sl != nil; sl = tl sl)
		cs = rfcomm->serve(s, hd sl) :: cs;
	for(; cs != nil; cs = tl cs)
		spawn port(hd cs);
}

#
# One port, once a peer has opened it.  What it does is echo, because
# there is nothing above here yet for a serial port to be: btfs offers
# the port and something else would have to be what is on the end of
# it.  That it echoes is said in btfs(4) rather than left to be
# discovered.
#
port(c: chan of ref Dlc)
{
	for(;;){
		d := <-c;
		if(d == nil)
			return;
		spawn echo(d);
	}
}

echo(d: ref Dlc)
{
	for(;;){
		(p, e) := rfcomm->read(d);
		if(e != nil)
			return;
		if(rfcomm->write(d, p) != nil)
			return;
	}
}

#
# What a Classic device says it can do.  There is no walking here and
# nothing to hold on to: SDP is asked once, over an L2CAP channel of
# its own, and what comes back is a set of records that are what they
# were at that moment.  So the channel is opened, the question asked,
# the channel closed, and the answer written down as files.
#
# The question is the public browse group, which is where a service
# that wants to be found puts itself.  A device with services outside
# it has them and does not advertise them, which is its own decision
# and not something to work around.
#
# Called with the device lock held.
#
sdpdiscover(d: ref Dev): string
{
	(ch, e) := l2cap->bconnect(d.mux, Sdp->Psm);
	if(e != nil)
		return "sdp: " + e;
	(recs, se) := sdp->search(d.mux, ch, Sdp->Upublic);
	l2cap->cclose(d.mux, ch);
	if(se != nil)
		return "sdp: " + se;
	if(recs == nil)
		return nil;		# a device with nothing to say
	d.sq = newnode(Kdsdp, d.r, d, nil, "sdp");
	create(d.q, mkdir("sdp", d.sq));
	for(rl := recs; rl != nil; rl = tl rl){
		r := hd rl;
		name := sprint("%8.8ux", r.handle);
		q := mkfd(d.sq, name, Ksdp, 8r444, d, nil);
		nodes[int q].text = rectext(r);
	}
	return nil;
}

#
# One record, as text.  The three lines that matter are named -- what
# the service is, what it is called, and how it is reached -- and then
# every attribute is written out whole, because a record holds
# whatever the device put in it and this cannot know in advance what
# something above will want.
#
rectext(r: ref Rec): string
{
	s := "";
	cl := r.attr(Sdp->Aclasses);
	if(cl != nil)
		for(l := cl.l; l != nil; l = tl l){
			u := (hd l).uuid;
			if(u == nil)
				continue;
			#
			# and its name only when there is one to give: a
			# UUID printed twice reads as two of something.
			#
			nm := sdp->uuidname(u);
			if(nm != u)
				s += sprint("class %s %s\n", u, nm);
			else
				s += sprint("class %s\n", u);
		}
	nm := r.attr(Sdp->Aname);
	if(nm != nil && nm.s != nil)
		s += sprint("name %s\n", nm.s);
	for(pl := sdp->protos(r); pl != nil; pl = tl pl)
		s += sprint("proto %s\n", hd pl);
	#
	# A HID device's report descriptor, in hexadecimal.  It is in
	# the attributes below as well, but as a text element whose
	# bytes are not text: a report descriptor is full of bytes that
	# are not characters, so the line that is meant to be read by
	# something is this one.
	#
	hdesc := sdp->hiddesc(r);
	if(hdesc != nil)
		s += sprint("hiddesc %s\n", bt->hex(hdesc));
	for(al := r.attrs; al != nil; al = tl al){
		(id, v) := hd al;
		s += sprint("attr %#4.4ux %s\n", id, v.text());
	}
	return s;
}

#
# how many characteristics of this service carry that UUID
#
dups(cs: list of ref Char, u: string): int
{
	n := 0;
	for(; cs != nil; cs = tl cs)
		if((hd cs).uuid == u)
			n++;
	return n;
}

#
# notifications arrive on the session; route each to the
# characteristic whose value handle it names
#
notifier(d: ref Dev)
{
	c := att->notifies(d.sess);
	for(;;){
		p := <-c;
		if(p == nil)
			return;
		if(len p < 3)
			continue;
		h := bt->get16(p, 1);
		v := p[3:];
		if(d.scv != 0 && h == d.scv){
			#
			# The value is the range of handles that moved.
			# The whole tree is built again regardless: this
			# has no cache to invalidate part of, and half a
			# rediscovery would leave the range's own
			# boundaries to be trusted, which is what a
			# device that has just told us it rearranged
			# itself has least claim to.  The range is said
			# out loud so what was ignored is visible.
			#
			first := 0;
			last := 0;
			if(len v >= 4){
				first = bt->get16(v, 0);
				last = bt->get16(v, 2);
			}
			sys->fprint(sys->fildes(2),
				"btfs: %s: service changed %#4.4ux-%#4.4ux, discovering again\n",
				d.dir, first, last);
			spawn rediscover(d);
			continue;
		}
		for(l := d.chars; l != nil; l = tl l){
			cn := hd l;
			if(cn.c.vhandle == h){
				alt {
				cn.notify <-= v =>	;
				* =>	;	# nobody is reading fast enough
				}
				break;
			}
		}
	}
}

#
# the link going away takes the gatt tree with it
#
watcher(d: ref Dev)
{
	c := d.conn;
	why := <-c.closed;
	# and back, for anyone else waiting on the same link
	alt {
	c.closed <-= why =>	;
	* =>	;
	}
	<-d.lock;
	if(d.conn == c){
		d.conn = nil;
		d.sess = nil;
		d.mux = nil;
		d.state = "disconnected: " + why;
		droptree(d);
		dropcocs(d);	# the link took the channels with it
		droprfs(d);	# and the serial ports on them
		d.scv = 0;	# and the handles it was talking about
		d.sccccd = 0;	# the link took the subscription with it
	}
	d.lock <-= 1;
}

#
# take the whole gatt tree down: the characteristic files, which hang
# off the service directories, then the service directories and the
# gatt directory itself.  Called with d.lock held, by the watcher when
# the link goes and by the rediscovery below when the device says its
# database has moved -- one function rather than two copies, because
# the two used to be one copy and a half.
#
droptree(d: ref Dev)
{
	for(l := d.chars; l != nil; l = tl l){
		cn := hd l;
		if(cn.nq != big 0)
			remove(cn.nq);
		remove(cn.q);
	}
	d.chars = nil;
	if(d.gq != big 0){
		removetree(d);
		d.gq = big 0;
	}
	#
	# d.scv is not cleared here.  It was, and that lost a second
	# Service Changed arriving while the first was still being acted
	# on: the notifier recognises the indication by its handle, the
	# handle was zero for as long as the rebuild took, and an
	# indication that arrives in that window went to the loop that
	# looks for a characteristic and was dropped.  A device that
	# changes twice in quick succession -- adding a service and then
	# a characteristic in it, say -- left the tree short.  The
	# handle a rebuild is about to find again is the same handle,
	# and if it finds none the last one the device used is the best
	# guess there is.
	#
	# d.sccccd is not cleared here either: it records what was
	# written to the device over this link, which a rediscovery does
	# not undo.  The watcher clears both when the link goes, because
	# that is what forgets them.
}

#
# a service directory has nothing left in it once its characteristics
# are gone, so removing this device's services and then its gatt
# directory is enough.  Only this device's: every service node carries
# the device it belongs to, and taking down one link must not empty
# the gatt tree of another that is still connected.
#
#
# The device says its database has moved.  Take the tree down and walk
# it again on the same link -- the connection is fine, it is the
# picture of it that is stale.  Under d.lock, so it cannot run beside a
# read or a connection, and spawned by the notifier rather than done in
# it, so notifications keep being delivered while it runs.
#
# A client that had a .notify file open loses it: the file is removed
# with the rest of the tree and the subscription that stood behind it
# was made against a handle that may no longer mean the same thing.
# btfs(4) says so.
#
rediscover(d: ref Dev)
{
	<-d.lock;
	if(d.sess == nil){
		d.lock <-= 1;
		return;
	}
	droptree(d);
	e := discover(d);
	d.lock <-= 1;
	if(e != nil)
		sys->fprint(sys->fildes(2),
			"btfs: %s: discovering again: %s\n", d.dir, e);
}

#
# Everything that belongs to one device: its own files, which hang off
# its directory, and then the directory.  Removing the directory alone
# would leave the files in the tree with no parent -- nametree does not
# take a subtree out, which is why the teardown of a gatt tree is a
# loop as well.
#
dropdev(d: ref Dev)
{
	droptree(d);
	dropcocs(d);
	for(i := 0; i < nextq; i++){
		n := nodes[i];
		if(n != nil && n.dev == d && n.q != d.q)
			remove(n.q);
	}
	remove(d.q);
}

#
# put the included services at the end of the list being walked, so
# they are discovered after everything already there
#
appendsvcs(l: list of ref Gatt->Service, more: list of ref Gatt->Service): list of ref Gatt->Service
{
	r: list of ref Gatt->Service;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	for(; more != nil; more = tl more)
		r = hd more :: r;
	rr: list of ref Gatt->Service;
	for(; r != nil; r = tl r)
		rr = hd r :: rr;
	return rr;
}

removetree(d: ref Dev)
{
	# qids are never reused -- nextq only grows -- so this walks the
	# whole table.  The entries it has already removed are nil and
	# cost nothing but the walk.
	for(i := 0; i < nextq; i++){
		n := nodes[i];
		if(n != nil && n.kind == Ksvc && n.dev == d)
			remove(n.q);
	}
	remove(d.gq);
}

disconnect(d: ref Dev): string
{
	<-d.lock;
	c := d.conn;
	d.lock <-= 1;
	if(c == nil)
		return "not connected";
	return hci->disconnect(c);
}

pair(d: ref Dev): string
{
	<-d.lock;
	if(d.conn == nil){
		d.lock <-= 1;
		return "not connected";
	}
	#
	# Two pairings with nothing in common but the word.  On LE it is
	# SMP, on the link, in this process; on BR/EDR the controller
	# does it and asks questions on the way, which secproc answers,
	# so all this does is ask for it and wait for the answer.
	#
	if(d.conn.classic){
		c := d.conn;
		d.lock <-= 1;
		return classicpair(d, c);
	}
	(b, e) := smp->pair(d.conn, d.mux, Smp->Ionoio);
	d.lock <-= 1;
	if(e != nil)
		return e;
	addbond(d.r, b);
	#
	# the peer's identity address, which is what its resolvable
	# private addresses will resolve to from here on.  Its directory
	# keeps the name it was created with: renaming a directory a
	# client may be holding open is not something this does, so a
	# device first seen from a private address and paired afterwards
	# stays under the address it was first seen from.  btfs(4) says
	# so.
	#
	if(b.addr != nil){
		<-d.r.devlock;
		d.id = bt->straddr(b.addr);
		d.idtype = b.atype;
		d.r.devlock <-= 1;
	}
	return nil;
}

#
# Pair a BR/EDR link.  The controller runs it: this asks, secproc
# answers what the controller asks on the way, and the answer arrives
# as an Authentication Complete.  Then the link is encrypted, because
# a link that is authenticated and not encrypted is one where the key
# was agreed and never used.
#
classicpair(d: ref Dev, c: ref Hci->Conn): string
{
	r := d.r;
	<-r.authlock;
	#
	# a stale answer belongs to whoever gave up on it, not to this
	# one, for the same reason a connection's does
	#
	alt {
	<-r.authc =>	;
	* =>		;
	}
	if((e := hci->authenticate(c)) != nil){
		r.authlock <-= 1;
		return e;
	}
	tick := chan[1] of int;
	spawn timeout(Authwait, tick);
	err: string;
	alt {
	err = <-r.authc =>	;
	<-tick =>
		err = "the controller never finished authenticating";
	}
	r.authlock <-= 1;
	if(err != nil)
		return err;
	return hci->encrypt(c, 1);
}

timeout(ms: int, c: chan of int)
{
	sys->sleep(ms);
	c <-= 1;
}

#
# What the controller asks while a BR/EDR link is being secured.  It
# is here and not in hci because every answer is policy: which key
# this device has, what this side can do about a passkey, and whether
# to accept.  The keys are here, so the answers are.
#
secproc(r: ref Radio)
{
	c := hci->secs(r.x);
	for(;;){
		s := <-c;
		if(s == nil)
			return;
		case s.kind {
		Hci->Slinkkey =>
			#
			# the whole point of writing a link key down: a
			# device that has one does not pair again.
			#
			b := findlk(r, s.addr);
			if(b != nil)
				hci->linkkeyreply(r.x, s.addr, b.lk);
			else
				hci->linkkeynegreply(r.x, s.addr);
		Hci->Siocap =>
			hci->iocapreply(r.x, s.addr, Hci->Hnoio, Hci->Hbonding);
		Hci->Sconfirm =>
			#
			# Just Works: there is nothing here that can show
			# a number and nothing that can read one, so the
			# only honest answer is yes, and what that gives
			# is an encrypted link with no protection against
			# a man in the middle.
			#
			hci->confirmreply(r.x, s.addr, 1);
		Hci->Skeynote =>
			addlk(r, s.addr, s.key, s.ktype);
		Hci->Spin =>
			#
			# the old kind of pairing, which needs a PIN from
			# somebody and a key derivation this does not
			# have.  Refusing it is the honest answer and
			# leaves the device able to say so.
			#
			sys->fprint(sys->fildes(2),
				"btfs: %s wants the old kind of pairing, which is not implemented\n",
				bt->addrstr(s.addr));
			hci->pinnegreply(r.x, s.addr);
		Hci->Sdone =>
			alt {
			r.authc <-= s.err =>	;
			* =>	;	# nobody is waiting
			}
		}
	}
}

#
# the bond holding a link key for that device, or nil
#
findlk(r: ref Radio, addr: array of byte): ref Bond
{
	a := bt->addrstr(addr);
	<-r.bondlock;
	b: ref Bond;
	for(l := r.bonds; l != nil; l = tl l)
		if((hd l).addr == a && len (hd l).lk == 16)
			b = hd l;
	r.bondlock <-= 1;
	return b;
}

#
# The key the controller just agreed.  It goes into the bond for that
# device if there is one -- a device may be bonded on both radios and
# that is one bond with two keys -- and into a new one if there is
# not.
#
addlk(r: ref Radio, addr, key: array of byte, ktype: int)
{
	a := bt->addrstr(addr);
	<-r.bondlock;
	b: ref Bond;
	for(l := r.bonds; l != nil; l = tl l)
		if((hd l).addr == a)
			b = hd l;
	r.bondlock <-= 1;
	if(b == nil){
		b = ref Bond;
		b.addr = a;
		b.atype = Bt->Apublic;	# a BD_ADDR has no type
		b.ediv = 0;
		b.ltk = b.rand = b.irk = b.csrk = nil;
		b.local = bt->addrstr(hci->localaddr(r.x));
	}
	b.lk = key;
	b.lktype = ktype;
	addbond(r, b);
}

addbond(r: ref Radio, b: ref Bond)
{
	<-r.bondlock;
	nl: list of ref Bond;
	for(l := r.bonds; l != nil; l = tl l)
		if((hd l).addr != b.addr)
			nl = hd l :: nl;
	r.bonds = b :: nl;
	r.bondlock <-= 1;
	savekeys(b);
}

#
# The key file is one file for every controller, and each line says
# which controller its bond was made on.  A line that does not say --
# one written before there was more than one controller to make a bond
# on -- goes to every controller, which is what it meant when there
# was only one, and is said out loud once rather than being guessed at
# in silence.
#
readkeys()
{
	src := keyfile;
	if(keysrv != nil)
		src = keysrv + "/bonds";
	if(src == nil)
		return;
	fd := sys->open(src, Sys->OREAD);
	if(fd == nil){
		#
		# no key file yet is the ordinary first run and says
		# nothing.  A key file that is there and will not open is
		# every bond silently gone, which is worth a line.
		#
		# a key service that is not there is not the ordinary
		# first run: it was named on the command line and is
		# missing, so it is said whether it stats or not
		(ok, nil) := sys->stat(src);
		if(ok == 0 || keysrv != nil)
			sys->fprint(sys->fildes(2),
				"btfs: cannot read %s, so no bond is loaded: %r\n", src);
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
	nb: list of ref Bond;
	for(; lines != nil; lines = tl lines){
		b := smp->parse(hd lines);
		if(b != nil)
			nb = b :: nb;
	}
	said := 0;
	for(; nb != nil; nb = tl nb){
		b := hd nb;
		if(b.local == nil && !said){
			sys->fprint(sys->fildes(2),
				"btfs: %s has bonds that do not say which controller they were made on; every controller is offered them\n",
				src);
			said = 1;
		}
		for(rl := radios; rl != nil; rl = tl rl){
			r := hd rl;
			if(b.local != nil && b.local != bt->addrstr(hci->localaddr(r.x)))
				continue;
			<-r.bondlock;
			r.bonds = b :: r.bonds;
			r.bondlock <-= 1;
		}
	}
}

#
# every controller's bonds, written out together.  A bond belongs to
# one radio and the store belongs to none of them, so this takes a
# lock of its own rather than any radio's.
#
# b is the bond that has just been made, or nil.  A key service is
# told the one thing that changed, because that is what a message to
# it means; a key file has no messages, only its contents, so it is
# written whole either way.
#
savekeys(b: ref Bond)
{
	<-keylock;
	if(keysrv != nil)
		sendkeys(b);
	else {
		s := "";
		for(rl := radios; rl != nil; rl = tl rl)
			s += bondtext(hd rl);
		writekeys(s);
	}
	keylock <-= 1;
}

#
# to the service, one bond per write: one write is one command there,
# and a bond replaces the one for the same peer on the same
# controller, so saying it again is saying nothing new.
#
sendkeys(b: ref Bond)
{
	fd := sys->open(keysrv + "/ctl", Sys->OWRITE);
	if(fd == nil){
		sys->fprint(sys->fildes(2),
			"btfs: cannot write %s/ctl, so this bond is not kept: %r\n", keysrv);
		return;
	}
	bl: list of ref Bond;
	if(b != nil)
		bl = b :: nil;
	else
		for(rl := radios; rl != nil; rl = tl rl){
			r := hd rl;
			<-r.bondlock;
			for(l := r.bonds; l != nil; l = tl l)
				bl = hd l :: bl;
			r.bondlock <-= 1;
		}
	for(; bl != nil; bl = tl bl){
		s := array of byte ("bond " + (hd bl).text());
		if(sys->write(fd, s, len s) != len s)
			sys->fprint(sys->fildes(2),
				"btfs: %s/ctl: %r\n", keysrv);
	}
}

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
		# a bond that was not written down is a bond that will not
		# be there next time; say so rather than losing it quietly
		sys->fprint(sys->fildes(2), "btfs: cannot write %s: %r\n", keyfile);
		return;
	}
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		sys->fprint(sys->fildes(2), "btfs: writing %s: %r\n", keyfile);
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "btfs: %s\n", s);
	raise "fail:" + s;
}

#
# A PSM is written the way it appears in every specification that
# assigns one: four hexadecimal digits, optionally with an 0x in
# front.  A decimal spelling would be ambiguous against those.
#
hexnum(s: string): int
{
	if(len s > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
		s = s[2:];
	v := 0;
	if(len s == 0)
		return -1;
	for(i := 0; i < len s; i++){
		d := bt->digit(s[i]);
		if(d < 0)
			return -1;
		v = v * 16 + d;
	}
	if(v < 0 || v > 16rffff)
		return -1;
	return v;
}

#
# by the name the file has, which is what a client that opened two
# channels to one PSM has to say to close the right one
#
findcocname(d: ref Dev, name: string): ref Coc
{
	for(l := d.cocs; l != nil; l = tl l)
		if((hd l).name == name)
			return hd l;
	return nil;
}

findcoc(d: ref Dev, psm: int): ref Coc
{
	for(l := d.cocs; l != nil; l = tl l)
		if((hd l).psm == psm)
			return hd l;
	return nil;
}

#
# The connection request is not sent under d.lock: it waits for the
# peer to answer, and holding the device lock across that would stop
# a read of the device's name for as long as the peer felt like
# taking.  The lock is taken to look, dropped to ask, and taken again
# to record, and the second time it has to look again -- two writers
# racing on the same PSM must not both end up with a channel.
#
cocopen(d: ref Dev, psm: int): string
{
	if(psm < 0)
		return "a PSM is four hexadecimal digits";
	<-d.lock;
	m := d.mux;
	if(m == nil){
		d.lock <-= 1;
		return "not connected";
	}
	d.lock <-= 1;

	#
	# The two kinds of L2CAP channel, told apart by the link they
	# are on: credit-based on LE, basic mode on BR/EDR.  What comes
	# back is the same adt and is read and written the same way,
	# which is why the file below is the same file.
	#
	c: ref Chan;
	e: string;
	if(d.conn != nil && d.conn.classic)
		(c, e) = l2cap->bconnect(m, psm);
	else
		(c, e) = l2cap->connect(m, psm);
	if(e != nil)
		return e;

	<-d.lock;
	if(d.mux != m){
		d.lock <-= 1;
		l2cap->cclose(m, c);
		return "the link changed while the channel was being opened";
	}
	name := sprint("%4.4ux", psm);
	for(n := 1; findcocname(d, name) != nil; n++)
		name = sprint("%4.4ux.%d", psm, n);
	co := ref Coc(psm, name, c, big 0);
	if(d.lq == big 0){
		d.lq = newnode(Kdl2cap, d.r, d, nil, "l2cap");
		create(d.q, mkdir("l2cap", d.lq));
	}
	co.q = mkfd(d.lq, name, Kcoc, 8r666, d, nil);
	nodes[int co.q].coc = co;
	d.cocs = co :: d.cocs;
	d.lock <-= 1;
	return nil;
}

#
# By the name the file has, which for the first channel to a PSM is
# the PSM: so "unl2cap 0019" still closes the one "l2cap 0019" opened,
# and "unl2cap 0019.1" closes the second one.  Closing by PSM when
# there are two would be closing whichever happened to be first.
#
cocclose(d: ref Dev, name: string): string
{
	<-d.lock;
	co := findcocname(d, name);
	if(co == nil){
		d.lock <-= 1;
		return sprint("%s is not open", name);
	}
	m := d.mux;
	dropcoc(d, co);
	d.lock <-= 1;
	if(m != nil)
		return l2cap->cclose(m, co.c);
	return nil;
}

#
# take one channel out of the tree.  Called with d.lock held.  The
# file goes whether or not the disconnection request gets an answer:
# the channel is finished either way, and a file that is still there
# would be a file whose every read fails.
#
dropcoc(d: ref Dev, co: ref Coc)
{
	l: list of ref Coc;
	for(cl := d.cocs; cl != nil; cl = tl cl)
		if(hd cl != co)
			l = hd cl :: l;
	d.cocs = l;
	if(co.q != big 0)
		remove(co.q);
	if(d.cocs == nil && d.lq != big 0){
		remove(d.lq);
		d.lq = big 0;
	}
}

#
# the link went away.  Every channel on it went with it; there is
# nobody to send a disconnection request to, so the files go and that
# is all.  Called with d.lock held.
#
dropcocs(d: ref Dev)
{
	for(l := d.cocs; l != nil; l = tl l){
		co := hd l;
		if(co.q != big 0)
			remove(co.q);
	}
	d.cocs = nil;
	if(d.lq != big 0){
		remove(d.lq);
		d.lq = big 0;
	}
}

#
# The channel died under the file.  L2CAP takes a channel down by
# itself when the peer breaks the credit rules, and the file has to go
# with it: btfs(4) says a file here is an open channel, and one whose
# every read fails for ever is not one.  The link going away is
# handled elsewhere, by the watcher, which takes them all at once.
#
reapcoc(d: ref Dev, co: ref Coc)
{
	<-d.lock;
	if(co.c.state != L2cap->Sup && findcoc(d, co.psm) == co)
		dropcoc(d, co);
	d.lock <-= 1;
}

#
# One read is one SDU.  A short read would lose the rest of it -- the
# SDU is gone from the queue and there is nowhere to put the remainder
# -- so a buffer too small to hold it is an error saying how big it
# was, not a truncation.
#
readcoc(m: ref Tmsg.Read, n: ref Node)
{
	d := n.dev;
	co := n.coc;
	<-d.lock;
	mux := d.mux;
	d.lock <-= 1;
	if(mux == nil || co == nil){
		srv.reply(ref Rmsg.Error(m.tag, "not connected"));
		return;
	}
	(v, e) := l2cap->crecv(mux, co.c);
	if(e != nil){
		reapcoc(d, co);
		srv.reply(ref Rmsg.Error(m.tag, e));
		return;
	}
	if(len v > m.count){
		srv.reply(ref Rmsg.Error(m.tag,
			sprint("an SDU of %d bytes and a read of %d", len v, m.count)));
		return;
	}
	srv.reply(ref Rmsg.Read(m.tag, v));
}

#
# One write is one SDU.  It may block: a peer that has given no
# credits has said it is not ready, and the bytes wait rather than
# being thrown away.
#
writecoc(m: ref Tmsg.Write, n: ref Node)
{
	d := n.dev;
	co := n.coc;
	<-d.lock;
	mux := d.mux;
	d.lock <-= 1;
	if(mux == nil || co == nil){
		srv.reply(ref Rmsg.Error(m.tag, "not connected"));
		return;
	}
	if((e := l2cap->csend(mux, co.c, m.data)) != nil){
		reapcoc(d, co);
		srv.reply(ref Rmsg.Error(m.tag, e));
		return;
	}
	srv.reply(ref Rmsg.Write(m.tag, len m.data));
}


#
# A serial port over RFCOMM.  The multiplexer under it -- an L2CAP
# channel to PSM 3 and the session on it -- is started by the first
# port and shared by the rest, because that is what a session is:
# thirty ports on one channel, not thirty channels.
#
rfopen(d: ref Dev, ch: int): string
{
	if(ch < 1 || ch > 30)
		return "a server channel is 1 to 30";
	<-d.lock;
	mux := d.mux;
	if(mux == nil || d.conn == nil || !d.conn.classic){
		d.lock <-= 1;
		return "not connected to a Classic device";
	}
	if(findrf(d, ch) != nil){
		d.lock <-= 1;
		return sprint("channel %d is already open", ch);
	}
	s := d.rsess;
	d.lock <-= 1;

	if(s == nil){
		(l2ch, le) := l2cap->bconnect(mux, Rfcomm->Psm);
		if(le != nil)
			return "rfcomm: " + le;
		(ns, se) := rfcomm->start(mux, l2ch);
		if(se != nil){
			l2cap->cclose(mux, l2ch);
			return "rfcomm: " + se;
		}
		<-d.lock;
		if(d.mux != mux){
			d.lock <-= 1;
			rfcomm->stop(ns);
			return "the link changed while the session was starting";
		}
		if(d.rsess != nil){
			# somebody else got there first, which is fine:
			# one session per device, and this one goes
			s = d.rsess;
			d.lock <-= 1;
			rfcomm->stop(ns);
		} else {
			s = d.rsess = ns;
			d.lock <-= 1;
		}
	}

	(dlc, e) := rfcomm->open(s, ch);
	if(e != nil)
		return e;

	<-d.lock;
	if(d.mux != mux || findrf(d, ch) != nil){
		d.lock <-= 1;
		rfcomm->close(dlc);
		return "the link changed while the channel was being opened";
	}
	rf := ref Rf(ch, dlc, big 0, big 0);
	if(d.rq == big 0){
		d.rq = newnode(Kdrfcomm, d.r, d, nil, "rfcomm");
		create(d.q, mkdir("rfcomm", d.rq));
	}
	name := string ch;
	rf.dq = newnode(Krfdir, d.r, d, nil, name);
	create(d.rq, mkdir(name, rf.dq));
	rf.q = mkfd(rf.dq, "data", Krfdata, 8r666, d, nil);
	nodes[int rf.q].rf = rf;
	d.rfs = rf :: d.rfs;
	d.lock <-= 1;
	return nil;
}

rfclose(d: ref Dev, ch: int): string
{
	<-d.lock;
	rf := findrf(d, ch);
	d.lock <-= 1;
	if(rf == nil)
		return sprint("channel %d is not open", ch);
	rfcomm->close(rf.d);
	dropone(d, rf);
	return nil;
}

# with the device lock held
findrf(d: ref Dev, ch: int): ref Rf
{
	for(l := d.rfs; l != nil; l = tl l)
		if((hd l).ch == ch)
			return hd l;
	return nil;
}

dropone(d: ref Dev, rf: ref Rf)
{
	<-d.lock;
	nl: list of ref Rf;
	for(l := d.rfs; l != nil; l = tl l)
		if(hd l != rf)
			nl = hd l :: nl;
	d.rfs = nl;
	if(rf.q != big 0)
		remove(rf.q);
	if(rf.dq != big 0)
		remove(rf.dq);
	d.lock <-= 1;
}

#
# every port on a device, when its link goes.  The session goes with
# the link; the ports go with the session.
#
droprfs(d: ref Dev)
{
	for(l := d.rfs; l != nil; l = tl l){
		rf := hd l;
		if(rf.q != big 0)
			remove(rf.q);
		if(rf.dq != big 0)
			remove(rf.dq);
	}
	d.rfs = nil;
	if(d.rq != big 0){
		remove(d.rq);
		d.rq = big 0;
	}
	d.rsess = nil;
}

#
# A serial line, so a read is whatever has arrived rather than a
# record: what a program writes is bytes and what it reads is bytes,
# and where the frame boundaries fell is this program's business.
#
readrf(m: ref Tmsg.Read, n: ref Node)
{
	rf := n.rf;
	if(rf == nil){
		srv.reply(ref Rmsg.Error(m.tag, "not connected"));
		return;
	}
	(v, e) := rfcomm->read(rf.d);
	if(e != nil){
		srv.reply(ref Rmsg.Error(m.tag, e));
		return;
	}
	if(len v > m.count)
		v = v[0:m.count];
	srv.reply(ref Rmsg.Read(m.tag, v));
}

writerf(m: ref Tmsg.Write, n: ref Node)
{
	rf := n.rf;
	if(rf == nil){
		srv.reply(ref Rmsg.Error(m.tag, "not connected"));
		return;
	}
	if((e := rfcomm->write(rf.d, m.data)) != nil){
		srv.reply(ref Rmsg.Error(m.tag, e));
		return;
	}
	srv.reply(ref Rmsg.Write(m.tag, len m.data));
}

#
# The advertisement: the flags every discoverable device sends, and
# the complete local name.  Thirty one bytes in all, so a long name is
# cut rather than making the whole thing fail -- a controller refuses
# the command outright, which would leave the stack silently not
# advertising.
#
addata(r: ref Radio): array of byte
{
	name := r.advname;
	if(name == nil)
		name = "inferno";
	nm := array of byte name;
	if(len nm > 31 - 5)
		nm = nm[0:31-5];
	a := array[5 + len nm] of byte;
	a[0] = byte 2;
	a[1] = byte 16r01;	# flags
	a[2] = byte 16r06;	# LE general discoverable, no BR/EDR
	a[3] = byte (1 + len nm);
	a[4] = byte 16r09;	# complete local name
	a[5:] = nm;
	return a;
}

advertise(r: ref Radio, on: int): string
{
	if(!on){
		e := hci->leadvertise(r.x, 0);
		if(e == nil)
			r.advertising = 0;
		return e;
	}
	#
	# The parameters go in once.  A controller will not take them
	# while it is advertising, so setting them every time would mean
	# stopping first, and there is nothing here that wants changing
	# between one advertisement and the next.
	#
	if(!r.advset){
		if((e := hci->leadvparams(r.x, 1)) != nil)
			return e;
		r.advset = 1;
	}
	if((de := hci->leadvdata(r.x, addata(r))) != nil)
		return de;
	if((ee := hci->leadvertise(r.x, 1)) != nil)
		return ee;
	r.advertising = 1;
	return nil;
}

#
# Links a peer opened to this side.  The device gets a directory like
# any other, named by the address it connected from; what is different
# is that nothing here asked for it, so there is no discovery to do
# and no gatt tree to build.  A peer that goes on to send ATT requests
# gets no answer: there is no server yet, and btfs(4) says so.
#
inproc(r: ref Radio)
{
	c := hci->incoming(r.x);
	for(;;){
		conn := <-c;
		if(conn == nil)
			return;
		name := bt->addrstr(conn.addr);
		<-r.devlock;
		d := finddev(r, conn.addr);
		if(d == nil)
			d = resolved(r, conn.atype, conn.addr);
		if(d == nil){
			d = newdev(r, name, conn.addr, conn.atype);
			r.devs = d :: r.devs;
		}
		r.devlock <-= 1;

		<-d.lock;
		if(d.conn != nil){
			#
			# already connected, on a link this side opened.
			# Two links to one device is not something the
			# name space can show, so the new one goes.
			#
			d.lock <-= 1;
			sys->fprint(sys->fildes(2),
				"btfs: %s: a peer connected to a device already connected; closing it\n",
				name);
			hci->disconnect(conn);
			continue;
		}
		d.conn = conn;
		if(conn.classic){
			#
			# A peer paged this side.  The L2CAP
			# demultiplexer runs on the link, because a peer
			# that opened it may want a channel on it; what
			# does not run is ATT, which is LE only.
			#
			d.classic = 1;
			d.mux = l2cap->start(conn);
			d.state = "connected";
			d.seen = daytime();
			spawn watcher(d);
			d.lock <-= 1;
			#
			# A peer that paged this side is the more likely
			# one to want something of it, so this matters
			# more here than on a link this side opened.
			#
			spawn classicserve(d);
			continue;
		}
		d.mux = l2cap->start(conn);
		#
		# a peer opened this link, so this side is the server on
		# it.  The client half runs on links this side opens;
		# one Dev has one link, so the two never share CID 4.
		#
		gattsrv->serve(r.db, d.mux);
		d.state = "connected";
		d.seen = daytime();
		spawn watcher(d);
		#
		# and wait for the peer to pair, if it wants to.  In its
		# own process: it waits for the peer to start and then
		# for the controller to ask for the key, and the link is
		# usable meanwhile.
		#
		spawn responder(d);
		d.lock <-= 1;
		sys->fprint(sys->fildes(2), "btfs: %s connected to us\n", name);
	}
}

#
# The database this side serves, built from ctl and read as files.
# /net/bt/N/gatt is the mirror of /net/bt/N/remote/ADDR/gatt: the same
# shape, a directory per service holding a file per characteristic,
# except that these are ours and a peer that connects reads them.
#
# Handles are given out as attributes are added and never given out
# again, so what a connected peer already holds stays right; what it
# has not seen it is told about, by the Service Changed indication
# every database carries.  So the database may grow while a peer is
# connected, and the peer walks it again.
#
props(s: string): int
{
	p := 0;
	for(i := 0; i < len s; i++)
		case s[i] {
		'r' =>	p |= Gatt->Pread;
		'w' =>	p |= Gatt->Pwrite;
		'W' =>	p |= Gatt->Pwritenoresp;
		'n' =>	p |= Gatt->Pnotify;
		'i' =>	p |= Gatt->Pindicate;
		}
	return p;
}

findsvcq(r: ref Radio, uuid: string): big
{
	for(l := r.svcs; l != nil; l = tl l){
		(u, q) := hd l;
		if(u == uuid)
			return q;
	}
	return big 0;
}

addservice(r: ref Radio, uuid: string): string
{
	u := bt->uuidbytes(uuid);
	if(u == nil)
		return "a UUID is 4, 8 or 32 hexadecimal digits";
	if(findsvcq(r, uuid) != big 0)
		return uuid + " is already there";
	(nil, e) := gattsrv->addsvc(r.db, u);
	if(e != nil)
		return e;
	if(r.lq == big 0){
		r.lq = newnode(Klocal, r, nil, nil, "gatt");
		create(r.q, mkdir("gatt", r.lq));
	}
	sq := newnode(Klsvc, r, nil, nil, uuid);
	create(r.lq, mkdir(uuid, sq));
	r.svcs = (uuid, sq) :: r.svcs;
	return nil;
}

addcharacteristic(r: ref Radio, svc, uuid: string, p: int): string
{
	u := bt->uuidbytes(uuid);
	if(u == nil)
		return "a UUID is 4, 8 or 32 hexadecimal digits";
	sq := findsvcq(r, svc);
	if(sq == big 0)
		return "no service " + svc;
	(nil, vh, nil, e) := gattsrv->addchar(r.db, u, p, nil);
	if(e != nil)
		return e;
	#
	# Always writable here, whatever the properties say.  The
	# properties are what a peer may do; this file is how the owner
	# of the database sets the value a peer reads, and a read-only
	# characteristic whose value could never be set would be a
	# characteristic that always reads empty.
	#
	lc := ref Lchar(r, uuid, vh, big 0);
	lc.q = newnode(Klchar, r, nil, nil, uuid);
	create(sq, mkfile(uuid, lc.q, 8r666));
	nodes[int lc.q].lc = lc;
	r.lchars = lc :: r.lchars;
	return nil;
}


#
# Setting a value this side serves.  Writing the file is what tells
# every peer that asked for notifications, so it is done in its own
# process: an indication waits for the peer to confirm it, and a write
# of a file should not hold the whole server up while it does.
#
writelocal(m: ref Tmsg.Write, n: ref Node)
{
	if((e := gattsrv->setval(n.rad.db, n.lc.vh, m.data)) != nil){
		srv.reply(ref Rmsg.Error(m.tag, e));
		return;
	}
	if((e = gattsrv->notify(n.rad.db, n.lc.vh, m.data)) != nil)
		sys->fprint(sys->fildes(2), "btfs: telling a peer the value changed: %s\n", e);
	srv.reply(ref Rmsg.Write(m.tag, len m.data));
}


#
# A peer pairing with us.  Whatever comes of it is a bond like any
# other and goes in the same list and the same key file: it names the
# peer, the controller it was made on, and the key this side chose.
#
responder(d: ref Dev)
{
	c := d.conn;
	m := d.mux;
	if(c == nil || m == nil)
		return;
	#
	# what is already known about this peer, if anything.  A peer
	# that has been here before starts encryption rather than
	# pairing, and the key it names is in that bond.
	#
	<-d.r.bondlock;
	known: ref Bond;
	for(bl := d.r.bonds; bl != nil; bl = tl bl)
		if((hd bl).addr == d.dir || (hd bl).addr == bt->addrstr(c.addr))
			known = hd bl;
	d.r.bondlock <-= 1;

	(b, e) := smp->respond(c, m, known);
	if(e != nil){
		#
		# Only worth a line when the peer actually started.  A
		# link that closes without anyone pairing ends this the
		# same way, and saying so every time would be a message
		# per connection that means nothing.
		#
		if(c.encrypted || e != "the link went away")
			sys->fprint(sys->fildes(2), "btfs: %s: pairing: %s\n", d.dir, e);
		return;
	}
	addbond(d.r, b);
	sys->fprint(sys->fildes(2), "btfs: %s paired with us\n", d.dir);
	#
	# and go back to waiting.  The peer may start encryption again
	# on this same link, and the key it names is now one we have.
	#
	spawn responder(d);
}
