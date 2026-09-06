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
	smp: Smp;
	Adv, Conn: import Hci;
	Mux: import L2cap;
	Sess: import Att;
	Service, Char: import Gatt;
	Bond: import smp;

Btfs: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Kroot, Kctlr, Kaddr, Kver, Kctl, Kstate, Kscan, Kremotes, Kbonds, Kdident,
	Kdev, Kdaddr, Kdtype, Kdrssi, Kdname, Kdadv, Kdstate, Kdctl,
	Kdgatt, Ksvc, Kchar, Kcnotify: con iota;

Qroot:	con big 0;

Cnode: adt {
	c:	ref Char;
	q:	big;		# the value file
	nq:	big;		# the notification stream
	notify:	chan of array of byte;
	subs:	int;
};

Dev: adt {
	q:	big;		# its directory
	gq:	big;		# its gatt directory
	dir:	string;		# the name of that directory, which is the
				# identity address once one is known and the
				# advertised address until then
	addr:	array of byte;	# where it is answering now: for a device
				# using resolvable private addresses this is
				# the current one, and it changes underneath
	atype:	int;
	id:	array of byte;	# its identity address, from a bond, or nil
	idtype:	int;
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
	lock:	chan of int;
};

Node: adt {
	q:	big;
	kind:	int;
	dev:	ref Dev;
	cn:	ref Cnode;
	name:	string;
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
devs:	list of ref Dev;
devlock:	chan of int;
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
bondlock:	chan of int;
scanning:	int;
bonds:	list of ref Bond;
keyfile:	string;
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

	tspec := "";
	tpath := Bttransport->H4PATH;
	mnt := mtpt;

	arg->init(argv);
	arg->setusage("btfs [-u] [-m mountpoint] [-k keyfile] [device]");
	usb := 0;
	while((c := arg->opt()) != 0)
		case c {
		'u' =>	usb = 1;
		'm' =>	mnt = arg->arg();
		'k' =>	keyfile = arg->arg();
		* =>	arg->usage();
		}
	a := arg->argv();
	if(a != nil)
		tspec = hd a;
	if(usb)
		tpath = Bttransport->USBPATH;
	else if(tspec == nil)
		tspec = "/dev/eia1!115200";

	t = load Bttransport tpath;
	if(t == nil)
		fail(sprint("cannot load %s: %r", tpath));
	hci = load Hci Hci->PATH;
	l2cap = load L2cap L2cap->PATH;
	att = load Att Att->PATH;
	gatt = load Gatt Gatt->PATH;
	smp = load Smp Smp->PATH;
	if(hci == nil || l2cap == nil || att == nil || gatt == nil || smp == nil)
		fail(sprint("cannot load the stack: %r"));

	if((e := t->init(bt, tspec)) != nil)
		fail("transport: " + e);
	if((e = hci->init(bt, t)) != nil)
		fail("hci: " + e);
	if((e = l2cap->init(bt, hci)) != nil)
		fail("l2cap: " + e);
	if((e = att->init(bt, l2cap)) != nil)
		fail("att: " + e);
	if((e = gatt->init(bt, att)) != nil)
		fail("gatt: " + e);
	if((e = smp->init(bt, hci, l2cap)) != nil)
		fail("smp: " + e);
	if((e = hci->start()) != nil)
		fail("controller: " + e);

	devlock = chan[1] of int;
	devlock <-= 1;
	bondlock = chan[1] of int;
	bondlock <-= 1;
	treelock = chan[1] of int;
	treelock <-= 1;
	nodes = array[64] of ref Node;
	# node 0 is the root of the served tree, so the first name
	# created below does not take its qid
	nodes[0] = ref Node(Qroot, Kroot, nil, nil, ".");
	nextq = 1;
	readkeys();

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

	build();

	# no NEWPGRP: the mount below belongs in the name space of
	# whoever started btfs, not in a private one
	spawn advproc();
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
build()
{
	create(Qroot, mkdir(".", Qroot));
	q0 := newnode(Kctlr, nil, nil, "0");
	create(Qroot, mkdir("0", q0));
	mkf(q0, "addr", Kaddr, 8r444);
	mkf(q0, "version", Kver, 8r444);
	mkf(q0, "state", Kstate, 8r444);
	mkf(q0, "scan", Kscan, 8r444);
	mkf(q0, "bonds", Kbonds, 8r444);
	mkf(q0, "ctl", Kctl, 8r666);
	qr := newnode(Kremotes, nil, nil, "remote");
	create(q0, mkdir("remote", qr));
}

qremotes(): big
{
	for(i := 0; i < nextq; i++)
		if(nodes[i] != nil && nodes[i].kind == Kremotes)
			return nodes[i].q;
	return Qroot;
}

qctlr(): big
{
	for(i := 0; i < nextq; i++)
		if(nodes[i] != nil && nodes[i].kind == Kctlr)
			return nodes[i].q;
	return Qroot;
}

newnode(kind: int, d: ref Dev, cn: ref Cnode, name: string): big
{
	if(nextq >= len nodes){
		a := array[2*len nodes] of ref Node;
		a[0:] = nodes;
		nodes = a;
	}
	q := big nextq;
	nodes[nextq] = ref Node(q, kind, d, cn, name);
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

mkf(parent: big, name: string, kind, mode: int): big
{
	q := newnode(kind, nil, nil, name);
	create(parent, mkfile(name, q, mode));
	return q;
}

mkfd(parent: big, name: string, kind, mode: int, d: ref Dev, cn: ref Cnode): big
{
	q := newnode(kind, d, cn, name);
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

daytime(): int
{
	return int (sys->millisec() / 1000);
}

#
# advertising reports: a device appears the first time it is heard
#
advproc()
{
	c := hci->advs();
	for(;;){
		a := <-c;
		if(a == nil)
			return;
		<-devlock;
		d := finddev(a.addr);
		if(d == nil)
			d = resolved(a.atype, a.addr);
		if(d == nil){
			d = newdev(bt->addrstr(a.addr), a.addr, a.atype);
			devs = d :: devs;
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
		if(len a.data > 0)
			d.adv = a.data;
		nm := advname(a.data);
		if(nm != nil)
			d.name = nm;
		devlock <-= 1;
	}
}

finddev(addr: array of byte): ref Dev
{
	s := bt->addrstr(addr);
	for(l := devs; l != nil; l = tl l)
		if(bt->addrstr((hd l).addr) == s)
			return hd l;
	return nil;
}

#
# the path walk names a device by its directory, which is its identity
# address once there is a bond to give one -- not by whatever address
# it is advertising from this minute.
#
finddevstr(s: string): ref Dev
{
	for(l := devs; l != nil; l = tl l)
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
resolved(atype: int, addr: array of byte): ref Dev
{
	if(!bt->resolvable(atype, addr))
		return nil;
	<-bondlock;
	bl := bonds;
	bondlock <-= 1;
	for(; bl != nil; bl = tl bl){
		b := hd bl;
		if(!smp->resolve(b, atype, addr))
			continue;
		id := bt->straddr(b.addr);
		if(id == nil)
			continue;
		for(l := devs; l != nil; l = tl l){
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
		d := newdev(b.addr, addr, atype);
		d.id = id;
		d.idtype = b.atype;
		devs = d :: devs;
		return d;
	}
	return nil;
}

newdev(name: string, addr: array of byte, atype: int): ref Dev
{
	d := ref Dev;
	d.dir = name;
	d.addr = addr;
	d.atype = atype;
	d.state = "seen";
	d.lock = chan[1] of int;
	d.lock <-= 1;
	d.q = newnode(Kdev, d, nil, name);
	create(qremotes(), mkdir(name, d.q));
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
		srv.reply(styxservers->readstr(m, bt->addrstr(hci->localaddr()) + "\n"));
	Kver =>
		srv.reply(styxservers->readstr(m, hci->localver() + "\n"));
	Kstate =>
		srv.reply(styxservers->readstr(m, ctlrstate()));
	Kscan =>
		s := "off\n";
		if(scanning)
			s = "on\n";
		srv.reply(styxservers->readstr(m, s));
	Kbonds =>
		srv.reply(styxservers->readstr(m, bondtext()));
	Kctl or Kdctl =>
		srv.reply(styxservers->readstr(m, ""));
	Kdaddr =>
		srv.reply(styxservers->readstr(m, bt->addrstr(n.dev.addr) + "\n"));
	Kdtype =>
		srv.reply(styxservers->readstr(m, bt->atypestr(n.dev.atype) + "\n"));
	Kdident =>
		srv.reply(styxservers->readstr(m, identtext(n.dev)));
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
	Kcnotify =>
		spawn readnotify(m, n);
	* =>
		srv.reply(ref Rmsg.Error(m.tag, Enotfound));
	}
}

ctlrstate(): string
{
	<-devlock;
	nd := len devs;
	devlock <-= 1;
	sc := "off";
	if(scanning)
		sc = "on";
	(sz, nb) := hci->aclmtu();
	return sprint("addr %s scan %s devices %d connections %d aclsize %d aclbufs %d\n",
		bt->addrstr(hci->localaddr()), sc, nd, len hci->conns(), sz, nb);
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
	if(d.conn != nil){
		s = sprint("connected handle %d", d.conn.handle);
		if(d.conn.encrypted)
			s += " encrypted";
		if(d.sess != nil)
			s += sprint(" mtu %d", d.sess.mtu);
	}
	return s + "\n";
}

bondtext(): string
{
	<-bondlock;
	s := bondtext0();
	bondlock <-= 1;
	return s;
}

# with bondlock already held
bondtext0(): string
{
	s := "";
	for(l := bonds; l != nil; l = tl l)
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
		spawn ctlwrite(m, nil, string m.data);
	Kdctl =>
		spawn ctlwrite(m, n.dev, string m.data);
	Kchar =>
		spawn writechar(m, n);
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
	e := gatt->write(d.sess, n.cn.c.vhandle, m.data);
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
ctlwrite(m: ref Tmsg.Write, d: ref Dev, s: string)
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
		e = hci->lescan(on);
		if(e == nil)
			scanning = on;
	"connect" =>
		(dd, ee) := target(d, f);
		if(ee != nil)
			e = ee;
		else
			e = connect(dd);
	"disconnect" =>
		(dd, ee) := target(d, f);
		if(ee != nil)
			e = ee;
		else
			e = disconnect(dd);
	"pair" =>
		(dd, ee) := target(d, f);
		if(ee != nil)
			e = ee;
		else
			e = pair(dd);
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

target(d: ref Dev, f: list of string): (ref Dev, string)
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
	<-devlock;
	dd := finddevstr(a);
	if(dd == nil){
		atype := Bt->Apublic;
		if(tl f != nil && hd tl f == "random")
			atype = Bt->Arandom;
		dd = newdev(a, addr, atype);
		devs = dd :: devs;
	}
	devlock <-= 1;
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
	(c, e) := hci->leconnect(d.atype, d.addr);
	if(e != nil){
		d.lock <-= 1;
		return e;
	}
	d.conn = c;
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
	d.gq = newnode(Kdgatt, d, nil, "gatt");
	create(d.q, mkdir("gatt", d.gq));
	(svcs, e) := gatt->services(d.sess);
	if(e != nil)
		return e;
	for(l := svcs; l != nil; l = tl l){
		s := hd l;
		sq := newnode(Ksvc, d, nil, s.uuid);
		create(d.gq, mkdir(s.uuid, sq));
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
			cn.q = mkfd(sq, ch.uuid, Kchar, mode, d, cn);
			if(ch.props & (Gatt->Pnotify|Gatt->Pindicate))
				cn.nq = mkfd(sq, ch.uuid + ".notify", Kcnotify, 8r444, d, cn);
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
	<-d.lock;
	if(d.conn == c){
		d.conn = nil;
		d.sess = nil;
		d.mux = nil;
		d.state = "disconnected: " + why;
		droptree(d);
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
	d.scv = 0;
	# d.sccccd is not cleared here: it records what was written to
	# the device over this link, which a rediscovery does not undo.
	# The watcher clears it when the link goes, because that is what
	# forgets it.
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
	(b, e) := smp->pair(d.conn, d.mux, Smp->Ionoio);
	d.lock <-= 1;
	if(e != nil)
		return e;
	addbond(b);
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
		<-devlock;
		d.id = bt->straddr(b.addr);
		d.idtype = b.atype;
		devlock <-= 1;
	}
	return nil;
}

addbond(b: ref Bond)
{
	<-bondlock;
	nl: list of ref Bond;
	for(l := bonds; l != nil; l = tl l)
		if((hd l).addr != b.addr)
			nl = hd l :: nl;
	bonds = b :: nl;
	s := bondtext0();
	bondlock <-= 1;
	writekeys(s);
}

readkeys()
{
	if(keyfile == nil)
		return;
	fd := sys->open(keyfile, Sys->OREAD);
	if(fd == nil){
		#
		# no key file yet is the ordinary first run and says
		# nothing.  A key file that is there and will not open is
		# every bond silently gone, which is worth a line.
		#
		(ok, nil) := sys->stat(keyfile);
		if(ok == 0)
			sys->fprint(sys->fildes(2),
				"btfs: cannot read %s, so no bond is loaded: %r\n", keyfile);
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
	<-bondlock;
	for(; nb != nil; nb = tl nb)
		bonds = hd nb :: bonds;
	bondlock <-= 1;
}

writekeys(s: string)
{
	if(keyfile == nil)
		return;
	fd := sys->create(keyfile, Sys->OWRITE, 8r600);
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
