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

Kroot, Kctlr, Kaddr, Kver, Kctl, Kstate, Kscan, Kremotes, Kbonds,
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
	addr:	array of byte;
	atype:	int;
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

remove(q: big)
{
	<-treelock;
	tree.remove(q);
	treelock <-= 1;
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
		if(d == nil){
			d = newdev(a.addr, a.atype);
			devs = d :: devs;
		}
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

finddevstr(s: string): ref Dev
{
	for(l := devs; l != nil; l = tl l)
		if(bt->addrstr((hd l).addr) == s)
			return hd l;
	return nil;
}

newdev(addr: array of byte, atype: int): ref Dev
{
	d := ref Dev;
	d.addr = addr;
	d.atype = atype;
	d.state = "seen";
	d.lock = chan[1] of int;
	d.lock <-= 1;
	name := bt->addrstr(addr);
	d.q = newnode(Kdev, d, nil, name);
	create(qremotes(), mkdir(name, d.q));
	mkfd(d.q, "addr", Kdaddr, 8r444, d, nil);
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
	a := hd f;
	<-devlock;
	dd := finddevstr(a);
	if(dd == nil){
		addr := bt->straddr(a);
		if(addr == nil){
			devlock <-= 1;
			return (nil, "not an address");
		}
		atype := Bt->Apublic;
		if(tl f != nil && hd tl f == "random")
			atype = Bt->Arandom;
		dd = newdev(addr, atype);
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
	}
	d.lock <-= 1;
}

#
# a service directory has nothing left in it once its characteristics
# are gone, so removing this device's services and then its gatt
# directory is enough.  Only this device's: every service node carries
# the device it belongs to, and taking down one link must not empty
# the gatt tree of another that is still connected.
#
removetree(d: ref Dev)
{
	# nodes are never reclaimed -- nextq only grows -- so a device
	# that connects and disconnects repeatedly leaves dead service
	# nodes here that every later teardown walks past and asks the
	# tree to remove again.  The tree says it does not have them and
	# that answer is discarded, so it costs a walk and nothing else;
	# it is left this way deliberately rather than by oversight.
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
	return nil;
}

addbond(b: ref Bond)
{
	nl: list of ref Bond;
	for(l := bonds; l != nil; l = tl l)
		if((hd l).addr != b.addr)
			nl = hd l :: nl;
	bonds = b :: nl;
	writekeys();
}

readkeys()
{
	if(keyfile == nil)
		return;
	fd := sys->open(keyfile, Sys->OREAD);
	if(fd == nil)
		return;
	buf := array[8192] of byte;
	s := "";
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[0:n];
	}
	(nil, lines) := sys->tokenize(s, "\n");
	for(; lines != nil; lines = tl lines){
		b := smp->parse(hd lines);
		if(b != nil)
			bonds = b :: bonds;
	}
}

writekeys()
{
	if(keyfile == nil)
		return;
	fd := sys->create(keyfile, Sys->OWRITE, 8r600);
	if(fd == nil)
		return;
	s := bondtext();
	sys->write(fd, array of byte s, len array of byte s);
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "btfs: %s\n", s);
	raise "fail:" + s;
}
